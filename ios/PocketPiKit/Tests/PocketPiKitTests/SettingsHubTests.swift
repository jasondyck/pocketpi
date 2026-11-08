import Foundation
import Testing
@testable import PocketPiKit

@MainActor
@Suite struct SettingsHubTests {
    private func hub(_ json: String) throws -> SettingsHub {
        let h = SettingsHub(client: PocketPiClient(server: ServerAddress(url: URL(string: "http://127.0.0.1:1")!)))
        h.status = try JSONDecoder().decode(PiStatus.self, from: Data(json.utf8))
        return h
    }

    @Test func countsStaleChatsButNotStages() throws {
        let h = try hub(#"""
        {"config_epoch":3,"control":true,"live":[
          {"key":"a","cwd":"/p","kind":"chat","streaming":false,"epoch":2,"stale":true},
          {"key":"b","cwd":"/p","kind":"chat_tab","streaming":true,"epoch":1,"stale":true},
          {"key":"c","cwd":"/p","kind":"stage","streaming":true,"epoch":0,"stale":true},
          {"key":"d","cwd":"/p","kind":"chat","streaming":false,"epoch":3,"stale":false}]}
        """#)
        #expect(h.staleChats.map(\.key) == ["a", "b"])
        #expect(h.needsRestart)
        #expect(h.bannerText == "Settings changed. 2 open chats still use the old ones (1 busy).")
    }

    @Test func nothingToSayWhenCurrent() throws {
        let h = try hub(#"{"config_epoch":0,"control":false,"live":[{"key":"a","cwd":"/","kind":"chat","streaming":false,"epoch":0,"stale":false}]}"#)
        #expect(!h.needsRestart)
        #expect(h.bannerText == nil)
        let one = try hub(#"{"config_epoch":1,"control":false,"live":[{"key":"a","cwd":"/","kind":"chat","streaming":false,"epoch":0,"stale":true}]}"#)
        #expect(one.bannerText == "Settings changed. 1 open chat still uses the old ones.")
    }

    @Test func aChatIsBehindByTheNewestEpochs() {
        // Only the hello so far.
        #expect(SettingsHub.isBehind(liveEpoch: nil, helloEpoch: nil, configEpoch: nil, helloConfigEpoch: nil, helloStale: true))
        #expect(!SettingsHub.isBehind(liveEpoch: nil, helloEpoch: nil, configEpoch: nil, helloConfigEpoch: nil, helloStale: false))
        // The poll saw a change after the hello.
        #expect(SettingsHub.isBehind(liveEpoch: 1, helloEpoch: 1, configEpoch: 2, helloConfigEpoch: 1, helloStale: false))
        // Restarted (hello says epoch 2) before the poll caught up.
        #expect(!SettingsHub.isBehind(liveEpoch: 1, helloEpoch: 2, configEpoch: 2, helloConfigEpoch: 2, helloStale: false))
        // The hello is newer than the last poll and says behind.
        #expect(SettingsHub.isBehind(liveEpoch: nil, helloEpoch: 2, configEpoch: 2, helloConfigEpoch: 3, helloStale: true))
    }

    @Test func summarisesAReload() throws {
        func r(_ j: String) throws -> PiReloadResult { try JSONDecoder().decode(PiReloadResult.self, from: Data(j.utf8)) }
        #expect(SettingsHub.summary(of: try r(#"{"restarted":[],"busy":[],"failed":[],"config_epoch":1}"#)) == "Nothing to restart")
        #expect(SettingsHub.summary(of: try r(#"{"restarted":["a"],"busy":["b"],"failed":[],"config_epoch":1}"#))
                == "Restarted 1 chat · 1 busy chat left: try again when it finishes")
        #expect(SettingsHub.summary(of: try r(#"{"restarted":["a","c"],"busy":["b","d"],"failed":[{"key":"e","error":"boom"}],"config_epoch":1}"#))
                == "Restarted 2 chats · 2 busy chats left: try again when they finish · 1 failed: boom")
    }
}
