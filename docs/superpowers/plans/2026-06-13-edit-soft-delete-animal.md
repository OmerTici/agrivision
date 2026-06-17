# Edit + Soft-Delete Animal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users edit an animal's metadata and soft-delete (archive) an animal from the iOS app, with archived animals excluded from `/identify` matching and recoverable via an undo toast.

**Architecture:** iOS talks directly to Supabase PostgREST for edit/delete/restore (same path as today's `create()`/`list()`), governed by the existing owner RLS policy (`for all ... with check (owner = auth.uid())` — UPDATE already permitted, no policy change). The only backend code change is the identify match query, which gains a `deleted_at is null` filter. Soft-delete sets `animals.deleted_at`; embeddings and photos are retained so restore is possible.

**Tech Stack:** FastAPI + asyncpg + pgvector (server), pytest (`-m "not slow and not integration"`, env-gated `integration` marker), SwiftUI + supabase-swift 2.47.0 (iOS), XCTest.

**iOS file-placement constraint:** The app target uses old-style PBXGroup — new app-target `.swift` files need 4-point manual pbxproj registration. To avoid that, **all new SwiftUI types in this plan are added to existing files** (`AddAnimalView.swift`, `AnimalsView.swift`). `AgriVisionTests` is filesystem-synchronized, so test edits to existing test files need no registration.

**Test commands:**
```bash
# iOS build
xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# iOS tests
xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
# Server fast suite (run from server/)
.venv/bin/pytest tests/ -m "not slow and not integration" -q
```

---

## File Structure

- `server/sql/schema.sql` — add `deleted_at` column to `animals` (modify).
- `server/sql/migrations/2026-06-13-add-animals-deleted-at.sql` — live-DB migration (create).
- `server/app/db.py` — `MATCH_SQL` excludes soft-deleted animals (modify).
- `server/tests/test_db.py` — assert the new filter is in `MATCH_SQL` (modify).
- `AgriVision/Services/AnimalRepository.swift` — `update`, `softDelete`, `restore`; `list()` filter (modify).
- `AgriVision/Models/HerdData.swift` — `HerdStore.updateAnimal/removeAnimal/restoreAnimal/clearRecentlyArchived` + `recentlyArchived` (modify).
- `AgriVisionTests/HerdStoreTests.swift` — store mutation tests (modify).
- `AgriVision/Views/Main/AddAnimalView.swift` — extract `AnimalDetailsForm`; add `EditAnimalScreen` (modify).
- `AgriVision/Views/Main/AnimalsView.swift` — Edit/Delete buttons in `AnimalDetailView`, swipe-to-delete in list, `UndoToast` (modify).
- `AgriVision/Models/Localization.swift` — en/tr strings for edit/delete/undo (modify).

---

## Task 1: Schema — add `deleted_at` column

**Files:**
- Modify: `server/sql/schema.sql:4-10`
- Create: `server/sql/migrations/2026-06-13-add-animals-deleted-at.sql`

- [ ] **Step 1: Add the column to schema.sql**

Replace the `animals` table definition (lines 4-10) with:

```sql
create table if not exists animals (
  id uuid primary key default gen_random_uuid(),
  owner uuid references auth.users not null,
  name text, tag text, breed text, sex text,
  birth_date date, status text,
  deleted_at timestamptz,
  created_at timestamptz default now()
);
```

- [ ] **Step 2: Create the live-DB migration file**

Create `server/sql/migrations/2026-06-13-add-animals-deleted-at.sql`:

```sql
-- Soft-delete support for animals. Run once in the Supabase SQL editor.
-- deleted_at IS NULL = active; a timestamp = archived (hidden from herd list
-- and excluded from /identify matching). Embeddings/photos are retained.
alter table animals add column if not exists deleted_at timestamptz;
```

- [ ] **Step 3: Commit**

```bash
git add server/sql/schema.sql server/sql/migrations/2026-06-13-add-animals-deleted-at.sql
git commit -m "feat(db): add animals.deleted_at for soft delete"
```

> **NOTE for the human operator:** This migration must be applied to the live Supabase DB (`alter table animals add column if not exists deleted_at timestamptz;`) before the iOS soft-delete ships, or PATCH calls setting `deleted_at` will fail. The `match()` change in Task 2 also requires the column to exist.

---

## Task 2: Exclude soft-deleted animals from `match()`

**Files:**
- Modify: `server/app/db.py:41-49`
- Test: `server/tests/test_db.py`

- [ ] **Step 1: Write the failing test**

Add to `server/tests/test_db.py` (after `test_match_sql_is_owner_scoped_exact_scan`):

```python
def test_match_sql_excludes_soft_deleted():
    # Archived animals (deleted_at set) must never be returned by identify.
    assert "a.deleted_at is null" in MATCH_SQL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && .venv/bin/pytest tests/test_db.py::test_match_sql_excludes_soft_deleted -q`
Expected: FAIL — `assert 'a.deleted_at is null' in MATCH_SQL`.

- [ ] **Step 3: Add the filter to MATCH_SQL**

In `server/app/db.py`, replace `MATCH_SQL` (lines 41-49) with:

```python
MATCH_SQL = """
select a.id::text as animal_id, a.name, max(1 - (e.vec <=> $1::vector)) as sim
from embeddings e
join animals a on a.id = e.animal_id and a.deleted_at is null
where e.owner = $2::uuid
group by a.id, a.name
order by sim desc
limit 5
"""
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && .venv/bin/pytest tests/test_db.py -q`
Expected: PASS (all `test_db.py` tests).

- [ ] **Step 5: Commit**

```bash
git add server/app/db.py server/tests/test_db.py
git commit -m "feat(match): exclude soft-deleted animals from identify"
```

---

## Task 3: Repository — `update`, `softDelete`, `restore`, and `list()` filter

**Files:**
- Modify: `AgriVision/Services/AnimalRepository.swift`

No unit test: these methods make live PostgREST network calls (the existing `create()`/`list()` are verified by build + integration, not unit-mocked). Verification is a successful build. The store-level logic that IS unit-tested lives in Task 4.

- [ ] **Step 1: Add the `deleted_at=is.null` filter to `list()`**

In `AnimalRepository.swift`, in `list()`, insert the `.is(...)` filter between `.select(...)` and `.order(...)`:

```swift
    func list() async throws -> [AnimalRecord] {
        let response = try await client
            .from("animals")
            .select("*, embeddings(count)")
            .is("deleted_at", value: nil)   // active animals only (deleted_at is null)
            .order("created_at", ascending: false)
            .execute()
        return try JSONDecoder().decode([AnimalRecord].self, from: response.data)
    }
```

- [ ] **Step 2: Add update/softDelete/restore payload types**

In `AnimalRepository.swift`, after the `AnimalInsert` struct (around line 127), add:

```swift
    /// Row payload for editing an animal's metadata (PATCH /animals?id=eq.{id}).
    private struct AnimalUpdate: Encodable {
        let name: String
        let tag: String
        let breed: String
        let sex: String
        let birth_date: String
    }

    /// PATCH payload that sets deleted_at to a timestamp (soft delete).
    private struct SoftDeletePayload: Encodable {
        let deleted_at: String
    }

    /// PATCH payload that explicitly sets deleted_at to JSON null (restore).
    /// Synthesized Encodable would omit a nil optional; encodeNil forces null.
    private struct RestorePayload: Encodable {
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeNil(forKey: .deletedAt)
        }
        enum CodingKeys: String, CodingKey {
            case deletedAt = "deleted_at"
        }
    }

    private static let timestampFormatter = ISO8601DateFormatter()
```

- [ ] **Step 3: Add the three methods**

In `AnimalRepository.swift`, after `list()` (before the closing brace of `struct AnimalRepository`), add:

```swift
    /// Edits an animal's metadata. RLS scopes the PATCH to the owner.
    func update(
        animalID: String,
        name: String,
        tag: String,
        breed: String,
        sex: AnimalSex,
        birthDate: Date
    ) async throws {
        let payload = AnimalUpdate(
            name: name,
            tag: tag,
            breed: breed,
            sex: sex.rawValue.lowercased(),
            birth_date: Self.dateFormatter.string(from: birthDate)
        )
        try await client
            .from("animals")
            .update(payload)
            .eq("id", value: animalID)
            .execute()
    }

    /// Soft-deletes (archives) an animal by stamping deleted_at. Embeddings and
    /// photos are retained; the row drops out of list() and identify matching.
    func softDelete(animalID: String) async throws {
        let payload = SoftDeletePayload(
            deleted_at: Self.timestampFormatter.string(from: Date())
        )
        try await client
            .from("animals")
            .update(payload)
            .eq("id", value: animalID)
            .execute()
    }

    /// Restores a soft-deleted animal by clearing deleted_at (undo).
    func restore(animalID: String) async throws {
        try await client
            .from("animals")
            .update(RestorePayload())
            .eq("id", value: animalID)
            .execute()
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

> If `.is("deleted_at", value: nil)` fails to resolve, fall back to `.filter("deleted_at", operator: "is", value: "null")` — both emit `deleted_at=is.null`.

- [ ] **Step 5: Commit**

```bash
git add AgriVision/Services/AnimalRepository.swift
git commit -m "feat(ios): repository update/softDelete/restore + list excludes deleted"
```

---

## Task 4: HerdStore — `updateAnimal`, `removeAnimal`, `restoreAnimal`

**Files:**
- Modify: `AgriVision/Models/HerdData.swift`
- Test: `AgriVisionTests/HerdStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `AgriVisionTests/HerdStoreTests.swift` (inside `HerdStoreTests`, after `testAddAnimalInsertsOptimisticallyAtTop`):

```swift
    func testUpdateAnimalReplacesFieldsInPlace() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 5)]
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())
        await store.load()

        store.updateAnimal(id: animalID, name: "Renamed", tag: "TR-9999",
                           breed: "Angus", sex: .male, birthDate: nil)

        XCTAssertEqual(store.animals.count, 1)
        XCTAssertEqual(store.animals[0].name, "Renamed")
        XCTAssertEqual(store.animals[0].tag, "TR-9999")
        XCTAssertEqual(store.animals[0].breed, "Angus")
        XCTAssertEqual(store.animals[0].sex, .male)
        XCTAssertTrue(store.animals[0].muzzleRegistered)  // derived flag preserved
    }

    func testRemoveAnimalDeletesAndRecordsRecentlyArchived() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 5)]
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())
        await store.load()

        store.removeAnimal(id: animalID)

        XCTAssertTrue(store.animals.isEmpty)
        XCTAssertEqual(store.recentlyArchived?.id, animalID)
    }

    func testRestoreAnimalReinsertsAndClearsRecentlyArchived() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 5)]
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())
        await store.load()
        let archived = store.animals[0]
        store.removeAnimal(id: animalID)

        store.restoreAnimal(archived)

        XCTAssertEqual(store.animals.count, 1)
        XCTAssertEqual(store.animals[0].id, animalID)
        XCTAssertNil(store.recentlyArchived)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:AgriVisionTests/HerdStoreTests`
Expected: FAIL to compile — `value of type 'HerdStore' has no member 'updateAnimal' / 'removeAnimal' / 'restoreAnimal' / 'recentlyArchived'`.

- [ ] **Step 3: Add the published property and methods**

In `HerdData.swift`, add the published property after `loadError` (line 149):

```swift
    /// The most recently archived animal, surfaced as an undo toast in the herd
    /// list. Set by removeAnimal; cleared by restoreAnimal or the toast timeout.
    @Published var recentlyArchived: Animal?
```

Then add these methods to `HerdStore` (after `addAnimal(id:...)`, before `loadErrorMessage`):

```swift
    /// Optimistic in-place edit after AnimalRepository.update succeeds. The
    /// derived muzzleRegistered flag is untouched (embeddings are unaffected).
    func updateAnimal(
        id: UUID, name: String, tag: String, breed: String,
        sex: AnimalSex, birthDate: Date?
    ) {
        guard let idx = animals.firstIndex(where: { $0.id == id }) else { return }
        animals[idx].name = name
        animals[idx].tag = tag
        animals[idx].breed = breed
        animals[idx].sex = sex
        animals[idx].birthDate = birthDate
    }

    /// Optimistic removal after AnimalRepository.softDelete succeeds. Stashes the
    /// removed animal in recentlyArchived so the herd list can offer undo.
    func removeAnimal(id: UUID) {
        guard let idx = animals.firstIndex(where: { $0.id == id }) else { return }
        recentlyArchived = animals.remove(at: idx)
    }

    /// Re-inserts a previously archived animal (undo), keeping created_at order.
    func restoreAnimal(_ animal: Animal) {
        if !animals.contains(where: { $0.id == animal.id }) {
            animals.append(animal)
            animals.sort { $0.createdAt > $1.createdAt }
        }
        if recentlyArchived?.id == animal.id { recentlyArchived = nil }
    }

    /// Dismisses the undo toast without restoring (timeout / manual close).
    func clearRecentlyArchived() {
        recentlyArchived = nil
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:AgriVisionTests/HerdStoreTests`
Expected: PASS (all HerdStoreTests, including the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add AgriVision/Models/HerdData.swift AgriVisionTests/HerdStoreTests.swift
git commit -m "feat(ios): HerdStore update/remove/restore animal with undo state"
```

---

## Task 5: Localization — edit/delete/undo strings (en + tr)

**Files:**
- Modify: `AgriVision/Models/Localization.swift`

- [ ] **Step 1: Add English strings**

In `Localization.swift`, in the English dictionary after `"add.saved": "Animal added to herd",` (line 143), add:

```swift
            "edit.title": "Edit Animal",
            "edit.subtitle": "Update this animal's details",
            "edit.save": "Save Changes",
            "detail.edit": "Edit",
            "detail.delete": "Delete Animal",
            "delete.confirmTitle": "Delete this animal?",
            "delete.confirmBody": "It will be archived and removed from your herd. You can undo this right after.",
            "delete.confirm": "Delete",
            "common.cancel": "Cancel",
            "undo.archived": "Animal archived",
            "undo.action": "Undo",
```

- [ ] **Step 2: Add Turkish strings**

In `Localization.swift`, in the Turkish dictionary, after the `"add.saved"` Turkish entry (the line near 342, value `"Hayvan sürüye eklendi"` or similar — locate `"add.saved"` in the `tr` block), add:

```swift
            "edit.title": "Hayvanı Düzenle",
            "edit.subtitle": "Bu hayvanın bilgilerini güncelle",
            "edit.save": "Değişiklikleri Kaydet",
            "detail.edit": "Düzenle",
            "detail.delete": "Hayvanı Sil",
            "delete.confirmTitle": "Bu hayvan silinsin mi?",
            "delete.confirmBody": "Arşivlenip sürünüzden kaldırılacak. Hemen ardından geri alabilirsiniz.",
            "delete.confirm": "Sil",
            "common.cancel": "İptal",
            "undo.archived": "Hayvan arşivlendi",
            "undo.action": "Geri al",
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add AgriVision/Models/Localization.swift
git commit -m "feat(ios): add edit/delete/undo strings (en/tr)"
```

---

## Task 6: Extract `AnimalDetailsForm` and refactor AddAnimalScreen

This extracts the shared metadata fields (name, tag, breed, sex, birth date) so Edit and Add render identical inputs. Weight and the muzzle-scan card stay Add-only.

**Files:**
- Modify: `AgriVision/Views/Main/AddAnimalView.swift`

- [ ] **Step 1: Add the shared `AnimalDetailsForm` view**

In `AddAnimalView.swift`, after the `FormField` struct (after line 311, before `extension String: Identifiable`), add:

```swift
/// Shared metadata inputs for Add and Edit: name, tag, breed, sex, birth date.
/// Weight and muzzle scanning are Add-only and stay in AddAnimalScreen.
struct AnimalDetailsForm: View {
    @Binding var name: String
    @Binding var tag: String
    @Binding var breed: String
    @Binding var sex: AnimalSex
    @Binding var birthDate: Date
    @ObservedObject private var lang = LanguageManager.shared

    static let breeds = ["Holstein", "Angus", "Simmental", "Jersey", "Hereford", "Charolais", "Limousin"]

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AgriColors.appBackground)
    }

    var body: some View {
        VStack(spacing: 16) {
            FormField(label: lang.t("add.name"), placeholder: lang.t("add.namePh"), text: $name)
            FormField(label: lang.t("add.tag"), placeholder: lang.t("add.tagPh"), text: $tag)

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.breed"))
                    .font(AgriFont.semibold(13))
                    .foregroundStyle(AgriColors.purpleDark)
                Menu {
                    ForEach(Self.breeds, id: \.self) { option in
                        Button(option) { breed = option }
                    }
                } label: {
                    HStack {
                        Text(breed)
                            .font(AgriFont.regular(15))
                            .foregroundStyle(AgriColors.purpleDark)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgriColors.tabInactive)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldBackground)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("detail.sex"))
                    .font(AgriFont.semibold(13))
                    .foregroundStyle(AgriColors.purpleDark)
                HStack(spacing: 8) {
                    ForEach(AnimalSex.allCases) { option in
                        Button {
                            sex = option
                        } label: {
                            Text(lang.t(option.key))
                                .font(AgriFont.semibold(14))
                                .foregroundStyle(sex == option ? .white : AgriColors.purple)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(sex == option ? AgriColors.purple : AgriColors.purple.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.dob"))
                    .font(AgriFont.semibold(13))
                    .foregroundStyle(AgriColors.purpleDark)
                HStack {
                    DatePicker("", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .tint(AgriColors.purple)
                        .environment(\.locale, lang.language.locale)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(fieldBackground)
            }
        }
    }
}
```

- [ ] **Step 2: Replace AddAnimalScreen's `detailsCard` to use the shared form**

In `AddAnimalView.swift`, replace the `detailsCard` computed property (lines 110-198) with:

```swift
    private var detailsCard: some View {
        VStack(spacing: 16) {
            AnimalDetailsForm(name: $name, tag: $tag, breed: $breed, sex: $sex, birthDate: $birthDate)

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.weight"))
                    .font(AgriFont.semibold(13))
                    .foregroundStyle(AgriColors.purpleDark)
                HStack {
                    TextField(lang.t("add.weightPh"), text: $weightText)
                        .font(AgriFont.regular(15))
                        .foregroundStyle(AgriColors.purpleDark)
                        .keyboardType(.decimalPad)
                    Text("kg")
                        .font(AgriFont.semibold(14))
                        .foregroundStyle(AgriColors.tabInactive)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(fieldBackground)
            }
        }
        .agriCard()
    }
```

Then delete the now-unused `breeds` constant (line 24) from `AddAnimalScreen` — the breed list lives in `AnimalDetailsForm.breeds`. (Leave `fieldBackground` on AddAnimalScreen: the weight field still uses it.)

- [ ] **Step 3: Build to verify the Add flow still compiles**

Run: `xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add AgriVision/Views/Main/AddAnimalView.swift
git commit -m "refactor(ios): extract AnimalDetailsForm shared by Add and Edit"
```

---

## Task 7: EditAnimalScreen + Edit button in AnimalDetailView

**Files:**
- Modify: `AgriVision/Views/Main/AddAnimalView.swift` (add `EditAnimalScreen`)
- Modify: `AgriVision/Views/Main/AnimalsView.swift` (detail view edit entry)

- [ ] **Step 1: Add `EditAnimalScreen`**

In `AddAnimalView.swift`, after the `AnimalDetailsForm` struct, add:

```swift
/// Edits an existing animal's metadata. Presented as a sheet from
/// AnimalDetailView. On save: PATCH via repository, then optimistic store
/// update, then dismiss. The onSaved closure lets the detail view refresh.
struct EditAnimalScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    private let repository = AnimalRepository()
    let animalID: UUID
    /// Called after a successful save with the new field values so the detail
    /// view can update its locally displayed copy.
    let onSaved: (_ name: String, _ tag: String, _ breed: String, _ sex: AnimalSex, _ birthDate: Date) -> Void

    @State private var name: String
    @State private var tag: String
    @State private var breed: String
    @State private var sex: AnimalSex
    @State private var birthDate: Date
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        animal: Animal,
        onSaved: @escaping (_ name: String, _ tag: String, _ breed: String, _ sex: AnimalSex, _ birthDate: Date) -> Void
    ) {
        self.animalID = animal.id
        self.onSaved = onSaved
        _name = State(initialValue: animal.name)
        _tag = State(initialValue: animal.tag)
        _breed = State(initialValue: animal.breed)
        _sex = State(initialValue: animal.sex)
        _birthDate = State(initialValue: animal.birthDate ?? Date())
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !tag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lang.t("edit.title"))
                        .font(AgriFont.bold(24))
                        .foregroundStyle(AgriColors.purpleDark)
                    Text(lang.t("edit.subtitle"))
                        .font(AgriFont.regular(13))
                        .foregroundStyle(AgriColors.tabInactive)
                }

                AnimalDetailsForm(name: $name, tag: $tag, breed: $breed, sex: $sex, birthDate: $birthDate)
                    .agriCard()

                if let saveError {
                    Text(saveError)
                        .font(AgriFont.regular(13))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: save) {
                    Text(isSaving ? lang.t("camera.enroll.submitting") : lang.t("edit.save"))
                        .font(AgriFont.bold(16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(canSave && !isSaving ? AgriColors.purple : AgriColors.purple.opacity(0.35))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, AgriLayout.tabBarClearance)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AgriColors.appBackground)
    }

    private func save() {
        saveError = nil
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        let chosenBreed = breed
        let chosenSex = sex
        let chosenDOB = birthDate

        Task {
            do {
                try await repository.update(
                    animalID: animalID.uuidString,
                    name: trimmedName, tag: trimmedTag, breed: chosenBreed,
                    sex: chosenSex, birthDate: chosenDOB
                )
                await MainActor.run {
                    store.updateAnimal(
                        id: animalID, name: trimmedName, tag: trimmedTag,
                        breed: chosenBreed, sex: chosenSex, birthDate: chosenDOB
                    )
                    onSaved(trimmedName, trimmedTag, chosenBreed, chosenSex, chosenDOB)
                    isSaving = false
                    dismiss()
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
```

- [ ] **Step 2: Make AnimalDetailView hold mutable state and present the editor**

In `AnimalsView.swift`, change `AnimalDetailView` to store the animal in `@State` (so edits reflect immediately) and add an Edit button. Replace the property declarations and `topBar` of `AnimalDetailView` (lines 241-284) with:

```swift
struct AnimalDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    @State private var animal: Animal
    @State private var showEdit = false

    init(animal: Animal) {
        _animal = State(initialValue: animal)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                identityCard
                infoGrid
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, AgriLayout.tabBarClearance)
        }
        .background(AgriColors.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showEdit) {
            EditAnimalScreen(animal: animal) { name, tag, breed, sex, birthDate in
                animal.name = name
                animal.tag = tag
                animal.breed = breed
                animal.sex = sex
                animal.birthDate = birthDate
            }
            .environmentObject(store)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AgriColors.purpleDark)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(Color.white)
                            .shadow(color: AgriColors.purpleDark.opacity(0.08), radius: 8, y: 3)
                    )
            }
            .buttonStyle(.plain)
            Spacer()
            Text(lang.t("detail.title"))
                .font(AgriFont.semibold(16))
                .foregroundStyle(AgriColors.purpleDark)
            Spacer()
            Button {
                showEdit = true
            } label: {
                Text(lang.t("detail.edit"))
                    .font(AgriFont.semibold(14))
                    .foregroundStyle(AgriColors.purple)
                    .frame(height: 38)
                    .padding(.horizontal, 12)
                    .background(
                        Capsule().fill(AgriColors.purple.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
        }
    }
```

> NOTE: this replaces the old trailing `Color.clear.frame(width: 38, height: 38)` spacer in `topBar` with the Edit button, and replaces the old `let animal: Animal` stored property with `@State private var animal` + `init`. The Delete button is added in Task 8.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add AgriVision/Views/Main/AddAnimalView.swift AgriVision/Views/Main/AnimalsView.swift
git commit -m "feat(ios): edit animal screen + edit entry in detail view"
```

---

## Task 8: Delete button, swipe-to-delete, and undo toast

**Files:**
- Modify: `AgriVision/Views/Main/AnimalsView.swift`

- [ ] **Step 1: Add the `UndoToast` component**

In `AnimalsView.swift`, at the end of the file, add:

```swift
/// Snackbar shown after archiving an animal: message + Undo, auto-dismissing.
struct UndoToast: View {
    let message: String
    let actionTitle: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(message)
                .font(AgriFont.semibold(14))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Button(action: onUndo) {
                Text(actionTitle)
                    .font(AgriFont.bold(14))
                    .foregroundStyle(AgriColors.purple)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            Capsule().fill(AgriColors.purpleDark)
                .shadow(color: AgriColors.purpleDark.opacity(0.35), radius: 10, y: 4)
        )
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
```

- [ ] **Step 2: Add the Delete button to AnimalDetailView**

In `AnimalsView.swift`, add a delete state field and a delete action to `AnimalDetailView`. Add after `@State private var showEdit = false`:

```swift
    @State private var showDeleteConfirm = false
    private let repository = AnimalRepository()
```

Add a Delete button at the bottom of the detail `VStack` — insert after `infoGrid` in `body`:

```swift
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(lang.t("detail.delete"), systemImage: "trash")
                        .font(AgriFont.semibold(15))
                        .foregroundStyle(Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255).opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
```

Add the confirmation dialog modifier to the detail `body` (alongside `.sheet(isPresented: $showEdit)`):

```swift
        .confirmationDialog(
            lang.t("delete.confirmTitle"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(lang.t("delete.confirm"), role: .destructive) { performDelete() }
            Button(lang.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(lang.t("delete.confirmBody"))
        }
```

Add the delete action method to `AnimalDetailView`:

```swift
    private func performDelete() {
        let id = animal.id
        Task {
            do {
                try await repository.softDelete(animalID: id.uuidString)
                await MainActor.run {
                    store.removeAnimal(id: id)   // sets store.recentlyArchived → toast in list
                    dismiss()
                }
            } catch {
                // Reconcile on failure: a reload drops it only if the server agrees.
                await store.load()
            }
        }
    }
```

- [ ] **Step 3: Add swipe-to-delete + the undo toast to AnimalsScreen**

In `AnimalsView.swift`, add a repository to `AnimalsScreen` (after `@State private var filter`):

```swift
    private let repository = AnimalRepository()
```

Wrap the list rows with a swipe action. Replace the `ForEach(filteredAnimals)` block (lines 63-70) with a `List`-free swipe alternative using `.swipeActions` requires a `List`; the current UI is a `ScrollView`+`ForEach`. To keep the existing card layout, add a swipe via `.swipeActions` is unavailable outside List — instead add a context menu for delete on each card. Replace the `ForEach` block with:

```swift
                            ForEach(filteredAnimals) { animal in
                                NavigationLink {
                                    AnimalDetailView(animal: animal)
                                } label: {
                                    AnimalCard(animal: animal)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        archive(animal)
                                    } label: {
                                        Label(lang.t("detail.delete"), systemImage: "trash")
                                    }
                                }
                            }
```

> Rationale: the herd list is a `ScrollView`/`ForEach`, not a `List`, so SwiftUI `.swipeActions` is unavailable without converting the whole screen to a `List` (which would lose the custom card styling). A long-press context-menu Delete is the idiomatic equivalent for card grids and keeps the existing layout. The detail-view Delete button remains the primary path.

Add the `archive` helper to `AnimalsScreen`:

```swift
    private func archive(_ animal: Animal) {
        Task {
            do {
                try await repository.softDelete(animalID: animal.id.uuidString)
                await MainActor.run { store.removeAnimal(id: animal.id) }
            } catch {
                await store.load()
            }
        }
    }

    private func undoArchive(_ animal: Animal) {
        Task {
            do {
                try await repository.restore(animalID: animal.id.uuidString)
                await MainActor.run { store.restoreAnimal(animal) }
            } catch {
                await store.load()
            }
        }
    }
```

Add the toast overlay. Change the outer `NavigationStack { ScrollView { ... } ... }` by adding an `.overlay(alignment: .bottom)` on the `ScrollView` (after the `.sheet(isPresented: $showAddAnimal)` modifier, line 87):

```swift
            .overlay(alignment: .bottom) {
                if let archived = store.recentlyArchived {
                    UndoToast(
                        message: lang.t("undo.archived"),
                        actionTitle: lang.t("undo.action"),
                        onUndo: { undoArchive(archived) }
                    )
                    .padding(.bottom, AgriLayout.tabBarClearance)
                    .task(id: archived.id) {
                        // Auto-dismiss after ~4s unless undone/replaced.
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if store.recentlyArchived?.id == archived.id {
                            store.clearRecentlyArchived()
                        }
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: store.recentlyArchived?.id)
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add AgriVision/Views/Main/AnimalsView.swift
git commit -m "feat(ios): soft-delete animal with confirmation, context-menu, and undo toast"
```

---

## Task 9: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full iOS test suite**

Run: `xcodebuild -project AgriVision.xcodeproj -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
Expected: TEST SUCCEEDED — all suites green (HerdStoreTests now has the 3 new cases).

- [ ] **Step 2: Run the server fast suite**

Run: `cd server && .venv/bin/pytest tests/ -m "not slow and not integration" -q`
Expected: PASS, including `test_match_sql_excludes_soft_deleted`.

- [ ] **Step 3: Confirm the live-DB migration reminder**

Verify `server/sql/migrations/2026-06-13-add-animals-deleted-at.sql` exists and remind the human operator to apply it in the Supabase SQL editor before shipping (soft-delete PATCH and the new `match()` join both require the `deleted_at` column to exist).

- [ ] **Step 4: Manual smoke test (human, on device/simulator)**

1. Open an animal → tap **Edit** → change name/tag/breed/sex/DOB → **Save Changes** → detail reflects new values; herd list updates.
2. Open an animal → **Delete Animal** → confirm → returns to herd list with "Animal archived · Undo" toast → tap **Undo** → animal reappears.
3. Long-press a herd card → **Delete Animal** → toast appears → let it time out (~4s) → animal stays gone.
4. Scan a muzzle of an archived (not undone) animal → result is **unknown** (excluded from matching).

---

## Notes / Out of scope (YAGNI)

- No archived-animals browse screen, no hard delete/purge, no storage cleanup, no `delete` event kind.
- Swipe-to-delete is realized as a long-press context menu because the herd list is a styled `ScrollView`/`ForEach`, not a `List`. If the herd list is ever converted to `List`, swap the context menu for `.swipeActions`.
