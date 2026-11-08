import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// A chat's Tools screen, Settings › Context, project settings and the raw
/// settings.json editor against the scratch server. Part of
/// IntegrationTests (serialized, same scratch server). ios/test-linux.sh
/// makes `ctx-project` next to the test project, with a CLAUDE.md.
private let ctxDir: String = {
    let p = ProcessInfo.processInfo.environment["POCKETPI_TEST_CWD"] ?? "/nonexistent/project"
    return (p as NSString).deletingLastPathComponent + "/ctx-project"
}()
private let toolsProjectDir = ProcessInfo.processInfo.environment["POCKETPI_TEST_CWD"] ?? ""

private func httpStatus(_ e: Error) -> Int? {
    if case PocketPiError.http(let s, _) = e { return s }
    return nil
}

extension IntegrationTests {
    @Test func chatToolsToggleRoundTrip() async throws {
        let key = try await client.newChat(cwd: toolsProjectDir).key
        let tools = try await client.tools(key: key)
        let sections = ChatTools.sections(tools)
        #expect(sections.map(\.group) == [.builtin, .extensions, .mcp])
        #expect(!sections.flatMap(\.tools).contains { $0.name == "old_tool" })
        #expect(sections.last?.tools.first?.mcpServer == "docs")
        // Turn on the extension's tool and the MCP one, then one off again.
        var after = try await client.setActiveTools(key: key, ChatTools.active(after: "hello_world", on: true, in: tools))
        after = try await client.setActiveTools(key: key, ChatTools.active(after: "mcp__docs__search", on: true, in: after))
        #expect(Set(after.filter(\.active).map(\.name)) == ["read", "bash", "edit", "write", "hello_world", "mcp__docs__search"])
        after = try await client.setActiveTools(key: key, ChatTools.active(after: "bash", on: false, in: after))
        #expect(Set(try await client.tools(key: key).filter(\.active).map(\.name)) == ["read", "edit", "write", "hello_world", "mcp__docs__search"])
        after = try await client.setActiveTools(key: key, ChatTools.active(setting: .mcp, on: false, in: after))
        #expect(!after.contains { $0.group == .mcp && $0.active })
        #expect(ChatTools.count(after) == "4 of 8 on")
        // The screen's model does the same.
        let m = ChatToolsModel(client: client, key: key)
        await m.load()
        #expect(m.loaded && m.problem == nil && m.count == "4 of 8 on")
        await m.set("grep", on: true)
        #expect(m.tools.first { $0.name == "grep" }?.active == true)
        await m.set(.extensions, on: false)
        #expect(m.count == "4 of 8 on")
        try await client.close(key: key)
        let gone = ChatToolsModel(client: client, key: key)
        await gone.load()
        #expect(!gone.loaded && gone.problem != nil)
    }

