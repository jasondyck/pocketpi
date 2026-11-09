import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// Subagent runs against a scratch pocketpi with ios/fake-pi.py as pi.
/// test-linux.sh seeds one live workflow run under POCKETPI_SUBAGENTS_DIR.
/// Skipped without POCKETPI_TEST_URL.
private let subagentEnv = ProcessInfo.processInfo.environment
private let subagentServer = subagentEnv["POCKETPI_TEST_URL"]

@Suite(.serialized, .enabled(if: subagentServer != nil))
@MainActor
struct SubagentsIntegrationTests {
    let client = PocketPiClient(server: ServerAddress(url: URL(string: subagentServer ?? "http://127.0.0.1:1")!))

    @Test func listsTheSeededRunAndItsSteps() async throws {
        let s = try await client.subagents(all: true)
        let run = try #require(s.runs.first { $0.id == "pp-test-live" })
        #expect(run.active)
        #expect(run.mode == "workflow")
        #expect(run.title == "Workflow · 2 steps")
        #expect(run.steps.compactMap(\.agent) == ["reviewer", "worker"])
        #expect(run.steps[0].status == "completed")
        #expect(run.steps[1].active)
        #expect(run.steps[1].sessionFile == "/pp-test-child.jsonl")
        #expect(run.steps[1].recentTools == ["read src/main.rs"])
        #expect(run.steps[1].tokens == 300)
    }

    @Test func filtersBySessionFile() async throws {
        let mine = try await client.subagents(session: "/pp-test-session.jsonl")
        #expect(mine.runs.contains { $0.id == "pp-test-live" })
        let other = try await client.subagents(session: "/nobody.jsonl")
        #expect(!other.runs.contains { $0.id == "pp-test-live" })
    }

    @Test func readsOneRunsOutputTail() async throws {
        let d = try await client.subagent(id: "pp-test-live")
        #expect(d.run?.id == "pp-test-live")
        let log = try #require(d.outputs.first { $0.name == "output-0.log" })
        #expect(log.text.contains("hello from the child"))
    }

    @Test func monitorPollsAndCountsActiveRuns() async throws {
        let m = SubagentMonitor(client: client, sessionPath: "/pp-test-session.jsonl")
        await m.refresh()
        #expect(m.activeCount >= 1)
        #expect(m.run(toolCallId: "call_pp_test")?.id == "pp-test-live")
        #expect(m.problem == nil)
        m.stop()
    }
}
