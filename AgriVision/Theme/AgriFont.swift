import SwiftUI

enum AgriFont {
    static func regular(_ size: CGFloat) -> Font {
        .custom("Lato-Regular", size: size)
    }

    static func semibold(_ size: CGFloat) -> Font {
        .custom("Lato-SemiBold", size: size)
    }

    static func bold(_ size: CGFloat) -> Font {
        .custom("Lato-Bold", size: size)
    }
}
