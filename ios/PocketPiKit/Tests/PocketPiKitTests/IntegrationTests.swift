import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// Against a scratch pocketpi running ios/fake-pi.py (ios/test-linux.sh starts
/// one). Skipped when POCKETPI_TEST_URL isn't set.
private let env = ProcessInfo.processInfo.environment
private let serverURL = env["POCKETPI_TEST_URL"]
private let projectDir = env["POCKETPI_TEST_CWD"] ?? ""

@MainActor
private func waitFor(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > end { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(25))
    }
}

@MainActor
private func lastAssistantText(_ s: ChatSession) -> String? {
    for item in s.transcript.items.reversed() {
        if case .assistant(let m, false) = item.kind, let t = m.content.compactMap(\.text).last { return t }
    }
    return nil
}

@Suite(.serialized, .enabled(if: serverURL != nil))
@MainActor
struct IntegrationTests {
    let client = PocketPiClient(server: ServerAddress(url: URL(string: serverURL ?? "http://127.0.0.1:1")!))

    @Test func listsAndVersions() async throws {
        #expect(try await client.version().build > 0)
        _ = try await client.projects()
        _ = try await client.sessions()
    }

    @Test func pinsRenamesAndHidesProjects() async throws {
        try await client.saveProject(path: projectDir)
        var p = try await client.projects().projects.first { $0.path == projectDir }
        #expect(p?.pinned == true)
        try await client.saveProject(path: projectDir, name: "Renamed")
        p = try await client.projects().projects.first { $0.path == projectDir }
        #expect(p?.name == "Renamed")
        try await client.hideProject(path: projectDir)
        p = try await client.projects().projects.first { $0.path == projectDir }
        #expect(p == nil || p?.pinned == false)
        // Back to how the other tests expect it.
        try await client.saveProject(path: projectDir, name: "")
    }

