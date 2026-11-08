import Foundation
import Testing
@testable import PocketPiKit

/// Entries the way pi 1.5.0 writes them (checked against real pi: see
/// docs/pi-parity-plan.md, Wave 3).
private func user(_ id: String, _ parent: String?, _ text: String) -> String {
    #"{"type":"message","id":"\#(id)","parentId":\#(parent.map { "\"\($0)\"" } ?? "null"),"timestamp":"2026-11-08T10:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
}
private func asst(_ id: String, _ parent: String, _ text: String?, tools: Int = 0, model: String = "m1", cost: Double = 0.01) -> String {
    var blocks: [String] = []
    if let text { blocks.append(#"{"type":"text","text":"\#(text)"}"#) }
    for i in 0..<tools { blocks.append(#"{"type":"toolCall","id":"c\#(id)\#(i)","name":"bash","arguments":{}}"#) }
    return #"{"type":"message","id":"\#(id)","parentId":"\#(parent)","timestamp":"2026-11-08T10:00:01.000Z","message":{"role":"assistant","content":[\#(blocks.joined(separator: ","))],"provider":"p","model":"\#(model)","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"cost":{"total":\#(cost)}}}}"#
}
private func tool(_ id: String, _ parent: String) -> String {
    #"{"type":"message","id":"\#(id)","parentId":"\#(parent)","timestamp":"2026-11-08T10:00:01.500Z","message":{"role":"toolResult","toolCallId":"x","toolName":"bash","content":[{"type":"text","text":"ok"}]}}"#
}
private func control(_ id: String, _ parent: String) -> String {
    #"{"type":"custom","customType":"pocketpi-control","data":{"reqId":"r","ok":true},"id":"\#(id)","parentId":"\#(parent)","timestamp":"2026-11-08T10:00:02.000Z"}"#
}

/// Builds get_tree's nested answer from flat entries (and labels).
private func treeData(_ lines: [String], leaf: String?, labels: [String: String] = [:]) throws -> JSONValue {
    let entries = try lines.map { try JSONValue.parse($0) }
    func node(_ e: JSONValue) -> JSONValue {
        let id = e["id"]!.string!
        var o: [String: JSONValue] = ["entry": e, "children": .array(entries.filter { $0["parentId"]?.string == id }.map(node))]
        if let l = labels[id] { o["label"] = .string(l) }
        return .object(o)
    }
    let roots = entries.filter { $0["parentId"]?.isNull ?? true }.map(node)
    return ["tree": .array(roots), "leafId": leaf.map(JSONValue.string) ?? .null]
}

@Suite struct SessionTreeTests {
    /// u1 → a1 ─┬─ u2 → a2 (tools) → tr → a2b
    ///          └─ u3 → a3 → [thinking_level_change] → [control reply] ← leaf
    private func branched() throws -> SessionTree {
        let lines = [
            user("u1", nil, "first question"),
            asst("a1", "u1", "first answer"),
            user("u2", "a1", "branch A question\\nsecond line"),
            asst("a2", "u2", nil, tools: 2),
            tool("t2", "a2"),
            asst("a2b", "t2", "branch A answer"),
            user("u3", "a1", "branch B question"),
            asst("a3", "u3", "branch B answer", model: "m2", cost: 0.02),
            #"{"type":"thinking_level_change","id":"tl","parentId":"a3","timestamp":"2026-11-08T10:00:03.000Z","thinkingLevel":"high"}"#,
            control("c1", "tl"),
            #"{"type":"label","id":"lb","parentId":"a2b","timestamp":"2026-11-08T10:00:04.000Z","targetId":"a1","label":"checkpoint"}"#,
        ]
        return SessionTree(try treeData(lines, leaf: "c1", labels: ["a1": "checkpoint"]))
    }

    @Test func showsPromptsRepliesAndBranches() throws {
        let t = try branched()
        #expect(t.rows.map(\.id) == ["u1", "a1", "u2", "a2b", "u3", "a3"])
        #expect(t.rows.map(\.depth) == [0, 0, 1, 1, 1, 1])
        #expect(t.rows.map(\.branchStart) == [false, false, true, false, true, false])
        #expect(t.rows.map(\.kind) == [.user, .assistant, .user, .assistant, .user, .assistant])
        #expect(t.branches == 2)
    }

    @Test func foldsAReplyIntoOneLine() throws {
        let t = try branched()
        let reply = try #require(t.row("a2b"))
        #expect(reply.text == "branch A answer")
        #expect(reply.toolCalls == 2)
        // A prompt shows its first line.
        #expect(t.row("u2")?.text == "branch A question")
    }

    @Test func currentIsTheNearestRowAboveAHiddenLeaf() throws {
        let t = try branched()
        #expect(t.currentId == "a3")
        #expect(t.rows.filter(\.isCurrent).map(\.id) == ["a3"])
        #expect(t.rows.filter(\.onPath).map(\.id) == ["u1", "a1", "u3", "a3"])
        #expect(t.pathUserIds == ["u1", "u3"])
    }

    @Test func showsLabels() throws {
        let t = try branched()
        #expect(t.row("a1")?.label == "checkpoint")
        #expect(t.rows.compactMap(\.label) == ["checkpoint"])
    }

    @Test func hiddenEntriesHandTheirChildrenOn() throws {
        // A prompt sent after a control reply hangs off the reply in pi's
        // tree; it still follows the reply before it here.
        let lines = [
            user("u1", nil, "hi"), asst("a1", "u1", "hello"), control("c1", "a1"),
            user("u2", "c1", "next"), asst("a2", "u2", "ok"),
        ]
        let t = SessionTree(try treeData(lines, leaf: "a2"))
        #expect(t.rows.map(\.id) == ["u1", "a1", "u2", "a2"])
        #expect(t.rows.allSatisfy { $0.depth == 0 && !$0.branchStart })
        #expect(t.currentId == "a2")
    }

    @Test func stopsFoldingWhereTheChatIs() throws {
        // Gone back to the middle of a turn: the rest of it is its own row.
        let lines = [user("u1", nil, "go"), asst("a1", "u1", "step one", tools: 1), tool("t1", "a1"), asst("a2", "t1", "done")]
        let t = SessionTree(try treeData(lines, leaf: "a1"))
        #expect(t.rows.map(\.id) == ["u1", "a1", "a2"])
        #expect(t.currentId == "a1")
        #expect(t.row("a2")?.onPath == false)
    }

    @Test func compactionsSummariesAndShellCommands() throws {
        let lines = [
            user("u1", nil, "hi"), asst("a1", "u1", "hello"),
            #"{"type":"compaction","id":"k1","parentId":"a1","timestamp":"t","summary":"s","firstKeptEntryId":"a1","tokensBefore":50000}"#,
            #"{"type":"branch_summary","id":"b1","parentId":"k1","timestamp":"t","fromId":"x","summary":"The user tried A.\nMore."}"#,
            #"{"type":"message","id":"x1","parentId":"b1","timestamp":"t","message":{"role":"bashExecution","command":"ls -la","output":""}}"#,
            #"{"type":"custom_message","id":"cm","parentId":"x1","timestamp":"t","customType":"e","content":"hidden","display":false}"#,
            #"{"type":"custom_message","id":"cv","parentId":"cm","timestamp":"t","customType":"e","content":"shown note","display":true}"#,
        ]
        let t = SessionTree(try treeData(lines, leaf: "cv"))
        #expect(t.rows.map(\.kind) == [.user, .assistant, .compaction, .branchSummary, .bash, .custom])
        #expect(t.rows[2].text == "Context compacted · 50k tokens")
        #expect(t.rows[3].text == "The user tried A.")
        #expect(t.rows[4].text == "!ls -la")
        #expect(t.rows[5].text == "shown note")
        #expect(t.rows[5].refills)
        #expect(t.currentId == "cv")
    }

    @Test func backBeforeTheFirstPromptHasNoCurrentRow() throws {
        let lines = [user("u1", nil, "hi"), asst("a1", "u1", "hello")]
        // After going to u1 pi's leaf is null (or a control reply at the root).
        let t = SessionTree(try treeData(lines + [#"{"type":"custom","customType":"pocketpi-control","data":{},"id":"c0","parentId":null,"timestamp":"t"}"#], leaf: "c0"))
        #expect(t.currentId == nil)
        #expect(t.rows.map(\.id) == ["u1", "a1"])
        #expect(t.rows.allSatisfy { !$0.onPath })
    }

    @Test func emptyTree() {
        let t = SessionTree(["tree": [], "leafId": nil])
        #expect(t.rows.isEmpty && t.currentId == nil && t.branches == 0)
    }
}

@Suite struct SessionSummaryTests {
    @Test func countsRolesAndCostPerModel() throws {
        let lines = [
            user("u1", nil, "q"), asst("a1", "u1", "a", tools: 1, model: "m1", cost: 0.01), tool("t1", "a1"),
            asst("a1b", "t1", "b", model: "m1", cost: 0.01), user("u2", "a1", "q2"), asst("a2", "u2", "c", model: "m2", cost: 0.05),
            #"{"type":"usage","id":"us","parentId":"a2","timestamp":"t","kind":"cache_warm","provider":"p","model":"m2","usage":{"totalTokens":100,"cost":{"total":0.001}}}"#,
            #"{"type":"branch_summary","id":"b1","parentId":"a2","timestamp":"t","fromId":"x","summary":"s","usage":{"input":300,"output":200,"cost":{"total":0.002}}}"#,
            #"{"type":"label","id":"l1","parentId":"b1","timestamp":"t","targetId":"a1","label":"x"}"#,
            #"{"type":"label","id":"l2","parentId":"l1","timestamp":"t","targetId":"a1"}"#,
            #"{"type":"label","id":"l3","parentId":"l2","timestamp":"t","targetId":"u1","label":"start"}"#,
        ]
        let s = SessionSummary(entries: try lines.map { try JSONValue.parse($0) })
        #expect(s.roles == ["user": 2, "assistant": 3, "toolResult": 1])
        #expect(s.messageCount == 6)
        #expect(s.toolCalls == 1)
        #expect(s.branchSummaries == 1)
        #expect(s.labels == 1)
        #expect(s.models.map(\.id) == ["p/m2", "p/m1", SessionSummary.summariesKey])
        let m2 = try #require(s.models.first)
        #expect(m2.messages == 1)
        #expect(m2.tokens == 115)
        #expect(abs(m2.cost - 0.051) < 1e-9)
        #expect(s.models[2].tokens == 500)
        #expect(abs(s.cost - 0.073) < 1e-9)
        #expect(s.roleLines.map(\.name) == ["Prompts", "Replies", "Tool results"])
    }

    @Test func readsTheHeaderAndGotoAnswers() throws {
        let h = SessionHeader(try JSONValue.parse(#"{"file":"/s/a.jsonl","header":{"type":"session","version":3,"id":"abc","timestamp":"2026-11-08T10:00:00.000Z","cwd":"/p","parentSession":"/s/old.jsonl"}}"#))
        #expect(h.file == "/s/a.jsonl" && h.id == "abc" && h.parentSession == "/s/old.jsonl" && h.created == "2026-11-08T10:00:00.000Z")
        let none = SessionHeader(try JSONValue.parse(#"{"file":null,"header":null}"#))
        #expect(none.file == nil && none.id == nil)
        let g = GotoResult(try JSONValue.parse(#"{"cancelled":false,"editorText":"again","leafId":"a1"}"#))
        #expect(!g.cancelled && g.editorText == "again" && g.leafId == "a1")
    }
}
