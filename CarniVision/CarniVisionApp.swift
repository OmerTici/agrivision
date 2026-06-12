import SwiftUI

@main
struct CarniVisionApp: App {
    @StateObject private var auth: AuthService
    @StateObject private var recognition: CloudRunRecognitionService

    init() {
        // Build a recognition service whose token is read from the live session.
        let authService = AuthService()
        _auth = StateObject(wrappedValue: authService)
        _recognition = StateObject(wrappedValue: CloudRunRecognitionService(
            baseURL: AppConfig.embedderBaseURL,
            tokenProvider: { [weak authService] in authService?.accessToken }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(recognition)
                .task {
                    await auth.bootstrap()
                    await recognition.warmUp()
                }
        }
    }
}
