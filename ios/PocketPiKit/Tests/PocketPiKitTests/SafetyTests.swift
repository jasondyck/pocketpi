import Foundation
import Testing
@testable import PocketPiKit

@Suite struct SafetyTests {
    private func doc(_ json: String) throws -> PolicyDocument {
        PolicyDocument(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    @Test func readsOrderedRulesAndPlainActions() throws {
        let d = try doc(#"""
        {"exists": true, "path": "/x/config.json",
         "data": {"promptTimeoutMs": 600000, "permission": {"bash": {"*": "allow"}, "external_directory": "ask",
                  "external_directory_write": {"*": "deny"}}},
         "rules": {"bash": [["*", "allow"], ["rm *", "ask"], ["sudo *", {"action": "deny", "reason": "no root"}], ["bad", "maybe"]],
                   "external_directory_write": [["*", {"action": "deny"}]]}}
        """#)
        #expect(d.rules(for: "bash").map(\.pattern) == ["*", "rm *", "sudo *"])
        #expect(d.rules(for: "bash")[2].reason == "no root")
        #expect(d.rules(for: "external_directory") == [PolicyRule(pattern: "*", action: .ask)])
        #expect(d.rules(for: "path").isEmpty)
        #expect(d.surfaces == ["bash", "path", "external_directory", "external_directory_write"])
        #expect(d.summary(for: "bash") == "allow by default · 1 ask · 1 deny")
        #expect(d.summary(for: "path") == "not set (uses the default)")
        #expect(Safety.timeoutText(d.promptTimeoutMs) == "Unanswered prompts are denied after 10 min")
        #expect(Safety.timeoutText(nil) == "Unanswered prompts wait forever")
        #expect(Safety.timeoutText(1500) == "Unanswered prompts are denied after 1 s")
    }

    @Test func writesRulesInOrderAndDropsBlankOnes() throws {
        let p = Safety.setRules("external_directory", [
            PolicyRule(pattern: "*", action: .ask),
            PolicyRule(pattern: "  ", action: .allow),
            PolicyRule(pattern: "~/.cargo/registry/*", action: .allow),
            PolicyRule(pattern: "/etc/*", action: .deny, reason: "system"),
            PolicyRule(pattern: "/opt/*", action: .deny, reason: " "),
        ])
        #expect(p.set["permission.external_directory"] == [["*", "ask"], ["~/.cargo/registry/*", "allow"],
                                                            ["/etc/*", ["action": "deny", "reason": "system"]], ["/opt/*", "deny"]])
        #expect(p.unset.isEmpty)
    }

    @Test func knowsWhetherThePackageIsInstalled() {
        #expect(!Safety.isInstalled(settings: [:]))
        #expect(!Safety.isInstalled(settings: ["packages": ["npm:pi-subagents"]]))
        #expect(Safety.isInstalled(settings: ["packages": ["npm:pi-subagents", "npm:@gotgenes/pi-permission-system@42.0.0"]]))
        #expect(Safety.isInstalled(settings: ["packages": [["source": "npm:@gotgenes/pi-permission-system"]]]))
    }

    @Test func projectModes() throws {
        #expect(Safety.mode(of: PolicyDocument()) == .standard)
        #expect(Safety.mode(of: try doc(#"{"exists": true, "data": {}}"#)) == .standard)
        #expect(Safety.mode(of: try doc(#"{"exists": true, "data": {"$schema": "x", "permission": {}}}"#)) == .standard)
        #expect(Safety.mode(of: try doc(#"{"exists": true, "data": {"permission": {"bash": {}}}}"#)) == .standard)
        #expect(Safety.mode(of: try doc(#"{"exists": true, "data": {"yoloMode": true}}"#)) == .off)
        #expect(Safety.mode(of: try doc(#"{"exists": true, "data": {"permission": {"bash": {"*": "ask"}, "write": "ask", "edit": "ask"}}}"#)) == .strict)
        #expect(Safety.mode(of: try doc(#"{"exists": true, "data": {"permission": {"bash": "ask", "write": "ask", "edit": "ask"}}}"#)) == .strict)
        #expect(Safety.mode(of: try doc(#"{"exists": true, "data": {"permission": {"bash": {"npm *": "deny"}}}}"#)) == .custom)
        #expect(Safety.mode(of: try doc(#"{"exists": true, "data": {"yoloMode": false}}"#)) == .custom)

        let off = Safety.patch(for: .off)
        #expect(off.set == ["yoloMode": true])
        #expect(off.unset == ["permission.bash.*", "permission.write", "permission.edit"])
        let strict = Safety.patch(for: .strict)
        #expect(strict.set == ["permission.bash.*": "ask", "permission.write": "ask", "permission.edit": "ask"])
        #expect(strict.unset == ["yoloMode"])
        #expect(Safety.patch(for: .standard).set.isEmpty)
        #expect(Safety.patch(for: .standard).unset.count == 4)
    }

    @Test func projectTrust() {
        let trust: JSONValue = ["/home/me/work": true, "/home/me/work/sketchy": false]
        #expect(Safety.isTrusted("/home/me/work/app", trust: trust, defaultTrust: nil))
        #expect(Safety.isTrusted("/home/me/work", trust: trust, defaultTrust: nil))
        #expect(!Safety.isTrusted("/home/me/work/sketchy/x", trust: trust, defaultTrust: "always"))
        #expect(!Safety.isTrusted("/home/me/other", trust: trust, defaultTrust: "ask"))
        #expect(Safety.isTrusted("/home/me/other/", trust: trust, defaultTrust: "always"))
        #expect(Safety.isTrusted("/x", trust: ["/": true], defaultTrust: nil))
    }

    @Test func dialogNoticesFromTheRunsStream() {
        let n = DialogNotice(["type": "dialog_pending", "key": "k1", "id": "d1", "title": "Permission Required · p",
                              "body": "pi wants to run: rm -rf junk", "url": "/?s=/x.jsonl"])
        #expect(n?.body == "pi wants to run: rm -rf junk")
        #expect(DialogNotice(["type": "notice", "key": "k", "id": "d"]) == nil)
    }

    @Test func helloReplaysPendingDialogs() {
        var t = Transcript()
        let fx = t.apply(["type": "pocketpi_hello", "ui": [], "dialogs": [
            ["type": "extension_ui_request", "id": "d1", "method": "select", "title": "Permission Required\ntool : bash",
             "options": ["Yes", "No"]],
        ]])
        #expect(fx.count == 2)
        guard case .reloadSnapshot = fx[0], case .extensionRequest(let r) = fx[1] else {
            Issue.record("expected a snapshot reload, then the dialog"); return
        }
        #expect(r.id == "d1")
        #expect(r.options == ["Yes", "No"])
    }
}
