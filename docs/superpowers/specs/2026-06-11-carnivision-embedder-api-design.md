# CarniVision Embedder API — Design Spec

**Date:** 2026-06-11
**Status:** Approved design, pre-implementation
**Scope of this spec:** The FastAPI embedder service (sub-project 1). The iOS app
integration and Supabase schema are described as context; their detailed work is
separate sub-projects.

## Goal

Ship a fast MVP that adds real muzzle **recognition** (enroll + 1:N identify) to the
CarniVision iOS app, reusing the proven MiewID science from the
`Animal_Biometrics_System` bakeoff. The embedding model runs in a stateless FastAPI
service on Cloud Run; Supabase (Postgres + pgvector, Auth, Storage) holds all state.

This fills three gaps in the current CarniVision app: no muzzle matching, no
persistence, no real auth.

## Proven facts reused from the bakeoff (do not re-derive)

- **Model:** `conservationxlabs/miewid-msv3` (HuggingFace, `transformers`,
  `trust_remote_code=True`), MIT licensed, ~206 MB.
- **Embedding:** 2152-dim, **L2-normalized**.
- **Preprocessing:** Resize to **440×440**, ImageNet normalize
  (mean `[0.485,0.456,0.406]`, std `[0.229,0.224,0.225]`). Source:
  `Animal_Biometrics_System/cattle_id_bakeoff/scripts/models/miewid_msv3.py`.
- **Similarity:** cosine on unit vectors.
- **Decision rule:** `top1_sim ≥ 0.7746 AND (top1_sim − top2_sim) ≥ 0.05` →
  identified; otherwise → unknown (offer enroll). Tuned for ~0 false accepts.
  Threshold provenance: `suggested_threshold` (0.77457) in
  `cattle_id_bakeoff/results/miewid-msv3.json` — the bakeoff harness's tuned
  operating point (mean correct sim 0.88, mean wrong sim 0.67, mean margin 0.30).
- **Enrollment depth:** ~5 images/animal is the sweet spot (~96% rank-1).
- **Per-animal scoring:** group gallery vectors by animal, take **max** cosine.

## Architecture

```
iPhone (CarniVision)                  Cloud Run (FastAPI, stateless)      Supabase
  on-device YOLO face+muzzle crop  →  verify JWT                          Postgres+pgvector
  RecognitionService (protocol)       MiewID embed (2152-d, L2)      ──▶  animals, embeddings
    POST /identify, /enroll      ──▶  cosine match via pgvector SQL       Auth (JWT)
  reads animals directly from Supabase ◀───────────────────────────────  Storage (muzzle jpgs)
```

Cloud Run is **stateless**: it embeds and runs SQL; pgvector does the search;
Supabase holds all state. The app reads animal lists/profiles directly from Supabase
and calls Cloud Run only for the two ML actions.

## The FastAPI service (this sub-project)

**Location:** `carni_vision/server/` (subfolder of the iOS repo, per decision).

**Layout:**
```
server/
  app/
    main.py          FastAPI app + routes
    miewid.py        vendored embedder (copied from miewid_msv3.py, self-contained)
    db.py            Supabase/Postgres access (SQL for match + insert)
    auth.py          verify Supabase JWT
    config.py        env + threshold/margin defaults
    schemas.py       pydantic request/response models
  tests/
    test_embed.py    asserts 2152-d, L2-norm
    test_match.py    enroll + identify against BeefCattle_Muzzle sample, asserts rank-1
  Dockerfile
  requirements.txt
  .env.example
  README.md
```

**Model lifecycle:** loaded once at container startup (module-global), never per
request. `/healthz` returns ready state and is used by the app to warm cold starts.

### Endpoints

- `GET /healthz` → `{status, model_loaded}`. Warmup ping.
- `POST /identify` — multipart: muzzle JPEG; header: `Authorization: Bearer <supabase_jwt>`.
  Flow: verify JWT → embed → pgvector query (RLS-scoped to user) → group by animal,
  max sim → apply decision rule → return
  `{decision: "identified"|"unknown", animal_id?, name?, score, margin, candidates[]}`.
- `POST /enroll` — multipart: one or more muzzle JPEGs + `animal_id`; JWT header.
  Flow: verify JWT → **embed all images in one batched forward pass** (CPU embeds
  run ~1–3 s each; batching turns a 5-photo enroll from ~10 s into ~3–4 s) →
  upload images to Supabase Storage → insert `embeddings` rows →
  return `{enrolled_count}`.

Errors: invalid/missing JWT → 401; no animal_id on enroll → 422; embedding failure →
500 with a clear message; empty gallery on identify → `decision: "unknown"`.

### Matching SQL (executed by the service against Supabase)

