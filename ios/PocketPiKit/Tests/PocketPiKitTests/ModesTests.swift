import Testing
@testable import PocketPiKit

@Suite struct ModesTests {
    private func ui(_ statuses: [(String, String?)]) throws -> ExtensionUIState {
        var ui = ExtensionUIState()
        for (k, v) in statuses {
            var o: [String: JSONValue] = ["method": "setStatus", "statusKey": .string(k)]
            if let v { o["statusText"] = .string(v) }
            ui.apply(.object(o))
        }
        return ui
    }

    @Test func modeDefaultsToAutoWithoutStatus() throws {
        let m = try ui([]).chatMode
        #expect(m == ChatMode())
        #expect(m.preset == .auto)
        #expect(!m.showsPresetChip)
    }

    @Test func modeIsParsed() throws {
        let m = try ui([("pp-mode", #"{"preset":"read-only","plan":true,"allow":{"tools":["edit"],"bash":["npm install"]}}"#)]).chatMode
        #expect(m.preset == .readOnly)
        #expect(m.plan)
        #expect(m.allowedTools == ["edit"])
        #expect(m.allowedCommands == ["npm install"])
        #expect(m.showsPresetChip)
        #expect(ChatMode(preset: .auto, plan: true).showsPresetChip)
        #expect(ChatMode(preset: .ask).showsPresetChip)
        // An unknown preset reads as Auto.
        #expect(ChatMode(try JSONValue.parse(#"{"preset":"yolo"}"#)).preset == .auto)
    }

    @Test func presetsRoundTrip() {
        #expect(PermissionPreset.allCases.map(\.rawValue) == ["auto", "ask", "read-only"])
        #expect(PermissionPreset.readOnly.symbol == "lock")
    }

    @Test func todosAreParsedAndSummarised() throws {
        let text = #"{"todos":[{"content":"Read the code","status":"completed"},{"content":"Write tests","status":"in_progress"},{"content":"Ship","status":"pending"},{"content":"bad","status":"nope"}],"done":1,"total":3}"#
        let t = try ui([("pp-todo", text)]).todos
        #expect(t.total == 3)
        #expect(t.done == 1)
        #expect(t.current?.content == "Write tests")
        #expect(t.line == "1/3 · Write tests")
        #expect(t.items.map(\.status) == [.completed, .inProgress, .pending])
    }

    @Test func todosClearedAndFinished() throws {
        var u = try ui([("pp-todo", #"{"todos":[{"content":"a","status":"completed"}]}"#)])
        #expect(u.todos.current == nil)
        #expect(u.todos.line == "1/1 · All done")
        u.apply(try JSONValue.parse(#"{"method":"setStatus","statusKey":"pp-todo"}"#))
        #expect(u.todos.isEmpty)
        #expect(TodoList(items: [TodoItem(content: "x", status: .pending)]).current?.content == "x")
    }

    @Test func planProposalFromCallAndResult() throws {
        let args = try JSONValue.parse(##"{"plan":"# Add a flag\n\n- step"}"##)
        var p = PlanProposal(arguments: args, result: nil)
        #expect(p.title == "Add a flag")
        #expect(p.outcome == nil)
        p = PlanProposal(arguments: args, result: ToolResult(text: "Plan approved", isError: false, details: ["outcome": "approved"]))
        #expect(p.outcome == .approved)
        p = PlanProposal(arguments: [:], result: ToolResult(text: "x", isError: true, details: ["plan": "# T", "outcome": "keep-planning"]))
        #expect(p.plan == "# T")
        #expect(p.outcome == .keepPlanning)
        #expect(PlanProposal(arguments: [:], result: ToolResult(text: "no", isError: true)).outcome == .error)
    }
}
