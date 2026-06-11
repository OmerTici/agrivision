# CarniVision Embedder API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the stateless FastAPI embedder service (`server/`) that adds muzzle enroll + 1:N identify to CarniVision, per the approved spec at `docs/superpowers/specs/2026-06-11-carnivision-embedder-api-design.md`.

**Architecture:** Cloud Run container loads MiewID-msv3 once at startup; every request verifies a Supabase HS256 JWT, embeds JPEG muzzle crops (2152-d, L2-normalized), and runs exact-scan cosine SQL against Supabase Postgres (pgvector, no index — intentional). Images go to Supabase Storage; all state lives in Supabase.

**Tech Stack:** Python 3.11, FastAPI, PyTorch (CPU) + transformers (pins from the bakeoff: `transformers==5.9.0`, `timm==1.0.27`), asyncpg via Supavisor transaction pooler, PyJWT, httpx, pgvector.

**Reference constants (from spec — do not re-derive):** model `conservationxlabs/miewid-msv3`; 440×440 input, ImageNet normalize; 2152-d L2-normalized output; decision rule `top1 ≥ 0.7746 AND (top1 − top2) ≥ 0.05`.

---

## File structure

```
server/
  app/
    __init__.py      empty package marker
    main.py          FastAPI app, lifespan model load, 3 routes
    miewid.py        vendored MiewID embedder (self-contained)
    decision.py      pure open-set decision rule
    auth.py          HS256 Supabase JWT verification (FastAPI dependency)
    db.py            asyncpg pool (pooler-safe), match + insert SQL
    storage.py       Supabase Storage upload via httpx
    config.py        pydantic-settings env config
    schemas.py       pydantic response models
  tests/
    __init__.py
    conftest.py      app fixture with auth + embedder overrides
    test_decision.py
    test_embed.py    real model: 2152-d, L2 norm (downloads ~206 MB once)
    test_auth.py
    test_db.py       vector-literal unit tests
    test_api.py      route tests with fakes (no model, no DB)
    test_match.py    integration: real model + real DB (env-gated, skipped otherwise)
  sql/
    schema.sql       tables + RLS (applied once to Supabase)
  Dockerfile
  requirements.txt
  requirements-dev.txt
  .env.example
  README.md
```

Each `app/` module has one responsibility and is importable without side effects (no model load, no DB connect at import time). The model loads in `main.py`'s lifespan; the DB pool is created lazily on first query.

**Working conventions for every task:**
- Run all commands from `/Users/korkutkaanbalta/Documents/carni_vision`.
- Python: `server/.venv/bin/python` and `server/.venv/bin/pytest` (created in Task 1).
- Commit after every green test, from the repo root.

---

### Task 1: Scaffold, venv, and config

**Files:**
- Create: `server/requirements.txt`, `server/requirements-dev.txt`
- Create: `server/app/__init__.py`, `server/tests/__init__.py` (both empty)
- Create: `server/app/config.py`
- Test: `server/tests/test_config.py`

- [ ] **Step 1: Create requirements files**

`server/requirements.txt`:
```
# Torch CPU wheels are installed separately (see Dockerfile / README) so pip
# doesn't pull the CUDA build: torch==2.12.0 torchvision==0.27.0
transformers==5.9.0
timm==1.0.27
huggingface_hub==1.16.1
numpy==2.4.4
Pillow
fastapi
uvicorn[standard]
python-multipart
pydantic-settings
PyJWT
asyncpg
httpx
```

`server/requirements-dev.txt`:
```
-r requirements.txt
pytest
pytest-asyncio
```

- [ ] **Step 2: Create venv and install (torch CPU first, then the rest)**

Run:
```bash
python3.11 -m venv server/.venv 2>/dev/null || python3 -m venv server/.venv
server/.venv/bin/pip install --upgrade pip
server/.venv/bin/pip install torch==2.12.0 torchvision==0.27.0
server/.venv/bin/pip install -r server/requirements-dev.txt
```
Expected: installs complete without error. (Locally plain torch is fine; the CPU-only index matters in the Dockerfile.)

- [ ] **Step 3: Create empty package markers**

```bash
touch server/app/__init__.py server/tests/__init__.py
```

- [ ] **Step 4: Write the failing config test**

`server/tests/test_config.py`:
```python
from app.config import Settings


def test_defaults_match_bakeoff_operating_point():
    s = Settings(_env_file=None)
    assert s.sim_threshold == 0.7746
    assert s.sim_margin == 0.05
    assert s.storage_bucket == "muzzles"


def test_env_override(monkeypatch):
    monkeypatch.setenv("SIM_THRESHOLD", "0.9")
    s = Settings(_env_file=None)
    assert s.sim_threshold == 0.9
```

- [ ] **Step 5: Run test to verify it fails**

Run: `cd server && .venv/bin/pytest tests/test_config.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.config'`

- [ ] **Step 6: Write config.py**

`server/app/config.py`:
```python
from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Supabase project
    supabase_url: str = ""                # https://<ref>.supabase.co
    supabase_jwt_secret: str = ""         # legacy HS256 secret (Dashboard > API)
    supabase_service_role_key: str = ""   # Storage uploads only
    # Supavisor TRANSACTION pooler DSN (port 6543), never direct 5432
    database_url: str = ""
    storage_bucket: str = "muzzles"

    # Open-set decision rule — bakeoff suggested_threshold (miewid-msv3.json)
    sim_threshold: float = 0.7746
    sim_margin: float = 0.05

    model_config = {"env_file": ".env", "extra": "ignore"}


@lru_cache
def get_settings() -> Settings:
    return Settings()
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cd server && .venv/bin/pytest tests/test_config.py -v`
Expected: 2 PASS

