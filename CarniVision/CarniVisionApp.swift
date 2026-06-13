import SwiftUI

@main
struct CarniVisionApp: App {
    @StateObject private var auth: AuthService
    @StateObject private var recognition: CloudRunRecognitionService

    init() {
        _auth = StateObject(wrappedValue: AuthService())
        // Always read a guaranteed-fresh token straight from the SDK session.
        // supabase-swift refreshes the access token transparently when it has expired,
        // so this never goes stale the way a sign-in snapshot would.
        _recognition = StateObject(wrappedValue: CloudRunRecognitionService(
            baseURL: AppConfig.embedderBaseURL,
            tokenProvider: { try? await SupabaseClientProvider.shared.auth.session.accessToken }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(recognition)
                .onOpenURL { url in
                    // Email-confirmation / magic-link deep link → finish sign-in.
                    Task { await auth.handleDeepLink(url) }
                }
                .task {
                    // Warmup now happens on user activity (MainTabView), not at launch,
                    // so a backgrounded-then-resumed app re-checks the sleeping container.
                    await auth.bootstrap()
                }
        }
    }
}
