import Foundation
import Testing
@testable import PocketPiKit

@Suite struct ComposerIntentTests {
    @Test func parsesBang() {
        #expect(ComposerIntent("ls -la") == .prompt("ls -la"))
        #expect(ComposerIntent("!ls -la") == .bash(command: "ls -la", excludeFromContext: false))
        #expect(ComposerIntent("  !! git status ") == .bash(command: "git status", excludeFromContext: true))
        #expect(ComposerIntent("!") == .prompt("!"))
        #expect(ComposerIntent("!!") == .prompt("!!"))
        #expect(ComposerIntent("hey!") == .prompt("hey!"))
    }

    @Test func hints() {
        #expect(ComposerIntent("hello").hint(streaming: false) == nil)
        #expect(ComposerIntent("!ls").hint(streaming: false)?.contains("next message") == true)
        #expect(ComposerIntent("!!ls").hint(streaming: false)?.contains("kept out") == true)
        #expect(ComposerIntent("!ls").hint(streaming: true) == "Shell commands run once pi has finished")
    }
}

@Suite struct BashCardTests {
    func ev(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    @Test func streamsThenFinishesLikeTheMessage() {
        var t = Transcript()
        t.beginBash(command: "ls", excludeFromContext: true)
        #expect(t.bashRunning)
        t.apply(ev(#"{"type":"bash_execution_update","id":"pp-1","delta":"a\n"}"#))
        t.apply(ev(#"{"type":"bash_execution_update","id":"pp-1","delta":"b\n"}"#))
        guard case .bash(let live) = t.items.last?.kind else { Issue.record("no card"); return }
        #expect(live.running && live.output == "a\nb\n")
        t.finishBash(ev(#"{"output":"b\n","exitCode":2,"cancelled":false,"truncated":true,"fullOutputPath":"/tmp/x"}"#))
        #expect(!t.bashRunning)
        guard case .bash(let done) = t.items.last?.kind else { Issue.record("no card"); return }
        #expect(!done.running && done.output == "b\n" && done.isError)
        #expect(done.status == "exit 2 · not in context")
        // The same command reloaded from pi's messages renders the same.
        let reloaded = BashRun(message: ev(#"{"role":"bashExecution","command":"ls","output":"b\n","exitCode":2,"cancelled":false,"truncated":true,"fullOutputPath":"/tmp/x","excludeFromContext":true}"#))
        #expect(reloaded == done)
    }

    @Test func cancelledAndFailed() {
        var t = Transcript()
        t.beginBash(command: "sleep 9", excludeFromContext: false)
        t.finishBash(ev(#"{"output":"","cancelled":true,"truncated":false}"#))
        guard case .bash(let c) = t.items.last?.kind else { Issue.record("no card"); return }
        #expect(c.cancelled && !c.isError && c.status == "cancelled")
        t.beginBash(command: "x", excludeFromContext: false)
        t.failBash("pi exited")
        guard case .bash(let f) = t.items.last?.kind else { Issue.record("no card"); return }
        #expect(!f.running && f.isError && f.output == "pi exited")
    }

    @Test func runningCommandSurvivesAReload() {
        var t = Transcript()
        t.load(messages: [["role": "user", "content": "hi"]], isStreaming: false)
        t.beginBash(command: "make", excludeFromContext: false)
        t.load(messages: [["role": "user", "content": "hi"]], isStreaming: false)
        #expect(t.bashRunning && t.items.count == 2)
        t.apply(ev(#"{"type":"bash_execution_update","delta":"ok\n"}"#))
        guard case .bash(let r) = t.items.last?.kind else { Issue.record("no card"); return }
        #expect(r.command == "make" && r.output == "ok\n")
    }

    @Test func anotherClientsCommandGetsACardAndSettles() {
        var t = Transcript()
        t.apply(ev(#"{"type":"bash_execution_update","delta":"x\n"}"#))
        #expect(t.bashRunning)
        t.apply(ev(#"{"type":"agent_start"}"#))
        #expect(!t.bashRunning)
    }
}

@Suite struct RetryTests {
    func ev(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    @Test func countsDownAndClears() {
        var t = Transcript()
        let t0 = Date(timeIntervalSince1970: 1000)
        t.apply(ev(#"{"type":"agent_start"}"#))
        t.apply(ev(#"{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"529 overloaded"}"#), now: t0)
        let r = try! #require(t.retry)
        #expect(r.errorMessage == "529 overloaded")
        #expect(r.line(now: t0) == "Retrying in 2s · attempt 1 of 3")
        #expect(r.line(now: t0 + 1.2) == "Retrying in 1s · attempt 1 of 3")
        #expect(r.line(now: t0 + 5) == "Retrying · attempt 1 of 3")
        t.apply(ev(#"{"type":"auto_retry_end","success":true,"attempt":1}"#))
        #expect(t.retry == nil)
        t.apply(ev(#"{"type":"auto_retry_start","attempt":2,"maxAttempts":3,"delayMs":4000,"errorMessage":"x"}"#), now: t0)
        t.apply(ev(#"{"type":"agent_settled"}"#))
        #expect(t.retry == nil)
    }
}
