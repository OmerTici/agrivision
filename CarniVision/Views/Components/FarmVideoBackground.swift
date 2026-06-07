import SwiftUI

struct FarmVideoBackground: View {
    var purpleOverlayOpacity: Double = 0.25

    var body: some View {
        ZStack {
            LoopingVideoPlayer(resourceName: "farm_background")
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    CarniColors.purpleLight,
                    CarniColors.purple,
                    CarniColors.purpleDark,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(purpleOverlayOpacity)
            .ignoresSafeArea()
        }
    }
}

struct VideoAuthBackground<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            FarmVideoBackground(purpleOverlayOpacity: 0.45)
            content
        }
    }
}
