import PocketPiKit
import SwiftUI
import UIKit

struct TranscriptItemView: View {
    let item: Transcript.Item
    let transcript: Transcript
    let home: String?
    /// "Fork from here" on a user message (nil: not offered).
    var onFork: ((Transcript.Item) -> Void)? = nil

    var body: some View {
        switch item.kind {
        case .user(let m):
            UserBubble(message: m, onFork: onFork.flatMap { f in transcript.canFork(item) ? { f(item) } : nil })
        case .assistant(let m, let live):
            AssistantMessageView(message: m, live: live, transcript: transcript, home: home)
        case .compaction(let summary, let tokensBefore):
            DisclosureGroup {
                MarkdownView(text: summary)
            } label: {
                Text("Earlier conversation summarized" + (tokensBefore.map { " · \(Format.tokens($0)) tokens" } ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .branchSummary(let summary):
            DisclosureGroup {
                MarkdownView(text: summary)
            } label: {
                Text("Branch summary").font(.footnote).foregroundStyle(.secondary)
            }
        case .bash(let run):
            BashCard(run: run)
        case .custom(let text):
            MarkdownView(text: text)
        case .note(let text):
            Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .error(let text):
            ErrorBox(text: text, soft: false)
        }
    }
}

private struct UserBubble: View {
    let message: ChatMessage
    /// Set when pi can fork from this message (it has text, pi is idle).
    let onFork: (() -> Void)?
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, b in
                    if case .image(let data, _) = b, let d = Data(base64Encoded: data), let img = UIImage(data: d) {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                if !message.plainText.isEmpty {
                    Text(message.plainText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .contextMenu {
            let text = message.plainText
            if !text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            }
            if let onFork {
                Button("Fork from here", systemImage: "arrow.triangle.branch", action: onFork)
            }
        }
    }
}

struct AssistantMessageView: View {
    let message: ChatMessage
    let live: Bool
    let transcript: Transcript
    let home: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, b in
                block(b)
            }
            switch message.stopReason {
            case "error": ErrorBox(text: message.errorMessage ?? "The model returned an error.", soft: false)
            case "aborted": ErrorBox(text: "Stopped.", soft: true)
            case "length": ErrorBox(text: "Hit the output limit.", soft: true)
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            let text = message.plainText
            if !text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                ShareLink(item: text)
            }
        }
    }

    @ViewBuilder private func block(_ b: ContentBlock) -> some View {
        switch b {
        case .text(let t):
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { MarkdownView(text: t) }
        case .thinking(let t, let secs):
            ThinkingView(text: t, seconds: secs, live: live && secs == nil)
        case .toolCall(let id, let name, let args):
            ToolCard(name: name, summary: ToolSummary.summary(name: name, arguments: args, home: home),
                     arguments: args, result: transcript.toolResults[id],
                     partial: transcript.partialResults[id], running: transcript.runningTools.contains(id))
        case .image(let data, _):
            if let d = Data(base64Encoded: data), let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
            }
        case .other:
            EmptyView()
        }
    }
}

struct ThinkingView: View {
    let text: String
    let seconds: Int?
    let live: Bool
    @State private var open = false

    var body: some View {
        if !text.isEmpty || live {
            DisclosureGroup(isExpanded: $open) {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(live ? "Thinking…" : seconds.map { "Thought for \($0)s" } ?? "Thought",
                      systemImage: "brain")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .tint(.secondary)
        }
    }
}

/// Thinking and tool calls between two pieces of text, as one line: what pi
/// did ("Ran 9 commands · thought for 12s"), or what it's doing now while it
/// works. Opens to the steps themselves.
struct ActivityRow: View {
    let steps: [ActivityStep]
    let live: Bool
    let transcript: Transcript
    let home: String?
    @State private var open = false

    private var failed: Int {
        steps.reduce(0) { n, s in
            if case .tool(let id, _, _) = s, transcript.toolResults[id]?.isError == true { return n + 1 }
            return n
        }
    }

