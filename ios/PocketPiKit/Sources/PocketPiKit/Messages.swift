import Foundation

/// One block of a message's content.
public enum ContentBlock: Sendable, Equatable {
    case text(String)
    /// `seconds` is measured on this device while it streams; history has none.
    case thinking(String, seconds: Int?)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case image(base64: String, mimeType: String)
    case other(JSONValue)

    public init(_ v: JSONValue) {
        switch v["type"]?.string {
        case "text": self = .text(v["text"]?.string ?? "")
        case "thinking": self = .thinking(v["thinking"]?.string ?? "", seconds: nil)
        case "toolCall":
            self = .toolCall(id: v["id"]?.string ?? "", name: v["name"]?.string ?? "tool",
                             arguments: v["arguments"] ?? [:])
        case "image": self = .image(base64: v["data"]?.string ?? "", mimeType: v["mimeType"]?.string ?? "image/png")
        default: self = .other(v)
        }
    }

    public var text: String? { if case .text(let t) = self { return t }; return nil }
}

/// A message from pi's session, any role. Unknown roles are kept (as `.other`)
/// so a newer pi doesn't break the transcript.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case user, assistant, toolResult, system
        case compactionSummary, branchSummary, bashExecution, custom
        case other(String)

        init(_ s: String?) {
            switch s {
            case "user": self = .user
            case "assistant": self = .assistant
            case "toolResult": self = .toolResult
            case "system": self = .system
            case "compactionSummary": self = .compactionSummary
            case "branchSummary": self = .branchSummary
            case "bashExecution": self = .bashExecution
            case "custom": self = .custom
            default: self = .other(s ?? "")
            }
        }
    }

    public var role: Role
    public var content: [ContentBlock]
    /// `stop`, `toolUse`, `error`, `aborted`, `length`; nil while streaming.
    public var stopReason: String?
    public var errorMessage: String?
    /// The whole message as pi sent it, for the fields only some roles have
    /// (toolCallId, isError, summary, command, output, exitCode, display...).
    public var raw: JSONValue

    public init(_ v: JSONValue) {
        raw = v
        role = Role(v["role"]?.string)
        if let s = v["content"]?.string { content = [.text(s)] }
        else { content = (v["content"]?.array ?? []).map(ContentBlock.init) }
        stopReason = v["stopReason"]?.string
        errorMessage = v["errorMessage"]?.string
    }

    public init(role: Role, content: [ContentBlock], stopReason: String? = nil) {
        self.role = role
        self.content = content
        self.stopReason = stopReason
        self.raw = [:]
    }

    /// All text blocks joined, like textOf() in web/app.js.
    public var plainText: String {
        content.compactMap(\.text).joined(separator: "\n")
    }

    public var toolCallId: String? { raw["toolCallId"]?.string }
    public var isError: Bool { raw["isError"]?.bool ?? false }
}

/// What a tool call came back with.
public struct ToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    public var durationMs: Int?
    public var details: JSONValue?

    public init(text: String, isError: Bool, durationMs: Int? = nil, details: JSONValue? = nil) {
        self.text = text
        self.isError = isError
        self.durationMs = durationMs
        self.details = details
    }

    /// From a toolResult message, or from the `result`/`partialResult` of a
    /// tool_execution event (both are `{content: [...], details}`).
    public init(_ v: JSONValue, isError: Bool, durationMs: Int? = nil) {
        let content = v["content"]
        if let s = content?.string { text = s }
        else {
            text = (content?.array ?? []).compactMap { b in
                b["type"]?.string == "text" ? b["text"]?.string : nil
            }.joined(separator: "\n")
        }
        self.isError = isError
        self.durationMs = durationMs
        details = v["details"]
    }

    /// The edit tool's unified diff, when it sent one.
    public var diff: String? { details?["diff"]?.string }
}

public enum ToolSummary {
    /// One line saying what a tool call does: the command, the file, the
    /// pattern. Same rules as toolArgSummary() in web/app.js.
    public static func summary(name: String, arguments a: JSONValue, home: String?) -> String {
        guard case .object(let o) = a else { return "" }
        if name == "bash" { return o["command"]?.string ?? "" }
        if let p = o["path"]?.string ?? o["file_path"]?.string ?? o["filePath"]?.string {
            let pat = o["pattern"]?.string.map { "  \($0)" } ?? ""
            return Format.tilde(p, home: home) + pat
        }
        for k in ["pattern", "query", "url"] { if let s = o[k]?.string { return s } }
        return o.isEmpty ? "" : a.compactText
    }
}
