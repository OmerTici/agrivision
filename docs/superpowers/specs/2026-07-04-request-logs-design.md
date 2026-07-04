# events expansion: DB-backed telemetry for /identify and /enroll

**Date:** 2026-07-04
**Status:** Approved (pending spec review) — revision 2: telemetry lives in the
existing `events` table (user decision), not a separate `request_logs` table.

## Problem

The demo-calibration instrumentation currently in the working tree writes JSON
lines via `logger.info` (`_log_demo` in `server/app/main.py`). Code review
found:

1. The lines are silently dropped in the deployed container — nothing
   configures Python logging, so the logger's effective level is WARNING.
2. Failure paths other than image decode (cold-start 503 from `_embed`, db
   errors, `insert_embeddings` strict-zip mismatch) emit no line at all.
3. `request_id` correlates nothing (one line per request, never returned to
   the client).
4. The instrumentation is copy-pasted across 7 call sites and 4 near-identical
   try/except blocks.

The user wants this telemetry queryable later (threshold tuning, demo
debugging) — persisted in Postgres, not container logs. Additionally, scores
must be attributable to the embedding model that produced them, so the same
pictures can be re-embedded under a different model and analyzed with a
model filter (the `embeddings` table already carries `model_name` and
`MATCH_SQL` already filters by it; `events` currently does not record it).

## Decision

Expand the existing `events` table: one row per request to `/identify` and
`/enroll`, **including failures**, with telemetry in new columns + a `detail`
jsonb. Replaces `_log_demo`, stdout logging, AND the separate `_record_event`
write (one insert per request serves both the app feed and telemetry).

Consumers:
- **iOS app** (feed): reads success rows only, explicit column list.
- **Developer** (telemetry): all rows + `detail`, via the Supabase SQL editor.

Rejected alternatives:

- **Separate `request_logs` table** (revision 1) — cleaner separation, but the
  user prefers one table; the client is controllable (plain-`String` result
  decoding at `EventRepository.swift:33`, filters added below), so the
  practical risk is low. Accepted trade-off: feed and telemetry share a
  lifecycle (no independent truncation; `animal_id` is `on delete set null`,
  so telemetry loses the animal reference when an animal is deleted).
- **Fix logging config, stay on stdout** — user wants SQL-queryable
  persistence; Cloud Run log retention/querying is worse for calibration.

## Schema

Append to `server/sql/schema.sql` (idempotent, applied in the Supabase SQL
editor like the rest of the file):

```sql
-- Telemetry expansion: events now records every request outcome incl.
-- failures. The iOS app filters to success results and never selects detail.
alter table events add column if not exists model_name  text;
alter table events add column if not exists margin      real;
alter table events add column if not exists http_status int;
alter table events add column if not exists total_ms    int;
alter table events add column if not exists request_id  text;
alter table events add column if not exists detail      jsonb not null default '{}';

alter table events drop constraint if exists events_result_check;
alter table events add constraint events_result_check check (result in (
  'enrolled', 'identified', 'unknown',                       -- success (app feed)
  'invalid_image', 'unowned_animal', 'storage_failed',       -- failures (telemetry only)
  'model_not_loaded', 'error'
));

-- Optional backfill: rows written before this migration were produced by the
-- launch model.
-- update events set model_name = 'conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d'
--   where model_name is null;
```

Existing columns keep their meaning; `score` stays top-level (threshold
tuning), now interpretable per `model_name`. RLS is unchanged: owners can
select their own rows (their own telemetry included — acceptable), only the
service role writes.

Result values per kind:

| kind     | success (visible in app feed)  | failures (telemetry only)                                        |
|----------|--------------------------------|------------------------------------------------------------------|
| identify | `identified`, `unknown`        | `invalid_image`, `model_not_loaded`, `error`                     |
| enroll   | `enrolled`                     | `invalid_image`, `unowned_animal`, `storage_failed`, `model_not_loaded`, `error` |

