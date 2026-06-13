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
                .padding(.bottom, CarniLayout.tabBarClearance)
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
                .font(CarniFont.bold(24))
                .foregroundStyle(CarniColors.purpleDark)
            Text(lang.t("add.subtitle"))
                .font(CarniFont.regular(13))
                .foregroundStyle(CarniColors.tabInactive)
        }
    }

    private var muzzleScanCard: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { muzzleScanned.toggle() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: muzzleScanned ? "checkmark.seal.fill" : "viewfinder")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(muzzleScanned ? CarniColors.successGreen : CarniColors.purple)

                Text(lang.t(muzzleScanned ? "add.scanDone" : "add.scanPrompt"))
                    .font(CarniFont.semibold(15))
                    .foregroundStyle(muzzleScanned ? CarniColors.successGreen : CarniColors.purpleDark)

                Text(lang.t(muzzleScanned ? "add.scanHintDone" : "add.scanHint"))
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill((muzzleScanned ? CarniColors.successGreen : CarniColors.purple).opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        (muzzleScanned ? CarniColors.successGreen : CarniColors.purple).opacity(0.45),
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
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                HStack {
                    TextField(lang.t("add.weightPh"), text: $weightText)
                        .font(CarniFont.regular(15))
                        .foregroundStyle(CarniColors.purpleDark)
                        .keyboardType(.decimalPad)
                    Text("kg")
                        .font(CarniFont.semibold(14))
                        .foregroundStyle(CarniColors.tabInactive)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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

    private var savedToast: some View {
        Label(lang.t("add.saved"), systemImage: "checkmark.circle.fill")
            .font(CarniFont.semibold(14))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(CarniColors.successGreen))
            .shadow(color: CarniColors.successGreen.opacity(0.35), radius: 10, y: 4)
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
            .fill(CarniColors.appBackground)
    }

    var body: some View {
        VStack(spacing: 16) {
            FormField(label: lang.t("add.name"), placeholder: lang.t("add.namePh"), text: $name)
            FormField(label: lang.t("add.tag"), placeholder: lang.t("add.tagPh"), text: $tag)

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.breed"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                Menu {
                    ForEach(Self.breeds, id: \.self) { option in
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
                        .font(CarniFont.bold(24))
                        .foregroundStyle(CarniColors.purpleDark)
                    Text(lang.t("edit.subtitle"))
                        .font(CarniFont.regular(13))
                        .foregroundStyle(CarniColors.tabInactive)
                }

                AnimalDetailsForm(name: $name, tag: $tag, breed: $breed, sex: $sex, birthDate: $birthDate)
                    .carniCard()

                if let saveError {
                    Text(saveError)
                        .font(CarniFont.regular(13))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: save) {
                    Text(isSaving ? lang.t("camera.enroll.submitting") : lang.t("edit.save"))
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
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, CarniLayout.tabBarClearance)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(CarniColors.appBackground)
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
