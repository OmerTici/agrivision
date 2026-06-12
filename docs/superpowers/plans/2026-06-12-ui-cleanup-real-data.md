# UI Cleanup & Real Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all demo/dummy data from the CarniVision iOS app and make every screen reflect reality: the user's enrolled animals (with the photos they actually took), recent enroll/identify actions from a new server-side `events` table, and search. Strip UI for data that has no backend (weights, health status, scan urgency, charts). 4-tab bar; Add-Animal becomes a **+** on the Animals screen.

**Architecture:** Reads go direct to Supabase (PostgREST + Storage) under RLS using the supabase-swift client (`SupabaseClientProvider.shared`, supabase-swift 2.47.0 exact). Writes with side effects stay in the Cloud Run embedder (`server/`), which gains best-effort `events` inserts via the existing asyncpg pool (`app/db.py`). The iOS data layer grows `AnimalRepository.list()`, a new `EventRepository`, a new `AnimalPhotoLoader` (memory + disk cache), and a rewritten `HerdStore` with no seed data.

**Tech Stack:** FastAPI + asyncpg + pgvector (server), pytest (`-m "not slow"`, env-gated `integration` marker), SwiftUI + supabase-swift 2.47.0 (iOS), XCTest. iOS app target uses old-style PBXGroup — new app-target files need 4-point manual pbxproj registration. `CarniVisionTests` is filesystem-synchronized — test files auto-register.

---

**Repo root:** `/Users/korkutkaanbalta/Documents/carni_vision` (branch `ios-recognition`).

**Build/test commands used throughout:**

```bash
# iOS build
xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# iOS tests
xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
# Server tests (from server/) — baseline today: 29 passed, 1 skipped, 2 deselected
.venv/bin/pytest tests/ -m "not slow" -q
```

**Never read `server/.env` (secrets).**

**Task order:** server (Tasks 1–4) → iOS data layer (5–8) → screens (9–13) → localization cleanup (14) → full test/build pass (15) → Cloud Run deploy (16, controller-run with user approval).

---

### Task 1: `events` table + Storage owner-read policy (schema + setup script)

**Files:**
- Modify: `server/sql/schema.sql`
- Modify: `server/scripts/setup_supabase.py`
- User-run step: apply via `scripts/setup_supabase.py`

- [ ] **Step 1: Append the events DDL and storage policy to `server/sql/schema.sql`**

Append this block at the end of the file (after the `"own embeddings"` policy). It follows the file's existing idempotency pattern (`create table if not exists`, `drop policy if exists` + `create policy`). Two deliberate details: `on delete set null` on `animal_id` keeps event history (and test cleanup) working when an animal row is deleted; the storage policy sits in a `DO` block because on newer Supabase projects the `postgres` role may not own `storage.objects` — the block degrades to a NOTICE instead of aborting the whole schema apply.

```sql

-- Action feed: one row per enroll/identify, written ONLY by the embedder
-- (service role). Owners read their own feed from the iOS app via PostgREST.
create table if not exists events (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null,
  kind        text not null check (kind in ('enroll', 'identify')),
  animal_id   uuid references animals(id) on delete set null,  -- null for unknown identify
  result      text not null check (result in ('enrolled', 'identified', 'unknown')),
  score       real,                                 -- top-1 similarity for identify, null for enroll
  created_at  timestamptz not null default now()
);
create index if not exists events_owner_created_idx on events (owner, created_at desc);

alter table events enable row level security;

-- Owners read their own events; there is deliberately NO insert/update/delete
-- policy — only the service role (which bypasses RLS) writes.
drop policy if exists "own events" on events;
create policy "own events" on events
  for select using (owner = auth.uid());

-- Storage: owners read their own photos. Object paths are
-- {owner_uid}/{animal_id}/{muzzle|full}/{uuid}.jpg, so the first path segment
-- is the owner uid. Wrapped in a DO block: on some Supabase projects the
-- postgres role cannot create policies on storage.objects; in that case the
-- NOTICE below says to add it in Dashboard > Storage > Policies instead.
do $$
begin
  drop policy if exists "muzzles owner read" on storage.objects;
  create policy "muzzles owner read" on storage.objects for select
    using (bucket_id = 'muzzles' and auth.uid()::text = (storage.foldername(name))[1]);
exception when insufficient_privilege then
  raise notice 'insufficient privilege for storage.objects policies — create "muzzles owner read" (SELECT, bucket muzzles, auth.uid()::text = (storage.foldername(name))[1]) in Dashboard > Storage > Policies';
end $$;
```

- [ ] **Step 2: Extend `setup_supabase.py` to verify the events table after apply**

`apply_schema` already executes the whole `schema.sql`, so the new DDL is applied automatically. Add a verification readout. In `server/scripts/setup_supabase.py`, replace:

```python
        dim = await conn.fetchval(
            "select atttypmod from pg_attribute "
            "where attrelid='embeddings'::regclass and attname='vec'"
        )
        print(f"[1/3] schema applied (embeddings.vec dim = {dim})")
```

with:

```python
        dim = await conn.fetchval(
            "select atttypmod from pg_attribute "
            "where attrelid='embeddings'::regclass and attname='vec'"
        )
        events_ok = await conn.fetchval("select to_regclass('public.events') is not null")
        storage_policy_ok = await conn.fetchval(
            "select exists (select 1 from pg_policies where schemaname = 'storage' "
            "and tablename = 'objects' and policyname = 'muzzles owner read')"
        )
        print(f"[1/3] schema applied (embeddings.vec dim = {dim}, "
              f"events table = {'ok' if events_ok else 'MISSING'}, "
              f"muzzles read policy = {'ok' if storage_policy_ok else 'MISSING - add in Dashboard > Storage > Policies'})")
```

- [ ] **Step 3: Run server tests (no behavior change expected)**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision/server && .venv/bin/pytest tests/ -m "not slow" -q
```
Expected: `29 passed, 1 skipped, 2 deselected` (unchanged from baseline).

- [ ] **Step 4: USER-RUN — apply the schema to Supabase**

The agent must NOT run this (it reads `server/.env`). Ask the user to run, from `server/`:

```bash
.venv/bin/python scripts/setup_supabase.py
```
Expected output: `[1/3] schema applied (embeddings.vec dim = 2156, events table = ok, muzzles read policy = ok)` plus the existing bucket/test-user lines. If the readout says the policy is MISSING, the user creates the `muzzles owner read` SELECT policy in Dashboard ▸ Storage ▸ Policies with definition `bucket_id = 'muzzles' and auth.uid()::text = (storage.foldername(name))[1]`. Tasks 2–3 can proceed before this runs; Task 4's integration run and Task 16's deploy verification require it done.

- [ ] **Step 5: Commit**

```bash
git add server/sql/schema.sql server/scripts/setup_supabase.py
git commit -m "feat(server): events table + storage owner-read policy in schema"
```

---

### Task 2: Embedder writes events on enroll/identify (TDD)

**Files:**
- Modify: `server/app/db.py`
- Modify: `server/app/main.py`
- Modify: `server/tests/conftest.py`
- Test: `server/tests/test_api.py`

- [ ] **Step 1: RED — add failing tests to `server/tests/test_api.py`**

Append at the end of the file (uses the existing `client`/`jpeg_bytes` fixtures, `main_mod`, `Candidate`, `ANIMAL`, `TEST_UID` already imported at the top of the file; add `import pytest` to the imports at the top, next to `import numpy as np`):

```python
def test_enroll_writes_event(client, jpeg_bytes, monkeypatch):
    recorded = []

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        return path

    async def fake_insert(animal_id, owner, vecs, image_paths):
        return len(image_paths)

    async def fake_insert_event(owner, kind, animal_id, result, score):
        recorded.append((owner, kind, animal_id, result, score))

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    monkeypatch.setattr(main_mod.db, "insert_embeddings", fake_insert)
    monkeypatch.setattr(main_mod.db, "insert_event", fake_insert_event)

    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 200
    assert recorded == [(TEST_UID, "enroll", ANIMAL, "enrolled", None)]


def test_identify_identified_writes_event(client, jpeg_bytes, monkeypatch):
    recorded = []

    async def fake_match(vec, owner):
        return [Candidate(ANIMAL, "Bessie", 0.91), Candidate("other", None, 0.60)]

    async def fake_insert_event(owner, kind, animal_id, result, score):
        recorded.append((owner, kind, animal_id, result, score))

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    monkeypatch.setattr(main_mod.db, "insert_event", fake_insert_event)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert recorded == [(TEST_UID, "identify", ANIMAL, "identified", pytest.approx(0.91))]


def test_identify_unknown_writes_event(client, jpeg_bytes, monkeypatch):
    recorded = []

    async def fake_match(vec, owner):
        return []  # empty gallery -> unknown

    async def fake_insert_event(owner, kind, animal_id, result, score):
        recorded.append((owner, kind, animal_id, result, score))

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    monkeypatch.setattr(main_mod.db, "insert_event", fake_insert_event)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"
    assert recorded == [(TEST_UID, "identify", None, "unknown", pytest.approx(0.0))]


