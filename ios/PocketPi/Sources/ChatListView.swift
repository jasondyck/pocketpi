import PocketPiKit
import SwiftUI

enum Route: Hashable {
    case chat(path: String, cwd: String)
    case newChat(cwd: String)
}

/// Chats, newest first, filtered by project. The drawer of the web app.
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var route: [Route] = []
    @State private var project: String?
    @State private var search = ""

    private var visible: [SessionInfo] {
        model.sessions.filter { s in
            (project == nil || s.cwd == project)
                && (search.isEmpty || s.displayTitle.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack(path: $route) {
            List {
                if model.projects.count > 1 {
                    ProjectStrip(selected: $project)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if let e = model.loadError {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
                }
                ForEach(visible) { s in
                    NavigationLink(value: Route.chat(path: s.path, cwd: s.cwd)) {
                        SessionRow(session: s, showProject: project == nil)
                    }
                }
                if visible.isEmpty, !model.loading, model.loadError == nil {
                    ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Start one with the pencil."))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
            .refreshable { await model.refresh() }
            .navigationTitle(project.map(model.projectName(for:)) ?? "Chats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Text(model.client?.server.display ?? "")
                        Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            model.disconnect()
                        }
                    } label: { Image(systemName: "server.rack") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NewChatButton(project: project) { cwd in route.append(.newChat(cwd: cwd)) }
                }
            }
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .chat(let path, let cwd): ChatView(path: path, cwd: cwd)
                case .newChat(let cwd): ChatView(newIn: cwd)
                }
            }
        }
        .task { await model.refresh() }
        // A tapped notification, also on a cold launch (set before this appeared).
        .task(id: model.pendingLink) {
            guard let link = model.pendingLink else { return }
            model.pendingLink = nil
            switch link {
            case .chat(let path):
                // The server answers with the real folder when the chat opens.
                let cwd = model.sessions.first { $0.path == path }?.cwd ?? model.home ?? "~"
                route = [.chat(path: path, cwd: cwd)]
            case .run:
                break // workflow runs have no screen in the app yet
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }
}

private struct ProjectStrip: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", path: nil, live: false)
                ForEach(model.projects.filter(\.exists)) { p in
                    chip(p.name, path: p.path, live: p.streaming)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, path: String?, live: Bool) -> some View {
        let on = selected == path
        return Button {
            selected = path
        } label: {
            HStack(spacing: 5) {
                if live { Circle().fill(Theme.signal).frame(width: 6, height: 6) }
                Text(title).font(.subheadline.weight(on ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(on ? Color.primary.opacity(0.12) : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionInfo
    let showProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProjectBadge(path: session.cwd, name: model.projectName(for: session.cwd))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle).lineLimit(2)
                HStack(spacing: 6) {
                    if session.streaming {
                        Circle().fill(Theme.signal).frame(width: 7, height: 7)
                        Text("working").foregroundStyle(Theme.signalText)
                    }
                    if showProject { Text(model.projectName(for: session.cwd)) }
                    Text(session.modifiedDate, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProjectBadge: View {
    let path: String
    let name: String

    var body: some View {
        let letters = name.split(whereSeparator: { " -_.".contains($0) }).prefix(2).compactMap(\.first)
        Text(String(letters).uppercased())
            .font(.caption2.weight(.bold).monospaced())
            .frame(width: 28, height: 28)
            .background(Theme.hue(path).opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(Theme.hue(path))
    }
}

/// New chat in the selected project, or a menu of projects when none is.
private struct NewChatButton: View {
    @Environment(AppModel.self) private var model
    let project: String?
    let start: (String) -> Void

    var body: some View {
        if let project {
            Button { begin(project) } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New chat")
        } else {
            Menu {
                ForEach(model.projects.filter(\.exists)) { p in
                    Button(p.name) { begin(p.path) }
                }
                if let home = model.home { Button("Home") { begin(home) } }
            } label: {
                Image(systemName: "square.and.pencil")
            } primaryAction: {
                begin(model.lastCwd)
            }
            .accessibilityLabel("New chat")
        }
    }

    private func begin(_ cwd: String) {
        model.lastCwd = cwd
        start(cwd)
    }
}
