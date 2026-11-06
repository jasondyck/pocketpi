import XCTest

/// Launches the app and keeps screenshots for a person to look at (the CI job
/// exports them). With POCKETPI_UITEST_URL set (ios/ui-test-server.sh), also
/// connects to that server, goes back to Projects, picks a project and a chat.
final class LaunchTests: XCTestCase {
    @MainActor
    func testConnectScreen() throws {
        try walkThrough(dark: false)
    }

    /// The same screens in dark mode, where the lime signal shows.
    @MainActor
    func testDarkMode() throws {
        try walkThrough(dark: true)
    }

    @MainActor
    private func walkThrough(dark: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-noPush"] + (dark ? ["-dark"] : [])
        app.launch()
        let address = app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        keep(app, "connect")

        guard let url = ProcessInfo.processInfo.environment["POCKETPI_UITEST_URL"] else { return }
        address.tap()
        address.typeText(url)
        app.buttons["connect"].tap()
        // Opens one step in, on All chats (like Mail on Inbox).
        XCTAssertTrue(app.navigationBars["All chats"].waitForExistence(timeout: 15))
        keep(app, "chats")

        // Back to the projects list, pick one, the list follows.
        app.navigationBars["All chats"].buttons.element(boundBy: 0).tap()
        let natter = app.descendants(matching: .any)["project-natter"].firstMatch
        XCTAssertTrue(natter.waitForExistence(timeout: 5))
        keep(app, "projects")
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
        let dark = app.launchArguments.contains("-dark")
        a.name = dark ? "dark-\(name)" : name
        a.lifetime = .keepAlways
        add(a)
    }
}
