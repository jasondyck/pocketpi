import Testing
@testable import PocketPiKit

@Suite struct ChatFeaturesTests {
    @Test func featureStateIsParsedAndKeptOutOfGenericChips() throws {
        var ui = ExtensionUIState()
        ui.apply(try JSONValue.parse(#"{"method":"setStatus","statusKey":"pp-goal","statusText":"{\"phase\":\"active\",\"rounds\":2}"}"#))
        ui.apply(try JSONValue.parse(#"{"method":"setStatus","statusKey":"git","statusText":"main"}"#))
        #expect(ui.feature("pp-goal")?["phase"]?.string == "active")
        #expect(ui.feature("pp-goal")?["rounds"]?.int == 2)
        #expect(ui.feature("pp-todo") == nil)
        #expect(ui.genericStatuses.map(\.key) == ["git"])
        ui.apply(try JSONValue.parse(#"{"method":"setStatus","statusKey":"pp-goal"}"#))
        #expect(ui.feature("pp-goal") == nil)
    }
}
