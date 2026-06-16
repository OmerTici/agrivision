import SwiftUI

struct AddAnimalScreen: View {
    @EnvironmentObject private var store: HerdStore
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared

    private let repository = AnimalRepository()

    @State private var name = ""
    @State private var tag = ""
    @State private var breed = "Holstein"
    @State private var sex: AnimalSex = .female
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
    @State private var weightText = ""
    @State private var muzzleScanned = false
    @State private var showSavedToast = false

    @State private var isSaving = false
    @State private var saveError: String?
    /// Set to the new animal id to trigger the enrollment camera.
    @State private var enrollAnimalID: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !tag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    muzzleScanCard
                    detailsCard
                    saveButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, AgriLayout.tabBarClearance)
            }
            .scrollDismissesKeyboard(.interactively)

            if showSavedToast {
                savedToast
            }
        }
        .fullScreenCover(item: $enrollAnimalID) { animalID in
            CameraScreen(
                onClose: {
                    enrollAnimalID = nil
                },
                onEnrollSuccess: {
                    store.markLastAddedMuzzleRegistered()
                },
                enrollAnimalID: animalID
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(lang.t("add.title"))
                .font(AgriFont.bold(24))
                .foregroundStyle(AgriColors.purpleDark)
            Text(lang.t("add.subtitle"))
                .font(AgriFont.regular(13))
                .foregroundStyle(AgriColors.tabInactive)
        }
    }

    private var muzzleScanCard: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { muzzleScanned.toggle() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: muzzleScanned ? "checkmark.seal.fill" : "viewfinder")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(muzzleScanned ? AgriColors.successGreen : AgriColors.purple)

                Text(lang.t(muzzleScanned ? "add.scanDone" : "add.scanPrompt"))
                    .font(AgriFont.semibold(15))
                    .foregroundStyle(muzzleScanned ? AgriColors.successGreen : AgriColors.purpleDark)

                Text(lang.t(muzzleScanned ? "add.scanHintDone" : "add.scanHint"))
                    .font(AgriFont.regular(12))
                    .foregroundStyle(AgriColors.tabInactive)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill((muzzleScanned ? AgriColors.successGreen : AgriColors.purple).opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        (muzzleScanned ? AgriColors.successGreen : AgriColors.purple).opacity(0.45),
                        style: StrokeStyle(lineWidth: 1.5, dash: muzzleScanned ? [] : [6, 5])
                    )
            )
        }
        .buttonStyle(.plain)
    }

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

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AgriColors.appBackground)
    }

    private var saveButton: some View {
        VStack(spacing: 10) {
            if let saveError {
                Text(saveError)
                    .font(AgriFont.regular(13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: save) {
                Text(isSaving ? lang.t("camera.enroll.submitting") : lang.t("add.save"))
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
    }

    private var savedToast: some View {
        Label(lang.t("add.saved"), systemImage: "checkmark.circle.fill")
            .font(AgriFont.semibold(14))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(AgriColors.successGreen))
            .shadow(color: AgriColors.successGreen.opacity(0.35), radius: 10, y: 4)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
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
                    // Keep the in-memory herd list in sync (muzzleRegistered flips
                    // to true only after a successful enroll — see markLast…).
                    store.addAnimal(
                        name: trimmedName,
                        tag: trimmedTag,
                        breed: breed,
                        sex: sex,
                        birthDate: birthDate,
                        initialWeightKg: Double(weightText.replacingOccurrences(of: ",", with: ".")),
                        muzzleRegistered: false
                    )
                    isSaving = false
                    name = ""
                    tag = ""
                    weightText = ""
                    muzzleScanned = false
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
                .font(AgriFont.semibold(13))
                .foregroundStyle(AgriColors.purpleDark)
            TextField(placeholder, text: $text)
                .font(AgriFont.regular(15))
                .foregroundStyle(AgriColors.purpleDark)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AgriColors.appBackground)
                )
        }
    }
}

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

extension String: Identifiable {
    public var id: String { self }
}
