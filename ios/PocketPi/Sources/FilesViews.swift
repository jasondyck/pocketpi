import PocketPiKit
import QuickLook
import SwiftUI

// Files panel (docs/dsh-features-plan.md §3.5): "Files" in the chat's title
// menu opens a sheet on the chat's folder. Files: a folder list, then a
// preview (Quick Look for images and PDFs, a text view with line numbers for
// code, markdown rendered). Changed: the files each turn changed, each with
// its diff. `FileMentionList` is the composer's `@` picker. The logic and
// the server calls are in PocketPiKit's Files.swift; same feature as
// web/files.js.

/// The title menu's entry.
struct FilesMenuButtons: View {
    let session: ChatSession
    @Binding var sheet: ChatFeatureSheet?

    var body: some View {
        Button("Files", systemImage: "folder") { sheet = .files }
    }
}

extension EnvironmentValues {
    /// Closes the Files sheet and puts `@path` in the message box (path,
    /// is a folder).
    @Entry var mentionFile: @MainActor (String, Bool) -> Void = { _, _ in }
}

struct FilesScreen: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.files

    enum Tab: Hashable { case files, changed }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .files: FolderList(session: session, dir: "")
                case .changed: ChangedList(session: session)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Show", selection: $tab) {
                    Text("Files").tag(Tab.files)
                    Text("Changed").tag(Tab.changed)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Files")
            .navigationSubtitle(Format.baseName(session.cwd))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .environment(\.mentionFile, mention)
    }

    private func mention(_ path: String, _ isDir: Bool) {
        let m = AtMention.format(path: path, isDirectory: isDir) ?? "@" + path
        let box = session.composer
        let gap = box.isEmpty || box.last?.isWhitespace == true ? "" : " "
        session.composer = box + gap + m + " "
        dismiss()
    }
}

// MARK: - Files

private struct FolderList: View {
    let session: ChatSession
    let dir: String
    @State private var listing: FileListing?
    @State private var error: String?

