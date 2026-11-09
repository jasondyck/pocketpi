import Foundation
import Observation

// Subagent runs, read from pi-subagents' own lifecycle files (`GET
// /api/subagents`, src/subagents.rs). The server projects each run's
// `status.json`: a run's steps, each step's current tool, recent output,
// tokens and child session file. The web twin is web/agents.js; the screen is
// SubagentsView.swift.
//
// A run is one `subagent` tool call: `single`, `chain`, `parallel` or a
// `workflow` whose children are its steps. `toolCallId` matches pi's tool call
// in the transcript; a step's `sessionFile` is a pi session that can be opened
// as a chat while the child is still working.

/// One child of a run (a workflow's child, a chain's step, a single agent).
public struct SubagentStep: Sendable, Equatable, Identifiable {
    public var index: Int
    public var agent: String?
    public var label: String?
    public var status: String
    public var active: Bool
    /// pi-subagents' own hint ("active_long_running").
    public var activity: String?
    /// Milliseconds since 1970.
    public var startedAt: UInt64?
    public var endedAt: UInt64?
    public var durationMs: UInt64?
    public var tokens: Int?
    public var cost: Double?
    public var model: String?
    public var provider: String?
    /// The child's pi session file: open it as a chat to watch it work.
    public var sessionFile: String?
    public var runId: String?
    /// The last tool calls, e.g. "read src/main.rs".
    public var recentTools: [String]
    /// The last lines the child printed.
    public var recentOutput: [String]
    public var turnCount: Int?
    public var toolCount: Int?

    public var id: Int { index }

    public init(_ v: JSONValue) {
        index = v["index"]?.int ?? 0
        agent = v["agent"]?.string
        label = v["label"]?.string
        status = v["status"]?.string ?? "pending"
        active = v["active"]?.bool ?? false
        activity = v["activity"]?.string
        startedAt = v["startedAt"]?.int.map(UInt64.init)
        endedAt = v["endedAt"]?.int.map(UInt64.init)
        durationMs = v["durationMs"]?.int.map(UInt64.init)
        if let t = v["tokens"] {
            if let total = t["total"]?.int ?? t.int {
                tokens = total
            } else {
                let n = (t["input"]?.int ?? 0) + (t["output"]?.int ?? 0)
                tokens = n > 0 ? n : nil
            }
        }
        cost = v["cost"]?.double
        model = v["model"]?.string
        provider = v["provider"]?.string
        sessionFile = v["sessionFile"]?.string
        runId = v["runId"]?.string
        recentTools = (v["recentTools"]?.array ?? []).compactMap(\.string)
        recentOutput = (v["recentOutput"]?.array ?? []).compactMap(\.string)
        turnCount = v["turnCount"]?.int
        toolCount = v["toolCount"]?.int
    }

    /// What it's doing: the latest tool, else its last output line.
    public var line: String {
        if let t = recentTools.last, !t.isEmpty { return t }
        return recentOutput.last ?? ""
    }

    /// "12s", "1m 4s": measured once it ends, ticking while it runs.
    public func elapsed(now: Date = Date()) -> String? {
        if let durationMs { return Format.duration(Double(durationMs) / 1000) }
        guard let startedAt, active else { return nil }
        return Format.duration(max(0, now.timeIntervalSince1970 - Double(startedAt) / 1000))
    }
}

/// One `subagent` tool call's run.
public struct SubagentRun: Sendable, Equatable, Identifiable {
    public var id: String
    /// pi's tool call id, to match the run with the chat's tool card.
    public var toolCallId: String?
    /// "single", "chain", "parallel" or "workflow".
    public var mode: String
    public var state: String
    public var active: Bool
    /// The launching chat's session file.
    public var sessionId: String?
    public var cwd: String?
    public var startedAt: UInt64?
    public var endedAt: UInt64?
    public var lastUpdate: UInt64?
    public var durationMs: UInt64?
    public var tokens: Int?
    public var cost: Double?
    public var steps: [SubagentStep]
    public var parentWorkflowRunId: String?
    public var workflowKey: String?

    public init(_ v: JSONValue) {
        id = v["id"]?.string ?? v["runId"]?.string ?? ""
        toolCallId = v["toolCallId"]?.string
        mode = v["mode"]?.string ?? "single"
        state = v["state"]?.string ?? "unknown"
        active = v["active"]?.bool ?? false
        sessionId = v["sessionId"]?.string
        cwd = v["cwd"]?.string
        startedAt = v["startedAt"]?.int.map(UInt64.init)
        endedAt = v["endedAt"]?.int.map(UInt64.init)
        lastUpdate = v["lastUpdate"]?.int.map(UInt64.init)
        durationMs = v["durationMs"]?.int.map(UInt64.init)
        if let t = v["tokens"] {
            tokens = t["total"]?.int ?? t.int
        }
        cost = v["cost"]?.double
        steps = (v["steps"]?.array ?? []).map(SubagentStep.init)
        parentWorkflowRunId = v["parentWorkflowRunId"]?.string
        workflowKey = v["workflowKey"]?.string
    }

    /// "reviewer" for one agent; "Workflow · 3 steps" for a workflow.
    public var title: String {
        var seen = Set<String>()
        let agents = steps.compactMap(\.agent).filter { seen.insert($0).inserted }
        switch mode {
        case "workflow": return "Workflow · \(steps.count) step\(steps.count == 1 ? "" : "s")"
        case "parallel": return "Parallel · \(steps.count) agent\(steps.count == 1 ? "" : "s")"
        case "chain": return "Chain · \(steps.count) step\(steps.count == 1 ? "" : "s")"
        default: return agents.isEmpty ? "Subagent" : agents.joined(separator: " + ")
        }
    }

