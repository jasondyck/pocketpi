import Foundation
import Testing
@testable import PocketPiKit

@Suite struct TrustResourcesTests {
    private func json(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    @Test func trustPatchesEscapeDots() {
        #expect(TrustChoice.trust.patch(for: "/home/me/my.project") == PiConfigPatch(set: [#"/home/me/my\.project"#: true]))
        #expect(TrustChoice.distrust.patch(for: "/p") == PiConfigPatch(set: ["/p": false]))
        #expect(TrustChoice.none.patch(for: "/a.b/c") == PiConfigPatch(unset: [#"/a\.b/c"#]))
        #expect(ProjectTrustDefault.ask.patch == PiConfigPatch(unset: ["defaultProjectTrust"]))
        #expect(ProjectTrustDefault.never.patch == PiConfigPatch(set: ["defaultProjectTrust": "never"]))
    }

    @Test func readsTheTrustOverview() throws {
        let o = TrustOverview(try json(#"""
        {"path":"/h/.pi/agent/trust.json","exists":true,"error":null,"default":"never","defaultSet":true,
         "entries":{"/h/code":true,"/h/code/a":false,"/gone":null,"/h/old":false},
         "projects":[
          {"path":"/h/code/a","name":"a","canonical":"/h/code/a","decision":false,"from":"/h/code/a","explicit":true,"trusted":false,"needsTrust":true,"protected":[".pi/extensions"]},
          {"path":"/h/code/b","name":"b","canonical":"/h/code/b","decision":true,"from":"/h/code","explicit":false,"trusted":true,"needsTrust":false,"protected":[]},
          {"path":"/h/x","name":"x","canonical":"/h/x","decision":null,"from":null,"explicit":false,"trusted":false,"needsTrust":true,"protected":[".pi/skills"]}]}
        """#))
        #expect(o.defaultTrust == .never)
        #expect(o.projects.map(\.choice) == [.distrust, .none, .none])
        #expect(o.projects.map(\.noneLabel) == ["No decision", "Inherit", "No decision"])
        #expect(o.projects[0].summary(default: .never) == "Not trusted: its .pi resources are skipped")
        #expect(o.projects[1].summary(default: .never, home: "/h") == "Trusted (from ~/code): its .pi resources load")
        #expect(o.projects[2].summary(default: .never) == "No decision: skipped (default is never)")
        #expect(o.projects[2].summary(default: .always) == "No decision: loads (default is always)")
        // Saved decisions that aren't projects; nulls aren't decisions.
        #expect(o.otherEntries.map(\.path) == ["/h/code", "/h/old"])
    }

    private let sample = #"""
    {"cwd":"/h/p","home":"/h","defaultTrust":"ask",
     "trust":{"canonical":"/h/p","decision":null,"from":null,"explicit":false,"trusted":false,"needsTrust":true,"protected":[".pi/prompts"]},
     "packages":[{"source":"npm:@me/tools@1","scope":"user","installedPath":"/h/.pi/agent/npm/node_modules/@me/tools","filtered":false}],
     "packagesError":null,"live":{"key":"k1","commands":2},"liveError":null,
     "resources":[
      {"kind":"prompt","name":"notes","description":"Release notes","argumentHint":null,"path":"/h/p/.pi/prompts/notes.md","scope":"project","origin":"auto","package":null,"enabled":true,"loads":false,"skipped":"project not trusted","toggle":{"key":"prompts","scope":"project","entry":"prompts/notes.md"},"commands":[],"live":false},
      {"kind":"prompt","name":"fix","description":"Fix tests","argumentHint":"<file>","path":"/h/.pi/agent/prompts/fix.md","scope":"global","origin":"auto","package":null,"enabled":true,"loads":true,"skipped":null,"toggle":{"key":"prompts","scope":"global","entry":"prompts/fix.md"},"commands":[],"live":true},
      {"kind":"skill","name":"tools","description":"From a package","path":"/x/SKILL.md","scope":"package","origin":"package","package":{"source":"npm:@me/tools@1","scope":"user"},"enabled":true,"loads":true,"toggle":{"key":"packages","scope":"global","package":"npm:@me/tools@1","resource":"skills","entry":"skills/tools/SKILL.md"},"commands":[],"live":false},
      {"kind":"extension","name":"mcp","description":"MCP servers","path":"builtin:mcp","scope":"builtin","origin":"builtin","enabled":false,"loads":false,"disabledBy":"-builtin:mcp in global settings","toggle":{"key":"extensions","scope":"global","entry":"builtin:mcp"},"commands":[],"live":false},
      {"kind":"extension","name":"hello","path":"/h/.pi/agent/extensions/hello.ts","scope":"global","origin":"auto","enabled":true,"loads":true,"commands":["hi","hey"],"live":true},
      {"kind":"theme","name":"ignored"}]}
    """#

    @Test func readsResources() throws {
        let r = PiResources(try json(sample))
        #expect(r.resources.count == 5)
        #expect(r.liveCommands == 2)
        #expect(r.packages.first?.installedPath == "/h/.pi/agent/npm/node_modules/@me/tools")
        #expect(r.trust?.canonical == "/h/p")
        #expect(r.untrustedWarning == "This project isn't trusted, so pi skips its .pi resources (no decision; the default is “ask”).")
        // Project first, then global.
        #expect(r.list(.prompt).map(\.name) == ["notes", "fix"])
        #expect(r.list(.extensionFile).map(\.name) == ["hello", "mcp"])
        #expect(r.sections(.skill).map(\.kind) == [.skill])
        #expect(r.sections(nil).count == 3)
        #expect(r.tilde("/h/p/x") == "~/p/x")
    }

    @Test func describesOneResource() throws {
        let r = PiResources(try json(sample))
        let fix = r.list(.prompt)[1]
        #expect(fix.invocation == "/fix <file>")
        #expect(fix.badges == ["global", "running"])
        #expect(fix.toggle == nil ? false : fix.toggle?.entry == "prompts/fix.md")
        let notes = r.list(.prompt)[0]
        #expect(notes.badges == ["project", "skipped: not trusted"])
        #expect(notes.loadsText == "No: project not trusted")
        let mcp = r.list(.extensionFile)[1]
        #expect(mcp.badges == ["built-in", "off"])
        #expect(mcp.loadsText == "No: -builtin:mcp in global settings")
        #expect(mcp.originText == "built in")
        #expect(r.list(.extensionFile)[0].invocation == "/hi /hey")
        let pkg = r.list(.skill)[0]
        #expect(pkg.badges == ["package", "tools@1"])
        #expect(pkg.toggle?.package == "npm:@me/tools@1")
        #expect(pkg.invocation == "/skill:tools")
    }
}
