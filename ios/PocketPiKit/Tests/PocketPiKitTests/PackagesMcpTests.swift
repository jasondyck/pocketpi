import Foundation
import Testing
@testable import PocketPiKit

@Suite struct PackagesMcpTests {
    private func json(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    private let sample = #"""
    {"cwd":"/h/p","home":"/h","defaultTrust":"ask","trust":{"canonical":"/h/p","trusted":true,"needsTrust":true},
     "packages":[{"source":"npm:@me/tools@1","scope":"user","installedPath":"/n/tools","filtered":true},{"source":"../local-pkg","scope":"project","installedPath":"/h/local-pkg"}],
     "resources":[
      {"kind":"prompt","name":"fix","path":"/h/.pi/agent/prompts/fix.md","scope":"global","origin":"auto","enabled":true,"loads":true,"toggle":{"key":"prompts","scope":"global","entry":"prompts/fix.md"}},
      {"kind":"skill","name":"tools","path":"/n/tools/skills/tools/SKILL.md","scope":"package","origin":"package","package":{"source":"npm:@me/tools@1","scope":"user"},"enabled":false,"loads":false,"toggle":{"key":"packages","scope":"global","package":"npm:@me/tools@1","resource":"skills","entry":"skills/tools/SKILL.md"}},
      {"kind":"extension","name":"t","path":"/n/tools/extensions/t.ts","scope":"package","origin":"package","package":{"source":"npm:@me/tools@1","scope":"user"},"enabled":true,"loads":true,"toggle":{"key":"packages","scope":"global","package":"npm:@me/tools@1","resource":"extensions","entry":"extensions/t.ts"}},
      {"kind":"skill","name":"review","path":"/h/.pi/agent/skills/review/SKILL.md","scope":"project","origin":"settings","enabled":false,"loads":false,"toggle":{"key":"skills","scope":"project","entry":"../../.pi/agent/skills/review/SKILL.md"}},
      {"kind":"extension","name":"codemode","path":"builtin:codemode","scope":"builtin","origin":"builtin","enabled":false,"loads":false,"toggle":{"key":"extensions","scope":"project","entry":"builtin:codemode"}},
      {"kind":"extension","name":"mcp","path":"builtin:mcp","scope":"builtin","origin":"builtin","enabled":true,"loads":true,"toggle":{"key":"extensions","scope":"global","entry":"builtin:mcp"}},
      {"kind":"extension","name":"workflows","path":"/x/wf.ts","scope":"temporary","origin":"live","enabled":true,"loads":true,"toggle":null}]}
    """#

    @Test func toggleRequests() throws {
        let r = PiResources(try json(sample))
        let fix = try #require(r.list(.prompt).first)
        #expect(fix.toggleRequest(.off, cwd: "/h/p") == ["kind": "prompt", "path": "/h/.pi/agent/prompts/fix.md", "state": "off", "cwd": "/h/p", "scope": "global"])
        #expect(fix.canSetPerProject(cwd: "/h/p") && !fix.canSetPerProject(cwd: nil))
        #expect(fix.projectState(cwd: "/h/p") == .inherit)
        // Only in this project: an override of the global file.
        #expect(fix.toggleRequest(.off, cwd: "/h/p", projectOnly: true)?["override"] == true)
        #expect(fix.toggleRequest(.off, cwd: "/h/p", projectOnly: true)?["scope"] == "project")
        // A package's resource goes through the package's filter.
        let tools = try #require(r.list(.skill).first { $0.name == "tools" })
        let body = try #require(tools.toggleRequest(.on, cwd: nil))
        #expect(body["package"] == ["source": "npm:@me/tools@1", "scope": "user", "entry": "skills/tools/SKILL.md"])
        #expect(!tools.canSetPerProject(cwd: "/h/p"))
        #expect(tools.toggleWhere(cwd: nil) == "in the package's settings entry")
        // A global file the project overrides: its switch changes the override.
        let review = try #require(r.list(.skill).first { $0.name == "review" })
        #expect(review.isProjectOverride(cwd: "/h/p"))
        #expect(review.projectState(cwd: "/h/p") == .off)
        #expect(review.toggleRequest(.on, cwd: "/h/p")?["override"] == true)
        // A built-in the project decides: no override flag, project scope.
        let cm = try #require(r.list(.extensionFile).first { $0.name == "codemode" })
        #expect(cm.isBuiltinSetInProject && cm.projectState(cwd: "/h/p") == .off)
        #expect(cm.toggleRequest(.inherit, cwd: "/h/p", projectOnly: true)?["override"] == false)
        let mcp = try #require(r.list(.extensionFile).first { $0.name == "mcp" })
        #expect(mcp.toggleRequest(.off, cwd: nil)?["scope"] == "global")
        // -e extensions can't be switched.
        let wf = try #require(r.list(.extensionFile).first { $0.name == "workflows" })
        #expect(!wf.canToggle && wf.toggleRequest(.off, cwd: nil) == nil)
    }

    @Test func packagesAndGallery() throws {
        let r = PiResources(try json(sample))
        #expect(r.sortedPackages.map(\.shortName) == ["local-pkg", "@me/tools"])
        let tools = r.packages[0]
        #expect(r.resources(of: tools).map(\.name) == ["tools", "t"])
        #expect(r.summary(of: tools) == "1 extension · 1 skill (1 off)")
        #expect(r.summary(of: r.packages[1]) == "nothing pi loads")
        #expect(r.isInstalled(npm: "@me/tools") && !r.isInstalled(npm: "@me/tool"))
        #expect(PiPackageInfo.shortName("npm:left-pad") == "left-pad")
        #expect(PiPackageInfo.shortName("git:github.com/x/pi-y@v1") == "x/pi-y")
        #expect(PiPackageInfo.shortName("https://github.com/x/pi-y.git") == "x/pi-y")
        #expect(PiPackageInfo.shortName("./pkgs/mine/") == "mine")
        let g = PiGallery(try json(#"{"total":40,"packages":[{"name":"pi-z","version":"2.0.0","monthly":3100555,"publisher":"me","date":"2026-11-07T23:32:24Z","source":"npm:pi-z"},{"nope":1}]}"#))
        #expect(g.total == 40 && g.packages.count == 1)
        #expect(g.packages[0].line == "v2.0.0 · 3.1M/month · me · 2026-11-07")
        #expect(PiGalleryPackage.short(999) == "999" && PiGalleryPackage.short(1500) == "1.5k" && PiGalleryPackage.short(2000) == "2k")
    }

    @Test func mergesMcpFilesAndReport() throws {
        let global = try json(#"{"mcpServers":{"fs":{"command":"npx","args":["-y","srv"]},"docs":{"url":"https://d/mcp","exposure":"direct","headers":{"Authorization":"<redacted>"}}}}"#)
        let project = try json(#"{"mcpServers":{"fs":{"enabled":false},"local":{"command":"./run"}}}"#)
        let before = McpServers.merge(global: global, project: project, report: nil)
        #expect(before.map(\.name) == ["local", "docs", "fs"])
        #expect(before.allSatisfy { $0.state == "checking" })
        let fs = try #require(before.first { $0.name == "fs" })
        #expect(fs.definedIn == "global" && fs.override != nil && !fs.enabled && fs.enabledInFile)
        #expect(fs.projectState == .off && fs.transport == "npx -y srv")
        let report = McpReport(PiCLIResult(code: 1, stdout: "", stderr: "", json: try json(#"""
        {"servers":[{"name":"docs","scope":"global","enabled":true,"exposure":"direct","transport":"https://d/mcp","state":"needs-auth","tools":[],"error":"Sign-in required"},
                    {"name":"local","scope":"project","enabled":true,"exposure":"codemode","transport":"./run","state":"connected","tools":["a","b"],"toolExposure":{"b":"hidden"}}],
         "errors":["bad entry"],"note":"untrusted"}
        """#)))
        let after = McpServers.merge(global: global, project: project, report: report)
        let docs = try #require(after.first { $0.name == "docs" })
        #expect(docs.isURL && docs.stateText.text == "needs sign-in" && docs.exposure == .direct)
        let local = try #require(after.first { $0.name == "local" })
        #expect(local.stateText.text == "2 tools" && local.toolExposure["b"] == "hidden" && local.definedIn == "project")
        #expect(report.errors == ["bad entry"] && report.note == "untrusted")
        #expect(McpReport(PiCLIResult(code: 1, stdout: "", stderr: "boom\n", json: nil)).error == "boom")

        #expect(McpEdit.enabled(fs, false, cwd: "/p").json == ["name": "fs", "scope": "global", "enabled": false])
        #expect(McpEdit.enabled(local, false, cwd: "/p").json == ["name": "local", "scope": "project", "cwd": "/p", "enabled": false])
        #expect(McpEdit.exposure(fs, .hidden, cwd: "/p").json == ["name": "fs", "scope": "project", "cwd": "/p", "exposure": "hidden"])
        #expect(McpEdit.inProject(docs, .off, cwd: "/p").json == ["name": "docs", "scope": "project", "cwd": "/p", "enabled": false, "override": true])
        #expect(McpEdit.inProject(fs, .inherit, cwd: "/p").json == ["name": "fs", "scope": "project", "cwd": "/p", "clear": true])
        #expect(McpExposure(pi: "codemode-deferred") == .codemode && McpExposure(pi: nil) == .codemode)
    }

    @Test func addFormAndSignin() throws {
        var f = McpAddForm()
        f.name = "bad name"
        #expect((try? f.action(cwd: nil).get()) == nil)
        f.name = "fs"; f.command = "npx"; f.args = "-y\n srv \n\n."; f.env = "A=b"; f.exposure = .direct; f.inProject = true
        #expect(try f.action(cwd: "/p").get() == .mcpAdd(name: "fs", local: true, cwd: "/p", command: "npx", args: ["-y", "srv", "."], env: ["A=b"], exposure: "direct"))
        // No project picked: global, whatever the switch says.
        #expect(try f.action(cwd: nil).get() == .mcpAdd(name: "fs", command: "npx", args: ["-y", "srv", "."], env: ["A=b"], exposure: "direct"))
        f.env = "nope"
        #expect(throws: McpFormError.self) { try f.action(cwd: nil).get() }
        f.useURL = true; f.url = "ftp://x"
        #expect(throws: McpFormError.self) { try f.action(cwd: nil).get() }
        f.url = "https://d/mcp"; f.headers = "Authorization=Bearer ${T}"; f.inProject = false; f.exposure = .codemode; f.description = " Docs "
        #expect(try f.action(cwd: "/p").get() == .mcpAdd(name: "fs", url: "https://d/mcp", headers: ["Authorization=Bearer ${T}"], description: "Docs"))

        let s = McpSignin(try json(#"""
        {"key":"k1","cwd":"/p","file":null,"done":false,"error":null,
         "notices":[{"message":"MCP servers need attention","type":"warning"},{"message":"Sign in to MCP server \"docs\" in your browser:\nhttps://auth/x?y=1","type":"info"}],
         "url":"https://auth/x?y=1","dialog":{"id":"d1","method":"input","title":"Waiting for sign-in","placeholder":"http://127.0.0.1:.../callback?code=..."}}
        """#))
        #expect(s.url == "https://auth/x?y=1" && s.dialogID == "d1" && !s.done)
        #expect(s.notices == ["MCP servers need attention"])
    }
}
