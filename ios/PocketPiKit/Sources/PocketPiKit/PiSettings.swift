import Foundation

// pi's global settings (`~/.pi/agent/settings.json`) as the Settings page
// edits them: the keys that matter to a pi running under pocketpi, with
// their types and pi's defaults (pi's docs/settings.md), how to read them
// from the document, and the patches that change them. TUI-only keys
// (theme, terminal.*, editor padding, …) are left out on purpose; they stay
// in the file untouched because every write is a patch.
//
// These are global: they also change what terminal pi and workflow stages do.
// The web twin is web/manage-settings.js (same keys, same defaults).

/// pi's thinking levels, lowest first.
public enum PiThinking {
    public static let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    /// pi's `defaultThinkingLevel` when unset.
    public static let defaultLevel = "medium"
}

/// One entry of `enabledModels`: a model pattern ("anthropic/claude-*",
/// "gpt-5.5", an exact "provider/id") with an optional `:<thinking>` suffix.
/// A colon is a suffix only when what follows is a thinking level, so model
/// ids with colons ("ollama/qwen3:8b") stay whole.
public struct ModelPattern: Hashable, Sendable, Identifiable {
    public var pattern: String
    public var thinking: String?
    public var id: String { raw }

    public init(pattern: String, thinking: String? = nil) {
        self.pattern = pattern
        self.thinking = thinking.flatMap { PiThinking.levels.contains($0) ? $0 : nil }
    }

    public init(_ raw: String) {
        let raw = raw.trimmingCharacters(in: .whitespaces)
        if let i = raw.lastIndex(of: ":") {
            let suffix = String(raw[raw.index(after: i)...]).lowercased()
            if PiThinking.levels.contains(suffix), i > raw.startIndex {
                self.init(pattern: String(raw[..<i]), thinking: suffix)
                return
            }
        }
        self.init(pattern: raw)
    }

    /// As pi stores it.
    public var raw: String { thinking.map { "\(pattern):\($0)" } ?? pattern }
    /// Matches more than one model (a glob).
    public var isGlob: Bool { pattern.contains("*") }

    /// pi's matching: the pattern against "provider/id" or the bare id.
    public func matches(_ m: ModelInfo) -> Bool {
        ModelInfo.matches(pattern, m.key) || ModelInfo.matches(pattern, m.id)
    }
}

/// `enabledModels`: the favourite models pi starts with and cycles through.
public enum EnabledModels {
    public static func parse(_ v: JSONValue?) -> [ModelPattern] {
        (v?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }.map(ModelPattern.init)
    }

    /// The models the list picks, in its order, each once.
    public static func resolve(_ list: [ModelPattern], in models: [ModelInfo]) -> [ModelInfo] {
        var out: [ModelInfo] = []
        for p in list {
            for m in models where !out.contains(m) && p.matches(m) { out.append(m) }
        }
        return out
    }

    /// Add a model (as "provider/id") or a typed pattern; nothing if it's already there.
    public static func adding(_ entry: ModelPattern, to list: [ModelPattern]) -> [ModelPattern] {
        guard !entry.pattern.isEmpty, !list.contains(where: { $0.pattern == entry.pattern }) else { return list }
        return list + [entry]
    }

    /// Move one entry up (-1) or down (+1); out-of-range moves change nothing.
    public static func moving(_ list: [ModelPattern], at index: Int, by offset: Int) -> [ModelPattern] {
        let to = index + offset
        guard list.indices.contains(index), list.indices.contains(to) else { return list }
        var l = list
        l.swapAt(index, to)
        return l
    }

    /// The whole list as a patch; an empty list removes the key (pi then
    /// offers every available model).
    public static func patch(_ list: [ModelPattern]) -> PiConfigPatch {
        list.isEmpty ? PiConfigPatch(unset: ["enabledModels"])
            : PiConfigPatch(set: ["enabledModels": .array(list.map { .string($0.raw) })])
    }
}

/// The groups the page shows, in order.
public enum PiSettingGroup: String, CaseIterable, Sendable {
    case models, queue, compaction, retry, images, display

    public var title: String {
        switch self {
        case .models: "Models"
        case .queue: "Queued messages"
        case .compaction: "Compaction"
        case .retry: "Retry"
        case .images: "Images"
        case .display: "Display"
        }
    }
}

