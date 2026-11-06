import XCTest

/// Launches the app and keeps screenshots for a person to look at (the CI job
/// exports them). With POCKETPI_UITEST_URL set (ios/ui-test-server.sh), also
/// connects to that server, opens the side menu, picks a project and a chat.
final class LaunchTests: XCTestCase {
    @MainActor
    func testConnectScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-noPush"]
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

        // The side menu: open, pick a project, the list follows.
        app.buttons["menu"].tap()
        let natter = app.buttons["project-natter"]
        XCTAssertTrue(natter.waitForExistence(timeout: 5))
        keep(app, "menu")
        natter.tap()
        XCTAssertTrue(app.navigationBars["natter"].waitForExistence(timeout: 5))
        keep(app, "project")

        // A chat, for the composer and the transcript.
        app.descendants(matching: .any)["chat-row"].firstMatch.tap()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10)
                      || app.textFields["composer"].waitForExistence(timeout: 2))
        sleep(1)
        keep(app, "chat")
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
