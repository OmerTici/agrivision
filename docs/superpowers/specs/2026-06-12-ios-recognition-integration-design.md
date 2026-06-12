# CarniVision iOS Recognition Integration — Design Spec

**Date:** 2026-06-12
**Status:** Approved design, pre-implementation
**Scope of this spec:** Sub-project 2 — wire the existing SwiftUI app to the deployed
embedder service (recognition path only). The embedder service itself (sub-project 1)
is specified in `2026-06-11-carnivision-embedder-api-design.md`.

## Goal

Connect the existing CarniVision iOS app to the live Cloud Run embedder so that a
farmer can enroll a cow's muzzle (5-photo guided burst + 1 full-body shot) and
identify animals in real time. Auth moves from a fake flag to real Supabase sessions.
No new ML work; no new server work; no persistence beyond what Supabase already holds.

## Out of scope (later sub-projects)

- Home / Animals tab backend sync (reads from Supabase, not in-memory HerdStore)
- Scan-history persistence
- Agritrack / Django integration
- Drone processing pipeline
- On-device CoreML conversion of MiewID

These are deferred per the biometric-registry direction established 2026-06-12. The
`RecognitionService` protocol boundary is designed so they can be added without
touching this sub-project's code.

## Architecture context

The embedder is already deployed and verified live:

```
iPhone (CarniVision SwiftUI)              Cloud Run (carnivision-embedder)
  SupabaseClientProvider (SDK)              europe-west1
  AuthService  ──── sign-in/JWT ──────▶    Supabase Auth (ES256 JWTs)
  AnimalRepository ─ insert ───────────▶   Supabase Postgres (animals table, RLS)
  CloudRunRecognitionService               FastAPI
    POST /identify  ──────────────────▶      embed → pgvector match → decision
    POST /enroll    ──────────────────▶      embed → Storage + embeddings insert
  warmUp: GET /health (app launch)
```

**Embedder base URL:** `https://carnivision-embedder-78377568014.europe-west1.run.app`

**Supabase project ref:** `xznmsmweefckkqjfepqs`

Supabase holds all state (animals, embeddings, Storage). The phone is the
collection + identify client; Cloud Run is stateless. This client contract is stable
regardless of the long-term biometric-registry direction.

## Current app state (facts from codebase exploration)

- SwiftUI, iOS 17 target; bundle `com.carnivision.app`; signing team `Z23895JP8U`.
- Auth: print-stub screens gated by a fake `@State` flag in `RootView`. Zero real
  networking. No SPM packages.
- Camera pipeline is **complete and unchanged by this spec**: `CameraView.swift`'s
  `CameraModel` runs AVCapture → `CowFaceDetectorService` (stability gating, auto/manual
  capture) → `MuzzleDetectorService.cropMuzzle` (≥ 0.25 confidence, 8% padding) →
  `@Published croppedMuzzle: UIImage` + `lastPhoto: UIImage` (full frame).
- `AddAnimalView` saves to in-memory `HerdStore` (EnvironmentObject).
- Localization via `LanguageManager.shared` keyed strings (EN/TR).

## New units

Each unit has one responsibility. Nothing in the existing camera pipeline changes.

### 1. `SupabaseClientProvider`