    /// While live: the step pi is on.
    private var now: String {
        switch steps.last {
        case .thinking(_, _, true): return "Thinking…"
        case .tool(let id, let name, let args) where transcript.runningTools.contains(id):
            return name + " " + ToolSummary.summary(name: name, arguments: args, home: home)
        default: return "Working…"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    switch step {
                    case .thinking(let text, let secs, let isLive):
                        ThinkingView(text: text, seconds: secs, live: isLive)
                    case .tool(let id, let name, let args):
                        ToolCard(name: name, summary: ToolSummary.summary(name: name, arguments: args, home: home),
                                 arguments: args, result: transcript.toolResults[id],
                                 partial: transcript.partialResults[id], running: transcript.runningTools.contains(id))
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if live { ProgressView().controlSize(.small).tint(Theme.signalText) }
                Text(live ? now : ActivitySummary.text(steps))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if failed > 0 {
                    Text("\(failed) failed").foregroundStyle(Theme.danger)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .tint(.secondary)
        .accessibilityIdentifier("activity-row")
    }
}

struct ToolCard: View {
    let name: String
    let summary: String
    let arguments: JSONValue
    let result: ToolResult?
    let partial: ToolResult?
    let running: Bool
    @State private var open = false
    @State private var showAll = false

    private var icon: String {
        switch name {
        case "bash": "terminal"
        case "read": "doc.text"
        case "edit", "write": "pencil"
        case "grep", "find", "ls": "magnifyingglass"
        case "web_fetch", "fetch", "web_search": "globe"
        default: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        // The system's expand control, like the Thought rows.
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                if name != "bash", case .object(let o) = arguments, !o.isEmpty {
                    Text(arguments.compactText).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6)
                } else if name == "bash" {
                    Text(summary).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let diff = result?.diff {
                    DiffView(diff: diff)
                } else if let out = (result ?? partial)?.text, !out.isEmpty {
                    let long = out.count > 4000 && !showAll
                    Text(long ? "…" + String(out.suffix(4000)) : out)
                        .font(.caption.monospaced())
                        .foregroundStyle(result?.isError == true ? Theme.danger : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if long { Button("Show all \(out.count) characters") { showAll = true }.font(.caption) }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.caption).frame(width: 16)
                Text(name).font(.footnote.monospaced().weight(.semibold))
                Text(summary).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                status
            }
            .foregroundStyle(.primary)
        }
        .tint(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    @ViewBuilder private var status: some View {
        if running {
            ProgressView().controlSize(.mini)
        } else if let r = result {
            if r.isError {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.caption)
            } else if let ms = r.durationMs, ms >= 1000 {
                Text("\(ms / 1000)s").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

/// An edit's diff. Lazy (an expanded card can hold 400 lines inside the
/// lazy transcript), and the +/− gutter is bold and coloured, so a change
/// reads without telling red from green.
private struct DiffView: View {
    let diff: String

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(400).map(String.init)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
    }

    private func row(_ line: String) -> some View {
        let kind: Character? = line.hasPrefix("+") && !line.hasPrefix("+++") ? "+"
            : line.hasPrefix("-") && !line.hasPrefix("---") ? "-" : nil
        let tint: Color = kind == "+" ? .green : kind == "-" ? .red : .clear
        let rest = kind == nil ? line : String(line.dropFirst())
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(kind == "+" ? "+" : kind == "-" ? "−" : " ")
                .font(.caption.monospaced().bold())
                .foregroundStyle(kind == "+" ? Color.green : Color.red)
                .frame(width: 14)
                .accessibilityLabel(kind == "+" ? "added" : kind == "-" ? "removed" : "")
            Text(rest.isEmpty ? " " : rest)
                .font(.caption.monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.15))
    }
}

private struct ErrorBox: View {
    let text: String
    let soft: Bool
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(soft ? Color.secondary : Theme.danger)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((soft ? Color.secondary : Theme.danger).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Block-level Markdown from PocketPiKit, inline markup from Foundation.
struct MarkdownView: View {
    let text: String
    @State private var wideCode: WideCode?

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                view(for: b)
                    // A heading starts a section: room above it, so sections
                    // don't run together.
                    .padding(.top, i > 0 && b.isHeading ? 10 : 0)
            }
        }
        .textSelection(.enabled)
        .sheet(item: $wideCode) { WideCodeSheet(code: $0) }
    }

    /// Headings step down from the title sizes to the body's bold.
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline
        }
    }

    @ViewBuilder private func view(for b: MarkdownBlock) -> some View {
        switch b {
        case .paragraph(let t):
            Text(Self.inline(t))
        case .heading(let level, let t):
            Text(Self.inline(t, code: Self.headingFont(level).monospaced()))
                .font(Self.headingFont(level))
                .accessibilityAddTraits(.isHeader)
        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(lang ?? "code").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button { wideCode = WideCode(lang: lang, code: code) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Open code full screen")
                    Button { UIPasteboard.general.string = code } label: { Image(systemName: "doc.on.doc").font(.caption2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Copy code")
                }
                // Wrapped rather than scrolled: a sideways scroller inside the
                // chat fights the vertical swipe. Full screen scrolls sideways.
                Text(code).font(.caption.monospaced())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { wideCode = WideCode(lang: lang, code: code) }
        case .quote(let t):
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(Self.inline(t)).foregroundStyle(.secondary)
            }
        case .listItem(let marker, let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(t))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .rule:
            Divider()
        }
    }

    /// Inline Markdown. Code spans get a smaller monospaced font (monospace
    /// at body size wraps awkwardly) and the code background.
    static func inline(_ s: String, code: Font = .callout.monospaced()) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        let spans = a.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for r in spans {
            a[r].swiftUI.font = code
            a[r].swiftUI.backgroundColor = Theme.code
        }
        return a
    }
}

/// A code block opened full screen: no wrapping, scrolls both ways.
struct WideCode: Identifiable {
    let id = UUID()
    let lang: String?
    let code: String
}

private struct WideCodeSheet: View {
    let code: WideCode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(code.code)
                    .font(.footnote.monospaced())
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Theme.code)
            .navigationTitle(code.lang ?? "Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = code.code }
                }
            }
        }
    }
}
