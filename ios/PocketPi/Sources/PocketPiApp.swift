import PocketPiKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct PocketPiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            // No app-wide tint: controls stay graphite (AccentColor) and the
            // lime only marks live things and the send button (HIG: colour
            // sparingly, toolbar symbols monochrome).
            RootView()
                .environment(delegate.model)
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-dark") ? .dark : nil)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.client == nil {
            ConnectView()
        } else {
            ChatListView()
                .task { await model.enablePush() }
        }
    }
}

/// The UIKit side of notifications: the device token from APNs, and what to
/// do with a notification that arrives or is tapped.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push registration failed: \(error.localizedDescription)")
    }

    /// In the foreground too: the server only notifies for things worth it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let url = response.notification.request.content.userInfo["url"] as? String
        guard let url, let link = NotificationLink(url: url) else { return }
        await MainActor.run { self.model.pendingLink = link }
    }
}

/// The server this phone talks to and the lists every screen shares.
@MainActor
@Observable
final class AppModel {
    private static let serverKey = "server"
    private static let pushTokenKey = "pushToken"

    private(set) var client: PocketPiClient?
    private(set) var projects: [Project] = []
    private(set) var sessions: [SessionInfo] = []
    private(set) var home: String?
    private(set) var loadError: String?
    private(set) var loading = false
    /// A tapped notification, for the chat list to open.
    var pendingLink: NotificationLink?

    init() {
        // UI tests start with a clean slate and an address to type.
        if ProcessInfo.processInfo.arguments.contains("-reset") {
            UserDefaults.standard.removeObject(forKey: Self.serverKey)
        }
        if let s = UserDefaults.standard.string(forKey: Self.serverKey),
           let url = URL(string: s) {
            client = PocketPiClient(server: ServerAddress(url: url))
        }
    }

    /// Check the address answers like pocketpi before keeping it.
    func connect(to raw: String) async throws {
        let address = try ServerAddress(parsing: raw)
        let c = PocketPiClient(server: address)
        _ = try await c.version()
        UserDefaults.standard.set(address.url.absoluteString, forKey: Self.serverKey)
        client = c
        await refresh()
    }

    func disconnect() {
        if let client, let token = UserDefaults.standard.string(forKey: Self.pushTokenKey) {
            Task { try? await client.unregisterPush(token: token) }
        }
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        client = nil
        projects = []
        sessions = []
    }

    // MARK: - notifications

    /// Ask once (iOS remembers the answer), then get a device token. APNs
    /// hands one over on every launch; it is sent to the server each time.
    func enablePush() async {
        // UI tests: no permission alert over the screenshots.
        if ProcessInfo.processInfo.arguments.contains("-noPush") { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func didRegister(deviceToken: Data) {
        let token = NotificationLink.hexToken(deviceToken)
        UserDefaults.standard.set(token, forKey: Self.pushTokenKey)
        guard let client else { return }
        #if DEBUG
        let env = PocketPiClient.PushEnvironment.sandbox
        #else
        let env = PocketPiClient.PushEnvironment.production
        #endif
        let label = UIDevice.current.name
        Task {
            do { try await client.registerPush(token: token, environment: env, label: label) } catch {
                // 503: the server has no APNs key; the app works without push.
                print("push register: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - lists

    func refresh() async {
        guard let client else { return }
        loading = true
        defer { loading = false }
        do {
            async let p = client.projects()
            async let s = client.sessions()
            let (pr, ss) = try await (p, s)
            projects = pr.projects
            home = pr.home
            sessions = ss
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func projectName(for path: String) -> String {
        if let p = projects.first(where: { $0.path == path }) { return p.name }
        if path == home { return "Home" }
        return Format.baseName(path)
    }

    /// Where a new chat starts when no project is picked: the last one used.
    var lastCwd: String {
        get { UserDefaults.standard.string(forKey: "lastCwd") ?? home ?? "~" }
        set { UserDefaults.standard.set(newValue, forKey: "lastCwd") }
    }
}
