import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The session tree (pi's /tree): every entry of a chat's session file with
// its branches, for a phone. Built from `get_tree`; moving around it and
// labels go through pocketpi-control's /pp-goto and /pp-label. The same
// logic is in web/tree.js.

/// One line of the tree as shown.
public struct TreeRow: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        /// A prompt of yours; going there puts it back in the message box.
        case user
        /// pi's reply: a run of assistant messages and tool results, one line.
        case assistant
        /// A `!cmd` shell command.
        case bash
        /// An extension's message that shows in the chat.
        case custom
        /// Context compacted here.
        case compaction
        /// A summary of a branch left behind (from a goto that summarized).
        case branchSummary
    }

    /// The entry to go to or label: for a reply, its last message.
    public var id: String
    public var kind: Kind
    /// One line of text.
    public var text: String
    /// Branch depth: each branch point indents its branches by one.
    public var depth: Int
    /// The first row of one of several branches from the row above it.
    public var branchStart: Bool
    /// On the way from the root to where the chat is now.
    public var onPath: Bool
    /// Where the chat is now (the next prompt continues after it).
    public var isCurrent: Bool
    public var label: String?
    /// Tool calls folded into a reply.
    public var toolCalls: Int
    /// The entry's ISO timestamp.
    public var timestamp: String?

    public init(id: String, kind: Kind, text: String, depth: Int = 0, branchStart: Bool = false, onPath: Bool = false,
                isCurrent: Bool = false, label: String? = nil, toolCalls: Int = 0, timestamp: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.depth = depth
        self.branchStart = branchStart
        self.onPath = onPath
        self.isCurrent = isCurrent
        self.label = label
        self.toolCalls = toolCalls
        self.timestamp = timestamp
    }

    /// Going here puts the prompt back in the message box (pi continues
    /// from the entry before it).
    public var refills: Bool { kind == .user || kind == .custom }
}

/// The tree of a chat's session file, flattened into rows.
public struct SessionTree: Sendable, Equatable {
    public var rows: [TreeRow]
    /// The row where the chat is now (nil for an empty chat, or one that's
    /// back before its first message).
    public var currentId: String?
    /// How many branches the session has (rows with no rows after them).
    public var branches: Int

    public static let empty = SessionTree(rows: [], currentId: nil, branches: 0)

    public init(rows: [TreeRow], currentId: String?, branches: Int) {
        self.rows = rows
        self.currentId = currentId
        self.branches = branches
    }

