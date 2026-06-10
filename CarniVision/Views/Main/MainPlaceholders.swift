import SwiftUI

/// Generic placeholder for screens that haven't been built yet.
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(CarniColors.purple)

            Text(title)
                .font(CarniFont.bold(26))
                .foregroundStyle(CarniColors.purpleDark)

            Text(subtitle)
                .font(CarniFont.regular(15))
                .multilineTextAlignment(.center)
                .foregroundStyle(CarniColors.tabInactive)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
