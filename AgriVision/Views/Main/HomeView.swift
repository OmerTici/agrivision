import SwiftUI
import Supabase

// MARK: - Shared screen components

extension View {
    /// White rounded card with the app's soft shadow.
    func agriCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: AgriColors.purpleDark.opacity(0.07), radius: 12, y: 4)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(AgriFont.bold(18))
                .foregroundStyle(AgriColors.purpleDark)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(AgriFont.semibold(13))
                        .foregroundStyle(AgriColors.purple)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AnimalAvatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.16))
            Text(name.prefix(1).uppercased())
                .font(AgriFont.bold(size * 0.42))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

/// Async animal photo with the initials avatar as fallback. Photo lookup is
/// owner-scoped under RLS; any failure silently degrades to the avatar.
struct AnimalPhotoView: View {
    let animalID: UUID?
    let name: String
    let color: Color
    var size: CGFloat = 48
    /// Chosen profile photo path; nil falls back to the first stored image.
    var profilePath: String? = nil

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                AnimalAvatar(name: name.isEmpty ? "?" : name, color: color, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: taskID) {
            guard let animalID,
                  let ownerID = SupabaseClientProvider.shared.auth.currentSession?.user.id.uuidString
            else { return }
            image = await AnimalPhotoLoader.shared.photo(
                ownerID: ownerID,
                animalID: animalID.uuidString,
                profilePath: profilePath
            )
        }
    }

    /// Re-run the load when either the animal or its chosen profile changes.
    private var taskID: String { "\(animalID?.uuidString ?? "")|\(profilePath ?? "")" }
}

/// Inline failure banner with a Retry button, shown when HerdStore.load() fails.
struct LoadErrorBanner: View {
    let message: String
    let retry: () -> Void
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255))
            Text(message)
                .font(AgriFont.regular(13))
                .foregroundStyle(AgriColors.purpleDark)
            Spacer()
            Button(action: retry) {
                Text(lang.t("common.retry"))
                    .font(AgriFont.semibold(13))
                    .foregroundStyle(AgriColors.purple)
            }
            .buttonStyle(.plain)
        }
        .agriCard(padding: 12)
    }
}

// MARK: - Home

struct HomeScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    var onSeeAllAnimals: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let error = store.loadError {
                        LoadErrorBanner(message: error) {
                            Task { await store.load() }
                        }
                    }
                    if store.isLoading && store.animals.isEmpty && store.events.isEmpty {
                        loadingState
                    } else {
                        statsGrid
                        recentActionsSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, AgriLayout.tabBarClearance)
            }
            .refreshable { await store.load() }
            .background(AgriColors.appBackground)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return lang.t("greeting.morning")
        case 12..<18: return lang.t("greeting.afternoon")
        default: return lang.t("greeting.evening")
        }
    }

    private var signedInEmail: String {
        SupabaseClientProvider.shared.auth.currentSession?.user.email ?? ""
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(AgriFont.regular(14))
                    .foregroundStyle(AgriColors.tabInactive)
                Text(signedInEmail)
                    .font(AgriFont.bold(22))
                    .foregroundStyle(AgriColors.purpleDark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 12)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AgriColors.purpleDark)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(Color.white)
                            .shadow(color: AgriColors.purpleDark.opacity(0.08), radius: 8, y: 3)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(lang.t("settings.title"))
        }
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(AgriColors.purple)
                .padding(.top, 60)
            Spacer()
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
            StatCard(
                icon: "pawprint.fill",
                tint: AgriColors.purple,
                value: "\(store.animals.count)",
                label: lang.t("home.animals")
            )
            StatCard(
                icon: "checkmark.seal.fill",
                tint: Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255),
                value: "\(store.registeredCount)/\(store.animals.count)",
                label: lang.t("home.muzzleIDs")
            )
            StatCard(
                icon: "camera.viewfinder",
                tint: Color(red: 222 / 255, green: 138 / 255, blue: 60 / 255),
                value: "\(store.scansThisWeek)",
                label: lang.t("home.scansThisWeek")
            )
        }
    }

    private var recentActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(lang.t("home.recentActions"))
                    .font(AgriFont.bold(18))
                    .foregroundStyle(AgriColors.purpleDark)
                Spacer()
                if !store.events.isEmpty {
                    NavigationLink {
                        ScanHistoryScreen()
                    } label: {
                        Text(lang.t("home.seeAll"))
                            .font(AgriFont.semibold(13))
                            .foregroundStyle(AgriColors.purple)
                    }
                    .buttonStyle(.plain)
                }
            }

            if store.events.isEmpty {
                emptyEvents
            } else {
                VStack(spacing: 10) {
                    ForEach(store.events.prefix(5)) { event in
                        NavigationLink {
                            ScanHistoryScreen()
                        } label: {
                            EventRow(event: event)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyEvents: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AgriColors.tabInactive.opacity(0.5))
            Text(lang.t("home.noEvents"))
                .font(AgriFont.regular(14))
                .foregroundStyle(AgriColors.tabInactive)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .agriCard()
    }
}

private struct StatCard: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.13))
                )
            Text(value)
                .font(AgriFont.bold(21))
                .foregroundStyle(AgriColors.purpleDark)
            Text(label)
                .font(AgriFont.regular(12))
                .foregroundStyle(AgriColors.tabInactive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agriCard(padding: 14)
    }
}