- [ ] **Step 8: Add .gitignore entries and commit**

Append to repo-root `.gitignore`:
```
server/.venv/
server/.env
__pycache__/
.pytest_cache/
```

```bash
git add .gitignore server/requirements.txt server/requirements-dev.txt server/app/__init__.py server/tests/__init__.py server/app/config.py server/tests/test_config.py
git commit -m "feat(server): scaffold embedder service with env config"
```

---

### Task 2: Open-set decision rule

**Files:**
- Create: `server/app/decision.py`
- Test: `server/tests/test_decision.py`

- [ ] **Step 1: Write the failing tests**

`server/tests/test_decision.py`:
```python
from app.decision import Candidate, decide

T, M = 0.7746, 0.05


def c(animal_id, sim, name=None):
    return Candidate(animal_id=animal_id, name=name, sim=sim)


def test_identified_when_above_threshold_and_margin():
    d = decide([c("a1", 0.90, "Bessie"), c("a2", 0.70)], T, M)
    assert d.decision == "identified"
    assert d.animal_id == "a1"
    assert d.name == "Bessie"
    assert d.score == 0.90
    assert abs(d.margin - 0.20) < 1e-9


def test_unknown_below_threshold():
    d = decide([c("a1", 0.60), c("a2", 0.40)], T, M)
    assert d.decision == "unknown"
    assert d.animal_id is None


def test_unknown_when_margin_too_thin():
    d = decide([c("a1", 0.90), c("a2", 0.88)], T, M)
    assert d.decision == "unknown"


def test_single_candidate_margin_trivially_satisfied():
    d = decide([c("a1", 0.85, "Solo")], T, M)
    assert d.decision == "identified"


def test_empty_gallery_is_unknown():
    d = decide([], T, M)
    assert d.decision == "unknown"
    assert d.score == 0.0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && .venv/bin/pytest tests/test_decision.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.decision'`

- [ ] **Step 3: Write decision.py**

`server/app/decision.py`:
```python
"""Open-set decision rule from the bakeoff: accept the top animal only if its
similarity clears the threshold AND beats the runner-up animal by the margin.
Candidates are per-animal max-cosine scores, ordered best-first."""
from dataclasses import dataclass


@dataclass
class Candidate:
    animal_id: str
    name: str | None
    sim: float


@dataclass
class Decision:
    decision: str  # "identified" | "unknown"
    animal_id: str | None
    name: str | None
    score: float
    margin: float


def decide(candidates: list[Candidate], threshold: float, margin: float) -> Decision:
    if not candidates:
        return Decision("unknown", None, None, 0.0, 0.0)
    top = candidates[0]
    # With one enrolled animal there is no runner-up; the margin criterion
    # is trivially satisfied (mirrors the bakeoff's top2-distinct semantics).
    gap = top.sim - candidates[1].sim if len(candidates) > 1 else 1.0
    if top.sim >= threshold and gap >= margin:
        return Decision("identified", top.animal_id, top.name, top.sim, gap)
    return Decision("unknown", None, None, top.sim, gap)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && .venv/bin/pytest tests/test_decision.py -v`
Expected: 5 PASS

- [ ] **Step 5: Commit**

```bash
git add server/app/decision.py server/tests/test_decision.py
git commit -m "feat(server): open-set decision rule (threshold + margin)"
```

---

### Task 3: Vendored MiewID embedder

**Files:**
- Create: `server/app/miewid.py` (adapted from `/Volumes/Extreme SSD/Animal_Biometrics_System/cattle_id_bakeoff/scripts/models/miewid_msv3.py`)
- Test: `server/tests/test_embed.py`

Note: the first run downloads ~206 MB from HuggingFace (or hits the existing bakeoff cache under `~/.cache/huggingface`). The test is marked `slow`.

- [ ] **Step 1: Write the failing test**

`server/tests/test_embed.py`:
```python
import numpy as np
import pytest
from PIL import Image

pytestmark = pytest.mark.slow


@pytest.fixture(scope="module")
def embedder():
    from app.miewid import MiewIDEmbedder
    return MiewIDEmbedder(device="cpu")


def _img(color):
    return Image.new("RGB", (300, 300), color)


def test_embedding_is_2152d_and_l2_normalized(embedder):
    out = embedder.embed_batch([_img((255, 255, 255))])
    assert out.shape == (1, 2152)
    assert out.dtype == np.float32
    assert abs(np.linalg.norm(out[0]) - 1.0) < 1e-3


def test_batched_forward_pass(embedder):
    out = embedder.embed_batch([_img((255, 0, 0)), _img((0, 255, 0)), _img((0, 0, 255))])
    assert out.shape == (3, 2152)
    norms = np.linalg.norm(out, axis=1)
    assert np.all(np.abs(norms - 1.0) < 1e-3)
```

Also create `server/pytest.ini`:
```ini
[pytest]
markers =
    slow: needs the real MiewID model (downloads ~206 MB on first run)
    integration: needs real Supabase DB + sample images (env-gated)
asyncio_mode = auto
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && .venv/bin/pytest tests/test_embed.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.miewid'`

- [ ] **Step 3: Write miewid.py (vendored, self-contained)**