def test_event_insert_failure_does_not_fail_response(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return []

    async def exploding_insert_event(owner, kind, animal_id, result, score):
        raise RuntimeError("db down")

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    monkeypatch.setattr(main_mod.db, "insert_event", exploding_insert_event)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"
```

Run:
```bash
cd /Users/korkutkaanbalta/Documents/carni_vision/server && .venv/bin/pytest tests/test_api.py -q
```
Expected: the 4 new tests FAIL with `AttributeError: ... has no attribute 'insert_event'`; the 8 existing tests still pass.

- [ ] **Step 2: GREEN — add `insert_event` to `server/app/db.py`**

Append at the end of `server/app/db.py`:

```python
INSERT_EVENT_SQL = """
insert into events (owner, kind, animal_id, result, score)
values ($1::uuid, $2, $3::uuid, $4, $5)
"""


async def insert_event(
    owner: str, kind: str, animal_id: str | None, result: str, score: float | None
) -> None:
    pool = await get_pool()
    await pool.execute(INSERT_EVENT_SQL, owner, kind, animal_id, result, score)
```

- [ ] **Step 3: GREEN — wire best-effort event writes into `server/app/main.py`**

Add this helper right after the `_embed` function (before the `/health` route):

```python
async def _record_event(
    owner: str, kind: str, animal_id: str | None, result: str, score: float | None
) -> None:
    """Best-effort event-feed write: an insert failure must never fail the
    API response — log and continue."""
    try:
        await db.insert_event(owner, kind, animal_id, result, score)
    except Exception:
        logger.exception("event insert failed (kind=%s, result=%s)", kind, result)
```

In the `identify` endpoint, insert the event between `d = decide(...)` and the `return`:

```python
    d = decide(candidates, s.sim_threshold, s.sim_margin)
    await _record_event(
        uid,
        "identify",
        d.animal_id,
        "identified" if d.decision == "identified" else "unknown",
        d.score,
    )
    return IdentifyResponse(
```

In the `enroll` endpoint, insert the event between `count = await db.insert_embeddings(...)` and the `return`:

```python
    count = await db.insert_embeddings(animal_id, uid, vecs, paths)
    await _record_event(uid, "enroll", animal_id, "enrolled", None)
    return EnrollResponse(enrolled_count=count, full_images_stored=len(raw_full))
```

- [ ] **Step 4: Keep existing unit tests hermetic — default-stub `insert_event` in `server/tests/conftest.py`**

Existing identify/enroll tests don't stub the new call; without this, `_record_event` would attempt a real pool connection (caught, but noisy/slow). In `conftest.py`, change the imports and the `client` fixture:

```python
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import db
from app.auth import current_uid
from app.main import app, state
```

and:

```python
@pytest.fixture
def client(monkeypatch):
    state["embedder"] = FakeEmbedder()
    app.dependency_overrides[current_uid] = lambda: TEST_UID

    async def _noop_insert_event(owner, kind, animal_id, result, score):
        return None

    # Unit tests never touch Postgres; event-asserting tests re-stub this.
    monkeypatch.setattr(db, "insert_event", _noop_insert_event)
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c
    app.dependency_overrides.clear()
    state["embedder"] = None
```

- [ ] **Step 5: Run the suite**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision/server && .venv/bin/pytest tests/ -m "not slow" -q
```
Expected: `33 passed, 1 skipped, 2 deselected` (29 baseline + 4 new).

- [ ] **Step 6: Commit**

```bash
git add server/app/db.py server/app/main.py server/tests/conftest.py server/tests/test_api.py
git commit -m "feat(server): write enroll/identify events (best-effort, never fails the response)"
```

---

### Task 3: Silence NNPACK warnings at startup

**Files:**
- Modify: `server/app/miewid.py`

- [ ] **Step 1: Disable NNPACK right after the torch import**

`app/miewid.py` is the only module that imports torch, and it is loaded once per container from the FastAPI lifespan (`app/main.py` line 26, `from .miewid import MiewIDEmbedder`) — so this runs before any inference. In `server/app/miewid.py`, replace:

```python
import numpy as np
import torch
import torchvision.transforms as T
from transformers import AutoModel
```

with:

```python
import numpy as np
import torch
import torchvision.transforms as T
from transformers import AutoModel

# Cloud Run vCPUs lack NNPACK support; PyTorch falls back automatically but
# logs "Could not initialize NNPACK" per worker. Disable it explicitly.
torch.backends.nnpack.set_flags(False)
```

- [ ] **Step 2: Verify the flag call is valid and nothing broke**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision/server && .venv/bin/python -c "import app.miewid; print('nnpack disabled ok')" && .venv/bin/pytest tests/ -m "not slow" -q
```
Expected: `nnpack disabled ok` then `33 passed, 1 skipped, 2 deselected`.

- [ ] **Step 3: Commit**

```bash
git add server/app/miewid.py
git commit -m "fix(server): disable NNPACK to silence benign startup warnings"
```

---

### Task 4: RLS cross-owner isolation integration test

**Files:**
- Create: `server/tests/test_rls.py` (pytest test files need no registration)

- [ ] **Step 1: Write the env-gated integration test**

Same gating pattern as `tests/test_match.py` (`pytestmark = pytest.mark.integration`, module-level skip). Create `server/tests/test_rls.py`:

```python
"""Integration: RLS isolation across owners (PostgREST + Storage).

Proves the design's decision #4: user B's JWT cannot read user A's animals,
events, or stored photos, while A can read their own.

Run from server/:
  INTEGRATION=1 \
  SUPABASE_URL=https://<ref>.supabase.co \
  SUPABASE_ANON_KEY=sb_publishable_... \
  SUPABASE_SERVICE_ROLE_KEY=sb_secret_... \
  DATABASE_URL=postgresql://...pooler.supabase.com:6543/postgres \
  .venv/bin/pytest tests/test_rls.py -v
"""
import io
import os

import asyncpg
import httpx
import pytest

pytestmark = pytest.mark.integration

if os.environ.get("INTEGRATION") != "1":
    pytest.skip("set INTEGRATION=1 to run", allow_module_level=True)

USER_A = ("pilot-test@carnivision.local", "pilot-test-only-3kX9")
USER_B = ("rls-test-b@carnivision.local", "rls-test-only-7pQ2")


def _url() -> str:
    return os.environ["SUPABASE_URL"]


def _service_headers() -> dict:
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    return {"Authorization": f"Bearer {key}", "apikey": key}


def _ensure_user(email: str, password: str) -> None:
    # 200/201 = created; 422 = already exists — both fine, sign-in verifies.
    httpx.post(
        f"{_url()}/auth/v1/admin/users",
        headers=_service_headers(),
        json={"email": email, "password": password, "email_confirm": True},
    )


def _sign_in(email: str, password: str) -> tuple[str, str]:
    anon = os.environ["SUPABASE_ANON_KEY"]
    r = httpx.post(
        f"{_url()}/auth/v1/token?grant_type=password",
        headers={"apikey": anon},
        json={"email": email, "password": password},
    )
    r.raise_for_status()
    body = r.json()
    return body["access_token"], body["user"]["id"]


def _user_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "apikey": os.environ["SUPABASE_ANON_KEY"]}


def _jpeg_bytes() -> bytes:
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (32, 32), (90, 90, 90)).save(buf, format="JPEG")
    return buf.getvalue()


async def test_rls_blocks_cross_owner_reads():
    from app import storage

    _ensure_user(*USER_A)
    _ensure_user(*USER_B)
    token_a, uid_a = _sign_in(*USER_A)
    token_b, uid_b = _sign_in(*USER_B)
    assert uid_a != uid_b

    conn = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    object_path = None
    try:
        animal_id = await conn.fetchval(
            "insert into animals (owner, name) values ($1::uuid, $2) returning id::text",
            uid_a, "rls-test-animal",
        )
        await conn.execute(
            "insert into events (owner, kind, animal_id, result, score) "
            "values ($1::uuid, 'identify', $2::uuid, 'identified', 0.91)",
            uid_a, animal_id,
        )
        object_path = storage.object_path(uid_a, animal_id, "muzzle")
        await storage.upload_jpeg(object_path, _jpeg_bytes())

        # --- B sees none of A's rows via PostgREST ---
        r = httpx.get(f"{_url()}/rest/v1/animals?select=id", headers=_user_headers(token_b))
        r.raise_for_status()
        assert animal_id not in [row["id"] for row in r.json()]

        r = httpx.get(f"{_url()}/rest/v1/events?select=id,owner", headers=_user_headers(token_b))
        r.raise_for_status()
        assert all(row["owner"] != uid_a for row in r.json())

        # --- B cannot read A's photo ---
        r = httpx.get(
            f"{_url()}/storage/v1/object/authenticated/muzzles/{object_path}",
            headers=_user_headers(token_b),
        )
        assert r.status_code != 200, f"cross-owner storage read allowed: {r.status_code}"

        # --- A CAN read their own photo (proves the read policy exists) ---
        r = httpx.get(
            f"{_url()}/storage/v1/object/authenticated/muzzles/{object_path}",
            headers=_user_headers(token_a),
        )
        assert r.status_code == 200, (
            f"owner storage read denied ({r.status_code}) — is the 'muzzles owner read' "
            "policy applied? (schema.sql DO block / Dashboard > Storage > Policies)"
        )

        # --- A sees their own rows via PostgREST ---
        r = httpx.get(f"{_url()}/rest/v1/animals?select=id", headers=_user_headers(token_a))
        r.raise_for_status()
        assert animal_id in [row["id"] for row in r.json()]

        r = httpx.get(
            f"{_url()}/rest/v1/events?select=animal_id,result,score",
            headers=_user_headers(token_a),
        )
        r.raise_for_status()
        assert any(row["animal_id"] == animal_id for row in r.json())
    finally:
        await conn.execute("delete from events where owner = $1::uuid", uid_a)
        await conn.execute(
            "delete from animals where owner = $1::uuid and name = 'rls-test-animal'", uid_a
        )
        await conn.close()
        if object_path:
            httpx.request(
                "DELETE",
                f"{_url()}/storage/v1/object/muzzles/{object_path}",
                headers=_service_headers(),
            )
```

- [ ] **Step 2: Verify it skips cleanly in the default suite**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision/server && .venv/bin/pytest tests/ -m "not slow" -q
```
Expected: `33 passed, 2 skipped, 2 deselected` (the new module adds one skip).

- [ ] **Step 3: USER-RUN — execute the integration test against the real project**

Requires Task 1 Step 4 done. The user runs it with their credentials (the agent must not read `.env`; `SUPABASE_ANON_KEY` is the same publishable key as in the iOS `Info.plist`):

```bash
cd server && INTEGRATION=1 SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=... DATABASE_URL=... .venv/bin/pytest tests/test_rls.py -v
```
Expected: `1 passed`. If the owner-read assertion fails, the storage policy from Task 1 wasn't applied — create it in the dashboard and re-run.

- [ ] **Step 4: Commit**

```bash
git add server/tests/test_rls.py
git commit -m "test(server): RLS cross-owner isolation integration test"
```

---

### Task 5: `AnimalRepository.list()` + `AnimalRecord` (TDD)

**Files:**
- Modify: `CarniVision/Services/AnimalRepository.swift`
- Test: `CarniVisionTests/AnimalRecordDecodingTests.swift` (new; auto-registers — filesystem-synchronized target, NO pbxproj work)

- [ ] **Step 1: RED — write decoding tests**

Create `CarniVisionTests/AnimalRecordDecodingTests.swift`:

```swift
import XCTest
@testable import CarniVision

final class AnimalRecordDecodingTests: XCTestCase {
    func testDecodesPostgrestRowWithEmbeddingCount() throws {
        let json = """
        [{
          "id": "9b2e7a44-1111-2222-3333-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "name": "Deneme 1",
          "tag": "TR-0412",
          "breed": "Holstein",
          "sex": "female",
          "birth_date": "2024-03-01",
          "status": null,
          "created_at": "2026-06-11T14:03:21.123456+00:00",
          "embeddings": [{"count": 5}]
        }]
        """.data(using: .utf8)!

        let records = try JSONDecoder().decode([AnimalRecord].self, from: json)
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.id.uuidString.lowercased(), "9b2e7a44-1111-2222-3333-444455556666")
        XCTAssertEqual(record.name, "Deneme 1")
        XCTAssertEqual(record.tag, "TR-0412")
        XCTAssertEqual(record.breed, "Holstein")
        XCTAssertEqual(record.sex, "female")
        XCTAssertEqual(record.embeddingCount, 5)
        XCTAssertTrue(record.muzzleRegistered)

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let birth = try XCTUnwrap(record.birthDate)
        let parts = calendar.dateComponents([.year, .month, .day], from: birth)
        XCTAssertEqual(parts.year, 2024)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 1)
        let created = calendar.dateComponents([.year, .month, .day, .hour], from: record.createdAt)
        XCTAssertEqual(created.year, 2026)
        XCTAssertEqual(created.hour, 14)
    }

    func testDecodesNullsZeroCountAndWholeSecondTimestamp() throws {
        let json = """
        [{
          "id": "9b2e7a44-aaaa-bbbb-cccc-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "name": null,
          "tag": null,
          "breed": null,
          "sex": null,
          "birth_date": null,
          "status": null,
          "created_at": "2026-06-11T14:03:21+00:00",
          "embeddings": [{"count": 0}]
        }]
        """.data(using: .utf8)!

        let record = try XCTUnwrap(JSONDecoder().decode([AnimalRecord].self, from: json).first)
        XCTAssertNil(record.name)
        XCTAssertNil(record.birthDate)
        XCTAssertEqual(record.embeddingCount, 0)
        XCTAssertFalse(record.muzzleRegistered)
    }
}
```

