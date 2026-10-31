import XCTest

/// Starting a routine by hand, and the words the Routines screen uses for what each kind does.
final class RoutineStartUITest: XCTestCase {

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheRoutinesScreenSaysWhatEachKindDoes() {
        let app = launch(["--routines"])
        XCTAssertTrue(app.navigationBars["Routines"].waitForExistence(timeout: 8))
        // No footer paragraph and no capital kind tags: the trigger line says when it starts.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'start when you press Start'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["SCHEDULED"].exists)
        XCTAssertFalse(app.staticTexts["NUDGE"].exists)
        // It promised a notification that was never sent.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'notification'")).firstMatch.exists)
    }

    func testARoutineWithNothingToPlayHasNoStartButton() {
        let app = launch(["--routines"])
        XCTAssertTrue(app.navigationBars["Routines"].waitForExistence(timeout: 8))
        // The sample routines have nothing set: a button that plays nothing is worse than none.
        XCTAssertFalse(app.buttons["Start Wake"].exists)
        XCTAssertFalse(app.buttons["Start Commute"].exists)
    }

    func testAManualRoutineStartsFromItsRow() {
        let app = launch(["--routines", "--routine-start-sample"])
        XCTAssertTrue(app.navigationBars["Routines"].waitForExistence(timeout: 8))
        let start = app.buttons["Start Wind down walk"]
        for _ in 0..<5 where !(start.exists && start.isHittable) { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 6), "a Manual routine had no button anywhere")
        start.tap()
        XCTAssertTrue(app.staticTexts["Started Wind down walk"].waitForExistence(timeout: 5))
        keep(app, "routine started")
    }
}
