# request_logs: DB-backed telemetry for /identify and /enroll

**Date:** 2026-07-04
**Status:** Approved (pending spec review)

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
debugging) — persisted in Postgres, not container logs.

## Decision

New service-role-only `request_logs` table; one row per request to
`/identify` and `/enroll`, **including failures**. Replaces `_log_demo` and
stdout logging entirely. Dev-only consumer: queried in the Supabase SQL
editor; no iOS app access, no RLS policies.

Rejected alternatives:

- **Extend `events` with a jsonb column** — `events` is app-facing with check
  constraints (`kind`, `result`) that failure outcomes don't fit; mixing dev
  telemetry into the user feed forces constraint loosening and feed filtering.
- **Fix logging config, stay on stdout** — user explicitly wants SQL-queryable
  persistence; Cloud Run log retention/querying is worse for calibration.

## Schema

Append to `server/sql/schema.sql` (idempotent, applied in the Supabase SQL
editor like the rest of the file):

```sql
create table if not exists request_logs (
  id          uuid primary key default gen_random_uuid(),
  request_id  text not null,
  owner       uuid,                -- no FK: log rows must survive user deletion
  kind        text not null check (kind in ('identify', 'enroll')),
  outcome     text not null,
  http_status int not null,
  animal_id   uuid,                -- no FK: keep rows after animal deletion
  model_name  text not null,       -- same convention as embeddings.model_name;
                                   -- keeps score rows comparable per model when
                                   -- the same pictures are re-embedded with a
                                   -- different model
  score       real,                -- top-level for threshold-tuning queries
  margin      real,
  total_ms    int not null,
  detail      jsonb not null default '{}',
  created_at  timestamptz not null default now()
);
create index if not exists request_logs_created_idx on request_logs (created_at desc);
alter table request_logs enable row level security;
-- Deliberately NO policies: only the service role (bypasses RLS) writes;
-- the developer reads via the SQL editor.
```

`outcome` values (text, unconstrained so new outcomes need no migration):

| kind     | success      | failures                                                        |
|----------|--------------|-----------------------------------------------------------------|
| identify | `identified`, `unknown` | `invalid_image`, `model_not_loaded`, `error`         |
| enroll   | `enrolled`   | `invalid_image`, `unowned_animal`, `storage_failed`, `model_not_loaded`, `error` |

`detail` jsonb carries the rest, keys as applicable per outcome/kind:
`candidates` (top-3 `{animal_id, sim}`, ids shortened to last 8 chars as
today), `candidate_count`, `decision_threshold`, `margin_threshold`,
`embed_ms`, `match_ms`, `upload_ms`, `insert_ms`, `image_bytes`,
`image_sizes` (list of `{width, height}` in BOTH endpoints — unifies the two
shapes the review flagged), `muzzle_count`, `muzzle_bytes`,
`full_image_count`, `full_image_bytes`, `enrolled_count`, `error` (exception
detail string on failure outcomes).

Privacy stance carried over from `_log_demo`: `owner` and `animal_id` are
stored as full uuids in their columns (needed for joins), but tokens and
storage paths are never stored; candidate ids inside `detail` stay shortened.

## Code changes (server/app)

### db.py

```python
async def insert_request_log(
    request_id, owner, kind, outcome, http_status, animal_id,
    model_name, score, margin, total_ms, detail: dict,
) -> None
```

Single `insert ... values (..., $n::jsonb)` with `json.dumps(detail)`.

### main.py

- Delete `_log_demo` (and the now-unused `json` import if nothing else uses
  it). Keep `_ms` and `_id_tail` (used for candidate ids in `detail`).
- Add a small `RequestLog` class (plain attributes mirroring the columns plus
  a `detail` dict, `started` perf-counter, and an async `flush()` that calls
  `db.insert_request_log`, computing `total_ms` at flush time). `flush()` is
  best-effort: wraps the insert in `try/except Exception:
  logger.exception(...)` so telemetry failure never fails the request.
- Each endpoint creates `rlog = RequestLog(kind=..., owner=uid,
  model_name=get_settings().embedding_model_name)` at the top, sets fields as
  stages complete, and wraps its body:

```python
try:
    ...existing handler logic, setting rlog fields inline...
    rlog.outcome, rlog.http_status = <success outcome>, 200
    return response
except HTTPException as e:
    rlog.http_status = e.status_code
    rlog.outcome = <mapped outcome>   # from where the exception was raised /
                                      # status: 422→invalid_image,
                                      # 404→unowned_animal, 502→storage_failed,
                                      # 503→model_not_loaded, else 'error'
    rlog.detail["error"] = e.detail
    raise
except Exception as e:
    rlog.outcome, rlog.http_status = "error", 500
    rlog.detail["error"] = repr(e)
    raise
finally:
    await rlog.flush()
```

- Stage timings (`embed_ms`, `match_ms`, `upload_ms`, `insert_ms`) recorded
  into `rlog.detail` where the current `_started`/`_ms` pairs are.
- The four hand-written `try/except → _log_demo → raise` blocks disappear;
  outcome mapping lives once in the endpoint-level `except HTTPException`.
- `_record_event` (app-facing `events` feed) is unchanged.
- `request_id` (`uuid.uuid4().hex[:10]`) is kept as a column so a Cloud Run
  stderr traceback can be matched to a row by hand if needed.

### Edge cases

- Postgres down: `db.match`/`insert_embeddings` fail AND `flush()` fails —
  the row is lost, the traceback still reaches Cloud Run stderr via
  `logger.exception`. Accepted for MVP.
- `flush()` runs in `finally`, so exactly one row per request on every path
  reachable after the dependency (`current_uid`) resolves. Auth failures
  (401 before the handler runs) are not logged — acceptable, they carry no
  calibration signal.
- Volume is demo-scale; no retention/TTL policy.

## Testing / verification

No server test harness exists. Manual verification:

1. Apply the schema block in the Supabase SQL editor.
2. Run the server locally, then:
   - `/identify` with a valid image → row with `outcome in
     ('identified','unknown')`, populated `score`/`margin`/`detail` timings.
   - `/identify` with a non-image payload → row with `outcome =
     'invalid_image'`, `http_status = 422`.
   - `/enroll` for an owned animal → row with `outcome = 'enrolled'`,
     `enrolled_count` in `detail`.
3. Confirm the iOS app feed (`events`) is unaffected.
