import Foundation

/// A workflow definition (`/api/workflows`, src/workflows.rs) with the
/// server's notes on it: validation errors, its last run, how many runs.
public struct WorkflowInfo: Sendable, Identifiable, Equatable {
    public struct Input: Sendable, Equatable, Hashable, Identifiable {
        public var name: String
        public var description: String
        public var required: Bool
        public var defaultValue: String
        public var id: String { name }
    }

    public struct LastRun: Sendable, Equatable {
        public var id: String
        public var status: String
        /// Milliseconds since 1970.
        public var created: UInt64
        public var createdDate: Date { Date(timeIntervalSince1970: Double(created) / 1000) }
    }

    public var id: String
    public var name: String
    public var description: String
    public var project: String
    public var enabled: Bool
    public var inputs: [Input]
    /// The triggers in words ("every 30 minutes", "new PR commits").
    public var triggers: [String]
    /// Whether a person can start it (it has a manual trigger).
    public var manual: Bool
    public var stageCount: Int
    public var maxCost: Double?
    public var errors: [String]
    /// Self-improvement: "off", "suggest" or "auto".
    public var improve: String
    public var lastRun: LastRun?
    public var runCount: Int

    public init?(_ v: JSONValue) {
        guard let w = v["workflow"], let id = w["id"]?.string else { return nil }
        self.id = id
        name = w["name"]?.string ?? id
        description = w["description"]?.string ?? ""
        project = w["project"]?.string ?? ""
        enabled = w["enabled"]?.bool ?? false
        inputs = (w["inputs"]?.array ?? []).compactMap { i in
            guard let n = i["name"]?.string else { return nil }
            return Input(name: n, description: i["description"]?.string ?? "",
                         required: i["required"]?.bool ?? false, defaultValue: i["default"]?.string ?? "")
        }
        let trig = w["triggers"]?.array ?? []
        triggers = trig.compactMap(Self.describe)
        manual = trig.isEmpty || trig.contains { $0["type"]?.string == "manual" }
        stageCount = w["stages"]?.array?.count ?? 0
        maxCost = w["max_cost"]?.double
        errors = (v["errors"]?.array ?? []).compactMap(\.string)
        improve = w["improve"]?.string ?? "suggest"
        if let l = v["last_run"], let lid = l["id"]?.string {
            lastRun = LastRun(id: lid, status: l["status"]?.string ?? "", created: UInt64(l["created"]?.double ?? 0))
        }
        runCount = v["runs"]?.int ?? v["runs"]?.array?.count ?? 0
    }

    /// A trigger in words. Manual is left out: every workflow can be run.
    static func describe(_ t: JSONValue) -> String? {
        switch t["type"]?.string {
        case "schedule": return Self.cronWords(t["cron"]?.string ?? "")
        case "git":
            switch t["on"]?.string {
            case "pr": return "new PR commits"
            case "issue": return "new issues"
            default: return "new commits" + (t["branch"]?.string.map { " on \($0)" } ?? "")
            }
        case "webhook": return "a webhook"
        case "agent": return "pi, when it applies"
        default: return nil
        }
    }

    /// The common cron shapes in words; anything else as the expression.
    static func cronWords(_ cron: String) -> String {
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5 else { return "schedule \(cron)" }
        let rest = f[2...].allSatisfy { $0 == "*" }
        if rest, f[1] == "*", f[0].hasPrefix("*/"), let n = Int(f[0].dropFirst(2)) {
            return n == 1 ? "every minute" : "every \(n) minutes"
        }
        if rest, f[1] == "*", let m = Int(f[0]) { return String(format: "hourly at :%02d", m) }
        if rest, f[1].hasPrefix("*/"), let n = Int(f[1].dropFirst(2)), Int(f[0]) != nil {
            return n == 1 ? "every hour" : "every \(n) hours"
        }
        if rest, let h = Int(f[1]), let m = Int(f[0]) { return String(format: "daily at %d:%02d", h, m) }
        return "schedule \(cron)"
    }
}

/// What starting a run did.
public enum StartResult: Sendable, Equatable {
    case started(runId: String)
    /// The same thing already ran (or is running); start it with `force` to
    /// run anyway.
    case duplicate(runId: String, message: String)
}

