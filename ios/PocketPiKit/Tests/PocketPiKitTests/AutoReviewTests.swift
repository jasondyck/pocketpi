import Foundation
import Testing
@testable import PocketPiKit

@Suite struct AutoReviewTests {
    private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    @Test func knowsWhetherItIsInstalledAndOn() throws {
        #expect(!AutoReview.isInstalled(settings: [:]))
        #expect(!AutoReview.isInstalled(settings: ["packages": ["npm:@gotgenes/pi-permission-system@42.0.0"]]))
        #expect(AutoReview.isInstalled(settings: ["packages": ["npm:pi-subagents", "npm:@mzwing/pi-permission-auto-review@1.0.1"]]))
        #expect(AutoReview.isInstalled(settings: ["packages": [["source": "npm:@mzwing/pi-permission-auto-review"]]]))

        #expect(!AutoReview.isOn(PolicyDocument()))
        #expect(!AutoReview.isOn(PolicyDocument(exists: true, data: ["authorizerChain": ["other"]])))
        #expect(AutoReview.isOn(PolicyDocument(exists: true, data: ["authorizerChain": ["other", "auto-review"]])))

        #expect(AutoReview.status(installed: false, on: true) == "Not installed: pi's asks come to you")
        #expect(AutoReview.status(installed: true, on: false) == "Installed and off: pi's asks come to you.")
        #expect(AutoReview.status(installed: true, on: true).hasPrefix("A model answers"))
    }

    @Test func readsTheConfigWithThePresetsDefaults() {
        let none = AutoReviewConfig()
        #expect(none.preset == .codex)
        #expect(none.modelKey == nil)
        #expect(none.preset.defaultModel == "openai-codex/codex-auto-review")
        #expect(none.preset.defaultReasoning == "low")
        #expect(none.reasoning == nil && none.followUpReviews == nil)

        let c = AutoReviewConfig(exists: true, data: ["preset": "claude-code", "provider": "opencode-go", "model": "claude-haiku-5-5",
                                                      "reasoning": "high", "followUpReviews": "off"])
        #expect(c.preset == .claudeCode)
        #expect(c.preset.defaultModel == "anthropic/claude-sonnet-5")
        #expect(c.preset.defaultReasoning == "high")
        #expect(c.modelKey == "opencode-go/claude-haiku-5-5")
        #expect(c.reasoning == "high")
        #expect(c.followUpReviews == "off")
        // Half a model, or values the extension doesn't know, read as the defaults.
        let odd = AutoReviewConfig(exists: true, data: ["preset": "gemini", "provider": "x", "reasoning": "max", "followUpReviews": "never"])
        #expect(odd.preset == .codex)
        #expect(odd.modelKey == nil)
        #expect(odd.reasoning == nil && odd.followUpReviews == nil)
    }

    @Test func warnsAboutClaudeThroughOpenCodeGo() {
        func cfg(_ d: [String: JSONValue]) -> AutoReviewConfig { AutoReviewConfig(exists: true, data: .object(d)) }
        #expect(cfg(["provider": "opencode-go", "model": "claude-haiku-5-5"]).claudeViaOpenCodeGo, "unset is auto")
        #expect(cfg(["provider": "opencode-go", "model": "Claude-Sonnet-5", "followUpReviews": "always"]).claudeViaOpenCodeGo)
        #expect(!cfg(["provider": "opencode-go", "model": "claude-haiku-5-5", "followUpReviews": "off"]).claudeViaOpenCodeGo)
        #expect(!cfg(["provider": "opencode-go", "model": "glm-5.2"]).claudeViaOpenCodeGo)
        #expect(!cfg(["provider": "anthropic", "model": "claude-haiku-5-5"]).claudeViaOpenCodeGo)
    }

    @Test func patchesTheConfig() {
        #expect(AutoReviewConfig.presetPatch(.claudeCode) == PiConfigPatch(set: ["preset": "claude-code"]))
        #expect(AutoReviewConfig.modelPatch("opencode-go/claude-haiku-5-5") == PiConfigPatch(set: ["provider": "opencode-go", "model": "claude-haiku-5-5"]))
        #expect(AutoReviewConfig.modelPatch("openrouter/anthropic/claude-x") == PiConfigPatch(set: ["provider": "openrouter", "model": "anthropic/claude-x"]))
        #expect(AutoReviewConfig.modelPatch("") == PiConfigPatch(unset: ["provider", "model"]))
        #expect(AutoReviewConfig.reasoningPatch("xhigh") == PiConfigPatch(set: ["reasoning": "xhigh"]))
        #expect(AutoReviewConfig.reasoningPatch("") == PiConfigPatch(unset: ["reasoning"]))
        #expect(AutoReviewConfig.followUpPatch("off") == PiConfigPatch(set: ["followUpReviews": "off"]))
        #expect(AutoReviewConfig.followUpPatch("") == PiConfigPatch(unset: ["followUpReviews"]))
        #expect(AutoReview.followUps.map(AutoReview.followUpLabel) == ["Auto", "Always", "Off"])
    }

    @Test func decodesAndDescribesReviews() throws {
        let data = Data(#"""
        {"reviews": [
          {"id": "c", "at": "2026-11-09T12:00:00.000Z", "outcome": "defer", "surface": "bash", "command": "git push --force",
           "then": "denied", "durationMs": 12000, "errorCategory": "provider-error", "model": "m"},
          {"id": "b", "at": "2026-11-09T11:55:00Z", "outcome": "deny", "surface": "external_directory", "path": "/etc/x",
           "reason": "[Scope] not asked for", "durationMs": 6000, "model": "m", "provider": "p", "stage": "slow"},
          {"id": "a", "at": "2026-11-09T09:00:00.000Z", "outcome": "allow", "surface": "bash", "command": "rm -rf build",
           "durationMs": 4000, "model": "claude-haiku-5-5"},
          {"id": "d", "outcome": "defer", "surface": "bash"}
        ], "log": "/x/review.jsonl"}
        """#.utf8)
        let log = try JSONDecoder().decode(AutoReviewLog.self, from: data)
        #expect(log.reviews.map(\.id) == ["c", "b", "a", "d"])
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-09T12:00:30Z"))
        let (c, b, a, d) = (log.reviews[0], log.reviews[1], log.reviews[2], log.reviews[3])

        #expect(c.outcomeLabel == "Asked you · you denied")
        #expect(c.kind == .asked)
        #expect(c.detail(now: now) == "12.0 s · provider-error · just now")
        #expect(b.outcomeLabel == "Denied")
        #expect(b.subject == "/etc/x")
        #expect(b.reason == "[Scope] not asked for")
        #expect(b.detail(now: now) == "6.0 s · m · 6 min ago")
        #expect(a.outcomeLabel == "Allowed")
        #expect(a.subject == "rm -rf build")
        #expect(a.detail(now: now) == "4.0 s · claude-haiku-5-5 · 3 h ago")
        #expect(d.outcomeLabel == "Asked you")
        #expect(d.subject == "bash")
        #expect(d.detail(now: now) == "")

        #expect(AutoReviewRecord.ago(now.addingTimeInterval(-3 * 86400), now: now) == "3 d ago")
        #expect(AutoReviewRecord.ago(now.addingTimeInterval(60), now: now) == "just now")
    }
}
