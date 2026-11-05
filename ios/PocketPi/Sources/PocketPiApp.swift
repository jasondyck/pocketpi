import PocketPiKit
import SwiftUI

@main
struct PocketPiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.signalText)
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
        }
    }
}

/// The server this phone talks to and the lists every screen shares.
@MainActor
@Observable
final class AppModel {
    private static let serverKey = "server"

    private(set) var client: PocketPiClient?
    private(set) var projects: [Project] = []
    private(set) var sessions: [SessionInfo] = []
    private(set) var home: String?
    private(set) var loadError: String?
    private(set) var loading = false

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
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        client = nil
        projects = []
        sessions = []
    }

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
