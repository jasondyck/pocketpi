import PocketPiKit
import SwiftUI

/// Which chats the middle column lists.
enum Scope: Hashable {
    case all
    case project(String)
    case archived
    case approvals
}

/// What the detail column shows.
enum ChatTarget: Hashable {
    case chat(path: String, cwd: String)
    /// A chat that doesn't exist yet; the id makes each "new chat" distinct.
    case new(cwd: String, id: UUID)
    /// A workflow run waiting for an approval.
    case approval(runId: String)
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
            if scope == .approvals {
                ApprovalsList(target: $target)
            } else if let scope {
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
                case .approval(let runId):
                    ApprovalView(runId: runId) {
                        target = nil
                        column = .content
                    }
                    .id(target)
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
            case .run(let id):
                await model.refresh()
                scope = .approvals
                target = .approval(runId: id)
                column = .detail
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
                // The lime dot: something is waiting for you.
                ScopeRow(title: "Approvals", count: model.approvals.count, live: !model.approvals.isEmpty) {
                    Image(systemName: "checkmark.seal")
                }
                .tag(Scope.approvals)
                .accessibilityIdentifier("project-approvals")
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

// MARK: - approvals

/// Workflow runs waiting for you (a PR review to post, a release to publish).
private struct ApprovalsList: View {
    @Environment(AppModel.self) private var model
    @Binding var target: ChatTarget?

    private var selection: Binding<String?> {
        Binding(
            get: { if case .approval(let id) = target { return id } else { return nil } },
            set: { id in target = id.map { .approval(runId: $0) } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(model.approvals) { run in
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.headline).lineLimit(2)
                    if let v = run.verdict {
                        VerdictLabel(verdict: v)
                    }
                    HStack(spacing: 6) {
                        Text(run.workflowName)
                        Text(run.createdDate, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .tag(run.id)
                .accessibilityIdentifier("approval-row")
            }
            if model.approvals.isEmpty {
                ContentUnavailableView("Nothing to approve", systemImage: "checkmark.seal",
                                       description: Text("Workflows that need your OK show up here."))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .navigationTitle("Approvals")
        // Runs move on their own (and other devices answer too): keep fresh.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await model.refresh()
            }
        }
    }
}

/// A review's verdict as a small coloured label: green for pass, orange for
/// changes requested (colour carries meaning here, per the HIG).
private struct VerdictLabel: View {
    let verdict: String
    private var pass: Bool { verdict.lowercased().hasPrefix("pass") }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: pass ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(verdict.prefix(1).uppercased() + verdict.dropFirst())
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(pass ? Color.green : Color.orange)
        .accessibilityElement(children: .combine)
    }
}

/// One approval: what the workflow wants to do, in full, and the answer.
private struct ApprovalView: View {
    @Environment(AppModel.self) private var model
    let runId: String
    let done: () -> Void
    @State private var busy = false
    @State private var confirmApprove = false

    private var run: RunInfo? { model.approvals.first { $0.id == runId } }

    var body: some View {
        Group {
            if let run, let stage = run.waitingApproval {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(run.headline).font(.title2.weight(.semibold))
                        Text(run.workflowName + " · " + Self.started(run.trigger))
                            .font(.footnote).foregroundStyle(.secondary)
                        // The text without its first line, which is the title above.
                        MarkdownView(text: Self.body(of: stage.prompt ?? "", headline: run.headline))
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Reject", role: .destructive) { answer(run, false) }
                            .disabled(busy)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Approve") { confirmApprove = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                            .accessibilityIdentifier("approve")
                            // On the button, so iOS 26 points the confirmation at it.
                            .confirmationDialog(run.headline, isPresented: $confirmApprove, titleVisibility: .visible) {
                                Button("Approve") { answer(run, true) }
                            } message: {
                                Text("The workflow carries on, for example posting the comment or publishing.")
                            }
                    }
                }
            } else {
                ContentUnavailableView("Already answered", systemImage: "checkmark.seal",
                                       description: Text("This run isn't waiting any more."))
            }
        }
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The approval text minus a first line that just repeats the headline.
    static func body(of prompt: String, headline: String) -> String {
        var lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first,
           first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
               .trimmingCharacters(in: .whitespaces) == headline {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How the run began, in words.
    static func started(_ trigger: String) -> String {
        switch trigger {
        case "manual": "started manually"
        case "agent": "started by pi"
        case "schedule": "started on a schedule"
        case "webhook": "started by a webhook"
        case "": "started"
        default: "started by a new " + trigger // pr, issue, commit sensors
        }
    }

    private func answer(_ run: RunInfo, _ approve: Bool) {
        busy = true
        Task {
            if await model.answer(run, approve: approve) { done() }
            busy = false
        }
    }
}
