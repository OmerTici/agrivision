import SwiftUI

struct RootView: View {
    @State private var isAuthenticated = false

    var body: some View {
        ZStack {
            if isAuthenticated {
                MainTabView()
                    .transition(.opacity)
            } else {
                LandingView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        isAuthenticated = true
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
