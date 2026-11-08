import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Settings › Safety (docs/pi-parity-plan.md §6): @gotgenes/pi-permission-system,
// its policy for chats (`permissions`: pi's global
// extensions/pi-permission-system/config.json, and per project under .pi/),
// and the one pocketpi gives workflow stages (`stage-policy`:
// ~/.config/pocketpi/safety/stage-policy.json, src/safety.rs). Rule maps are
// ordered (the last matching rule wins), so the server hands them out as
// `rules: {surface: [[pattern, action], ...]}` and takes them back that way.

/// What a rule does.
public enum PolicyAction: String, Sendable, CaseIterable, Equatable {
    case allow, ask, deny

    public var label: String {
        switch self {
        case .allow: return "Allow"
        case .ask: return "Ask"
        case .deny: return "Deny"
        }
    }
}

/// One `pattern: action` line of a rule map. A deny may carry a reason the
/// model is told.
public struct PolicyRule: Sendable, Equatable, Identifiable, Hashable {
    public var id = UUID()
    public var pattern: String
    public var action: PolicyAction
    public var reason: String?

    public init(pattern: String, action: PolicyAction, reason: String? = nil) {
        self.pattern = pattern
        self.action = action
        self.reason = reason
    }

    /// From the server's `[pattern, action]`.
    init?(pair: JSONValue) {
        guard let p = pair[0]?.string, let a = pair[1] else { return nil }
        if let s = a.string, let act = PolicyAction(rawValue: s) {
            self.init(pattern: p, action: act)
        } else if a["action"]?.string == "deny" {
            self.init(pattern: p, action: .deny, reason: a["reason"]?.string)
        } else {
            return nil
        }
    }

    var pair: JSONValue {
        let value: JSONValue
        if action == .deny, let r = reason?.trimmingCharacters(in: .whitespaces), !r.isEmpty {
            value = ["action": "deny", "reason": .string(r)]
        } else {
            value = .string(action.rawValue)
        }
        return [.string(pattern), value]
    }

    public static func == (a: PolicyRule, b: PolicyRule) -> Bool {
        a.pattern == b.pattern && a.action == b.action && (a.reason ?? "") == (b.reason ?? "")
    }
    public func hash(into h: inout Hasher) { h.combine(pattern); h.combine(action) }
}

/// Which policy file.
public enum PolicyFile: String, Sendable {
    /// The extension's own config: chats, and the terminal's pi too.
    case chats = "permissions"
    /// pocketpi's file for workflow stages.
    case stages = "stage-policy"
}

/// A policy file as read: the surfaces pocketpi edits, in file order.
public struct PolicyDocument: Sendable, Equatable {
    public var exists: Bool
    public var path: String
    public var data: JSONValue
    /// Object-valued surfaces, in order.
    public var rules: [String: [PolicyRule]]

    public init(exists: Bool = false, path: String = "", data: JSONValue = [:], rules: [String: [PolicyRule]] = [:]) {
        self.exists = exists
        self.path = path
        self.data = data
        self.rules = rules
    }

    init(_ v: JSONValue) {
        exists = v["exists"]?.bool ?? false
        path = v["path"]?.string ?? ""
        data = v["data"] ?? [:]
        var r: [String: [PolicyRule]] = [:]
        for (surface, pairs) in v["rules"]?.object ?? [:] {
            r[surface] = (pairs.array ?? []).compactMap(PolicyRule.init(pair:))
        }
        rules = r
    }

    /// The surfaces the page shows as lists. The directional ones only when
    /// the file uses them (the stage policy does).
    public static let mainSurfaces = ["bash", "path", "external_directory"]
    public var surfaces: [String] {
        let extra = ["path_read", "path_write", "external_directory_read", "external_directory_write"]
            .filter { data["permission"]?[$0] != nil }
        return Self.mainSurfaces + extra
    }

    /// A surface's rules; a plain action (`"bash": "allow"`) reads as `* -> action`.
    public func rules(for surface: String) -> [PolicyRule] {
        if let r = rules[surface] { return r }
        if let s = data["permission"]?[surface]?.string, let a = PolicyAction(rawValue: s) {
            return [PolicyRule(pattern: "*", action: a)]
        }
        return []
    }