`server/app/miewid.py`:
```python
"""Vendored MiewID-msv3 embedder.

Source of truth: Animal_Biometrics_System/cattle_id_bakeoff/scripts/models/
miewid_msv3.py (the exact code the bakeoff results were produced with).
Per the model card: 440x440 input, ImageNet normalization, model(batch)
returns the embedding tensor directly. Output: 2152-d, L2-normalized."""
import numpy as np
import torch
import torchvision.transforms as T
from transformers import AutoModel

HF_ID = "conservationxlabs/miewid-msv3"
EMB_DIM = 2152


def _compat_shim():
    """MiewID's remote modeling code predates transformers 5.x, which expects
    every PreTrainedModel to expose `all_tied_weights_keys` during
    from_pretrained's weight-tying step. Provide a harmless class-level default
    (MiewID has no tied weights)."""
    try:
        from transformers import PreTrainedModel
        if not hasattr(PreTrainedModel, "all_tied_weights_keys"):
            PreTrainedModel.all_tied_weights_keys = {}
    except Exception:
        pass


class MiewIDEmbedder:
    def __init__(self, device: str = "cpu"):
        self.device = device
        _compat_shim()
        self.model = (
            AutoModel.from_pretrained(HF_ID, trust_remote_code=True).eval().to(device)
        )
        # Preprocessing taken verbatim from the model card (do not assume).
        self.tfm = T.Compose([
            T.Resize((440, 440)),
            T.ToTensor(),
            T.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ])

    def _feats(self, batch: torch.Tensor) -> torch.Tensor:
        out = self.model(batch)
        if hasattr(out, "shape"):  # custom model returns the tensor directly
            return out
        for attr in ("pooler_output", "last_hidden_state", "logits"):
            if getattr(out, attr, None) is not None:
                return getattr(out, attr)
        raise RuntimeError(f"unexpected MiewID output type: {type(out)}")

    @torch.no_grad()
    def embed_batch(self, pil_images) -> np.ndarray:
        batch = torch.stack([self.tfm(im.convert("RGB")) for im in pil_images]).to(self.device)
        feats = torch.nn.functional.normalize(self._feats(batch), p=2, dim=1)
        arr = feats.detach().cpu().numpy().astype(np.float32)
        assert arr.shape[1] == EMB_DIM, f"expected {EMB_DIM}-d, got {arr.shape[1]}"
        assert np.all(np.abs(np.linalg.norm(arr, axis=1) - 1.0) < 1e-3), "not L2-normalized"
        return arr
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && .venv/bin/pytest tests/test_embed.py -v`
Expected: 2 PASS (first run may take minutes for download + CPU inference)

- [ ] **Step 5: Commit**

```bash
git add server/app/miewid.py server/tests/test_embed.py server/pytest.ini
git commit -m "feat(server): vendor MiewID-msv3 embedder from bakeoff"
```

---

### Task 4: JWT auth (HS256)

**Files:**
- Create: `server/app/auth.py`
- Test: `server/tests/test_auth.py`

- [ ] **Step 1: Write the failing tests**

`server/tests/test_auth.py`:
```python
import time

import jwt
import pytest
from fastapi import HTTPException

from app.auth import verify_jwt

SECRET = "test-secret"


def make_token(secret=SECRET, sub="user-123", aud="authenticated", exp_delta=3600):
    return jwt.encode(
        {"sub": sub, "aud": aud, "exp": int(time.time()) + exp_delta},
        secret,
        algorithm="HS256",
    )


def test_valid_token_returns_uid():
    assert verify_jwt(make_token(), SECRET) == "user-123"


def test_wrong_secret_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(secret="other"), SECRET)
    assert e.value.status_code == 401


def test_expired_token_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(exp_delta=-10), SECRET)
    assert e.value.status_code == 401


def test_wrong_audience_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(aud="anon"), SECRET)
    assert e.value.status_code == 401


def test_missing_sub_rejected():
    tok = jwt.encode({"aud": "authenticated", "exp": int(time.time()) + 60}, SECRET, algorithm="HS256")
    with pytest.raises(HTTPException) as e:
        verify_jwt(tok, SECRET)
    assert e.value.status_code == 401
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && .venv/bin/pytest tests/test_auth.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.auth'`

- [ ] **Step 3: Write auth.py**

`server/app/auth.py`:
```python
"""Supabase JWT verification — legacy HS256 secret (decided 2026-06-11).
ALL verify logic lives here so the future swap to JWKS (asymmetric keys)
is a one-file change."""
import jwt
from fastapi import Header, HTTPException

from .config import get_settings


def verify_jwt(token: str, secret: str) -> str:
    """Return the authenticated user's uid (the `sub` claim) or raise 401."""
    try:
        payload = jwt.decode(
            token, secret, algorithms=["HS256"], audience="authenticated"
        )
    except jwt.InvalidTokenError as exc:
        raise HTTPException(status_code=401, detail=f"invalid token: {exc}")
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(status_code=401, detail="token missing sub claim")
    return sub


def current_uid(authorization: str = Header(default="")) -> str:
    """FastAPI dependency: extract and verify the bearer token."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    return verify_jwt(authorization[len("Bearer "):], get_settings().supabase_jwt_secret)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && .venv/bin/pytest tests/test_auth.py -v`
Expected: 5 PASS

- [ ] **Step 5: Commit**

```bash
git add server/app/auth.py server/tests/test_auth.py
git commit -m "feat(server): HS256 Supabase JWT verification"
```

---

### Task 5: Database access (asyncpg, pooler-safe)

**Files:**
- Create: `server/app/db.py`
- Test: `server/tests/test_db.py`

