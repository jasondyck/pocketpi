import Testing
@testable import PocketPiKit

@Suite struct GoalTests {
    private func status(_ json: String) throws -> Goal? {
        var ui = ExtensionUIState()
        let text = try JSONValue.string(json).encoded()
        ui.apply(try JSONValue.parse(#"{"method":"setStatus","statusKey":"pp-goal","statusText":"# + String(decoding: text, as: UTF8.self) + "}"))
        return Goal(ui.feature("pp-goal"))
    }

    @Test func parsesThePublishedGoal() throws {
        let g = try #require(try status(#"{"id":"g1","revision":4,"objective":"ship it","phase":"active","rounds":2,"maxRounds":30,"cost":0.4567,"maxCost":5,"blockedReason":null,"armed":true}"#))
        #expect(g.id == "g1")
        #expect(g.revision == 4)
        #expect(g.objective == "ship it")
        #expect(g.phase == .active)
        #expect(g.isRunning)
        #expect(g.phaseLabel == "Running")
        #expect(g.roundsText == "Round 2/30")
        #expect(g.costText == "$0.46 of $5.00")
        #expect(g.blockedReason == nil)
        #expect(g.toggleAction == .pause)
    }

    @Test func phasesAndLabels() throws {
        let waiting = try #require(try status(#"{"id":"g","objective":"x","phase":"active","armed":false}"#))
        #expect(waiting.phaseLabel == "Waiting")
        #expect(!waiting.isRunning)
        #expect(waiting.toggleAction == .resume)
        let capped = try #require(try status(#"{"id":"g","objective":"x","phase":"blocked","blockedReason":"round-limit"}"#))
        #expect(capped.phaseLabel == "Round cap reached")
        #expect(capped.blockedDetail == nil)
        let cost = try #require(try status(#"{"id":"g","objective":"x","phase":"blocked","blockedReason":"cost-limit"}"#))
        #expect(cost.phaseLabel == "Cost cap reached")
        let stuck = try #require(try status(#"{"id":"g","objective":"x","phase":"blocked","blockedReason":"no credentials"}"#))
        #expect(stuck.phaseLabel == "Blocked")
        #expect(stuck.blockedDetail == "no credentials")
        #expect(stuck.toggleAction == .resume)
        let done = try #require(try status(#"{"id":"g","objective":"x","phase":"complete"}"#))
        #expect(done.toggleAction == nil)
        #expect(done.maxRounds == 30 && done.maxCost == 5)
        #expect(Goal(nil) == nil)
        #expect(Goal(["id": "g", "objective": "x", "phase": "weird"]) == nil)
    }

    @Test func actionArgs() throws {
        #expect(GoalAction.pause.args == ["action": "pause"])
        #expect(GoalAction.create(objective: "x", caps: GoalDefaults(maxRounds: 4, maxCost: 1.5)).args
            == ["action": "create", "objective": "x", "maxRounds": 4, "maxCost": 1.5])
        let g = try #require(Goal(["id": "g1", "revision": 3, "objective": "x", "phase": "paused"]))
        #expect(GoalAction.edit(goal: g, objective: "y", caps: nil).args == ["action": "edit", "id": "g1", "revision": 3, "objective": "y"])
        #expect(GoalAction.edit(goal: g, objective: nil, caps: .builtIn).args
            == ["action": "edit", "id": "g1", "revision": 3, "maxRounds": 30, "maxCost": 5])
    }

    @Test func defaultsFromFeatures() {
        #expect(GoalDefaults(features: nil) == .builtIn)
        #expect(GoalDefaults(features: ["goal": ["maxRounds": 8, "maxCost": 2.5]]) == GoalDefaults(maxRounds: 8, maxCost: 2.5))
        #expect(GoalDefaults(features: ["goal": ["maxRounds": 0, "maxCost": -1]]) == .builtIn)
        #expect(GoalDefaults(features: ["maxRounds": 12]).maxRounds == 12)
        #expect(GoalDefaults(maxRounds: 3, maxCost: 1).json == ["maxRounds": 3, "maxCost": 1])
    }
}