    /// "running", "done", "failed"…
    public var stateLabel: String { Subagents.stateLabel(state) }

    /// "done · 93k tokens · $0.03"
    public var subtitle: String {
        [stateLabel, tokens.map { Format.tokens($0) + " tokens" }, cost.flatMap { $0 > 0 ? Format.cost($0) : nil }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Measured or ticking, never empty.
    public func elapsed(now: Date = Date()) -> String {
        if let durationMs { return Format.duration(Double(durationMs) / 1000) }
        guard let startedAt else { return "" }
        return Format.duration(max(0, now.timeIntervalSince1970 - Double(startedAt) / 1000))
    }

    /// Where the live work is: the first running step, else the last.
    public var currentStep: SubagentStep? {
        steps.first(where: \.active) ?? steps.last
    }
}

/// The tail of one `output-<n>.log` (child 0, child 1, …).
public struct SubagentOutput: Sendable, Equatable, Identifiable {
    public var name: String
    public var text: String
    public var id: String { name }

    public init(_ v: JSONValue) {
        name = v["name"]?.string ?? "output"
        text = v["text"]?.string ?? ""
    }

    /// "Child 1" from "output-1.log".
    public var label: String {
        if name.hasPrefix("output-"), name.hasSuffix(".log") {
            return "Child " + String(name.dropFirst(7).dropLast(4))
        }
        return name
    }
}

public struct SubagentDetail: Sendable, Equatable {
    public var run: SubagentRun?
    public var outputs: [SubagentOutput]

    public init(_ v: JSONValue) {
        if let r = v["run"], !r.isNull { run = SubagentRun(r) }
        outputs = (v["outputs"]?.array ?? []).map(SubagentOutput.init)
    }
}

public struct SubagentSnapshot: Sendable, Equatable {
    /// Milliseconds since 1970 on the server; steps tick against it.
    public var at: UInt64
    public var runs: [SubagentRun]
    public var total: Int

    public init(_ v: JSONValue) {
        at = v["at"]?.int.map(UInt64.init) ?? 0
        runs = (v["runs"]?.array ?? []).map(SubagentRun.init).filter { !$0.id.isEmpty }
        total = v["total"]?.int ?? runs.count
    }

    public var active: [SubagentRun] { runs.filter(\.active) }
    public var finished: [SubagentRun] { runs.filter { !$0.active } }
}

/// The words the web sheet uses, so both clients read the same.
public enum Subagents {
    public static func stateLabel(_ state: String) -> String {
        switch state.lowercased() {
        case "running", "starting", "pending", "queued": return state.lowercased() == "pending" ? "pending" : "running"
        case "complete", "completed", "succeeded": return "done"
        case "failed", "error": return "failed"
        case "stopped", "cancelled", "canceled", "aborted": return "stopped"
        case "paused", "waiting": return "needs you"
        default: return state
        }
    }
}

extension PocketPiClient {
    /// Recent subagent runs: this chat's (`session` = its session file) or
    /// every chat's (`all`). Live runs come first.
    public func subagents(session: String? = nil, all: Bool = false) async throws -> SubagentSnapshot {
        var query: [String] = []
        if all { query.append("all=1") }
        else if let session, !session.isEmpty {
            query.append("session=" + (session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session))
        }
        let path = query.isEmpty ? "/api/subagents" : "/api/subagents?" + query.joined(separator: "&")
        return SubagentSnapshot(try await get(path, as: JSONValue.self))
    }

    /// One run plus the bounded tails of its `output-<n>.log` files.
    public func subagent(id: String) async throws -> SubagentDetail {
        SubagentDetail(try await get("/api/subagents/\(id)", as: JSONValue.self))
    }
}

/// Polls `/api/subagents` for a screen. The run list is small and local to the
/// server; while anything runs it refreshes every second, and every 15 s
/// otherwise (so a finished run still leaves the count).
@MainActor
@Observable
public final class SubagentMonitor {
    public let client: PocketPiClient
    public private(set) var runs: [SubagentRun] = []
    public private(set) var at: Date = Date()
    public private(set) var loading = false
    public private(set) var problem: String?
    /// Every chat's runs instead of this chat's.
    public var all = false {
        didSet { if oldValue != all { Task { await refresh() } } }
    }
    /// The chat's session file; nil means every chat's runs.
    public var sessionPath: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    public init(client: PocketPiClient, sessionPath: String? = nil) {
        self.client = client
        self.sessionPath = sessionPath
    }

    public var active: [SubagentRun] { runs.filter(\.active) }
    public var finished: [SubagentRun] { runs.filter { !$0.active } }
    public var activeCount: Int { active.count }

    /// Match a chat tool card's run.
    public func run(toolCallId: String?) -> SubagentRun? {
        guard let toolCallId else { return nil }
        return runs.first { $0.toolCallId == toolCallId }
    }

    public func refresh() async {
        loading = runs.isEmpty
        defer { loading = false }
        do {
            let s = try await client.subagents(session: sessionPath, all: all || sessionPath == nil)
            runs = s.runs
            at = Date()
            problem = nil
        } catch {
            if let m = error.reportable, runs.isEmpty { problem = m }
        }
    }

    /// Poll while the screen is up; the loop stops with the task.
    public func start(every: Duration = .seconds(1)) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                let wait = self.active.isEmpty && !self.all ? Duration.seconds(5) : every
                try? await Task.sleep(for: wait)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