Run:
```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: build FAILS (`cannot find 'AnimalRecord' in scope`). That's the red state.

- [ ] **Step 2: GREEN — add `AnimalRecord`, `PostgrestDate`, and `list()` to `CarniVision/Services/AnimalRepository.swift`**

Insert the following ABOVE `struct AnimalRepository {` (after the `CreatedAnimal` struct):

```swift
/// Parses PostgREST date strings deterministically (no reliance on the
/// supabase-swift internal decoder, so fixtures decode with plain JSONDecoder).
enum PostgrestDate {
    /// `date` columns: YYYY-MM-DD.
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `timestamptz` columns: ISO-8601, with or without fractional seconds.
    /// PostgREST emits microsecond precision, which ISO8601DateFormatter can
    /// reject — when both formatters fail, trim the fraction and retry
    /// (sub-second precision is irrelevant for display).
    static func timestamp(_ raw: String) -> Date? {
        if let date = fractional.date(from: raw) ?? whole.date(from: raw) {
            return date
        }
        guard let dotIndex = raw.firstIndex(of: ".") else { return nil }
        let tail = raw[raw.index(after: dotIndex)...]
        guard let tzIndex = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else {
            return nil
        }
        return whole.date(from: String(raw[..<dotIndex]) + String(tail[tzIndex...]))
    }
}

/// One row of `animals` with its embedding count, as returned by PostgREST
/// (`select=*,embeddings(count)`). Schema columns are nullable free text.
struct AnimalRecord: Identifiable, Decodable {
    let id: UUID
    let name: String?
    let tag: String?
    let breed: String?
    let sex: String?           // "female" | "male" (free text in the schema)
    let birthDate: Date?
    let createdAt: Date
    let embeddingCount: Int

    /// Derived, never a locally flipped flag: registered == embeddings exist.
    var muzzleRegistered: Bool { embeddingCount > 0 }

    init(
        id: UUID, name: String?, tag: String?, breed: String?, sex: String?,
        birthDate: Date?, createdAt: Date, embeddingCount: Int
    ) {
        self.id = id
        self.name = name
        self.tag = tag
        self.breed = breed
        self.sex = sex
        self.birthDate = birthDate
        self.createdAt = createdAt
        self.embeddingCount = embeddingCount
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tag, breed, sex, embeddings
        case birthDate = "birth_date"
        case createdAt = "created_at"
    }

    private struct EmbeddingCount: Decodable { let count: Int }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        breed = try c.decodeIfPresent(String.self, forKey: .breed)
        sex = try c.decodeIfPresent(String.self, forKey: .sex)
        birthDate = try c.decodeIfPresent(String.self, forKey: .birthDate)
            .flatMap { PostgrestDate.dateOnly.date(from: $0) }
        let createdRaw = try c.decode(String.self, forKey: .createdAt)
        guard let created = PostgrestDate.timestamp(createdRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt, in: c,
                debugDescription: "unparseable timestamptz: \(createdRaw)"
            )
        }
        createdAt = created
        embeddingCount = (try c.decodeIfPresent([EmbeddingCount].self, forKey: .embeddings))?
            .first?.count ?? 0
    }
}
```

Then add `list()` inside `struct AnimalRepository`, after the `create(...)` method:

```swift
    /// All of the signed-in owner's animals (RLS-scoped), newest first, with
    /// embedding counts. PostgREST: GET /rest/v1/animals?select=*,embeddings(count)
    /// &order=created_at.desc — decoded with plain JSONDecoder because
    /// AnimalRecord parses its own dates.
    func list() async throws -> [AnimalRecord] {
        let response = try await client
            .from("animals")
            .select("*, embeddings(count)")
            .order("created_at", ascending: false)
            .execute()
        return try JSONDecoder().decode([AnimalRecord].self, from: response.data)
    }
```

- [ ] **Step 3: Run the tests**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **` — both new tests pass, all 12 existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add CarniVision/Services/AnimalRepository.swift CarniVisionTests/AnimalRecordDecodingTests.swift
git commit -m "feat(ios): AnimalRepository.list with embedding counts"
```

---

### Task 6: `EventRepository` (new app-target file + pbxproj registration, TDD)

**Files:**
- Create: `CarniVision/Services/EventRepository.swift`
- Modify: `CarniVision.xcodeproj/project.pbxproj` (4-point registration)
- Test: `CarniVisionTests/EventRecordDecodingTests.swift` (new; auto-registers)

- [ ] **Step 1: Create `CarniVision/Services/EventRepository.swift`**

```swift
import Foundation
import Supabase

/// One row of the server-written `events` feed (enroll/identify actions).
struct EventRecord: Identifiable, Decodable, Equatable {
    let id: UUID
    let kind: String       // "enroll" | "identify"
    let animalID: UUID?    // nil for unknown identify
    let result: String     // "enrolled" | "identified" | "unknown"
    let score: Double?     // top-1 similarity for identify, nil for enroll
    let createdAt: Date

    init(id: UUID, kind: String, animalID: UUID?, result: String, score: Double?, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.animalID = animalID
        self.result = result
        self.score = score
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, result, score
        case animalID = "animal_id"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        animalID = try c.decodeIfPresent(UUID.self, forKey: .animalID)
        result = try c.decode(String.self, forKey: .result)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        let createdRaw = try c.decode(String.self, forKey: .createdAt)
        guard let created = PostgrestDate.timestamp(createdRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt, in: c,
                debugDescription: "unparseable timestamptz: \(createdRaw)"
            )
        }
        createdAt = created
    }
}

/// Reads the signed-in owner's recent events via PostgREST (RLS-scoped).
/// GET /rest/v1/events?select=*&order=created_at.desc&limit=N
struct EventRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
    }

    /// Most recent events, newest first.
    func recent(limit: Int) async throws -> [EventRecord] {
        let response = try await client
            .from("events")
            .select()
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
        return try JSONDecoder().decode([EventRecord].self, from: response.data)
    }
}
```

- [ ] **Step 2: Register the file in `project.pbxproj` (4 points — old PBXGroup style, MANDATORY)**

IDs follow the existing `A1…`/`B1…` sequential hex pattern; the highest used are `A1000000000000000000003C` and `B1000000000000000000002F`, so EventRepository takes `A1…3D`/`B1…30`.

(a) **PBXBuildFile section** — after the line:
```
		A1000000000000000000003C /* AnimalRepository.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000000000000000000002D /* AnimalRepository.swift */; };
```
add:
```
		A1000000000000000000003D /* EventRepository.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000000000000000000030 /* EventRepository.swift */; };
```

(b) **PBXFileReference section** — after the line:
```
		B1000000000000000000002D /* AnimalRepository.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AnimalRepository.swift; sourceTree = "<group>"; };
```
add:
```
		B10000000000000000000030 /* EventRepository.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = EventRepository.swift; sourceTree = "<group>"; };
```

(c) **Services group children** (`C1000000000000000000000C /* Services */`) — after the line:
```
				B1000000000000000000002D /* AnimalRepository.swift */,
```
add:
```
				B10000000000000000000030 /* EventRepository.swift */,
```

(d) **App target Sources build phase** — after the line:
```
				A1000000000000000000003C /* AnimalRepository.swift in Sources */,
```
add:
```
				A1000000000000000000003D /* EventRepository.swift in Sources */,
```

- [ ] **Step 3: Write decoding tests — `CarniVisionTests/EventRecordDecodingTests.swift`**

```swift
import XCTest
@testable import CarniVision

final class EventRecordDecodingTests: XCTestCase {
    func testDecodesIdentifyEvent() throws {
        let json = """
        [{
          "id": "0a1b2c3d-1111-2222-3333-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "kind": "identify",
          "animal_id": "9b2e7a44-1111-2222-3333-444455556666",
          "result": "identified",
          "score": 0.64,
          "created_at": "2026-06-12T09:15:00.123456+00:00"
        }]
        """.data(using: .utf8)!

        let record = try XCTUnwrap(JSONDecoder().decode([EventRecord].self, from: json).first)
        XCTAssertEqual(record.kind, "identify")
        XCTAssertEqual(record.result, "identified")
        XCTAssertEqual(record.animalID?.uuidString.lowercased(), "9b2e7a44-1111-2222-3333-444455556666")
        let score = try XCTUnwrap(record.score)
        XCTAssertEqual(score, 0.64, accuracy: 0.0001)
    }

