import Foundation

// Plan mode, the todo list and permission presets (docs/dsh-features-plan.md
// §3.2–3.3). extensions/pocketpi-modes.ts publishes
//   "pp-mode": {preset, plan, allow: {tools, bash}}
//   "pp-todo": {todos: [{content, status}], done, total}   (unset when empty)
// and takes the control commands `mode {preset?, clearAllow?}`,
// `plan {on, message?}` and `todo`.

/// A chat's permission preset.
public enum PermissionPreset: String, Sendable, CaseIterable, Identifiable {
    case auto
    case ask
    case readOnly = "read-only"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .ask: "Ask"
        case .readOnly: "Read-only"
        }
    }

    public var detail: String {
        switch self {
        case .auto: "pi edits and runs commands without asking (the safety rules still apply)"
        case .ask: "Each edit, write and command that changes something asks first"
        case .readOnly: "pi can read and run read-only commands; changes are blocked"
        }
    }

    /// An SF Symbol for the preset.
    public var symbol: String {
        switch self {
        case .auto: "bolt"
        case .ask: "questionmark.circle"
        case .readOnly: "lock"
        }
    }
}

/// The chat's mode, from "pp-mode".
public struct ChatMode: Sendable, Equatable {
    public var preset: PermissionPreset
    public var plan: Bool
    /// "Allow for this chat" answers: whole tools ("edit") and command prefixes ("npm install").
    public var allowedTools: [String]
    public var allowedCommands: [String]

    public init(preset: PermissionPreset = .auto, plan: Bool = false, allowedTools: [String] = [], allowedCommands: [String] = []) {
        self.preset = preset
        self.plan = plan
        self.allowedTools = allowedTools
        self.allowedCommands = allowedCommands
    }

    public init(_ v: JSONValue) {
        preset = v["preset"]?.string.flatMap(PermissionPreset.init(rawValue:)) ?? .auto
        plan = v["plan"]?.bool ?? false
        allowedTools = v["allow"]?["tools"]?.array?.compactMap(\.string) ?? []
        allowedCommands = v["allow"]?["bash"]?.array?.compactMap(\.string) ?? []
    }

    /// Whether the composer shows a preset chip: not for plain Auto, so the
    /// composer stays clean in the common case.
    public var showsPresetChip: Bool { preset != .auto || plan }
}

/// One item of the todo list.
public struct TodoItem: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    public var content: String
    public var status: Status
    public var id: String { content } // unique within a list (the extension enforces it)

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }

    public init?(_ v: JSONValue) {
        guard let c = v["content"]?.string, let s = v["status"]?.string.flatMap(Status.init(rawValue:)) else { return nil }
        self.init(content: c, status: s)
    }
}

/// The todo list, from "pp-todo" or a todo_write call.
public struct TodoList: Sendable, Equatable {
    public var items: [TodoItem]

    public init(items: [TodoItem]) { self.items = items }

    /// From {todos: [...]} (the status JSON, a todo_write call's arguments or its result details).
    public init(_ v: JSONValue) {
        items = v["todos"]?.array?.compactMap(TodoItem.init) ?? []
    }

    public var done: Int { items.filter { $0.status == .completed }.count }
    public var total: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    /// What pi is on: the item in progress, else the next pending one.
    public var current: TodoItem? {
        items.first { $0.status == .inProgress } ?? items.first { $0.status == .pending }
    }
    /// "3/7 · Write the tests"
    public var line: String {
        "\(done)/\(total) · " + (current?.content ?? "All done")
    }
}

/// An exit_plan_mode call: the plan and how the approval went.
public struct PlanProposal: Sendable, Equatable {
    public enum Outcome: String, Sendable { case approved, keepPlanning = "keep-planning", dismissed, error }
    public var plan: String
    public var outcome: Outcome?

    public init(arguments: JSONValue, result: ToolResult?) {
        plan = arguments["plan"]?.string ?? result?.details?["plan"]?.string ?? ""
        outcome = result?.details?["outcome"]?.string.flatMap(Outcome.init(rawValue:)) ?? (result?.isError == true ? .error : nil)
    }

    /// The plan's "# " title line.
    public var title: String {
        let first = plan.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.hasPrefix("#") ? first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) : first
    }
}

extension ExtensionUIState {
    /// The chat's mode; the default (Auto, no plan) until the extension says otherwise.
    public var chatMode: ChatMode { feature("pp-mode").map(ChatMode.init) ?? ChatMode() }
    /// The todo list; empty when there is none.
    public var todos: TodoList { feature("pp-todo").map(TodoList.init) ?? TodoList(items: []) }
}

extension ChatSession {
    public var chatMode: ChatMode { transcript.extensionUI.chatMode }
    public var todos: TodoList { transcript.extensionUI.todos }

    /// Changes this chat's preset. The new state arrives as "pp-mode".
    public func setPreset(_ preset: PermissionPreset) async {
        do { _ = try await control("mode", args: ["preset": .string(preset.rawValue)]) } catch { problem = error.reportable }
    }

    /// Forgets the "Allow for this chat" answers.
    public func clearAllowances() async {
        do { _ = try await control("mode", args: ["clearAllow": true]) } catch { problem = error.reportable }
    }

    /// Turns plan mode on or off; `message` (with on) also sends it as a prompt.
    public func setPlan(_ on: Bool, message: String? = nil) async {
        var args: [String: JSONValue] = ["on": .bool(on)]
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args["message"] = .string(message) }
        do { _ = try await control("plan", args: .object(args)) } catch { problem = error.reportable }
    }

    /// Asks the extension for the list (normally "pp-todo" already has it).
    public func fetchTodos() async throws -> TodoList {
        TodoList(try await control("todo"))
    }
}

extension PocketPiClient {
    /// `modes.defaultPreset` from ~/.config/pocketpi/features.json.
    public func defaultPreset() async throws -> PermissionPreset {
        let all: JSONValue = try await get("/api/features")
        return all["modes"]?["defaultPreset"]?.string.flatMap(PermissionPreset.init(rawValue:)) ?? .auto
    }

    /// Sets the preset new chats start with, keeping the rest of `modes`.
    public func setDefaultPreset(_ preset: PermissionPreset) async throws {
        let all: JSONValue = try await get("/api/features")
        var modes = all["modes"]?.object ?? [:]
        modes["defaultPreset"] = .string(preset.rawValue)
        let _: JSONValue = try await post("/api/features", ["key": "modes", "value": .object(modes)])
    }
}
