import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// The turn outline: decoding, the request path and finding a turn on screen.
struct OutlineTests {
    @Test func decodesTheServersAnswer() throws {
        let json = #"[{"entryId":"u1","prompt":"Fix the flaky test…","response":"Done."},{"entryId":"u2","prompt":"thanks"}]"#
        let turns = try JSONDecoder().decode([OutlineTurn].self, from: Data(json.utf8))
        #expect(turns == [OutlineTurn(entryId: "u1", prompt: "Fix the flaky test…", response: "Done."),
                          OutlineTurn(entryId: "u2", prompt: "thanks", response: "")])
        #expect(turns.map(\.id) == ["u1", "u2"])
    }

    @Test func pathIsEscaped() {
        let p = PocketPiClient.outlinePath("/home/x/.pi/agent/sessions/--a+b--/2026_x y.jsonl")
        #expect(p == "/api/sessions/outline?path=/home/x/.pi/agent/sessions/--a%2Bb--/2026_x%20y.jsonl")
    }

    @Test func findsTheRowOfATurn() {
        // On screen: the prompts after a compaction ("one" is gone), with a
        // repeated "go on".
        let shown = [(id: 7, text: "go on"), (id: 9, text: "two"), (id: 12, text: "go on")]
        let points = [ForkPoint(entryId: "e1", text: "one"), ForkPoint(entryId: "e2", text: "go on"),
                      ForkPoint(entryId: "e3", text: "two"), ForkPoint(entryId: "e4", text: "go on")]
        #expect(OutlineMap.rowId(for: "e4", shown: shown, points: points) == "i12")
        #expect(OutlineMap.rowId(for: "e2", shown: shown, points: points) == "i7")
        #expect(OutlineMap.rowId(for: "e3", shown: shown, points: points) == "i9")
        #expect(OutlineMap.rowId(for: "e1", shown: shown, points: points) == nil)
        #expect(OutlineMap.rowId(for: "nope", shown: shown, points: points) == nil)
    }

    @Test func rowIdIsTheTranscriptRowId() {
        var t = Transcript()
        t.load(messages: [["role": "user", "content": "hi"], ["role": "assistant", "content": [["type": "text", "text": "hello"]], "stopReason": "stop"]], isStreaming: false)
        let shown = t.userMessages.map { (id: $0.id, text: ForkMap.text(of: $0.message)) }
        let row = OutlineMap.rowId(for: "e1", shown: shown, points: [ForkPoint(entryId: "e1", text: "hi")])
        #expect(row != nil)
        #expect(t.rows.contains { $0.id == row })
    }
}

/// The outline against a scratch pocketpi with ios/fake-pi.py as pi
/// (ios/test-linux.sh). Skipped without POCKETPI_TEST_URL.
private let outlineEnv = ProcessInfo.processInfo.environment
private let outlineServer = outlineEnv["POCKETPI_TEST_URL"]
private let outlineCwd = outlineEnv["POCKETPI_TEST_CWD"] ?? ""

@Suite(.serialized, .enabled(if: outlineServer != nil))
@MainActor
struct OutlineIntegrationTests {
    let client = PocketPiClient(server: ServerAddress(url: URL(string: outlineServer ?? "http://127.0.0.1:1")!))

    private func waitFor(_ what: String, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !cond() {
            if Date() > end { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func lastReply(_ s: ChatSession) -> String? {
        for item in s.transcript.items.reversed() {
            if case .assistant(let m, false) = item.kind, let t = m.content.compactMap(\.text).last { return t }
        }
        return nil
    }

    private func say(_ s: ChatSession, _ text: String) async throws {
        try await s.send(text)
        try await waitFor("the reply to \(text)") { lastReply(s) == "Echo: \(text)" && s.path != nil && !s.isStreaming }
    }

    @Test func outlinesTheActiveBranch() async throws {
        let s = ChatSession(client: client, newIn: outlineCwd)
        try await say(s, "outline first")
        try await say(s, "outline second")
        var turns = try await s.loadOutline()
        #expect(turns.map(\.prompt) == ["outline first", "outline second"])
        #expect(turns.map(\.response) == ["Echo: outline first", "Echo: outline second"])

        // Each line finds its message on screen.
        let second = await s.transcriptRow(forEntry: turns[1].entryId)
        #expect(second == "i\(s.transcript.userMessages[1].id)")
        #expect(s.transcript.rows.contains { $0.id == second })

        // Back before the second prompt and on with another: only the active branch.
        let tree = try await s.loadTree()
        let row = try #require(tree.rows.first { $0.text == "outline second" })
        #expect(await s.goto(row))
        try await say(s, "outline third")
        turns = try await client.outline(path: try #require(s.path))
        #expect(turns.map(\.prompt) == ["outline first", "outline third"])
        s.leave()
    }

    @Test func onlySessionFiles() async throws {
        await #expect(throws: PocketPiError.self) { try await client.outline(path: "/etc/passwd") }
        await #expect(throws: PocketPiError.self) { try await client.outline(path: outlineCwd + "/nope.jsonl") }
    }
}