`detail` jsonb carries the rest, keys as applicable per result/kind:
`candidates` (top-3 `{animal_id, sim}`, ids shortened to last 8 chars as
today), `candidate_count`, `decision_threshold`, `margin_threshold`,
`embed_ms`, `match_ms`, `upload_ms`, `insert_ms`, `image_bytes`,
`image_sizes` (list of `{width, height}` in BOTH endpoints — unifies the two
shapes the review flagged), `muzzle_count`, `muzzle_bytes`,
`full_image_count`, `full_image_bytes`, `enrolled_count`, `error` (exception
detail string on failure results).

Privacy stance carried over from `_log_demo`: tokens and storage paths are
never stored; candidate ids inside `detail` stay shortened.

## Code changes

### server/app/db.py

Replace `insert_event` with:

```python
async def insert_event(
    owner, kind, animal_id, result, score,
    *, model_name, margin, http_status, total_ms, request_id, detail: dict,
) -> None
```

Single insert; `detail` passed as `json.dumps(detail)::jsonb`.

### server/app/main.py

- Delete `_log_demo` and `_record_event` (one write per request now). Keep
  `_ms` and `_id_tail` (candidate ids in `detail`).
- Add a small `RequestLog` class: plain attributes mirroring the columns plus
  a `detail` dict, `started` perf-counter, and an async `flush()` that calls
  `db.insert_event`, computing `total_ms` at flush time. `flush()` is
  best-effort: `try/except Exception: logger.exception(...)` so a telemetry
  failure never fails the request (same stance as today's `_record_event`).
- Each endpoint creates `rlog = RequestLog(kind=..., owner=uid,
  model_name=get_settings().embedding_model_name)` at the top, sets fields as
  stages complete, and wraps its body:

```python
try:
    ...existing handler logic, setting rlog fields inline...
    rlog.result, rlog.http_status = <success result>, 200
    return response
except HTTPException as e:
    rlog.http_status = e.status_code
    rlog.result = <mapped result>     # 422→invalid_image, 404→unowned_animal,
                                      # 502→storage_failed, 503→model_not_loaded,
                                      # else 'error'
    rlog.detail["error"] = e.detail
    raise
except Exception as e:
    rlog.result, rlog.http_status = "error", 500
    rlog.detail["error"] = repr(e)
    raise
finally:
    await rlog.flush()
```

- Stage timings (`embed_ms`, `match_ms`, `upload_ms`, `insert_ms`) recorded
  into `rlog.detail` where the current `_started`/`_ms` pairs are.
- The four hand-written `try/except → _log_demo → raise` blocks disappear;
  result mapping lives once in the endpoint-level `except HTTPException`.
- `request_id` (`uuid.uuid4().hex[:10]`) kept as a column so a Cloud Run
  stderr traceback can be matched to a row by hand.

### AgriVision/Services/EventRepository.swift (iOS)

Both `recent(limit:)` and `page(offset:limit:animal:since:)`:

1. Filter to feed-visible rows:
   `.in("result", values: ["enrolled", "identified", "unknown"])`
2. Replace `select()` (= `select=*`) with the explicit feed column list
   `select("id,kind,animal_id,result,score,created_at")` so the feed never
   downloads `detail`/telemetry columns.

`EventRecord` is unchanged (`result` is already a plain `String`).

### Edge cases

- Postgres down: the handler fails AND `flush()` fails — the row is lost, the
  traceback still reaches Cloud Run stderr via `logger.exception`. Accepted
  for MVP.
- `flush()` runs in `finally`: exactly one row per request on every path
  reachable after `current_uid` resolves. Auth failures (401 before the
  handler runs) are not logged — acceptable, no calibration signal.
- Old app builds (no result filter) would render failure rows in the feed as
  odd entries; acceptable pre-launch, and new builds ship the filter.
- Volume is demo-scale; no retention/TTL policy.

## Testing / verification

No server test harness exists. Manual verification:

1. Apply the schema block in the Supabase SQL editor.
2. Run the server locally, then:
   - `/identify` with a valid image → row with `result in
     ('identified','unknown')`, populated `score`/`margin`/`model_name` and
     `detail` timings.
   - `/identify` with a non-image payload → row with `result =
     'invalid_image'`, `http_status = 422`.
   - `/enroll` for an owned animal → row with `result = 'enrolled'`,
     `enrolled_count` in `detail`.
3. Build and run the iOS app: Home last-5 and scan history show only success
   rows and paginate correctly with the new filters.