/// A plain setting with a typed control: a switch, a choice or a number.
/// The default model, `enabledModels`, `modelThinkingLevels` and
/// `compaction.modelOverrides` have their own editors.
public struct PiSettingSpec: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case toggle(default: Bool)
        /// `labels` are what to show for each value, same order.
        case choice([String], labels: [String], default: String)
        case number(default: Int, min: Int, max: Int?)
    }

    /// Dotted path in settings.json.
    public let key: String
    public let group: PiSettingGroup
    public let title: String
    public let detail: String
    public let kind: Kind
    public var id: String { key }

    public var defaultValue: JSONValue {
        switch kind {
        case .toggle(let d): .bool(d)
        case .choice(_, _, let d): .string(d)
        case .number(let d, _, _): .number(Double(d))
        }
    }
}

public enum PiSettings {
    static let queueModes = ["one-at-a-time", "all"]
    static let queueLabels = ["One at a time", "All at once"]

    /// Every plain setting the page offers, in page order.
    public static let specs: [PiSettingSpec] = [
        .init(key: "defaultThinkingLevel", group: .models, title: "Default thinking",
              detail: "Thinking level for new chats (clamped to what the model supports).",
              kind: .choice(PiThinking.levels, labels: PiThinking.levels, default: PiThinking.defaultLevel)),
        .init(key: "steeringMode", group: .queue, title: "Steering messages",
              detail: "Messages sent while pi works: delivered one per turn, or all together.",
              kind: .choice(queueModes, labels: queueLabels, default: "one-at-a-time")),
        .init(key: "followUpMode", group: .queue, title: "Follow-up messages",
              detail: "Messages queued for after the turn: one per turn, or all together.",
              kind: .choice(queueModes, labels: queueLabels, default: "one-at-a-time")),
        .init(key: "compaction.enabled", group: .compaction, title: "Auto-compact",
              detail: "Summarise older messages when the context fills up.", kind: .toggle(default: true)),
        .init(key: "compaction.reserveTokens", group: .compaction, title: "Reserve tokens",
              detail: "Compact when fewer free context tokens than this are left.",
              kind: .number(default: 16384, min: 0, max: nil)),
        .init(key: "compaction.keepRecentTokens", group: .compaction, title: "Keep recent tokens",
              detail: "Recent tokens kept word for word, not summarised.",
              kind: .number(default: 20000, min: 0, max: nil)),
        .init(key: "retry.enabled", group: .retry, title: "Auto-retry",
              detail: "Retry transient provider errors (overloaded, rate limits) with backoff.", kind: .toggle(default: true)),
        .init(key: "retry.maxRetries", group: .retry, title: "Max retries",
              detail: "Attempts before giving up.", kind: .number(default: 3, min: 0, max: 100)),
        .init(key: "images.autoResize", group: .images, title: "Resize images",
              detail: "Shrink images to at most 2000×2000 before sending them.", kind: .toggle(default: true)),
        .init(key: "images.blockImages", group: .images, title: "Block images",
              detail: "Never send images to models.", kind: .toggle(default: false)),
        .init(key: "hideThinkingBlock", group: .display, title: "Hide thinking",
              detail: "Leave thinking blocks out of the transcript.", kind: .toggle(default: false)),
    ]

    public static func spec(_ key: String) -> PiSettingSpec? { specs.first { $0.key == key } }
    public static func specs(in group: PiSettingGroup) -> [PiSettingSpec] { specs.filter { $0.group == group } }

    // MARK: reading

    /// The value at a dotted path (spec keys have no escaped dots).
    public static func value(_ data: JSONValue, at key: String) -> JSONValue? {
        var v: JSONValue? = data
        for part in key.split(separator: ".") { v = v?[String(part)] }
        guard let v, !v.isNull else { return nil }
        return v
    }

    /// The value pi uses: the file's when it has a valid one, else pi's default.
    public static func effective(_ data: JSONValue, _ spec: PiSettingSpec) -> JSONValue {
        guard let v = value(data, at: spec.key) else { return spec.defaultValue }
        switch spec.kind {
        case .toggle: return v.bool.map(JSONValue.bool) ?? spec.defaultValue
        case .choice(let values, _, _):
            guard let s = v.string, values.contains(s) else { return spec.defaultValue }
            return .string(s)
        case .number: return v.double.map(JSONValue.number) ?? spec.defaultValue
        }
    }

    public static func bool(_ data: JSONValue, _ spec: PiSettingSpec) -> Bool { effective(data, spec).bool ?? false }
    public static func string(_ data: JSONValue, _ spec: PiSettingSpec) -> String { effective(data, spec).string ?? "" }
    public static func int(_ data: JSONValue, _ spec: PiSettingSpec) -> Int { effective(data, spec).int ?? 0 }
    /// Whether the file sets it (otherwise pi's default applies).
    public static func isSet(_ data: JSONValue, _ spec: PiSettingSpec) -> Bool { value(data, at: spec.key) != nil }

