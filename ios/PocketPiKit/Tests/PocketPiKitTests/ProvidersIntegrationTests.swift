import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// Settings › Providers against a scratch pocketpi with ios/fake-pi.py as pi
/// (which answers `pi auth check` for a few providers from auth.json).
/// Skipped when POCKETPI_TEST_URL isn't set.
private let providersServer = ProcessInfo.processInfo.environment["POCKETPI_TEST_URL"]

@Suite(.serialized, .enabled(if: providersServer != nil))
struct ProvidersIntegrationTests {
    let client = PocketPiClient(server: ServerAddress(url: URL(string: providersServer ?? "http://127.0.0.1:1")!))

    @Test func listsProvidersWithPisVerdict() async throws {
        let r = try await client.providers(refresh: true)
        #expect(r.providers.count > 30)
        let codex = try #require(r.provider("openai-codex"))
        #expect(!codex.apiKey && codex.oauth)
        #expect(r.provider("anthropic")?.status == .notConfigured)
        // test-linux.sh logs llama.cpp in without a key; pi's CLI can't check it.
        let llama = try #require(r.provider("llama.cpp"))
        #expect(llama.stored?.type == "api_key")
        #expect(llama.status == .unknown)
        #expect(r.setUp.contains { $0.id == "llama.cpp" })
        #expect(r.fallbackModel?.isEmpty == false)
    }

    @Test func addsReplacesAndRemovesAKey() async throws {
        let before = try await client.config(.auth).epoch
        let added = try await client.setProviderKey("groq", key: "  gsk-test-secret-1 ")
        #expect(added.status == .ready)
        #expect(added.hasStoredKey)
        // Only the redacted view ever comes back.
        let doc = try await client.config(.auth)
        #expect(doc.epoch > before)
        #expect(doc.authProviders.contains { $0.provider == "groq" && $0.hasKey && $0.type == "api_key" })
        #expect(!doc.data.compactText.contains("gsk-test-secret"))
        let listed = try await client.providers()
        #expect(listed.provider("groq")?.status == .ready)
        #expect(!listed.cached)

        // fake-pi reads keys starting with "bad" as invalid.
        let replaced = try await client.setProviderKey("groq", key: "bad-key")
        #expect(replaced.status == .invalid)

        // Commands and OAuth-only providers are refused.
        await #expect(throws: PocketPiError.self) { try await client.setProviderKey("groq", key: "!pass groq") }
        do {
            _ = try await client.post("/api/pi/providers/groq/key", ["key": "!pass groq"], as: JSONValue.self)
            Issue.record("the server took a !command key")
        } catch PocketPiError.http(let status, _) { #expect(status == 400) }
        do {
            _ = try await client.setProviderKey("openai-codex", key: "sk-x")
            Issue.record("the server took a key for an OAuth-only provider")
        } catch PocketPiError.http(let status, _) { #expect(status == 400) }

        let removed = try await client.removeProviderKey("groq")
        #expect(removed.stored == nil)
        #expect(removed.status == .notConfigured)
        #expect(try await client.config(.auth).authProviders.contains { $0.provider == "groq" } == false)
        // llama.cpp's credential (with its router URL) is left alone.
        #expect(try await client.config(.auth).authProviders.contains { $0.provider == "llama.cpp" })
    }
}
