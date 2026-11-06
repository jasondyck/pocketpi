import Foundation

/// A request from a pi extension for the user (extension_ui_request).
public struct ExtensionRequest: Sendable, Equatable, Identifiable {
    public enum Method: String, Sendable { case confirm, select, input, editor }
    public var id: String
    public var method: Method
    public var title: String
    public var message: String?
    public var options: [String]
    public var prefill: String?
    public var placeholder: String?
}

/// Something the transcript can't do itself, for whoever owns it to act on.
public enum TranscriptEffect: Sendable, Equatable {
    /// pocketpi (re)connected or dropped events: fetch get_messages + get_state.
    case reloadSnapshot
    /// pi settled after a turn: refresh stats, the chat list, the session file.
    case turnFinished
    /// The pi process exited; its key is dead. stderr's tail, if any.
    case exited(stderr: [String])
    case extensionRequest(ExtensionRequest)
    /// Put this in the composer (extension set_editor_text).
    case setComposer(String)
    /// Something went wrong that the person should see now (an alert).
    case problem(String)
    case thinkingLevelChanged(String)
    case sessionNameChanged(String?)
    /// Compaction finished; stats are stale.
    case statsStale
}

/// The chat as it is on screen, built from pi's messages and kept current from
/// its events. A port of the event handling in web/app.js (onEvent,
/// onMessageStart/Update/End) with no UI in it, so it is tested on Linux.
public struct Transcript: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case user(ChatMessage)
        /// `live` while it streams; the final message replaces it on message_end.
        case assistant(ChatMessage, live: Bool)
        case compaction(summary: String, tokensBefore: Int?)
        case branchSummary(String)
        case bash(command: String, output: String, exitCode: Int?)
        case custom(String)
        /// A line in the chat from pocketpi itself, not pi ("Context compacted").
        case note(String)
        case error(String)
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public let id: Int
        public var kind: Kind
    }

    public private(set) var items: [Item] = []
    /// Results by tool call id; a tool card looks itself up here.
    public private(set) var toolResults: [String: ToolResult] = [:]
    /// Output so far of tools still running (tool_execution_update).
    public private(set) var partialResults: [String: ToolResult] = [:]
    public private(set) var runningTools: Set<String> = []
    public private(set) var isStreaming = false
    /// What pi is doing right now, for the "working" line.
    public private(set) var activity = "Working"
    public private(set) var steering: [String] = []
    public private(set) var followUp: [String] = []

    private var nextId = 0
    private var liveIndex: Int?
    private var thinkingStarted: [Int: Date] = [:]
    private var thinkingSeconds: [Int: Int] = [:]

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    /// The first user prompt's first line, for a chat that has no name yet.
    public var firstPrompt: String? {
        for item in items {
            if case .user(let m) = item.kind {
                let line = m.plainText.split(separator: "\n", omittingEmptySubsequences: true).first
                return line.map { String($0.prefix(80)) }
            }
        }
        return nil
    }

    // MARK: - snapshot

    /// Replace everything with pi's `get_messages`.
    public mutating func load(messages: [JSONValue], isStreaming: Bool) {
        items = []
        toolResults = [:]
        partialResults = [:]
        runningTools = []
        liveIndex = nil
        thinkingStarted = [:]
        thinkingSeconds = [:]
        for v in messages { append(ChatMessage(v)) }
        setStreaming(isStreaming)
    }

    private mutating func append(_ m: ChatMessage) {
        switch m.role {
        case .user: push(.user(m))
        case .assistant: push(.assistant(m, live: false))
        case .toolResult:
            if let id = m.toolCallId {
                toolResults[id] = ToolResult(m.raw, isError: m.isError)
            }
        case .compactionSummary:
            push(.compaction(summary: m.raw["summary"]?.string ?? "", tokensBefore: m.raw["tokensBefore"]?.int))
        case .branchSummary: push(.branchSummary(m.raw["summary"]?.string ?? ""))
        case .bashExecution:
            push(.bash(command: m.raw["command"]?.string ?? "", output: m.raw["output"]?.string ?? "",
                       exitCode: m.raw["exitCode"]?.int))
        case .custom:
            if m.raw["display"]?.bool == true { push(.custom(m.plainText)) }
        case .system, .other: break
        }
    }

    private mutating func push(_ kind: Kind) {
        items.append(Item(id: nextId, kind: kind))
        nextId += 1
    }

    private mutating func setStreaming(_ on: Bool) {
        isStreaming = on
        if on { activity = "Working" }
    }

    // MARK: - events

    /// Apply one event from /api/s/{key}/events.
    @discardableResult
    public mutating func apply(_ ev: JSONValue, now: Date = Date()) -> [TranscriptEffect] {
        switch ev["type"]?.string ?? "" {
        case "pocketpi_hello", "pocketpi_resync":
            return [.reloadSnapshot]
        case "pocketpi_exit":
            setStreaming(false)
            liveIndex = nil
            return [.exited(stderr: (ev["stderr"]?.array ?? []).compactMap(\.string))]
        case "agent_start":
            setStreaming(true)
        case "agent_settled":
            setStreaming(false)
            runningTools = []
            return [.turnFinished]
        case "message_start":
            if let m = ev["message"] { messageStart(ChatMessage(m)) }
        case "message_update":
            messageUpdate(ev, now: now)
        case "message_end":
            if let m = ev["message"] { messageEnd(ChatMessage(m)) }
        case "tool_execution_start":
            if let id = ev["toolCallId"]?.string { runningTools.insert(id) }
            activity = "Running \(ev["toolName"]?.string ?? "tool")"
        case "tool_execution_update":
            if let id = ev["toolCallId"]?.string, let p = ev["partialResult"] {
                partialResults[id] = ToolResult(p, isError: false)
            }
        case "tool_execution_end":
            if let id = ev["toolCallId"]?.string {
                runningTools.remove(id)
                partialResults[id] = nil
                toolResults[id] = ToolResult(ev["result"] ?? [:], isError: ev["isError"]?.bool ?? false,
                                             durationMs: ev["durationMs"]?.int)
            }
            activity = "Working"
        case "queue_update":
            steering = (ev["steering"]?.array ?? []).compactMap(\.string)
            followUp = (ev["followUp"]?.array ?? []).compactMap(\.string)
        case "compaction_start":
            activity = "Compacting context"
        case "compaction_end":
            if let r = ev["result"], !r.isNull {
                push(.note("Context compacted · \(Format.tokens(r["tokensBefore"]?.int)) → \(Format.tokens(r["estimatedTokensAfter"]?.int))"))
                return [.statsStale]
            }
            if let e = ev["errorMessage"]?.string { return [.problem("Compaction failed: \(e)")] }
        case "auto_retry_start":
            let n = ev["attempt"]?.int.map(String.init) ?? "?"
            let of = ev["maxAttempts"]?.int.map(String.init) ?? "?"
            activity = "Retrying \(n)/\(of) · \(ev["errorMessage"]?.string ?? "")"
        case "auto_retry_end":
            if ev["success"]?.bool != true { push(.error(ev["finalError"]?.string ?? "Retries failed")) }
        case "thinking_level_changed":
            if let l = ev["level"]?.string { return [.thinkingLevelChanged(l)] }
        case "session_info_changed":
            return [.sessionNameChanged(ev["name"]?.string)]
        case "extension_ui_request":
            return extensionRequest(ev)
        case "extension_error":
            return [.problem("Extension error: \(ev["error"]?.string ?? "")")]
        default:
            break
        }
        return []
    }

    private mutating func messageStart(_ m: ChatMessage) {
        switch m.role {
        case .assistant:
            beginLive()
        case .user:
            push(.user(m))
        default:
            break // tool results and the rest arrive complete on message_end
        }
    }

    private mutating func beginLive() {
        push(.assistant(ChatMessage(role: .assistant, content: []), live: true))
        liveIndex = items.count - 1
        thinkingStarted = [:]
        thinkingSeconds = [:]
    }

    private mutating func messageUpdate(_ ev: JSONValue, now: Date) {
        guard let e = ev["assistantMessageEvent"], let type = e["type"]?.string else { return }
        let i = e["contentIndex"]?.int ?? 0
        if liveIndex == nil { beginLive() }
        guard let li = liveIndex, case .assistant(var msg, _) = items[li].kind else { return }
        while msg.content.count <= i { msg.content.append(.text("")) }
        let delta = e["delta"]?.string ?? ""
        switch type {
        case "text_start": msg.content[i] = .text("")
        case "text_delta": msg.content[i] = .text((msg.content[i].text ?? "") + delta)
        case "text_end": msg.content[i] = .text(e["content"]?.string ?? msg.content[i].text ?? "")
        case "thinking_start":
            thinkingStarted[i] = now
            msg.content[i] = .thinking("", seconds: nil)
        case "thinking_delta":
            if thinkingStarted[i] == nil { thinkingStarted[i] = now }
            var t = ""
            if case .thinking(let s, _) = msg.content[i] { t = s }
            msg.content[i] = .thinking(t + delta, seconds: nil)
        case "thinking_end":
            var t = ""
            if case .thinking(let s, _) = msg.content[i] { t = s }
            let secs = thinkingStarted[i].map { max(1, Int(now.timeIntervalSince($0).rounded())) }
            thinkingSeconds[i] = secs
            msg.content[i] = .thinking(e["content"]?.string ?? t, seconds: secs)
        case "toolcall_start":
            msg.content[i] = .toolCall(id: e["id"]?.string ?? "", name: e["toolName"]?.string ?? "tool", arguments: [:])
        case "toolcall_end":
            if let tc = e["toolCall"] { msg.content[i] = ContentBlock(tc) }
        default:
            return
        }
        items[li].kind = .assistant(msg, live: true)
        activity = type.hasPrefix("thinking") ? "Thinking" : type.hasPrefix("toolcall") ? "Preparing tool call" : "Writing"
    }

    private mutating func messageEnd(_ m: ChatMessage) {
        switch m.role {
        case .assistant:
            var final = m
            for (i, b) in final.content.enumerated() {
                if case .thinking(let t, _) = b, let s = thinkingSeconds[i] { final.content[i] = .thinking(t, seconds: s) }
            }
            if let li = liveIndex { items[li].kind = .assistant(final, live: false) }
            else { push(.assistant(final, live: false)) }
            liveIndex = nil
        case .user, .system:
            break
        default:
            append(m)
        }
    }

    private mutating func extensionRequest(_ ev: JSONValue) -> [TranscriptEffect] {
        let method = ev["method"]?.string ?? ""
        switch method {
        case "notify":
            // Errors are alerts; anything else is a line in the transcript,
            // like the system lines in Messages.
            let msg = ev["message"]?.string ?? ""
            if ev["notifyType"]?.string == "error" { return [.problem(msg)] }
            if !msg.isEmpty { push(.note(msg)) }
            return []
        case "set_editor_text":
            return [.setComposer(ev["text"]?.string ?? "")]
        default:
            guard let m = ExtensionRequest.Method(rawValue: method), let id = ev["id"]?.string else { return [] }
            return [.extensionRequest(ExtensionRequest(
                id: id, method: m, title: ev["title"]?.string ?? "pi needs input",
                message: ev["message"]?.string, options: (ev["options"]?.array ?? []).compactMap(\.string),
                prefill: ev["prefill"]?.string, placeholder: ev["placeholder"]?.string))]
        }
    }
}
