import PocketPiKit
import SwiftUI

/// Which chats the middle column lists.
enum Scope: Hashable {
    case all
    case project(String)
    case archived
}

/// What the detail column shows.
enum ChatTarget: Hashable {
    case chat(path: String, cwd: String)
    /// A chat that doesn't exist yet; the id makes each "new chat" distinct.
    case new(cwd: String, id: UUID)
}

/// Apple's pattern for a list of containers (Mail's Mailboxes): a three-column
/// split view. On iPhone it collapses to a stack, Projects → chats → chat,
/// with the system back button and swipe; on iPad the columns sit side by
/// side. Opens on All chats, one step in, like Mail opens on Inbox.
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var scope: Scope? = .all
    @State private var target: ChatTarget?
    @State private var column: NavigationSplitViewColumn = .content

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            ProjectsView(scope: $scope)
        } content: {
            if let scope {
                ChatsView(scope: scope, target: $target) { column = .detail }
            } else {
                ContentUnavailableView("Pick a project", systemImage: "folder")
            }
        } detail: {
            NavigationStack {
                switch target {
                case .chat(let path, let cwd):
                    ChatView(path: path, cwd: cwd).id(target)
                case .new(let cwd, _):
                    ChatView(newIn: cwd).id(target)
                case nil:
                    ContentUnavailableView("No chat open", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Pick a chat or start one."))
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
                scope = scope ?? .all
                target = .chat(path: path, cwd: cwd)
                column = .detail
            case .run:
                break // workflow runs have no screen in the app yet
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.problem != nil },
            set: { if !$0 { model.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        // iPhone: backing out of a chat closes it, so it doesn't reopen.
        .onChange(of: column) { _, c in
            if c != .detail { target = nil }
        }
    }
}

// MARK: - projects (sidebar)

/// All chats, pinned projects, then the rest by last activity.
private struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Binding var scope: Scope?
    @State private var renaming: Project?
    @State private var newName = ""

    private var shown: [Project] { model.projects.filter(\.exists) }
    private var pinned: [Project] { shown.filter(\.pinned) }
    private var recent: [Project] { shown.filter { !$0.pinned }.sorted { $0.modified > $1.modified } }

    var body: some View {
        List(selection: $scope) {
            Section {
                ScopeRow(title: "All chats", count: model.sessions.count,
                         live: model.sessions.contains(where: \.streaming)) {
                    Image(systemName: "tray.full")
                }
                .tag(Scope.all)
                .accessibilityIdentifier("project-all")
            }
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned) { projectRow($0) } }
            }
            if !recent.isEmpty {
                Section(pinned.isEmpty ? "Projects" : "Recent") { ForEach(recent) { projectRow($0) } }
            }
            Section {
                ScopeRow(title: "Archived", count: model.archived.count, live: false) {
                    Image(systemName: "archivebox")
                }
                .tag(Scope.archived)
                .accessibilityIdentifier("project-archived")
            }
            if let e = model.loadError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
            }
        }
        .navigationTitle("Projects")
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Text(model.client?.server.display ?? "")
                    Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        model.disconnect()
                    }
                } label: {
                    Image(systemName: "server.rack")
                }
                .accessibilityLabel("Server")
            }
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let p = renaming { act { try await $0.saveProject(path: p.path, name: newName) } }
            }
        } message: {
            Text("Leave it empty for the folder's name.")
        }
    }

    private func projectRow(_ p: Project) -> some View {
        ScopeRow(title: p.name, count: p.chats, live: p.streaming) {
            ProjectBadge(path: p.path, name: p.name)
        }
        .tag(Scope.project(p.path))
        .accessibilityIdentifier("project-" + Format.baseName(p.path))
        .swipeActions(edge: .leading) {
            if !p.pinned {
                Button("Pin", systemImage: "pin") { act { try await $0.saveProject(path: p.path) } }
                    .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(p.pinned ? "Unpin and hide" : "Hide", systemImage: "eye.slash", role: .destructive) {
                if scope == .project(p.path) { scope = .all }
                act { try await $0.hideProject(path: p.path) }
            }
        }
        .contextMenu {
            if !p.pinned {
                Button("Pin", systemImage: "pin") { act { try await $0.saveProject(path: p.path) } }
            }
            Button("Rename", systemImage: "pencil") {
                newName = p.name
                renaming = p
            }
            Button(p.pinned ? "Unpin and hide" : "Hide", systemImage: "eye.slash", role: .destructive) {
                if scope == .project(p.path) { scope = .all }
                act { try await $0.hideProject(path: p.path) }
            }
        }
    }

    private func act(_ f: @escaping (PocketPiClient) async throws -> Void) {
        guard let client = model.client else { return }
        Task {
            try? await f(client)
            await model.refresh()
        }
    }
}