    @Test func registersForPush() async throws {
        let token = String(repeating: "a1", count: 32)
        try await client.registerPush(token: token, environment: .sandbox, label: "test phone")
        try await client.registerPush(token: token, environment: .sandbox, label: "test phone")
        let info: JSONValue = try await client.get("/api/push")
        #expect(info["apns"]?["devices"]?.int == 1)
        await #expect(throws: PocketPiError.self) {
            try await client.registerPush(token: "not-hex", environment: .production, label: "")
        }
        try await client.unregisterPush(token: token)
        let after: JSONValue = try await client.get("/api/push")
        #expect(after["apns"]?["devices"]?.int == 0)
    }

    @Test func refusesPostsWithoutTheHeader() async throws {
        var r = URLRequest(url: client.server.url.appending(path: "/api/new"))
        r.httpMethod = "POST"
        r.httpBody = Data(#"{"cwd":"~"}"#.utf8)
        let (_, resp) = try await URLSession.shared.data(for: r)
        #expect((resp as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test func newChatStreamsAndIsSaved() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        var turns = 0
        s.onTurnFinished = { turns += 1 }
        try await s.send("hello there")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: hello there" && !s.isStreaming }
        try await waitFor("the session file") { s.path != nil && turns == 1 }
        #expect(s.title == "hello there")
        #expect(s.stats?.totalTokens == 1234)
        #expect(s.thinkingLevels.contains("high"))
        if case .assistant(let m, _) = s.transcript.items.last?.kind, case .thinking(_, let secs) = m.content.first {
            #expect(secs != nil) // measured live
        } else { Issue.record("no thinking block") }

        let listed = try await client.sessions()
        #expect(listed.contains { $0.path == s.path && $0.title == "hello there" }, "\(listed.map { ($0.path, $0.title) }) vs \(s.path ?? "nil")")

        // Reopened from the file, as from the chat list.
        let path = try #require(s.path)
        s.leave()
        let again = ChatSession(client: client, path: path, cwd: projectDir)
        await again.start()
        try await waitFor("history") { again.transcript.items.count == 2 }
        #expect(again.status == .connected)
        again.leave()
    }

    @Test func toolCallsGetResults() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("use a tool")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: use a tool" && !s.isStreaming }
        let callId = s.transcript.items.compactMap { item -> String? in
            if case .assistant(let m, _) = item.kind {
                for b in m.content { if case .toolCall(let id, "bash", _) = b { return id } }
            }
            return nil
        }.first
        let id = try #require(callId)
        #expect(s.transcript.toolResults[id]?.text == "hi")
        s.leave()
    }

    @Test func answersExtensionDialogs() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("ask me")
        try await waitFor("the dialog") { s.pendingRequest != nil }
        let r = try #require(s.pendingRequest)
        #expect(r.method == .confirm && r.title == "Allow it?")
        await s.respond(to: r, .confirmed(true))
        #expect(s.pendingRequest == nil)
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: ask me · confirmed" }
        s.leave()
    }

    @Test func showsStatusWidgetsAndTitle() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("show widgets")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: show widgets" && s.path != nil && !s.isStreaming }
        let ui = s.transcript.extensionUI
        #expect(ui.statuses == [.init(key: "fake", text: "ready"), .init(key: "lint", text: "2 warnings"),
                                .init(key: "mode", text: "Build (sandboxed in project dir, alt+m)  Network: filtered (alt+n)")])
        #expect(ui.aboveEditor.map(\.lines) == [["TODO", "[x] status chips", "[ ] widgets"]])
        #expect(ui.belowEditor.map(\.key) == ["hint"])
        #expect(s.subtitle(fallback: "project") == "pi - fake project")
        #expect(s.title == "show widgets")
        try await s.send("clear widgets")
        try await waitFor("the clear") { lastAssistantText(s) == "Echo: clear widgets" && !s.isStreaming }
        #expect(s.transcript.extensionUI.statuses.map(\.key) == ["fake", "mode"])
        #expect(s.transcript.extensionUI.widgets.map(\.key) == ["todo"])
        let path = try #require(s.path)
        s.leave()

        // Another client on the same pi gets it from pocketpi's hello.
        let again = ChatSession(client: client, path: path, cwd: projectDir)
        await again.start()
        try await waitFor("the replay") { again.transcript.extensionUI.widgets.map(\.key) == ["todo"] }
        #expect(again.transcript.extensionUI.statuses.map(\.key) == ["fake", "mode"])
        #expect(again.transcript.extensionUI.title == "pi - fake project")

        // A new pi on the same file starts with none of it.
        let key = try #require(again.key)
        _ = try await client.restart(key: key)
        try await waitFor("the reset") { again.status == .connected && again.transcript.extensionUI.title == nil }
        #expect(again.transcript.extensionUI.isEmpty)
        again.leave()
    }

    @Test func dialogsWithATimeoutCloseByThemselves() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("timeout please")
        try await waitFor("the dialog") { s.pendingRequest != nil }
        let r = try #require(s.pendingRequest)
        #expect(r.timeout == 1.5)
        #expect(r.countdown() != nil)
        // Nobody answers: the sheet goes and pi resolves it itself.
        try await waitFor("the dialog to close", timeout: 4) { s.pendingRequest == nil }
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: timeout please · timed out" }
        s.leave()
    }

    @Test func stopsAndRenames() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("be slow")
        try await waitFor("streaming") { s.isStreaming }
        await s.stop()
        try await waitFor("the stop") { !s.isStreaming }
        #expect(lastAssistantText(s) == "Stopped")
        await s.rename("Renamed")
        try await waitFor("the name") { s.title == "Renamed" }
        s.leave()
    }

    @Test func renamesFromTheList() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("hello")
        try await waitFor("the reply") { !s.isStreaming && lastAssistantText(s) != nil }
        let key = try #require(s.key)
        s.leave()
        try await client.close(key: key)
        var info: SessionInfo?
        for _ in 0..<40 {
            info = try await client.sessions().first { $0.path == s.path && !$0.live }
            if info != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let closed = try #require(info)
        try await client.renameSession(closed, to: "From the list")
        var named: SessionInfo?
        for _ in 0..<40 {
            named = try await client.sessions().first { $0.path == closed.path }
            if named?.displayTitle == "From the list", named?.live == false { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(named?.displayTitle == "From the list")
        #expect(named?.live == false)
    }

    @Test func archivesAndUnarchives() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("archive me")
        try await waitFor("the reply") { !s.isStreaming && lastAssistantText(s) != nil }
        s.leave()
        let path = try #require(s.path)
        let before = try await client.projects().projects.first { $0.path == projectDir }?.chats ?? 0
        try await client.archiveSession(path: path)
        #expect(try await !client.sessions().contains { $0.path == path })
        #expect(try await client.archivedSessions().contains { $0.path == path })
        let during = try await client.projects().projects.first { $0.path == projectDir }?.chats ?? 0
        #expect(during == before - 1)
        try await client.archiveSession(path: path, archived: false)
        #expect(try await client.sessions().contains { $0.path == path })
        #expect(try await !client.archivedSessions().contains { $0.path == path })
        await #expect(throws: PocketPiError.self) {
            try await client.archiveSession(path: "/etc/passwd")
        }
    }

    @Test func picksAModel() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        await s.prepare()
        try await waitFor("the models") { !s.models.isEmpty }
        #expect(s.models.filter { $0.provider != "llama.cpp" }.count == 3)
        #expect(s.currentModel?.id == "echo-1")
        #expect(s.thinkingLevels.count == 4)
        let mini = try #require(s.models.first { $0.id == "echo-mini" })
        #expect(mini.label == "Echo Mini")
        await s.setModel(mini)
        #expect(s.currentModel?.id == "echo-mini")
        // ios/test-linux.sh writes enabledModels ["other/glm-5.2", "fake/echo-*"].
        #expect(s.favorites.map(\.key) == ["other/glm-5.2", "fake/echo-1", "fake/echo-mini"])
        #expect(s.thinkingLevels == ["off"])
        #expect(s.problem == nil)
        s.leave()
    }

    @Test func offersSlashCommands() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        #expect(s.slashMatches.isEmpty)
        s.composer = "/fix"
        await s.composerChanged()
        #expect(s.commands?.count == 3)
        #expect(s.slashMatches.map(\.name) == ["fix-tests"])
        #expect(s.slashMatches.first?.description == "Fix failing tests")
        s.pick(s.slashMatches[0])
        #expect(s.composer == "/fix-tests ")
        #expect(s.slashMatches.isEmpty)
        s.composer = "/"
        #expect(s.slashMatches.map(\.name) == ["fix-tests", "skill:review", "workflows"])
        s.leave()
    }

    @Test func chatTabChatsStayOutOfWork() async throws {
        let list = try await client.chats()
        #expect(!list.chatDir.isEmpty)
        let s = ChatSession(client: client, newIn: list.chatDir)
        try await s.send("hello from the chat tab")
        try await waitFor("the reply") { lastAssistantText(s)?.contains("hello from the chat tab") == true }
        try await waitFor("the session file") { s.path != nil }
        let chats = try await client.chats().sessions.map(\.path)
        let work = try await client.sessions().map(\.path)
        #expect(chats.contains(s.path!))
        #expect(!work.contains(s.path!))
        #expect(try await client.projects().projects.allSatisfy { $0.path != list.chatDir })
        // Renamed from the Chat tab's list: still a Chat-tab chat.
        let key = try #require(s.key)
        s.leave()
        try await client.close(key: key)
        var row: SessionInfo?
        for _ in 0..<40 {
            row = try await client.chats().sessions.first { $0.path == s.path && !$0.live }
            if row != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await client.renameSession(try #require(row), to: "Sourdough")
        var named: SessionInfo?
        for _ in 0..<40 {
            named = try await client.chats().sessions.first { $0.path == s.path }
            if named?.displayTitle == "Sourdough" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(named?.displayTitle == "Sourdough")
        #expect(try await !client.sessions().contains { $0.path == s.path })
    }

    @Test func deletesOnlyArchivedChats() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("delete me later")
        try await waitFor("the reply") { !s.isStreaming && lastAssistantText(s) != nil }
        try await waitFor("the session file") { s.path != nil }
        let path = try #require(s.path)
        s.leave()
        // Not archived: refused, and the file stays.
        await #expect(throws: PocketPiError.self) { try await client.deleteSession(path: path) }
        #expect(try await client.sessions().contains { $0.path == path })
        // Archived, its pi still up from a moment ago: stopped, then deleted.
        try await client.archiveSession(path: path)
        try await client.deleteSession(path: path)
        #expect(try await !client.archivedSessions().contains { $0.path == path })
        #expect(try await !client.sessions().contains { $0.path == path })
        await #expect(throws: PocketPiError.self) { try await client.open(path: path) }
    }

    @Test func loadsALocalModel() async throws {
        let router = try await client.llama()
        #expect(router.available)
        #expect(router.models.map(\.id).sorted() == ["broken", "other-chat", "tiny-chat"])
        let s = ChatSession(client: client, newIn: projectDir)
        await s.prepare()
        try await waitFor("the models") { !s.models.isEmpty }
        await s.refreshLlama()
        #expect(s.models.contains { $0.key == "llama.cpp/tiny-chat" })
        #expect(!s.models.contains { $0.key == "llama.cpp/other-chat" })

        // Unloaded: loaded on the router (the other one unloaded), pi restarted to see it.
        let other = try #require(s.llama?.models.first { $0.id == "other-chat" })
        await s.useLocal(other)
        #expect(s.problem == nil)
        #expect(s.currentModel?.key == "llama.cpp/other-chat")
        #expect(s.loadingLocal == nil)
        let after = try await client.llama().models
        #expect(after.first { $0.id == "other-chat" }?.status == "loaded")
        #expect(after.first { $0.id == "tiny-chat" }?.status == "unloaded")

        // The chat still works on the new pi.
        try await s.send("after the switch")
        try await waitFor("the reply") { lastAssistantText(s)?.contains("after the switch") == true }

        // A model that fails to load says so and leaves the model alone.
        let broken = try #require(after.first { $0.id == "broken" })
        await s.useLocal(broken)
        #expect(s.problem?.contains("broken") == true)
        #expect(s.currentModel?.key == "llama.cpp/other-chat")
        s.leave()
    }

    @Test func answersApprovals() async throws {
        // ios/test-linux.sh writes the "approve-test" workflow: shell, approval, shell.
        for approve in [true, false] {
            let started: JSONValue = try await client.post("/api/workflows/approve-test/run", [:])
            let id = try #require(started["run_id"]?.string)
            var run: RunInfo?
            for _ in 0..<50 {
                run = try await client.runs().first { $0.id == id }
                if run?.waitingApproval != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let stage = try #require(run?.waitingApproval)
            #expect(stage.prompt == "Ship it?")
            #expect(run?.workflowName == "Approve test")
            try await client.answer(run: id, stage: stage.id, approve: approve)
            for _ in 0..<50 {
                run = try await client.runs().first { $0.id == id }
                if run?.status == "succeeded" || run?.status == "failed" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(run?.status == (approve ? "succeeded" : "failed"))
        }
        await #expect(throws: PocketPiError.self) {
            try await client.answer(run: "nope", stage: "ask", approve: true)
        }
    }

    @Test func startsRunsAndRefusesDuplicates() async throws {
        // ios/test-linux.sh writes "slow-test": one shell stage that sleeps {{input.wait}}.
        let w = try #require(try await client.workflows().first { $0.id == "slow-test" })
        #expect(w.inputs.map(\.name) == ["issue", "wait"])
        #expect(w.triggers == ["every 30 minutes"])
        #expect(!w.enabled)

        let issue = String(Int.random(in: 1000...9999))
        guard case .started(let first) = try await client.start(workflow: "slow-test", inputs: ["issue": issue]) else {
            Issue.record("first run didn't start"); return
        }
        var run = try await client.run(id: first)
        for _ in 0..<50 where run.isActive {
            try await Task.sleep(for: .milliseconds(100))
            run = try await client.run(id: first)
        }
        #expect(run.status == "succeeded")
        #expect(run.stages.first?.output.contains("rested for issue \(issue)") == true)
        #expect(run.inputs["issue"] == issue)

        // The same issue again: refused, unless forced.
        let again = try await client.start(workflow: "slow-test", inputs: ["issue": issue])
        guard case .duplicate(let dup, let message) = again else { Issue.record("not refused: \(again)"); return }
        #expect(dup == first && !message.isEmpty)
        guard case .started(let forced) = try await client.start(workflow: "slow-test", inputs: ["issue": issue, "wait": "30"], force: true) else {
            Issue.record("forced run didn't start"); return
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await client.run(id: forced).isActive)
        try await client.cancel(run: forced)
        run = try await client.run(id: forced)
        for _ in 0..<50 where run.isActive {
            try await Task.sleep(for: .milliseconds(100))
            run = try await client.run(id: forced)
        }
        #expect(run.status == "cancelled")
        #expect(try await client.runs(workflow: "slow-test").map(\.id).contains(forced))

        try await client.setEnabled(workflow: "slow-test", true)
        #expect(try await client.workflows().first { $0.id == "slow-test" }?.enabled == true)
        try await client.setEnabled(workflow: "slow-test", false)
    }

    @Test func improvesAndReverts() async throws {
        // ios/test-linux.sh writes a suggested improvement for slow-test.
        var d = try await client.workflow(id: "slow-test")
        let p = try #require(d.proposal)
        #expect(p.changes.first?.summary == "Clearer description")
        #expect(!d.proposalDiff.isEmpty)
        let before = d.info.description
        try await client.applyProposal(workflow: "slow-test")
        d = try await client.workflow(id: "slow-test")
        #expect(d.proposal == nil)
        #expect(d.info.description == "Waits, so a run can be cancelled.")
        let version = try #require(d.history.first)
        try await client.revert(workflow: "slow-test", version: version.version)
        #expect(try await client.workflow(id: "slow-test").info.description == before)

        try await client.setImprove(workflow: "slow-test", mode: "auto")
        #expect(try await client.workflow(id: "slow-test").info.improve == "auto")
        try await client.setImprove(workflow: "slow-test", mode: "off")

        try await client.deleteWorkflow("delete-me")
        #expect(try await client.workflows().contains { $0.id == "delete-me" } == false)
        // Dismissing with nothing suggested is allowed and changes nothing.
        try await client.dismissProposal(workflow: "slow-test")
    }

    @Test func reopensWhenPiIsGone() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("first")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: first" && s.path != nil && !s.isStreaming }
        // pi exits (as when pocketpi reaps it); the next send must reopen the file.
        try await client.close(key: try #require(s.key))
        try await waitFor("the exit") { s.key == nil }
        try await s.send("second")
        try await waitFor("the second reply") { lastAssistantText(s) == "Echo: second" && !s.isStreaming }
        #expect(s.transcript.items.count == 4)
        s.leave()
    }

    // MARK: - pi config, restart, reload, control

    @Test func readsAndPatchesSettingsKeepingOtherKeys() async throws {
        let before = try await client.config(.settings)
        #expect(before.scope == "global")
        #expect(before.data["enabledModels"]?.array?.count == 2)
        let doc = try await client.patchConfig(.settings, PiConfigPatch(set: [
            "compaction.enabled": false,
            PiConfigPatch.path("modelThinkingLevels", "other/glm-5.2"): "high",
        ]))
        #expect(doc.epoch > before.epoch)
        #expect(doc.data["compaction"]?["enabled"]?.bool == false)
        #expect(doc.data["modelThinkingLevels"]?["other/glm-5.2"]?.string == "high")
        // Untouched keys survive (the other tests need enabledModels).
        #expect(doc.data["enabledModels"] == before.data["enabledModels"])
        let after = try await client.patchConfig(.settings, PiConfigPatch(unset: ["compaction", "modelThinkingLevels"]))
        #expect(after.data == before.data)
        // Project settings live in the project.
        let project = try await client.patchConfig(.settings, PiConfigPatch(set: ["defaultThinkingLevel": "low"]), cwd: projectDir)
        #expect(project.scope == "project")
        #expect(project.path.hasSuffix("/.pi/settings.json"))
        #expect(try await client.config(.settings).data["defaultThinkingLevel"] == nil)
        _ = try await client.patchConfig(.settings, PiConfigPatch(unset: ["defaultThinkingLevel"]), cwd: projectDir)
        // A path through a non-object is refused.
        await #expect(throws: PocketPiError.self) {
            try await client.patchConfig(.settings, PiConfigPatch(set: ["enabledModels.x": 1]))
        }
    }

    @Test func neverReturnsCredentials() async throws {
        let doc = try await client.patchConfig(.auth, PiConfigPatch(set: ["fakeprov": ["type": "api_key", "key": "sk-test-secret"]]))
        let raw = String(decoding: try doc.data.encoded(), as: UTF8.self)
        #expect(!raw.contains("sk-test-secret"))
        #expect(!raw.contains("LLAMA_BASE_URL"))
        let providers = Dictionary(uniqueKeysWithValues: doc.authProviders.map { ($0.provider, $0) })
        #expect(providers["fakeprov"]?.hasKey == true)
        #expect(providers["fakeprov"]?.type == "api_key")
        #expect(providers["llama.cpp"] != nil)
        // The redaction marker can't be written back over a secret.
        await #expect(throws: PocketPiError.self) {
            try await client.patchConfig(.auth, PiConfigPatch(set: ["fakeprov.key": "<redacted>"]))
        }
        let back = try await client.patchConfig(.auth, PiConfigPatch(unset: ["fakeprov"]))
        #expect(!back.authProviders.contains { $0.provider == "fakeprov" })
        #expect(back.authProviders.contains { $0.provider == "llama.cpp" })
        // Other secrets: models.json values under credential-looking keys.
        let models = try await client.patchConfig(.models, PiConfigPatch(set: ["providers.mine": ["baseUrl": "http://h", "apiKey": "sk-model-secret"]]))
        #expect(models.data["providers"]?["mine"]?["apiKey"]?.string == "<redacted>")
        #expect(models.data["providers"]?["mine"]?["baseUrl"]?.string == "http://h")
        _ = try await client.patchConfig(.models, PiConfigPatch(unset: ["providers.mine"]))
    }

    @Test func restartKeepsTheKeyAndTranscript() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("before restart")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: before restart" && s.path != nil && !s.isStreaming }
        let key = try #require(s.key)
        let path = s.path
        let r = try await client.restart(key: key)
        #expect(r.key == key)
        #expect(r.file == path)
        try await waitFor("the reconnect") { s.status == .connected && s.key == key && s.transcript.items.count == 2 }
        try await s.send("after restart")
        try await waitFor("the next reply") { lastAssistantText(s) == "Echo: after restart" && !s.isStreaming }
        #expect(s.key == key)
        #expect(s.path == path)
        #expect(s.transcript.items.count == 4)
        s.leave()
    }

    @Test func reloadRestartsStaleIdleChats() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("reload me")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: reload me" && !s.isStreaming }
        let key = try #require(s.key)
        _ = try await client.patchConfig(.settings, PiConfigPatch(set: ["retry.maxRetries": 4]))
        let status = try await client.piStatus()
        #expect(status.control)
        #expect(status.live.first { $0.key == key }?.stale == true)
        #expect(try await client.sessions().first { $0.path == s.path }.map { ($0.epoch ?? 0) < status.configEpoch } == true)
        let r = try await client.reload()
        #expect(r.restarted.contains(key))
        #expect(r.failed.isEmpty)
        try await waitFor("the reconnect", timeout: 15) { s.status == .connected && !s.needsRestart && s.transcript.items.count == 2 }
        #expect(try await client.piStatus().live.first { $0.key == key }?.stale == false)
        _ = try await client.patchConfig(.settings, PiConfigPatch(unset: ["retry"]))
        s.leave()
    }

    @Test func settingsHubSeesAChangeAndApplies() async throws {
        let hub = SettingsHub(client: client)
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("hub")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: hub" && !s.isStreaming }
        let key = try #require(s.key)
        await hub.refresh()
        #expect(!hub.needsRestart(s))
        _ = try await client.patchConfig(.settings, PiConfigPatch(set: ["retry.maxRetries": 5]))
        // The open chat's hello predates the change; only the hub's status knows.
        #expect(!s.needsRestart)
        await hub.changed()
        #expect(hub.needsRestart(s))
        #expect(hub.staleChats.contains { $0.key == key })
        #expect(hub.bannerText != nil)
        let r = try #require(await hub.reload())
        #expect(r.restarted.contains(key))
        #expect(!hub.staleChats.contains { $0.key == key })
        try await waitFor("the reconnect", timeout: 15) { s.status == .connected && s.transcript.items.count == 2 }
        #expect(!hub.needsRestart(s))
        _ = try await client.patchConfig(.settings, PiConfigPatch(unset: ["retry"]))
        s.leave()
    }

    @Test func forkMovesTheChatToTheNewFile() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("one")
        try await waitFor("the first reply") { lastAssistantText(s) == "Echo: one" && s.path != nil && !s.isStreaming }
        try await s.send("two")
        try await waitFor("the second reply") { lastAssistantText(s) == "Echo: two" && !s.isStreaming }
        let key = try #require(s.key)
        let old = try #require(s.path)
        let forks = try await client.command(key: key, ["type": "get_fork_messages"])["messages"]?.array ?? []
        #expect(forks.compactMap { $0["text"]?.string } == ["one", "two"])
        let entry = try #require(forks.last?["entryId"])
        let r = try await client.command(key: key, ["type": "fork", "entryId": entry])
        #expect(r["text"]?.string == "two")
        try await waitFor("the new session file") { s.path != nil && s.path != old }
        let state = try await client.command(key: key, ["type": "get_state"])
        #expect(state["sessionFile"]?.string == s.path)
        #expect(try await client.piStatus().live.first { $0.key == key }?.file == s.path)
        s.leave()
    }

    @Test func forkFromAMessagePutsItBackInTheComposer() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        for (i, p) in ["first", "again", "again"].enumerated() {
            try await s.send(p)
            try await waitFor("the reply to prompt \(i)") {
                s.transcript.userMessages.count == i + 1 && lastAssistantText(s) == "Echo: \(p)" && s.path != nil && !s.isStreaming
            }
        }
        let old = try #require(s.path)
        // The second "again": the mapping must pick the right one of the two.
        let target = try #require(s.transcript.items.first { $0.id == s.transcript.userMessages[1].id })
        #expect(s.transcript.canFork(target))
        #expect(await s.fork(at: target))
        #expect(s.problem == nil)
        #expect(s.composer == "again")
        // ...and the keyboard comes up for it.
        #expect(s.composerFocusRequests == 1)
        #expect(s.path != nil && s.path != old)
        #expect(s.transcript.userMessages.map { ForkMap.text(of: $0.message) } == ["first"])
        let list = try await client.sessions()
        let forked = try #require(list.first { $0.path == s.path })
        #expect(forked.parent == old)
        #expect(forked.forkHint(in: list)?.hasPrefix("Forked from") == true)
        // The original is untouched.
        #expect(list.first { $0.path == old }?.messages == 6)
        // And the chat carries on in the new file.
        try await s.send("next")
        try await waitFor("the reply in the fork") { lastAssistantText(s) == "Echo: next" && !s.isStreaming }
        #expect(try await client.sessions().first { $0.path == s.path }?.messages == 4)
        s.leave()
    }

    @Test func forkFromTheFirstMessageStartsANewChat() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("only")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: only" && s.path != nil && !s.isStreaming }
        let old = try #require(s.path)
        let first = try #require(s.transcript.items.first)
        #expect(await s.fork(at: first))
        #expect(s.composer == "only")
        #expect(s.transcript.items.isEmpty)
        // pi picked a file it writes with the next message.
        #expect(s.path == nil)
        try await s.send("redo")
        try await waitFor("the reply in the fork") { lastAssistantText(s) == "Echo: redo" && s.path != nil && !s.isStreaming }
        #expect(s.path != old)
        #expect(try await client.sessions().first { $0.path == s.path }?.parent == old)
        s.leave()
    }

    @Test func cancelledForkAndCloneLeaveTheChat() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("no-fork please")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: no-fork please" && s.path != nil && !s.isStreaming }
        let old = s.path
        let first = try #require(s.transcript.items.first)
        #expect(await s.fork(at: first) == false)
        #expect(s.problem != nil)
        s.problem = nil
        #expect(await s.clone() == false)
        #expect(s.problem != nil)
        #expect(s.path == old)
        #expect(s.composer.isEmpty)
        s.leave()
    }

    @Test func cloneCopiesTheChat() async throws {
        let s = ChatSession(client: client, newIn: projectDir)
        try await s.send("copy me")
        try await waitFor("the reply") { lastAssistantText(s) == "Echo: copy me" && s.path != nil && !s.isStreaming }
        let old = try #require(s.path)
        let before = s.transcript.items.count
        #expect(await s.clone())
        #expect(s.path != nil && s.path != old)
        #expect(s.transcript.items.count == before)
        let list = try await client.sessions()
        #expect(list.first { $0.path == s.path }?.parent == old)
        #expect(list.first { $0.path == s.path }?.messages == list.first { $0.path == old }?.messages)
        s.leave()
    }

    @Test func controlRoundTrip() async throws {
        let key = try await client.newChat(cwd: projectDir).key
        let tools = try await client.tools(key: key)
        #expect(tools.map(\.name).contains("bash"))
        #expect(tools.filter(\.active).map(\.name) == ["read", "bash", "edit", "write"])
        let after = try await client.setActiveTools(key: key, ["read"])
        #expect(after.filter(\.active).map(\.name) == ["read"])
        await #expect(throws: PocketPiError.command("unknown tools: nope")) {
            try await client.setActiveTools(key: key, ["nope"])
        }
        // The extension's commands are pocketpi's, not the person's.
        let commands = try await client.command(key: key, ["type": "get_commands"])["commands"]?.array ?? []
        #expect(!commands.contains { $0["name"]?.string?.hasPrefix("pp-") == true })
        await #expect(throws: PocketPiError.self) {
            try await client.command(key: key, ["type": "prompt", "message": "/pp-tools x"])
        }
        // Never allowed: commands that would move pi off its session file.
        for t in ["new_session", "switch_session", "cycle_model"] {
            await #expect(throws: PocketPiError.self) { try await client.command(key: key, ["type": .string(t)]) }
        }
        try await client.close(key: key)
    }

    @Test func runsPiCLI() async throws {
        // fake-pi answers any CLI call like an RPC session would not; only
        // the plumbing is checked here (real pi was checked by hand).
        let id = try await client.startJob(.list())
        var job = try await client.job(id: id)
        for _ in 0..<40 where job.isRunning {
            try await Task.sleep(for: .milliseconds(100))
            job = try await client.job(id: id)
        }
        #expect(!job.isRunning)
        #expect(job.argv == ["list"])
        #expect(try await client.jobs().contains { $0.id == id })
        await #expect(throws: PocketPiError.self) { _ = try await client.startJob(.install(source: "--evil")) }
    }

    // MARK: trust and resources (test-linux.sh seeds the scratch HOME)

    @Test func trustToggleRoundTrip() async throws {
        try await client.saveProject(path: projectDir)
        var o = try await client.trustOverview()
        var p = try #require(o.projects.first { $0.path == projectDir })
        #expect(p.needsTrust)
        #expect(p.protected.contains(".pi/prompts"))
        #expect(p.decision == nil && !p.trusted)
        #expect(o.defaultTrust == .ask)
        let epoch = try await client.piStatus().configEpoch

        // The scratch path has a dot in it (mktemp): the key must be escaped.
        let doc = try await client.setTrust(.trust, for: p.canonical)
        #expect(doc.data[p.canonical]?.bool == true)
        #expect(try await client.piStatus().configEpoch > epoch)
        o = try await client.trustOverview()
        p = try #require(o.projects.first { $0.path == projectDir })
        #expect(p.choice == .trust && p.trusted && p.explicit)
        #expect(o.entries[p.canonical] == true)

        try await client.setTrust(.distrust, for: p.canonical)
        p = try #require(try await client.trustOverview().projects.first { $0.path == projectDir })
        #expect(p.choice == .distrust && !p.trusted)

        try await client.setTrust(.none, for: p.canonical)
        try await client.setDefaultProjectTrust(.always)
        o = try await client.trustOverview()
        p = try #require(o.projects.first { $0.path == projectDir })
        #expect(o.defaultTrust == .always)
        #expect(p.choice == .none && p.decision == nil && p.trusted)
        #expect(o.entries[p.canonical] == nil)
        try await client.setDefaultProjectTrust(.ask)
        #expect(try await client.trustOverview().defaultTrust == .ask)
    }

    @Test func listsResources() async throws {
        var r = try await client.resources(cwd: projectDir)
        let names = { (k: PiResourceKind) in r.list(k).map(\.name) }
        #expect(names(.skill).contains("review"))
        #expect(names(.extensionFile).contains("hello"))
        #expect(Set(names(.extensionFile)).isSuperset(of: ["mcp", "llama.cpp", "codemode", "tool-search"]))
        let review = try #require(r.list(.skill).first { $0.name == "review" })
        #expect(review.description == "Review the staged diff")
        #expect(review.scope == .global && review.loads)
        let fix = try #require(r.list(.prompt).first { $0.name == "fix-tests" })
        #expect(fix.argumentHint == "<file>")
        #expect(fix.toggle?.entry == "prompts/fix-tests.md")
        // The project's own prompt is skipped until the project is trusted.
        var deploy = try #require(r.list(.prompt).first { $0.name == "deploy" })
        #expect(deploy.scope == .project && !deploy.loads && deploy.skipped == "project not trusted")
        #expect(r.untrustedWarning != nil)
        // Global only: no project resources.
        let global = try await client.resources()
        #expect(global.cwd == nil && !global.resources.contains { $0.name == "deploy" })

        let canonical = try #require(r.trust?.canonical)
        try await client.setTrust(.trust, for: canonical)
        // A chat open in the project: what its pi reports is marked running.
        let chat = try await client.newChat(cwd: projectDir)
        r = try await client.resources(cwd: projectDir)
        deploy = try #require(r.list(.prompt).first { $0.name == "deploy" })
        #expect(deploy.loads && r.untrustedWarning == nil)
        #expect(r.liveCommands != nil)
        #expect(r.list(.prompt).first { $0.name == "fix-tests" }?.live == true)
        #expect(r.list(.skill).first { $0.name == "review" }?.live == true)
        #expect(r.list(.extensionFile).contains { $0.name == "pocketpi-workflows" && $0.scope == .temporary })
        #expect(!r.resources.contains { $0.commands.contains("pp-tools") })
        try await client.close(key: chat.key)
        try await client.setTrust(.none, for: canonical)
    }
}
