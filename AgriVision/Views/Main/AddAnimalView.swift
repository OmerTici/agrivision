import SwiftUI

struct AddAnimalScreen: View {
    @EnvironmentObject private var store: HerdStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var recognition: CloudRunRecognitionService
    @ObservedObject private var lang = LanguageManager.shared
    /// Switches to the My Herd (Animals) tab. Mirrors the Animals header's
    /// quick-jump button, in reverse.
    let onOpenHerd: () -> Void
    /// Muzzle carried in from the "not recognized" identify screen, if any. Seeds
    /// the muzzle scans as scan 1 of 5.
    let carriedMuzzleCrop: UIImage?
    let carriedMuzzleFull: UIImage?

    private let repository = AnimalRepository()

    static let muzzleTarget = 5
    static let cowPhotoMax = 5

    @State private var name = ""
    @State private var tag = ""
    @State private var breed = "Holstein"
    @State private var sex: AnimalSex = .female
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
    @State private var weightText = ""

    // Photos gathered on the hub. Muzzle crops (cow-gated, must reach 5) are
    // matched server-side; profile + cow photos are ungated quality-of-life shots
    // that ride along as optional `full_images`.
    @State private var muzzleCrops: [UIImage]
    @State private var muzzleFull: UIImage?
    @State private var profilePhoto: UIImage?
    @State private var cowPhotos: [UIImage] = []

    @State private var showSavedToast = false
    @State private var enrollStatus: EnrollStatus = .idle
    /// Set once the animal row is created, so an enroll retry doesn't create a
    /// duplicate.
    @State private var createdAnimalID: String?
    @State private var activeCamera: ActiveCamera?

    /// Drives the enrollment popup (please-wait → success / fail).
    private enum EnrollStatus: Equatable {
        case idle
        case submitting
        case success
        case failed(String)
    }

    private var isSubmitting: Bool { enrollStatus == .submitting }

    private enum ActiveCamera: Identifiable {
        case muzzle
        case profile
        case cow
        var id: String {
            switch self {
            case .muzzle: return "muzzle"
            case .profile: return "profile"
            case .cow: return "cow"
            }
        }
    }

    init(
        onOpenHerd: @escaping () -> Void = {},
        carriedMuzzleCrop: UIImage? = nil,
        carriedMuzzleFull: UIImage? = nil
    ) {
        self.onOpenHerd = onOpenHerd
        self.carriedMuzzleCrop = carriedMuzzleCrop
        self.carriedMuzzleFull = carriedMuzzleFull
        _muzzleCrops = State(initialValue: carriedMuzzleCrop.map { [$0] } ?? [])
        _muzzleFull = State(initialValue: carriedMuzzleFull)
    }

