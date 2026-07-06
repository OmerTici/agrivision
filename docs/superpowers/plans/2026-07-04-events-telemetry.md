# Events-Table Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist per-request telemetry (timings, scores, model name, failures) for `/identify` and `/enroll` into the existing `events` table, replacing the broken stdout `_log_demo` logging, and add the missing `embeddings.model_name` column to the live database.

**Architecture:** One `events` row per request (success AND failure) written by a small `_RequestLog` helper in a `try/except/finally` per endpoint — this merges the old `_record_event` feed write and `_log_demo` telemetry into a single insert. The iOS feed filters to success results and selects explicit columns. Spec: `docs/superpowers/specs/2026-07-04-request-logs-design.md`.

**Tech Stack:** FastAPI + asyncpg (server), pytest (`server/tests`, existing harness with `TestClient` + monkeypatch), Supabase Postgres (live project `xznmsmweefckkqjfepqs`, applied via Supabase MCP `apply_migration`), SwiftUI + supabase-swift (iOS).

## Global Constraints

- Embedding model identifier (exact string, used in migration default and asserted in tests): `conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d` (source: `server/app/config.py:21-23`).
- Live Supabase project id: `xznmsmweefckkqjfepqs` (project "mvp_agrivision"). Do NOT touch project `fciaprnvlmdncxdjstxh` ("AgriTrack" — unrelated).
- Telemetry write is best-effort: an `events` insert failure must never fail the API response (existing stance, `server/app/main.py:_record_event`), capped by `asyncio.wait_for(..., timeout=5.0)`.
- Privacy: tokens and storage paths never go into `detail`; candidate ids inside `detail` are shortened to their last 8 chars via `_id_tail`.
- Run server tests from `server/`: `python -m pytest tests/test_api.py -v` (integration/slow tests are marker-gated and skip without env).
- `events.animal_id` has a FK to `animals(id)`: only write it when the animal is confirmed to exist (success paths / post-ownership-check failures). For `unowned_animal` failures put the attempted id in `detail.animal_id_attempted` instead — inserting a nonexistent uuid into the column would violate the FK and lose the row.

---

### Task 1: Database migrations (live Supabase + schema.sql)

**Files:**
- Modify: `server/sql/schema.sql` (events create-table block at lines 52-60; add migration `alter` statements)
- Live DB: apply two migrations via Supabase MCP `apply_migration` (project `xznmsmweefckkqjfepqs`)

**Interfaces:**
- Produces: live `embeddings.model_name text not null default '<model>'` column; live `events` columns `model_name text`, `margin real`, `http_status int`, `total_ms int`, `request_id text`, `detail jsonb not null default '{}'`; widened `events_result_check`. Task 2's insert depends on all of these existing in the live DB.

- [ ] **Step 1: Apply migration `embeddings_model_name` to the live DB**

Confirmed absent on 2026-07-04 (`information_schema.columns` shows only `id, animal_id, owner, vec, image_path, created_at`), while `db.py` `MATCH_SQL`/`INSERT_SQL` already reference it — the next server deploy breaks without this. Call `mcp__claude_ai_Supabase__apply_migration` with `project_id: "xznmsmweefckkqjfepqs"`, `name: "embeddings_model_name"`, query:

```sql
alter table embeddings add column if not exists model_name text not null
  default 'conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d';
create index if not exists embeddings_owner_model_idx on embeddings (owner, model_name);
```

(Existing rows were all embedded with the launch model, so backfilling via the default is correct.)

- [ ] **Step 2: Apply migration `events_telemetry` to the live DB**

Call `mcp__claude_ai_Supabase__apply_migration` with `project_id: "xznmsmweefckkqjfepqs"`, `name: "events_telemetry"`, query:

```sql
alter table events add column if not exists model_name  text;
alter table events add column if not exists margin      real;
alter table events add column if not exists http_status int;
alter table events add column if not exists total_ms    int;
alter table events add column if not exists request_id  text;
alter table events add column if not exists detail      jsonb not null default '{}';

alter table events drop constraint if exists events_result_check;
alter table events add constraint events_result_check check (result in (
  'enrolled', 'identified', 'unknown',
  'invalid_image', 'unowned_animal', 'storage_failed',
  'model_not_loaded', 'error'
));

update events set model_name = 'conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d'
  where model_name is null;
```

- [ ] **Step 3: Verify live schema**

Run `mcp__claude_ai_Supabase__execute_sql` on project `xznmsmweefckkqjfepqs`:

