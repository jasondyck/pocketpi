import Foundation
import Testing
@testable import PocketPiKit

@Suite struct ProvidersTests {
    private let sample = #"""
    {"cached":false,"checked":1794000000000,
     "models":{"default":{"provider":"xai","model":"grok-4.3"},
               "fallback":{"model":"opencode-go/deepseek-v4.1-flash","provider":"opencode-go","from":["xai","openai","openai-codex"]}},
     "providers":[
      {"id":"xai","name":"xAI","source":"builtin","common":true,"apiKey":true,"oauth":true,"subscription":true,
       "env":["XAI_API_KEY"],"envSet":[],"stored":{"type":"api_key","hasKey":true},"status":"ready","reason":null,"authType":"api_key","login":"/login xai"},
      {"id":"openai-codex","name":"OpenAI Codex (ChatGPT)","source":"builtin","common":true,"apiKey":false,"oauth":true,"subscription":true,
       "env":[],"envSet":[],"stored":{"type":"oauth","hasKey":true},"status":"invalid","reason":"invalid_state","authType":null,"login":"/login openai-codex"},
      {"id":"llama.cpp","name":"llama.cpp (local)","source":"builtin","common":true,"apiKey":false,"oauth":false,"subscription":false,
       "env":["LLAMA_BASE_URL"],"envSet":[],"stored":{"type":"api_key","hasKey":false},"status":"unknown","reason":"provider_not_found","authType":null,"login":"/login llama.cpp"},
      {"id":"deepseek","name":"DeepSeek","source":"builtin","common":false,"apiKey":true,"oauth":false,"subscription":false,
       "env":["DEEPSEEK_API_KEY"],"envSet":["DEEPSEEK_API_KEY"],"stored":null,"status":"ready","reason":null,"authType":"api_key","login":"/login deepseek"},
      {"id":"opencode-go","name":"OpenCode Go","source":"builtin","common":true,"apiKey":true,"oauth":false,"subscription":false,
       "env":["OPENCODE_API_KEY"],"envSet":[],"stored":null,"status":"not_configured","reason":"credentials_not_configured","authType":null,"login":"/login opencode-go"},
      {"id":"groq","name":"Groq","source":"builtin","common":false,"apiKey":true,"oauth":false,"subscription":false,
       "env":["GROQ_API_KEY"],"envSet":[],"stored":null,"status":"not_configured","reason":"credentials_not_configured","authType":null,"login":"/login groq"},
      {"id":"mine","name":"mine","source":"custom","common":false,"apiKey":true,"oauth":false,"subscription":false,
       "env":[],"envSet":[],"stored":null,"status":"not_configured","reason":null,"authType":null,"login":"/login mine"}
    ]}
    """#

    private func report() throws -> PiProvidersReport { PiProvidersReport(try JSONValue.parse(sample)) }

    @Test func readsTheReport() throws {
        let r = try report()
        #expect(r.providers.count == 7)
        #expect(r.defaultLabel == "xai/grok-4.3")
        #expect(r.fallbackModel == "opencode-go/deepseek-v4.1-flash")
        #expect(r.fallbackFrom == ["xai", "openai", "openai-codex"])
        #expect(r.fallbackBroken)
        #expect(r.checked == 1794000000000)
        let xai = try #require(r.provider("xai"))
        #expect(xai.status == .ready && xai.hasStoredKey && !xai.isSignedIn)
        #expect(xai.stored == PiProvider.Stored(type: "api_key", hasKey: true))
    }

    @Test func groupsSetUpPopularAndMore() throws {
        let r = try report()
        #expect(r.setUp.map(\.id) == ["xai", "openai-codex", "llama.cpp", "deepseek"])
        #expect(r.popular.map(\.id) == ["opencode-go"])
        #expect(r.more.map(\.id) == ["groq", "mine"])
    }

    @Test func describesEachProvider() throws {
        let r = try report()
        #expect(r.provider("xai")?.detail == "API key saved in pi")
        #expect(r.provider("openai-codex")?.detail == "Signed in (subscription)")
        #expect(r.provider("openai-codex")?.statusLabel == "Invalid")
        #expect(r.provider("openai-codex")?.reasonText == "The saved sign-in doesn't work any more (expired or revoked)")
        #expect(r.provider("openai-codex")?.needsTerminal == true)
        #expect(r.provider("llama.cpp")?.detail == "Saved in pi; the CLI can't check it")
        #expect(r.provider("llama.cpp")?.statusLabel == "Unchecked")
        #expect(r.provider("deepseek")?.detail == "From $DEEPSEEK_API_KEY")
        #expect(r.provider("opencode-go")?.detail == "Add a key, or set OPENCODE_API_KEY")
        #expect(r.provider("opencode-go")?.reasonText == nil)
        #expect(r.provider("opencode-go")?.needsTerminal == false)
        #expect(r.provider("mine")?.detail == "Add an API key")
    }

    @Test func replacesARow() throws {
        var r = try report()
        var g = try #require(r.provider("groq"))
        g.status = .ready
        g.stored = .init(type: "api_key", hasKey: true)
        r.replace(g)
        #expect(r.setUp.contains { $0.id == "groq" })
        #expect(r.providers.count == 7)
    }

    @Test func onlyLiteralKeys() {
        #expect(ProviderKey.problem("sk-abc") == nil)
        #expect(ProviderKey.problem("  sk-abc\n") == nil)
        #expect(ProviderKey.problem("") != nil)
        #expect(ProviderKey.problem("!op read op://x") != nil)
        #expect(ProviderKey.problem(" !cmd") != nil)
        #expect(ProviderKey.problem("sk abc") != nil)
        #expect(ProviderKey.problem(String(repeating: "x", count: 5000)) != nil)
    }
}
