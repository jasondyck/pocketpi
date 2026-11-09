import Foundation

// Goal mode (docs/dsh-features-plan.md §3.1). extensions/pocketpi-goal.ts
// publishes the chat's goal as JSON in the "pp-goal" status:
//   {id, revision, objective, phase, rounds, maxRounds, cost, maxCost, blockedReason, armed}
// and takes `pp-goal` control commands
//   {action: get|create|edit|pause|resume|clear|defaults, objective?, maxRounds?, maxCost?, id?, revision?}.
// The defaults for new goals live in features.json under "goal"
// (GET / POST /api/features). The web twin is web/goal.js.

/// A chat's goal, as pocketpi-goal.ts publishes it.
public struct Goal: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case active, paused, blocked, complete
    }

    public var id: String
    public var revision: Int
    public var objective: String
    public var phase: Phase
    public var rounds: Int
    public var maxRounds: Int
    /// Dollars spent since the goal was created.
    public var cost: Double
    public var maxCost: Double
    /// Why it's blocked: the model's reason, or "round-limit" / "cost-limit".
    public var blockedReason: String?
    /// Rounds keep coming on their own (false after a restart, resume or
    /// abort, until a person resumes it).
    public var armed: Bool

    public init?(_ json: JSONValue?) {
        guard let j = json, let id = j["id"]?.string, let objective = j["objective"]?.string,
              let phase = Phase(rawValue: j["phase"]?.string ?? "") else { return nil }
        self.id = id
        self.objective = objective
        self.phase = phase
        revision = j["revision"]?.int ?? 0
        rounds = j["rounds"]?.int ?? 0
        maxRounds = j["maxRounds"]?.int ?? GoalDefaults.builtIn.maxRounds
        cost = j["cost"]?.double ?? 0
        maxCost = j["maxCost"]?.double ?? GoalDefaults.builtIn.maxCost
        blockedReason = j["blockedReason"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        armed = j["armed"]?.bool ?? false
    }

    /// pi is working on it now and will keep taking rounds.
    public var isRunning: Bool { phase == .active && armed }

    /// The phase as a person reads it.
    public var phaseLabel: String {
        switch phase {
        case .active: armed ? "Running" : "Waiting"
        case .paused: "Paused"
        case .complete: "Complete"
        case .blocked:
            switch blockedReason {
            case "round-limit": "Round cap reached"
            case "cost-limit": "Cost cap reached"
            default: "Blocked"
            }
        }
    }

    /// The model's own reason for blocking (nil for the caps, which the
    /// phase label already says).
    public var blockedDetail: String? {
        guard phase == .blocked, let r = blockedReason, r != "round-limit", r != "cost-limit" else { return nil }
        return r
    }

    /// Pause for a running goal, Resume for one that isn't; nil once complete.
    public var toggleAction: GoalAction? {
        switch phase {
        case .complete: nil
        case .active where armed: .pause
        default: .resume
        }
    }

    public var roundsText: String { "Round \(rounds)/\(maxRounds)" }
    public var costText: String { "\(Self.dollars(cost)) of \(Self.dollars(maxCost))" }

    public static func dollars(_ d: Double) -> String { String(format: "$%.2f", d) }
}

/// The caps a new goal starts with.
public struct GoalDefaults: Sendable, Equatable {
    public var maxRounds: Int
    public var maxCost: Double

    public init(maxRounds: Int, maxCost: Double) {
        self.maxRounds = maxRounds
        self.maxCost = maxCost
    }

    /// 30 rounds and $5 (docs/dsh-features-plan.md §5).
    public static let builtIn = GoalDefaults(maxRounds: 30, maxCost: 5)

    /// From the whole features.json (GET /api/features) or its "goal" object.
    public init(features: JSONValue?) {
        let g = features?["goal"] ?? features
        maxRounds = g?["maxRounds"]?.int.flatMap { $0 >= 1 ? $0 : nil } ?? Self.builtIn.maxRounds
        maxCost = g?["maxCost"]?.double.flatMap { $0 > 0 ? $0 : nil } ?? Self.builtIn.maxCost
    }

    public var json: JSONValue { ["maxRounds": .number(Double(maxRounds)), "maxCost": .number(maxCost)] }
}

/// What a person can do to a goal (the `pp-goal` control command).
public enum GoalAction: Sendable, Equatable {
    case get
    case create(objective: String, caps: GoalDefaults)
    /// Changes what is given; checked against the goal's id and revision.
    case edit(goal: Goal, objective: String?, caps: GoalDefaults?)
    case pause, resume, clear

    public var args: JSONValue {
        switch self {
        case .get: return ["action": "get"]
        case .pause: return ["action": "pause"]
        case .resume: return ["action": "resume"]
        case .clear: return ["action": "clear"]
        case .create(let objective, let caps):
            return ["action": "create", "objective": .string(objective),
                    "maxRounds": .number(Double(caps.maxRounds)), "maxCost": .number(caps.maxCost)]
        case .edit(let goal, let objective, let caps):
            var o: [String: JSONValue] = ["action": "edit", "id": .string(goal.id), "revision": .number(Double(goal.revision))]
            if let objective { o["objective"] = .string(objective) }
            if let caps {
                o["maxRounds"] = .number(Double(caps.maxRounds))
                o["maxCost"] = .number(caps.maxCost)
            }
            return .object(o)
        }
    }
}

extension ChatSession {
    /// This chat's goal, from the extension's published state.
    public var goal: Goal? { Goal(transcript.extensionUI.feature("pp-goal")) }

    /// Runs a goal action; returns the goal afterwards (nil when there is none).
    @discardableResult
    public func runGoal(_ action: GoalAction) async throws -> Goal? {
        Goal(try await control("goal", args: action.args)["goal"])
    }

    /// The caps new goals start with (features.json).
    public func goalDefaults() async -> GoalDefaults {
        GoalDefaults(features: try? await client.get("/api/features", as: JSONValue.self))
    }

    /// Makes `caps` the default for new goals.
    public func saveGoalDefaults(_ caps: GoalDefaults) async throws {
        let _: JSONValue = try await client.post("/api/features", ["key": "goal", "value": caps.json])
    }
}