```sql
select table_name, column_name, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and ((table_name = 'embeddings' and column_name = 'model_name')
    or (table_name = 'events' and column_name in
        ('model_name','margin','http_status','total_ms','request_id','detail')))
order by table_name, column_name;
```

Expected: 7 rows (1 for embeddings, 6 for events); `embeddings.model_name` is `NO`-nullable with the model default; `events.detail` is `NO`-nullable with default `'{}'::jsonb`.

- [ ] **Step 4: Update `server/sql/schema.sql`**

Replace the events block (currently lines 50-61) with:

```sql
-- Action feed + request telemetry: one row per enroll/identify request,
-- INCLUDING failures, written ONLY by the embedder (service role). Owners
-- read their own success rows from the iOS app via PostgREST (the app
-- filters result to the success values and never selects detail).
create table if not exists events (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid references auth.users not null,
  kind        text not null check (kind in ('enroll', 'identify')),
  animal_id   uuid references animals(id) on delete set null,  -- null for unknown identify and most failures
  result      text not null check (result in (
    'enrolled', 'identified', 'unknown',                       -- success (app feed)
    'invalid_image', 'unowned_animal', 'storage_failed',       -- failures (telemetry only)
    'model_not_loaded', 'error'
  )),
  score       real,                                 -- top-1 similarity for identify, null for enroll
  margin      real,                                 -- top1 - top2 similarity for identify
  model_name  text,                                 -- embedding model that produced score/margin
  http_status int,
  total_ms    int,
  request_id  text,
  detail      jsonb not null default '{}',          -- timings, candidates, byte counts
  created_at  timestamptz not null default now()
);

-- Migration for existing databases (safe to re-run):
alter table embeddings add column if not exists model_name text not null
  default 'conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d';
alter table events add column if not exists model_name  text;
alter table events add column if not exists margin      real;
alter table events add column if not exists http_status int;
alter table events add column if not exists total_ms    int;
alter table events add column if not exists request_id  text;
alter table events add column if not exists detail      jsonb not null default '{}';
alter table events drop constraint if exists events_result_check;
alter table events add constraint events_result_check check (result in (
  'enrolled', 'identified', 'unknown',
  'invalid_image', 'unowned_animal', 'storage_failed',
  'model_not_loaded', 'error'
));
```

Keep the existing `events_owner_created_idx` index, RLS enable, and "own events" select policy lines below the block exactly as they are.

Note: the `create table if not exists embeddings` block already declares `model_name` (schema.sql line 23) — only the `alter table` migration line above is new.

- [ ] **Step 5: Commit**

```bash
git add server/sql/schema.sql
git commit -m "feat(db): events telemetry columns + embeddings.model_name migration"
```

---

### Task 2: Server — one events row per request (`db.py`, `main.py`, tests)

**Files:**
- Modify: `server/app/db.py:84-94` (`INSERT_EVENT_SQL`, `insert_event`)
- Modify: `server/app/main.py` (delete `_log_demo` and `_record_event`; add `_RequestLog`; rewrite `identify` and `enroll` bodies)
- Modify: `server/tests/conftest.py:27-31` (noop stub signature)
- Test: `server/tests/test_api.py`

**Interfaces:**
- Consumes: Task 1's live columns (only at runtime; unit tests monkeypatch `db.insert_event`).
- Produces: `db.insert_event(owner: str, kind: str, animal_id: str | None, result: str, score: float | None, *, model_name: str | None = None, margin: float | None = None, http_status: int | None = None, total_ms: int | None = None, request_id: str | None = None, detail: dict | None = None) -> None`. Task 3 (iOS) relies on failure rows carrying `result` values `invalid_image | unowned_animal | storage_failed | model_not_loaded | error`.

- [ ] **Step 1: Update the conftest stub to tolerate the new keyword arguments**

In `server/tests/conftest.py`, replace lines 27-31 with:

```python
    async def _noop_insert_event(*args, **kwargs):
        return None

    # Unit tests never touch Postgres; event-asserting tests re-stub this.
    monkeypatch.setattr(db, "insert_event", _noop_insert_event)
```

- [ ] **Step 2: Rewrite the three existing event tests and add five failure-row tests (failing first)**

In `server/tests/test_api.py`, add this helper near the top (after `ANIMAL = ...`):

