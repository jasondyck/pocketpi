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
