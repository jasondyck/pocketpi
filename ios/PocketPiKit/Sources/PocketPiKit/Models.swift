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

/// A workflow run (`/api/runs`): the parts the Approvals screen uses.
public struct RunInfo: Sendable, Identifiable, Equatable {
    public struct Stage: Sendable, Equatable {
        public var id: String
        public var name: String
        public var kind: String
        public var status: String
        /// For an approval: the question and what it's about (Markdown).
        public var prompt: String?
        public var summary: String
    }

    public var id: String
    public var workflowId: String
    public var workflowName: String
    public var status: String
    public var trigger: String
    /// Milliseconds since 1970.
    public var created: UInt64
    public var stages: [Stage]

    public init?(_ v: JSONValue) {
        guard let id = v["id"]?.string, let wf = v["workflow_id"]?.string else { return nil }
        self.id = id
        workflowId = wf
        workflowName = v["workflow_name"]?.string ?? wf
        status = v["status"]?.string ?? ""
        trigger = v["trigger"]?.string ?? ""
        created = UInt64(v["created"]?.double ?? 0)
        stages = (v["stages"]?.array ?? []).compactMap { s in
            guard let id = s["id"]?.string else { return nil }
            return Stage(id: id, name: s["name"]?.string ?? id, kind: s["kind"]?.string ?? "",
                         status: s["status"]?.string ?? "", prompt: s["prompt"]?.string,
                         summary: s["summary"]?.string ?? "")
        }
    }

    /// What a waiting approval is about, for the list: the first line of its
    /// text without Markdown ("Post this review on PR #89?"), else the stage.
    public var headline: String {
        guard let stage = waitingApproval else { return workflowName }
        for line in (stage.prompt ?? "").split(separator: "\n") {
            let clean = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { return clean }
        }
        return stage.name
    }

    /// A review's verdict when the text has one ("Verdict: pass").
    public var verdict: String? {
        guard let p = waitingApproval?.prompt?.replacingOccurrences(of: "**", with: ""),
              let r = p.range(of: "Verdict:", options: .caseInsensitive) else { return nil }
        let rest = p[r.upperBound...].split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return rest.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The approval this run is waiting for, if it is.
    public var waitingApproval: Stage? {
        stages.first { $0.kind == "approval" && $0.status == "waiting" }
    }

    public var createdDate: Date { Date(timeIntervalSince1970: Double(created) / 1000) }
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

    /// pi's model patterns: exact, or `*` for any run of characters.
    public static func matches(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(s.lowercased())
        func go(_ i: Int, _ j: Int) -> Bool {
            if i == p.count { return j == t.count }
            if p[i] == "*" { return (j...t.count).contains { go(i + 1, $0) } }
            return j < t.count && p[i] == t[j] && go(i + 1, j + 1)
        }
        return go(0, 0)
    }

    /// The provider as people write it: known ones by their own spelling,
    /// others with each word capitalised ("my-proxy" → "My Proxy").
    public var providerLabel: String { Self.providerLabel(provider) }

    public static func providerLabel(_ p: String) -> String {
        let known: [String: String] = [
            "anthropic": "Anthropic", "openai": "OpenAI", "openai-codex": "OpenAI Codex",
            "google": "Google", "google-vertex": "Google Vertex", "gemini": "Gemini",
            "deepseek": "DeepSeek", "xai": "xAI", "mistral": "Mistral", "groq": "Groq",
            "openrouter": "OpenRouter", "opencode": "OpenCode", "opencode-go": "OpenCode Go",
            "github-copilot": "GitHub Copilot", "amazon-bedrock": "Amazon Bedrock",
            "azure-openai": "Azure OpenAI", "cerebras": "Cerebras", "zai": "Z.ai",
            "moonshot": "Moonshot", "minimax": "MiniMax", "ollama": "Ollama",
            "lmstudio": "LM Studio", "huggingface": "Hugging Face", "vercel-ai-gateway": "Vercel AI Gateway",
        ]
        if let k = known[p.lowercased()] { return k }
        return p.split(whereSeparator: { "-_ ".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