    public var promptTimeoutMs: Int? { data["promptTimeoutMs"]?.int }
    public var yoloMode: Bool { data["yoloMode"]?.bool ?? false }

    /// "6 ask · 7 deny", for a list row.
    public func summary(for surface: String) -> String {
        let r = rules(for: surface)
        if r.isEmpty { return "not set (uses the default)" }
        let fallback = r.last { $0.pattern == "*" }?.action
        var parts: [String] = []
        if let fallback { parts.append("\(fallback.rawValue) by default") }
        for a in PolicyAction.allCases {
            let n = r.filter { $0.pattern != "*" && $0.action == a }.count
            if n > 0 { parts.append("\(n) \(a.rawValue)") }
        }
        return parts.joined(separator: " · ")
    }
}

/// The page's model of things, all pure so it's tested on Linux.
public enum Safety {
    /// What "Install" installs (the server pins the same).
    public static let package = "npm:@gotgenes/pi-permission-system@42.0.0"

    /// Whether pi's settings list the package (`packages`: strings or `{source}`).
    public static func isInstalled(settings: JSONValue) -> Bool {
        (settings["packages"]?.array ?? []).contains { p in
            let s = p.string ?? p["source"]?.string ?? ""
            return s.contains("@gotgenes/pi-permission-system")
        }
    }

    /// The patch that replaces one surface's rules, keeping their order.
    public static func setRules(_ surface: String, _ rules: [PolicyRule]) -> PiConfigPatch {
        let clean = rules.filter { !$0.pattern.trimmingCharacters(in: .whitespaces).isEmpty }
        return PiConfigPatch(set: [PiConfigPatch.path("permission", surface): .array(clean.map(\.pair))])
    }

    /// Minutes from `promptTimeoutMs`, for "Unanswered prompts are denied after N min".
    public static func timeoutText(_ ms: Int?) -> String {
        guard let ms, ms > 0 else { return "Unanswered prompts wait forever" }
        if ms % 60000 == 0 { return "Unanswered prompts are denied after \(ms / 60000) min" }
        return "Unanswered prompts are denied after \(ms / 1000) s"
    }

    // MARK: per project

    /// What a project's own policy file does on top of the global one.
    public enum ProjectMode: String, Sendable, CaseIterable, Equatable {
        /// No changes: the global policy.
        case standard
        /// `yoloMode`: every "ask" is allowed without asking; denies still deny.
        case off
        /// bash, write and edit all ask (except what the global policy allows or denies by name).
        case strict
        /// Something else pocketpi didn't write.
        case custom

        public var label: String {
            switch self {
            case .standard: return "Ask"
            case .off: return "Off"
            case .strict: return "Strict"
            case .custom: return "Custom"
            }
        }

        public var explanation: String {
            switch self {
            case .standard: return "The global policy: asks before risky commands."
            case .off: return "Never asks: what would ask is allowed. Hard denies (secrets, sudo) still apply."
            case .strict: return "Asks before every command, write and edit, unless a global rule allows it by name."
            case .custom: return "This project's policy file has its own rules."
            }
        }
    }

    /// The keys a mode sets; everything else in the file is left alone.
    static let strictKeys = ["permission.bash.*", "permission.write", "permission.edit"]

    public static func mode(of project: PolicyDocument) -> ProjectMode {
        guard project.exists else { return .standard }
        let d = project.data
        if d["yoloMode"]?.bool == true { return .off }
        let bash = d["permission"]?["bash"]
        let bashAsks = bash?.string == "ask" || bash?["*"]?.string == "ask"
        if bashAsks && d["permission"]?["write"]?.string == "ask" && d["permission"]?["edit"]?.string == "ask" {
            return .strict
        }
        let managed = d["yoloMode"] != nil || bash?["*"] != nil || bash?.string != nil
            || d["permission"]?["write"] != nil || d["permission"]?["edit"] != nil
        let other = (d.object ?? [:]).keys.contains { $0 != "$schema" && $0 != "permission" && $0 != "yoloMode" }
            // (what a mode leaves behind, like `bash: {}`, changes nothing)
            || (d["permission"]?.object ?? [:]).values.contains { $0.object?.isEmpty != true }
        return managed || other ? .custom : .standard
    }