    @Test func contextFilesWriteAndRead() async throws {
        let start = try await client.piStatus().configEpoch
        var o = try await client.contextOverview(cwd: ctxDir)
        #expect(o.trusted == false)
        let claude = try #require(o.files.first { $0.scope == "project" && $0.name == "CLAUDE.md" })
        #expect(claude.exists && claude.loaded && !claude.editable)
        #expect(o.files.contains { $0.scope == "project" && $0.name == "AGENTS.md" && !$0.exists })
        #expect(try await client.contextFile(scope: "project", name: "CLAUDE.md", cwd: ctxDir).content == "Claude notes\n")

        // A project AGENTS.md: written, read back, and now it's the one pi loads.
        try await client.saveContextFile(scope: "project", name: "AGENTS.md", cwd: ctxDir, content: "Be brief.\n")
        #expect(try await client.contextFile(scope: "project", name: "AGENTS.md", cwd: ctxDir).content == "Be brief.\n")
        o = try await client.contextOverview(cwd: ctxDir)
        #expect(o.files.first { $0.scope == "project" && $0.name == "AGENTS.md" }?.loaded == true)
        #expect(o.files.first { $0.scope == "project" && $0.name == "CLAUDE.md" }?.loaded == false)
        #expect(o.context.last?.path.hasSuffix("ctx-project/AGENTS.md") == true)
        #expect(try await client.piStatus().configEpoch > start)

        // A project SYSTEM.md needs trust; a global one is used meanwhile.
        try await client.saveContextFile(scope: "project", name: "SYSTEM.md", cwd: ctxDir, content: "Project prompt")
        try await client.saveContextFile(scope: "global", name: "APPEND_SYSTEM.md", content: "Global extra")
        o = try await client.contextOverview(cwd: ctxDir)
        let sys = try #require(o.files.first { $0.scope == "project" && $0.name == "SYSTEM.md" })
        #expect(sys.exists && !sys.loaded)
        #expect(sys.status(in: o) == "Ignored: pi doesn't trust this project")
        #expect(o.append?.scope == "global")
        #expect(o.system == nil)

        // Not on the list, read only, or too big: refused.
        for name in ["../x.md", "settings.json", "AGENTS.md/../../y"] {
            await #expect { try await client.contextFile(scope: "project", name: name, cwd: ctxDir) } throws: { httpStatus($0) == 400 }
        }
        await #expect { try await client.saveContextFile(scope: "project", name: "CLAUDE.md", cwd: ctxDir, content: "x") }
            throws: { httpStatus($0) == 409 }
        await #expect { try await client.saveContextFile(scope: "global", name: "AGENTS.md", cwd: ctxDir, content: "x") }
            throws: { httpStatus($0) == 400 }
        let big = String(repeating: "x", count: o.maxBytes + 1)
        await #expect { try await client.saveContextFile(scope: "project", name: "AGENTS.md", cwd: ctxDir, content: big) }
            throws: { httpStatus($0) == 413 }
        #expect(try await client.contextFile(scope: "project", name: "AGENTS.md", cwd: ctxDir).content == "Be brief.\n")

        // Deleting goes back to CLAUDE.md.
        try await client.deleteContextFile(scope: "project", name: "AGENTS.md", cwd: ctxDir)
        try await client.deleteContextFile(scope: "project", name: "SYSTEM.md", cwd: ctxDir)
        try await client.deleteContextFile(scope: "global", name: "APPEND_SYSTEM.md")
        o = try await client.contextOverview(cwd: ctxDir)
        #expect(o.files.first { $0.scope == "project" && $0.name == "CLAUDE.md" }?.loaded == true)
        #expect(o.append == nil)
    }

    @Test func projectSettingsPatch() async throws {
        let global = try await client.config(.settings)
        let list = DefaultTools.toggling(nil, "codemode", on: true)
        var doc = try await client.patchConfig(.settings, DefaultTools.patch(list), cwd: ctxDir)
        #expect(doc.scope == "project")
        #expect(doc.path.hasSuffix("ctx-project/.pi/settings.json"))
        #expect(DefaultTools.parse(doc.data["defaultTools"]) == list)
        doc = try await client.patchConfig(.settings, PiSettings.patch(PiSettings.spec("codemode.mode")!, selection: "only"), cwd: ctxDir)
        #expect(doc.data["codemode"]?["mode"]?.string == "only")
        // The global file didn't change.
        #expect(try await client.config(.settings).data == global.data)
        _ = try await client.patchConfig(.settings, PiConfigPatch(unset: ["defaultTools", "codemode"]), cwd: ctxDir)
    }

    @Test func rawSettingsEditorChecksBeforeSaving() async throws {
        let before = try await client.rawSettings(cwd: ctxDir)
        #expect(before.scope == "project")
        // Not JSON, or not what pi's schema allows: refused, nothing written.
        await #expect { try await client.saveRawSettings("{ \"retry\": ", cwd: ctxDir) } throws: { e in
            httpStatus(e) == 422 && e.localizedDescription.contains("not valid JSON")
        }
        let bad = #"{"codemode": {"mode": "sometimes"}, "defaultTools": "read"}"#
        await #expect { try await client.saveRawSettings(bad, cwd: ctxDir) } throws: { e in
            httpStatus(e) == 422 && e.localizedDescription.contains("codemode.mode") && e.localizedDescription.contains("defaultTools")
        }
        let problems = try await client.checkRawSettings(bad, cwd: ctxDir)
        #expect(problems.map(\.path).sorted() == ["codemode.mode", "defaultTools"])
        #expect(try await client.rawSettings(cwd: ctxDir).text == before.text)
        await #expect { try await client.saveRawSettings("[]") } throws: { httpStatus($0) == 422 }

        // A good one is written as typed (and the global file is left alone).
        let good = "{\n  \"defaultTools\": [\"+grep\"],\n  \"somethingPiAddsLater\": true\n}\n"
        #expect(try await client.checkRawSettings(good, cwd: ctxDir).isEmpty)
        let doc = try await client.saveRawSettings(good, cwd: ctxDir)
        #expect(doc.data["defaultTools"] == ["+grep"])
        #expect(try await client.rawSettings(cwd: ctxDir).text == good)
        _ = try await client.saveRawSettings("{}", cwd: ctxDir)
    }
}
