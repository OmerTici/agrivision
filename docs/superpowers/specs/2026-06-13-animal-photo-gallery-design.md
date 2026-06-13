# Animal Photo Gallery + Full-Photo CRUD — Design

**Date:** 2026-06-13
**Branch:** `ios-recognition`
**Status:** Approved, pending implementation

## Goal

Show all of an animal's stored photos in a gallery on the detail screen, and let
the user add and delete **full** (display) photos. Muzzle crops are shown
read-only — they are the biometric identity and must not be edited here.

## Decisions (from brainstorming)

- **CRUD scope:** add/delete apply to `full/` display photos only. `muzzle/`
  crops are shown read-only, badged "Muzzle ID". No muzzle CRUD, no embedding
  changes.
- **Add source:** system photo library via `PhotosPicker`.
- **Architecture:** iOS talks directly to Supabase Storage (consistent with
  animals CRUD). No new embedder endpoint, no recognition changes.
- **Viewer:** tapping a thumbnail opens a lightweight full-screen paged viewer.

## Architecture & data flow

The `muzzles` bucket already stores objects at
`{owner}/{animal_id}/{muzzle|full}/{uuid}.jpg`. The owner segment is the JWT sub
**lowercased**. Read is already permitted by the `"muzzles owner read"` SELECT
policy. We add two owner-scoped Storage RLS policies so the signed-in user can
write/delete only inside their own `{uid}/…` folder:

- `"muzzles owner insert"` — `for insert with check (bucket_id = 'muzzles' and auth.uid()::text = (storage.foldername(name))[1])`
- `"muzzles owner delete"` — `for delete using (bucket_id = 'muzzles' and auth.uid()::text = (storage.foldername(name))[1])`

Both wrapped in a `DO` block with the same `insufficient_privilege` fallback
notice as the existing SELECT policy (some projects require adding storage
policies via the Dashboard). Added to `server/sql/schema.sql` and a migration
file; **must be applied to the live Supabase DB before the feature works**
(same operational gate pattern as `deleted_at`).

Because `auth.uid()::text` is lowercase, iOS must upload to a **lowercased owner
segment**. The animal segment case is irrelevant to the policy (it only checks
segment 1).

## Components

### Storage service — `PhotoStoring` (added to `AnimalPhotoLoader.swift`)

A protocol seam for testability, with the live implementation on
`AnimalPhotoLoader` (it already owns the bucket + cache):

- `func listPhotos(ownerID:animalID:) async -> [GalleryPhoto]` — lists `full/`
  and `muzzle/` prefixes (both animal-id case variants), returns `full` first.
- `func loadImage(objectPath:) async -> UIImage?` — per-path download with the
  existing memory + disk cache.
- `func uploadFullPhoto(ownerID:animalID:image:) async throws -> String` —
  downscale to max ~1600px, JPEG ~0.85, upload to
  `{owner-lowercased}/{animalID}/full/{uuid}.jpg` via `upload(_:data:options:)`
  with `FileOptions(contentType: "image/jpeg", upsert: false)`. Returns the path.
- `func deletePhoto(objectPath:) async throws` — `remove(paths:)`. UI calls this
  only for `.full`.

`GalleryPhoto { id: String (objectPath), objectPath: String, kind: Kind }` with
`enum Kind { case full, muzzle }`.

### State — `AnimalGalleryModel` (`@MainActor ObservableObject`)

Lives in `AnimalPhotoLoader.swift` (or `AnimalsView.swift`). Injects a
`PhotoStoring`. Holds `@Published photos: [GalleryPhoto]`, `@Published isLoading`,
`@Published loadFailed`. Methods:

- `load(ownerID:animalID:)` — fetch list.
- `add(ownerID:animalID:image:)` — upload then append the new `.full` photo
  optimistically (or reload).
- `delete(_ photo:)` — guard `photo.kind == .full`; remove from storage then drop
  from `photos`.

### UI (added to `AnimalsView.swift`)

- `AnimalGallerySection` — a titled section placed in `AnimalDetailView` between
  `identityCard` and `infoGrid`. A horizontally-scrolling thumbnail row (or
  2-row grid): each thumbnail loads via `loadImage`. `.muzzle` thumbnails carry a
  small "Muzzle ID" badge and are not deletable. A leading **+** tile opens
  `PhotosPicker`. Tapping a thumbnail opens the viewer.
- `PhotoViewer` — full-screen paged `TabView` over the full-size images, with a
  close button; for `.full` photos a delete (trash) action with a confirmation
  dialog.
- Loading and empty states.

### Localization (en/tr)

`gallery.title`, `gallery.add`, `gallery.empty`, `gallery.muzzleBadge`,
`gallery.deleteTitle`, `gallery.deleteConfirm`, `gallery.loadError` (reuse
`common.cancel`).

## Testing

- `AnimalGalleryModel` unit tests via a mock `PhotoStoring`: load orders full
  before muzzle; `add` appends; `delete` removes a full photo; `delete` is a
  no-op on a muzzle photo.
- The Storage network calls (upload/list/remove/download) are not unit-tested —
  same convention as `AnimalRepository`; verified by build + manual smoke test.

## Out of scope (YAGNI)

- No cropping/editing/filters, no reordering, no set-as-cover.
- No muzzle add/delete, no embedding changes.
- No video. No multi-select delete.
