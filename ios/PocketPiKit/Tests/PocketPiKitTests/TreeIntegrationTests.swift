import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// The session tree, /pp-goto, /pp-label and session info, against a scratch
/// pocketpi running ios/fake-pi.py (ios/test-linux.sh). Skipped without
/// POCKETPI_TEST_URL.
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
private func lastReply(_ s: ChatSession) -> String? {
    for item in s.transcript.items.reversed() {
        if case .assistant(let m, false) = item.kind, let t = m.content.compactMap(\.text).last { return t }
    }
    return nil
}

@MainActor
private func prompts(_ s: ChatSession) -> [String] {
    s.transcript.userMessages.map { ForkMap.text(of: $0.message) }
}

@Suite(.serialized, .enabled(if: serverURL != nil))
@MainActor
struct TreeIntegrationTests {
    let client = PocketPiClient(server: ServerAddress(url: URL(string: serverURL ?? "http://127.0.0.1:1")!))

    private func chat(_ texts: [String]) async throws -> ChatSession {
        let s = ChatSession(client: client, newIn: projectDir)
        for (i, p) in texts.enumerated() {
            try await s.send(p)
            try await waitFor("reply \(i)") { prompts(s).count == i + 1 && lastReply(s) == "Echo: \(p)" && s.path != nil && !s.isStreaming }
        }
        return s
    }

    @Test func gotoAPromptPutsItBackAndBranches() async throws {
        let s = try await chat(["one", "two"])
        let file = s.path
        var tree = try await s.loadTree()
        #expect(tree.rows.map(\.kind) == [.user, .assistant, .user, .assistant])
        let two = try #require(tree.rows.first { $0.text == "two" })
        #expect(await s.goto(two))
        #expect(s.problem == nil)
        #expect(s.composer == "two")
        #expect(s.composerFocusRequests == 1)
        // Same file, back before "two".
        #expect(s.path == file)
        #expect(prompts(s) == ["one"])
        // A new prompt makes a second branch.
        try await s.send("three")
        try await waitFor("the reply on the new branch") { lastReply(s) == "Echo: three" && !s.isStreaming }
        tree = try await s.loadTree()
        #expect(tree.branches == 2)
        #expect(tree.rows.map(\.text).contains("two"))
        #expect(tree.rows.first { $0.text == "three" }?.onPath == true)
        #expect(tree.rows.first { $0.text == "two" }?.onPath == false)
        #expect(tree.rows.filter(\.branchStart).count == 2)
        // pocketpi-control's reply entries never show.
        #expect(tree.rows.allSatisfy { !$0.text.contains("reqId") })
        // Back to the end of the first branch: an assistant row, nothing to refill.
        s.composer = ""
        let end = try #require(tree.rows.last { $0.kind == .assistant && !$0.onPath })
        #expect(await s.goto(end))
        #expect(s.composer.isEmpty)
        #expect(prompts(s) == ["one", "two"])
        #expect(try await s.loadTree().currentId == end.id)
        s.leave()
    }

    @Test func gotoWithASummaryAddsOne() async throws {
        let s = try await chat(["alpha", "beta"])
        let tree = try await s.loadTree()
        let firstReply = try #require(tree.rows.first { $0.kind == .assistant })
        #expect(await s.goto(firstReply, summarize: true, instructions: "keep names"))
        let after = try await s.loadTree()
        let summary = try #require(after.rows.first { $0.kind == .branchSummary })
        #expect(summary.text.contains("keep names"))
        #expect(after.currentId == summary.id)
        // The chat shows it as a branch summary.
        #expect(s.transcript.items.contains { if case .branchSummary(let t) = $0.kind { return t.contains("keep names") }; return false })
        #expect(prompts(s) == ["alpha"])
        s.leave()
    }

    @Test func labelsShowInTheTree() async throws {
        let s = try await chat(["mark me"])
        let row = try #require(try await s.loadTree().rows.first)
        #expect(await s.setLabel(row.id, "start"))
        #expect(try await s.loadTree().row(row.id)?.label == "start")
        #expect(await s.setLabel(row.id, nil))
        #expect(try await s.loadTree().row(row.id)?.label == nil)
        // An unknown entry is the extension's error.
        #expect(await s.setLabel("nope", "x") == false)
        #expect(s.problem?.contains("not found") == true)
        s.leave()
    }

    @Test func cancelledGotoLeavesTheChat() async throws {
        let s = try await chat(["no-goto here", "after"])
        let row = try #require(try await s.loadTree().rows.first)
        #expect(await s.goto(row) == false)
        #expect(s.problem != nil)
        #expect(prompts(s) == ["no-goto here", "after"])
        s.leave()
    }

    @Test func forkAfterMovingPicksThePromptOnTheCurrentBranch() async throws {
        // root ─┬─ x → same   (older)
        //       └─ y → same   (newer)
        // On the older branch, forking at its "same" must keep root and x;
        // matching the newest "same" in the file would keep root and y.
        let s = try await chat(["root", "x", "same"])
        let x = try #require(try await s.loadTree().rows.first { $0.text == "x" })
        #expect(await s.goto(x))
        for (i, p) in ["y", "same"].enumerated() {
            try await s.send(p)
            try await waitFor("reply \(i) on the new branch") { prompts(s).count == i + 2 && lastReply(s) == "Echo: \(p)" && !s.isStreaming }
        }
        #expect(prompts(s) == ["root", "y", "same"])
        let tree = try await s.loadTree()
        let oldEnd = try #require(tree.rows.last { $0.kind == .assistant && !$0.onPath })
        #expect(await s.goto(oldEnd))
        #expect(prompts(s) == ["root", "x", "same"])
        let target = try #require(s.transcript.items.first { $0.id == s.transcript.userMessages[2].id })
        #expect(await s.fork(at: target))
        #expect(s.composer == "same")
        #expect(prompts(s) == ["root", "x"])
        s.leave()
    }

    @Test func sessionInfo() async throws {
        let s = try await chat(["count", "tool please"])
        let info = try await s.loadInfo()
        #expect(info.header.file == s.path)
        #expect(info.header.id?.isEmpty == false)
        #expect(info.header.created != nil)
        #expect(info.summary.roles["user"] == 2)
        #expect(info.summary.roles["toolResult"] == 1)
        #expect(info.summary.toolCalls == 1)
        #expect(info.summary.models.map(\.id) == ["fake/echo-1"])
        #expect(info.summary.models.first?.messages == 3)
        #expect(info.cost != nil)
        // A clone records where it came from.
        let old = s.path
        #expect(await s.clone())
        #expect(try await s.loadInfo().header.parentSession == old)
        s.leave()
    }

    @Test func gotoAndLabelNeedTheExtension() async throws {
        // A Chat-tab pi runs without pocketpi-control.
        let key = try await client.newChat(cwd: try await client.chats().chatDir).key
        await #expect(throws: PocketPiError.self) { _ = try await client.goto(key: key, entryId: "x") }
        await #expect(throws: PocketPiError.self) { try await client.setLabel(key: key, entryId: "x", label: "y") }
        try? await client.close(key: key)
    }
}