The pure part (pgvector literal formatting) is unit-tested; the SQL execution paths are exercised by the integration test in Task 9.

- [ ] **Step 1: Write the failing tests**

`server/tests/test_db.py`:
```python
import numpy as np

from app.db import MATCH_SQL, vector_literal


def test_vector_literal_format():
    lit = vector_literal(np.array([0.5, -0.25, 1.0], dtype=np.float32))
    assert lit.startswith("[") and lit.endswith("]")
    parts = [float(p) for p in lit[1:-1].split(",")]
    assert parts == [0.5, -0.25, 1.0]


def test_vector_literal_roundtrip_precision():
    vec = np.random.default_rng(48).standard_normal(2152).astype(np.float32)
    vec /= np.linalg.norm(vec)
    parts = np.array([float(p) for p in vector_literal(vec)[1:-1].split(",")], dtype=np.float32)
    assert np.allclose(parts, vec, atol=1e-7)


def test_match_sql_is_owner_scoped_exact_scan():
    assert "e.owner = $2::uuid" in MATCH_SQL
    assert "<=>" in MATCH_SQL          # pgvector cosine distance
    assert "limit 5" in MATCH_SQL
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && .venv/bin/pytest tests/test_db.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.db'`

- [ ] **Step 3: Write db.py**

`server/app/db.py`:
```python
"""Postgres access via the Supavisor TRANSACTION pooler (port 6543).
statement_cache_size=0 is REQUIRED behind transaction pooling: prepared
statements don't survive connection reassignment.

Vectors are passed as pgvector text literals and cast in SQL — no client-side
codec registration needed, which also keeps the pooler happy.

Matching is an exact scan by design (no vector index): pgvector caps HNSW at
2000 dims (MiewID is 2152) and exact scan is ~0.2 ms at 1k vectors anyway."""
import asyncpg
import numpy as np

from .config import get_settings
from .decision import Candidate

_pool: asyncpg.Pool | None = None


def vector_literal(vec: np.ndarray) -> str:
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(
            get_settings().database_url,
            min_size=0,
            max_size=4,
            statement_cache_size=0,
        )
    return _pool


MATCH_SQL = """
select a.id::text as animal_id, a.name, max(1 - (e.vec <=> $1::vector)) as sim
from embeddings e
join animals a on a.id = e.animal_id
where e.owner = $2::uuid
group by a.id, a.name
order by sim desc
limit 5
"""

INSERT_SQL = """
insert into embeddings (animal_id, owner, vec, image_path)
values ($1::uuid, $2::uuid, $3::vector, $4)
"""

ANIMAL_OWNED_SQL = "select 1 from animals where id = $1::uuid and owner = $2::uuid"


async def match(vec: np.ndarray, owner: str) -> list[Candidate]:
    pool = await get_pool()
    rows = await pool.fetch(MATCH_SQL, vector_literal(vec), owner)
    return [Candidate(r["animal_id"], r["name"], float(r["sim"])) for r in rows]


async def animal_owned(animal_id: str, owner: str) -> bool:
    pool = await get_pool()
    return await pool.fetchval(ANIMAL_OWNED_SQL, animal_id, owner) is not None


async def insert_embeddings(
    animal_id: str, owner: str, vecs: np.ndarray, image_paths: list[str]
) -> int:
    pool = await get_pool()
    args = [
        (animal_id, owner, vector_literal(v), p)
        for v, p in zip(vecs, image_paths, strict=True)
    ]
    await pool.executemany(INSERT_SQL, args)
    return len(args)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && .venv/bin/pytest tests/test_db.py -v`
Expected: 3 PASS

- [ ] **Step 5: Commit**

```bash
git add server/app/db.py server/tests/test_db.py
git commit -m "feat(server): pooler-safe asyncpg access with exact-scan match SQL"
```

---

### Task 6: Storage upload

**Files:**
- Create: `server/app/storage.py`
- Test: `server/tests/test_storage.py`

- [ ] **Step 1: Write the failing tests**

`server/tests/test_storage.py`:
```python
from app.storage import object_path


def test_object_path_is_owner_prefixed():
    p = object_path("owner-uid", "animal-uid")
    assert p.startswith("owner-uid/animal-uid/")
    assert p.endswith(".jpg")


def test_object_paths_unique():
    a = object_path("o", "a")
    b = object_path("o", "a")
    assert a != b
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && .venv/bin/pytest tests/test_storage.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.storage'`

- [ ] **Step 3: Write storage.py**

`server/app/storage.py`:
```python
"""Supabase Storage uploads via the REST API (service-role key).
Bucket is private; paths are owner-prefixed so per-owner Storage policies
line up with the DB's RLS model."""
import uuid

import httpx

from .config import get_settings


def object_path(owner: str, animal_id: str) -> str:
    return f"{owner}/{animal_id}/{uuid.uuid4().hex}.jpg"


async def upload_jpeg(path: str, data: bytes) -> str:
    s = get_settings()
    url = f"{s.supabase_url}/storage/v1/object/{s.storage_bucket}/{path}"
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            url,
            content=data,
            headers={
                "Authorization": f"Bearer {s.supabase_service_role_key}",
                "Content-Type": "image/jpeg",
            },
        )
    resp.raise_for_status()
    return path
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && .venv/bin/pytest tests/test_storage.py -v`
Expected: 2 PASS

- [ ] **Step 5: Commit**

```bash
git add server/app/storage.py server/tests/test_storage.py
git commit -m "feat(server): Supabase Storage upload with owner-prefixed paths"
```

