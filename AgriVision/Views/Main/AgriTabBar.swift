import SwiftUI

enum AppTab: Hashable {
    case home
    case animals
    case camera
    case addAnimal
    case settings
}

/// White bar that is flat on the sides and rises into a soft-edged square hump
/// in the center, wrapping up and over the (square) camera button.
struct RaisedCenterTabBarShape: Shape {
    var bumpWidth: CGFloat = 80
    var bumpHeight: CGFloat = 18
    var cornerRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let bw = bumpWidth / 2
        let top = rect.minY
        let flat = rect.minY + bumpHeight
        let r = min(cornerRadius, bumpHeight)
        let fillet = min(r * 0.7, bumpHeight)

        path.move(to: CGPoint(x: rect.minX, y: flat))
        path.addLine(to: CGPoint(x: cx - bw - fillet, y: flat))
        // Concave fillet where the flat bar curves up into the hump.
        path.addQuadCurve(
            to: CGPoint(x: cx - bw, y: flat - fillet),
            control: CGPoint(x: cx - bw, y: flat)
        )
        path.addLine(to: CGPoint(x: cx - bw, y: top + r))
        // Soft top-left corner of the square hump.
        path.addQuadCurve(
            to: CGPoint(x: cx - bw + r, y: top),
            control: CGPoint(x: cx - bw, y: top)
        )
        path.addLine(to: CGPoint(x: cx + bw - r, y: top))
        // Soft top-right corner.
        path.addQuadCurve(
            to: CGPoint(x: cx + bw, y: top + r),
            control: CGPoint(x: cx + bw, y: top)
        )
        path.addLine(to: CGPoint(x: cx + bw, y: flat - fillet))
        // Concave fillet back down to the flat bar.
        path.addQuadCurve(
            to: CGPoint(x: cx + bw + fillet, y: flat),
            control: CGPoint(x: cx + bw, y: flat)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: flat))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct AgriTabBar: View {
    @Binding var selected: AppTab
    @ObservedObject private var lang = LanguageManager.shared

    private let bumpHeight: CGFloat = 16

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TabBarItem(
                icon: "house",
                selectedIcon: "house.fill",
                label: lang.t("tab.home"),
                tab: .home,
                selected: $selected
            )

            TabBarItem(
                icon: "pawprint",
                selectedIcon: "pawprint.fill",
                label: lang.t("tab.animals"),
                tab: .animals,
                selected: $selected
            )

            CameraTabButton {
                selected = .camera
            }

            TabBarItem(
                icon: "plus",
                selectedIcon: "plus",
                label: lang.t("tab.add"),
                tab: .addAnimal,
                selected: $selected
            )

            TabBarItem(
                icon: "gearshape",
                selectedIcon: "gearshape.fill",
                label: lang.t("tab.settings"),
                tab: .settings,
                selected: $selected
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            RaisedCenterTabBarShape(bumpWidth: 84, bumpHeight: bumpHeight)
                .fill(AgriColors.tabBar)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

private struct TabBarItem: View {
    let icon: String
    let selectedIcon: String
    let label: String
    let tab: AppTab
    @Binding var selected: AppTab

    private var isSelected: Bool { selected == tab }

    var body: some View {
        Button {
            selected = tab
        } label: {
            VStack(spacing: 5) {
                Image(systemName: isSelected ? selectedIcon : icon)
                    .font(.system(size: 22, weight: .regular))
                Text(label)
                    .font(AgriFont.regular(11))
            }
            .foregroundStyle(isSelected ? AgriColors.purple : AgriColors.tabInactive)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct CameraTabButton: View {
    let action: () -> Void

    // 1.25x+ the footprint of a regular tab item (icon + label ≈ 40pt tall).
    private let size: CGFloat = 56
    private let cornerRadius: CGFloat = 16

    var body: some View {
        Button(action: action) {
            Image(systemName: "camera.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(AgriColors.white)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(AgriColors.purple)
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}