    /// From `get_tree`'s data (`{tree: [{entry, children, label?}], leafId}`).
    ///
    /// Only what the chat shows is a row: prompts, replies, shell commands,
    /// extension messages that display, compactions and branch summaries.
    /// The rest (tool results, system prompts, model and thinking changes,
    /// labels, session names, usage, hidden extension entries such as
    /// pocketpi-control's replies) is left out and its children move up to
    /// the nearest row. pi's leaf is often such an entry (a control reply
    /// goes after the leaf), so "current" is the nearest row above it.
    public init(_ data: JSONValue) {
        // Flatten the nested nodes (iteratively: long chats are deep).
        var entries: [String: JSONValue] = [:]
        var labels: [String: String] = [:]
        var children: [String: [String]] = [:]
        var parent: [String: String] = [:]
        var roots: [String] = []
        var stack: [(JSONValue, String?)] = (data["tree"]?.array ?? []).reversed().map { ($0, nil) }
        while let (node, p) = stack.popLast() {
            guard let e = node["entry"], let id = e["id"]?.string, entries[id] == nil else { continue }
            entries[id] = e
            if let l = node["label"]?.string, !l.isEmpty { labels[id] = l }
            if let p { children[p, default: []].append(id); parent[id] = p } else { roots.append(id) }
            for c in (node["children"]?.array ?? []).reversed() { stack.append((c, id)) }
        }

        func kind(_ id: String) -> TreeRow.Kind? { entries[id].flatMap(TreeEntry.kind) }

        // The rows each entry leads to: its visible children, or theirs.
        func visibleKids(_ ids: [String]) -> [String] {
            var out: [String] = []
            var todo = Array(ids.reversed())
            while let id = todo.popLast() {
                if kind(id) != nil { out.append(id) } else { todo.append(contentsOf: (children[id] ?? []).reversed()) }
            }
            return out
        }

        // Where the chat is: the leaf, or the nearest row above it.
        var onPath = Set<String>()
        var current: String?
        var cursor = data["leafId"]?.string
        while let id = cursor, !onPath.contains(id) {
            onPath.insert(id)
            if current == nil, kind(id) != nil { current = id }
            cursor = parent[id]
        }

        var rows: [TreeRow] = []
        var branches = 0
        let top = visibleKids(roots)
        var todo: [(id: String, depth: Int, start: Bool)] = top.reversed().map { ($0, 0, top.count > 1) }
        while let (first, depth, start) = todo.popLast() {
            guard let k = kind(first), let e = entries[first] else { continue }
            var row = TreeRow(id: first, kind: k, text: TreeEntry.line(e), depth: depth, branchStart: start,
                              onPath: onPath.contains(first), isCurrent: first == current, label: labels[first],
                              toolCalls: TreeEntry.toolCalls(e), timestamp: e["timestamp"]?.string)
            var last = first
            var kids = visibleKids(children[first] ?? [])
            // A reply is one row: fold the assistant messages after it in, up
            // to a branch, a label, or where the chat is.
            if k == .assistant {
                while kids.count == 1, kind(kids[0]) == .assistant, labels[kids[0]] == nil, last != current,
                      let next = entries[kids[0]] {
                    last = kids[0]
                    row.toolCalls += TreeEntry.toolCalls(next)
                    // The reply's last words (or, without any, its error).
                    if TreeEntry.hasText(next) || row.text.isEmpty { row.text = TreeEntry.line(next) }
                    row.id = last
                    row.onPath = onPath.contains(last)
                    row.isCurrent = last == current
                    row.timestamp = next["timestamp"]?.string
                    kids = visibleKids(children[last] ?? [])
                }
                if row.text.isEmpty { row.text = row.toolCalls > 0 ? "Used \(row.toolCalls) tool\(row.toolCalls == 1 ? "" : "s")" : "(no text)" }
            }
            rows.append(row)
            if kids.isEmpty { branches += 1 }
            if kids.count == 1 {
                todo.append((kids[0], depth, false))
            } else {
                for c in kids.reversed() { todo.append((c, depth + 1, true)) }
            }
        }
        // Folding stops at the current entry, so it is always a row's id.
        self.init(rows: rows, currentId: current, branches: branches)
    }

    public func row(_ id: String) -> TreeRow? { rows.first { $0.id == id } }

    /// The user-message entry ids on the way to where the chat is, oldest
    /// first: what `get_fork_messages` should be narrowed to, so a prompt
    /// repeated on an abandoned branch can't be picked by mistake.
    public var pathUserIds: [String] { rows.filter { $0.onPath && $0.kind == .user }.map(\.id) }
}

/// Reading one session entry.
enum TreeEntry {
    static func kind(_ e: JSONValue) -> TreeRow.Kind? {
        switch e["type"]?.string {
        case "message":
            switch e["message"]?["role"]?.string {
            case "user": return .user
            case "assistant": return .assistant
            case "bashExecution": return .bash
            case "custom": return e["message"]?["display"]?.bool == false ? nil : .custom
            default: return nil
            }
        case "custom_message": return e["display"]?.bool == true ? .custom : nil
        case "compaction": return .compaction
        case "branch_summary": return .branchSummary
        default: return nil
        }
    }

    static func text(_ content: JSONValue?) -> String {
        if let s = content?.string { return s }
        return (content?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: " ")
    }