    func testDecodesUnknownIdentifyAndEnrollEvents() throws {
        let json = """
        [{
          "id": "0a1b2c3d-aaaa-2222-3333-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "kind": "identify",
          "animal_id": null,
          "result": "unknown",
          "score": 0.31,
          "created_at": "2026-06-12T09:16:00+00:00"
        },
        {
          "id": "0a1b2c3d-bbbb-2222-3333-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "kind": "enroll",
          "animal_id": "9b2e7a44-1111-2222-3333-444455556666",
          "result": "enrolled",
          "score": null,
          "created_at": "2026-06-12T09:17:00+00:00"
        }]
        """.data(using: .utf8)!

        let records = try JSONDecoder().decode([EventRecord].self, from: json)
        XCTAssertEqual(records.count, 2)
        XCTAssertNil(records[0].animalID)
        XCTAssertEqual(records[0].result, "unknown")
        XCTAssertEqual(records[1].kind, "enroll")
        XCTAssertNil(records[1].score)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`. If the build fails with `cannot find 'EventRecord' in scope` from the test target, the pbxproj registration (Step 2) is wrong — re-check all four points.

- [ ] **Step 5: Commit**

```bash
git add CarniVision/Services/EventRepository.swift CarniVision.xcodeproj/project.pbxproj CarniVisionTests/EventRecordDecodingTests.swift
git commit -m "feat(ios): EventRepository for the recent-actions feed"
```

---

### Task 7: `AnimalPhotoLoader` (new app-target file + pbxproj registration)

**Files:**
- Create: `CarniVision/Services/AnimalPhotoLoader.swift`
- Modify: `CarniVision.xcodeproj/project.pbxproj` (4-point registration)

- [ ] **Step 1: Create `CarniVision/Services/AnimalPhotoLoader.swift`**

Casing gotcha encoded below: the embedder writes object paths as `{jwt-sub}/{form animal_id}/{kind}/{uuid}.jpg`. The JWT `sub` is always lowercase, but the iOS client sends `UUID.uuidString` (uppercase) as `animal_id`, so the animal path segment is uppercase for app-enrolled animals — the loader probes both casings.

```swift
import Foundation
import Supabase
import UIKit

/// Loads an animal's display photo from the private `muzzles` bucket.
/// Prefers the full-body shot (`{owner}/{animal}/full/`), falls back to a
/// muzzle crop (`.../muzzle/`), and returns nil on any failure (callers show
/// the initials avatar). Caches decoded images in memory (NSCache) and raw
/// JPEG bytes on disk (Caches/AnimalPhotos, keyed by object path).
final class AnimalPhotoLoader {
    static let shared = AnimalPhotoLoader()

    private let client: SupabaseClient
    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskDirectory: URL

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("AnimalPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Returns the animal's photo, or nil so the caller falls back to the
    /// initials avatar. Never throws.
    func photo(ownerID: String, animalID: String) async -> UIImage? {
        let cacheKey = "\(ownerID.lowercased())/\(animalID.lowercased())" as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        guard let objectPath = await firstObjectPath(ownerID: ownerID, animalID: animalID) else {
            return nil
        }

        if let image = diskImage(for: objectPath) {
            memoryCache.setObject(image, forKey: cacheKey)
            return image
        }

        guard let data = try? await client.storage.from("muzzles").download(path: objectPath),
              let image = UIImage(data: data) else {
            return nil
        }
        memoryCache.setObject(image, forKey: cacheKey)
        try? data.write(to: diskURL(for: objectPath), options: .atomic)
        return image
    }

    /// Object paths were written by the embedder as `{jwt-sub}/{form animal_id}/…`:
    /// the owner segment is always lowercase (JWT sub) but the animal segment
    /// keeps the case the client sent (UUID.uuidString is uppercase), so probe
    /// both. `full/` of any casing beats `muzzle/`.
    private func firstObjectPath(ownerID: String, animalID: String) async -> String? {
        let owner = ownerID.lowercased()
        var animalSegments = [animalID]
        if animalID.lowercased() != animalID {
            animalSegments.append(animalID.lowercased())
        }
        for kind in ["full", "muzzle"] {
            for animal in animalSegments {
                let prefix = "\(owner)/\(animal)/\(kind)"
                guard let objects = try? await client.storage.from("muzzles").list(path: prefix),
                      let first = objects.first else {
                    continue
                }
                return "\(prefix)/\(first.name)"
            }
        }
        return nil
    }

    private func diskURL(for objectPath: String) -> URL {
        // "/" is not valid in a file name; flatten the object path.
        let name = objectPath.replacingOccurrences(of: "/", with: "_")
        return diskDirectory.appendingPathComponent(name)
    }

    private func diskImage(for objectPath: String) -> UIImage? {
        guard let data = try? Data(contentsOf: diskURL(for: objectPath)) else { return nil }
        return UIImage(data: data)
    }
}
```

- [ ] **Step 2: Register the file in `project.pbxproj` (4 points)**

AnimalPhotoLoader takes the next free IDs: `A1000000000000000000003E` / `B10000000000000000000031`.

(a) **PBXBuildFile section** — after the line (added in Task 6):
```
		A1000000000000000000003D /* EventRepository.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000000000000000000030 /* EventRepository.swift */; };
```
add:
```
		A1000000000000000000003E /* AnimalPhotoLoader.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000000000000000000031 /* AnimalPhotoLoader.swift */; };
```

(b) **PBXFileReference section** — after the line (added in Task 6):
```
		B10000000000000000000030 /* EventRepository.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = EventRepository.swift; sourceTree = "<group>"; };
```
add:
```
		B10000000000000000000031 /* AnimalPhotoLoader.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AnimalPhotoLoader.swift; sourceTree = "<group>"; };
```

(c) **Services group children** — after the line (added in Task 6):
```
				B10000000000000000000030 /* EventRepository.swift */,
```
add:
```
				B10000000000000000000031 /* AnimalPhotoLoader.swift */,
```

(d) **App target Sources build phase** — after the line (added in Task 6):
```
				A1000000000000000000003D /* EventRepository.swift in Sources */,
```
add:
```
				A1000000000000000000003E /* AnimalPhotoLoader.swift in Sources */,
```

- [ ] **Step 3: Build**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add CarniVision/Services/AnimalPhotoLoader.swift CarniVision.xcodeproj/project.pbxproj
git commit -m "feat(ios): AnimalPhotoLoader with memory and disk cache"
```

---

### Task 8: Rewrite `HerdData.swift` — slim `Animal`, real `ScanEvent`, real `HerdStore` (TDD)

**Files:**
- Modify: `CarniVision/Models/HerdData.swift` (full rewrite)
- Modify: `CarniVision/Models/Localization.swift` (event/common keys, EN+TR)
- Test: `CarniVisionTests/HerdStoreTests.swift` (new; auto-registers)
- Test: `CarniVisionTests/EventFormattingTests.swift` (new; auto-registers)

Note: this task makes the app target temporarily NOT compile (HomeView/AnimalsView/AddAnimalView still reference deleted APIs) if done in isolation — so this task replaces `HerdData.swift` AND is immediately followed by Tasks 9–13 which fix the views. To keep every commit green, this task's test step compiles ONLY after Tasks 9–13? No — instead, this task includes the minimal view stubs? Neither: the correct sequencing is that Tasks 8–13 each leave the tree compiling. To guarantee that, Task 8 rewrites `HerdData.swift` and runs ONLY a syntax check; the full build/test gate for the model change runs at the end of Task 13 and in Task 15. HOWEVER — committing non-compiling code breaks bisect. **Therefore Tasks 8–13 below are written so each compiles:** Task 8's rewrite keeps temporary compatibility shims (clearly marked) that Tasks 10–12 delete.

- [ ] **Step 1: Add event/common localization keys (EN+TR)**

In `CarniVision/Models/Localization.swift`, in the **English** table, after the line `"sex.male": "Male",` add:

```swift
            // Events (recent actions feed)
            "event.enrolled": "%@ — enrolled",
            "event.identified": "%@ — identified (%.2f)",
            "event.identifiedNoScore": "%@ — identified",
            "event.noMatch": "Unknown animal — no match",
            "event.unknownAnimal": "Unknown animal",
            "common.retry": "Retry",
            "common.loadError": "Couldn't load your data.",
```

In the **Turkish** table, after the line `"sex.male": "Erkek",` add:

```swift
            // Events (recent actions feed)
            "event.enrolled": "%@ — kaydedildi",
            "event.identified": "%@ — tanımlandı (%.2f)",
            "event.identifiedNoScore": "%@ — tanımlandı",
            "event.noMatch": "Bilinmeyen hayvan — eşleşme yok",
            "event.unknownAnimal": "Bilinmeyen hayvan",
            "common.retry": "Tekrar dene",
            "common.loadError": "Verileriniz yüklenemedi.",
```

- [ ] **Step 2: RED — write `CarniVisionTests/HerdStoreTests.swift`**

```swift
import XCTest
@testable import CarniVision

private final class MockAnimalListing: AnimalListing {
    var records: [AnimalRecord] = []
    var error: Error?

    func list() async throws -> [AnimalRecord] {
        if let error { throw error }
        return records
    }
}

private final class MockEventListing: EventListing {
    var records: [EventRecord] = []
    var error: Error?

    func recent(limit: Int) async throws -> [EventRecord] {
        if let error { throw error }
        return records
    }
}

@MainActor
final class HerdStoreTests: XCTestCase {
    private let animalID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeRecord(embeddingCount: Int) -> AnimalRecord {
        AnimalRecord(
            id: animalID, name: "Deneme 1", tag: "TR-0001", breed: "Holstein",
            sex: "female", birthDate: nil, createdAt: Date(), embeddingCount: embeddingCount
        )
    }

    func testLoadSuccessPopulatesAnimalsAndResolvesEventNames() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 5)]
        let events = MockEventListing()
        events.records = [
            EventRecord(id: UUID(), kind: "identify", animalID: animalID,
                        result: "identified", score: 0.64, createdAt: Date())
        ]
        let store = HerdStore(animalSource: animals, eventSource: events)

        await store.load()

        XCTAssertNil(store.loadError)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.animals.count, 1)
        XCTAssertEqual(store.animals[0].name, "Deneme 1")
        XCTAssertTrue(store.animals[0].muzzleRegistered)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].animalName, "Deneme 1")
        XCTAssertEqual(store.registeredCount, 1)
        XCTAssertEqual(store.scansThisWeek, 1)
    }

    func testLoadFailureSetsLoadErrorAndKeepsListsEmpty() async {
        let animals = MockAnimalListing()
        animals.error = URLError(.notConnectedToInternet)
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())

        await store.load()

        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(store.animals.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    func testReloadAfterEnrollFlipsDerivedMuzzleFlag() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 0)]
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())

        await store.load()
        XCTAssertFalse(store.animals[0].muzzleRegistered)

        animals.records = [makeRecord(embeddingCount: 5)]  // enrollment happened server-side
        await store.load()
        XCTAssertTrue(store.animals[0].muzzleRegistered)
        XCTAssertNil(store.loadError)
    }

    func testAddAnimalInsertsOptimisticallyAtTop() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 5)]
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())
        await store.load()

        let newID = UUID()
        store.addAnimal(id: newID, name: "Yeni", tag: "TR-0002", breed: "Angus",
                        sex: .male, birthDate: Date())

        XCTAssertEqual(store.animals.count, 2)
        XCTAssertEqual(store.animals[0].id, newID)
        XCTAssertEqual(store.animals[0].name, "Yeni")
        XCTAssertFalse(store.animals[0].muzzleRegistered)
    }
}
```

- [ ] **Step 3: RED — write `CarniVisionTests/EventFormattingTests.swift`**

```swift
import XCTest
@testable import CarniVision

@MainActor
final class EventFormattingTests: XCTestCase {
    private var previousLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        previousLanguage = LanguageManager.shared.language
    }

    override func tearDown() {
        LanguageManager.shared.language = previousLanguage
        super.tearDown()
    }

    private func makeEvent(result: String, score: Double?, animalName: String?) -> ScanEvent {
        let id = UUID()
        let record = EventRecord(
            id: UUID(),
            kind: result == "enrolled" ? "enroll" : "identify",
            animalID: animalName == nil ? nil : id,
            result: result,
            score: score,
            createdAt: Date()
        )
        let animals = animalName.map { name in
            [Animal(id: id, name: name, tag: "TR-1", breed: "Holstein", sex: .female,
                    birthDate: nil, createdAt: Date(), muzzleRegistered: true,
                    avatarColor: .purple)]
        } ?? []
        return ScanEvent(record: record, animals: animals)
    }

    func testIdentifiedWithScoreEnglish() {
        LanguageManager.shared.language = .english
        let event = makeEvent(result: "identified", score: 0.64, animalName: "Deneme 1")
        XCTAssertEqual(event.title(LanguageManager.shared), "Deneme 1 — identified (0.64)")
    }

    func testIdentifiedWithScoreTurkish() {
        LanguageManager.shared.language = .turkish
        let event = makeEvent(result: "identified", score: 0.64, animalName: "Deneme 1")
        XCTAssertEqual(event.title(LanguageManager.shared), "Deneme 1 — tanımlandı (0.64)")
    }

    func testEnrolledEnglishAndTurkish() {
        LanguageManager.shared.language = .english
        var event = makeEvent(result: "enrolled", score: nil, animalName: "Deneme 1")
        XCTAssertEqual(event.title(LanguageManager.shared), "Deneme 1 — enrolled")

        LanguageManager.shared.language = .turkish
        event = makeEvent(result: "enrolled", score: nil, animalName: "Deneme 1")
        XCTAssertEqual(event.title(LanguageManager.shared), "Deneme 1 — kaydedildi")
    }

    func testUnknownEnglishAndTurkish() {
        LanguageManager.shared.language = .english
        var event = makeEvent(result: "unknown", score: 0.31, animalName: nil)
        XCTAssertEqual(event.title(LanguageManager.shared), "Unknown animal — no match")

        LanguageManager.shared.language = .turkish
        event = makeEvent(result: "unknown", score: 0.31, animalName: nil)
        XCTAssertEqual(event.title(LanguageManager.shared), "Bilinmeyen hayvan — eşleşme yok")
    }
}
```

- [ ] **Step 4: GREEN — replace the entire contents of `CarniVision/Models/HerdData.swift`**

```swift
import SwiftUI

// MARK: - Models

enum AnimalSex: String, CaseIterable, Identifiable {
    case female = "Female"
    case male = "Male"

    var id: String { rawValue }

    var key: String {
        switch self {
        case .female: return "sex.female"
        case .male: return "sex.male"
        }
    }
}

struct Animal: Identifiable {
    let id: UUID
    var name: String
    var tag: String
    var breed: String
    var sex: AnimalSex
    var birthDate: Date?
    /// Enrollment date (the DB row's created_at).
    var createdAt: Date
    /// Derived server-side: true when the animal has at least one embedding.
    var muzzleRegistered: Bool
    var avatarColor: Color

    func ageDescription(_ lang: LanguageManager) -> String {
        guard let birthDate else { return "—" }
        let parts = Calendar.current.dateComponents([.year, .month], from: birthDate, to: Date())
        let years = parts.year ?? 0
        let months = parts.month ?? 0
        let yr = lang.t("unit.yr")
        let mo = lang.t("unit.mo")
        if years == 0 { return "\(months) \(mo)" }
        if months == 0 { return "\(years) \(yr)" }
        return "\(years) \(yr) \(months) \(mo)"
    }
}

extension Animal {
    static let avatarPalette: [Color] = [
        CarniColors.purple,
        Color(red: 70 / 255, green: 152 / 255, blue: 115 / 255),
        Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255),
        Color(red: 222 / 255, green: 138 / 255, blue: 60 / 255),
        Color(red: 204 / 255, green: 96 / 255, blue: 144 / 255),
        Color(red: 52 / 255, green: 144 / 255, blue: 150 / 255),
    ]

    init(record: AnimalRecord) {
        self.init(
            id: record.id,
            name: record.name ?? "",
            tag: record.tag ?? "",
            breed: record.breed ?? "",
            sex: record.sex == "male" ? .male : .female,
            birthDate: record.birthDate,
            createdAt: record.createdAt,
            muzzleRegistered: record.muzzleRegistered,
            // Stable across launches: derived from the UUID, not array position.
            avatarColor: Self.avatarPalette[Int(record.id.uuid.0) % Self.avatarPalette.count]
        )
    }
}

/// One enroll/identify action from the server-side events feed, with the
/// animal's display info resolved against the loaded herd.
struct ScanEvent: Identifiable {
    let id: UUID
    let kind: String      // "enroll" | "identify"
    let result: String    // "enrolled" | "identified" | "unknown"
    let score: Double?
    let date: Date
    let animalID: UUID?
    let animalName: String?
    let avatarColor: Color

    init(record: EventRecord, animals: [Animal]) {
        let animal = record.animalID.flatMap { id in animals.first(where: { $0.id == id }) }
        self.id = record.id
        self.kind = record.kind
        self.result = record.result
        self.score = record.score
        self.date = record.createdAt
        self.animalID = record.animalID
        self.animalName = animal?.name
        self.avatarColor = animal?.avatarColor ?? Color.gray
    }

    /// Row text, e.g. "Deneme 1 — identified (0.64)" / "Unknown animal — no match".
    func title(_ lang: LanguageManager) -> String {
        let name = animalName ?? lang.t("event.unknownAnimal")
        switch result {
        case "enrolled":
            return lang.t("event.enrolled", name)
        case "identified":
            if let score {
                return lang.t("event.identified", name, score)
            }
            return lang.t("event.identifiedNoScore", name)
        default:
            return lang.t("event.noMatch")
        }
    }

    var icon: String {
        switch result {
        case "enrolled": return "plus.viewfinder"
        case "identified": return "checkmark.seal.fill"
        default: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch result {
        case "enrolled": return Color(red: 64 / 255, green: 130 / 255, blue: 224 / 255)
        case "identified": return CarniColors.successGreen
        default: return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255)
        }
    }
}

// MARK: - Repository seams (tests substitute these)

protocol AnimalListing {
    func list() async throws -> [AnimalRecord]
}

protocol EventListing {
    func recent(limit: Int) async throws -> [EventRecord]
}

extension AnimalRepository: AnimalListing {}
extension EventRepository: EventListing {}

// MARK: - Store

/// Owns the herd + event feed for the UI. No seed data: empty until `load()`.
@MainActor
final class HerdStore: ObservableObject {
    @Published var animals: [Animal] = []
    @Published var events: [ScanEvent] = []
    @Published var isLoading = false
    @Published var loadError: String?

    private let animalSource: AnimalListing
    private let eventSource: EventListing

    init(
        animalSource: AnimalListing = AnimalRepository(),
        eventSource: EventListing = EventRepository()
    ) {
        self.animalSource = animalSource
        self.eventSource = eventSource
    }

    var registeredCount: Int {
        animals.filter(\.muzzleRegistered).count
    }

    var scansThisWeek: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return events.filter { $0.date > weekAgo }.count
    }

    /// Fetches animals and events concurrently. Called on sign-in (MainTabView
    /// .task), pull-to-refresh, after a successful enrollment, and after an
    /// identify returns (the server wrote an event either way).
    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            async let animalRecords = animalSource.list()
            async let eventRecords = eventSource.recent(limit: 20)
            let (records, recent) = try await (animalRecords, eventRecords)
            let loaded = records.map(Animal.init(record:))
            animals = loaded
            events = recent.map { ScanEvent(record: $0, animals: loaded) }
        } catch {
            loadError = Self.loadErrorMessage(for: error)
        }
    }

    /// Optimistic insert after AnimalRepository.create succeeds; reconciled by
    /// the next load(). muzzleRegistered stays false until embeddings exist.
    func addAnimal(
        id: UUID, name: String, tag: String, breed: String,
        sex: AnimalSex, birthDate: Date
    ) {
        let record = AnimalRecord(
            id: id, name: name, tag: tag, breed: breed,
            sex: sex.rawValue.lowercased(), birthDate: birthDate,
            createdAt: Date(), embeddingCount: 0
        )
        animals.insert(Animal(record: record), at: 0)
    }

    /// Maps load failures to a localized banner message at the UI boundary
    /// (same pattern as CameraModel.localizedRecognitionMessage).
    static func loadErrorMessage(for error: Error) -> String {
        let lang = LanguageManager.shared
        if error is URLError {
            return lang.t("recognition.error.network")
        }
        return lang.t("common.loadError")
    }
}

// MARK: - TEMPORARY compatibility shims (deleted by Tasks 10-12)
// These keep HomeView/AnimalsView/AddAnimalView compiling until each screen is
// rewritten. DO NOT ship: Task 14's grep step verifies they are gone.

struct WeightEntry: Identifiable {
    let id = UUID()
    let date: Date
    let kg: Double
}

enum AnimalStatus: String {
    case healthy = "Healthy"

    var key: String { "status.healthy" }
    var color: Color { CarniColors.successGreen }
}

extension Animal {
    var status: AnimalStatus { .healthy }
    var lastScanned: Date? { nil }
    var weights: [WeightEntry] { [] }
    var currentWeight: Double? { nil }
    var weightDelta: Double? { nil }
}

extension HerdStore {
    var recentScans: [ScanEvent] { events }
    var herdTrend: [WeightEntry] { [] }
    var averageWeight: Double { 0 }
    var animalsByScanUrgency: [Animal] { animals }

    func addAnimal(
        name: String, tag: String, breed: String, sex: AnimalSex,
        birthDate: Date, initialWeightKg: Double?, muzzleRegistered: Bool
    ) {
        addAnimal(id: UUID(), name: name, tag: tag, breed: breed, sex: sex, birthDate: birthDate)
    }

    func markLastAddedMuzzleRegistered() {
        Task { await load() }
    }
}
```

Note for the worker: `HomeView.swift`'s `ScanRow` references the old `ScanResult` enum API (`scan.result.key/.icon/.color`) and the now-optional `scan.animalName`. To keep this task compiling, ALSO replace the entire body of `private struct ScanRow` in `CarniVision/Views/Main/HomeView.swift` (the full HomeView rewrite happens in Task 10) — replace:

```swift
    var body: some View {
        HStack(spacing: 12) {
            AnimalAvatar(name: scan.animalName, color: scan.avatarColor, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(scan.animalName)
                    .font(CarniFont.semibold(15))
                    .foregroundStyle(CarniColors.purpleDark)
                Text("\(scan.animalTag) · \(lang.timeAgo(scan.date))")
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
                    .lineLimit(1)
            }

            Spacer()

            Label(lang.t(scan.result.key), systemImage: scan.result.icon)
                .font(CarniFont.semibold(11))
                .foregroundStyle(scan.result.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(scan.result.color.opacity(0.12)))
        }
        .carniCard(padding: 12)
    }
```
with:
```swift
    var body: some View {
        HStack(spacing: 12) {
            AnimalAvatar(name: scan.animalName ?? "?", color: scan.avatarColor, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(scan.animalName ?? lang.t("event.unknownAnimal"))
                    .font(CarniFont.semibold(15))
                    .foregroundStyle(CarniColors.purpleDark)
                Text(lang.timeAgo(scan.date))
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
                    .lineLimit(1)
            }

            Spacer()

            Label(scan.title(lang), systemImage: scan.icon)
                .font(CarniFont.semibold(11))
                .foregroundStyle(scan.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(scan.color.opacity(0.12)))
        }
        .carniCard(padding: 12)
    }
```
`AnimalsView.swift`'s `lang.t(animal.status.key)` capsule still compiles via the `AnimalStatus` shim — leave it for Task 11.

- [ ] **Step 5: Run the tests**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **` — 4 HerdStore tests + 4 formatting tests pass, all earlier tests pass.

- [ ] **Step 6: Commit**

```bash
git add CarniVision/Models/HerdData.swift CarniVision/Models/Localization.swift CarniVision/Views/Main/HomeView.swift CarniVisionTests/HerdStoreTests.swift CarniVisionTests/EventFormattingTests.swift
git commit -m "feat(ios): HerdStore loads real animals and events (no seed data)"
```

---

### Task 9: 4-tab bar — remove the Add tab, wire `store.load()` and the Add sheet trigger

**Files:**
- Modify: `CarniVision/Views/Main/MainTabView.swift` (full rewrite)
- Modify: `CarniVision/Views/Main/CarniTabBar.swift` (remove `.addAnimal`)
- Modify: `CarniVision/Views/Main/AnimalsView.swift` (binding only, minimal edit)

- [ ] **Step 1: Replace the entire contents of `CarniVision/Views/Main/MainTabView.swift`**

```swift
import SwiftUI

struct MainTabView: View {
    @State private var selected: AppTab = .home
    @State private var showAddAnimal = false
    @StateObject private var store = HerdStore()

