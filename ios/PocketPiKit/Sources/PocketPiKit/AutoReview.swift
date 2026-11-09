import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Settings › Safety › Auto review: @mzwing/pi-permission-auto-review, an
// `authorizerChain` link (named `auto-review`) that has a model answer the
// chat policy's asks the way Claude Code's auto mode does, so they reach the
// person only when its review fails (src/safety.rs). On/off is the chat
// policy's chain (`POST /api/safety/auto-review`), its settings are pi's
// extensions/pi-permission-auto-review/config.json (the `auto-review` config
// file, read when pi starts), and its recent decisions come from
// pi-permission-system's review log (`GET /api/safety/reviews`). The web twin
// is web/manage-safety.js.

/// The page's model of auto review, all pure so it's tested on Linux.
public enum AutoReview {
    /// What "Install auto review" installs (the server pins the same).
    public static let package = "npm:@mzwing/pi-permission-auto-review@1.0.1"
    /// Its link's name in the chat policy's `authorizerChain`.
    public static let link = "auto-review"

    /// Whose reviewer the config copies, and what each falls back to.
    public enum Preset: String, Sendable, CaseIterable, Equatable {
        case codex
        case claudeCode = "claude-code"

        public var label: String {
            switch self {
            case .codex: return "Codex"
            case .claudeCode: return "Claude Code"
            }
        }

        /// The model a preset reviews with when the config names none.
        public var defaultModel: String {
            switch self {
            case .codex: return "openai-codex/codex-auto-review"
            case .claudeCode: return "anthropic/claude-sonnet-5"
            }
        }

        public var defaultReasoning: String {
            switch self {
            case .codex: return "low"
            case .claudeCode: return "high"
            }
        }
    }

    /// `reasoning`'s levels, lowest first.
    public static let reasoningLevels = ["off", "minimal", "low", "medium", "high", "xhigh"]
    /// `followUpReviews`'s values and their labels; unset means auto.
    public static let followUps = ["auto", "always", "off"]
    public static func followUpLabel(_ v: String) -> String {
        switch v {
        case "auto": return "Auto"
        case "always": return "Always"
        case "off": return "Off"
        default: return v
        }
    }

    /// Whether pi's settings list the package (`packages`: strings or `{source}`).
    public static func isInstalled(settings: JSONValue) -> Bool {
        (settings["packages"]?.array ?? []).contains { p in
            let s = p.string ?? p["source"]?.string ?? ""
            return s.contains("@mzwing/pi-permission-auto-review")
        }
    }

    /// Whether the chat policy's `authorizerChain` has the link.
    public static func isOn(_ policy: PolicyDocument) -> Bool {
        (policy.data["authorizerChain"]?.array ?? []).contains(.string(link))
    }

    /// The row's subtitle.
    public static func status(installed: Bool, on: Bool) -> String {
        guard installed else { return "Not installed: pi's asks come to you" }
        return on ? "A model answers pi's permission asks; you're asked only when its review fails."
            : "Installed and off: pi's asks come to you."
    }
}

/// Auto review's config file as read: what the settings rows show.
public struct AutoReviewConfig: Sendable, Equatable {
    public var exists: Bool
    public var data: JSONValue

    public init(exists: Bool = false, data: JSONValue = [:]) {
        self.exists = exists
        self.data = data
    }

    public init(_ doc: PiConfigDocument) {
        self.init(exists: doc.exists, data: doc.data)
    }

    /// An unknown or missing preset reads as Codex, as the extension does.
    public var preset: AutoReview.Preset { data["preset"]?.string.flatMap(AutoReview.Preset.init) ?? .codex }
    public var provider: String? { data["provider"]?.string }
    public var model: String? { data["model"]?.string }
    /// "provider/model" when the config names one, else the preset's.
    public var modelKey: String? {
        guard let provider, let model, !provider.isEmpty, !model.isEmpty else { return nil }
        return provider + "/" + model
    }
    /// The set level, or nil for the preset's default.
    public var reasoning: String? { data["reasoning"]?.string.flatMap { AutoReview.reasoningLevels.contains($0) ? $0 : nil } }
    /// The set value, or nil for the default (auto).
    public var followUpReviews: String? { data["followUpReviews"]?.string.flatMap { AutoReview.followUps.contains($0) ? $0 : nil } }

    /// Claude through OpenCode Go fails a continued review conversation: each
    /// follow-up review errors and falls back to asking.
    public var claudeViaOpenCodeGo: Bool {
        provider == "opencode-go" && (model ?? "").lowercased().contains("claude") && followUpReviews != "off"
    }
    public static let claudeViaOpenCodeGoWarning = "Claude through OpenCode Go fails continued reviews, so they fall back to asking you. Set Follow-up reviews to Off."

    // MARK: patches

    public static func presetPatch(_ p: AutoReview.Preset) -> PiConfigPatch {
        PiConfigPatch(set: ["preset": .string(p.rawValue)])
    }