```python
def _capture_events(monkeypatch):
    """Stub db.insert_event, returning the list it appends (args, kwargs) to."""
    recorded = []

    async def fake_insert_event(owner, kind, animal_id, result, score, **kw):
        recorded.append({"owner": owner, "kind": kind, "animal_id": animal_id,
                         "result": result, "score": score, **kw})

    monkeypatch.setattr(main_mod.db, "insert_event", fake_insert_event)
    return recorded
```

Replace `test_enroll_writes_event`, `test_identify_identified_writes_event`, `test_identify_unknown_writes_event`, and `test_event_insert_failure_does_not_fail_response` with:

```python
MODEL = "conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d"


def test_enroll_writes_event(client, jpeg_bytes, monkeypatch):
    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        return path

    async def fake_insert(animal_id, owner, vecs, image_paths):
        return len(image_paths)

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    monkeypatch.setattr(main_mod.db, "insert_embeddings", fake_insert)
    recorded = _capture_events(monkeypatch)

    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 200
    (e,) = recorded
    assert (e["owner"], e["kind"], e["animal_id"], e["result"], e["score"]) == (
        TEST_UID, "enroll", ANIMAL, "enrolled", None,
    )
    assert e["http_status"] == 200
    assert e["model_name"] == MODEL
    assert e["detail"]["muzzle_count"] == 1
    assert e["detail"]["enrolled_count"] == 1
    assert "upload_ms" in e["detail"] and "embed_ms" in e["detail"] and "insert_ms" in e["detail"]
    assert e["total_ms"] >= 0 and len(e["request_id"]) == 10


def test_identify_identified_writes_event(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return [Candidate(ANIMAL, "Bessie", 0.91), Candidate("other", None, 0.60)]

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    recorded = _capture_events(monkeypatch)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    (e,) = recorded
    assert (e["owner"], e["kind"], e["animal_id"], e["result"]) == (
        TEST_UID, "identify", ANIMAL, "identified",
    )
    assert e["score"] == pytest.approx(0.91)
    assert e["margin"] == pytest.approx(0.31)
    assert e["http_status"] == 200
    assert e["model_name"] == MODEL
    assert e["detail"]["candidate_count"] == 2
    assert e["detail"]["candidates"][0]["sim"] == pytest.approx(0.91)
    assert "embed_ms" in e["detail"] and "match_ms" in e["detail"]


def test_identify_unknown_writes_event(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return []  # empty gallery -> unknown

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    recorded = _capture_events(monkeypatch)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"
    (e,) = recorded
    assert (e["animal_id"], e["result"], e["http_status"]) == (None, "unknown", 200)


def test_event_insert_failure_does_not_fail_response(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return []

    async def exploding_insert_event(*args, **kwargs):
        raise RuntimeError("db down")

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    monkeypatch.setattr(main_mod.db, "insert_event", exploding_insert_event)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"
```

Then add the five new failure-row tests at the end of the file:

```python
def test_identify_invalid_image_writes_failure_row(client, monkeypatch):
    recorded = _capture_events(monkeypatch)
    r = client.post("/identify", files={"image": ("m.jpg", b"not a jpeg", "image/jpeg")})
    assert r.status_code == 422
    (e,) = recorded
    assert (e["kind"], e["result"], e["http_status"]) == ("identify", "invalid_image", 422)
    assert e["animal_id"] is None and e["score"] is None
    assert e["detail"]["error"] == "invalid image payload"
    assert e["detail"]["image_bytes"] == len(b"not a jpeg")


def test_identify_model_not_loaded_writes_failure_row(client, jpeg_bytes, monkeypatch):
    recorded = _capture_events(monkeypatch)
    main_mod.state["embedder"] = None  # client fixture restores this on teardown
    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 503
    (e,) = recorded
    assert (e["result"], e["http_status"]) == ("model_not_loaded", 503)


def test_identify_unexpected_error_writes_error_row(client, jpeg_bytes, monkeypatch):
    async def exploding_match(vec, owner):
        raise RuntimeError("pg down")

    monkeypatch.setattr(main_mod.db, "match", exploding_match)
    recorded = _capture_events(monkeypatch)
    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 500
    (e,) = recorded
    assert (e["result"], e["http_status"]) == ("error", 500)
    assert "RuntimeError" in e["detail"]["error"]


def test_enroll_unowned_writes_failure_row(client, jpeg_bytes, monkeypatch):
    async def fake_animal_owned(animal_id, owner):
        return False

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    recorded = _capture_events(monkeypatch)
    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 404
    (e,) = recorded
    assert (e["kind"], e["result"], e["http_status"]) == ("enroll", "unowned_animal", 404)
    # FK safety: the column stays NULL for an unverified id; it goes in detail.
    assert e["animal_id"] is None
    assert e["detail"]["animal_id_attempted"] == ANIMAL


def test_enroll_storage_failure_writes_failure_row(client, jpeg_bytes, monkeypatch):
    import httpx

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        raise httpx.HTTPStatusError(
            "boom", request=httpx.Request("POST", "http://x"), response=httpx.Response(500)
        )

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    recorded = _capture_events(monkeypatch)
    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 502
    (e,) = recorded
    assert (e["result"], e["http_status"]) == ("storage_failed", 502)
    assert e["animal_id"] == ANIMAL  # ownership was confirmed before the failure
```