    var body: some View {
        ZStack(alignment: .bottom) {
            CarniColors.appBackground
                .ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(store)

            if selected != .camera {
                CarniTabBar(selected: $selected)
            }
        }
        // MainTabView only exists while signed in (RootView), so this runs on
        // sign-in and on each cold launch with a restored session.
        .task { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .home:
            HomeScreen(onSeeAllAnimals: { selected = .animals })
        case .animals:
            AnimalsScreen(showAddAnimal: $showAddAnimal)
        case .camera:
            CameraScreen(
                onClose: { selected = .home },
                onRequestEnroll: {
                    // Unknown identify -> offer enrollment via the Add form.
                    selected = .animals
                    showAddAnimal = true
                }
            )
        case .settings:
            SettingsScreen()
        }
    }
}
```

- [ ] **Step 2: Update `CarniVision/Views/Main/CarniTabBar.swift`**

(a) Replace the `AppTab` enum:

```swift
enum AppTab: Hashable {
    case home
    case animals
    case camera
    case settings
}
```

(b) In `CarniTabBar.body`, delete the `add` tab item — remove this block (between `CameraTabButton { ... }` and the settings `TabBarItem`):

```swift
            TabBarItem(
                icon: "plus",
                selectedIcon: "plus",
                label: lang.t("tab.add"),
                tab: .addAnimal,
                selected: $selected
            )
```

The bar is now home, animals, [camera button], settings.

- [ ] **Step 3: Minimal edit to `CarniVision/Views/Main/AnimalsView.swift` so it accepts the binding**

(Full rewrite comes in Task 11; this keeps the tree compiling.) In `AnimalsScreen`, after the line `@ObservedObject private var lang = LanguageManager.shared`, add:

```swift
    @Binding var showAddAnimal: Bool
```

and at the end of `AnimalsScreen.body`'s `NavigationStack { ... }` chain (after `.toolbar(.hidden, for: .navigationBar)`), add:

```swift
            .sheet(isPresented: $showAddAnimal) {
                AddAnimalScreen()
            }
```

- [ ] **Step 4: Build**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add CarniVision/Views/Main/MainTabView.swift CarniVision/Views/Main/CarniTabBar.swift CarniVision/Views/Main/AnimalsView.swift
git commit -m "feat(ios): 4-tab bar; Add Animal moves to a + on the Animals screen"
```

---### Task 10: HomeView — real header, 3 stat cards, recent actions feed

**Files:**
- Modify: `CarniVision/Views/Main/HomeView.swift` (full rewrite)
- Modify: `CarniVision/Models/Localization.swift` (home keys)
- Modify: `CarniVision/Models/HerdData.swift` (delete shims this screen used)

- [ ] **Step 1: Add the home localization keys (EN+TR)**

In the **English** table, after `"home.seeAll": "See All",` add:

```swift
            "home.recentActions": "Recent Actions",
            "home.noEvents": "No activity yet — enroll or identify an animal to see it here.",
```

In the **Turkish** table, after `"home.seeAll": "Tümünü Gör",` add:

```swift
            "home.recentActions": "Son İşlemler",
            "home.noEvents": "Henüz işlem yok — burada görmek için bir hayvan kaydedin veya tanımlayın.",
```

- [ ] **Step 2: Replace the entire contents of `CarniVision/Views/Main/HomeView.swift`**

(Keeps the shared `carniCard`, `SectionHeader`, `AnimalAvatar` components; adds shared `AnimalPhotoView` and `LoadErrorBanner`; deletes the bell, weight-trend chart, needs-scanning section, `NeedsScanRow`, the old `ScanRow`, and the `Charts` import. `scanUrgencyColor` is kept ONE more task as a marked shim because the old AnimalsView still calls it; Task 11 deletes it.)

```swift
import SwiftUI
import Supabase

// MARK: - Shared screen components

extension View {
    /// White rounded card with the app's soft shadow.
    func carniCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: CarniColors.purpleDark.opacity(0.07), radius: 12, y: 4)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(CarniFont.bold(18))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(CarniFont.semibold(13))
                        .foregroundStyle(CarniColors.purple)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AnimalAvatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.16))
            Text(name.prefix(1).uppercased())
                .font(CarniFont.bold(size * 0.42))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

// TEMPORARY shim (deleted in Task 11): the old AnimalsView still calls this
// until its rewrite lands. Task 14's grep verifies it is gone.
func scanUrgencyColor(_ lastScanned: Date?) -> Color {
    guard let lastScanned else {
        return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255)
    }
    let days = Date().timeIntervalSince(lastScanned) / 86400
    if days >= 7 { return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255) }
    if days >= 2 { return Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255) }
    return CarniColors.successGreen
}

/// Async animal photo with the initials avatar as fallback. Photo lookup is
/// owner-scoped under RLS; any failure silently degrades to the avatar.
struct AnimalPhotoView: View {
    let animalID: UUID?
    let name: String
    let color: Color
    var size: CGFloat = 48

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                AnimalAvatar(name: name.isEmpty ? "?" : name, color: color, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: animalID) {
            guard let animalID,
                  let ownerID = SupabaseClientProvider.shared.auth.currentSession?.user.id.uuidString
            else { return }
            image = await AnimalPhotoLoader.shared.photo(
                ownerID: ownerID,
                animalID: animalID.uuidString
            )
        }
    }
}

/// Inline failure banner with a Retry button, shown when HerdStore.load() fails.
struct LoadErrorBanner: View {
    let message: String
    let retry: () -> Void
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255))
            Text(message)
                .font(CarniFont.regular(13))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            Button(action: retry) {
                Text(lang.t("common.retry"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purple)
            }
            .buttonStyle(.plain)
        }
        .carniCard(padding: 12)
    }
}

// MARK: - Home

struct HomeScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    var onSeeAllAnimals: () -> Void = {}

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = store.loadError {
                    LoadErrorBanner(message: error) {
                        Task { await store.load() }
                    }
                }
                if store.isLoading && store.animals.isEmpty && store.events.isEmpty {
                    loadingState
                } else {
                    statsGrid
                    recentActionsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, CarniLayout.tabBarClearance)
        }
        .refreshable { await store.load() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return lang.t("greeting.morning")
        case 12..<18: return lang.t("greeting.afternoon")
        default: return lang.t("greeting.evening")
        }
    }

    private var signedInEmail: String {
        SupabaseClientProvider.shared.auth.currentSession?.user.email ?? ""
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(greeting)
                .font(CarniFont.regular(14))
                .foregroundStyle(CarniColors.tabInactive)
            Text(signedInEmail)
                .font(CarniFont.bold(22))
                .foregroundStyle(CarniColors.purpleDark)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(CarniColors.purple)
                .padding(.top, 60)
            Spacer()
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
            StatCard(
                icon: "pawprint.fill",
                tint: CarniColors.purple,
                value: "\(store.animals.count)",
                label: lang.t("home.animals")
            )
            StatCard(
                icon: "checkmark.seal.fill",
                tint: Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255),
                value: "\(store.registeredCount)/\(store.animals.count)",
                label: lang.t("home.muzzleIDs")
            )
            StatCard(
                icon: "camera.viewfinder",
                tint: Color(red: 222 / 255, green: 138 / 255, blue: 60 / 255),
                value: "\(store.scansThisWeek)",
                label: lang.t("home.scansThisWeek")
            )
        }
    }

    private var recentActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: lang.t("home.recentActions"),
                actionTitle: lang.t("home.seeAll"),
                action: onSeeAllAnimals
            )

            if store.events.isEmpty {
                emptyEvents
            } else {
                VStack(spacing: 10) {
                    ForEach(store.events) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }

    private var emptyEvents: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive.opacity(0.5))
            Text(lang.t("home.noEvents"))
                .font(CarniFont.regular(14))
                .foregroundStyle(CarniColors.tabInactive)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .carniCard()
    }
}

private struct StatCard: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.13))
                )
            Text(value)
                .font(CarniFont.bold(21))
                .foregroundStyle(CarniColors.purpleDark)
            Text(label)
                .font(CarniFont.regular(12))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carniCard(padding: 14)
    }
}

private struct EventRow: View {
    let event: ScanEvent
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            AnimalPhotoView(
                animalID: event.animalID,
                name: event.animalName ?? "?",
                color: event.avatarColor,
                size: 44
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title(lang))
                    .font(CarniFont.semibold(14))
                    .foregroundStyle(CarniColors.purpleDark)
                    .lineLimit(1)
                Text(lang.timeAgo(event.date))
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
            }

            Spacer()

            Image(systemName: event.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(event.color)
                .padding(8)
                .background(Circle().fill(event.color.opacity(0.12)))
        }
        .carniCard(padding: 12)
    }
}
```

- [ ] **Step 3: Delete the shims HomeView no longer needs from `CarniVision/Models/HerdData.swift`**

In the `TEMPORARY compatibility shims` section, remove these members from `extension HerdStore` (AnimalsView/AddAnimalView shims stay until Tasks 11–12):

```swift
    var recentScans: [ScanEvent] { events }
    var herdTrend: [WeightEntry] { [] }
    var averageWeight: Double { 0 }
```

(`animalsByScanUrgency`, `WeightEntry`, `AnimalStatus`, the `Animal` shim extension, and the old `addAnimal`/`markLastAddedMuzzleRegistered` shims remain until Tasks 11–12. NOTE: the old AnimalsView, rewritten only in Task 11, still calls the free function `scanUrgencyColor(_:)` that used to live in HomeView.swift — that is why the Step 2 rewrite above keeps it as a marked temporary shim; Task 11 deletes it.)

- [ ] **Step 4: Build and test**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add CarniVision/Views/Main/HomeView.swift CarniVision/Models/Localization.swift CarniVision/Models/HerdData.swift
git commit -m "feat(ios): Home shows real stats and recent actions feed"
```

---

### Task 11: AnimalsView + AnimalDetailView on real data

**Files:**
- Modify: `CarniVision/Views/Main/AnimalsView.swift` (full rewrite)
- Modify: `CarniVision/Models/Localization.swift` (animals/detail keys)
- Modify: `CarniVision/Models/HerdData.swift` (delete more shims)

- [ ] **Step 1: Add localization keys (EN+TR)**

English table, after `"animals.empty": "No animals found",` add:

```swift
            "animals.emptyHerd": "No animals yet — tap + to add your first.",
```

English table, after `"detail.notRegistered": "Not Registered",` add:

```swift
            "detail.enrolled": "Enrolled",
```

Turkish table, after `"animals.empty": "Hayvan bulunamadı",` add:

```swift
            "animals.emptyHerd": "Henüz hayvan yok — ilkini eklemek için + simgesine dokunun.",
```

Turkish table, after `"detail.notRegistered": "Kayıtlı Değil",` add:

```swift
            "detail.enrolled": "Kayıt Tarihi",
```

- [ ] **Step 2: Replace the entire contents of `CarniVision/Views/Main/AnimalsView.swift`**

(Deletes the `Charts` import, weight/last-scan card elements, charts, weigh-in table; adds the + button, photo thumbnails, pull-to-refresh, empty/loading/error states. Search + sex filter unchanged.)

```swift
import SwiftUI

// MARK: - Animals list

struct AnimalsScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    @Binding var showAddAnimal: Bool
    @State private var searchText = ""
    @State private var filter: SexFilter = .all

