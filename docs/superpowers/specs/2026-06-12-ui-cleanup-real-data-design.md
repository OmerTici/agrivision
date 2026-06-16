# UI Cleanup & Real Data Design

**Date:** 2026-06-12
**Status:** Approved pending user review
**Branch:** continues on `ios-recognition` (or a follow-up branch from it)

## Goal

Remove all demo/dummy data from the AgriVision iOS app and make every screen reflect reality: the user's enrolled animals (with the photos they actually took), recent enroll/identify actions, and search. Strip UI for data that has no backend (weights, health status, scan urgency, charts).

## Decisions (made with the user)

1. **Recent actions come from a server-side `events` table** — the embedder writes one row per enroll/identify. Real history, survives reinstall, shared later with the Django app and drones.
2. **Animal model stripped to essentials** — photo, name, tag, breed, sex, age, muzzle-registered badge, enrollment date. Weights, health status, charts, and scan-urgency are deleted everywhere.
3. **4-tab bar** — Home, Animals, Camera, Settings. Add-Animal becomes a **+** button on the Animals screen (presented as a sheet/fullscreen form).
4. **Reads go direct to Supabase (PostgREST + Storage) under RLS; writes with side effects stay in the embedder service.** The client holds no DB credentials — only the publishable key and the user's JWT; the database enforces owner scoping via Row Level Security. An RLS verification test proves cross-owner isolation.

## Architecture

```
iPhone app ──(JWT)──> Supabase PostgREST   : list animals (+embedding count), list events   [RLS]
iPhone app ──(JWT)──> Supabase Storage     : read own photos (uid-prefix read policy)       [RLS]
iPhone app ──(JWT)──> Cloud Run embedder   : POST /enroll, POST /identify (unchanged)
Cloud Run embedder ──(service role)──> Postgres: + insert into events on enroll/identify
```

## Backend changes (server/)

### 1. `events` table (append to `sql/schema.sql`, idempotent)

```sql
create table if not exists events (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null,
  kind        text not null check (kind in ('enroll', 'identify')),
  animal_id   uuid references animals(id),          -- null for unknown identify
  result      text not null check (result in ('enrolled', 'identified', 'unknown')),
  score       real,                                  -- top-1 similarity for identify, null for enroll
  created_at  timestamptz not null default now()
);
create index if not exists events_owner_created_idx on events (owner, created_at desc);

alter table events enable row level security;
-- owners read their own events; only the service role writes
create policy events_owner_select on events for select using (auth.uid() = owner);
```

(Use the same `drop policy if exists` + `create policy` idempotency pattern as the existing schema.)

### 2. Embedder writes events

- `POST /enroll` success → insert `(owner, 'enroll', animal_id, 'enrolled', null)`.
- `POST /identify` → insert `(owner, 'identify', matched_animal_or_null, 'identified'|'unknown', top1_score)`. Insert even for `unknown` (that is the interesting case for the feed). Event insert failures must not fail the API response — log and continue.

### 3. Storage read policy (owner reads own folder)

```sql
create policy muzzles_owner_read on storage.objects for select
  using (bucket_id = 'muzzles' and auth.uid()::text = (storage.foldername(name))[1]);
```

Object paths are `owner_uid/animal_id/{muzzle|full}/uuid.jpg`, so the first path segment is the owner uid.

### 4. Deploy

- Schema changes are applied by the user via `scripts/setup_supabase.py` (extended to include the new DDL), same flow as the original setup.
- Redeploy Cloud Run with the event-writing code; include `torch.backends.nnpack.set_flags(False)` at startup to silence the benign NNPACK warnings.

## iOS changes

### Data layer (Services/)