/// One workflow in full (`/api/workflows/{id}`): the definition as JSON (for
/// copying and diffs), a suggested improvement waiting for you, and the
/// earlier versions it can go back to.
public struct WorkflowDetail: Sendable, Equatable {
    public struct Change: Sendable, Equatable, Hashable {
        public var summary: String
        public var why: String
    }

    public struct Proposal: Sendable, Equatable {
        /// Milliseconds since 1970.
        public var created: UInt64
        public var model: String
        public var changes: [Change]
        /// Why it wasn't applied by itself ("removes an approval stage").
        public var violations: [String]
        public var workflow: JSONValue
        public var createdDate: Date { Date(timeIntervalSince1970: Double(created) / 1000) }
        /// "openai-codex/gpt-6.1-sol" → "gpt-6.1-sol".
        public var modelLabel: String { model.split(separator: "/").last.map(String.init) ?? model }
    }

    public struct Version: Sendable, Equatable, Identifiable {
        public var version: String
        /// When this version was replaced, ms since 1970.
        public var at: UInt64
        /// Why it was replaced ("auto-improved after run …: …").
        public var reason: String
        public var id: String { version }
        public var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }
    }

    public var info: WorkflowInfo
    public var workflow: JSONValue
    public var proposal: Proposal?
    public var history: [Version]

    public init?(_ v: JSONValue) {
        guard let info = WorkflowInfo(v), let w = v["workflow"] else { return nil }
        self.info = info
        workflow = w
        if let p = v["proposal"], let pw = p["workflow"], !pw.isNull {
            proposal = Proposal(
                created: UInt64(p["created"]?.double ?? 0),
                model: p["model"]?.string ?? "",
                changes: (p["changes"]?.array ?? []).compactMap { c in
                    guard let s = c["summary"]?.string else { return nil }
                    return Change(summary: s, why: c["why"]?.string ?? "")
                },
                violations: (p["violations"]?.array ?? []).compactMap(\.string),
                workflow: pw)
        }
        history = (v["history"]?.array ?? []).compactMap { h in
            guard let ver = h["version"]?.string else { return nil }
            return Version(version: ver, at: UInt64(h["at"]?.double ?? 0), reason: h["reason"]?.string ?? "")
        }
    }

    /// The suggested change as a line diff of the two definitions.
    public var proposalDiff: [DiffLine] {
        guard let p = proposal else { return [] }
        return DiffLine.diff(workflow.prettyLines, p.workflow.prettyLines)
    }
}

public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable { case same, added, removed, skipped }
    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    /// Line diff (longest common subsequence), with unchanged runs longer than
    /// `context` lines on each side of a change folded into one `.skipped`
    /// line saying how many were left out.
    public static func diff(_ a: [String], _ b: [String], context: Int = 2) -> [DiffLine] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(DiffLine(.same, a[i])); i += 1; j += 1
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                // removals first, so a changed line reads old then new
                out.append(DiffLine(.removed, a[i])); i += 1
            } else {
                out.append(DiffLine(.added, b[j])); j += 1
            }
        }
        // fold long unchanged runs
        let changed = out.indices.filter { out[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(out.count - 1, c + context) { keep.insert(k) } }
        var folded: [DiffLine] = []
        var skipped = 0
        for (k, line) in out.enumerated() {
            if keep.contains(k) {
                if skipped > 0 { folded.append(DiffLine(.skipped, "\(skipped) unchanged line\(skipped == 1 ? "" : "s")")); skipped = 0 }
                folded.append(line)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { folded.append(DiffLine(.skipped, "\(skipped) unchanged line\(skipped == 1 ? "" : "s")")) }
        return folded
    }
}

extension JSONValue {
    /// Indented JSON with sorted keys, one line per entry, for diffs.
    public var prettyLines: [String] {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let d = try? e.encode(self), let t = String(data: d, encoding: .utf8) else { return [] }
        return t.components(separatedBy: "\n")
    }

    /// Indented JSON text (for copying a definition).
    public var prettyText: String { prettyLines.joined(separator: "\n") }
}
