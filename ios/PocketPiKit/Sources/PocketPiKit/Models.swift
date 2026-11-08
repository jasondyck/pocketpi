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

/// A workflow run (`/api/runs`, src/engine.rs `Run`).
public struct RunInfo: Sendable, Identifiable, Equatable {
    public struct Stage: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String
        public var status: String
        /// For an approval: the question and what it's about (Markdown).
        /// For a shell stage: the command it ran.
        public var prompt: String?
        public var summary: String
        /// What the stage printed or replied (the server keeps the tail).
        public var output: String
        public var attempts: Int
        /// Milliseconds since 1970.
        public var started: UInt64?
        public var ended: UInt64?
        /// While an agent stage runs: what pi is doing ("Reading src/main.rs")
        /// and since when (ms since 1970).
        public var activity: String? = nil
        public var activityAt: UInt64? = nil
    }

    public var id: String
    public var workflowId: String
    public var workflowName: String
    public var status: String
    public var trigger: String
    /// Milliseconds since 1970.
    public var created: UInt64
    public var ended: UInt64?
    public var stages: [Stage]
    public var inputs: [String: String]
    public var cost: Double
    /// Why it failed.
    public var error: String?
    public var branch: String?

    public init?(_ v: JSONValue) {
        guard let id = v["id"]?.string, let wf = v["workflow_id"]?.string else { return nil }
        self.id = id
        workflowId = wf
        workflowName = v["workflow_name"]?.string ?? wf
        status = v["status"]?.string ?? ""
        trigger = v["trigger"]?.string ?? ""
        created = UInt64(v["created"]?.double ?? 0)
        ended = v["ended"]?.double.map { UInt64($0) }
        stages = (v["stages"]?.array ?? []).compactMap { s in
            guard let id = s["id"]?.string else { return nil }
            return Stage(id: id, name: s["name"]?.string ?? id, kind: s["kind"]?.string ?? "",
                         status: s["status"]?.string ?? "", prompt: s["prompt"]?.string,
                         summary: s["summary"]?.string ?? "", output: s["output"]?.string ?? "",
                         attempts: s["attempts"]?.int ?? 0,
                         started: s["started"]?.double.map { UInt64($0) },
                         ended: s["ended"]?.double.map { UInt64($0) },
                         activity: s["activity"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                         activityAt: s["activity_at"]?.double.map { UInt64($0) })
        }
        inputs = (v["inputs"]?.object ?? [:]).compactMapValues(\.string)
        cost = v["cost"]?.double ?? 0
        error = v["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        branch = v["branch"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Still going: running, or paused at an approval.
    public var isActive: Bool { ["pending", "running", "waiting"].contains(status) }

    /// The stage it's on: the one waiting for a person, else the one
    /// running, else nil (queued, or between stages).
    public var currentStage: Stage? {
        stages.first { $0.status == "waiting" } ?? stages.first { $0.status == "running" }
    }

    /// The inputs to start the same run again: the ones a person would set.
    /// The PR's commit is left out so the server picks the PR's current head,
    /// and so is what a sensor or schedule adds for its own bookkeeping.
    public var rerunInputs: [String: String] {
        inputs.filter { !["commit", "scheduled_for", "title", "url", "branch"].contains($0.key) }
    }

    /// The inputs worth showing, in a stable order ("pr" → "PR #89").
    public var inputSummary: String {
        inputs.filter { !["commit", "scheduled_for", "title", "url", "branch"].contains($0.key) && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { $0.key == "pr" ? "PR #\($0.value)" : $0.key == "issue" ? "issue #\($0.value)" : "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }

    /// How the run began, in words.
    public var startedBy: String {
        switch trigger {
        case "manual", "chat": "started manually"
        case "agent": "started by pi"
        case "schedule": "started on a schedule"
        case "webhook": "started by a webhook"
        case "merge-gate": "started by the merge gate"
        case "": "started"
        default: "started by a new " + trigger // pr, issue, commit sensors
        }
    }

    /// How long it ran (or has been running, as of `now`).
    public func duration(now: Date = Date()) -> TimeInterval {
        let end = ended.map { Double($0) / 1000 } ?? now.timeIntervalSince1970
        return max(0, end - Double(created) / 1000)
    }

    /// What a waiting approval is about, for the list: the first line of its
    /// text without Markdown ("Post this review on PR #89?"), else the stage.
    public var headline: String {
        guard let stage = waitingApproval else { return workflowName }
        for line in (stage.prompt ?? "").split(separator: "\n") {
            let clean = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            // The verdict has its own label; the headline is what it's about.
            if !clean.isEmpty, !clean.lowercased().hasPrefix("verdict:") { return clean }
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
    /// "45s", "3m 12s", "1h 4m".
    public static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

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

/// One of pi's slash commands (`get_commands`): an extension command, a
/// prompt template or a skill. Built-in TUI commands aren't listed; pi only
/// runs these through `prompt`.
public struct SlashCommand: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String?
    /// "extension", "prompt" or "skill".
    public var source: String?
    public var id: String { name }

    public init(name: String, description: String? = nil, source: String? = nil) {
        self.name = name
        self.description = description
        self.source = source
    }

    public init?(_ v: JSONValue) {
        guard let name = v["name"]?.string, !name.isEmpty else { return nil }
        self.init(name: name, description: v["description"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                  source: v["source"]?.string)
    }

    /// The commands to offer for what's typed: only while the composer is a
    /// lone `/word` (nothing after it yet), names containing the word, those
    /// starting with it first, at most 30. Like web/app.js's updateSlash.
    public static func matches(_ commands: [SlashCommand], for text: String) -> [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let q = text.dropFirst().lowercased()
        let hits = commands.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let (starts, rest) = hits.reduce(into: ([SlashCommand](), [SlashCommand]())) { acc, c in
            if c.name.lowercased().hasPrefix(q) { acc.0.append(c) } else { acc.1.append(c) }
        }
        return Array((starts + rest).prefix(30))
    }
}
