import SwiftUI

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

struct HomeScreen: View {
    var body: some View {
        PlaceholderScreen(
            title: "Home",
            systemImage: "house.fill",
            subtitle: "Your dashboard will appear here."
        )
    }
}

struct AnimalsScreen: View {
    var body: some View {
        PlaceholderScreen(
            title: "Animals",
            systemImage: "pawprint.fill",
            subtitle: "Your animals list will appear here."
        )
    }
}

struct AddAnimalScreen: View {
    var body: some View {
        PlaceholderScreen(
            title: "Add Animal",
            systemImage: "plus.circle.fill",
            subtitle: "Add a new animal to your herd."
        )
    }
}

struct SettingsScreen: View {
    var body: some View {
        PlaceholderScreen(
            title: "Settings",
            systemImage: "gearshape.fill",
            subtitle: "App settings will appear here."
        )
    }
}
