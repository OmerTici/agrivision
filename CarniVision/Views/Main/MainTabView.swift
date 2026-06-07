import SwiftUI

struct MainTabView: View {
    @State private var selected: AppTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            CarniColors.appBackground
                .ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selected != .camera {
                CarniTabBar(selected: $selected)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .home:
            HomeScreen()
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
