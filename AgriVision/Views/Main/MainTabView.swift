import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var recognition: CloudRunRecognitionService
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var lang = LanguageManager.shared
    @State private var selected: AppTab = .home
    @StateObject private var store = HerdStore()
    /// Muzzle carried from an unknown identify result into the Add-Animal hub.
    @State private var carriedMuzzleCrop: UIImage?
    @State private var carriedMuzzleFull: UIImage?
    /// Tag number carried from a not-registered ear-tag read into the Add hub.
    @State private var carriedTag: String?
    /// Animal whose profile the Animals tab should open on arrival (camera
    /// match -> "Go to profile"). Cleared once the tab consumes it.
    @State private var openAnimalID: UUID?
    var body: some View {
        ZStack(alignment: .bottom) {
            AgriColors.appBackground
                .ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(store)

            if selected != .camera {
                AgriTabBar(selected: $selected)
            }

            VStack {
                ServerStatusPill(status: recognition.status,
                                 lang: lang,
                                 onRetry: { Task { await recognition.warmUp() } })
                Spacer()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: recognition.status)
        // MainTabView only exists while signed in (RootView), so this runs on
        // sign-in and on each cold launch with a restored session.
        .task {
            await store.load()
            await recognition.warmUp()
        }
        // Re-warm when the app returns to the foreground: the scale-to-zero
        // container may have slept while the app was backgrounded.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await recognition.warmUp() } }
        }
        // Drop the carried muzzle once the user leaves the Add hub, so a manual
        // "Add animal" later starts without a stale seed.
        .onChange(of: selected) { _, tab in
            if tab != .addAnimal {
                carriedMuzzleCrop = nil
                carriedMuzzleFull = nil
                carriedTag = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .home:
            HomeScreen(
                onSeeAllAnimals: { selected = .animals },
                onOpenSettings: { selected = .settings }
            )
        case .animals:
            AnimalsScreen(
                onAddAnimal: { selected = .addAnimal },
                deepLinkAnimalID: openAnimalID,
                onDeepLinkHandled: { openAnimalID = nil }
            )
        case .camera:
            CameraScreen(
                onClose: { selected = .home },
                onRequestEnroll: { crop, full in
                    // Unknown identify -> carry the captured muzzle into the Add hub.
                    carriedMuzzleCrop = crop
                    carriedMuzzleFull = full
                    selected = .addAnimal
                },
                onRequestEnrollTag: { tag in
                    // Not-registered ear tag -> Add hub with the number filled in.
                    carriedTag = tag
                    selected = .addAnimal
                },
                onOpenAnimal: { id in
                    // Matched animal -> its profile on the Animals tab.
                    openAnimalID = id
                    selected = .animals
                }
            )
        case .addAnimal:
            AddAnimalScreen(
                onOpenHerd: { selected = .animals },
                carriedMuzzleCrop: carriedMuzzleCrop,
                carriedMuzzleFull: carriedMuzzleFull,
                carriedTag: carriedTag
            )
        case .settings:
            SettingsScreen()
        }
    }
}

/// Floating status indicator. Silent when the server is healthy (online/unknown);
/// shows an amber "connecting" pill or a red tap-to-retry "offline" pill otherwise.
private struct ServerStatusPill: View {
    let status: ServerStatus
    @ObservedObject var lang: LanguageManager
    let onRetry: () -> Void

    var body: some View {
        switch status {
        case .connecting:
            pill(text: lang.t("server.status.connecting"),
                 background: Color.orange.opacity(0.92),
                 showsSpinner: true)
                .allowsHitTesting(false)
        case .offline:
            Button(action: onRetry) {
                pill(text: lang.t("server.status.offline"),
                     background: Color.red.opacity(0.92),
                     showsSpinner: false)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
        case .online, .unknown:
            EmptyView()
        }
    }

    private func pill(text: String, background: Color, showsSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            if showsSpinner {
                ProgressView().tint(.white).scaleEffect(0.8)
            }
            Text(text)
                .font(AgriFont.semibold(13))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Capsule().fill(background))
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