    static func hasText(_ e: JSONValue) -> Bool {
        !text(e["message"]?["content"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    static func line(_ e: JSONValue) -> String {
        let m = e["message"]
        switch kind(e) {
        case .user:
            let t = firstLine(text(m?["content"]))
            if !t.isEmpty { return t }
            return (m?["content"]?.array ?? []).contains { $0["type"]?.string == "image" } ? "(image)" : "(empty)"
        case .assistant:
            let t = firstLine(text(m?["content"]))
            if !t.isEmpty { return t }
            if let err = m?["errorMessage"]?.string { return firstLine(err) }
            return ""
        case .bash:
            return "!" + firstLine(m?["command"]?.string ?? "")
        case .custom:
            return firstLine(text(m?["content"] ?? e["content"]))
        case .compaction:
            let n = e["tokensBefore"]?.int
            return "Context compacted" + (n.map { " · " + Format.tokens($0) + " tokens" } ?? "")
        case .branchSummary:
            return firstLine(e["summary"]?.string ?? "Branch summary")
        case nil:
            return ""
        }
    }

    static func toolCalls(_ e: JSONValue) -> Int {
        guard e["message"]?["role"]?.string == "assistant" else { return 0 }
        return (e["message"]?["content"]?.array ?? []).filter { $0["type"]?.string == "toolCall" }.count
    }
}

// MARK: - session info

/// The numbers of the session info sheet, from `get_entries` (every entry,
/// abandoned branches and compacted history included, like pi's totals).
public struct SessionSummary: Sendable, Equatable {
    public struct ModelUsage: Sendable, Equatable, Identifiable {
        /// "provider/model", or "Summaries" for compaction and branch
        /// summaries (pi doesn't record their model).
        public var id: String
        public var messages: Int
        public var tokens: Int
        public var cost: Double
    }

    /// Messages by role ("user", "assistant", "toolResult", "bashExecution",
    /// "custom", …).
    public var roles: [String: Int]
    public var toolCalls: Int
    public var compactions: Int
    public var branchSummaries: Int
    public var labels: Int
    /// Cost per model, most expensive first.
    public var models: [ModelUsage]
    public var cost: Double
    public var tokens: Int

    public static let summariesKey = "Summaries"

    public init(entries: [JSONValue]) {
        var roles: [String: Int] = [:]
        var calls = 0, compactions = 0, summaries = 0
        var labelled: [String: Bool] = [:]
        var by: [String: ModelUsage] = [:]
        func add(_ key: String, _ usage: JSONValue?, message: Bool) {
            var u = by[key] ?? ModelUsage(id: key, messages: 0, tokens: 0, cost: 0)
            if message { u.messages += 1 }
            u.tokens += SessionSummary.tokens(usage)
            u.cost += usage?["cost"]?["total"]?.double ?? 0
            by[key] = u
        }
        for e in entries {
            switch e["type"]?.string {
            case "message":
                let m = e["message"]
                let role = m?["role"]?.string ?? "?"
                roles[role, default: 0] += 1
                if role == "assistant" {
                    calls += TreeEntry.toolCalls(e)
                    let model = [m?["provider"]?.string, m?["model"]?.string].compactMap { $0 }.joined(separator: "/")
                    add(model.isEmpty ? "unknown" : model, m?["usage"], message: true)
                }
            case "usage":
                let model = [e["provider"]?.string, e["model"]?.string].compactMap { $0 }.joined(separator: "/")
                add(model.isEmpty ? "unknown" : model, e["usage"], message: false)
            case "compaction":
                compactions += 1
                if e["usage"] != nil { add(Self.summariesKey, e["usage"], message: false) }
            case "branch_summary":
                summaries += 1
                if e["usage"] != nil { add(Self.summariesKey, e["usage"], message: false) }
            case "label":
                if let t = e["targetId"]?.string { labelled[t] = !(e["label"]?.string ?? "").isEmpty }
            default:
                break
            }
        }
        self.roles = roles
        self.toolCalls = calls
        self.compactions = compactions
        self.branchSummaries = summaries
        self.labels = labelled.values.filter { $0 }.count
        self.models = by.values.sorted { ($0.cost, $0.tokens, $1.id) > ($1.cost, $1.tokens, $0.id) }
        self.cost = by.values.reduce(0) { $0 + $1.cost }
        self.tokens = by.values.reduce(0) { $0 + $1.tokens }
    }

    public var messageCount: Int { roles.values.reduce(0, +) }

    /// The role counts worth a line, in a fixed order, with readable names.
    public var roleLines: [(name: String, count: Int)] {
        let names: [(String, String)] = [("user", "Prompts"), ("assistant", "Replies"), ("toolResult", "Tool results"),
                                         ("bashExecution", "Shell commands"), ("custom", "Extension messages")]
        var out = names.compactMap { key, name in roles[key].map { (name, $0) } }
        let known = Set(names.map(\.0))
        for (k, n) in roles.sorted(by: { $0.key < $1.key }) where !known.contains(k) { out.append((k, n)) }
        return out
    }

    static func tokens(_ u: JSONValue?) -> Int {
        guard let u else { return 0 }
        if let t = u["totalTokens"]?.int { return t }
        return ["input", "output", "cacheRead", "cacheWrite"].compactMap { u[$0]?.int }.reduce(0, +)
    }
}

/// The session file's header (`GET /api/s/{key}/header`).
public struct SessionHeader: Sendable, Equatable {
    public var file: String?
    public var id: String?
    public var created: String?
    public var cwd: String?
    public var parentSession: String?
    public var version: Int?

    public init(_ v: JSONValue) {
        file = v["file"]?.string
        let h = v["header"]
        id = h?["id"]?.string
        created = h?["timestamp"]?.string
        cwd = h?["cwd"]?.string
        parentSession = h?["parentSession"]?.string
        version = h?["version"]?.int
    }
}

/// What `/pp-goto` answered.
public struct GotoResult: Sendable, Equatable {
    public var cancelled: Bool
    /// The prompt to put back in the message box (going to a prompt).
    public var editorText: String?
    public var leafId: String?

    public init(_ v: JSONValue) {
        cancelled = v["cancelled"]?.bool ?? false
        editorText = v["editorText"]?.string
        leafId = v["leafId"]?.string
    }
}

extension PocketPiClient {
    /// The chat's session file and its header.
    public func sessionHeader(key: String) async throws -> SessionHeader {
        SessionHeader(try await get("/api/s/\(key)/header", as: JSONValue.self))
    }

    /// Move the chat to another entry of its tree (pocketpi-control's
    /// /pp-goto). With `summarize`, pi first writes a summary of the branch
    /// being left (a model call, so this may take minutes).
    public func goto(key: String, entryId: String, summarize: Bool = false, instructions: String? = nil) async throws -> GotoResult {
        var args: [String: JSONValue] = ["entryId": .string(entryId), "summarize": .bool(summarize)]
        if let instructions, !instructions.isEmpty { args["instructions"] = .string(instructions) }
        var req = try request("/api/s/\(key)/control", body: ["command": "goto", "args": .object(args)])
        req.timeoutInterval = summarize ? 620 : 40
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PocketPiError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
        let r = try JSONValue.parse(data)
        if r["success"]?.bool != true { throw PocketPiError.command(r["error"]?.string ?? "goto failed") }
        return GotoResult(r["data"] ?? .null)
    }

    /// Set (or, with nil or "", clear) an entry's label.
    public func setLabel(key: String, entryId: String, label: String?) async throws {
        var args: [String: JSONValue] = ["entryId": .string(entryId)]
        if let label, !label.isEmpty { args["label"] = .string(label) }
        _ = try await control(key: key, "label", args: .object(args))
    }
}