private struct EventRow: View {
    let event: ScanEvent
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            AnimalPhotoView(
                animalID: event.animalID,
                name: event.animalName ?? "?",
                color: event.avatarColor,
                size: 44
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title(lang))
                    .font(AgriFont.semibold(14))
                    .foregroundStyle(AgriColors.purpleDark)
                    .lineLimit(1)
                Text(lang.timeAgo(event.date))
                    .font(AgriFont.regular(12))
                    .foregroundStyle(AgriColors.tabInactive)
            }

            Spacer()

            Image(systemName: event.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(event.color)
                .padding(8)
                .background(Circle().fill(event.color.opacity(0.12)))
        }
        .agriCard(padding: 12)
    }
}

/// Full scan history with animal + date filters, server-side filtered and
/// paginated (infinite scroll) so it stays fast as scans accumulate. Tapping a
/// scan with a known animal opens that animal's detail; unrecognized scans are
/// listed but not tappable.
struct ScanHistoryScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    private let repository = EventRepository()
    private static let pageSize = 30

    @State private var animalFilter: AnimalFilter = .all
    @State private var dateFilter: DateFilter = .all

    @State private var events: [ScanEvent] = []
    @State private var nextOffset = 0
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var didInitialLoad = false

    private enum AnimalFilter: Equatable {
        case all
        case unrecognized
        case animal(UUID)
    }

    private enum DateFilter: CaseIterable {
        case all, today, week, month
        var labelKey: String {
            switch self {
            case .all: return "filter.allTime"
            case .today: return "filter.today"
            case .week: return "filter.week"
            case .month: return "filter.month"
            }
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                topBar
                    .padding(.bottom, 2)
                filters
                    .padding(.bottom, 4)

                if events.isEmpty && reachedEnd {
                    emptyState
                } else {
                    ForEach(events) { event in
                        row(event)
                            .onAppear {
                                if event.id == events.last?.id { Task { await loadNextPage() } }
                            }
                    }
                    if isLoading {
                        ProgressView()
                            .tint(AgriColors.purple)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, AgriLayout.tabBarClearance)
        }
        .background(AgriColors.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await loadNextPage()
        }
        .onChange(of: animalFilter) { _, _ in Task { await reload() } }
        .onChange(of: dateFilter) { _, _ in Task { await reload() } }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AgriColors.purple)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(Color.white)
                            .shadow(color: AgriColors.purpleDark.opacity(0.08), radius: 8, y: 3)
                    )
            }
            .buttonStyle(.plain)
            Spacer()
            Text(lang.t("scanHistory.title"))
                .font(AgriFont.semibold(16))
                .foregroundStyle(AgriColors.purpleDark)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
    }

    @ViewBuilder
    private func row(_ event: ScanEvent) -> some View {
        if let animalID = event.animalID,
           let animal = store.animals.first(where: { $0.id == animalID }) {
            NavigationLink {
                AnimalDetailView(animal: animal)
            } label: {
                EventRow(event: event)
            }
            .buttonStyle(.plain)
        } else {
            EventRow(event: event)
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Menu {
                Button(lang.t("filter.allAnimals")) { animalFilter = .all }
                Button(lang.t("filter.unrecognized")) { animalFilter = .unrecognized }
                if !store.animals.isEmpty { Divider() }
                ForEach(store.animals) { animal in
                    Button(animal.name.isEmpty ? animal.tag : animal.name) {
                        animalFilter = .animal(animal.id)
                    }
                }
            } label: {
                filterChip(systemImage: "pawprint", text: animalFilterLabel)
            }

            Menu {
                ForEach(DateFilter.allCases, id: \.self) { option in
                    Button(lang.t(option.labelKey)) { dateFilter = option }
                }
            } label: {
                filterChip(systemImage: "calendar", text: lang.t(dateFilter.labelKey))
            }

            Spacer()
        }
    }

    private var animalFilterLabel: String {
        switch animalFilter {
        case .all: return lang.t("filter.allAnimals")
        case .unrecognized: return lang.t("filter.unrecognized")
        case .animal(let id):
            return store.animals.first(where: { $0.id == id })?.name ?? lang.t("filter.allAnimals")
        }
    }

    private func filterChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
            Text(text).font(AgriFont.semibold(13)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(AgriColors.purple)
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Capsule().fill(AgriColors.purple.opacity(0.1)))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AgriColors.tabInactive.opacity(0.5))
            Text(lang.t("scanHistory.empty"))
                .font(AgriFont.regular(14))
                .foregroundStyle(AgriColors.tabInactive)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .agriCard()
    }

    // MARK: Paging

    private var serverAnimalFilter: EventAnimalFilter {
        switch animalFilter {
        case .all: return .all
        case .unrecognized: return .unrecognized
        case .animal(let id): return .specific(id)
        }
    }

    private var sinceDate: Date? {
        switch dateFilter {
        case .all: return nil
        case .today: return Calendar.current.startOfDay(for: Date())
        case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        }
    }

    /// Resets and loads the first page (after a filter change).
    private func reload() async {
        events = []
        nextOffset = 0
        reachedEnd = false
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let records = try await repository.page(
                offset: nextOffset,
                limit: Self.pageSize,
                animal: serverAnimalFilter,
                since: sinceDate
            )
            events.append(contentsOf: records.map { ScanEvent(record: $0, animals: store.animals) })
            nextOffset += records.count
            if records.count < Self.pageSize { reachedEnd = true }
        } catch {
            // Stop paging on error; the loaded page (if any) stays visible.
            reachedEnd = true
        }
    }
}
