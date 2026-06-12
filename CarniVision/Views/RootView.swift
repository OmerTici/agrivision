import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        ZStack {
            if auth.identity != nil {
                MainTabView()
                    .transition(.opacity)
            } else {
                LandingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: auth.identity)
    }
}
