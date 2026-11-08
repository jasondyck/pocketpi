import Foundation
import Testing
@testable import PocketPiKit

@Suite struct JSONValueTests {
    @Test func roundTrips() throws {
        let v = try JSONValue.parse(#"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#)
        #expect(v["a"]?[0]?.int == 1)
        #expect(v["a"]?[1]?.double == 2.5)
        #expect(v["a"]?[2]?.string == "x")
        #expect(v["a"]?[3]?.bool == true)
        #expect(v["a"]?[4]?.isNull == true)
        #expect(v["b"]?["c"]?.string == "d")
        #expect(try JSONValue.parse(v.encoded()) == v)
        #expect(JSONValue.number(3).compactText == "3")
    }
}

@Suite struct SSEParserTests {
    @Test func splitsEventsAcrossChunks() {
        var p = SSEParser()
        #expect(p.feed(Data("data: {\"a\"".utf8)).isEmpty)
        #expect(p.feed(Data(":1}\n".utf8)).isEmpty)
        #expect(p.feed(Data("\n: keep-alive\n\ndata:x\r\n\r\ndata: a\ndata: b\n\n".utf8)) == [#"{"a":1}"#, "x", "a\nb"])
    }

    @Test func keepsMultibyteCharactersSplitAcrossChunks() {
        var p = SSEParser()
        let bytes = Array("data: héllo\n\n".utf8)
        let cut = 8 // inside é
        #expect(p.feed(Data(bytes[..<cut])).isEmpty)
        #expect(p.feed(Data(bytes[cut...])) == ["héllo"])
    }
}

@Suite struct ServerAddressTests {
    @Test func acceptsWhatPeopleType() throws {
        #expect(try ServerAddress(parsing: "box.example.ts.net:9457").url.absoluteString == "https://box.example.ts.net:9457")
        #expect(try ServerAddress(parsing: " https://host.ts.net/some/path?x=1 ").url.absoluteString == "https://host.ts.net")
        #expect(try ServerAddress(parsing: "http://127.0.0.1:3457").url.absoluteString == "http://127.0.0.1:3457")
        #expect(throws: PocketPiError.self) { try ServerAddress(parsing: "") }
        #expect(throws: PocketPiError.self) { try ServerAddress(parsing: "ftp://x") }
    }
}

@Suite struct FormatTests {
    @Test func formats() {
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(1500) == "1.5k")
        #expect(Format.tokens(25_000) == "25k")
        #expect(Format.tokens(1_200_000) == "1.2M")
        #expect(Format.cost(0.004) == "<$0.01")
        #expect(Format.cost(0.123) == "$0.123")
        #expect(Format.cost(2) == "$2.00")
        #expect(Format.tilde("/home/j/x", home: "/home/j") == "~/x")
        #expect(Format.tilde("/home/jx", home: "/home/j") == "/home/jx")
        #expect(Format.baseName("/a/b/") == "b")
        #expect(ToolSummary.summary(name: "bash", arguments: ["command": "ls"], home: nil) == "ls")
        #expect(ToolSummary.summary(name: "read", arguments: ["path": "/home/j/f.rs"], home: "/home/j") == "~/f.rs")
        #expect(ToolSummary.summary(name: "x", arguments: [:], home: nil) == "")
    }
}

