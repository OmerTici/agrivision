import SwiftUI

struct MainTabView: View {
    @State private var selected: AppTab = .home
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
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .home:
            HomeScreen(onSeeAllAnimals: { selected = .animals })
        case .animals:
            AnimalsScreen()
        case .camera:
            CameraScreen(onClose: { selected = .home })
        case .addAnimal:
            AddAnimalScreen()
        case .settings:
            SettingsScreen()
        }
    }
}
