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

        // Swipe actions on a chat (Archive, Rename), then put the row back.
        let firstRow = app.descendants(matching: .any)["chat-row"].firstMatch
        firstRow.swipeLeft()
        sleep(1)
        keep(app, "swipe")
        firstRow.swipeRight()

        // Back to the projects list, pick one, the list follows.
        app.navigationBars["All chats"].buttons.element(boundBy: 0).tap()
        let natter = app.descendants(matching: .any)["project-natter"].firstMatch
        XCTAssertTrue(natter.waitForExistence(timeout: 5))
        keep(app, "projects")

        // Approvals: the waiting run and its review text.
        app.descendants(matching: .any)["project-approvals"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Approvals"].waitForExistence(timeout: 5))
        keep(app, "approvals")
        app.descendants(matching: .any)["approval-row"].firstMatch.tap()
        XCTAssertTrue(app.buttons["approve"].waitForExistence(timeout: 5))
        keep(app, "approval")
        app.navigationBars["Approval"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Approvals"].waitForExistence(timeout: 5))
        app.navigationBars["Approvals"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(natter.waitForExistence(timeout: 5))
        natter.tap()
        XCTAssertTrue(app.navigationBars["natter"].waitForExistence(timeout: 5))
        keep(app, "project")

        // A chat, for the composer and the transcript.
        app.descendants(matching: .any)["chat-row"].firstMatch.tap()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10)
                      || app.textFields["composer"].waitForExistence(timeout: 2))
        sleep(1)
        keep(app, "chat")

        // Thinking and tool calls fold into one line; it opens to the steps.
        let activity = app.descendants(matching: .any)["activity-row"].firstMatch
        if activity.waitForExistence(timeout: 3) {
            activity.tap()
            sleep(1)
            keep(app, "activity-open")
            activity.tap()
        }

        // The model button in the message box opens the model sheet.
        app.descendants(matching: .any)["model-button"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Select model"].waitForExistence(timeout: 5))
        keep(app, "models")
        app.buttons["More models"].tap()
        XCTAssertTrue(app.navigationBars["More models"].waitForExistence(timeout: 5))
        keep(app, "more-models")
        // Above the sheet: dismisses it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)

        // The chat's "…" menu (context, thinking, rename, compact).
        app.descendants(matching: .any)["chat-menu"].firstMatch.tap()
        sleep(1)
        keep(app, "chat-menu")
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
