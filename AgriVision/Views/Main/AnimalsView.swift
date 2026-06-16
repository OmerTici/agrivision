import SwiftUI

// MARK: - Animals list

struct AnimalsScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    @Binding var showAddAnimal: Bool
    @State private var searchText = ""
    @State private var filter: SexFilter = .all
    private let repository = AnimalRepository()

    enum SexFilter: String, CaseIterable {
        case all
        case female
        case male

        var key: String {
            switch self {
            case .all: return "filter.all"
            case .female: return "filter.females"
            case .male: return "filter.males"
            }
        }
    }

    private var filteredAnimals: [Animal] {
        store.animals.filter { animal in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .female: matchesFilter = animal.sex == .female
            case .male: matchesFilter = animal.sex == .male
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            // localizedStandardContains: case/diacritic-insensitive and correct
            // for Turkish dotted-I, unlike lowercased().contains.
            return animal.name.localizedStandardContains(searchText)
                || animal.tag.localizedStandardContains(searchText)
                || animal.breed.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let error = store.loadError {
                        LoadErrorBanner(message: error) {
                            Task { await store.load() }
                        }
                    }
                    searchField
                    filterChips

                    if store.isLoading && store.animals.isEmpty {
                        loadingState
                    } else if store.animals.isEmpty {
                        emptyHerdState
                    } else {
                        VStack(spacing: 10) {
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
                        }

                        if filteredAnimals.isEmpty {
                            noResultsState
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, AgriLayout.tabBarClearance)
            }
            .refreshable { await store.load() }
            .background(AgriColors.appBackground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAddAnimal) {
                AddAnimalScreen()
            }
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
        }
    }

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

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lang.t("animals.title"))
                    .font(AgriFont.bold(24))
                    .foregroundStyle(AgriColors.purpleDark)
                Text(lang.t("animals.subtitle", store.animals.count, store.registeredCount))
                    .font(AgriFont.regular(13))
                    .foregroundStyle(AgriColors.tabInactive)
            }
            Spacer()
            Button {
                showAddAnimal = true
            } label: {
                Image(systemName: "plus")
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

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AgriColors.tabInactive)
            TextField(lang.t("animals.search"), text: $searchText)
                .font(AgriFont.regular(15))
                .foregroundStyle(AgriColors.purpleDark)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AgriColors.tabInactive)
                }
                .buttonStyle(.plain)
            }
        }
        .agriCard(padding: 13)
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(SexFilter.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = option }
                } label: {
                    Text(lang.t(option.key))
                        .font(AgriFont.semibold(13))
                        .foregroundStyle(filter == option ? .white : AgriColors.purple)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(filter == option ? AgriColors.purple : AgriColors.purple.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(AgriColors.purple)
                .padding(.top, 50)
            Spacer()
        }
    }

    private var emptyHerdState: some View {
        VStack(spacing: 10) {
            Image(systemName: "pawprint")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(AgriColors.tabInactive.opacity(0.5))
            Text(lang.t("animals.emptyHerd"))
                .font(AgriFont.semibold(15))
                .foregroundStyle(AgriColors.tabInactive)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(AgriColors.tabInactive.opacity(0.5))
            Text(lang.t("animals.empty"))
                .font(AgriFont.semibold(15))
                .foregroundStyle(AgriColors.tabInactive)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

private struct AnimalCard: View {
    let animal: Animal
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            AnimalPhotoView(
                animalID: animal.id,
                name: animal.name,
                color: animal.avatarColor,
                size: 50
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(animal.name)
                        .font(AgriFont.semibold(16))
                        .foregroundStyle(AgriColors.purpleDark)
                    if animal.muzzleRegistered {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AgriColors.successGreen)
                    }
                }
                Text(animal.tag)
                    .font(AgriFont.regular(12))
                    .foregroundStyle(AgriColors.purple)
                Text("\(animal.breed) · \(animal.ageDescription(lang))")
                    .font(AgriFont.regular(12))
                    .foregroundStyle(AgriColors.tabInactive)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgriColors.tabInactive)
        }
        .agriCard(padding: 14)
    }
}

// MARK: - Animal detail

struct AnimalDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    @State private var animal: Animal
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    private let repository = AnimalRepository()

    init(animal: Animal) {
        _animal = State(initialValue: animal)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                identityCard
                infoGrid
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
    }

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

    private var identityCard: some View {
        HStack(spacing: 14) {
            AnimalPhotoView(
                animalID: animal.id,
                name: animal.name,
                color: animal.avatarColor,
                size: 72
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(animal.name)
                    .font(AgriFont.bold(22))
                    .foregroundStyle(AgriColors.purpleDark)
                Text(animal.tag)
                    .font(AgriFont.semibold(13))
                    .foregroundStyle(AgriColors.purple)
                Label(
                    lang.t(animal.muzzleRegistered ? "detail.muzzleID" : "detail.notRegistered"),
                    systemImage: animal.muzzleRegistered ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(AgriFont.semibold(11))
                .foregroundStyle(animal.muzzleRegistered ? AgriColors.successGreen : Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        (animal.muzzleRegistered ? AgriColors.successGreen : Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255)).opacity(0.12)
                    )
                )
            }
            Spacer(minLength: 0)
        }
        .agriCard()
    }

    private var infoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            InfoTile(label: lang.t("detail.breed"), value: animal.breed)
            InfoTile(label: lang.t("detail.sex"), value: lang.t(animal.sex.key))
            InfoTile(label: lang.t("detail.age"), value: animal.ageDescription(lang))
            InfoTile(label: lang.t("detail.enrolled"), value: lang.shortDate(animal.createdAt))
        }
    }
}

private struct InfoTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(AgriFont.regular(12))
                .foregroundStyle(AgriColors.tabInactive)
            Text(value)
                .font(AgriFont.semibold(15))
                .foregroundStyle(AgriColors.purpleDark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agriCard(padding: 14)
    }
}

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