```sql
select a.id, a.name, max(1 - (e.vec <=> $1)) as sim
from embeddings e join animals a on a.id = e.animal_id
where e.owner = $2            -- the authenticated user's uid from the JWT
group by a.id, a.name
order by sim desc limit 5;
```
Service then applies the decision rule (threshold/margin from `config`, env-overridable).

## Supabase schema (context — applied once to the existing project)

```sql
create extension if not exists vector;

create table animals (
  id uuid primary key default gen_random_uuid(),
  owner uuid references auth.users not null,
  name text, tag text, breed text, sex text,
  birth_date date, status text,
  created_at timestamptz default now()
);

create table embeddings (
  id uuid primary key default gen_random_uuid(),
  animal_id uuid references animals(id) on delete cascade,
  owner uuid references auth.users not null,
  vec vector(2152) not null,
  image_path text,
  created_at timestamptz default now()
);
-- NO vector index, intentionally. pgvector caps HNSW/IVFFlat indexes at 2000
-- dims (MiewID is 2152), and exact scan is the better choice anyway at MVP
-- scale: ~0.2 ms at 1k vectors, ~2 ms at 10k (measured in
-- cattle_id_bakeoff/results/serving_scale.json), 100% recall, owner-filtered.
-- Revisit with an HNSW index over `(vec::halfvec(2152)) halfvec_cosine_ops`
-- only if a single owner exceeds ~50k vectors.
```

**Auth model:** The service verifies the Supabase JWT itself via the project's legacy
**HS256 JWT secret** (decided 2026-06-11; simplest path, one env var). All verify
logic lives in `auth.py` so that when Supabase migrates the project to asymmetric
signing keys, the swap to JWKS verification is a one-file change. The service
extracts the user's `uid` and passes it explicitly as the `owner` filter in
every query (the `$2` in the matching SQL above; `owner = uid` on every insert). This is
the single source of truth for scoping. **RLS** is still enabled on both tables
(`owner = auth.uid()`) as defense-in-depth. Storage bucket `muzzles` is private with
per-owner path prefixes.

## Deployment

- Dockerfile: `python:3.11-slim`, torch (CPU), transformers; copy `app/`.
  **Bake the MiewID weights into the image** (download from HF at build time, not at
  container startup) — this is what keeps cold starts at ~20–30 s instead of 60 s+
  and removes the HF-availability dependency at runtime.
- Cloud Run: `--memory 4Gi --cpu 2 --min-instances 0 --cpu-boost` (decided
  2026-06-11: scale-to-zero + app-driven `/healthz` warmup; CPU boost is free at
  idle and halves cold-start time). Option `--min-instances 1` (~$15–30/mo) can be
  flipped on during pilot weeks if cold starts annoy in practice.
- **Postgres connections go through the Supavisor transaction-mode pooler (port
  6543)**, never direct 5432 — Cloud Run scales horizontally and direct connections
  would exhaust Supabase's connection slots. Small per-instance pool (e.g. 2–5).
- Secrets via env: Supabase URL, **JWT secret** (verify incoming JWTs), pooled
  Postgres connection string, service-role key (Storage uploads). `.env.example`
  documents all.

## iOS integration (context — separate sub-project)

- New `RecognitionService` protocol + `CloudRunRecognitionService` (swappable for future
  on-device CoreML).
- `CameraView`: after existing on-device muzzle crop → `identify(jpeg)` → result card.
- `AddAnimalView`: capture-5 enrollment → `enroll(animal, jpegs)`.
- Supabase Swift SDK wires existing Login/SignUp to real Auth; `AnimalsView`/`HomeView`
  read from Supabase instead of in-memory `HerdStore`.
- Info.plist: Cloud Run URL + ATS; send JWT on every service call.

## Error handling

- **Cold start:** app shows "waking up recognizer", fires `/healthz` on launch, 90 s
  timeout on first call.
- **No/blurry muzzle:** on-device detector gates (confidence < 0.25 → reposition); never
  call the server without a valid crop.
- **Low confidence/margin:** → unknown, never a confident wrong ID.
- **Offline:** animal browsing from cached Supabase; enroll/identify need connectivity.

## Testing

- **Embedder unit test:** output is 2152-d and L2-normalized.
- **Integration test:** enroll a handful of `BeefCattle_Muzzle_Individualized` animals,
  identify held-out images, assert rank-1 and the decision rule reproduce bakeoff-level
  results.
- **iOS:** mock `RecognitionService` for UI tests.

## Out of scope (YAGNI for MVP)

- On-device CoreML conversion of MiewID (future phase 2, behind the same
  `RecognitionService` interface).
- Vector indexing / dedicated vector DB (exact pgvector scan is the deliberate
  choice at this scale — see schema note; halfvec HNSW is the documented upgrade path).
- Model fine-tuning / ArcFace head.
- Multi-farm org management beyond per-user RLS.
