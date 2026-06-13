# Edit + Soft-Delete Animal — Design

**Date:** 2026-06-13
**Branch:** `ios-recognition`
**Status:** Approved, pending implementation plan

## Goal

Let users edit an animal's metadata and soft-delete (archive) an animal from the
iOS app. Soft-deleted animals disappear from the herd list and are excluded from
`/identify` matching, but their row, embeddings, and photos are retained so the
action is reversible via an undo toast.

## Decisions (from brainstorming)

- **Delete semantics:** soft delete (reversible), not hard delete.
- **Identify behavior:** soft-deleted animals are **excluded** from matching — a
  scan of an archived animal returns `unknown`.
- **Restore scope:** undo toast only ("Animal archived · Undo"). No separate
  archived-animals screen this iteration.
- **Edit fields:** all metadata — name, tag, breed, sex, birth date (same fields
  as the Add form). Muzzle embeddings/photos are not touched by edit.
- **Action entry points:** Edit and Delete buttons in `AnimalDetailView`, plus
  swipe-to-delete on the herd list row.

## Architecture

The iOS app already talks directly to Supabase Postgrest for `create()` and
`list()`. Edit, soft-delete, and restore follow the same path — Postgrest PATCH
calls governed by the existing owner RLS policy. **No new FastAPI endpoint.** The
only backend code change is the identify match query.

### 1. Data model & backend

- **Schema:** add `deleted_at timestamptz` (nullable, default `null`) to the
  `animals` table. `null` = active; a timestamp = archived. Chosen over the
  existing unused `status` text column because it records *when* and is the
  standard soft-delete pattern.
  - Update `server/sql/schema.sql`.
  - Apply a one-line migration (`alter table animals add column deleted_at
    timestamptz`) against the live Supabase DB.
- **Identify exclusion:** `match()` in `server/app/db.py` gains
  `and a.deleted_at is null` in its join so archived animals can't be matched.
- **RLS:** existing policy is `owner = auth.uid()`. Verify it permits
  `UPDATE ... WITH CHECK (owner = auth.uid())` so PATCH (edit / delete / restore)
  works; tighten if it only covers `USING`.
- **No delete event** is logged this round. The `events` table is server-write
  only and its `kind` check is `enroll|identify`; `deleted_at` is the audit
  trail.
- Photos and embeddings are **retained** in storage on soft-delete — this is
  what makes restore possible.

### 2. iOS — service layer (`CarniVision/Services/AnimalRepository.swift`)

- `update(animalID:name:tag:breed:sex:birthDate:)` → Postgrest PATCH on
  `animals?id=eq.{id}`.
- `softDelete(animalID:)` → PATCH `deleted_at = now()`.
- `restore(animalID:)` → PATCH `deleted_at = null`.
- `list()` → add `deleted_at=is.null` filter so archived animals drop out.

### 3. iOS — state (`HerdStore` in `CarniVision/Models/HerdData.swift`)

- `updateAnimal(...)` — replace the matching `Animal` in place.
- `removeAnimal(id:)` — optimistic removal from `animals`.
- `restoreAnimal(_:)` — re-insert an `Animal` for undo.
- All mutations are optimistic with rollback on repository failure.

### 4. iOS — UI

- **`AnimalDetailView`:** an **Edit** button presents the edit form; a **Delete**
  button shows a confirmation dialog, then `softDelete` and dismisses to the list.
- **Edit form:** new `EditAnimalScreen` reusing AddAnimal's field layout
  (name, tag, breed, sex, birth date), prefilled; Save → `update`. Factor the
  shared field UI out of `AddAnimalView` so Add and Edit don't drift.
- **List (`AnimalsScreen`):** swipe-to-delete on each `AnimalCard` row →
  `softDelete`.
- **Undo:** a lightweight reusable snackbar overlay — "Animal archived · Undo" —
  auto-dismissing after ~4s; Undo calls `restore` and `restoreAnimal`. SwiftUI
  has no native snackbar, so a small toast component is added.
- **Localization:** new en/tr strings for Edit, Delete, the confirmation dialog,
  and the undo toast.

### 5. Testing

- **Backend:** a `server/tests/test_match.py` case proving a soft-deleted animal
  is not returned by `match()`.
- **iOS:** `HerdStore` tests for `updateAnimal` / `removeAnimal` /
  `restoreAnimal`.

## Out of scope (YAGNI)

- Archived-animals screen / browse-deleted UI.
- Hard delete / purge of archived animals.
- Storage (photo) cleanup.
- A `delete` event kind.
