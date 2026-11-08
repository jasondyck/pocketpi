import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// Export, download, compact with instructions and usage against a scratch
/// pocketpi with ios/fake-pi.py as pi. test-linux.sh seeds a session in the
/// project "/usage-seed" with known usage. Skipped without POCKETPI_TEST_URL.
private let exportEnv = ProcessInfo.processInfo.environment
private let exportServer = exportEnv["POCKETPI_TEST_URL"]
private let exportCwd = exportEnv["POCKETPI_TEST_CWD"] ?? ""

@Suite(.serialized, .enabled(if: exportServer != nil))
@MainActor
struct ExportUsageIntegrationTests {
    let client = PocketPiClient(server: ServerAddress(url: URL(string: exportServer ?? "http://127.0.0.1:1")!))

    private func chat(saying text: String) async throws -> ChatSession {
        let s = ChatSession(client: client, newIn: exportCwd)
        try await s.send(text)
        let end = Date().addingTimeInterval(10)
        while s.isStreaming || s.path == nil || !s.transcript.items.contains(where: { if case .assistant(_, false) = $0.kind { true } else { false } }) {
            if Date() > end { Issue.record("no reply"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
        return s
    }

    private func raw(_ path: String) async throws -> (Int, [String: String], Data) {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: path, relativeTo: client.server.url)!)
        let h = resp as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in h.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        return (h.statusCode, headers, data)
    }

    @Test func exportsHTMLAndServesIt() async throws {
        let s = try await chat(saying: "export me please")
        let file = try #require(await s.exportHTML(), "\(s.problem ?? "")")
        #expect(file.lastPathComponent.lowercased() == "export-me-please.html")
        let html = try String(contentsOf: file, encoding: .utf8)
        #expect(html.contains("export me please"))

        let key = try #require(s.key)
        let page = try await client.exportHTML(key: key)
        #expect(page.url == "/api/exports/" + page.name)
        let (status, headers, body) = try await raw(page.url)
        #expect(status == 200)
        #expect(headers["content-type"]?.hasPrefix("text/html") == true)
        #expect(headers["content-security-policy"]?.contains("sandbox") == true)
        #expect(headers["content-disposition"] == nil)
        #expect(String(decoding: body, as: UTF8.self).contains("export me please"))
        let (_, dl, _) = try await raw(page.url + "?download=1&title=My%20chat")
        #expect(dl["content-disposition"]?.contains("My-chat.html") == true)
        // Only names the server made.
        #expect(try await raw("/api/exports/..%2F..%2Fetc%2Fpasswd").0 == 404)
        #expect(try await raw("/api/exports/nope-1.html").0 == 404)
        s.leave()
    }

    @Test func downloadsTheSessionFile() async throws {
        let s = try await chat(saying: "jsonl download")
        let file = try #require(await s.exportJSONL(), "\(s.problem ?? "")")
        #expect(file.pathExtension == "jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix(#"{"type":"session""#))
        #expect(text.contains("jsonl download"))
        let path = try #require(s.path)
        let (status, headers, _) = try await raw(PocketPiClient.sessionFilePath(path))
        #expect(status == 200)
        #expect(headers["content-disposition"]?.hasPrefix("attachment") == true)
        // Nothing outside the sessions folders.
        #expect(try await raw(PocketPiClient.sessionFilePath("/etc/passwd")).0 == 404)
        #expect(try await raw(PocketPiClient.sessionFilePath(path + "/../../../../etc/hostname")).0 == 404)
        s.leave()
    }

    @Test func compactsWithInstructions() async throws {
        let s = try await chat(saying: "compact this chat")
        let r = try #require(await s.compact(instructions: "  the failing tests \n"), "\(s.problem ?? "")")
        #expect(r.summary.contains("(focus: the failing tests)"))
        #expect(r.tokensBefore == 4000 && r.tokensAfter == 800)
        let plain = try #require(await s.compact(instructions: ""))
        #expect(!plain.summary.contains("focus"))
        s.leave()
    }

    @Test func addsUpUsageOverSeededSessions() async throws {
        let r = try await client.usage(days: 7)
        #expect(r.days == 7 && r.byDay.count == 7)
        let seed = try #require(r.byProject.first { $0.project == "/usage-seed" }, "\(r.byProject.map(\.id))")
        #expect(seed.totals.count == 4)
        #expect(abs(seed.totals.cost - 1.75) < 1e-9)
        #expect(seed.totals.input == 1000 + 2000 + 300)
        #expect(seed.totals.cacheRead == 50000)
        #expect(r.byModel.contains { $0.provider == "opencode-go" && $0.billing == .pool })
        #expect(r.byModel.contains { $0.provider == "openai-codex" && $0.billing == .subscription })
        #expect(r.byProvider.contains { $0.provider == "anthropic" && $0.billing == .api })
        // The 40-day-old reply only shows in a longer range.
        let long = try await client.usage(days: 90)
        let seed90 = try #require(long.byProject.first { $0.project == "/usage-seed" })
        #expect(seed90.totals.count == 5)
        #expect(long.byDay.count == 90)
    }
}
