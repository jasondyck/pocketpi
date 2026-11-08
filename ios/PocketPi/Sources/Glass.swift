import SwiftUI

/// Liquid Glass for the app's own floating controls (composer, jump button,
/// run lines). System bars, toolbars, menus, search and sheets get glass by
/// themselves.
extension View {
    func glass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
    }
}
