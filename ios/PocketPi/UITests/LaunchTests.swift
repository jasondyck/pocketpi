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

        // Workflows: the list, one workflow's runs, a run's stages, the Run sheet.
        app.descendants(matching: .any)["project-workflows"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Workflows"].waitForExistence(timeout: 5))
        keep(app, "workflows")
        app.staticTexts["clipt: PR review + fix"].firstMatch.tap()
        XCTAssertTrue(app.buttons["run-workflow"].waitForExistence(timeout: 5))
        keep(app, "workflow")
        // The suggested improvement and its diff.
        XCTAssertTrue(app.buttons["apply-proposal"].waitForExistence(timeout: 10))
        app.buttons["Show changes"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Changes"].waitForExistence(timeout: 5))
        keep(app, "workflow-diff")
        app.navigationBars["Changes"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["run-workflow"].waitForExistence(timeout: 5))
        app.swipeUp()
        keep(app, "workflow-improve")
        app.swipeDown()
        // The runs are below the suggestion and Improvements: scroll to them.
        let runRow = app.descendants(matching: .any)["run-row"].firstMatch
        for _ in 0..<4 where !runRow.isHittable { app.swipeUp() }
        XCTAssertTrue(runRow.waitForExistence(timeout: 10))
        runRow.tap()
        XCTAssertTrue(app.buttons["run-again"].waitForExistence(timeout: 10))
        let stage = app.descendants(matching: .any)["stage-row"].firstMatch
        if stage.waitForExistence(timeout: 3) { stage.tap(); sleep(1) }
        keep(app, "run")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["run-workflow"].waitForExistence(timeout: 5))
        app.buttons["run-workflow"].tap()
        XCTAssertTrue(app.buttons["start-run"].waitForExistence(timeout: 5))
        keep(app, "start-run")
        app.buttons["Cancel"].firstMatch.tap()
        sleep(1)
        // Edit in chat: a new chat in the project with the request started.
        app.buttons["workflow-menu"].firstMatch.tap()
        app.buttons["Edit in chat"].firstMatch.tap()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10)
                      || app.textFields["composer"].waitForExistence(timeout: 2))
        sleep(1)
        keep(app, "edit-in-chat")
        // Back to Projects (chat → clipt's chats → projects), then Workflows again.
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        sleep(1)
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(natter.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["project-workflows"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Workflows"].waitForExistence(timeout: 5))
        app.staticTexts["clipt: PR review + fix"].firstMatch.tap()
        XCTAssertTrue(app.buttons["run-workflow"].waitForExistence(timeout: 5))
        // Back out to Projects (iPhone: workflow → list → projects).
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Workflows"].waitForExistence(timeout: 5))
        app.navigationBars["Workflows"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(natter.waitForExistence(timeout: 5))
        natter.tap()
        XCTAssertTrue(app.navigationBars["natter"].waitForExistence(timeout: 5))
        keep(app, "project")

        // The Chat tab at the top: plain chats, any model, local ones too.
        app.segmentedControls.buttons["Chat"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
        let plainChat = app.descendants(matching: .any)["chat-tab-row"].firstMatch
        XCTAssertTrue(plainChat.waitForExistence(timeout: 10))
        keep(app, "chat-tab")
        plainChat.tap()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10)
                      || app.textFields["composer"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.segmentedControls.buttons["Chat"].exists)
        app.descendants(matching: .any)["model-button"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Select model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["local-tiny-chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["local-other-chat"].exists)
        keep(app, "local-models")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)
        app.navigationBars.firstMatch.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
        // Back to Work, where it was left (natter's chats).
        app.segmentedControls.buttons["Work"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["natter"].waitForExistence(timeout: 5))

        // A chat, for the composer and the transcript.
        app.descendants(matching: .any)["chat-row"].firstMatch.tap()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10)
                      || app.textFields["composer"].waitForExistence(timeout: 2))
        // pi started natter's deploy check here (ui-test-server.sh); it's
        // still going, so a line above the composer says so.
        let activeRun = app.descendants(matching: .any)["active-run"].firstMatch
        XCTAssertTrue(activeRun.waitForExistence(timeout: 10))
        sleep(1)
        keep(app, "chat")
        activeRun.tap()
        XCTAssertTrue(app.navigationBars["natter: deploy check"].waitForExistence(timeout: 5))
        keep(app, "active-run-opened")
        // That page's own Back (the first bar's first button missed in light mode).
        app.navigationBars["natter: deploy check"].buttons["BackButton"].tap()
        XCTAssertTrue(activeRun.waitForExistence(timeout: 5))

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

        // Typing "/" offers pi's slash commands; a tap fills the composer.
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        composer.tap()
        composer.typeText("/fix")
        let fixTests = app.descendants(matching: .any)["slash-fix-tests"].firstMatch
        XCTAssertTrue(fixTests.waitForExistence(timeout: 5))
        keep(app, "slash")
        fixTests.tap()
        XCTAssertEqual(composer.value as? String, "/fix-tests ")
        XCTAssertFalse(fixTests.exists)
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11))

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
