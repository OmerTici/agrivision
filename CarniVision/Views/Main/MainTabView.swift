import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var recognition: CloudRunRecognitionService
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var lang = LanguageManager.shared
    @State private var selected: AppTab = .home
    @State private var showAddAnimal = false
    @State private var showSettings = false
    @StateObject private var store = HerdStore()

    var body: some View {
        ZStack(alignment: .bottom) {
            CarniColors.appBackground
                .ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(store)

            if selected != .camera {
                CarniTabBar(selected: $selected)
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
        .sheet(isPresented: $showSettings) {
            // Sheets present in a detached context; re-inject the objects
            // Settings depends on so they survive the presentation boundary.
            SettingsScreen(onClose: { showSettings = false })
                .environmentObject(auth)
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .home:
            HomeScreen(
                onSeeAllAnimals: { selected = .animals },
                onOpenSettings: { showSettings = true }
            )
        case .animals:
            AnimalsScreen(showAddAnimal: $showAddAnimal)
        case .camera:
            CameraScreen(
                onClose: { selected = .home },
                onRequestEnroll: {
                    // Unknown identify -> offer enrollment via the Add form.
                    selected = .animals
                    showAddAnimal = true
                }
            )
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
                .font(CarniFont.semibold(13))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Capsule().fill(background))
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
