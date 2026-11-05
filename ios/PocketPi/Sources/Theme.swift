import SwiftUI
import UIKit

/// The web app's palette (web/app.css): graphite surfaces and one lime
/// "signal" that only shows when something is live.
enum Theme {
    static let signal = Color(red: 0xB8 / 255, green: 0xF1 / 255, blue: 0x3A / 255)
    static let signalInk = Color(red: 0x10 / 255, green: 0x14 / 255, blue: 0x0A / 255)
    /// The accent for text and controls: dark olive on light, the lime on dark.
    static let signalText = Color(light: Color(red: 0x4F / 255, green: 0x7A / 255, blue: 0), dark: signal)
    static let surface = Color(light: Color(red: 0xED / 255, green: 0xED / 255, blue: 0xEA / 255),
                               dark: Color(red: 0x22 / 255, green: 0x23 / 255, blue: 0x25 / 255))
    static let code = Color(light: Color(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF0 / 255),
                            dark: Color(red: 0x1A / 255, green: 0x1B / 255, blue: 0x1D / 255))
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
