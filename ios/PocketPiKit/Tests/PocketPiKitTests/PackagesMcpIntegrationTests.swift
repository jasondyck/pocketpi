import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// Settings › Resources switches, Packages and MCP servers against a scratch
/// pocketpi with ios/fake-pi.py as pi (which knows `pi install|remove|update`
/// and `pi mcp list|add|remove|logout`, and `/mcp login` in a chat).
/// test-linux.sh seeds a global prompt to switch (toggle-me) and a local
/// package (POCKETPI_TEST_PKG). Skipped when POCKETPI_TEST_URL isn't set.
private let env = ProcessInfo.processInfo.environment
private let pmServer = env["POCKETPI_TEST_URL"]

@Suite(.serialized, .enabled(if: pmServer != nil && env["POCKETPI_TEST_PKG"] != nil))
struct PackagesMcpIntegrationTests {
    let client = PocketPiClient(server: ServerAddress(url: URL(string: pmServer ?? "http://127.0.0.1:1")!))
    let pkg = env["POCKETPI_TEST_PKG"] ?? ""

    /// A job, waiting while another suite's job holds the runner.
    private func job(_ a: PiAction) async throws -> PiJob {
        for _ in 0..<100 {
            do { return try await client.runJob(a, every: .milliseconds(150)) }
            catch PocketPiError.http(let status, _) where status == 409 { try await Task.sleep(for: .milliseconds(300)) }
        }
        throw PocketPiError.unexpected("the job runner stayed busy")
    }

    @Test func toggleRoundTrip() async throws {
        let find = { (r: PiResources) in r.list(.prompt).first { $0.name == "toggle-me" } }
        let before = try #require(find(try await client.resources()))
        #expect(before.enabled && before.loads && before.canToggle)
        let epoch = try await client.piStatus().configEpoch
        let off = try await client.setResource(before, .off, cwd: nil)
        #expect(!off.enabled && off.key == "prompts" && off.entries == ["-prompts/toggle-me.md"])
        #expect(try await client.piStatus().configEpoch > epoch)
        let now = try #require(find(try await client.resources()))
        #expect(!now.enabled && !now.loads)
        // The settings file holds pi's own override, nothing else changed.
        let settings = try await client.config(.settings)
        #expect(settings.data["prompts"] == ["-prompts/toggle-me.md"])
        #expect(settings.data["enabledModels"] != nil)
        let on = try await client.setResource(now, .on, cwd: nil)
        #expect(on.enabled)
        #expect(find(try await client.resources())?.enabled == true)
        #expect(try await client.config(.settings).data["prompts"] == nil)
    }

    @Test func installTogglesAndRemovesAPackage() async throws {
        var job = try await job(.install(source: pkg))
        #expect(job.status == "ok", "\(job.output)")
        var r = try await client.resources()
        let p = try #require(r.packages.first { $0.source == pkg })
        #expect(p.installedPath != nil)
        #expect(r.summary(of: p) == "1 extension · 1 skill · 1 prompt")
        // One of its skills off: the settings entry becomes a filter, then a string again.
        let skill = try #require(r.resources(of: p).first { $0.kind == .skill })
        #expect(try await client.setResource(skill, .off, cwd: nil).key == "packages")
        r = try await client.resources()
        #expect(r.resources(of: p).first { $0.kind == .skill }?.enabled == false)
        #expect(try await client.config(.settings).data["packages"]?.array?.contains { $0["source"]?.string == pkg } == true)
        try await client.setResource(skill, .on, cwd: nil)
        #expect(try await client.config(.settings).data["packages"]?.array?.contains(.string(pkg)) == true)

        job = try await self.job(.update(source: pkg))
        #expect(job.status == "ok" && job.argv == ["update", pkg])
        job = try await self.job(.remove(source: pkg))
        #expect(job.status == "ok")
        #expect(try await client.resources().packages.contains { $0.source == pkg } == false)
        // A failed install is a failed job, with pi's words.
        job = try await self.job(.install(source: "npm:will-fail"))
        #expect(job.status == "failed" && job.output.contains("404"))
        await #expect(throws: PocketPiError.self) { _ = try await client.startJob(.update(source: "pi")) }
    }

    @Test func mcpAddDisableSignInRemove() async throws {
        var job = try await job(.mcpAdd(name: "itest", command: "npx", args: ["-y", "srv"], env: ["TOKEN=${T}"]))
        #expect(job.status == "ok", "\(job.output)")
        job = try await self.job(.mcpAdd(name: "idocs", url: "https://docs.oauth.test/mcp"))
        #expect(job.status == "ok")
        var files = try await client.mcpFiles(cwd: nil)
        var report = try await client.mcpReport(cwd: nil)
        var list = McpServers.merge(global: files.global.data, project: nil, report: report)
        let s = try #require(list.first { $0.name == "itest" })
        #expect(s.state == "connected" && s.tools == ["itest_echo"] && s.enabled)
        // Secrets stay on the server.
        #expect(files.global.data["mcpServers"]?["itest"]?["env"]?["TOKEN"] == "<redacted>")
        #expect(list.first { $0.name == "idocs" }?.state == "needs-auth")

        try await client.editMcpServer(.enabled(s, false, cwd: nil))
        try await client.editMcpServer(.exposure(s, .direct, cwd: nil))
        files = try await client.mcpFiles(cwd: nil)
        #expect(files.global.data["mcpServers"]?["itest"]?["enabled"] == false)
        #expect(files.global.data["mcpServers"]?["itest"]?["exposure"] == "direct")
        report = try await client.mcpReport(cwd: nil)
        list = McpServers.merge(global: files.global.data, project: nil, report: report)
        #expect(list.first { $0.name == "itest" }?.state == "disabled")
        // Back to the defaults: pi drops the keys.
        try await client.editMcpServer(McpEdit(name: "itest", enabled: true, exposure: .codemode))
        #expect(try await client.config(.mcp).data["mcpServers"]?["itest"]?["enabled"] == nil)
        await #expect(throws: PocketPiError.self) { try await client.editMcpServer(McpEdit(name: "nope", enabled: false)) }

        // Sign-in runs /mcp login in a chat and answers with the URL and the dialog.
        let si = try await client.mcpChat(.login, server: "idocs", cwd: nil)
        #expect(si.url?.hasPrefix("https://auth.example.test/") == true)
        #expect(si.dialogID != nil && !si.done)
        try await client.finishSignin(si, redirect: "http://127.0.0.1:5555/callback?code=abc")
        let out = try await client.mcpChat(.logout, server: "idocs", cwd: nil, key: si.key)
        #expect(out.done && out.notices.contains { $0.contains("No stored credentials") })
        job = try await self.job(.mcpLogout(name: "idocs"))
        #expect(job.status == "ok" && job.argv == ["mcp", "logout", "idocs"])
        // The pages' log: output and a headline.
        let log = await PiJobLog()
        var logged: PiJob?
        for _ in 0..<50 {
            logged = await log.run("Signing out of idocs", .mcpLogout(name: "idocs"), client: client)
            if logged != nil { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(await log.headline == "Signing out of idocs: done")
        #expect(await log.output.contains("No stored credentials"))
        try await client.close(key: si.key)

        for n in ["itest", "idocs"] {
            job = try await self.job(.mcpRemove(name: n))
            #expect(job.status == "ok")
        }
        #expect(try await client.config(.mcp).data["mcpServers"]?["itest"] == nil)
    }
}
