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

enum AppMode: String {
    case work, chat
}


struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.client == nil {
            ConnectView()
        } else {
            // Work (projects, chats, workflows, approvals) and Chat (plain
            // conversations). On iOS 26 the tab bar floats as glass and
            // shrinks while scrolling down; chats hide it.
            TabView(selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                Tab("Work", systemImage: "hammer", value: AppMode.work) {
                    ChatListView()
                }
                .badge(model.approvals.count)
                Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: AppMode.chat) {
                    ChatTab()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .onChange(of: model.pendingLink, initial: true) { _, link in
                guard let link else { return }
                if case .chat(let p) = link, model.chats.contains(where: { $0.path == p }) {
                    model.pendingLink = nil
                    model.mode = .chat
                    model.chatPath = [.open(p)]
                } else {
                    model.mode = .work
                }
            }
            .onChange(of: model.openRequest) { _, req in if req != nil { model.mode = .work } }
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
        // Something changed on the server (an approval, a finished run).
        await MainActor.run { Task { await self.model.refresh() } }
        return [.banner, .list, .sound]
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
    private(set) var archived: [SessionInfo] = []
    /// The Chat tab's chats and their folder (pi without tools there).
    private(set) var chats: [SessionInfo] = []
    private(set) var archivedChats: [SessionInfo] = []
    private(set) var chatDir: String?
    /// Which tab is showing (a notification can switch it).
    var mode: AppMode = .work
    /// The Chat tab's stack, so a notification can open a chat in it.
    var chatPath: [ChatRoute] = []
    /// Workflow runs waiting for an approval, newest first.
    private(set) var approvals: [RunInfo] = []
    private(set) var workflows: [WorkflowInfo] = []
    /// Recent runs of every workflow, newest first.
    private(set) var runs: [RunInfo] = []
    var activeRuns: [RunInfo] { runs.filter(\.isActive) }
    private(set) var home: String?
    private(set) var loadError: String?
    /// An action that failed (archive), shown as an alert.
    var problem: String?
    private(set) var loading = false
    /// A tapped notification, for the chat list to open.
    var pendingLink: NotificationLink?
    /// A screen asking the split view to show something else (a workflow's
    /// Edit in chat opens a new chat in its project).
    var openRequest: OpenRequest?

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
        archived = []
        approvals = []
        workflows = []
        runs = []
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
            async let a = client.archivedSessions()
            async let r = client.runs()
            async let w = client.workflows()
            async let c = client.chats()
            let (pr, ss, aa, rr, ww) = try await (p, s, a, r, w)
            // An older server has no Chat tab; Work still loads.
            if let cc = try? await c {
                chats = cc.sessions
                chatDir = cc.chatDir.isEmpty ? nil : cc.chatDir
            }
            if let ac = try? await client.chats(archived: true) { archivedChats = ac.sessions }
            approvals = rr.filter { $0.waitingApproval != nil }
            runs = rr
            workflows = ww
            projects = pr.projects
            home = pr.home
            sessions = ss
            archived = aa
            loadError = nil
        } catch where error.isCancellation {
            // Cut short (left the screen, a newer refresh): keep what's shown.
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Archive (or bring back) a chat: moved between the lists at once, then
    /// saved; on failure the lists reload from the server and an alert says so.
    func archive(_ s: SessionInfo, _ on: Bool) async {
        guard let client else { return }
        if on {
            sessions.removeAll { $0.path == s.path }
            archived.insert(s, at: 0)
        } else {
            archived.removeAll { $0.path == s.path }
            sessions.insert(s, at: 0)
            sessions.sort { $0.modified > $1.modified }
        }
        do {
            try await client.archiveSession(path: s.path, archived: on)
        } catch {
            if let m = error.reportable { problem = (on ? "Couldn't archive: " : "Couldn't unarchive: ") + m }
        }
        await refresh()
    }

    /// Delete an archived chat for good: gone from the list at once, then
    /// from the server; on failure the lists reload and an alert says why.
    func delete(_ s: SessionInfo) async {
        guard let client else { return }
        archived.removeAll { $0.path == s.path }
        archivedChats.removeAll { $0.path == s.path }
        do {
            try await client.deleteSession(path: s.path)
        } catch {
            if let m = error.reportable { problem = "Couldn't delete: " + m }
        }
        await refresh()
    }

    /// Approve or reject a run's waiting stage; the list updates at once.
    func answer(_ run: RunInfo, approve: Bool) async -> Bool {
        guard let client, let stage = run.waitingApproval else { return false }
        do {
            try await client.answer(run: run.id, stage: stage.id, approve: approve)
            approvals.removeAll { $0.id == run.id }
            await refresh()
            return true
        } catch {
            if let m = error.reportable { problem = (approve ? "Couldn't approve: " : "Couldn't reject: ") + m }
            await refresh()
            return false
        }
    }

    func projectName(for path: String) -> String {
        if path == chatDir { return "Chat" }
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

/// Where to go: the list (middle column) and what it shows.
struct OpenRequest: Equatable {
    var scope: Scope
    /// nil: just the list.
    var target: ChatTarget?
}
