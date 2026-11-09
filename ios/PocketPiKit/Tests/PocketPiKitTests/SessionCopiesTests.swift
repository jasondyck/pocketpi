import Foundation
import Testing
@testable import PocketPiKit

// The chat screen copies the transcript's small parts (whether pi is
// streaming, the queue, retry, the extension statuses and widgets, the runs
// pi started) into the session. The composer, toolbar and docks read the
// copies, so a streamed token doesn't redraw them — redrawing them on every
// token made the chat above them shift while pi thought. These check the
// copies stay in step with the transcript.
@MainActor
@Suite struct SessionCopiesTests {
    private func ev(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    private func session() -> ChatSession {
        ChatSession(client: PocketPiClient(server: try! ServerAddress(parsing: "http://127.0.0.1:9")),
                    newIn: "/tmp")
    }

    @Test func streamingAndTheQueueFollowTheTranscript() async {
        let s = session()
        #expect(!s.isStreaming)
        await s.handle(ev(#"{"type":"agent_start"}"#))
        #expect(s.isStreaming && s.transcript.isStreaming)

        await s.handle(ev(#"{"type":"queue_update","steering":["go on"],"followUp":["then this"]}"#))
        #expect(s.steering == ["go on"] && s.steering == s.transcript.steering)
        #expect(s.followUp == ["then this"] && s.followUp == s.transcript.followUp)

        await s.handle(ev(#"{"type":"auto_retry_start","attempt":2,"maxAttempts":3,"delayMs":1500,"errorMessage":"529"}"#))
        #expect(s.retry == s.transcript.retry && s.retry?.attempt == 2)
        await s.handle(ev(#"{"type":"auto_retry_end","success":true}"#))
        #expect(s.retry == nil)

        await s.handle(ev(#"{"type":"agent_settled"}"#))
        #expect(!s.isStreaming && !s.transcript.isStreaming)
    }

    @Test func extensionsAndTitlesReadTheCopy() async {
        let s = session()
        await s.handle(ev(#"{"type":"extension_ui_request","id":"1","method":"setStatus","statusKey":"pp-lint","statusText":"2 warnings"}"#))
        #expect(!s.extensionUI.isEmpty && s.extensionUI == s.transcript.extensionUI)

        await s.handle(ev(#"{"type":"extension_ui_request","id":"2","method":"setTitle","title":"A chat"}"#))
        #expect(s.subtitle(fallback: "project") == "A chat")

        await s.handle(ev(#"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Fix the thing"}]}}"#))
        #expect(s.title == "Fix the thing")
        #expect(s.extensionUI == s.transcript.extensionUI)
    }

    @Test func bashRunningComesFromTheCopy() async {
        let s = session()
        await s.handle(ev(#"{"type":"bash_execution_update","delta":"hi\n"}"#))
        #expect(s.bashRunning && s.bashRunning == s.transcript.bashRunning)
        #expect(s.composerHint == "A shell command is running")
        // A turn settling (here: the next agent_start) ends a command no one
        // answered.
        await s.handle(ev(#"{"type":"agent_start"}"#))
        #expect(!s.bashRunning)
    }

    @Test func startedRunsFollowTheTranscript() async {
        let s = session()
        await s.handle(ev(#"{"type":"tool_execution_end","toolCallId":"w1","toolName":"workflow_run","result":{"content":[{"type":"text","text":"Started."}],"details":{"run_id":"1794236171347-ab"}},"isError":false}"#))
        #expect(s.startedRuns == ["1794236171347-ab"] && s.startedRuns == s.transcript.startedRuns)
    }
}

extension SessionCopiesTests {
    @Test func revisionBumpsAndSpotsASentMessage() async {
        let s = session()
        let start = s.transcriptRevision
        await s.handle(ev(#"{"type":"agent_start"}"#))
        #expect(s.transcriptRevision.number > start.number)
        #expect(!s.transcriptRevision.sentMessage(since: start))

        let beforeSend = s.transcriptRevision
        await s.handle(ev(#"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#))
        #expect(s.transcriptRevision.sentMessage(since: beforeSend))
    }
}