    /// "provider/id" of the default model, nil when pi picks one itself.
    public static func defaultModel(_ data: JSONValue) -> String? {
        guard let m = data["defaultModel"]?.string, !m.isEmpty else { return nil }
        if let p = data["defaultProvider"]?.string, !p.isEmpty { return "\(p)/\(m)" }
        return m
    }

    /// `modelThinkingLevels`, sorted by model.
    public static func modelThinking(_ data: JSONValue) -> [(model: String, level: String)] {
        (data["modelThinkingLevels"]?.object ?? [:]).compactMap { k, v in v.string.map { (k, $0) } }
            .sorted { $0.model < $1.model }
    }

    /// `compaction.modelOverrides` as "model: reserve 1000 · keep 2000" lines.
    public static func compactionOverrides(_ data: JSONValue) -> [(model: String, summary: String)] {
        (data["compaction"]?["modelOverrides"]?.object ?? [:]).map { k, v in
            var parts: [String] = []
            if let r = v["reserveTokens"]?.int { parts.append("reserve \(r)") }
            if let r = v["keepRecentTokens"]?.int { parts.append("keep \(r)") }
            if let e = v["enabled"]?.bool { parts.append(e ? "on" : "off") }
            return (k, parts.isEmpty ? "custom" : parts.joined(separator: " · "))
        }.sorted { $0.model < $1.model }
    }

    // MARK: writing

    /// Set a plain setting; nil goes back to pi's default (removes the key).
    public static func patch(_ spec: PiSettingSpec, _ value: JSONValue?) -> PiConfigPatch {
        guard let value else { return PiConfigPatch(unset: [spec.key]) }
        return PiConfigPatch(set: [spec.key: value])
    }

    public enum NumberProblem: Error, Equatable { case notANumber, tooSmall(Int), tooBig(Int) }

    /// A number field's text: nil for empty (pi's default), else a whole
    /// number within the spec's range.
    public static func parseNumber(_ text: String, _ spec: PiSettingSpec) -> Result<Int?, NumberProblem> {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ",", with: "")
        if t.isEmpty { return .success(nil) }
        guard let n = Int(t) else { return .failure(.notANumber) }
        if case .number(_, let lo, let hi) = spec.kind {
            if n < lo { return .failure(.tooSmall(lo)) }
            if let hi, n > hi { return .failure(.tooBig(hi)) }
        }
        return .success(n)
    }

    /// The default model for new chats, or nil to let pi choose.
    public static func defaultModelPatch(_ model: ModelInfo?) -> PiConfigPatch {
        guard let model else { return PiConfigPatch(unset: ["defaultProvider", "defaultModel"]) }
        return PiConfigPatch(set: ["defaultProvider": .string(model.provider), "defaultModel": .string(model.id)])
    }

    /// One model's startup thinking level; nil removes it.
    public static func modelThinkingPatch(_ model: String, _ level: String?) -> PiConfigPatch {
        let path = PiConfigPatch.path("modelThinkingLevels", model)
        guard let level else { return PiConfigPatch(unset: [path]) }
        return PiConfigPatch(set: [path: .string(level)])
    }
}

extension PocketPiClient {
    /// The models pi can use (`get_available_models`), sorted by provider and
    /// name. pi's RPC is the only source, so this asks a running chat's pi;
    /// with none running it starts one in the home folder, asks, and closes
    /// it (a chat with no messages leaves no session file).
    public func availableModels() async throws -> [ModelInfo] {
        func ask(_ key: String) async throws -> [ModelInfo] {
            try await command(key: key, ["type": "get_available_models"])["models"]?.array?
                .compactMap(ModelInfo.init)
                .sorted { ($0.provider, $0.label) < ($1.provider, $1.label) } ?? []
        }
        let live = (try? await piStatus())?.live ?? []
        if let chat = live.first(where: { $0.kind == "chat" && !$0.stale }) ?? live.first(where: { $0.kind != "stage" }),
           let models = try? await ask(chat.key) {
            return models
        }
        let temp = try await newChat(cwd: "~")
        do {
            let models = try await ask(temp.key)
            try? await close(key: temp.key)
            return models
        } catch {
            try? await close(key: temp.key)
            throw error
        }
    }
}