    var body: some View {
        Group {
            if let listing {
                if listing.entries.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                } else {
                    List {
                        Section {
                            ForEach(listing.entries) { e in row(e) }
                        } footer: {
                            if listing.truncated { Text("Only the first \(listing.entries.count) entries are shown.") }
                        }
                    }
                    .listStyle(.plain)
                }
            } else if let error {
                ContentUnavailableView("Couldn't list the folder", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(dir.isEmpty ? "Files" : Format.baseName(dir))
        .task { await load() }
        .refreshable { await load() }
    }

    private func path(_ e: FileEntry) -> String { dir.isEmpty ? e.name : dir + "/" + e.name }

    @ViewBuilder private func row(_ e: FileEntry) -> some View {
        if e.isDirectory {
            NavigationLink { FolderList(session: session, dir: path(e)) } label: { FileRow(entry: e) }
        } else if e.canPreview {
            NavigationLink { FilePreview(session: session, path: path(e)) } label: { FileRow(entry: e) }
        } else {
            FileRow(entry: e)
                .foregroundStyle(.secondary)
                .accessibilityHint(e.kind == .link ? "A link; links aren't opened here" : "")
        }
    }

    private func load() async {
        do { listing = try await session.client.listFiles(root: session.cwd, dir: dir); error = nil } catch {
            if error.isCancellation { return }
            self.error = error.localizedDescription
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder" : entry.kind == .link ? "link" : icon)
                .foregroundStyle(entry.isDirectory ? Theme.signalText : .secondary)
                .frame(width: 22)
            Text(entry.name)
                .font(.subheadline.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if entry.kind == .file {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch FilePreviewKind.of(entry.name) {
        case .quickLook: entry.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "photo"
        case .markdown: "doc.text"
        case .text: "doc.plaintext"
        }
    }
}

/// One file: Quick Look for images and PDFs, markdown rendered, anything
/// else as text with line numbers, a page at a time.
private struct FilePreview: View {
    let session: ChatSession
    let path: String
    @Environment(\.mentionFile) private var mention
    @State private var lines: [String] = []
    @State private var next: Int?
    @State private var first: FilePage?
    @State private var loadingMore = false
    @State private var problem: FileReadProblem?
    @State private var error: String?
    @State private var quickLook: URL?
    @State private var downloading = false

    private var kind: FilePreviewKind { FilePreviewKind.of(path) }

    var body: some View {
        content
            .navigationTitle(Format.baseName(path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Mention", systemImage: "at") { mention(path, false) }
                    Button("Open", systemImage: "square.and.arrow.up") { Task { await openRaw() } }
                        .disabled(downloading)
                }
            }
            .quickLookPreview($quickLook)
            .task { await start() }
    }

    @ViewBuilder private var content: some View {
        if kind == .quickLook {
            VStack(spacing: 14) {
                if downloading { ProgressView() }
                Button("Open in Quick Look", systemImage: "eye") { Task { await openRaw() } }
                    .buttonStyle(.bordered)
                    .disabled(downloading)
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem {
            ContentUnavailableView {
                Label(problem == .notText ? "Not a text file" : "Too large to show", systemImage: "doc.questionmark")
            } description: {
                Text("Open it to preview or share it.")
            } actions: {
                Button("Open", systemImage: "square.and.arrow.up") { Task { await openRaw() } }
                    .disabled(downloading)
            }
        } else if let error {
            ContentUnavailableView("Couldn't read the file", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if first == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .markdown {
            ScrollView {
                MarkdownView(text: lines.joined(separator: "\n"))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if next != nil {
                    Button("Load the rest") { Task { await loadAll() } }
                        .disabled(loadingMore)
                        .padding(.bottom)
                }
            }
        } else if lines.isEmpty {
            ContentUnavailableView("Empty file", systemImage: "doc")
        } else {
            CodeLines(lines: lines, more: next != nil) { Task { await loadMore() } }
        }
    }

    private func start() async {
        guard first == nil, kind != .quickLook else {
            if kind == .quickLook, quickLook == nil { await openRaw() }
            return
        }
        do {
            let p = try await session.client.readFile(root: session.cwd, path: path)
            first = p
            lines = p.lines
            next = p.next
        } catch {
            if error.isCancellation { return }
            if let p = FileReadProblem(error) { problem = p } else { self.error = error.localizedDescription }
        }
    }

    private func loadMore() async {
        guard let from = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let p = try await session.client.readFile(root: session.cwd, path: path, from: from)
            lines += p.lines
            next = p.next
        } catch {
            next = nil
        }
    }

    private func loadAll() async {
        while next != nil {
            let before = next
            await loadMore()
            if next == before { break }
        }
    }

    private func openRaw() async {
        downloading = true
        defer { downloading = false }
        do {
            quickLook = try await session.client.download(PocketPiClient.rawFilePath(root: session.cwd, path: path), as: Format.baseName(path))
            error = nil
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }
}

/// Text with line numbers; asks for more as the end comes into view.
private struct CodeLines: View {
    let lines: [String]
    let more: Bool
    let loadMore: () -> Void

    var body: some View {
        let width = CGFloat(String(lines.count).count) * 8 + 8
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)")
                            .foregroundStyle(.secondary)
                            .frame(width: width, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(line.isEmpty ? " " : line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.monospaced())
                    .padding(.vertical, 1)
                    .onAppear { if more, i >= lines.count - 40 { loadMore() } }
                }
                if more { ProgressView().padding() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }
}

// MARK: - Changed

private struct ChangedList: View {
    let session: ChatSession
    @State private var changes: ChatChanges?
    @State private var error: String?

    var body: some View {
        Group {
            if let changes {
                let turns = changes.changedTurns
                if turns.isEmpty {
                    ContentUnavailableView("Nothing changed yet", systemImage: "doc.badge.clock",
                                           description: Text(changes.turns.isEmpty ? "Each turn's changed files show up here." : "No turn changed a file yet."))
                } else {
                    List {
                        if changes.git == false {
                            Section {
                                Text("Not a git folder: these are the files pi's edit and write tools named, without diffs.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else if turns.count > 1 {
                            Section {
                                NavigationLink { AllChanges(session: session) } label: {
                                    Label("Since this chat opened", systemImage: "clock.arrow.circlepath")
                                }
                            }
                        }
                        ForEach(turns) { t in
                            Section {
                                if let e = t.error { Text(e).font(.footnote).foregroundStyle(Theme.danger) }
                                ForEach(t.files) { f in
                                    ChangedRow(session: session, turn: .turn(t.turn), file: f, git: changes.git != false)
                                }
                            } header: {
                                HStack {
                                    Text("Turn \(t.turn)")
                                    Spacer()
                                    if let end = t.end {
                                        Text(Date(timeIntervalSince1970: end / 1000), style: .relative)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            } else if let error {
                ContentUnavailableView("Couldn't load the changes", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { changes = try await session.loadChanges(); error = nil } catch {
            if error.isCancellation { return }
            self.error = error.localizedDescription
        }
    }
}

private struct AllChanges: View {
    let session: ChatSession
    @State private var files: [ChangedFile]?
    @State private var error: String?

    var body: some View {
        Group {
            if let files {
                List(files) { f in ChangedRow(session: session, turn: .all, file: f, git: true) }
            } else if let error {
                ContentUnavailableView("Couldn't load the changes", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Since this chat opened")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { files = try await session.changedFiles(.all) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ChangedRow: View {
    let session: ChatSession
    let turn: TurnSelector
    let file: ChangedFile
    let git: Bool

    var body: some View {
        if git {
            NavigationLink { PatchView(session: session, turn: turn, file: file) } label: { label }
        } else if !file.path.hasPrefix("/"), !file.path.hasPrefix("../") {
            NavigationLink { FilePreview(session: session, path: file.path) } label: { label }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.path).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.head)
                if let from = file.from {
                    Text("from " + from).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if let a = file.added, let r = file.removed {
                Text("+\(a)").foregroundStyle(.green) + Text(" −\(r)").foregroundStyle(.red)
            } else if git {
                Text("binary").foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}

/// One file's diff in a turn: the patch, its +/− lines tinted.
private struct PatchView: View {
    let session: ChatSession
    let turn: TurnSelector
    let file: ChangedFile
    @State private var lines: [String]?
    @State private var error: String?

    var body: some View {
        Group {
            if let lines {
                if lines.allSatisfy({ $0.isEmpty }) {
                    ContentUnavailableView("No text changes", systemImage: "doc")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in row(l) }
                        }
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                    }
                }
            } else if let error {
                ContentUnavailableView("Couldn't load the diff", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Format.baseName(file.path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !file.path.hasPrefix("../") {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { FilePreview(session: session, path: file.path) } label: { Label("Open the file", systemImage: "doc.text") }
                }
            }
        }
        .task {
            do {
                let d = try await session.fileDiff(turn, file: file.path)
                lines = d.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func row(_ l: String) -> some View {
        let add = l.hasPrefix("+") && !l.hasPrefix("+++")
        let del = l.hasPrefix("-") && !l.hasPrefix("---")
        let hunk = l.hasPrefix("@@")
        return Text(l.isEmpty ? " " : l)
            .font(.caption.monospaced())
            .foregroundStyle(hunk ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .background((add ? Color.green : del ? Color.red : Color.clear).opacity(0.15))
            .accessibilityLabel(Self.spoken(l, add: add, del: del))
    }

    private static func spoken(_ l: String, add: Bool, del: Bool) -> String {
        let rest = String(l.dropFirst())
        if add { return "added: " + rest }
        if del { return "removed: " + rest }
        return l
    }
}

// MARK: - @ picker

/// Paths matching the `@` mention being typed at the end of the message
/// box; a tap puts `@path` in its place (a folder: `@dir/`, to go on into it).
struct FileMentionList: View {
    @Bindable var session: ChatSession
    let picked: () -> Void
    @State private var results: [FileCandidate] = []
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        let token = session.mentionToken
        Group {
            if token != nil, !results.isEmpty {
                ScrollView {
                    rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(rowsHeight, 1), 240))
                .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .task(id: token?.query) {
            guard let q = token?.query else { results = []; return }
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let found = await session.mentionCandidates(for: q)
            if !Task.isCancelled { results = found }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(results) { c in
                Button {
                    session.pickMention(c)
                    picked()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: c.isDirectory ? "folder" : "doc")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(c.name + (c.isDirectory ? "/" : ""))
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(c.folder)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mention-" + c.path)
            }
        }
    }
}