    enum SexFilter: String, CaseIterable {
        case all
        case female
        case male

        var key: String {
            switch self {
            case .all: return "filter.all"
            case .female: return "filter.females"
            case .male: return "filter.males"
            }
        }
    }

    private var filteredAnimals: [Animal] {
        store.animals.filter { animal in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .female: matchesFilter = animal.sex == .female
            case .male: matchesFilter = animal.sex == .male
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.lowercased()
            return animal.name.lowercased().contains(query)
                || animal.tag.lowercased().contains(query)
                || animal.breed.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let error = store.loadError {
                        LoadErrorBanner(message: error) {
                            Task { await store.load() }
                        }
                    }
                    searchField
                    filterChips

                    if store.isLoading && store.animals.isEmpty {
                        loadingState
                    } else if store.animals.isEmpty {
                        emptyHerdState
                    } else {
                        VStack(spacing: 10) {
                            ForEach(filteredAnimals) { animal in
                                NavigationLink {
                                    AnimalDetailView(animal: animal)
                                } label: {
                                    AnimalCard(animal: animal)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if filteredAnimals.isEmpty {
                            noResultsState
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, CarniLayout.tabBarClearance)
            }
            .refreshable { await store.load() }
            .background(CarniColors.appBackground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAddAnimal) {
                AddAnimalScreen()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lang.t("animals.title"))
                    .font(CarniFont.bold(24))
                    .foregroundStyle(CarniColors.purpleDark)
                Text(lang.t("animals.subtitle", store.animals.count, store.registeredCount))
                    .font(CarniFont.regular(13))
                    .foregroundStyle(CarniColors.tabInactive)
            }
            Spacer()
            Button {
                showAddAnimal = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(CarniColors.purple)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CarniColors.tabInactive)
            TextField(lang.t("animals.search"), text: $searchText)
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CarniColors.tabInactive)
                }
                .buttonStyle(.plain)
            }
        }
        .carniCard(padding: 13)
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(SexFilter.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = option }
                } label: {
                    Text(lang.t(option.key))
                        .font(CarniFont.semibold(13))
                        .foregroundStyle(filter == option ? .white : CarniColors.purple)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(filter == option ? CarniColors.purple : CarniColors.purple.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(CarniColors.purple)
                .padding(.top, 50)
            Spacer()
        }
    }

    private var emptyHerdState: some View {
        VStack(spacing: 10) {
            Image(systemName: "pawprint")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive.opacity(0.5))
            Text(lang.t("animals.emptyHerd"))
                .font(CarniFont.semibold(15))
                .foregroundStyle(CarniColors.tabInactive)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive.opacity(0.5))
            Text(lang.t("animals.empty"))
                .font(CarniFont.semibold(15))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

private struct AnimalCard: View {
    let animal: Animal
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            AnimalPhotoView(
                animalID: animal.id,
                name: animal.name,
                color: animal.avatarColor,
                size: 50
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(animal.name)
                        .font(CarniFont.semibold(16))
                        .foregroundStyle(CarniColors.purpleDark)
                    if animal.muzzleRegistered {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CarniColors.successGreen)
                    }
                }
                Text(animal.tag)
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.purple)
                Text("\(animal.breed) · \(animal.ageDescription(lang))")
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .carniCard(padding: 14)
    }
}

