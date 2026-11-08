import PocketPiKit
import SwiftUI

// A chat's session tree (pi's /tree) and session info, opened from the chat's
// title menu. The logic is PocketPiKit's (Tree.swift, ChatSessionTree.swift);
// ChatView only adds `TreeMenuButtons`, `@State treeSheet` and
// `.treeSheets(...)`.

/// Which of the two sheets is up.
enum TreeSheet: String, Identifiable {
    case tree, info
    var id: String { rawValue }
}

/// The title menu's entries.
struct TreeMenuButtons: View {
    let session: ChatSession
    @Binding var sheet: TreeSheet?

    var body: some View {
        Button("Session tree", systemImage: "arrow.triangle.branch") { sheet = .tree }
            .disabled(session.path == nil)
        Button("Session info", systemImage: "info.circle") { sheet = .info }
            .disabled(session.path == nil)
    }
}

extension View {
    func treeSheets(_ sheet: Binding<TreeSheet?>, session: ChatSession) -> some View {
        self.sheet(item: sheet) { which in
            switch which {
            case .tree: SessionTreeView(session: session)
            case .info: SessionInfoView(session: session)
            }
        }
    }
}

// MARK: - tree

struct SessionTreeView: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var tree: SessionTree?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let tree {
                    if tree.rows.isEmpty {
                        ContentUnavailableView("Nothing here yet", systemImage: "arrow.triangle.branch")
                    } else {
                        ScrollViewReader { proxy in
                            List(tree.rows) { row in
                                NavigationLink(value: row) { TreeRowView(row: row) }
                                    .id(row.id)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 12 + CGFloat(min(row.depth, 8)) * 14, bottom: 2, trailing: 12))
                            }
                            .listStyle(.plain)
                            .onAppear { if let c = tree.currentId { proxy.scrollTo(c, anchor: .center) } }
                        }
                    }
                } else if let error {
                    ContentUnavailableView("Couldn't read the tree", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Session tree")
            .navigationSubtitle(tree.map { "\($0.branches) branch\($0.branches == 1 ? "" : "es")" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TreeRow.self) { row in
                TreeNodeView(session: session, row: row, done: { dismiss() }, changed: { Task { await load() } })
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
            .refreshable { await load() }
        }
        .presentationDetents([.large])
    }

    private func load() async {
        do { tree = try await session.loadTree(); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct TreeRowView: View {
    let row: TreeRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text)
                    .font(row.kind == .user ? .subheadline : .footnote)
                    .fontWeight(row.isCurrent ? .semibold : .regular)
                    .foregroundStyle(row.kind == .user || row.isCurrent ? HierarchicalShapeStyle.primary : .secondary)
                    .opacity(row.onPath || row.isCurrent ? 1 : 0.7)
                    .lineLimit(1)
                if row.label != nil || row.isCurrent || row.toolCalls > 0 {
                    HStack(spacing: 6) {
                        if let l = row.label {
                            Text(l)
                                .font(.caption2.monospaced().weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.signal, in: .rect(cornerRadius: 5))
                                .foregroundStyle(Theme.signalInk)
                        }
                        if row.isCurrent { Text("You are here").font(.caption2.weight(.semibold)).textCase(.uppercase) }
                        if row.toolCalls > 0 {
                            Text("\(row.toolCalls) tool\(row.toolCalls == 1 ? "" : "s")").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(row.isCurrent ? "Where the chat is now" : "")
    }

    @ViewBuilder private var marker: some View {
        if row.branchStart && row.depth > 0 {
            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary).frame(width: 12)
        }
        Group {
            switch row.kind {
            case .user: Circle().fill(row.isCurrent ? Theme.signal : Color.primary)
            case .assistant: RoundedRectangle(cornerRadius: 3).strokeBorder(row.isCurrent ? Theme.signal : Color.secondary, lineWidth: 1.5)
                .background(row.isCurrent ? Theme.signal : .clear, in: .rect(cornerRadius: 3))
            case .compaction, .branchSummary: Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            case .bash, .custom: Circle().strokeBorder(row.isCurrent ? Theme.signal : Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: 10, height: 10)
    }
}

// MARK: - one point of the tree

struct TreeNodeView: View {
    let session: ChatSession
    let row: TreeRow
    let done: () -> Void
    let changed: () -> Void
    @State private var summarize = false
    @State private var instructions = ""
    @State private var label = ""
    @State private var working = false
    @Environment(\.dismiss) private var pop

    var body: some View {
        Form {
            Section(kindTitle) {
                Text(row.text).textSelection(.enabled)
            }
            if row.isCurrent {
                Section { Text("The chat is here: your next message continues from this point.").foregroundStyle(.secondary) }
            } else {
                Section {
                    Button {
                        Task { await go() }
                    } label: {
                        Label(row.refills ? "Edit and resend from here" : "Continue from here", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(working || session.isStreaming)
                    Toggle("Summarize the branch I'm leaving", isOn: $summarize)
                    if summarize {
                        TextField("What the summary should focus on (optional)", text: $instructions, axis: .vertical)
                    }
                } header: {
                    Text("Go here")
                } footer: {
                    Text(session.isStreaming ? "Wait for pi to finish first."
                         : row.refills ? "Goes back to before this message and puts it in the message box."
                         : "Your next message continues after this point. A summary uses the model.")
                }
            }
            Section {
                TextField("Label, e.g. before refactor", text: $label)
                    .submitLabel(.done)
                    .onSubmit { Task { await saveLabel(label) } }
                Button("Save label") { Task { await saveLabel(label) } }
                    .disabled(working || label.trimmingCharacters(in: .whitespaces).isEmpty || label == row.label)
                if row.label != nil {
                    Button("Remove label", role: .destructive) { Task { await saveLabel(nil) } }.disabled(working)
                }
            } header: {
                Text("Label")
            } footer: {
                Text("A bookmark shown in the tree (and in pi's /tree).")
            }
        }
        .navigationTitle(kindTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if working { ProgressView() } }
        .onAppear { label = row.label ?? "" }
    }

    private var kindTitle: String {
        switch row.kind {
        case .user: "Your message"
        case .assistant: "pi's reply"
        case .bash: "Shell command"
        case .custom: "Extension message"
        case .compaction: "Compaction"
        case .branchSummary: "Branch summary"
        }
    }

    private func go() async {
        working = true
        defer { working = false }
        let ins = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if await session.goto(row, summarize: summarize, instructions: ins.isEmpty ? nil : ins) { done() }
    }

    private func saveLabel(_ text: String?) async {
        working = true
        defer { working = false }
        if await session.setLabel(row.id, text?.trimmingCharacters(in: .whitespaces)) {
            changed()
            pop()
        }
    }
}

// MARK: - session info

struct SessionInfoView: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var info: SessionInfoSheet?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let info {
                    Form { content(info) }
                } else if let error {
                    ContentUnavailableView("Couldn't read the session", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Session info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do { info = try await session.loadInfo() } catch { self.error = error.localizedDescription }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func content(_ info: SessionInfoSheet) -> some View {
        Section {
            LabeledContent("Tokens", value: Format.tokens(info.totalTokens))
            LabeledContent("Cost", value: Format.cost(info.cost))
            if let s = session.stats, let p = s.contextPercent {
                LabeledContent("Context now", value: "\(Int(p.rounded()))% of \(Format.tokens(s.contextWindow))")
            }
        }
        Section("File") {
            LabeledContent("Path") { Text(info.header.file.map { Format.tilde($0, home: model.home) } ?? "not saved yet").font(.caption.monospaced()).textSelection(.enabled) }
            if let id = info.header.id { LabeledContent("Session id") { Text(id).font(.caption.monospaced()).textSelection(.enabled) } }
            if let c = info.header.created, let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(c) {
                LabeledContent("Created", value: d.formatted(date: .abbreviated, time: .shortened))
            }
            if let p = info.header.parentSession {
                LabeledContent("Forked from") {
                    Text(model.sessions.first { $0.path == p }?.displayTitle ?? Format.tilde(p, home: model.home))
                        .font(.caption).textSelection(.enabled)
                }
            }
        }
        Section("Messages") {
            ForEach(info.summary.roleLines, id: \.name) { LabeledContent($0.name, value: "\($0.count)") }
            if info.summary.toolCalls > 0 { LabeledContent("Tool calls", value: "\(info.summary.toolCalls)") }
            if info.summary.compactions > 0 { LabeledContent("Compactions", value: "\(info.summary.compactions)") }
            if info.summary.branchSummaries > 0 { LabeledContent("Branch summaries", value: "\(info.summary.branchSummaries)") }
            if info.summary.labels > 0 { LabeledContent("Labels", value: "\(info.summary.labels)") }
        }
        if !info.summary.models.isEmpty {
            Section("Cost by model") {
                ForEach(info.summary.models) { m in
                    LabeledContent {
                        Text(Format.cost(m.cost)).monospacedDigit()
                    } label: {
                        Text(m.id).font(.subheadline.monospaced())
                        Text((m.messages > 0 ? "\(m.messages) replies · " : "") + Format.tokens(m.tokens) + " tokens")
                    }
                }
            }
        }
    }
}