---

### Task 7: Schemas and FastAPI routes

**Files:**
- Create: `server/app/schemas.py`, `server/app/main.py`
- Create: `server/tests/conftest.py`
- Test: `server/tests/test_api.py`

Routes are tested with a fake embedder and monkeypatched db/storage — no model, no network.

- [ ] **Step 1: Write schemas.py** (data definitions; exercised by the route tests)

`server/app/schemas.py`:
```python
from pydantic import BaseModel


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool


class CandidateOut(BaseModel):
    animal_id: str
    name: str | None
    sim: float


class IdentifyResponse(BaseModel):
    decision: str  # "identified" | "unknown"
    animal_id: str | None = None
    name: str | None = None
    score: float
    margin: float
    candidates: list[CandidateOut]


class EnrollResponse(BaseModel):
    enrolled_count: int
```

- [ ] **Step 2: Write conftest.py with fakes**

`server/tests/conftest.py`:
```python
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.auth import current_uid
from app.main import app, state

TEST_UID = "11111111-1111-1111-1111-111111111111"


class FakeEmbedder:
    """Deterministic unit vectors; index i lights up dimension i."""

    def embed_batch(self, pil_images):
        out = np.zeros((len(pil_images), 2152), dtype=np.float32)
        for i in range(len(pil_images)):
            out[i, i] = 1.0
        return out


@pytest.fixture
def client():
    state["embedder"] = FakeEmbedder()
    app.dependency_overrides[current_uid] = lambda: TEST_UID
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c
    app.dependency_overrides.clear()
    state["embedder"] = None


@pytest.fixture
def jpeg_bytes():
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (64, 64), (128, 128, 128)).save(buf, format="JPEG")
    return buf.getvalue()
```

Note: `TestClient(app)` runs the lifespan, which would load the real model. `main.py` (Step 4) skips the load when `state["embedder"]` is already set — that's what makes this fixture model-free.

- [ ] **Step 3: Write the failing route tests**

`server/tests/test_api.py`:
```python
import numpy as np

import app.main as main_mod
from app.decision import Candidate
from tests.conftest import TEST_UID

ANIMAL = "22222222-2222-2222-2222-222222222222"


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "model_loaded": True}


def test_identify_identified(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        assert owner == TEST_UID
        return [Candidate(ANIMAL, "Bessie", 0.91), Candidate("other", None, 0.60)]

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    body = r.json()
    assert body["decision"] == "identified"
    assert body["animal_id"] == ANIMAL
    assert body["name"] == "Bessie"
    assert len(body["candidates"]) == 2


def test_identify_empty_gallery_is_unknown(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return []

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"


def test_identify_invalid_image_is_422(client):
    r = client.post("/identify", files={"image": ("m.jpg", b"not a jpeg", "image/jpeg")})
    assert r.status_code == 422


def test_enroll_batches_and_inserts(client, jpeg_bytes, monkeypatch):
    inserted = {}

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        return path

    async def fake_insert(animal_id, owner, vecs, image_paths):
        inserted["vecs"] = vecs
        inserted["paths"] = image_paths
        return len(image_paths)

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    monkeypatch.setattr(main_mod.db, "insert_embeddings", fake_insert)

    files = [("images", (f"m{i}.jpg", jpeg_bytes, "image/jpeg")) for i in range(3)]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 200
    assert r.json() == {"enrolled_count": 3}
    assert np.asarray(inserted["vecs"]).shape == (3, 2152)  # one batched pass
    assert len(inserted["paths"]) == 3


def test_enroll_unowned_animal_is_404(client, jpeg_bytes, monkeypatch):
    async def fake_animal_owned(animal_id, owner):
        return False

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 404


def test_missing_auth_is_401(jpeg_bytes, monkeypatch):
    from fastapi.testclient import TestClient

    from app.main import app, state

    monkeypatch.setenv("SKIP_MODEL_LOAD", "1")  # keep lifespan from loading the real model
    state["embedder"] = None
    with TestClient(app, raise_server_exceptions=False) as c:
        r = c.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 401  # auth dependency fires before the 503 model check
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd server && .venv/bin/pytest tests/test_api.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.main'`

- [ ] **Step 5: Write main.py**

