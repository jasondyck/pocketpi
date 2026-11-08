import Foundation

/// What the composer's text asks for. `!cmd` runs a shell command whose
/// output goes into pi's context with the next prompt; `!!cmd` runs one that
/// stays out of it. Anything else is a prompt.
public enum ComposerIntent: Sendable, Equatable {
    case prompt(String)
    case bash(command: String, excludeFromContext: Bool)

    public init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("!!") {
            let c = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
            self = c.isEmpty ? .prompt(text) : .bash(command: c, excludeFromContext: true)
        } else if text.hasPrefix("!") {
            let c = text.dropFirst().trimmingCharacters(in: .whitespaces)
            self = c.isEmpty ? .prompt(text) : .bash(command: c, excludeFromContext: false)
        } else {
            self = .prompt(text)
        }
    }

    public var isBash: Bool { if case .bash = self { return true }; return false }

    /// A line under the composer saying what sending will do, or nil for
    /// an ordinary prompt.
    public func hint(streaming: Bool) -> String? {
        guard case .bash(_, let excluded) = self else { return nil }
        if streaming { return "Shell commands run once pi has finished" }
        return excluded ? "Shell · output kept out of pi's context" : "Shell · output goes to pi with your next message"
    }
}

/// How a message sent while pi works is delivered.
public enum Delivery: Sendable, Equatable {
    /// After the current tool calls, before pi's next model call (the default).
    case steer
    /// Only once pi has finished the whole turn (`follow_up`).
    case followUp
}

/// A shell command run from the composer (pi's `bash` RPC) or a
/// `bashExecution` message from the session.
public struct BashRun: Sendable, Equatable {
    public var command: String
    public var output: String
    public var exitCode: Int?
    public var cancelled: Bool
    public var truncated: Bool
    public var fullOutputPath: String?
    public var excludeFromContext: Bool
    /// Still going: output streams in from bash_execution_update.
    public var running: Bool

    public init(command: String, output: String = "", exitCode: Int? = nil, cancelled: Bool = false,
                truncated: Bool = false, fullOutputPath: String? = nil, excludeFromContext: Bool = false,
                running: Bool = false) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.cancelled = cancelled
        self.truncated = truncated
        self.fullOutputPath = fullOutputPath
        self.excludeFromContext = excludeFromContext
        self.running = running
    }

    /// From a `bashExecution` message.
    public init(message v: JSONValue) {
        self.init(command: v["command"]?.string ?? "", output: v["output"]?.string ?? "")
        finish(v)
        excludeFromContext = v["excludeFromContext"]?.bool ?? false
    }

    /// Take the final result (the `bash` response, or a message): its
    /// output replaces what streamed, as it's what pi keeps.
    mutating func finish(_ v: JSONValue) {
        if let o = v["output"]?.string { output = o }
        exitCode = v["exitCode"]?.int
        cancelled = v["cancelled"]?.bool ?? false
        truncated = v["truncated"]?.bool ?? false
        fullOutputPath = v["fullOutputPath"]?.string
        running = false
    }

    public var isError: Bool { !running && !cancelled && exitCode != nil && exitCode != 0 }

    /// "exit 2", "cancelled", "not in context"; empty for a plain success.
    public var status: String {
        var parts: [String] = []
        if cancelled { parts.append("cancelled") } else if let c = exitCode, c != 0 { parts.append("exit \(c)") }
        if excludeFromContext { parts.append("not in context") }
        return parts.joined(separator: " · ")
    }
}

/// pi waiting to try the model again after a transient error
/// (auto_retry_start), until auto_retry_end.
public struct RetryState: Sendable, Equatable {
    public var attempt: Int
    public var maxAttempts: Int
    public var delayMs: Int
    public var errorMessage: String
    /// When the event arrived; the retry is due `delayMs` later.
    public var since: Date

    public init(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String, since: Date) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.delayMs = delayMs
        self.errorMessage = errorMessage
        self.since = since
    }

    init(_ ev: JSONValue, now: Date) {
        self.init(attempt: ev["attempt"]?.int ?? 1, maxAttempts: ev["maxAttempts"]?.int ?? 0,
                  delayMs: ev["delayMs"]?.int ?? 0, errorMessage: ev["errorMessage"]?.string ?? "", since: now)
    }

    public var due: Date { since.addingTimeInterval(Double(delayMs) / 1000) }

    /// Whole seconds until the retry (0 once it's under way).
    public func secondsLeft(now: Date = Date()) -> Int {
        max(0, Int(due.timeIntervalSince(now).rounded(.up)))
    }

    /// "Retrying in 3s · attempt 1 of 3"; "Retrying · attempt 1 of 3" once due.
    public func line(now: Date = Date()) -> String {
        let n = secondsLeft(now: now)
        let of = maxAttempts > 0 ? " of \(maxAttempts)" : ""
        return (n > 0 ? "Retrying in \(n)s" : "Retrying") + " · attempt \(attempt)\(of)"
    }
}