    /// "provider/model" sets both; "" (the preset's default) unsets both.
    /// Only the first slash splits: model ids may have their own.
    public static func modelPatch(_ key: String) -> PiConfigPatch {
        guard let slash = key.firstIndex(of: "/") else { return PiConfigPatch(unset: ["provider", "model"]) }
        return PiConfigPatch(set: ["provider": .string(String(key[..<slash])),
                                   "model": .string(String(key[key.index(after: slash)...]))])
    }

    /// A level, or "" for the preset's default.
    public static func reasoningPatch(_ level: String) -> PiConfigPatch {
        level.isEmpty ? PiConfigPatch(unset: ["reasoning"]) : PiConfigPatch(set: ["reasoning": .string(level)])
    }

    /// A value, or "" for the default (auto).
    public static func followUpPatch(_ value: String) -> PiConfigPatch {
        value.isEmpty ? PiConfigPatch(unset: ["followUpReviews"]) : PiConfigPatch(set: ["followUpReviews": .string(value)])
    }
}

/// One of auto review's decisions, joined with what it was about and how the
/// request ended (`GET /api/safety/reviews`).
public struct AutoReviewRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// When it decided (ISO 8601).
    public var at: String?
    /// "allow", "deny" or "defer" (handed to the person).
    public var outcome: String
    public var surface: String?
    public var command: String?
    public var path: String?
    /// A deny's reason.
    public var reason: String?
    /// After a defer, what the person answered: "approved" or "denied".
    public var then: String?
    public var durationMs: Double?
    public var model: String?
    public var provider: String?
    public var stage: String?
    public var errorCategory: String?

    public init(id: String, at: String? = nil, outcome: String, surface: String? = nil, command: String? = nil,
                path: String? = nil, reason: String? = nil, then: String? = nil, durationMs: Double? = nil,
                model: String? = nil, provider: String? = nil, stage: String? = nil, errorCategory: String? = nil) {
        self.id = id
        self.at = at
        self.outcome = outcome
        self.surface = surface
        self.command = command
        self.path = path
        self.reason = reason
        self.then = then
        self.durationMs = durationMs
        self.model = model
        self.provider = provider
        self.stage = stage
        self.errorCategory = errorCategory
    }

    public enum Kind: Sendable, Equatable { case allowed, denied, asked }
    public var kind: Kind {
        switch outcome {
        case "allow": return .allowed
        case "deny": return .denied
        default: return .asked
        }
    }

    /// "Allowed", "Denied", "Asked you · you approved".
    public var outcomeLabel: String {
        switch kind {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .asked: return then.map { "Asked you · you \($0)" } ?? "Asked you"
        }
    }

    /// What was asked: the command, else the path, else the surface.
    public var subject: String {
        [command, path, surface].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    public var date: Date? {
        guard let at else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: at) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: at)
    }

    /// "4.0 s · claude-haiku-5-5 · 5 min ago"; a defer names its error instead of the model.
    public func detail(now: Date = Date()) -> String {
        var parts: [String] = []
        if let ms = durationMs { parts.append(String(format: "%.1f s", ms / 1000)) }
        if kind == .asked, let e = errorCategory, !e.isEmpty { parts.append(e) } else if let m = model, !m.isEmpty { parts.append(m) }
        if let d = date { parts.append(Self.ago(d, now: now)) }
        return parts.joined(separator: " · ")
    }

    /// "just now", "5 min ago", "3 h ago", "2 d ago".
    public static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min ago" }
        if s < 86400 { return "\(Int((s / 3600).rounded())) h ago" }
        return "\(Int((s / 86400).rounded())) d ago"
    }
}

/// `GET /api/safety/reviews`.
public struct AutoReviewLog: Codable, Sendable, Equatable {
    public var reviews: [AutoReviewRecord]
    /// The review log's path.
    public var log: String?
}

extension PocketPiClient {
    /// Turn auto review on or off for chats (the chat policy's chain; the
    /// package stays installed). The first time on, the server writes its
    /// recommended config and the rules that keep the agent from writing
    /// pi's settings, packages and policies. Returns the chat policy and the
    /// config as they are now.
    @discardableResult
    public func setAutoReview(_ enabled: Bool) async throws -> (policy: PolicyDocument, config: PiConfigDocument) {
        struct R: Decodable { var permissions: JSONValue; var config: PiConfigDocument }
        let r = try await post("/api/safety/auto-review", ["enabled": .bool(enabled)], as: R.self)
        return (PolicyDocument(r.permissions), r.config)
    }

    /// Auto review's latest decisions, newest first.
    public func autoReviews(limit: Int = 20) async throws -> [AutoReviewRecord] {
        try await get("/api/safety/reviews?limit=\(limit)", as: AutoReviewLog.self).reviews
    }

    /// Install the package (a pi CLI job), then turn it on. Returns the
    /// finished job; it's only turned on when the install worked.
    public func installAutoReview() async throws -> PiJob {
        let id = try await startJob(.install(source: AutoReview.package))
        let job = try await waitForJob(id)
        if job.status == "ok" {
            try await setAutoReview(true)
        }
        return job
    }
}