`server/app/main.py`:
```python
import io
import os
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from PIL import Image

from . import db, storage
from .auth import current_uid
from .config import get_settings
from .decision import decide
from .schemas import CandidateOut, EnrollResponse, HealthResponse, IdentifyResponse

# Module-global model slot. Tests pre-populate it with a fake; production
# leaves it None and the lifespan loads the real model once per container.
state: dict = {"embedder": None}


@asynccontextmanager
async def lifespan(app: FastAPI):
    if state["embedder"] is None and os.environ.get("SKIP_MODEL_LOAD") != "1":
        from .miewid import MiewIDEmbedder

        state["embedder"] = MiewIDEmbedder(device="cpu")
    yield


app = FastAPI(title="CarniVision Embedder", lifespan=lifespan)


def _decode_jpegs(uploads: list[bytes]) -> list[Image.Image]:
    images = []
    for raw in uploads:
        try:
            images.append(Image.open(io.BytesIO(raw)).convert("RGB"))
        except Exception:
            raise HTTPException(status_code=422, detail="invalid image payload")
    return images


def _embed(images: list[Image.Image]):
    embedder = state["embedder"]
    if embedder is None:
        raise HTTPException(status_code=503, detail="model not loaded yet")
    try:
        return embedder.embed_batch(images)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"embedding failed: {exc}")


@app.get("/healthz", response_model=HealthResponse)
async def healthz():
    return HealthResponse(
        status="ok" if state["embedder"] is not None else "loading",
        model_loaded=state["embedder"] is not None,
    )


@app.post("/identify", response_model=IdentifyResponse)
async def identify(image: UploadFile = File(...), uid: str = Depends(current_uid)):
    pil = _decode_jpegs([await image.read()])
    vec = _embed(pil)[0]
    candidates = await db.match(vec, uid)
    s = get_settings()
    d = decide(candidates, s.sim_threshold, s.sim_margin)
    return IdentifyResponse(
        decision=d.decision,
        animal_id=d.animal_id,
        name=d.name,
        score=d.score,
        margin=d.margin,
        candidates=[CandidateOut(animal_id=c.animal_id, name=c.name, sim=c.sim) for c in candidates],
    )


@app.post("/enroll", response_model=EnrollResponse)
async def enroll(
    animal_id: str = Form(...),
    images: list[UploadFile] = File(...),
    uid: str = Depends(current_uid),
):
    if not await db.animal_owned(animal_id, uid):
        raise HTTPException(status_code=404, detail="animal not found for this user")
    raw = [await f.read() for f in images]
    pil = _decode_jpegs(raw)
    vecs = _embed(pil)  # ONE batched forward pass for all enrollment photos
    paths = []
    for data in raw:
        path = storage.object_path(uid, animal_id)
        await storage.upload_jpeg(path, data)
        paths.append(path)
    count = await db.insert_embeddings(animal_id, uid, vecs, paths)
    return EnrollResponse(enrolled_count=count)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd server && .venv/bin/pytest tests/test_api.py -v`
Expected: 7 PASS

- [ ] **Step 7: Run the whole non-slow suite**

Run: `cd server && .venv/bin/pytest -m "not slow and not integration" -v`
Expected: all PASS (config, decision, auth, db, storage, api)

- [ ] **Step 8: Commit**

```bash
git add server/app/schemas.py server/app/main.py server/tests/conftest.py server/tests/test_api.py
git commit -m "feat(server): FastAPI routes for healthz, identify, enroll"
```

---

### Task 8: Supabase schema + env example

**Files:**
- Create: `server/sql/schema.sql`
- Create: `server/.env.example`

- [ ] **Step 1: Write schema.sql**

`server/sql/schema.sql`:
```sql
-- CarniVision embedder schema. Apply once in the Supabase SQL editor.
create extension if not exists vector;

create table if not exists animals (
  id uuid primary key default gen_random_uuid(),
  owner uuid references auth.users not null,
  name text, tag text, breed text, sex text,
  birth_date date, status text,
  created_at timestamptz default now()
);

create table if not exists embeddings (
  id uuid primary key default gen_random_uuid(),
  animal_id uuid references animals(id) on delete cascade,
  owner uuid references auth.users not null,
  vec vector(2152) not null,
  image_path text,
  created_at timestamptz default now()
);

-- NO vector index, intentionally. pgvector caps HNSW/IVFFlat at 2000 dims
-- (MiewID is 2152); exact scan is ~0.2 ms at 1k vectors and 100% recall.
-- Upgrade path if an owner exceeds ~50k vectors:
--   create index on embeddings using hnsw ((vec::halfvec(2152)) halfvec_cosine_ops);

create index if not exists embeddings_owner_idx on embeddings (owner);
create index if not exists animals_owner_idx on animals (owner);

-- RLS: defense-in-depth. The service filters by owner explicitly in SQL;
-- these policies protect direct PostgREST access from the iOS app.
alter table animals enable row level security;
alter table embeddings enable row level security;

create policy "own animals" on animals
  for all using (owner = auth.uid()) with check (owner = auth.uid());
create policy "own embeddings" on embeddings
  for all using (owner = auth.uid()) with check (owner = auth.uid());
```

Manual step recorded for the operator (no SQL equivalent): create a **private** Storage bucket named `muzzles` in the Supabase dashboard.

- [ ] **Step 2: Write .env.example**

`server/.env.example`:
```
# Supabase project (Dashboard > Settings > API)
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_JWT_SECRET=<legacy JWT secret — Settings > API > JWT Settings>
SUPABASE_SERVICE_ROLE_KEY=<service_role key — Storage uploads only>

# Supavisor TRANSACTION pooler DSN — port 6543, NOT direct 5432
# (Dashboard > Settings > Database > Connection string > Transaction)
DATABASE_URL=postgresql://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres

# Open-set decision rule (defaults match the bakeoff; override to recalibrate)
SIM_THRESHOLD=0.7746
SIM_MARGIN=0.05
STORAGE_BUCKET=muzzles
```

- [ ] **Step 3: Commit**

```bash
git add server/sql/schema.sql server/.env.example
git commit -m "feat(server): Supabase schema with RLS and env template"
```

---

### Task 9: Integration test (real model + real DB, env-gated)

**Files:**
- Test: `server/tests/test_match.py`

Reproduces the spec's acceptance test: enroll real `BeefCattle_Muzzle_Individualized` animals, identify held-out images, assert rank-1 and the decision rule. Skips cleanly unless `INTEGRATION=1`, `DATABASE_URL`, and `TEST_OWNER_UID` (an existing auth.users uid — create a test user in Supabase Auth first; the FK requires it) are set. Storage upload is bypassed (DB-path only) so the test exercises embed → insert → match → decide.

- [ ] **Step 1: Write the integration test**

