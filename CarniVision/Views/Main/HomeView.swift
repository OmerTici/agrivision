import SwiftUI
import Supabase

// MARK: - Shared screen components

extension View {
    /// White rounded card with the app's soft shadow.
    func carniCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: CarniColors.purpleDark.opacity(0.07), radius: 12, y: 4)
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
                .font(CarniFont.bold(18))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(CarniFont.semibold(13))
                        .foregroundStyle(CarniColors.purple)
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
                .font(CarniFont.bold(size * 0.42))
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
        .task(id: animalID) {
            guard let animalID,
                  let ownerID = SupabaseClientProvider.shared.auth.currentSession?.user.id.uuidString
            else { return }
            image = await AnimalPhotoLoader.shared.photo(
                ownerID: ownerID,
                animalID: animalID.uuidString
            )
        }
    }
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
                .font(CarniFont.regular(13))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            Button(action: retry) {
                Text(lang.t("common.retry"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purple)
            }
            .buttonStyle(.plain)
        }
        .carniCard(padding: 12)
    }
}

// MARK: - Home

struct HomeScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    var onSeeAllAnimals: () -> Void = {}

    var body: some View {
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
            .padding(.bottom, CarniLayout.tabBarClearance)
        }
        .refreshable { await store.load() }
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
        VStack(alignment: .leading, spacing: 3) {
            Text(greeting)
                .font(CarniFont.regular(14))
                .foregroundStyle(CarniColors.tabInactive)
            Text(signedInEmail)
                .font(CarniFont.bold(22))
                .foregroundStyle(CarniColors.purpleDark)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(CarniColors.purple)
                .padding(.top, 60)
            Spacer()
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
            StatCard(
                icon: "pawprint.fill",
                tint: CarniColors.purple,
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
            SectionHeader(
                title: lang.t("home.recentActions"),
                actionTitle: lang.t("home.seeAll"),
                action: onSeeAllAnimals
            )

            if store.events.isEmpty {
                emptyEvents
            } else {
                VStack(spacing: 10) {
                    ForEach(store.events) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }

    private var emptyEvents: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive.opacity(0.5))
            Text(lang.t("home.noEvents"))
                .font(CarniFont.regular(14))
                .foregroundStyle(CarniColors.tabInactive)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .carniCard()
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
                .font(CarniFont.bold(21))
                .foregroundStyle(CarniColors.purpleDark)
            Text(label)
                .font(CarniFont.regular(12))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carniCard(padding: 14)
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
                    .font(CarniFont.semibold(14))
                    .foregroundStyle(CarniColors.purpleDark)
                    .lineLimit(1)
                Text(lang.timeAgo(event.date))
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
            }

            Spacer()

            Image(systemName: event.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(event.color)
                .padding(8)
                .background(Circle().fill(event.color.opacity(0.12)))
        }
        .carniCard(padding: 12)
    }
}
