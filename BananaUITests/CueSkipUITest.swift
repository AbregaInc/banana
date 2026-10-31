import XCTest

/// Skipping a routine moment shows that it worked: a toast names it, with Undo, and the moment
/// reads as skipped when its sheet opens again. A skip used to change nothing on screen until the
/// timeline recomputed.
final class CueSkipUITest: XCTestCase {
    func testASkipSaysSoAndCanBeUndone() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--week", "-planMode", "week", "--reset-day-scroll-offset", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        var cue = try revealCalendarButton("Wind", in: app)
        cue.tap()
        let skip = app.buttons["Skip this one"]
        if app.buttons["Restore"].waitForExistence(timeout: 1) {
            app.buttons["Restore"].tap()
            cue = try revealCalendarButton("Wind", in: app)
            cue.tap()
        }
        XCTAssertTrue(skip.waitForExistence(timeout: 3))
        skip.tap()

        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Skipped Wind")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 2), "the skip names what it skipped\n\(app.debugDescription)")
        app.buttons["toast.undo"].tap()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3))
        cue = try revealCalendarButton("Wind", in: app)
        cue.tap()
        XCTAssertTrue(app.buttons["Skip this one"].waitForExistence(timeout: 3), "Undo brings it back")

        // Skipped, it reads as skipped the moment it's opened again; Restore says so too.
        app.buttons["Skip this one"].tap()
        cue = try revealCalendarButton("Wind", in: app)
        cue.tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 3), "the moment is skipped at once")
        app.buttons["Restore"].tap()
        let back = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "is back")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 2), app.debugDescription)
    }
}