`server/tests/test_match.py`:
```python
"""Integration: real MiewID + real Supabase Postgres.

Run:
  INTEGRATION=1 TEST_OWNER_UID=<auth user uuid> \
  DATABASE_URL=postgresql://...pooler...:6543/postgres \
  .venv/bin/pytest tests/test_match.py -v

Enrolls the first 5 images of 3 animals, identifies a held-out 6th image of
each (expect: identified, correct animal), and one image of a never-enrolled
animal (expect: unknown). Cleans up its rows afterwards."""
import os
from pathlib import Path

import pytest
from PIL import Image

pytestmark = pytest.mark.integration

DATASET = Path(
    os.environ.get(
        "MUZZLE_DATASET",
        "/Volumes/Extreme SSD/Animal_Biometrics_System/BeefCattle_Muzzle_Individualized",
    )
)

if os.environ.get("INTEGRATION") != "1":
    pytest.skip("set INTEGRATION=1 to run", allow_module_level=True)


def animal_images(n_animals: int, n_images: int):
    dirs = sorted(d for d in DATASET.iterdir() if d.is_dir())[: n_animals]
    out = {}
    for d in dirs:
        imgs = sorted(d.glob("*.*"))[: n_images]
        assert len(imgs) >= n_images, f"{d.name} has fewer than {n_images} images"
        out[d.name] = imgs
    return out


@pytest.fixture(scope="module")
def embedder():
    from app.miewid import MiewIDEmbedder

    return MiewIDEmbedder(device="cpu")


async def test_enroll_then_identify_rank1(embedder):
    from app import db
    from app.config import get_settings
    from app.decision import decide

    owner = os.environ["TEST_OWNER_UID"]
    pool = await db.get_pool()
    data = animal_images(n_animals=4, n_images=6)
    names = list(data)
    enrolled, holdout = names[:3], names[3]
    settings = get_settings()
    animal_ids = {}

    try:
        for name in enrolled:
            animal_ids[name] = await pool.fetchval(
                "insert into animals (owner, name) values ($1::uuid, $2) returning id::text",
                owner, name,
            )
            train = [Image.open(p) for p in data[name][:5]]
            vecs = embedder.embed_batch(train)
            await db.insert_embeddings(
                animal_ids[name], owner, vecs, [f"test/{name}/{i}.jpg" for i in range(5)]
            )

        # Held-out 6th image of each enrolled animal → identified, correct.
        for name in enrolled:
            q = embedder.embed_batch([Image.open(data[name][5])])[0]
            d = decide(await db.match(q, owner), settings.sim_threshold, settings.sim_margin)
            assert d.decision == "identified", f"{name}: {d}"
            assert d.animal_id == animal_ids[name], f"{name} misidentified: {d}"

        # Never-enrolled animal → unknown.
        q = embedder.embed_batch([Image.open(data[holdout][0])])[0]
        d = decide(await db.match(q, owner), settings.sim_threshold, settings.sim_margin)
        assert d.decision == "unknown", f"open-set leak: {d}"
    finally:
        await pool.execute("delete from animals where owner = $1::uuid", owner)
```

- [ ] **Step 2: Run the integration test** (needs `.env` filled in, schema applied, test user created)

Run:
```bash
cd server && INTEGRATION=1 TEST_OWNER_UID=<uid> .venv/bin/pytest tests/test_match.py -v
```
Expected: 1 PASS (3 identified rank-1, 1 unknown). If Supabase isn't provisioned yet, defer this step to Task 11 and continue — the test must at minimum SKIP cleanly: `cd server && .venv/bin/pytest tests/test_match.py -v` → "skipped".

- [ ] **Step 3: Commit**

```bash
git add server/tests/test_match.py
git commit -m "test(server): env-gated integration test reproducing bakeoff rank-1"
```

---

### Task 10: Dockerfile + README

**Files:**
- Create: `server/Dockerfile`, `server/.dockerignore`, `server/README.md`

- [ ] **Step 1: Write the Dockerfile (weights baked in)**

`server/Dockerfile`:
```dockerfile
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    HF_HOME=/opt/hf

WORKDIR /srv

# Torch CPU wheels first (separate index), then the rest.
COPY requirements.txt .
RUN pip install --no-cache-dir torch==2.12.0 torchvision==0.27.0 \
      --index-url https://download.pytorch.org/whl/cpu \
 && pip install --no-cache-dir -r requirements.txt

# Bake the MiewID weights into the image: no startup download, cold start
# stays ~20-30 s, and runtime has no HuggingFace dependency.
RUN python -c "from huggingface_hub import snapshot_download; \
    snapshot_download('conservationxlabs/miewid-msv3')"
ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

COPY app ./app

ENV PORT=8080
CMD exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --workers 1
```

`server/.dockerignore`:
```
.venv
.env
tests
__pycache__
.pytest_cache
```

- [ ] **Step 2: Build and smoke-test locally**

Run:
```bash
cd server && docker build -t carnivision-embedder .
docker run --rm -p 8080:8080 --env-file .env carnivision-embedder &
sleep 60 && curl -s localhost:8080/healthz
```
Expected: `{"status":"ok","model_loaded":true}`. Stop the container afterwards (`docker ps` → `docker stop <id>`). If Docker isn't installed locally, skip this step — Cloud Build performs the build in Task 11.

- [ ] **Step 3: Write README.md**

