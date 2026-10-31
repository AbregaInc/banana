import XCTest

/// Deleting from the event screen is instant: it closes at once, the event is off the day, and an
/// Undo toast is up — Google hears about it only when that window closes. It used to sit there,
/// open, until Google answered. Undo here, so the preview never reaches the network.
final class EventDeleteUITest: XCTestCase {
    func testDeletingClosesAtOnceWithUndo() {
        let app = XCUIApplication()
        app.launchArguments = ["--event-editor", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 8))

        let delete = app.buttons["Delete event"]
        for _ in 0..<6 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        delete.tap()
        let onlyThis = app.buttons["Delete this event only"]
        XCTAssertTrue(onlyThis.waitForExistence(timeout: 3), "a repeating event asks which")
        XCTAssertTrue(app.buttons["Delete this and following"].exists)
        onlyThis.tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.navigationBars["Edit event"])
        waitForExpectations(timeout: 1.5)   // the sheet's own animation, no network
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 1.5), "the toast offers Undo")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Deleted")).firstMatch.exists)
        undo.tap()
    }
}