@Suite struct TranscriptTests {
    func ev(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    @Test func loadsHistory() {
        var t = Transcript()
        t.load(messages: [
            ["role": "user", "content": "hi there\nsecond line"],
            ["role": "assistant", "content": [["type": "text", "text": "hello"],
                                               ["type": "toolCall", "id": "c1", "name": "bash", "arguments": ["command": "ls"]]],
             "stopReason": "toolUse"],
            ["role": "toolResult", "toolCallId": "c1", "content": [["type": "text", "text": "a\nb"]], "isError": false],
            ["role": "compactionSummary", "summary": "earlier", "tokensBefore": 5000],
            ["role": "custom", "content": "hidden"],
            ["role": "custom", "content": "shown", "display": true],
            ["role": "bashExecution", "command": "pwd", "output": "/x", "exitCode": 0],
        ], isStreaming: false)
        #expect(t.items.count == 5)
        #expect(t.firstPrompt == "hi there")
        #expect(t.toolResults["c1"]?.text == "a\nb")
        #expect(t.items[2].kind == .compaction(summary: "earlier", tokensBefore: 5000))
        #expect(t.items[3].kind == .custom("shown"))
        #expect(t.items[4].kind == .bash(command: "pwd", output: "/x", exitCode: 0))
    }

    @Test func streamsATurn() {
        var t = Transcript()
        let t0 = Date(timeIntervalSince1970: 1000)
        t.apply(ev(#"{"type":"agent_start"}"#))
        #expect(t.isStreaming)
        t.apply(ev(#"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"q"}]}}"#))
        t.apply(ev(#"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"q"}]}}"#))
        t.apply(ev(#"{"type":"message_start","message":{"role":"assistant","content":[]}}"#))
        t.apply(ev(#"{"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}"#), now: t0)
        t.apply(ev(#"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"hm"}}"#), now: t0)
        #expect(t.activity == "Thinking")
        t.apply(ev(#"{"type":"message_update","assistantMessageEvent":{"type":"thinking_end","contentIndex":0}}"#), now: t0 + 3)
        t.apply(ev(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"Hel"}}"#))
        t.apply(ev(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"lo"}}"#))
        #expect(t.activity == "Writing")
        guard case .assistant(let live, true) = t.items.last?.kind else { Issue.record("no live message"); return }
        #expect(live.content == [.thinking("hm", seconds: 3), .text("Hello")])

        t.apply(ev(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Hello"}],"stopReason":"stop"}}"#))
        guard case .assistant(let final, false) = t.items.last?.kind else { Issue.record("not final"); return }
        #expect(final.content == [.thinking("hm", seconds: 3), .text("Hello")]) // measured time kept
        #expect(final.stopReason == "stop")
        #expect(t.items.count == 2)
        #expect(t.apply(ev(#"{"type":"agent_settled"}"#)) == [.turnFinished])
        #expect(!t.isStreaming)
    }

    @Test func toolLifecycle() {
        var t = Transcript()
        t.apply(ev(#"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":0,"id":"c","toolName":"bash"}}"#))
        t.apply(ev(#"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":0,"toolCall":{"type":"toolCall","id":"c","name":"bash","arguments":{"command":"ls"}}}}"#))
        t.apply(ev(#"{"type":"tool_execution_start","toolCallId":"c","toolName":"bash"}"#))
        #expect(t.runningTools == ["c"])
        #expect(t.activity == "Running bash")
        t.apply(ev(#"{"type":"tool_execution_update","toolCallId":"c","partialResult":{"content":[{"type":"text","text":"par"}]}}"#))
        #expect(t.partialResults["c"]?.text == "par")
        t.apply(ev(#"{"type":"tool_execution_end","toolCallId":"c","result":{"content":[{"type":"text","text":"done"}],"details":{"diff":"-a\n+b"}},"isError":true,"durationMs":12}"#))
        #expect(t.runningTools.isEmpty)
        #expect(t.partialResults["c"] == nil)
        #expect(t.toolResults["c"]?.isError == true)
        #expect(t.toolResults["c"]?.durationMs == 12)
        #expect(t.toolResults["c"]?.diff == "-a\n+b")
    }

    @Test func effects() {
        var t = Transcript()
        #expect(t.apply(ev(#"{"type":"pocketpi_hello","streaming":false}"#)) == [.reloadSnapshot])
        #expect(t.apply(ev(#"{"type":"pocketpi_exit","stderr":["boom"]}"#)) == [.exited(stderr: ["boom"])])
        #expect(t.apply(ev(#"{"type":"pocketpi_exit","restarting":true,"stderr":[]}"#)) == [.restarting])
        #expect(t.apply(ev(#"{"type":"pocketpi_session","file":"/s/new.jsonl"}"#)) == [.sessionFileChanged("/s/new.jsonl")])
        #expect(PiConfigPatch.path("modelThinkingLevels", "anthropic/claude-4.5") == #"modelThinkingLevels.anthropic/claude-4\.5"#)
        #expect(t.apply(ev(#"{"type":"extension_ui_request","id":"u","method":"select","title":"Pick","options":["a","b"]}"#))
            == [.extensionRequest(ExtensionRequest(id: "u", method: .select, title: "Pick", message: nil, options: ["a", "b"], prefill: nil, placeholder: nil))])
        #expect(t.apply(ev(#"{"type":"extension_ui_request","id":"n","method":"notify","message":"hey"}"#)) == [])
        #expect(t.items.last?.kind == .note("hey"))
        #expect(t.apply(ev(#"{"type":"extension_ui_request","id":"e","method":"notify","message":"bad","notifyType":"error"}"#)) == [.problem("bad")])
        #expect(t.apply(ev(#"{"type":"extension_ui_request","id":"e","method":"set_editor_text","text":"draft"}"#)) == [.setComposer("draft")])
        #expect(t.apply(ev(#"{"type":"extension_ui_request","id":"x","method":"unknown"}"#)).isEmpty)
        #expect(t.apply(ev(#"{"type":"session_info_changed","name":"N"}"#)) == [.sessionNameChanged("N")])
        t.apply(ev(#"{"type":"queue_update","steering":["s"],"followUp":["f"]}"#))
        #expect(t.steering == ["s"] && t.followUp == ["f"])
        #expect(t.apply(ev(#"{"type":"compaction_end","result":{"tokensBefore":20000,"estimatedTokensAfter":3000}}"#)) == [.statsStale])
        #expect(t.items.last?.kind == .note("Context compacted · 20k → 3.0k"))
        t.apply(ev(#"{"type":"auto_retry_end","success":false,"finalError":"overloaded"}"#))
        #expect(t.items.last?.kind == .error("overloaded"))
        #expect(t.apply(ev(#"{"type":"something_new"}"#)).isEmpty)
    }
}

@Suite struct ExtensionUITests {
    func ev(_ s: String) -> JSONValue { try! JSONValue.parse(s) }
    func req(_ body: String) -> JSONValue { ev(#"{"type":"extension_ui_request","id":"x",\#(body)}"#) }

    @Test func statusWidgetsAndTitle() {
        var t = Transcript()
        #expect(t.apply(req(#""method":"setStatus","statusKey":"a","statusText":"\u001b[32mone\u001b[0m""#)).isEmpty)
        #expect(t.extensionUI.statuses == [.init(key: "a", text: "one")])
        t.apply(req(#""method":"setStatus","statusKey":"b","statusText":"two""#))
        t.apply(req(#""method":"setStatus","statusKey":"a","statusText":"three""#))
        #expect(t.extensionUI.statuses.map(\.key) == ["a", "b"])
        #expect(t.extensionUI.statuses.map(\.text) == ["three", "two"])
        t.apply(req(#""method":"setWidget","widgetKey":"w","widgetLines":["x","y"]"#))
        t.apply(req(#""method":"setWidget","widgetKey":"v","widgetLines":["z"],"widgetPlacement":"belowEditor""#))
        #expect(t.extensionUI.aboveEditor.map(\.lines) == [["x", "y"]])
        #expect(t.extensionUI.belowEditor.map(\.key) == ["v"])
        t.apply(req(#""method":"setTitle","title":"pi - demo""#))
        #expect(t.extensionUI.title == "pi - demo")
        // Fire-and-forget: none of these is a dialog or a line in the chat.
        #expect(t.items.isEmpty)

        // Clearing: no statusText / widgetLines.
        t.apply(req(#""method":"setStatus","statusKey":"a""#))
        t.apply(req(#""method":"setWidget","widgetKey":"w","widgetLines":null"#))
        #expect(t.extensionUI.statuses.map(\.key) == ["b"])
        #expect(t.extensionUI.widgets.map(\.key) == ["v"])

        // pi exits: it all goes.
        t.apply(ev(#"{"type":"pocketpi_exit","stderr":[]}"#))
        #expect(t.extensionUI == ExtensionUIState())
    }

    @Test func helloReplaysWhatIsInEffect() {
        var t = Transcript()
        t.apply(req(#""method":"setStatus","statusKey":"old","statusText":"stale""#))
        let effects = t.apply(ev(#"{"type":"pocketpi_hello","streaming":false,"ui":[{"type":"extension_ui_request","id":"1","method":"setStatus","statusKey":"s","statusText":"on"},{"type":"extension_ui_request","id":"2","method":"setTitle","title":"T"}]}"#))
        #expect(effects == [.reloadSnapshot])
        #expect(t.extensionUI.statuses == [.init(key: "s", text: "on")])
        #expect(t.extensionUI.title == "T")
        // A resync (dropped events) keeps it.
        t.apply(ev(#"{"type":"pocketpi_resync"}"#))
        #expect(t.extensionUI.title == "T")
        // A restart's new pi says what it has in its own hello.
        t.apply(ev(#"{"type":"pocketpi_exit","restarting":true,"stderr":[]}"#))
        #expect(t.extensionUI.isEmpty && t.extensionUI.title == nil)
    }

    @Test func dialogTimeoutCountsDown() {
        var t = Transcript()
        let now = Date(timeIntervalSince1970: 1000)
        let effects = t.apply(req(#""method":"confirm","title":"Sure?","timeout":5000"#), now: now)
        guard case .extensionRequest(let r)? = effects.first else { Issue.record("no dialog"); return }
        #expect(r.timeout == 5)
        #expect(r.deadline == now.addingTimeInterval(5))
        #expect(r.countdown(at: now) == "Closes in 5 s")
        #expect(r.countdown(at: now.addingTimeInterval(3.2)) == "Closes in 2 s")
        #expect(!r.isExpired(at: now.addingTimeInterval(4.9)))
        #expect(r.isExpired(at: now.addingTimeInterval(5)))
        #expect(r.remaining(at: now.addingTimeInterval(9)) == 0)
        let plain = t.apply(req(#""method":"input","title":"Name""#))
        guard case .extensionRequest(let q)? = plain.first else { Issue.record("no dialog"); return }
        #expect(q.deadline == nil && q.countdown() == nil && !q.isExpired())
    }

    @Test func stripsTerminalEscapes() {
        #expect(ExtensionUIState.plain("\u{1B}[1;31mred\u{1B}[0m ok") == "red ok")
        #expect(ExtensionUIState.plain("\u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{1B}\\") == "link")
        #expect(ExtensionUIState.plain("plain") == "plain")
        // pi-permission-modes' status, exactly.
        let mode = "\u{1B}[38;5;5mBuild\u{1B}[39m \u{1B}[2m(sandboxed in project dir, alt+m)\u{1B}[22;39m  \u{1B}[38;5;2mNetwork: filtered (alt+n)\u{1B}[39m"
        #expect(ExtensionUIState.plain(mode) == "Build (sandboxed in project dir, alt+m)  Network: filtered (alt+n)")
        // Widget lines and titles go through it too.
        var ui = ExtensionUIState()
        ui.apply(.object(["method": .string("setWidget"), "widgetKey": .string("w"), "widgetLines": .array([.string(mode)])]))
        ui.apply(.object(["method": .string("setTitle"), "title": .string("\u{1B}[1mpi\u{1B}[0m - x")]))
        #expect(ui.widgets.first?.lines == ["Build (sandboxed in project dir, alt+m)  Network: filtered (alt+n)"])
        #expect(ui.title == "pi - x")
    }
}

@Suite struct ModelTests {
    @Test func decodesServerShapes() throws {
        let s = try JSONDecoder().decode(SessionsResponse.self, from: Data(#"""
        {"sessions":[{"path":"/s/a.jsonl","id":"a","cwd":"/p","name":null,"title":"first","modified":1730000000000,"messages":2,"live":false,"streaming":false}]}
        """#.utf8))
        #expect(s.sessions[0].displayTitle == "first")
        let p = try JSONDecoder().decode(ProjectsResponse.self, from: Data(#"""
        {"projects":[{"path":"/p","name":"p","pinned":true,"chats":3,"live":1,"streaming":false,"modified":1,"exists":true}],"home":"/home/j"}
        """#.utf8))
        #expect(p.projects[0].pinned && p.home == "/home/j")
        let st = ChatState(["model": ["id": "opencode-go/kimi-k3"], "isStreaming": true, "messageCount": 4])
        #expect(st.modelLabel == "kimi-k3" && st.isStreaming && st.messageCount == 4)
        let stats = SessionStats(["cost": 0.5, "tokens": ["total": 10], "contextUsage": ["percent": 50, "contextWindow": 1000]])
        #expect(stats.contextFraction == 0.5 && stats.totalTokens == 10)
    }
}

@Suite struct MarkdownBlockTests {
    @Test func headingsStartSections() {
        let b = MarkdownBlock.parse("intro\n\n## Verification caveat\n\nbody")
        #expect(b.map(\.isHeading) == [false, true, false])
    }

    @Test func splitsBlocks() {
        let src = """
        # Title
        Some **bold** text
        that wraps.

        ```swift
        let x = 1

        print(x)
        ```
        - one
          continued
        - [x] done
        2. two
        > quoted
        > more
        ---
        tail
        """
        #expect(MarkdownBlock.parse(src) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\nthat wraps."),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .listItem(marker: "•", indent: 0, text: "one\ncontinued"),
            .listItem(marker: "☑", indent: 0, text: "done"),
            .listItem(marker: "2.", indent: 0, text: "two"),
            .quote("quoted\nmore"),
            .rule,
            .paragraph("tail"),
        ])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        // While a reply streams, its code block isn't closed yet.
        #expect(MarkdownBlock.parse("x\n```\ncode") == [.paragraph("x"), .code(language: nil, text: "code")])
        #expect(MarkdownBlock.parse("#nospace") == [.paragraph("#nospace")])
    }
}

@Suite struct NotificationLinkTests {
    @Test func parsesServerURLs() {
        #expect(NotificationLink(url: "/?s=%2Fhome%2Fj%2Fs%2Fa%20b.jsonl") == .chat(path: "/home/j/s/a b.jsonl"))
        #expect(NotificationLink(url: "/?s=/home/j/s/x_1.jsonl") == .chat(path: "/home/j/s/x_1.jsonl")) // as urlencode() in main.rs writes it
        #expect(NotificationLink(url: "/?r=20261105-abc") == .run(id: "20261105-abc"))
        #expect(NotificationLink(url: "/") == nil)
        #expect(NotificationLink(url: "/?s=") == nil)
        #expect(NotificationLink.hexToken(Data([0x0f, 0xa0, 0xff])) == "0fa0ff")
    }
}

@Test func providerLabels() {
    #expect(ModelInfo.providerLabel("opencode-go") == "OpenCode Go")
    #expect(ModelInfo.providerLabel("openai") == "OpenAI")
    #expect(ModelInfo.providerLabel("deepseek") == "DeepSeek")
    #expect(ModelInfo.providerLabel("my-proxy_v2") == "My Proxy V2")
    #expect(ModelInfo.providerLabel("fake") == "Fake")
}

@Test func modelPatterns() {
    #expect(ModelInfo.matches("xai/grok-4.7", "xai/grok-4.7"))
    #expect(ModelInfo.matches("opencode-go/deepseek-*", "opencode-go/deepseek-v4-pro"))
    #expect(!ModelInfo.matches("xai/grok-4.7", "xai/grok-4.7-mini"))
    #expect(ModelInfo.matches("*", "anything"))
}

@Test func foldsThinkingAndToolsIntoOneRow() throws {
    func j(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
    var t = Transcript()
    t.load(messages: [
        j(#"{"role":"user","content":"what's next?"}"#),
        j(#"{"role":"assistant","content":[{"type":"thinking","thinking":"look"},{"type":"toolCall","id":"a","name":"bash","arguments":{"command":"git log"}}],"stopReason":"toolUse"}"#),
        j(#"{"role":"toolResult","toolCallId":"a","content":[{"type":"text","text":"ok"}]}"#),
        j(#"{"role":"assistant","content":[{"type":"toolCall","id":"b","name":"read","arguments":{"path":"x"}},{"type":"toolCall","id":"c","name":"bash","arguments":{"command":"ls"}}],"stopReason":"toolUse"}"#),
        j(#"{"role":"toolResult","toolCallId":"b","content":[{"type":"text","text":"x"}]}"#),
        j(#"{"role":"toolResult","toolCallId":"c","content":[{"type":"text","text":"y"}]}"#),
        j(#"{"role":"assistant","content":[{"type":"thinking","thinking":"so"},{"type":"text","text":"Do the audio plan."}],"stopReason":"stop"}"#),
    ], isStreaming: false)
    let rows = t.rows
    #expect(rows.count == 3)
    guard rows.count == 3 else { return }
    if case .item = rows[0] {} else { Issue.record("first row is the user's message") }
    guard case .activity(_, let steps, let live) = rows[1] else { Issue.record("one activity row"); return }
    #expect(steps.count == 5)
    #expect(!live)
    #expect(ActivitySummary.text(steps) == "Ran 2 commands, read 1 file")
    guard case .text(_, let m) = rows[2] else { Issue.record("then the text"); return }
    #expect(m.plainText == "Do the audio plan.")
}

@Test func activitySummaries() {
    #expect(ActivitySummary.text([.thinking("", seconds: 3, live: false)]) == "Thought for 3s")
    #expect(ActivitySummary.text([.tool(id: "1", name: "edit", arguments: [:])]) == "Edited 1 file")
    #expect(ActivitySummary.text([
        .tool(id: "1", name: "bash", arguments: [:]), .thinking("", seconds: 2, live: false),
        .tool(id: "2", name: "bash", arguments: [:]), .thinking("", seconds: 4, live: false),
    ]) == "Ran 2 commands · thought for 6s")
}

@Test func approvalHeadlines() throws {
    let v = try JSONValue.parse(#"{"id":"r","workflow_id":"w","workflow_name":"clipt: PR check-in","status":"waiting","stages":[{"id":"approve","name":"Post it?","kind":"approval","status":"waiting","prompt":"Post this review on PR #89?\n\n**Verdict: changes requested**\n\n1. `x`"}]}"#)
    let run = try #require(RunInfo(v))
    #expect(run.headline == "Post this review on PR #89?")
    #expect(run.verdict == "changes requested")
}

@Test func approvalHeadlineSkipsTheVerdict() throws {
    let v = try JSONValue.parse(#"{"id":"r","workflow_id":"w","workflow_name":"x","status":"waiting","stages":[{"id":"a","name":"Post it?","kind":"approval","status":"waiting","prompt":"**Verdict: pass**\n\nNo blocking issues."}]}"#)
    let run = try #require(RunInfo(v))
    #expect(run.headline == "No blocking issues.")
    #expect(run.verdict == "pass")
}

@Test func cancellationsAreNotReported() {
    #expect(URLError(.cancelled).isCancellation)
    #expect(CancellationError().reportable == nil)
    #expect(!URLError(.timedOut).isCancellation)
    #expect(PocketPiError.command("boom").reportable == "boom")
}

@Suite struct WorkflowTests {
    @Test func readsAWorkflowAndItsLastRun() throws {
        let v = try JSONValue.parse(#"""
        {"workflow":{"id":"clipt-merge","name":"clipt: auto-merge","description":"Merges.","project":"/p","enabled":true,
          "triggers":[{"type":"schedule","cron":"*/30 * * * *"},{"type":"manual"},{"type":"git","on":"pr"},{"type":"agent","when":"x"}],
          "inputs":[{"name":"pr","description":"PR number","required":true,"default":null},{"name":"commit","required":false,"default":""}],
          "max_cost":2.0,"stages":[{"id":"a"},{"id":"b"}]},
         "errors":[],"last_run":{"id":"r1","status":"failed","created":1794058218063,"ended":null,"cost":0},"runs":53}
        """#)
        let w = try #require(WorkflowInfo(v))
        #expect(w.id == "clipt-merge")
        #expect(w.enabled && w.manual)
        #expect(w.triggers == ["every 30 minutes", "new PR commits", "pi, when it applies"])
        #expect(w.inputs.map(\.name) == ["pr", "commit"])
        #expect(w.inputs[0].required && w.inputs[0].defaultValue == "")
        #expect(w.stageCount == 2 && w.maxCost == 2.0 && w.runCount == 53)
        #expect(w.lastRun?.id == "r1" && w.lastRun?.status == "failed")
    }

    @Test func cronInWords() {
        #expect(WorkflowInfo.cronWords("*/30 * * * *") == "every 30 minutes")
        #expect(WorkflowInfo.cronWords("5 * * * *") == "hourly at :05")
        #expect(WorkflowInfo.cronWords("0 */6 * * *") == "every 6 hours")
        #expect(WorkflowInfo.cronWords("43 16 * * *") == "daily at 16:43")
        #expect(WorkflowInfo.cronWords("0 9 * * 1") == "schedule 0 9 * * 1")
    }

    @Test func runInputsAndRerun() throws {
        let v = try JSONValue.parse(#"""
        {"id":"r","workflow_id":"w","status":"failed","created":1000,"ended":61000,"cost":0.25,"error":"stage Fix failed",
         "inputs":{"pr":"89","commit":"6d039f0","title":"T","url":"u","branch":"b"},
         "stages":[{"id":"fix","name":"Fix","kind":"agent","status":"failed","output":"boom","attempts":2,"started":2000,"ended":3000}]}
        """#)
        let r = try #require(RunInfo(v))
        #expect(r.rerunInputs == ["pr": "89"])
        #expect(r.inputSummary == "PR #89")
        #expect(r.duration() == 60)
        #expect(!r.isActive && r.error == "stage Fix failed")
        #expect(r.stages[0].output == "boom" && r.stages[0].attempts == 2)
        #expect(r.startedBy == "started")
        #expect(Format.duration(45) == "45s" && Format.duration(192) == "3m 12s")
        #expect(Format.duration(120) == "2m" && Format.duration(3840) == "1h 4m")
    }
}

@Suite struct WorkflowDetailTests {
    @Test func readsProposalAndHistory() throws {
        let v = try JSONValue.parse(#"""
        {"workflow":{"id":"w","name":"W","improve":"auto","stages":[{"id":"a","prompt":"old"}]},
         "errors":[],"runs":[{},{}],
         "proposal":{"created":1794000000000,"model":"openai-codex/gpt-6.1-sol",
           "changes":[{"summary":"Sharper prompt","why":"It kept missing X."}],"violations":["changes a shell command"],
           "workflow":{"id":"w","name":"W","improve":"auto","stages":[{"id":"a","prompt":"new"}]}},
         "history":[{"version":"1794000000001","at":1794000000001,"reason":"auto-improved after run r"}]}
        """#)
        let d = try #require(WorkflowDetail(v))
        #expect(d.info.improve == "auto" && d.info.runCount == 2)
        let p = try #require(d.proposal)
        #expect(p.modelLabel == "gpt-6.1-sol")
        #expect(p.changes == [.init(summary: "Sharper prompt", why: "It kept missing X.")])
        #expect(p.violations == ["changes a shell command"])
        #expect(d.history.map(\.reason) == ["auto-improved after run r"])
        let diff = d.proposalDiff
        #expect(diff.contains(DiffLine(.removed, #"      "prompt" : "old""#)))
        #expect(diff.contains(DiffLine(.added, #"      "prompt" : "new""#)))
        #expect(WorkflowDetail(try JSONValue.parse(#"{"workflow":{"id":"w"},"proposal":null}"#))?.proposal == nil)
    }

    @Test func diffFoldsUnchangedRuns() {
        let a = (1...10).map(String.init)
        var b = a
        b[4] = "five"
        let d = DiffLine.diff(a, b, context: 1)
        #expect(d == [
            DiffLine(.skipped, "3 unchanged lines"), DiffLine(.same, "4"), DiffLine(.removed, "5"),
            DiffLine(.added, "five"), DiffLine(.same, "6"), DiffLine(.skipped, "4 unchanged lines"),
        ])
        #expect(DiffLine.diff(a, a).isEmpty)
    }

    @Test func workflowNotificationLink() {
        #expect(NotificationLink(url: "/?w=clipt-merge") == .workflow(id: "clipt-merge"))
    }
}

@Suite struct SlashCommandTests {
    let all = [
        SlashCommand(name: "workflows"),
        SlashCommand(name: "fix-tests", description: "Fix failing tests", source: "prompt"),
        SlashCommand(name: "skill:fix", source: "skill"),
    ]

    @Test func parses() {
        let c = SlashCommand(["name": "fix-tests", "description": "", "source": "prompt"])
        #expect(c == SlashCommand(name: "fix-tests", description: nil, source: "prompt"))
        #expect(SlashCommand(["description": "no name"]) == nil)
    }

    @Test func offersOnlyForALoneSlashWord() {
        #expect(SlashCommand.matches(all, for: "/").count == 3)
        #expect(SlashCommand.matches(all, for: "fix").isEmpty)
        #expect(SlashCommand.matches(all, for: "/fix-tests now").isEmpty)
        #expect(SlashCommand.matches(all, for: "/fix\n").isEmpty)
    }

    @Test func prefixMatchesFirst() {
        #expect(SlashCommand.matches(all, for: "/FIX").map(\.name) == ["fix-tests", "skill:fix"])
        #expect(SlashCommand.matches(all, for: "/flow").map(\.name) == ["workflows"])
        #expect(SlashCommand.matches(all, for: "/zzz").isEmpty)
    }
}

@Suite struct ChatRunsTests {
    @Test func findsRunsPiStarted() {
        var t = Transcript()
        let call: JSONValue = ["role": "assistant", "content": [
            ["type": "toolCall", "id": "c1", "name": "workflow_run", "arguments": ["id": "clipt-fix-pr"]],
            ["type": "toolCall", "id": "c2", "name": "bash", "arguments": ["command": "ls"]],
        ]]
        t.load(messages: [
            ["role": "user", "content": [["type": "text", "text": "fix it"]]],
            call,
            ["role": "toolResult", "toolCallId": "c1", "toolName": "workflow_run",
             "content": [["type": "text", "text": "Started run 20261107-175912-dcd."]],
             "details": ["run_id": "20261107-175912-dcd", "workflow_id": "clipt-fix-pr"]],
            ["role": "toolResult", "toolCallId": "c2", "toolName": "bash",
             "content": [["type": "text", "text": "a"]], "details": [:]],
        ], isStreaming: false)
        #expect(t.startedRuns == ["20261107-175912-dcd"])
    }

    @Test func currentStage() throws {
        func run(_ statuses: [String]) throws -> RunInfo {
            try #require(RunInfo(["id": "r", "workflow_id": "w", "status": "running", "stages": .array(
                statuses.enumerated().map { ["id": .string("s\($0.offset)"), "status": .string($0.element)] })]))
        }
        #expect(try run(["succeeded", "running", "pending"]).currentStage?.id == "s1")
        #expect(try run(["running", "waiting"]).currentStage?.id == "s1")
        #expect(try run(["succeeded", "pending"]).currentStage == nil)
    }

    @Test func stageActivity() throws {
        let r = try #require(RunInfo(["id": "r", "workflow_id": "w", "stages": [
            ["id": "impl", "status": "running", "activity": "Reading src/main.rs", "activity_at": 1794100000000],
            ["id": "checks", "status": "pending"],
        ]]))
        #expect(r.currentStage?.activity == "Reading src/main.rs")
        #expect(r.currentStage?.activityAt == 1794100000000)
        #expect(r.stages[1].activity == nil)
    }
}