// MARK: - Animal detail

struct AnimalDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    let animal: Animal

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                identityCard
                infoGrid
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, CarniLayout.tabBarClearance)
        }
        .background(CarniColors.appBackground)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CarniColors.purpleDark)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(Color.white)
                            .shadow(color: CarniColors.purpleDark.opacity(0.08), radius: 8, y: 3)
                    )
            }
            .buttonStyle(.plain)
            Spacer()
            Text(lang.t("detail.title"))
                .font(CarniFont.semibold(16))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
    }

    private var identityCard: some View {
        HStack(spacing: 14) {
            AnimalPhotoView(
                animalID: animal.id,
                name: animal.name,
                color: animal.avatarColor,
                size: 72
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(animal.name)
                    .font(CarniFont.bold(22))
                    .foregroundStyle(CarniColors.purpleDark)
                Text(animal.tag)
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purple)
                Label(
                    lang.t(animal.muzzleRegistered ? "detail.muzzleID" : "detail.notRegistered"),
                    systemImage: animal.muzzleRegistered ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(CarniFont.semibold(11))
                .foregroundStyle(animal.muzzleRegistered ? CarniColors.successGreen : Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        (animal.muzzleRegistered ? CarniColors.successGreen : Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255)).opacity(0.12)
                    )
                )
            }
            Spacer(minLength: 0)
        }
        .carniCard()
    }

    private var infoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            InfoTile(label: lang.t("detail.breed"), value: animal.breed)
            InfoTile(label: lang.t("detail.sex"), value: lang.t(animal.sex.key))
            InfoTile(label: lang.t("detail.age"), value: animal.ageDescription(lang))
            InfoTile(label: lang.t("detail.enrolled"), value: lang.shortDate(animal.createdAt))
        }
    }
}

private struct InfoTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(CarniFont.regular(12))
                .foregroundStyle(CarniColors.tabInactive)
            Text(value)
                .font(CarniFont.semibold(15))
                .foregroundStyle(CarniColors.purpleDark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carniCard(padding: 14)
    }
}
```

(The duplicate `.sheet` added in Task 9 Step 3 is replaced by this rewrite — the rewrite includes it exactly once.)

- [ ] **Step 3: Delete the shims AnimalsView used from `CarniVision/Models/HerdData.swift`**

From the `TEMPORARY compatibility shims` section delete:

```swift
struct WeightEntry: Identifiable {
    let id = UUID()
    let date: Date
    let kg: Double
}

enum AnimalStatus: String {
    case healthy = "Healthy"

    var key: String { "status.healthy" }
    var color: Color { CarniColors.successGreen }
}

extension Animal {
    var status: AnimalStatus { .healthy }
    var lastScanned: Date? { nil }
    var weights: [WeightEntry] { [] }
    var currentWeight: Double? { nil }
    var weightDelta: Double? { nil }
}
```

and from `extension HerdStore` delete:

```swift
    var animalsByScanUrgency: [Animal] { animals }
```

Also delete the temporary `scanUrgencyColor` shim from `CarniVision/Views/Main/HomeView.swift` (the whole block added in Task 10, including its `// TEMPORARY shim` comment):

```swift
// TEMPORARY shim (deleted in Task 11): the old AnimalsView still calls this
// until its rewrite lands. Task 14's grep verifies it is gone.
func scanUrgencyColor(_ lastScanned: Date?) -> Color {
    guard let lastScanned else {
        return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255)
    }
    let days = Date().timeIntervalSince(lastScanned) / 86400
    if days >= 7 { return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255) }
    if days >= 2 { return Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255) }
    return CarniColors.successGreen
}
```

(The legacy `addAnimal(... initialWeightKg ...)` and `markLastAddedMuzzleRegistered` shims survive one more task — AddAnimalView still calls them.)

- [ ] **Step 4: Build and test**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add CarniVision/Views/Main/AnimalsView.swift CarniVision/Views/Main/HomeView.swift CarniVision/Models/Localization.swift CarniVision/Models/HerdData.swift
git commit -m "feat(ios): Animals list and detail on real data with photos"
```

---

### Task 12: AddAnimalView — sheet presentation, real fields only

**Files:**
- Modify: `CarniVision/Views/Main/AddAnimalView.swift` (full rewrite)
- Modify: `CarniVision/Models/HerdData.swift` (delete the last shims)

- [ ] **Step 1: Replace the entire contents of `CarniVision/Views/Main/AddAnimalView.swift`**

(Removes the weight field, the no-op muzzle-scanned toggle card, and the never-shown toast; adds a close button for sheet presentation; save → `repository.create` → optimistic `store.addAnimal` → enrollment camera; after a successful enrollment the store reloads and the sheet dismisses.)

```swift
import SwiftUI

struct AddAnimalScreen: View {
    @EnvironmentObject private var store: HerdStore
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared

    private let repository = AnimalRepository()

    @State private var name = ""
    @State private var tag = ""
    @State private var breed = "Holstein"
    @State private var sex: AnimalSex = .female
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()

    @State private var isSaving = false
    @State private var saveError: String?
    /// Set to the new animal id to trigger the enrollment camera.
    @State private var enrollAnimalID: String?
    /// True once the enrollment camera reported success; closing it then
    /// dismisses this sheet too.
    @State private var enrollmentCompleted = false

