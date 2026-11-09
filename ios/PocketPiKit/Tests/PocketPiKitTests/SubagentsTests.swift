import Foundation
import Testing
@testable import PocketPiKit

@Suite struct SubagentsTests {
    private let snapshot = #"""
    {"at":1794179796496,"total":2,"runs":[
      {"id":"wf-1","runId":"wf-1","toolCallId":"call_wf","mode":"workflow","state":"running","active":true,
       "sessionId":"/s/chat.jsonl","cwd":"/home/x/project","startedAt":1794179000000,"lastUpdate":1794179796496,
       "durationMs":796496,"tokens":1500,"cost":0.02,"steps":[
        {"index":0,"agent":"reviewer","label":"task-1","status":"completed","active":false,
         "startedAt":1794179000000,"endedAt":1794179020000,"durationMs":20000,
         "tokens":{"input":900,"output":300,"total":1200},"model":"deepseek","provider":"opencode-go",
         "sessionFile":"/s/child-1.jsonl","recentTools":["read src/main.rs"],
         "recentOutput":["done reviewing"],"turnCount":3},
        {"index":1,"agent":"worker","label":"task-2","status":"running","active":true,
         "startedAt":1794179700000,"recentTools":["edit src/subagents.rs","bash cargo test"],
         "recentOutput":["line one","line two"],"sessionFile":"/s/child-2.jsonl",
         "tokens":{"input":200,"output":100}}]},
      {"id":"done-1","runId":"done-1","toolCallId":null,"mode":"single","state":"complete","active":false,
       "sessionId":"/s/chat.jsonl","startedAt":1794178000000,"durationMs":12000,
       "tokens":300,"cost":0.004,"steps":[
        {"index":0,"agent":"scout","status":"completed","active":false,"durationMs":12000,
         "sessionFile":"/s/child-3.jsonl","recentOutput":["found it"]}]}]}
    """#

    private func parsed() throws -> SubagentSnapshot {
        SubagentSnapshot(try JSONDecoder().decode(JSONValue.self, from: Data(snapshot.utf8)))
    }

    @Test func readsRunsAndSteps() throws {
        let s = try parsed()
        #expect(s.total == 2 && s.runs.count == 2)
        #expect(s.active.map(\.id) == ["wf-1"])
        #expect(s.finished.map(\.id) == ["done-1"])
        let run = s.runs[0]
        #expect(run.toolCallId == "call_wf")
        #expect(run.title == "Workflow · 2 steps")
        #expect(run.stateLabel == "running")
        #expect(run.subtitle == "running · 1.5k tokens · $0.020")
        #expect(run.steps.count == 2)
        #expect(run.currentStep?.index == 1)
        #expect(run.steps[1].line == "bash cargo test")
        #expect(run.steps[1].tokens == 300)
        #expect(run.steps[1].sessionFile == "/s/child-2.jsonl")
        #expect(run.steps[0].tokens == 1200)
        #expect(run.steps[0].elapsed() == "20s")
        #expect(Subagents.stateLabel("complete") == "done")
        #expect(Subagents.stateLabel("paused") == "needs you")
    }

    @Test func oneAgentRunsUseTheAgentName() throws {
        let s = try parsed()
        #expect(s.runs[1].title == "scout")
        #expect(s.runs[1].currentStep?.line == "found it")
        #expect(s.runs[1].elapsed() == "12s")
    }

    @Test func readsTheDetailTail() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"at":1,"run":{"id":"r","mode":"single","state":"running","steps":[]},
         "outputs":[{"name":"output-0.log","text":"hello\nworld"},{"name":"output-1.log","text":""}]}
        """#.utf8))
        let d = SubagentDetail(v)
        #expect(d.run?.id == "r")
        #expect(d.outputs.count == 2)
        #expect(d.outputs[0].label == "Child 0")
        #expect(d.outputs[0].text.contains("world"))
        #expect(d.outputs[1].label == "Child 1")
    }

    @Test func emptyRunListsAreFine() throws {
        let s = SubagentSnapshot(try JSONValue.parse(#"{"at":0,"runs":[],"total":0}"#))
        #expect(s.runs.isEmpty && s.active.isEmpty && s.finished.isEmpty)
    }
}
