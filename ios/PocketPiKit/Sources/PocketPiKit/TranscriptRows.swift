import Foundation

/// The transcript as the chat screen draws it: pi's thinking and tool calls
/// between two pieces of text fold into one activity row ("Ran 9 commands ·
/// thought 12s"), like the Claude app, instead of a card per step. The text,
/// your messages and everything else stay rows of their own.
public enum TranscriptRow: Sendable, Equatable, Identifiable {
    /// Anything that isn't an assistant message.
    case item(Transcript.Item)
    /// The text (and images) of an assistant message. On the last piece of a
    /// message, `stopReason` is kept so errors and "Stopped." still show.
    case text(id: String, message: ChatMessage)
    /// Thinking and tool calls in a row. `live` while pi is still at it.
    case activity(id: String, steps: [ActivityStep], live: Bool)

    public var id: String {
        switch self {
        case .item(let i): "i\(i.id)"
        case .text(let id, _): id
        case .activity(let id, _, _): id
        }
    }
}

public enum ActivityStep: Sendable, Equatable {
    case thinking(String, seconds: Int?, live: Bool)
    case tool(id: String, name: String, arguments: JSONValue)
}

extension Transcript {
    /// Ids are made from where a row starts, so they stay put while a reply
    /// streams in and an opened activity row stays open.
    public var rows: [TranscriptRow] {
        var out: [TranscriptRow] = []
        var steps: [ActivityStep] = []
        var activityId: String?

        func flushActivity() {
            if let id = activityId, !steps.isEmpty { out.append(.activity(id: id, steps: steps, live: false)) }
            steps = []
            activityId = nil
        }

        for item in items {
            guard case .assistant(let m, let live) = item.kind else {
                flushActivity()
                out.append(.item(item))
                continue
            }
            var texts: [ContentBlock] = []
            var textStart: Int?

            func flushText(last: Bool) {
                let ending = last && ["error", "aborted", "length"].contains(m.stopReason ?? "")
                guard !texts.isEmpty || ending else { return }
                flushActivity()
                var piece = m
                piece.content = texts
                if !last { piece.stopReason = nil }
                out.append(.text(id: "t\(item.id)-\(textStart ?? m.content.count)", message: piece))
                texts = []
                textStart = nil
            }

            for (i, b) in m.content.enumerated() {
                switch b {
                case .thinking(let t, let secs):
                    flushText(last: false)
                    if activityId == nil { activityId = "a\(item.id)-\(i)" }
                    steps.append(.thinking(t, seconds: secs, live: live && secs == nil))
                case .toolCall(let id, let name, let args):
                    flushText(last: false)
                    if activityId == nil { activityId = "a\(item.id)-\(i)" }
                    steps.append(.tool(id: id, name: name, arguments: args))
                case .text(let t) where t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    continue
                case .other:
                    continue
                case .text, .image:
                    if textStart == nil { textStart = i }
                    texts.append(b)
                }
            }
            flushText(last: true)
        }
        flushActivity()
        // The last activity is live while pi works and nothing came after it.
        if isStreaming, case .activity(let id, let s, _)? = out.last {
            out[out.count - 1] = .activity(id: id, steps: s, live: true)
        }
        return out
    }
}

public enum ActivitySummary {
    /// "Ran 9 commands, read 2 files · thought 12s"; "Thought for 3s" alone.
    public static func text(_ steps: [ActivityStep]) -> String {
        var counts: [(String, Int)] = []
        func add(_ key: String) {
            if let i = counts.firstIndex(where: { $0.0 == key }) { counts[i].1 += 1 } else { counts.append((key, 1)) }
        }
        var seconds = 0
        var thoughts = 0
        for s in steps {
            switch s {
            case .thinking(_, let secs, _):
                thoughts += 1
                seconds += secs ?? 0
            case .tool(_, let name, _):
                switch name {
                case "bash": add("command")
                case "read": add("read")
                case "edit", "write": add("edit")
                case "grep", "find", "ls": add("search")
                case "web_fetch", "fetch", "web_search": add("web")
                default: add("tool")
                }
            }
        }
        var parts = counts.map { key, n -> String in
            switch key {
            case "command": "ran \(n) command" + (n == 1 ? "" : "s")
            case "read": "read \(n) file" + (n == 1 ? "" : "s")
            case "edit": "edited \(n) file" + (n == 1 ? "" : "s")
            case "search": "searched \(n) time" + (n == 1 ? "" : "s")
            case "web": "looked up \(n) page" + (n == 1 ? "" : "s")
            default: "used \(n) tool" + (n == 1 ? "" : "s")
            }
        }
        let thought = seconds > 0 ? "thought for \(seconds)s" : "thought"
        var line: String
        if parts.isEmpty {
            line = thoughts > 0 ? thought : "worked"
        } else {
            line = parts.removeFirst()
            if !parts.isEmpty { line += ", " + parts.joined(separator: ", ") }
            if thoughts > 0 { line += " · " + thought }
        }
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
