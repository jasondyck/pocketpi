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
        if let l = v["last_run"], let lid = l["id"]?.string {
            lastRun = LastRun(id: lid, status: l["status"]?.string ?? "", created: UInt64(l["created"]?.double ?? 0))
        }
        runCount = v["runs"]?.int ?? 0
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
