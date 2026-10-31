import XCTest

/// A day with more all-day events than its row holds (`--all-day-crowded`: two Busy, four Free).
/// The ones that block the day are the ones shown, and "+N more" opens the rest — it used to say
/// how many and open nothing, with a Busy event among the ones it hid.
final class AllDayCrowdedUITest: XCTestCase {
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [mode, "--all-day-preview", "--all-day-crowded", "--disable-icloud", "--no-space-sync", "--ui-audit",
                               "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    func testTheWeekShowsWhatBlocksTheDayAndMoreOpensTheRest() {
        let app = launch("--week")
        let more = app.buttons["allDay.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        // Only calendar events live here now. Routines share the reminders band instead.
        XCTAssertEqual(more.label, "4 more with no time")
        XCTAssertTrue(app.buttons["Out of office, all day, busy"].exists, "both Busy events are in the row")
        XCTAssertFalse(app.buttons["Bins out, all day, free"].exists)

        more.tap()
        XCTAssertTrue(app.buttons["Bins out, all day, free"].waitForExistence(timeout: 3), "the rest, a tap away")
        XCTAssertTrue(app.buttons["Rosh Hashanah, all day, free"].exists)
        XCTAssertFalse(app.otherElements["allDay.list"].buttons["Workout, no set time"].exists,
                       "routines must not be duplicated in the all-day overflow")
    }

    func testTheDayShowsEveryOneWithoutScrollingSideways() {
        let app = launch("--day")
        let last = app.buttons["Bins out, all day, free"]
        XCTAssertTrue(last.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(last.isHittable, "wrapped onto its own line, not past the edge")
        XCTAssertTrue(app.buttons["Out of office, all day, busy"].isHittable)
    }
}
