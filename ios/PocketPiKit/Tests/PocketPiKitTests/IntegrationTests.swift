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
}
