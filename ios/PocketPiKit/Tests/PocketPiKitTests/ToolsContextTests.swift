import Foundation
import Testing
@testable import PocketPiKit

// The chat's Tools screen, defaultTools, codemode settings, the Context page
// and the raw settings editor (no server).
@Suite struct ToolsContextTests {
    private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
    private func tool(_ name: String, source: String = "builtin", exposure: String = "direct", active: Bool = false,
                      description: String? = nil) -> PiTool {
        PiTool(["name": .string(name), "source": .string(source), "exposure": .string(exposure), "active": .bool(active),
                "description": description.map(JSONValue.string) ?? .null])!
    }

    // MARK: chat tools

    @Test func groupsToolsAndHidesWithdrawnOnes() {
        let tools = [tool("read", active: true), tool("mcp__docs__search"), tool("hello", source: "local", active: true),
                     tool("codemode"), tool("old", source: "local", exposure: "hidden")]
        let s = ChatTools.sections(tools)
        #expect(s.map(\.group) == [.builtin, .extensions, .mcp])
        #expect(s[0].tools.map(\.name) == ["read", "codemode"])
        #expect(s[1].tools.map(\.name) == ["hello"])
        #expect(tools[1].mcpServer == "docs")
        #expect(tools[0].mcpServer == nil)
        #expect(ChatTools.count(tools) == "2 of 4 on")
    }

    @Test func switchingKeepsTheOthers() {
        let tools = [tool("read", active: true), tool("bash", active: true), tool("grep"), tool("x", exposure: "hidden", active: true)]
        #expect(ChatTools.active(after: "grep", on: true, in: tools) == ["read", "bash", "grep"])
        #expect(ChatTools.active(after: "read", on: false, in: tools) == ["bash"])
        #expect(ChatTools.active(setting: .builtin, on: false, in: tools) == [])
        #expect(ChatTools.active(setting: .builtin, on: true, in: tools) == ["read", "bash", "grep"])
    }

    @Test func summariesAndNotes() {
        let t = tool("a", exposure: "codemode", description: "First line\nsecond")
        #expect(t.summary() == "First line")
        #expect(tool("b", description: String(repeating: "x", count: 200)).summary(limit: 10).count == 10)
        #expect(t.exposureNote != nil)
        #expect(tool("c").exposureNote == nil)
    }

    // MARK: defaultTools

    @Test func resolvesLikePi() {
        let p = { (s: [String]) in s.compactMap(DefaultTools.Entry.init) }
        #expect(DefaultTools.resolve(nil) == ["read", "bash", "edit", "write"])
        #expect(DefaultTools.resolve(p(["+codemode"])) == ["read", "bash", "edit", "write", "codemode"])
        #expect(DefaultTools.resolve(p(["-bash", "+powershell", "+grep"])) == ["read", "edit", "write", "powershell", "grep"])
        #expect(DefaultTools.resolve(p(["read", "grep"])) == ["read", "grep"])
        #expect(DefaultTools.resolve(p(["+ls", "read"])) == ["read", "ls"])
        #expect(DefaultTools.resolve([]) == [])
        // Project on top of the user's.
        #expect(DefaultTools.resolve(p(["-read"]), inherited: ["read", "grep"]) == ["grep"])
        #expect(DefaultTools.Entry(" + x ")?.raw == "+x")
        #expect(DefaultTools.Entry("+") == nil)
    }

    @Test func togglingKeepsTheListsForm() {
        let p = { (s: [String]) in s.compactMap(DefaultTools.Entry.init) }
        // Unset or relative stays relative; an entry that changes nothing goes.
        #expect(DefaultTools.toggling(nil, "codemode", on: true).map(\.raw) == ["+codemode"])
        #expect(DefaultTools.toggling(p(["+codemode"]), "bash", on: false).map(\.raw) == ["+codemode", "-bash"])
        #expect(DefaultTools.toggling(p(["+codemode"]), "codemode", on: false).map(\.raw) == [])
        // Plain names stay plain.
        #expect(DefaultTools.toggling(p(["read"]), "grep", on: true).map(\.raw) == ["read", "grep"])
        #expect(DefaultTools.toggling(p(["read", "grep"]), "read", on: false).map(\.raw) == ["grep"])
        #expect(DefaultTools.patch(nil) == PiConfigPatch(unset: ["defaultTools"]))
        #expect(DefaultTools.patch([]) == PiConfigPatch(set: ["defaultTools": .array([])]))
        #expect(DefaultTools.parse(["+a", "b", 3]) == p(["+a", "b"]))
        #expect(DefaultTools.parse(nil) == nil)
        #expect(DefaultTools.explain(nil).hasPrefix("Not set"))
        #expect(DefaultTools.explain([]).hasPrefix("Empty"))
        #expect(DefaultTools.offered(p(["mytool"])).last == "mytool")
    }

    @Test func codemodeSettings() throws {
        let mode = try #require(PiSettings.spec("codemode.mode"))
        let budget = try #require(PiSettings.spec("codemode.inlineBudget"))
        #expect(mode.group == .tools && budget.group == .tools)
        let data = try json(#"{"codemode":{"mode":"only"}}"#)
        #expect(PiSettings.string(data, mode) == "only")
        #expect(PiSettings.int(data, budget) == 3000)
        #expect(PiSettings.parseNumber("-1", budget) == .failure(.tooSmall(0)))
    }

    // MARK: context files

    @Test func readsTheContextOverview() throws {
        let v = try json("""
        {"agentDir":"/h/.pi/agent","cwd":"/p","maxBytes":1000,"trust":{"trusted":false},
         "files":[{"scope":"global","name":"AGENTS.md","path":"/h/.pi/agent/AGENTS.md","exists":true,"size":3,"editable":true,"kind":"context","loaded":true},
                  {"scope":"project","name":"SYSTEM.md","path":"/p/.pi/SYSTEM.md","exists":true,"size":3,"editable":true,"kind":"system","loaded":false},
                  {"scope":"project","name":"CLAUDE.md","path":"/p/CLAUDE.md","exists":true,"size":3,"editable":false,"kind":"context","loaded":true},
                  {"scope":"project","name":"APPEND_SYSTEM.md","path":"/p/.pi/APPEND_SYSTEM.md","exists":false,"editable":true,"kind":"append","loaded":false}],
         "loaded":{"context":[{"path":"/h/.pi/agent/AGENTS.md","scope":"global"},{"path":"/CLAUDE.md","scope":"parent"},{"path":"/p/CLAUDE.md","scope":"project"}],
                   "system":null,"append":null}}
        """)
        let o = PiContextOverview(v)
        #expect(o.trusted == false)
        #expect(o.files(scope: "project").count == 3)
        #expect(o.parents.map(\.path) == ["/CLAUDE.md"])
        #expect(o.systemSummary == "pi's own")
        let sys = o.files[1]
        #expect(sys.status(in: o) == "Ignored: pi doesn't trust this project")
        #expect(o.files[0].status(in: o) == "Loaded")
        #expect(o.files[3].status(in: o) == "Not created")
        #expect(!o.files[2].editable)
        #expect(sys.role == "Replaces pi's system prompt")
    }

    @Test func rawSettingsSyntax() {
        #expect(RawSettings.syntaxProblem(#"{"a": 1}"#) == nil)
        #expect(RawSettings.syntaxProblem("{ nope") == "Not valid JSON")
        #expect(RawSettings.syntaxProblem("[1]") != nil)
        #expect(SettingsScope.project("/p").cwd == "/p")
        #expect(!SettingsScope.global.isProject)
    }
}