    /// The patch that puts a project in `mode` (not for `.custom`).
    public static func patch(for mode: ProjectMode) -> PiConfigPatch {
        switch mode {
        case .standard, .custom:
            return PiConfigPatch(unset: ["yoloMode"] + strictKeys)
        case .off:
            return PiConfigPatch(set: ["yoloMode": true], unset: strictKeys)
        case .strict:
            return PiConfigPatch(set: ["permission.bash.*": "ask", "permission.write": "ask", "permission.edit": "ask"],
                                 unset: ["yoloMode"])
        }
    }

    /// Whether pi trusts `project` (trust.json: the nearest saved decision
    /// for the folder or a parent, else `defaultProjectTrust: "always"`).
    /// The extension ignores an untrusted project's policy.
    public static func isTrusted(_ project: String, trust: JSONValue, defaultTrust: String?) -> Bool {
        let decisions = trust.object ?? [:]
        var dir = project.count > 1 && project.hasSuffix("/") ? String(project.dropLast()) : project
        while true {
            if let d = decisions[dir]?.bool { return d }
            guard let slash = dir.lastIndex(of: "/"), dir != "/" else { break }
            dir = slash == dir.startIndex ? "/" : String(dir[..<slash])
        }
        return defaultTrust == "always"
    }
}

/// A dialog notification as it also appears on the runs stream.
public struct DialogNotice: Sendable, Equatable {
    public var key: String
    public var id: String
    public var title: String
    public var body: String
    public var url: String

    public init?(_ ev: JSONValue) {
        guard ev["type"]?.string == "dialog_pending", let key = ev["key"]?.string, let id = ev["id"]?.string else { return nil }
        self.key = key
        self.id = id
        title = ev["title"]?.string ?? ""
        body = ev["body"]?.string ?? ""
        url = ev["url"]?.string ?? ""
    }
}

extension PocketPiClient {
    private static func cwdQuery(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        return "?cwd=" + (cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? cwd)
    }

    /// A policy file (the chat policy per project with `cwd`).
    public func policy(_ file: PolicyFile, cwd: String? = nil) async throws -> PolicyDocument {
        PolicyDocument(try await get("/api/pi/config/\(file.rawValue)\(Self.cwdQuery(cwd))", as: JSONValue.self))
    }

    /// Change a policy file; returns it as it is now. The extension rereads
    /// it by itself (no restart), stages read theirs when they start.
    @discardableResult
    public func patchPolicy(_ file: PolicyFile, _ patch: PiConfigPatch, cwd: String? = nil) async throws -> PolicyDocument {
        PolicyDocument(try await post("/api/pi/config/\(file.rawValue)\(Self.cwdQuery(cwd))", patch.json, as: JSONValue.self))
    }

    /// Write pocketpi's proposed policy over the file's keys (others stay).
    @discardableResult
    public func useRecommendedPolicy(_ file: PolicyFile) async throws -> PolicyDocument {
        PolicyDocument(try await post("/api/safety/recommended", ["file": .string(file.rawValue)], as: JSONValue.self))
    }

    /// `/api/safety`: the package, the proposed policies, where stages' policy lives.
    public func safetyInfo() async throws -> JSONValue { try await get("/api/safety") }

    /// Wait for a pi CLI job to end (polling); returns it.
    public func waitForJob(_ id: String, every: Duration = .milliseconds(500), timeout: Duration = .seconds(300)) async throws -> PiJob {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: timeout)
        while true {
            let j = try await job(id: id)
            if j.status != "running" { return j }
            if clock.now > end { throw PocketPiError.unexpected("pi install is taking too long") }
            try await Task.sleep(for: every)
        }
    }

    /// Install the package (a pi CLI job), then write the recommended chat
    /// policy. Returns the finished job; the policy is only written when
    /// the install worked.
    public func installPermissionSystem() async throws -> PiJob {
        let id = try await startJob(.install(source: Safety.package))
        let job = try await waitForJob(id)
        if job.status == "ok" {
            try await useRecommendedPolicy(.chats)
        }
        return job
    }

    /// The runs stream (`/api/runs/events`): runs, jobs, config changes and
    /// `dialog_pending` notices.
    public func runEvents() -> AsyncThrowingStream<JSONValue, Error> {
        do {
            var r = try request("/api/runs/events")
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            r.timeoutInterval = 60
            return SSEStream.open(r)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
