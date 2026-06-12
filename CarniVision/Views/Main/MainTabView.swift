import SwiftUI

struct MainTabView: View {
    @State private var selected: AppTab = .home
    @State private var showAddAnimal = false
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
        // MainTabView only exists while signed in (RootView), so this runs on
        // sign-in and on each cold launch with a restored session.
        .task { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .home:
            HomeScreen(onSeeAllAnimals: { selected = .animals })
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
        case .settings:
            SettingsScreen()
        }
    }
}
