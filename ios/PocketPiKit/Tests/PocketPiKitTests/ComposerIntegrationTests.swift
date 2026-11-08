import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// The composer against fake-pi: follow-ups, `!cmd` shell commands, and
/// stopping an automatic retry. Part of IntegrationTests (serialized, same
/// scratch server).
private let composerProjectDir = ProcessInfo.processInfo.environment["POCKETPI_TEST_CWD"] ?? ""

@MainActor
private func waitUntil(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > end { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(25))
    }
}

@MainActor
private func bashRuns(_ s: ChatSession) -> [BashRun] {
    s.transcript.items.compactMap { if case .bash(let r) = $0.kind { return r }; return nil }
}

@MainActor
private func userTexts(_ s: ChatSession) -> [String] {
    s.transcript.items.compactMap { if case .user(let m) = $0.kind { return m.plainText }; return nil }
}

extension IntegrationTests {
    @Test func queuesAFollowUpAfterSteering() async throws {
        let s = ChatSession(client: client, newIn: composerProjectDir)
        try await s.send("pause first")
        try await waitUntil("streaming") { s.isStreaming }
        try await s.send("later", delivery: .followUp)
        try await s.send("now")
        try await waitUntil("the queue") { s.transcript.followUp == ["later"] && s.transcript.steering == ["now"] }
        try await waitUntil("all three answered", timeout: 15) {
            !s.isStreaming && userTexts(s) == ["pause first", "now", "later"]
        }
        #expect(s.transcript.followUp.isEmpty && s.transcript.steering.isEmpty)
        s.leave()
    }

    @Test func runsShellCommandsFromTheComposer() async throws {
        let s = ChatSession(client: client, newIn: composerProjectDir)
        try await s.send("hello")
        try await waitUntil("the reply") { !s.isStreaming && s.path != nil }

        s.composer = "!!echo hi"
        #expect(s.composerHint?.contains("kept out") == true)
        try await s.send("!!echo hi")
        try await s.send("! fail now")
        var runs = bashRuns(s)
        #expect(runs.count == 2)
        #expect(runs[0].command == "echo hi" && runs[0].output.hasPrefix("fake: echo hi\n") && runs[0].exitCode == 0)
        #expect(runs[0].excludeFromContext && !runs[0].isError)
        #expect(runs[1].command == "fail now" && runs[1].exitCode == 1 && runs[1].isError)

        // A slow one, stopped while its output streams.
        let running = Task { try await s.send("!slow") }
        try await waitUntil("output") { bashRuns(s).count == 3 && bashRuns(s)[2].output.contains("line 2") }
        #expect(s.transcript.bashRunning && !s.canSendComposer)
        await s.abortBash()
        try await running.value
        runs = bashRuns(s)
        #expect(runs.count == 3 && runs[2].cancelled && !runs[2].running && runs[2].status == "cancelled")

        // Reopened, pi's bashExecution messages render as the live cards did.
        let path = try #require(s.path)
        s.leave()
        let again = ChatSession(client: client, path: path, cwd: composerProjectDir)
        await again.start()
        try await waitUntil("history") { bashRuns(again).count == 3 }
        #expect(bashRuns(again) == runs)
        again.leave()
    }

    @Test func refusesShellCommandsWhileStreaming() async throws {
        let s = ChatSession(client: client, newIn: composerProjectDir)
        try await s.send("be slow")
        try await waitUntil("streaming") { s.isStreaming }
        s.composer = "!ls"
        #expect(!s.canSendComposer && s.composerHint == "Shell commands run once pi has finished")
        await #expect(throws: PocketPiError.self) { try await s.send("!ls") }
        await s.stop()
        try await waitUntil("the stop") { !s.isStreaming }
        s.leave()
    }

    @Test func stopsRetrying() async throws {
        let s = ChatSession(client: client, newIn: composerProjectDir)
        try await s.send("retry please")
        try await waitUntil("the retry") { s.transcript.retry != nil }
        let r = try #require(s.transcript.retry)
        #expect(r.attempt == 1 && r.maxAttempts == 3 && r.errorMessage == "529 overloaded")
        await s.stopRetrying()
        try await waitUntil("the end") { s.transcript.retry == nil && !s.isStreaming }
        #expect(s.transcript.items.contains { $0.kind == .error("Retry cancelled") })
        s.leave()
    }
}