`server/README.md`:
```markdown
# CarniVision Embedder API

Stateless FastAPI service: MiewID-msv3 muzzle embeddings (2152-d) + exact-scan
pgvector matching in Supabase. Spec:
`../docs/superpowers/specs/2026-06-11-carnivision-embedder-api-design.md`.

## Endpoints
- `GET  /healthz` — `{status, model_loaded}`; the iOS app pings this on launch to warm cold starts.
- `POST /identify` — multipart `image` (muzzle JPEG) + `Authorization: Bearer <supabase JWT>`.
- `POST /enroll` — multipart `images[]` + form `animal_id` + JWT.

## One-time Supabase setup
1. Run `sql/schema.sql` in the SQL editor.
2. Create a **private** Storage bucket named `muzzles`.
3. Copy `.env.example` → `.env` and fill in values (JWT secret, service-role
   key, **transaction pooler** DSN on port 6543).

## Local dev
    python3 -m venv .venv && .venv/bin/pip install torch==2.12.0 torchvision==0.27.0
    .venv/bin/pip install -r requirements-dev.txt
    .venv/bin/pytest -m "not slow and not integration"   # fast suite
    .venv/bin/pytest -m slow                              # real model (~206 MB download)
    INTEGRATION=1 TEST_OWNER_UID=<uid> .venv/bin/pytest tests/test_match.py
    .venv/bin/uvicorn app.main:app --reload

## Deploy (Cloud Run)
See `gcloud` commands in the repo plan
(`../docs/superpowers/plans/2026-06-11-embedder-api.md`, Task 11) — scale to
zero, `--cpu-boost`, secrets in Secret Manager.
```

- [ ] **Step 4: Commit**

```bash
git add server/Dockerfile server/.dockerignore server/README.md
git commit -m "feat(server): Dockerfile with baked-in weights + README"
```

---

### Task 11: Deploy to Cloud Run

**Files:** none (operations). Requires: `gcloud` CLI authenticated, a GCP project selected, Supabase schema applied (Task 8) and `.env` values at hand.

- [ ] **Step 1: Store secrets in Secret Manager**

```bash
gcloud services enable run.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com
printf '%s' "$SUPABASE_JWT_SECRET"       | gcloud secrets create supabase-jwt-secret --data-file=-
printf '%s' "$SUPABASE_SERVICE_ROLE_KEY" | gcloud secrets create supabase-service-role-key --data-file=-
printf '%s' "$DATABASE_URL"              | gcloud secrets create supabase-database-url --data-file=-
```
Expected: three `Created secret` confirmations.

- [ ] **Step 2: Deploy from source**

```bash
gcloud run deploy carnivision-embedder \
  --source server \
  --region europe-west1 \
  --memory 4Gi --cpu 2 \
  --min-instances 0 --max-instances 3 --cpu-boost \
  --concurrency 4 --timeout 120 \
  --allow-unauthenticated \
  --set-env-vars SUPABASE_URL=https://<project-ref>.supabase.co,STORAGE_BUCKET=muzzles \
  --set-secrets SUPABASE_JWT_SECRET=supabase-jwt-secret:latest,SUPABASE_SERVICE_ROLE_KEY=supabase-service-role-key:latest,DATABASE_URL=supabase-database-url:latest
```
Expected: build (~10–15 min, the weights bake is the slow layer) then `Service URL: https://carnivision-embedder-....run.app`.
`--allow-unauthenticated` is correct: app-level auth is the Supabase JWT, enforced by the service itself. `--concurrency 4` keeps CPU embeds from queueing behind each other on a 2-vCPU instance.

- [ ] **Step 3: Verify the live service**

```bash
URL=$(gcloud run services describe carnivision-embedder --region europe-west1 --format 'value(status.url)')
curl -s "$URL/healthz"                       # first hit: cold start, 20-30 s
curl -s -X POST "$URL/identify" -F image=@/tmp/test.jpg   # no JWT
```
Expected: healthz `{"status":"ok","model_loaded":true}`; identify without JWT → `{"detail":"missing bearer token"}` (401). Then a real end-to-end check with a JWT from the Supabase project (sign in a test user, take the access token):
```bash
curl -s -X POST "$URL/identify" -H "Authorization: Bearer $JWT" \
  -F image=@"/Volumes/Extreme SSD/Animal_Biometrics_System/AllDataset2/<any muzzle jpg>"
```
Expected: `{"decision":"unknown",...}` on an empty gallery, or an identification if the integration test's animals are enrolled.

- [ ] **Step 4: Run the integration test against production DB if not done in Task 9, then commit any doc tweaks**

```bash
git add -A && git diff --cached --quiet || git commit -m "docs(server): deployment notes"
```

---

## Self-review (performed at planning time)

- **Spec coverage:** healthz/identify/enroll (T7), decision rule + provenance (T2, T1 config), vendored embedder w/ 440×440 + L2 (T3), HS256 auth isolated in auth.py (T4), exact-scan owner-scoped match SQL + pooler + statement_cache_size=0 (T5), Storage owner-prefixed private bucket (T6, T8), schema + RLS + no-index rationale (T8), batched enroll forward pass (T7, asserted in test), baked weights + cpu-boost + min-instances 0 (T10, T11), integration test reproducing bakeoff (T9), error mapping 401/404/422/500/503 + empty gallery → unknown (T7).
- **Known judgment calls:** enroll with an `animal_id` the user doesn't own returns 404 (not in spec's error list; safest). `/identify` before model load returns 503 (spec's healthz contract covers the warmup path). Storage upload failures surface as 500 via httpx `raise_for_status` — acceptable for MVP.
