import XCTest

/// Launches the app and keeps screenshots for a person to look at (the CI job
/// exports them). With POCKETPI_UITEST_URL set, also connects to that server
/// and opens a new chat.
final class LaunchTests: XCTestCase {
    @MainActor
    func testConnectScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset"]
        app.launch()
        let address = app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        keep(app, "connect")

        guard let url = ProcessInfo.processInfo.environment["POCKETPI_UITEST_URL"] else { return }
        address.tap()
        address.typeText(url)
        app.buttons["connect"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 15))
        keep(app, "chats")
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
