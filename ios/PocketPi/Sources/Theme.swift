import SwiftUI
import UIKit

/// The web app's lime on system surfaces: one lime
/// "signal" that only shows when something is live or is the primary action
/// (send). Controls use the graphite AccentColor, not the lime.
enum Theme {
    static let signal = Color(red: 0xB8 / 255, green: 0xF1 / 255, blue: 0x3A / 255)
    static let signalInk = Color(red: 0x10 / 255, green: 0x14 / 255, blue: 0x0A / 255)
    /// The accent for text and controls: dark olive on light, the lime on dark.
    static let signalText = Color(light: Color(red: 0x4F / 255, green: 0x7A / 255, blue: 0), dark: signal)
    /// System backgrounds, so dark mode, Increase Contrast and later
    /// contrast changes reach them: bubbles and cards on the plain background.
    static let surface = Color(uiColor: .secondarySystemBackground)
    /// Code blocks and inline code: one step off the background.
    static let code = Color(uiColor: .secondarySystemBackground)
    /// Hairlines around cards (the system separator, stronger with
    /// Increase Contrast).
    static let hairline = Color(uiColor: .separator)
    static let danger = Color(red: 0xD0 / 255, green: 0x36 / 255, blue: 0x2C / 255)

    /// A stable hue per project path, like hue() in app.js.
    static func hue(_ s: String) -> Color {
        var h: UInt32 = 0
        for u in s.unicodeScalars { h = h &* 31 &+ u.value }
        return Color(hue: Double(h % 360) / 360, saturation: 0.45, brightness: 0.75)
    }
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}