`test_identify_identified_writes_event` asserts `margin == 0.31` (top1 0.91 − top2 0.60), matching `decide()`'s margin definition — if this assertion fails with margin equal to 0.91, read `server/app/decision.py` and adjust the expected value to the actual top1−top2 semantics; do not weaken the assertion to "is not None".

- [ ] **Step 3: Run the tests to verify the new/changed ones fail**

```bash
cd server && python -m pytest tests/test_api.py -v
```

Expected: the rewritten event tests fail with `TypeError`-style mismatches or missing-key assertions (old `insert_event` receives no kwargs); the five new failure-row tests fail with `recorded` empty (no row written on failure paths today). Pre-existing non-event tests still pass.

- [ ] **Step 4: Implement `db.insert_event` with the new columns**

In `server/app/db.py`: add `import json` to the imports (after `import asyncio`), then replace lines 84-94 with:

```python
INSERT_EVENT_SQL = """
insert into events (owner, kind, animal_id, result, score,
                    model_name, margin, http_status, total_ms, request_id, detail)
values ($1::uuid, $2, $3::uuid, $4, $5, $6, $7, $8, $9, $10, $11::jsonb)
"""


async def insert_event(
    owner: str,
    kind: str,
    animal_id: str | None,
    result: str,
    score: float | None,
    *,
    model_name: str | None = None,
    margin: float | None = None,
    http_status: int | None = None,
    total_ms: int | None = None,
    request_id: str | None = None,
    detail: dict | None = None,
) -> None:
    pool = await get_pool()
    await pool.execute(
        INSERT_EVENT_SQL,
        owner, kind, animal_id, result, score,
        model_name, margin, http_status, total_ms, request_id,
        json.dumps(detail or {}),
    )
```

- [ ] **Step 5: Implement `_RequestLog` and rewire both endpoints in `main.py`**

In `server/app/main.py`:

1. Remove `import json` from the imports (no longer used in this module).
2. Delete `_log_demo` (lines 49-55) and `_record_event` (lines 79-90).
3. Add after `_id_tail`:

```python
# HTTPException status -> events.result for failure rows.
_FAILURE_RESULTS = {
    404: "unowned_animal",
    422: "invalid_image",
    502: "storage_failed",
    503: "model_not_loaded",
}


class _RequestLog:
    """One events row per request — the app feed and the demo/calibration
    telemetry in a single write. Field defaults assume the worst (error/500);
    the happy path overwrites them just before returning. flush() is
    best-effort: an insert failure must never fail the API response, and is
    capped at 5s so a degraded pool can't stall the response."""

    def __init__(self, kind: str, owner: str):
        self.kind = kind
        self.owner = owner
        self.request_id = uuid.uuid4().hex[:10]
        self.started = time.perf_counter()
        self.animal_id: str | None = None  # only set once the animal is known to exist (FK)
        self.result = "error"
        self.http_status = 500
        self.score: float | None = None
        self.margin: float | None = None
        self.model_name = get_settings().embedding_model_name
        self.detail: dict = {}

    def fail(self, exc: HTTPException) -> None:
        self.http_status = exc.status_code
        self.result = _FAILURE_RESULTS.get(exc.status_code, "error")
        self.detail["error"] = exc.detail

    async def flush(self) -> None:
        try:
            await asyncio.wait_for(
                db.insert_event(
                    self.owner, self.kind, self.animal_id, self.result, self.score,
                    model_name=self.model_name,
                    margin=self.margin,
                    http_status=self.http_status,
                    total_ms=_ms(self.started),
                    request_id=self.request_id,
                    detail=self.detail,
                ),
                timeout=5.0,
            )
        except Exception:
            logger.exception(
                "event insert failed (kind=%s, result=%s)", self.kind, self.result
            )
```