A singleton that vends the configured `SupabaseClient` from the
[`supabase-swift`](https://github.com/supabase/supabase-swift) package (add via SPM).

**Configuration source:** A `Config.plist` file (or xcconfig-driven `Info.plist` keys)
holds two values:

| Key | Value |
|-----|-------|
| `SUPABASE_URL` | `https://xznmsmweefckkqjfepqs.supabase.co` |
| `SUPABASE_ANON_KEY` | _(operator-supplied publishable key — see §Operator inputs)_ |

The service-role key **never ships in the app**. `SupabaseClientProvider` reads both
values at startup and constructs the client once.

### 2. `AuthService` (ObservableObject)

Wraps Supabase Auth. Exposes:

- `signIn(email: String, password: String) async throws`
- `signUp(email: String, password: String) async throws`
- `signOut() async throws`
- `@Published session: Session?` — SDK-persisted across launches
- `var accessToken: String?` — extracted from `session.accessToken`

`RootView` replaces its fake `@State` flag with `@StateObject var auth: AuthService`
and gates on `auth.session != nil`. Login and SignUp forms call the corresponding
methods directly; errors are surfaced inline via a `@Published errorMessage: String?`
(localized via `LanguageManager`).

### 3. `AnimalRepository`

Inserts a new animal row into the embedder project's `animals` table via `supabase-swift`.
RLS scopes the row to the authenticated user automatically (the SDK attaches the session
JWT on every request).

**Fields written** (mapped from `AddAnimalView`'s form):

| Supabase column | Source |
|-----------------|--------|
| `name` | animal name field |
| `tag` | ear tag field |
| `breed` | breed picker |
| `sex` | sex picker |
| `birth_date` | date picker (ISO-8601 date string) |

Returns the new row's `id` (UUID string), which is passed immediately into the
enrollment flow. `owner` must be set explicitly to the authenticated user's UID
(from `AuthService.session.user.id`) on insert — the schema declares it `not null`
with no default. `status` is omitted from the initial insert (nullable, set later
if needed).

### 4. `RecognitionService` protocol + `CloudRunRecognitionService`

**Protocol:**

```swift
protocol RecognitionService {
    func warmUp() async
    func identify(jpegData: Data) async throws -> IdentifyResult
    func enroll(animalID: String, muzzleJpegs: [Data], fullJpeg: Data?) async throws -> EnrollResult
}
```

**`IdentifyResult`** mirrors the server response:

```swift
struct IdentifyResult: Decodable {
    let decision: String      // "identified" | "unknown"
    let animalId: String?
    let name: String?
    let score: Double
    let margin: Double
    let candidates: [Candidate]
}
```

**`EnrollResult`** mirrors the server response:

```swift
struct EnrollResult: Decodable {
    let enrolledCount: Int
    let fullImagesStored: Int
}
```

**`CloudRunRecognitionService`** implementation:

- Base URL and access token injected at init (base URL from config; token from
  `AuthService`).
- All requests use `URLSession` with multipart/form-data encoding (written inline —
  no third-party HTTP library needed).
- Every request carries `Authorization: Bearer <accessToken>`.
- `warmUp()` fires `GET /health` and updates a `@Published` `isReady: Bool` flag;
  the caller shows "waking up recognizer" while `isReady == false`. First-call timeout:
  90 seconds (cold-start budget).
- JPEG quality: **0.85** (`UIImage.jpegData(compressionQuality: 0.85)`).
- Full-body photo: downscaled to ≤ 2048 px on the longest side before encoding,
  keeping uploads under 10 MB.
- Muzzle crops are sent at native crop size (small; no resize needed).

**Mock for previews / unit tests:** `MockRecognitionService` returns canned
`IdentifyResult` / `EnrollResult` values; SwiftUI previews inject it so the camera
view renders without a network call.

## Flows

### Enrollment (guided 5-photo burst)

1. Operator fills `AddAnimalView` form → taps **Save**.
2. `AnimalRepository.create(...)` inserts the animal row → returns `animalID`.
3. `AddAnimalView` transitions to `CameraView` in **enrollment mode**, passing
   `animalID`.
4. The existing stable-gate + crop pipeline runs unchanged. Each confirmed crop is
   appended to a local `[UIImage]` buffer. A **progress ring** overlay shows `N/5`
   until five crops are collected; no manual tap required (auto-capture reused).
5. After five muzzle crops, the camera pauses and prompts a **single full-body shot**
   ("Now capture the full animal"). The operator taps capture; `lastPhoto` is used.
6. All six images are JPEG-encoded (muzzle × 5 at 0.85; full-body downscaled ≤ 2048 px
   at 0.85) and sent in one `POST /enroll` call with `animal_id`.
7. On success: `HerdStore` marks the animal `muzzleRegistered = true` (local flag,
   this sub-project only). A success banner is shown.
8. On 502 / network error: retry UI offered. Re-enrollment adds new embedding rows
   (the server does not deduplicate); this is acceptable at MVP scale and noted in
   `HerdStore` by overwriting the flag only on success.

### Identify

1. Operator points camera at a muzzle.
2. Existing pipeline fires; `croppedMuzzle` is published.
3. `CameraView` encodes `croppedMuzzle` to JPEG (0.85) → calls `identify(jpegData:)`.
4. **Result card** overlaid on the live feed:
   - **Identified:** animal name + confidence score.
   - **Unknown:** "Animal not recognized" + **Enroll** button → jumps to enrollment
     flow (step 3 above, with a new `AnimalRepository.create` first if the animal
     has no row yet).
5. Detector confidence gate is **unchanged**: crops with confidence < 0.25 never reach
   the network.

## Error handling

| Condition | Behaviour |
|-----------|-----------|
| Cold start (first launch) | `warmUp()` fires on app launch; "waking up recognizer" spinner shown until `isReady`; 90 s timeout |
| Offline | Retry UI; animal browsing (HerdStore) remains available |
| 401 Unauthorized | SDK attempts silent token refresh; on failure → re-login prompt via `AuthService` |
| Enroll 502 / partial failure | Retry whole enroll (server is idempotent re: adding rows; duplicates acceptable at MVP) |
| Detector gate miss (< 0.25) | Reposition prompt shown on device; no server call made |
| Low score / margin | `decision: "unknown"` returned; never a confident wrong ID |

## Image encoding rules

| Image type | Compression | Max dimension | Notes |
|------------|-------------|---------------|-------|
| Muzzle crop | 0.85 | Native (small) | No resize needed |
| Full-body / full frame | 0.85 | 2048 px longest side | Keeps upload < 10 MB |

## Testing

### Unit tests (Swift)

- **`CloudRunRecognitionServiceTests`**: register a `MockURLProtocol` that intercepts
  requests; assert multipart field names (`image`, `images[]`, `animal_id`), presence
  of `Authorization: Bearer` header, and correct decoding of `IdentifyResult` /
  `EnrollResult` from fixture JSON.
- **`AuthServiceTests`**: inject a mocked `SupabaseClient` stub; assert that
  `signIn` updates `session`, `signOut` clears it, and auth errors propagate to
  `errorMessage`.

### On-device manual test plan

1. Build to iPhone (team `Z23895JP8U`).
2. Sign in with pilot account `pilot-test@carnivision.local`.
3. Enroll: create an animal, complete the 5-photo burst + full-body capture, confirm
   success banner.
4. Verify in Supabase dashboard: row in `animals`, 5 rows in `embeddings`, objects in
   `muzzles/{owner}/{animal_id}/muzzle/` and `/full/`.
5. Identify: point camera at the same muzzle → confirm name + score on result card.
6. Identify unknown: point camera at an unenrolled animal → confirm "unknown" card +
   Enroll button is tappable.
7. Offline test: disable network → confirm retry UI appears and HerdStore still
   renders the animal list.

### SwiftUI previews

Inject `MockRecognitionService` and a pre-seeded `AuthService` stub so all preview
scenarios render without network calls.

## Operator inputs required before build

| Input | Where used |
|-------|------------|
| Supabase **anon (publishable) key** (from Supabase dashboard → Project Settings → API) | `Config.plist` / xcconfig `SUPABASE_ANON_KEY` |
| Decision: **Sign Up enabled in-app?** (Supabase project signups are currently open) | `AuthService` — show/hide SignUp button accordingly |

Neither the service-role key nor the database password is needed by the app.
