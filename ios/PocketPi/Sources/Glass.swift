import SwiftUI

/// Liquid Glass (iOS 26) for the app's own floating controls, with the old
/// material on iOS 18. System bars, toolbars, menus, search and sheets get
/// glass by themselves when built with the iOS 26 SDK; this is for the custom
/// pieces (composer, jump button, toasts, banners).
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
        #else
        self.background(.regularMaterial, in: shape)
        #endif
    }
}

enum LiquidGlass {
    /// True when the app was built with the iOS 26 SDK and runs on iOS 26.
    static var available: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }
}