4. Replace the entire `identify` endpoint with:

```python
@app.post("/identify", response_model=IdentifyResponse)
async def identify(image: UploadFile = File(...), uid: str = Depends(current_uid)):
    rlog = _RequestLog("identify", uid)
    try:
        raw = await image.read()
        rlog.detail["image_bytes"] = len(raw)
        pil = _decode_jpegs([raw])
        rlog.detail["image_sizes"] = [{"width": pil[0].width, "height": pil[0].height}]
        embed_started = time.perf_counter()
        vec = _embed(pil)[0]
        rlog.detail["embed_ms"] = _ms(embed_started)
        match_started = time.perf_counter()
        candidates = await db.match(vec, uid)
        rlog.detail["match_ms"] = _ms(match_started)
        s = get_settings()
        d = decide(candidates, s.sim_threshold, s.sim_margin)
        rlog.animal_id = d.animal_id
        rlog.result = "identified" if d.decision == "identified" else "unknown"
        rlog.http_status = 200
        rlog.score = d.score
        rlog.margin = d.margin
        rlog.detail.update(
            decision_threshold=s.sim_threshold,
            margin_threshold=s.sim_margin,
            candidates=[
                {"animal_id": _id_tail(c.animal_id), "sim": round(c.sim, 4)}
                for c in candidates[:3]
            ],
            candidate_count=len(candidates),
        )
        return IdentifyResponse(
            decision=d.decision,
            animal_id=d.animal_id,
            name=d.name,
            score=d.score,
            margin=d.margin,
            candidates=[
                CandidateOut(animal_id=c.animal_id, name=c.name, sim=c.sim)
                for c in candidates
            ],
        )
    except HTTPException as e:
        rlog.fail(e)
        raise
    except Exception as e:
        rlog.detail["error"] = repr(e)  # result/http_status already default to error/500
        raise
    finally:
        await rlog.flush()
```

5. Replace the entire `enroll` endpoint with:

```python
@app.post("/enroll", response_model=EnrollResponse)
async def enroll(
    animal_id: str = Form(...),
    images: list[UploadFile] = File(...),
    full_images: list[UploadFile] = File(default=[]),
    uid: str = Depends(current_uid),
):
    rlog = _RequestLog("enroll", uid)
    try:
        if not await db.animal_owned(animal_id, uid):
            # Unverified id: keep it out of the FK column, log it in detail.
            rlog.detail["animal_id_attempted"] = animal_id
            raise HTTPException(status_code=404, detail="animal not found for this user")
        rlog.animal_id = animal_id
        raw = [await f.read() for f in images]
        rlog.detail["muzzle_count"] = len(raw)
        rlog.detail["muzzle_bytes"] = sum(len(data) for data in raw)
        pil = _decode_jpegs(raw)
        rlog.detail["image_sizes"] = [{"width": im.width, "height": im.height} for im in pil]
        raw_full = [await f.read() for f in full_images]
        rlog.detail["full_image_count"] = len(raw_full)
        rlog.detail["full_image_bytes"] = sum(len(data) for data in raw_full)
        _decode_jpegs(raw_full)  # validate only; full pictures are stored, never embedded
        embed_started = time.perf_counter()
        vecs = _embed(pil)  # ONE batched forward pass for all muzzle crops
        rlog.detail["embed_ms"] = _ms(embed_started)
        paths = []
        # On partial upload failure we return 502 and skip the DB insert; already-
        # uploaded objects are left as storage orphans (DB stays the source of
        # truth). Acceptable for MVP; a cleanup pass can reap them later.
        upload_started = time.perf_counter()
        try:
            for data in raw:
                path = storage.object_path(uid, animal_id, "muzzle")
                await storage.upload_jpeg(path, data)
                paths.append(path)
            for data in raw_full:
                await storage.upload_jpeg(storage.object_path(uid, animal_id, "full"), data)
        except httpx.HTTPError:
            raise HTTPException(status_code=502, detail="image storage upload failed")
        rlog.detail["upload_ms"] = _ms(upload_started)
        insert_started = time.perf_counter()
        count = await db.insert_embeddings(animal_id, uid, vecs, paths)
        rlog.detail["insert_ms"] = _ms(insert_started)
        rlog.detail["enrolled_count"] = count
        rlog.result = "enrolled"
        rlog.http_status = 200
        return EnrollResponse(enrolled_count=count, full_images_stored=len(raw_full))
    except HTTPException as e:
        rlog.fail(e)
        raise
    except Exception as e:
        rlog.detail["error"] = repr(e)
        raise
    finally:
        await rlog.flush()
```

