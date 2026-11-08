import PocketPiKit
import SwiftUI

// A chat's tools (title menu › Tools; docs/pi-parity-plan.md F5): every tool
// the chat's pi has, grouped (built-in, extensions, MCP servers), with a
// switch each. State and calls are PocketPiKit's ChatToolsModel; the web
// twin is web/chat-tools.js. ChatView hooks it in with one menu button and
// one `.chatToolsSheet` modifier.

/// The title menu's "Tools" row. Only chats with pocketpi-control (not the
/// Chat tab) have one, and only once their pi runs.
struct ChatToolsMenuButton: View {
    let session: ChatSession
    @Binding var shown: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if session.cwd != model.chatDir {
            Button("Tools", systemImage: "wrench.and.screwdriver") { shown = true }
                .disabled(session.key == nil)
        }
    }
}

extension View {
    /// Presents the Tools screen for `session` while `isPresented`.
    func chatToolsSheet(isPresented: Binding<Bool>, session: ChatSession) -> some View {
        sheet(isPresented: isPresented) {
            if let key = session.key {
                ChatToolsView(model: ChatToolsModel(client: session.client, key: key))
            }
        }
    }
}

struct ChatToolsView: View {
    @State var model: ChatToolsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !model.loaded, model.problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(model.sections.map { $0.group }, id: \.self) { group in
                    let tools = model.sections.first { $0.group == group }?.tools ?? []
                    Section {
                        ForEach(tools) { tool in row(tool) }
                    } header: {
                        HStack {
                            Text("\(group.title) · \(tools.filter(\.active).count)/\(tools.count)")
                            Spacer()
                            let allOn = tools.allSatisfy(\.active)
                            Button(allOn ? "All off" : "All on") {
                                Task { await model.set(group, on: !allOn) }
                            }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                            .disabled(model.busy)
                        }
                    }
                }
                if model.loaded {
                    Section {
                    } footer: {
                        Text(ChatTools.note)
                    }
                }
            }
            .navigationTitle("Tools")
            .navigationSubtitle(model.loaded ? model.count : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .alert("Tools", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.problem ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ tool: PiTool) -> some View {
        Toggle(isOn: Binding(
            get: { tool.active },
            set: { on in Task { await model.set(tool.name, on: on) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.callout.monospaced())
                    if let e = tool.exposure, e != "direct" {
                        Text(e).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).overlay(Capsule().stroke(.secondary.opacity(0.4)))
                    }
                }
                let summary = [tool.mcpServer, tool.summary()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let note = tool.exposureNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.busy)
        .accessibilityIdentifier("tool-\(tool.name)")
    }
}
