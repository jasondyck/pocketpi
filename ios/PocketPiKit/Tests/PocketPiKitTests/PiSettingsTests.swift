import Foundation
import Testing
@testable import PocketPiKit

@Suite struct PiSettingsTests {
    private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
    private func model(_ provider: String, _ id: String) -> ModelInfo {
        ModelInfo(["provider": .string(provider), "id": .string(id)])!
    }

    // MARK: model patterns

    @Test func patternsSplitOnlyAThinkingSuffix() {
        let a = ModelPattern("anthropic/claude-opus-4:high")
        #expect(a.pattern == "anthropic/claude-opus-4")
        #expect(a.thinking == "high")
        #expect(a.raw == "anthropic/claude-opus-4:high")
        // A colon that isn't a thinking level is part of the id.
        let b = ModelPattern("ollama/qwen3:8b")
        #expect(b.pattern == "ollama/qwen3:8b")
        #expect(b.thinking == nil)
        #expect(ModelPattern("gpt-5:XHIGH").thinking == "xhigh")
        #expect(ModelPattern(":high").pattern == ":high")
        #expect(ModelPattern(pattern: "x", thinking: "loud").raw == "x")
        #expect(ModelPattern("fake/echo-*").isGlob)
    }

    @Test func resolvesFavouritesInOrderIgnoringSuffixes() {
        let models = [model("fake", "echo-1"), model("fake", "echo-2"), model("other", "glm-5.2")]
        let list = EnabledModels.parse(["other/glm-5.2:high", "fake/echo-*", "echo-1", "missing/x"])
        #expect(EnabledModels.resolve(list, in: models).map(\.key) == ["other/glm-5.2", "fake/echo-1", "fake/echo-2"])
        #expect(EnabledModels.resolve(EnabledModels.parse(["ECHO-2"]), in: models).map(\.key) == ["fake/echo-2"])
    }

    @Test func editsTheFavouritesList() {
        var list = EnabledModels.parse(["a/1", "b/2:low"])
        list = EnabledModels.adding(ModelPattern("c/3"), to: list)
        list = EnabledModels.adding(ModelPattern("a/1:high"), to: list)   // already there
        #expect(list.map(\.raw) == ["a/1", "b/2:low", "c/3"])
        #expect(EnabledModels.moving(list, at: 2, by: -1).map(\.raw) == ["a/1", "c/3", "b/2:low"])
        #expect(EnabledModels.moving(list, at: 0, by: -1) == list)
        #expect(EnabledModels.moving(list, at: 2, by: 1) == list)
        #expect(EnabledModels.patch(list) == PiConfigPatch(set: ["enabledModels": ["a/1", "b/2:low", "c/3"]]))
        #expect(EnabledModels.patch([]) == PiConfigPatch(unset: ["enabledModels"]))
    }

    // MARK: plain settings

    @Test func specsCoverTheRPCKeysAndNoTUIOnes() {
        let keys = Set(PiSettings.specs.map(\.key))
        for k in ["defaultThinkingLevel", "steeringMode", "followUpMode", "compaction.enabled", "compaction.reserveTokens",
                  "compaction.keepRecentTokens", "retry.enabled", "retry.maxRetries", "images.autoResize",
                  "images.blockImages", "hideThinkingBlock"] {
            #expect(keys.contains(k), "\(k)")
        }
        for k in ["theme", "tuiMode", "editorPaddingX", "terminal.showImages", "doubleEscapeAction"] {
            #expect(!keys.contains(k), "\(k)")
        }
        #expect(keys.count == PiSettings.specs.count)
        #expect(PiSettings.specs(in: .queue).map(\.key) == ["steeringMode", "followUpMode"])
    }

