import PocketPiKit
import SwiftUI

/// The Chat tab: plain conversations with any model, pi's enabled ones, the
/// rest, or one on the llama.cpp router. pi has no tools here (the server
/// starts it that way in its chat folder), and these chats stay out of Work.
/// A screen in the Chat tab's stack (kept in the app model, so the tab
/// opens where it was left, and a notification can open a chat in it).
enum ChatRoute: Hashable {
    case open(String)
    case new(UUID)
    case archived
}

struct ChatTab: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var renaming: SessionInfo?
    @State private var newName = ""

    private var visible: [SessionInfo] {
        search.isEmpty ? model.chats : model.chats.filter { $0.displayTitle.localizedCaseInsensitiveContains(search) }
    }

    private var path: Binding<[ChatRoute]> {
        Binding(get: { model.chatPath }, set: { model.chatPath = $0 })
    }

    var body: some View {
        NavigationStack(path: path) {
            List {
                ForEach(visible) { s in
                    NavigationLink(value: ChatRoute.open(s.path)) {
                        SessionRow(session: s, showProject: false, showBadge: false)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chat-tab-row")
                    .swipeActions(edge: .trailing) {
                        Button("Archive", systemImage: "archivebox") {
                            Task { await archive(s) }
                        }
                        .tint(.indigo)
                        Button("Rename", systemImage: "pencil") { startRename(s) }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { startRename(s) }
                        Button("Archive", systemImage: "archivebox") { Task { await archive(s) } }
                    }
                }
            }
            .overlay {
                if !search.isEmpty, visible.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if model.chats.isEmpty {
                    ContentUnavailableView {
                        Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Talk with any model, including local ones on the llama.cpp router. pi has no tools here: it only talks.")
                    } actions: {
                        if model.chatDir != nil {
                            Button("New chat") { model.chatPath.append(.new(UUID())) }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.signal)
                                .foregroundStyle(Theme.signalInk)
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            // Search and the new-chat button where Work's chat list has them.
            .modifier(ChatsSearch(search: $search, newChat: newChatButton))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: ChatRoute.archived) {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityLabel("Archived chats")
                    .accessibilityIdentifier("chat-tab-archived")
                }
            }
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard let s = renaming, let client = model.client else { return }
                    let name = newName
                    Task {
                        do { try await client.renameSession(s, to: name) } catch {
                            model.problem = "Couldn't rename: " + error.localizedDescription
                        }
                        await model.refresh()
                    }
                }
            }
            .refreshable { await model.refresh() }
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .open(let p):
                    ChatView(path: p, cwd: model.chatDir ?? "~")
                case .archived:
                    ArchivedChats()
                case .new:
                    if let dir = model.chatDir {
                        ChatView(newIn: dir)
                    } else {
                        ContentUnavailableView("This server has no Chat tab yet", systemImage: "exclamationmark.triangle",
                                               description: Text("Update pocketpi on the server."))
                    }
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.problem != nil && model.mode == .chat },
            set: { if !$0 { model.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        .onChange(of: model.chatPath) { _, p in
            // Back on the list: a chat that was just started now has a row.
            if p.isEmpty { Task { await model.refresh() } }
        }
    }

    private var newChatButton: some View {
        Button { model.chatPath.append(.new(UUID())) } label: {
            Image(systemName: "square.and.pencil")
        }
        .disabled(model.chatDir == nil)
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("new-chat-tab")
    }

    private func startRename(_ s: SessionInfo) {
        newName = s.displayTitle
        renaming = s
    }

    private func archive(_ s: SessionInfo) async {
        do {
            try await model.client?.archiveSession(path: s.path)
        } catch {
            model.problem = "Couldn't archive: " + error.localizedDescription
        }
        await model.refresh()
    }
}

/// The Chat tab's archived chats: open one to read it, swipe to bring it
/// back or delete it for good.
private struct ArchivedChats: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: SessionInfo?

    var body: some View {
        List {
            ForEach(model.archivedChats) { s in
                NavigationLink(value: ChatRoute.open(s.path)) {
                    SessionRow(session: s, showProject: false, showBadge: false)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("archived-chat-row")
                // Delete asks first, so no full swipe and no destructive role
                // (which removes the row before the answer).
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash") { deleting = s }
                        .tint(.red)
                    Button("Unarchive", systemImage: "tray.and.arrow.up") {
                        Task { await unarchive(s) }
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button("Unarchive", systemImage: "tray.and.arrow.up") { Task { await unarchive(s) } }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = s }
                }
            }
        }
        .overlay {
            if model.archivedChats.isEmpty {
                ContentUnavailableView("Nothing archived", systemImage: "archivebox",
                                       description: Text("Swipe left on a chat to archive it."))
            }
        }
        .deleteChatConfirmation($deleting)
        .refreshable { await model.refresh() }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func unarchive(_ s: SessionInfo) async {
        do {
            try await model.client?.archiveSession(path: s.path, archived: false)
        } catch {
            model.problem = "Couldn't unarchive: " + error.localizedDescription
        }
        await model.refresh()
    }
}