private struct ScopeRow<Icon: View>: View {
    let title: String
    let count: Int
    let live: Bool
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if live {
                Circle().fill(Theme.signal).frame(width: 7, height: 7)
                    .accessibilityLabel("working")
            }
            if count > 0 {
                Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - chats (content column)

private struct ChatsView: View {
    @Environment(AppModel.self) private var model
    let scope: Scope
    @Binding var target: ChatTarget?
    /// Show the detail column (iPhone): a new chat isn't a list selection.
    let showDetail: () -> Void
    @State private var search = ""
    @State private var renaming: SessionInfo?
    @State private var newName = ""

    private var project: String? {
        if case .project(let p) = scope { return p }
        return nil
    }

    private var isArchive: Bool { scope == .archived }
    private var source: [SessionInfo] { isArchive ? model.archived : model.sessions }

    private var visible: [SessionInfo] {
        source.filter { s in
            (project == nil || s.cwd == project)
                && (search.isEmpty || s.displayTitle.localizedCaseInsensitiveContains(search))
        }
    }

    /// The list's selection is the open chat (a new, unsaved chat has no row).
    private var selection: Binding<String?> {
        Binding(
            get: { if case .chat(let path, _) = target { return path } else { return nil } },
            set: { path in
                guard let path, let s = source.first(where: { $0.path == path }) else {
                    target = nil
                    return
                }
                target = .chat(path: s.path, cwd: s.cwd)
            })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(visible) { s in
                SessionRow(session: s, showProject: project == nil)
                    // One element per row: VoiceOver reads it as one line, and
                    // UI tests swipe the row rather than a label inside it.
                    .accessibilityElement(children: .combine)
                    .tag(s.path)
                    .accessibilityIdentifier("chat-row")
                    // Like Mail: a full swipe left archives.
                    .swipeActions(edge: .trailing) {
                        archiveButton(s)
                        Button("Rename", systemImage: "pencil") {
                            newName = s.displayTitle
                            renaming = s
                        }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            newName = s.displayTitle
                            renaming = s
                        }
                        archiveButton(s)
                    }
            }
            if visible.isEmpty, !model.loading, model.loadError == nil {
                Group {
                    if isArchive {
                        ContentUnavailableView("Nothing archived", systemImage: "archivebox",
                                               description: Text("Swipe left on a chat to archive it."))
                    } else {
                        ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Start one with the pencil."))
                    }
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .modifier(ChatsSearch(search: $search, newChat: newChatButton))
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let s = renaming, let client = model.client else { return }
                let name = newName
                Task {
                    try? await client.renameSession(s, to: name)
                    await model.refresh()
                }
            }
        }
        .refreshable { await model.refresh() }
        .navigationTitle(isArchive ? "Archived" : project.map(model.projectName(for:)) ?? "All chats")
    }

    @ViewBuilder private func archiveButton(_ s: SessionInfo) -> some View {
        if isArchive {
            Button("Unarchive", systemImage: "tray.and.arrow.up") { archive(s, false) }
                .tint(.blue)
        } else {
            Button("Archive", systemImage: "archivebox") { archive(s, true) }
                .tint(.indigo)
        }
    }

    private func archive(_ s: SessionInfo, _ on: Bool) {
        if case .chat(let path, _) = target, path == s.path { target = nil }
        Task { await model.archive(s, on) }
    }

    private var newChatButton: some View {
        NewChatButton(project: project) { cwd in
            target = .new(cwd: cwd, id: UUID())
            showDetail()
        }
    }
}

/// iOS 26: search and new chat in the bottom toolbar, like Mail. Search sits
/// as a button that expands when tapped. A search field in the navigation bar
/// stays behind (cross-fades) while the page slides during the back swipe;
/// the bottom toolbar moves with the page. iOS 18: the field under the title.
private struct ChatsSearch<NewChat: View>: ViewModifier {
    @Binding var search: String
    let newChat: NewChat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content
                .searchable(text: $search)
                .searchToolbarBehavior(.minimize)
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { newChat }
                }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { newChat }
            }
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
