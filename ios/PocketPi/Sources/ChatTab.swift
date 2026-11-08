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
}

struct ChatTab: View {
    @Environment(AppModel.self) private var model

    private var path: Binding<[ChatRoute]> {
        Binding(get: { model.chatPath }, set: { model.chatPath = $0 })
    }

    var body: some View {
        NavigationStack(path: path) {
            List {
                ForEach(model.chats) { s in
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
                    }
                }
            }
            .overlay {
                if model.chats.isEmpty {
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.chatPath.append(.new(UUID())) } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(model.chatDir == nil)
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("new-chat-tab")
                }
            }
            .refreshable { await model.refresh() }
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .open(let p):
                    ChatView(path: p, cwd: model.chatDir ?? "~")
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

    private func archive(_ s: SessionInfo) async {
        do {
            try await model.client?.archiveSession(path: s.path)
        } catch {
            model.problem = "Couldn't archive: " + error.localizedDescription
        }
        await model.refresh()
    }
}
