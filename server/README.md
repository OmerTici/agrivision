# AgriVision Embedder API

Stateless FastAPI service: MiewID-msv3 muzzle embeddings (2152-d) + exact-scan
pgvector matching in Supabase. Spec:
`../docs/superpowers/specs/2026-06-11-carnivision-embedder-api-design.md`.

## Endpoints
- `GET  /health` — `{status, model_loaded}`; the iOS app pings this on launch to warm cold starts.
- `POST /identify` — multipart `image` (muzzle JPEG) + `Authorization: Bearer <supabase JWT>`.
- `POST /enroll` — multipart `images[]` + form `animal_id` + JWT.

## One-time Supabase setup
1. Run `sql/schema.sql` in the SQL editor.
2. Create a **private** Storage bucket named `muzzles`.
3. Copy `.env.example` → `.env` and fill in values (service-role key,
   **transaction pooler** DSN on port 6543). Auth uses JWKS derived from
   SUPABASE_URL — no JWT secret needed.

## Local dev
    python3 -m venv .venv && .venv/bin/pip install torch==2.12.0 torchvision==0.27.0 --index-url https://download.pytorch.org/whl/cpu
    .venv/bin/pip install -r requirements-dev.txt
    .venv/bin/pytest -m "not slow and not integration"    # fast suite
    .venv/bin/pytest -m slow                               # real model (~206 MB download)
    INTEGRATION=1 TEST_OWNER_UID=<uid> DATABASE_URL=postgresql://user:pass@host:6543/postgres .venv/bin/pytest tests/test_match.py
    .venv/bin/uvicorn app.main:app --reload

## Deploy (Cloud Run — GCP project: agritrack, service separate from agritrack-app)
See the deploy commands in
`../docs/superpowers/plans/2026-06-11-embedder-api.md` (Task 11): new Cloud Run
service `carnivision-embedder`, scale to zero, `--cpu-boost`, secrets in
Secret Manager. Muzzle images live in Supabase Storage — the service does NOT
use the project's existing GCS media bucket.