- **`AnimalRepository`** gains `list() async throws -> [AnimalRecord]` — PostgREST `GET /rest/v1/animals?select=*,embeddings(count)&order=created_at.desc`. `AnimalRecord`: `id, name, tag, breed, sex, birthDate, createdAt, embeddingCount`. `muzzleRegistered == embeddingCount > 0` (derived, not a locally flipped flag).
- **`EventRepository`** (new): `recent(limit: Int) async throws -> [EventRecord]` — `GET /rest/v1/events?select=*&order=created_at.desc&limit=N`. `EventRecord`: `id, kind, animalID?, result, score?, createdAt`.
- **`AnimalPhotoLoader`** (new): given `(ownerID, animalID)`, list `owner/animal/full/` in the `muzzles` bucket (fall back to `muzzle/` if no full image), download the first object via supabase-swift Storage, cache in memory (`NSCache`) and on disk (`Caches/` directory keyed by object path). Returns `UIImage?`; failures degrade to the existing initials avatar.
- **`HerdStore`** rewritten: no seed data. `@Published var animals: [Animal]`, `events: [ScanEvent]`, `isLoading`, `loadError: String?`. `load()` fetches animals + events concurrently; called on sign-in, on pull-to-refresh, and after a successful enrollment. Keeps `addAnimal` optimistic-insert behavior after `create()` succeeds, then reconciles on next `load()`.
- **Models** (`HerdData.swift`): `Animal` loses `weights`, `status`, `lastScanned`; gains `createdAt` and a real `UUID` id matching the DB row. `WeightEntry`, `AnimalStatus`, scan-urgency helpers, `herdTrend`, `monthlySeries`, and all seed data are deleted. `ScanEvent` is re-pointed at `EventRecord` + resolved animal name/photo.

### Screens (Views/Main/)

- **MainTabView:** remove the `.addAnimal` tab → 4 tabs. Trigger `store.load()` when authenticated.
- **HomeView:** header = time-based greeting + signed-in email (replaces hardcoded "Green Valley Farm"); remove the fake notification bell. Stats: 3 cards — animals, muzzle-registered, scans this week (events count). **Recent actions** section: event rows with photo thumbnail (via `AnimalPhotoLoader`), text like "Deneme 1 — enrolled", "Deneme 1 — identified (0.64)", "Unknown animal — no match", and relative time. Weight-trend chart and "needs scanning" sections deleted. Empty state when no events.
- **AnimalsView:** toolbar **+** button presents the Add Animal form. Cards: photo thumbnail (fallback initials avatar), name, tag, breed, age, registered badge. Search (name/tag/breed) and sex filter unchanged. Pull-to-refresh. Empty state: "No animals yet — tap + to add your first." Weight/last-scan elements removed from cards.
- **AnimalDetailView:** full photo header (tap = full-screen viewer optional/out of scope), info grid: tag, breed, sex, age, enrolled date, muzzle status. Charts and weight table deleted.
- **AddAnimalView:** presented from Animals **+**; weight field and the no-op "muzzle scanned" toggle removed. Save → repository.create → enrollment camera (unchanged flow); store refreshes after enrollment success.
- **CameraView (identify result card):** resolve `animal_id` → name + photo from `HerdStore` instead of showing a UUID. Unknown result card unchanged (offers enroll).
- **Localization:** new keys EN+TR for all new/changed strings; keys for deleted UI removed.

### Error & empty states

First load shows a spinner; network failure shows an inline banner with a Retry button (reuses `localizedRecognitionMessage`-style mapping). Every list has an empty state. Photo load failure silently falls back to the initials avatar.

## Testing

- Repository decoding tests (PostgREST JSON fixtures → `AnimalRecord`/`EventRecord`).
- `HerdStore` tests with mocked repositories: load success, load failure sets `loadError`, refresh-after-enroll.
- Event-row formatting tests (identified w/ score, unknown, enrolled; EN+TR).
- **RLS verification (integration, server/tests/):** create a second test user via the admin API; with user B's JWT, assert `GET /rest/v1/animals` and `GET /rest/v1/events` return 0 of user A's rows and a Storage read of one of A's object paths is denied.
- Server tests: events row written on enroll and identify (incl. unknown); event-insert failure does not fail the request.
- Existing 12 iOS tests updated for the slimmer models.

## Out of scope (explicitly deferred)

- Editing/deactivating animals from the app
- Notifications (the bell is removed, not reimplemented)
- Weight tracking, health status (return only when a real backend exists)
- Biometric-registry reshape, Django/Agritrack integration, drone pipelines
- Offline caching of animal lists (photos are cached; lists require connectivity)