- [ ] **Step 6: Run the full server suite**

```bash
cd server && python -m pytest -v
```

Expected: all tests pass (integration/slow skip without env). If `test_identify_identified_writes_event` fails only on the margin value, see the note in Step 2.

- [ ] **Step 7: Commit**

```bash
git add server/app/db.py server/app/main.py server/tests/conftest.py server/tests/test_api.py
git commit -m "feat(server): one events row per request — feed + telemetry, incl. failures"
```

---

### Task 3: iOS — feed filters to success rows, explicit columns

**Files:**
- Modify: `AgriVision/Services/EventRepository.swift:62-91` (`recent`, `page`)

**Interfaces:**
- Consumes: Task 2's failure `result` values (rows the feed must exclude): `invalid_image`, `unowned_animal`, `storage_failed`, `model_not_loaded`, `error`.
- Produces: unchanged `EventRecord` API for `HomeView`/scan-history callers.

- [ ] **Step 1: Add the success filter and explicit column list to both queries**

In `AgriVision/Services/EventRepository.swift`, add near the top of `EventRepository` (below `private let client`):

```swift
    /// Result values that are user-visible feed entries. The events table also
    /// holds failure telemetry rows (invalid_image, storage_failed, ...) that
    /// the app must never render.
    private static let feedResults = ["enrolled", "identified", "unknown"]
    /// Feed queries never select telemetry columns (detail jsonb etc.).
    private static let feedColumns = "id,kind,animal_id,result,score,created_at"
```

Replace `recent(limit:)` (lines 63-71) with:

```swift
    /// Most recent events, newest first.
    func recent(limit: Int) async throws -> [EventRecord] {
        let response = try await client
            .from("events")
            .select(Self.feedColumns)
            .in("result", values: Self.feedResults)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
        return try JSONDecoder().decode([EventRecord].self, from: response.data)
    }
```

In `page(offset:limit:animal:since:)`, replace line 77:

```swift
        var query = client.from("events").select()
```

with:

```swift
        var query = client.from("events").select(Self.feedColumns)
            .in("result", values: Self.feedResults)
```

`EventRecord` itself is unchanged (`result` is a plain `String`, `EventRepository.swift:33`).

- [ ] **Step 2: Build the app**

```bash
xcodebuild -project AgriVision.xcodeproj -scheme AgriVision \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (If the scheme name differs, list schemes with `xcodebuild -list -project AgriVision.xcodeproj`.) If `.in(...)` fails to compile on this supabase-swift version, the equivalent spelling is `.filter("result", operator: "in", value: "(enrolled,identified,unknown)")` — prefer `.in` if it compiles.

- [ ] **Step 3: Commit**

```bash
git add AgriVision/Services/EventRepository.swift
git commit -m "fix(scan-history): feed shows only success events, skips telemetry columns"
```

---

### Task 4: End-to-end verification against the live stack

**Files:**
- None modified — verification only.

**Interfaces:**
- Consumes: everything above, deployed schema on project `xznmsmweefckkqjfepqs`.

- [ ] **Step 1: Full server suite one more time from a clean state**

```bash
cd server && python -m pytest -v
```

Expected: all pass.

- [ ] **Step 2: Confirm no stray references to the removed helpers**

```bash
grep -rn "_log_demo\|_record_event" server/ && echo "FOUND — fix before proceeding" || echo "clean"
```

Expected: `clean`.

- [ ] **Step 3: Live smoke check (user-driven)**

The server must be deployed (or run locally with real `.env`) for rows to land. After the user performs one identify and one enroll from the iOS app, run via `mcp__claude_ai_Supabase__execute_sql` on `xznmsmweefckkqjfepqs`:

```sql
select kind, result, http_status, model_name, score, margin, total_ms,
       detail->'embed_ms' as embed_ms, created_at
from events
order by created_at desc
limit 5;
```

Expected: the new rows show `http_status = 200`, the model name string, and non-null `total_ms`/`embed_ms`; older rows show nulls in the new columns. Confirm in the app that Home last-5 and scan history render normally.

- [ ] **Step 4: Report completion to the user**

Summarize: migrations applied (including the previously missing `embeddings.model_name`), server writes one row per request including failures, iOS feed filtered. Remind: server redeploy required for the new telemetry to start flowing.
