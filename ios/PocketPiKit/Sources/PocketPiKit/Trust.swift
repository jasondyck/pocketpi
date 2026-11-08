import Foundation

// Project trust (plan E5; the server side is src/pi_resources.rs).
//
// pi keeps decisions in ~/.pi/agent/trust.json: one flat object, canonical
// folder path → true (trusted) or false (not trusted). The nearest saved
// decision for a folder or one of its parents applies; with none, pi uses
// `defaultProjectTrust` from the global settings. Over RPC, which is how
// pocketpi runs pi, "ask" can't ask: the project's .pi resources are
// silently skipped. `GET /api/pi/trust` resolves this per project; changes
// are patches of trust.json / settings.json through the config routes.

/// `defaultProjectTrust`.
public enum ProjectTrustDefault: String, Sendable, CaseIterable, Identifiable {
    case ask, always, never
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: "Ask (pi's default)"
        case .always: "Always trust"
        case .never: "Never trust"
        }
    }

    /// What it means for a project without a decision, under pocketpi.
    public var explanation: String {
        switch self {
        case .ask: "pi can't ask over pocketpi, so a project without a decision runs without its .pi resources: they are silently skipped."
        case .always: "Every project's .pi extensions, skills, prompts, settings and MCP servers load. Only for folders you wrote yourself."
        case .never: "Projects without a decision never load their .pi resources."
        }
    }

    /// The settings patch that makes this the default ("ask" is pi's own
    /// default, so it is written by removing the key).
    public var patch: PiConfigPatch {
        self == .ask ? PiConfigPatch(unset: ["defaultProjectTrust"]) : PiConfigPatch(set: ["defaultProjectTrust": .string(rawValue)])
    }
}

/// The three things a person can say about one folder.
public enum TrustChoice: String, Sendable, CaseIterable, Identifiable {
    case trust, distrust
    /// No saved decision: a parent's applies, else the default.
    case none
    public var id: String { rawValue }

    /// The trust.json patch for `path` (a canonical folder path).
    public func patch(for path: String) -> PiConfigPatch {
        let key = PiConfigPatch.path(path)
        switch self {
        case .trust: return PiConfigPatch(set: [key: true])
        case .distrust: return PiConfigPatch(set: [key: false])
        case .none: return PiConfigPatch(unset: [key])
        }
    }
}

/// One project's trust, as `/api/pi/trust` resolves it.
public struct ProjectTrust: Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    /// The key pi uses in trust.json.
    public var canonical: String
    /// The nearest saved decision (this folder's or a parent's), if any.
    public var decision: Bool?
    /// Which trust.json key that decision is under.
    public var from: String?
    /// The decision is for this folder itself, not inherited.
    public var explicit: Bool
    /// Whether pi (in RPC mode) loads the project's protected resources.
    public var trusted: Bool
    /// The project has something trust gates (.pi/extensions, ...).
    public var needsTrust: Bool
    public var protected: [String]
    public var id: String { path }

    init?(_ v: JSONValue) {
        guard let p = v["path"]?.string else { return nil }
        path = p
        name = v["name"]?.string ?? (p as NSString).lastPathComponent
        canonical = v["canonical"]?.string ?? p
        decision = v["decision"]?.bool
        from = v["from"]?.string
        explicit = v["explicit"]?.bool ?? false
        trusted = v["trusted"]?.bool ?? false
        needsTrust = v["needsTrust"]?.bool ?? false
        protected = v["protected"]?.array?.compactMap(\.string) ?? []
    }

    /// What the picker shows as selected.
    public var choice: TrustChoice {
        guard explicit, let decision else { return .none }
        return decision ? .trust : .distrust
    }

    /// The label for "no decision of its own": it may inherit a parent's.
    public var noneLabel: String { from != nil && !explicit ? "Inherit" : "No decision" }

    /// One line on what pi does with this project, and why.
    public func summary(default d: ProjectTrustDefault, home: String = "") -> String {
        let via: String
        if let from, !explicit { via = " (from \(Self.tilde(from, home: home)))" } else { via = "" }
        switch decision {
        case true?: return "Trusted\(via): its .pi resources load"
        case false?: return "Not trusted\(via): its .pi resources are skipped"
        case nil: return d == .always ? "No decision: loads (default is always)" : "No decision: skipped (default is \(d.rawValue))"
        }
    }

    static func tilde(_ p: String, home: String) -> String {
        guard !home.isEmpty else { return p }
        if p == home { return "~" }
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
}

/// `GET /api/pi/trust`.
public struct TrustOverview: Sendable, Equatable {
    /// Where trust.json is.
    public var path: String
    /// trust.json isn't valid; pocketpi won't change it.
    public var error: String?
    public var defaultTrust: ProjectTrustDefault
    public var projects: [ProjectTrust]
    /// Every saved decision (null entries left out).
    public var entries: [String: Bool]

    public init(_ v: JSONValue) {
        path = v["path"]?.string ?? ""
        error = v["error"]?.string
        defaultTrust = ProjectTrustDefault(rawValue: v["default"]?.string ?? "ask") ?? .ask
        projects = v["projects"]?.array?.compactMap(ProjectTrust.init) ?? []
        entries = (v["entries"]?.object ?? [:]).compactMapValues(\.bool)
    }

    /// Saved decisions for folders that aren't listed projects (parents,
    /// old paths), sorted by path.
    public var otherEntries: [(path: String, trusted: Bool)] {
        let shown = Set(projects.map(\.canonical))
        return entries.filter { !shown.contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

extension PocketPiClient {
    /// Every project's trust, the default, and trust.json's other entries.
    public func trustOverview() async throws -> TrustOverview {
        TrustOverview(try await get("/api/pi/trust", as: JSONValue.self))
    }

    /// Save (or remove) the decision for a folder. Takes effect when chats restart.
    @discardableResult
    public func setTrust(_ choice: TrustChoice, for canonicalPath: String) async throws -> PiConfigDocument {
        try await patchConfig(.trust, choice.patch(for: canonicalPath))
    }

    /// Change `defaultProjectTrust` in the global settings.
    @discardableResult
    public func setDefaultProjectTrust(_ d: ProjectTrustDefault) async throws -> PiConfigDocument {
        try await patchConfig(.settings, d.patch)
    }
}
