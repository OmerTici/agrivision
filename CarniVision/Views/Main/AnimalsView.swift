import SwiftUI

// MARK: - Animals list

struct AnimalsScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    @Binding var showAddAnimal: Bool
    @State private var searchText = ""
    @State private var filter: SexFilter = .all

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
            let query = searchText.lowercased()
            return animal.name.lowercased().contains(query)
                || animal.tag.lowercased().contains(query)
                || animal.breed.lowercased().contains(query)
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
                            }
                        }

                        if filteredAnimals.isEmpty {
                            noResultsState
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, CarniLayout.tabBarClearance)
            }
            .refreshable { await store.load() }
            .background(CarniColors.appBackground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAddAnimal) {
                AddAnimalScreen()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lang.t("animals.title"))
                    .font(CarniFont.bold(24))
                    .foregroundStyle(CarniColors.purpleDark)
                Text(lang.t("animals.subtitle", store.animals.count, store.registeredCount))
                    .font(CarniFont.regular(13))
                    .foregroundStyle(CarniColors.tabInactive)
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
                            .fill(CarniColors.purple)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CarniColors.tabInactive)
            TextField(lang.t("animals.search"), text: $searchText)
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CarniColors.tabInactive)
                }
                .buttonStyle(.plain)
            }
        }
        .carniCard(padding: 13)
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(SexFilter.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = option }
                } label: {
                    Text(lang.t(option.key))
                        .font(CarniFont.semibold(13))
                        .foregroundStyle(filter == option ? .white : CarniColors.purple)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(filter == option ? CarniColors.purple : CarniColors.purple.opacity(0.1))
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
                .tint(CarniColors.purple)
                .padding(.top, 50)
            Spacer()
        }
    }

    private var emptyHerdState: some View {
        VStack(spacing: 10) {
            Image(systemName: "pawprint")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive.opacity(0.5))
            Text(lang.t("animals.emptyHerd"))
                .font(CarniFont.semibold(15))
                .foregroundStyle(CarniColors.tabInactive)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive.opacity(0.5))
            Text(lang.t("animals.empty"))
                .font(CarniFont.semibold(15))
                .foregroundStyle(CarniColors.tabInactive)
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
                        .font(CarniFont.semibold(16))
                        .foregroundStyle(CarniColors.purpleDark)
                    if animal.muzzleRegistered {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CarniColors.successGreen)
                    }
                }
                Text(animal.tag)
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.purple)
                Text("\(animal.breed) · \(animal.ageDescription(lang))")
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .carniCard(padding: 14)
    }
}

// MARK: - Animal detail

struct AnimalDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    let animal: Animal

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                identityCard
                infoGrid
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, CarniLayout.tabBarClearance)
        }
        .background(CarniColors.appBackground)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CarniColors.purpleDark)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(Color.white)
                            .shadow(color: CarniColors.purpleDark.opacity(0.08), radius: 8, y: 3)
                    )
            }
            .buttonStyle(.plain)
            Spacer()
            Text(lang.t("detail.title"))
                .font(CarniFont.semibold(16))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
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
                    .font(CarniFont.bold(22))
                    .foregroundStyle(CarniColors.purpleDark)
                Text(animal.tag)
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purple)
                Label(
                    lang.t(animal.muzzleRegistered ? "detail.muzzleID" : "detail.notRegistered"),
                    systemImage: animal.muzzleRegistered ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(CarniFont.semibold(11))
                .foregroundStyle(animal.muzzleRegistered ? CarniColors.successGreen : Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        (animal.muzzleRegistered ? CarniColors.successGreen : Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255)).opacity(0.12)
                    )
                )
            }
            Spacer(minLength: 0)
        }
        .carniCard()
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
                .font(CarniFont.regular(12))
                .foregroundStyle(CarniColors.tabInactive)
            Text(value)
                .font(CarniFont.semibold(15))
                .foregroundStyle(CarniColors.purpleDark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carniCard(padding: 14)
    }
}
