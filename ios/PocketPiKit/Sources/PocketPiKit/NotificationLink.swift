import Foundation

/// Where a tapped notification should go. pocketpi's notifications carry the
/// web app's URL (`/?s=<session file>` for a chat, `/?r=<run id>` for a
/// workflow run, `/?w=<id>` for a workflow that improved itself or has a
/// suggestion); the app maps them to its own screens.
public enum NotificationLink: Equatable, Sendable {
    case chat(path: String)
    case run(id: String)
    case workflow(id: String)

    public init?(url: String) {
        guard let c = URLComponents(string: url), let items = c.queryItems else { return nil }
        if let s = items.first(where: { $0.name == "s" })?.value, !s.isEmpty { self = .chat(path: s); return }
        if let r = items.first(where: { $0.name == "r" })?.value, !r.isEmpty { self = .run(id: r); return }
        if let w = items.first(where: { $0.name == "w" })?.value, !w.isEmpty { self = .workflow(id: w); return }
        return nil
    }

    /// Data from APNs (`didRegisterForRemoteNotificationsWithDeviceToken`) as
    /// the hex string the server wants.
    public static func hexToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
