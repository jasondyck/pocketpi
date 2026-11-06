import Foundation

/// A project: a folder chats were started in (src/projects.rs).
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var pinned: Bool
    public var chats: Int
    public var live: Int
    public var streaming: Bool
    public var modified: UInt64
    public var exists: Bool
    public var id: String { path }
}

public struct ProjectsResponse: Codable, Sendable {
    public var projects: [Project]
    public var home: String
}

/// One pi session file (src/sessions.rs). `live` means pocketpi has a pi
/// process open for it; `streaming` that pi is working in it right now.
public struct SessionInfo: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var id: String
    public var cwd: String
    public var name: String?
    public var title: String
    public var modified: UInt64
    public var messages: Int
    public var live: Bool
    public var streaming: Bool

    /// What the chat list shows: the name given with /name or rename, else
    /// the first line of the first prompt.
    public var displayTitle: String {
        if let n = name, !n.isEmpty { return n }
        return title.isEmpty ? "Chat" : title
    }

    public var modifiedDate: Date { Date(timeIntervalSince1970: Double(modified) / 1000) }
}

public struct SessionsResponse: Codable, Sendable {
    public var sessions: [SessionInfo]
}

/// The answer to /api/new and /api/open: `key` addresses the live pi process
/// until it exits or is reaped; the session file path is what lasts.
public struct OpenResponse: Codable, Sendable {
    public var key: String
    public var cwd: String
}

/// `/api/version`: the build id changes on every server start, which is how
/// the web page notices a deploy.
public struct BuildInfo: Codable, Sendable, Equatable {
    public var build: UInt64
}

/// pi's `get_state`, the parts the app uses. The model is left as JSON: its
/// shape is pi's and only its id/name/provider are shown.
public struct ChatState: Sendable, Equatable {
    public var sessionName: String?
    public var sessionFile: String?
    public var isStreaming: Bool
    public var thinkingLevel: String?
    public var messageCount: Int
    public var model: JSONValue?

    public init(_ v: JSONValue) {
        sessionName = v["sessionName"]?.string
        sessionFile = v["sessionFile"]?.string
        isStreaming = v["isStreaming"]?.bool ?? false
        thinkingLevel = v["thinkingLevel"]?.string
        messageCount = v["messageCount"]?.int ?? 0
        model = v["model"].flatMap { $0.isNull ? nil : $0 }
    }

    public var modelLabel: String {
        guard let m = model else { return "no model" }
        let id = m["id"]?.string ?? m["name"]?.string ?? ""
        return id.split(separator: "/").last.map(String.init) ?? id
    }
}

/// A model pi can use (`get_available_models`): only the ones with a key set
/// up in pi.
public struct ModelInfo: Sendable, Hashable, Identifiable {
    public var provider: String
    public var id: String
    public var name: String?
    public var reasoning: Bool
    public var contextWindow: Int?
    public var vision: Bool
    /// Unique across providers.
    public var key: String { provider + "/" + id }

    public init?(_ v: JSONValue) {
        guard let provider = v["provider"]?.string, let id = v["id"]?.string else { return nil }
        self.provider = provider
        self.id = id
        name = v["name"]?.string
        reasoning = v["reasoning"]?.bool ?? false
        contextWindow = v["contextWindow"]?.int
        vision = v["input"]?.array?.contains(.string("image")) ?? false
    }

    /// What the picker shows: the model's name, else the last part of its id.
    public var label: String {
        if let n = name, !n.isEmpty { return n }
        return id.split(separator: "/").last.map(String.init) ?? id
    }
}

/// pi's `get_session_stats`: tokens, cost and how full the context is.
public struct SessionStats: Sendable, Equatable {
    public var cost: Double?
    public var totalTokens: Int?
    public var contextPercent: Double?
    public var contextWindow: Int?

    public init(_ v: JSONValue) {
        cost = v["cost"]?.double
        totalTokens = v["tokens"]?["total"]?.int
        contextPercent = v["contextUsage"]?["percent"]?.double
        contextWindow = v["contextUsage"]?["contextWindow"]?.int
    }

    /// 0...1, or nil when pi didn't say.
    public var contextFraction: Double? {
        contextPercent.map { min(1, max(0, $0 / 100)) }
    }
}

public enum Format {
    public static func tokens(_ n: Int?) -> String {
        guard let n else { return "–" }
        let d = Double(n)
        if n >= 1_000_000 { return String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", d / 1e6) }
        if n >= 1_000 { return String(format: n >= 10_000 ? "%.0fk" : "%.1fk", d / 1e3) }
        return String(n)
    }

    public static func cost(_ c: Double?) -> String {
        guard let c, c > 0 else { return "$0" }
        if c < 0.01 { return "<$0.01" }
        return String(format: c < 1 ? "$%.3f" : "$%.2f", c)
    }

    /// `/home/user/x` → `~/x` when `home` is `/home/user`.
    public static func tilde(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func baseName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? "/"
    }
}