    @Test func readsValuesAndFallsBackToPiDefaults() throws {
        let data = try json(#"{"compaction":{"enabled":false,"reserveTokens":9000},"steeringMode":"all","retry":{"maxRetries":"x"},"defaultThinkingLevel":"loud","theme":"dark","hideThinkingBlock":null}"#)
        let s = { PiSettings.spec($0)! }
        #expect(PiSettings.bool(data, s("compaction.enabled")) == false)
        #expect(PiSettings.int(data, s("compaction.reserveTokens")) == 9000)
        #expect(PiSettings.int(data, s("compaction.keepRecentTokens")) == 20000)
        #expect(PiSettings.string(data, s("steeringMode")) == "all")
        #expect(PiSettings.string(data, s("followUpMode")) == "one-at-a-time")
        // Wrong types and unknown choices read as pi's default.
        #expect(PiSettings.int(data, s("retry.maxRetries")) == 3)
        #expect(PiSettings.string(data, s("defaultThinkingLevel")) == "medium")
        #expect(PiSettings.bool(data, s("retry.enabled")))
        #expect(PiSettings.isSet(data, s("steeringMode")))
        #expect(!PiSettings.isSet(data, s("followUpMode")))
        #expect(!PiSettings.isSet(data, s("hideThinkingBlock")))
    }

    @Test func patchesSetOrGoBackToTheDefault() {
        let spec = PiSettings.spec("retry.maxRetries")!
        #expect(PiSettings.patch(spec, 5) == PiConfigPatch(set: ["retry.maxRetries": 5]))
        #expect(PiSettings.patch(spec, nil) == PiConfigPatch(unset: ["retry.maxRetries"]))
    }

    @Test func parsesNumbers() {
        let spec = PiSettings.spec("retry.maxRetries")!
        #expect(PiSettings.parseNumber(" 7 ", spec) == .success(7))
        #expect(PiSettings.parseNumber("", spec) == .success(nil))
        #expect(PiSettings.parseNumber("1.5", spec) == .failure(.notANumber))
        #expect(PiSettings.parseNumber("-1", spec) == .failure(.tooSmall(0)))
        #expect(PiSettings.parseNumber("101", spec) == .failure(.tooBig(100)))
        #expect(PiSettings.parseNumber("16_384", PiSettings.spec("compaction.reserveTokens")!) == .success(16384))
        #expect(PiSettings.parseNumber("20,000", PiSettings.spec("compaction.keepRecentTokens")!) == .success(20000))
    }

    // MARK: models

    @Test func defaultModelReadsAndPatches() throws {
        #expect(PiSettings.defaultModel(try json(#"{"defaultProvider":"fake","defaultModel":"echo-1"}"#)) == "fake/echo-1")
        #expect(PiSettings.defaultModel(try json(#"{"defaultModel":"echo-1"}"#)) == "echo-1")
        #expect(PiSettings.defaultModel(try json("{}")) == nil)
        #expect(PiSettings.defaultModelPatch(model("fake", "echo-2"))
            == PiConfigPatch(set: ["defaultProvider": "fake", "defaultModel": "echo-2"]))
        #expect(PiSettings.defaultModelPatch(nil) == PiConfigPatch(unset: ["defaultProvider", "defaultModel"]))
    }

    @Test func perModelThinkingEscapesDots() throws {
        let data = try json(#"{"modelThinkingLevels":{"z/m":"low","a/glm-5.2":"high","bad":1}}"#)
        #expect(PiSettings.modelThinking(data).map(\.model) == ["a/glm-5.2", "z/m"])
        #expect(PiSettings.modelThinkingPatch("a/glm-5.2", "max") == PiConfigPatch(set: [#"modelThinkingLevels.a/glm-5\.2"#: "max"]))
        #expect(PiSettings.modelThinkingPatch("a/glm-5.2", nil) == PiConfigPatch(unset: [#"modelThinkingLevels.a/glm-5\.2"#]))
    }

    @Test func summarisesCompactionOverrides() throws {
        let data = try json(#"{"compaction":{"modelOverrides":{"b/x":{"reserveTokens":1000,"keepRecentTokens":2000},"a/y":{}}}}"#)
        let o = PiSettings.compactionOverrides(data)
        #expect(o.map(\.model) == ["a/y", "b/x"])
        #expect(o[1].summary == "reserve 1000 · keep 2000")
        #expect(o[0].summary == "custom")
    }
}