    private let breeds = ["Holstein", "Angus", "Simmental", "Jersey", "Hereford", "Charolais", "Limousin"]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !tag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                detailsCard
                saveButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(CarniColors.appBackground.ignoresSafeArea())
        .fullScreenCover(item: $enrollAnimalID) { animalID in
            CameraScreen(
                onClose: {
                    enrollAnimalID = nil
                    if enrollmentCompleted { dismiss() }
                },
                onEnrollSuccess: {
                    enrollmentCompleted = true
                    Task { await store.load() }
                },
                enrollAnimalID: animalID
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lang.t("add.title"))
                    .font(CarniFont.bold(24))
                    .foregroundStyle(CarniColors.purpleDark)
                Text(lang.t("add.subtitle"))
                    .font(CarniFont.regular(13))
                    .foregroundStyle(CarniColors.tabInactive)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CarniColors.purpleDark)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.white)
                            .shadow(color: CarniColors.purpleDark.opacity(0.08), radius: 8, y: 3)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var detailsCard: some View {
        VStack(spacing: 16) {
            FormField(label: lang.t("add.name"), placeholder: lang.t("add.namePh"), text: $name)
            FormField(label: lang.t("add.tag"), placeholder: lang.t("add.tagPh"), text: $tag)

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.breed"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                Menu {
                    ForEach(breeds, id: \.self) { option in
                        Button(option) { breed = option }
                    }
                } label: {
                    HStack {
                        Text(breed)
                            .font(CarniFont.regular(15))
                            .foregroundStyle(CarniColors.purpleDark)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CarniColors.tabInactive)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldBackground)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("detail.sex"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                HStack(spacing: 8) {
                    ForEach(AnimalSex.allCases) { option in
                        Button {
                            sex = option
                        } label: {
                            Text(lang.t(option.key))
                                .font(CarniFont.semibold(14))
                                .foregroundStyle(sex == option ? .white : CarniColors.purple)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(sex == option ? CarniColors.purple : CarniColors.purple.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.dob"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                HStack {
                    DatePicker("", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .tint(CarniColors.purple)
                        .environment(\.locale, lang.language.locale)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(fieldBackground)
            }
        }
        .carniCard()
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(CarniColors.appBackground)
    }

    private var saveButton: some View {
        VStack(spacing: 10) {
            if let saveError {
                Text(saveError)
                    .font(CarniFont.regular(13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: save) {
                Text(isSaving ? lang.t("camera.enroll.submitting") : lang.t("add.save"))
                    .font(CarniFont.bold(16))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(canSave && !isSaving ? CarniColors.purple : CarniColors.purple.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave || isSaving)
        }
    }

    private func save() {
        guard let ownerID = auth.userID else {
            saveError = lang.t("auth.error.generic")
            return
        }
        saveError = nil
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let created = try await repository.create(
                    ownerID: ownerID,
                    name: trimmedName,
                    tag: trimmedTag,
                    breed: breed,
                    sex: sex,
                    birthDate: birthDate
                )
                await MainActor.run {
                    // Optimistic insert with the REAL row id; muzzleRegistered
                    // stays false until enrollment succeeds and load() reconciles.
                    store.addAnimal(
                        id: UUID(uuidString: created.id) ?? UUID(),
                        name: trimmedName,
                        tag: trimmedTag,
                        breed: breed,
                        sex: sex,
                        birthDate: birthDate
                    )
                    isSaving = false
                    name = ""
                    tag = ""
                    enrollAnimalID = created.id   // launches the enrollment camera
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

private struct FormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(CarniFont.semibold(13))
                .foregroundStyle(CarniColors.purpleDark)
            TextField(placeholder, text: $text)
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(CarniColors.appBackground)
                )
        }
    }
}

extension String: Identifiable {
    public var id: String { self }
}
```

- [ ] **Step 2: Delete the remaining shims from `CarniVision/Models/HerdData.swift`**

Remove the entire `// MARK: - TEMPORARY compatibility shims` section — at this point the only remaining shims are:

```swift
extension HerdStore {
    func addAnimal(
        name: String, tag: String, breed: String, sex: AnimalSex,
        birthDate: Date, initialWeightKg: Double?, muzzleRegistered: Bool
    ) {
        addAnimal(id: UUID(), name: name, tag: tag, breed: breed, sex: sex, birthDate: birthDate)
    }

    func markLastAddedMuzzleRegistered() {
        Task { await load() }
    }
}
```

Delete them and the MARK comment block. `HerdData.swift` now ends with `loadErrorMessage(for:)`.

- [ ] **Step 3: Build and test**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add CarniVision/Views/Main/AddAnimalView.swift CarniVision/Models/HerdData.swift
git commit -m "feat(ios): Add Animal sheet slimmed to real fields"
```

---

### Task 13: CameraView — identify result card resolves name + photo

**Files:**
- Modify: `CarniVision/Views/Main/CameraView.swift`

- [ ] **Step 1: Add the store environment object to `CameraScreen`**

In `struct CameraScreen`, after the line `@EnvironmentObject private var recognition: CloudRunRecognitionService`, add:

```swift
    @EnvironmentObject private var store: HerdStore
```

- [ ] **Step 2: Resolve the identified animal in `identifyOverlay`**

Replace the identified branch of `identifyOverlay` — the block:

```swift
                if let result = model.identifyResult {
                    if result.isIdentified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 50)).foregroundStyle(CarniColors.successGreen)
                        Text(result.name ?? lang.t("camera.identify.identified"))
                            .font(CarniFont.bold(22)).foregroundStyle(.white)
                        Text(lang.t("camera.identify.score", result.score * 100))
                            .font(CarniFont.regular(15)).foregroundStyle(.white.opacity(0.85))
                    } else {
```

with:

```swift
                if let result = model.identifyResult {
                    if result.isIdentified {
                        // Resolve the UUID against the loaded herd: show the
                        // animal's photo + name + tag instead of a raw id.
                        let matched = result.animalId
                            .flatMap(UUID.init(uuidString:))
                            .flatMap { id in store.animals.first(where: { $0.id == id }) }
                        if let matched {
                            AnimalPhotoView(
                                animalID: matched.id,
                                name: matched.name,
                                color: matched.avatarColor,
                                size: 76
                            )
                        } else {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 50)).foregroundStyle(CarniColors.successGreen)
                        }
                        Text(matched?.name ?? result.name ?? lang.t("camera.identify.identified"))
                            .font(CarniFont.bold(22)).foregroundStyle(.white)
                        if let matched, !matched.tag.isEmpty {
                            Text(matched.tag)
                                .font(CarniFont.semibold(14)).foregroundStyle(.white.opacity(0.85))
                        }
                        Text(lang.t("camera.identify.score", result.score * 100))
                            .font(CarniFont.regular(15)).foregroundStyle(.white.opacity(0.85))
                    } else {
```

(The unknown branch is unchanged — it still offers "Enroll this animal" via `onRequestEnroll`, which now opens the Add sheet per Task 9.)

- [ ] **Step 3: Refresh the feed after an identify returns**

The server wrote an event either way (identified or unknown). In `CameraScreen.body`, after the existing `.onChange(of: model.captureFailed) { ... }` modifier, add:

```swift
        .onChange(of: model.identifyResult) { _, result in
            guard result != nil else { return }
            Task { await store.load() }
        }
```

- [ ] **Step 4: Fix the DEBUG preview**

`CameraScreen` now requires a `HerdStore` in the environment. Replace:

```swift
#Preview {
    CameraScreen()
        .environmentObject(CloudRunRecognitionService.preview)
}
```

with:

```swift
#Preview {
    CameraScreen()
        .environmentObject(CloudRunRecognitionService.preview)
        .environmentObject(HerdStore())
}
```

- [ ] **Step 5: Build and test**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add CarniVision/Views/Main/CameraView.swift
git commit -m "feat(ios): identify result card resolves animal name and photo"
```

---

### Task 14: Settings de-demo + localization cleanup

**Files:**
- Modify: `CarniVision/Views/Main/SettingsView.swift`
- Modify: `CarniVision/Models/Localization.swift` (remove dead keys, EN+TR)

- [ ] **Step 1: De-demo SettingsView**

(a) Replace `profileCard` (currently hardcoded "GV" / "Green Valley Farm" / `owner@greenvalley.farm` fallback):

```swift
    private var signedInEmail: String {
        SupabaseClientProvider.shared.auth.currentSession?.user.email ?? ""
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(CarniColors.purple.opacity(0.14))
                Text(signedInEmail.prefix(1).uppercased())
                    .font(CarniFont.bold(20))
                    .foregroundStyle(CarniColors.purple)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(signedInEmail)
                    .font(CarniFont.bold(16))
                    .foregroundStyle(CarniColors.purpleDark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer()
        }
        .carniCard()
    }
```

(b) Remove the no-op Preferences section (fake notification/auto-capture/metric toggles with no backend):
- Delete `preferencesSection` from the `VStack` in `body` (the line `preferencesSection`).
- Delete the entire `private var preferencesSection: some View { ... }` property.
- Delete the now-unused `@State private var notificationsOn = true`, `@State private var autoCaptureOn = true`, `@State private var metricUnits = true`.
- Delete the now-unused `private struct ToggleRow: View { ... }` at the bottom of the file.

- [ ] **Step 2: Remove dead localization keys from BOTH tables (EN and TR) in `CarniVision/Models/Localization.swift`**

Delete these key lines from the English table AND their counterparts in the Turkish table:

```
home.avgWeight, home.weightTrend, home.recentScans, home.needsScan,
tab.add,
status.healthy, status.pregnant, status.attention,
scan.identified, scan.newID, scan.noMatch,
animals.lastScan, animals.never,
detail.currentWeight, detail.lastScan, detail.weightHistory, detail.weighIns, detail.notEnough,
add.scanPrompt, add.scanDone, add.scanHint, add.scanHintDone,
add.weight, add.weightPh, add.saved,
settings.preferences, settings.notifications, settings.autoCapture, settings.metric
```

(Keep `home.animals`, `home.scansThisWeek`, `home.muzzleIDs`, `home.seeAll`, `animals.empty`, `unit.yr`, `unit.mo`, all `detail.title/muzzleID/notRegistered/breed/sex/age/enrolled`, all camera/auth/recognition keys.)

- [ ] **Step 3: Verify no dead keys or shims are still referenced**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && \
for key in home.avgWeight home.weightTrend home.recentScans home.needsScan tab.add status.healthy status.pregnant status.attention scan.identified scan.newID scan.noMatch animals.lastScan animals.never detail.currentWeight detail.lastScan detail.weightHistory detail.weighIns detail.notEnough add.scanPrompt add.scanDone add.scanHint add.scanHintDone add.weight add.weightPh add.saved settings.preferences settings.notifications settings.autoCapture settings.metric; do \
  grep -rn "\"$key\"" CarniVision --include="*.swift" && echo "DEAD KEY STILL REFERENCED: $key"; \
done; \
grep -rn "WeightEntry\|AnimalStatus\|markLastAddedMuzzleRegistered\|animalsByScanUrgency\|scanUrgencyColor\|herdTrend\|recentScans\|TEMPORARY compatibility" CarniVision --include="*.swift"
```
Expected: no output from either grep (every dead key and every Task 8 shim is gone).

- [ ] **Step 4: Build and test**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add CarniVision/Views/Main/SettingsView.swift CarniVision/Models/Localization.swift
git commit -m "chore(ios): de-demo Settings and remove localization keys for deleted UI"
```

---

### Task 15: Full verification pass (iOS + server)

**Files:** none (verification only; fix-forward anything that fails).

- [ ] **Step 1: Full iOS test run**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `** TEST SUCCEEDED **` — all 12 pre-existing tests (AuthServiceTests, MultipartFormDataTests, RecognitionDecodingTests) plus the new AnimalRecordDecodingTests (2), EventRecordDecodingTests (2), HerdStoreTests (4), EventFormattingTests (4).

- [ ] **Step 2: Full server test run**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision/server && .venv/bin/pytest tests/ -m "not slow" -q
```
Expected: `33 passed, 2 skipped, 2 deselected`.

- [ ] **Step 3: Release build of the app (catches preview/asset issues `test` can mask)**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && xcodebuild -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit (only if fixes were needed)**

```bash
git add -A && git diff --cached --quiet || git commit -m "test: full iOS + server pass after UI cleanup"
```

---

### Task 16: Deploy the event-writing embedder to Cloud Run — CONTROLLER-RUN WITH USER APPROVAL

**Files:** none (operations). Prerequisites: Tasks 1–4 merged, Task 1 Step 4 (schema applied by the user) done. GCP project `agritrack-465917`, region `europe-west1`, service `carnivision-embedder`. This task must NOT run unattended — ask the user before each gcloud command.

- [ ] **Step 1: Build the image with Cloud Build (user approval required)**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && gcloud builds submit server \
  --project agritrack-465917 \
  --tag gcr.io/agritrack-465917/carnivision-embedder:events
```
Expected: build succeeds in ~10–15 min (the MiewID weight-bake layer is cached from prior builds when unchanged) and pushes the tag.

- [ ] **Step 2: Deploy the new revision (user approval required)**

Deploying by `--image` only — existing env vars, secrets (`carnivision-service-role-key`, `carnivision-database-url`), 4Gi/2cpu, min 0/max 3, cpu-boost, concurrency 4 and `--allow-unauthenticated` are all preserved from the current service config:

```bash
gcloud run deploy carnivision-embedder \
  --project agritrack-465917 \
  --region europe-west1 \
  --image gcr.io/agritrack-465917/carnivision-embedder:events
```
Expected: `Service [carnivision-embedder] revision [...] has been deployed` with URL `https://carnivision-embedder-78377568014.europe-west1.run.app`.

- [ ] **Step 3: Verify the live service**

```bash
URL=$(gcloud run services describe carnivision-embedder --project agritrack-465917 --region europe-west1 --format 'value(status.url)')
curl -s "$URL/health"
```
Expected: `{"status":"ok","model_loaded":true}` (first hit may take ~20–30 s cold start). Check the revision logs for the absence of "Could not initialize NNPACK" warnings:

```bash
gcloud run services logs read carnivision-embedder --project agritrack-465917 --region europe-west1 --limit 50
```

End-to-end event check (user runs from the app, or with a test JWT): perform one identify from the iOS app, then the user verifies a row landed via the app's Home feed (Recent Actions shows the identify) — or via SQL in the dashboard: `select kind, result, score, created_at from events order by created_at desc limit 5;`.

- [ ] **Step 4: Commit any doc/ops tweaks (only if files changed)**

```bash
cd /Users/korkutkaanbalta/Documents/carni_vision && git add -A && git diff --cached --quiet || git commit -m "chore(server): deployment notes for event-writing embedder"
```

---

## Spec-coverage self-review

| Spec section | Task(s) |
|---|---|
| `events` table (idempotent, RLS select-only) | 1 |
| Embedder writes events; failure never fails response | 2 |
| Storage owner-read policy | 1, verified in 4 |
| Schema applied via setup script (user-run) | 1 Step 4 |
| NNPACK flag at startup | 3 |
| Cloud Run redeploy | 16 |
| RLS verification integration test | 4 |
| `AnimalRepository.list()` / `AnimalRecord` / derived `muzzleRegistered` | 5 |
| `EventRepository` / `EventRecord` | 6 |
| `AnimalPhotoLoader` (full→muzzle fallback, NSCache + disk, nil on failure) | 7 |
| `HerdStore` rewrite, no seed data, concurrent load, optimistic insert | 8 |
| Model slimming (no weights/status/lastScanned/charts/seeds) | 8, 10, 11, 12 |
| MainTabView 4 tabs + load on auth | 9 |
| HomeView (greeting+email, no bell, 3 stats, recent actions, empty state) | 10 |
| AnimalsView (+ button, photo cards, search/filter, refresh, empty states) | 11 |
| AnimalDetailView (photo, info grid incl. enrolled date + muzzle status) | 11 |
| AddAnimalView (sheet, no weight/toggle, enroll flow, refresh) | 12 |
| CameraView identify card resolves name+photo; unknown unchanged | 13 |
| Localization EN+TR new keys / dead-key removal | 8, 10, 11, 14 |
| Error & empty states (spinner, retry banner, avatar fallback) | 8, 10, 11 |
| Testing: decoding, HerdStore, formatting EN+TR, RLS, server events, existing 12 | 5, 6, 8, 4, 2, 15 |

## Ambiguities resolved during planning

1. **`events.animal_id` FK:** spec showed plain `references animals(id)`; the plan uses `on delete set null` so event history survives animal deletion and integration-test cleanup (`delete from animals ...`) doesn't violate the FK.
2. **Storage policy privileges:** on newer Supabase projects the `postgres` role may not own `storage.objects`; the policy is wrapped in a `DO` block that degrades to a NOTICE, the setup script reports policy presence, and the RLS test asserts the owner CAN read (proving the policy exists) in addition to the cross-owner denial.
3. **Storage path casing:** the embedder writes `{jwt-sub}` (lowercase) but the iOS client sends `UUID.uuidString` (uppercase) as `animal_id`, so existing objects have uppercase animal segments. `AnimalPhotoLoader` lowercases the owner segment and probes both animal-segment casings.
4. **SettingsView:** not in the spec's screen list but in scope of "remove all demo data" — the hardcoded "Green Valley Farm"/"GV" profile card now shows the signed-in email, and the no-op Preferences toggles (notifications, auto-capture, metric units) are removed along with their keys.
5. **Refresh after identify:** the spec only mandates refresh after enrollment; the plan also reloads after an identify returns (the server wrote an event either way) so the Home feed stays current.
6. **Score formatting:** `%.2f` with non-localized decimal separator, matching the spec's example "identified (0.64)" in both languages.
7. **Compile-green sequencing:** Task 8's model rewrite ships with clearly-marked temporary shims so every commit builds; Tasks 10–12 delete them and Task 14's grep proves none remain.
8. **Feed size:** `recent(limit: 20)` for the Home feed (spec left N open).