    private var muzzleComplete: Bool { muzzleCrops.count >= Self.muzzleTarget }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !tag.trimmingCharacters(in: .whitespaces).isEmpty
            && muzzleComplete
    }

    /// Profile + cow body photos, in submission order.
    private var extraFullFrames: [UIImage] {
        var frames: [UIImage] = []
        if let profilePhoto { frames.append(profilePhoto) }
        frames.append(contentsOf: cowPhotos)
        return frames
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    muzzleSection
                    photosCard
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

            enrollOverlay
        }
        .fullScreenCover(item: $activeCamera) { which in
            switch which {
            case .muzzle:
                CameraScreen(
                    onClose: { activeCamera = nil },
                    collection: CameraCollectionRequest(
                        kind: .muzzle,
                        max: max(1, Self.muzzleTarget - muzzleCrops.count),
                        titleKey: "camera.collect.muzzle"
                    ),
                    onCollected: { crops, bestFull in
                        muzzleCrops.append(contentsOf: crops)
                        if let bestFull { muzzleFull = bestFull }
                        activeCamera = nil
                    }
                )
            case .profile:
                CameraScreen(
                    onClose: { activeCamera = nil },
                    collection: CameraCollectionRequest(kind: .frame, max: 1, titleKey: "camera.collect.profile"),
                    onCollected: { frames, _ in
                        if let first = frames.first { profilePhoto = first }
                        activeCamera = nil
                    }
                )
            case .cow:
                CameraScreen(
                    onClose: { activeCamera = nil },
                    collection: CameraCollectionRequest(
                        kind: .frame,
                        max: max(1, Self.cowPhotoMax - cowPhotos.count),
                        titleKey: "camera.collect.cow"
                    ),
                    onCollected: { frames, _ in
                        cowPhotos.append(contentsOf: frames)
                        activeCamera = nil
                    }
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lang.t("add.title"))
                    .font(AgriFont.bold(24))
                    .foregroundStyle(AgriColors.purpleDark)
                Text(lang.t("add.subtitle"))
                    .font(AgriFont.regular(13))
                    .foregroundStyle(AgriColors.tabInactive)
            }
            Spacer()
            Button {
                onOpenHerd()
            } label: {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AgriColors.purple)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Muzzle (required, tap to scan)

    private var muzzleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(lang.t("add.muzzle.title"))
                    .font(AgriFont.semibold(15))
                    .foregroundStyle(AgriColors.purpleDark)
                Text("\(muzzleCrops.count)/\(Self.muzzleTarget)")
                    .font(AgriFont.semibold(13))
                    .foregroundStyle(muzzleComplete ? AgriColors.successGreen : AgriColors.purple)
                Spacer()
                if muzzleComplete {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AgriColors.successGreen)
                }
            }

            if !muzzleCrops.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(muzzleCrops.enumerated()), id: \.offset) { idx, img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable().scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Button {
                                    muzzleCrops.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white)
                                        .background(Circle().fill(.black.opacity(0.5)))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                            }
                        }
                    }
                }
            }

            if !muzzleComplete {
                Button {
                    activeCamera = .muzzle
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 16, weight: .semibold))
                        Text(lang.t(muzzleCrops.isEmpty ? "add.muzzle.scan" : "add.muzzle.scanMore"))
                            .font(AgriFont.semibold(14))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AgriColors.purple)
                    )
                }
                .buttonStyle(.plain)
                Text(lang.t("add.muzzle.hint"))
                    .font(AgriFont.regular(12))
                    .foregroundStyle(AgriColors.tabInactive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((muzzleComplete ? AgriColors.successGreen : AgriColors.purple).opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder((muzzleComplete ? AgriColors.successGreen : AgriColors.purple).opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: muzzleComplete ? [] : [6, 5]))
        )
    }

    // MARK: Optional photos (profile + cow body, ungated)

    private var photosCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Profile photo (optional, 1)
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(title: lang.t("add.profile.title"))
                if let profilePhoto {
                    photoRow(image: profilePhoto, caption: lang.t("add.profile.captured")) {
                        self.profilePhoto = nil
                    }
                } else {
                    captureButton(label: lang.t("add.profile.add"), systemImage: "person.crop.square") {
                        activeCamera = .profile
                    }
                }
            }

            Divider()

            // Cow body photos (optional, up to 5)
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(title: "\(lang.t("add.cow.title"))  \(cowPhotos.count)/\(Self.cowPhotoMax)")
                if !cowPhotos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(cowPhotos.enumerated()), id: \.offset) { idx, img in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: img)
                                        .resizable().scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    Button {
                                        cowPhotos.remove(at: idx)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .background(Circle().fill(.black.opacity(0.5)))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                }
                            }
                        }
                    }
                }
                if cowPhotos.count < Self.cowPhotoMax {
                    captureButton(label: lang.t("add.cow.add"), systemImage: "camera") {
                        activeCamera = .cow
                    }
                }
            }
        }
        .agriCard()
    }

    private func sectionHeader(title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AgriFont.semibold(15))
                .foregroundStyle(AgriColors.purpleDark)
            Text(lang.t("add.optional"))
                .font(AgriFont.semibold(11))
                .foregroundStyle(AgriColors.tabInactive)
                .padding(.vertical, 2).padding(.horizontal, 7)
                .background(Capsule().fill(AgriColors.tabInactive.opacity(0.12)))
        }
    }

    private func captureButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(label)
                    .font(AgriFont.semibold(14))
            }
            .foregroundStyle(AgriColors.purple)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AgriColors.purple.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private func photoRow(image: UIImage, caption: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(caption)
                .font(AgriFont.semibold(14))
                .foregroundStyle(AgriColors.purpleDark)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AgriColors.tabInactive)
            }
            .buttonStyle(.plain)
        }
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
            Button(action: save) {
                Text(lang.t("add.saveEnroll"))
                    .font(AgriFont.bold(16))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(canSave && !isSubmitting ? AgriColors.purple : AgriColors.purple.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave || isSubmitting)

            if !muzzleComplete {
                Text(lang.t("add.saveEnrollHint"))
                    .font(AgriFont.regular(12))
                    .foregroundStyle(AgriColors.tabInactive)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: Enrollment popup

    @ViewBuilder
    private var enrollOverlay: some View {
        if enrollStatus != .idle {
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .transition(.opacity)

                VStack(spacing: 18) {
                    switch enrollStatus {
                    case .submitting:
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(AgriColors.purple)
                        Text(lang.t("enroll.popup.wait"))
                            .font(AgriFont.semibold(16))
                            .foregroundStyle(AgriColors.purpleDark)
                        Text(lang.t("enroll.popup.waitHint"))
                            .font(AgriFont.regular(13))
                            .foregroundStyle(AgriColors.tabInactive)
                            .multilineTextAlignment(.center)

                    case .success:
                        AnimatedResultIcon(systemName: "checkmark.circle.fill", color: AgriColors.successGreen)
                        Text(lang.t("enroll.popup.success"))
                            .font(AgriFont.bold(18))
                            .foregroundStyle(AgriColors.purpleDark)

                    case .failed(let message):
                        AnimatedResultIcon(systemName: "xmark.circle.fill", color: .red)
                        Text(lang.t("enroll.popup.failed"))
                            .font(AgriFont.bold(18))
                            .foregroundStyle(AgriColors.purpleDark)
                        Text(message)
                            .font(AgriFont.regular(13))
                            .foregroundStyle(AgriColors.tabInactive)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            Button { enrollStatus = .idle } label: {
                                Text(lang.t("enroll.popup.close"))
                                    .font(AgriFont.semibold(15))
                                    .foregroundStyle(AgriColors.purple)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(AgriColors.purple.opacity(0.4), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            Button(action: save) {
                                Text(lang.t("enroll.popup.retry"))
                                    .font(AgriFont.semibold(15))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(AgriColors.purple)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)

                    case .idle:
                        EmptyView()
                    }
                }
                .padding(28)
                .frame(maxWidth: 320)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(AgriColors.white)
                )
                .padding(.horizontal, 40)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            .animation(.easeInOut(duration: 0.2), value: enrollStatus)
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
            enrollStatus = .failed(lang.t("auth.error.generic"))
            return
        }
        withAnimation { enrollStatus = .submitting }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        let muzzleJpegs = muzzleCrops.compactMap { ImageEncoding.muzzleJPEG($0) }
        var fullJpegs: [Data] = []
        if let muzzleFull, let encoded = ImageEncoding.fullBodyJPEG(muzzleFull) {
            fullJpegs.append(encoded)
        }
        fullJpegs.append(contentsOf: extraFullFrames.compactMap { ImageEncoding.fullBodyJPEG($0) })
        let weightKg = Double(weightText.replacingOccurrences(of: ",", with: "."))

        Task {
            do {
                // Create the animal row once; an enroll retry reuses the same id.
                let animalID: String
                if let existing = createdAnimalID {
                    animalID = existing
                } else {
                    let created = try await repository.create(
                        ownerID: ownerID,
                        name: trimmedName,
                        tag: trimmedTag,
                        breed: breed,
                        sex: sex,
                        birthDate: birthDate
                    )
                    await MainActor.run {
                        store.addAnimal(
                            name: trimmedName,
                            tag: trimmedTag,
                            breed: breed,
                            sex: sex,
                            birthDate: birthDate,
                            initialWeightKg: weightKg,
                            muzzleRegistered: false
                        )
                        createdAnimalID = created.id
                    }
                    animalID = created.id
                }

                _ = try await recognition.enroll(
                    animalID: animalID,
                    muzzleJpegs: muzzleJpegs,
                    fullJpegs: fullJpegs
                )
                await MainActor.run {
                    store.markLastAddedMuzzleRegistered()
                    withAnimation { enrollStatus = .success }
                    // Hold the success animation briefly, then reset the form.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation { enrollStatus = .idle }
                        resetAndToast()
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation { enrollStatus = .failed(error.localizedDescription) }
                }
            }
        }
    }

    /// Clears the form after a successful enrollment and shows the saved toast.
    private func resetAndToast() {
        name = ""
        tag = ""
        weightText = ""
        muzzleCrops = []
        muzzleFull = nil
        profilePhoto = nil
        cowPhotos = []
        createdAnimalID = nil
        withAnimation(.spring(duration: 0.35)) { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { showSavedToast = false }
        }
    }
}

/// A result glyph that springs in (used by the enrollment popup).
private struct AnimatedResultIcon: View {
    let systemName: String
    let color: Color
    @State private var shown = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 64))
            .foregroundStyle(color)
            .scaleEffect(shown ? 1 : 0.4)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { shown = true }
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
