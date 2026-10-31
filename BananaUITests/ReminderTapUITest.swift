import XCTest

/// A reminder in the plan: its words open it, its circle ticks it, and a tick can be undone.
/// (A tap anywhere on it used to tick it, a ticked one left the line, and nothing took it back,
/// so one too long to read in the line could only be read by completing it.)
final class ReminderTapUITest: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--plan", "-planMode", "day", "--outstanding-reminders",
                               "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    func testTheWordsOpenAReminderWithoutCompletingIt() {
        let app = launch()
        let tick = app.buttons["Mark Call the plumber done"]
        XCTAssertTrue(tick.waitForExistence(timeout: 10), app.debugDescription)

        app.buttons["Open Call the plumber"].tap()
        XCTAssertTrue(app.navigationBars["Edit reminder"].waitForExistence(timeout: 4))
        // Its title is there to read, on as many lines as it needs.
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "Call the plumber")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()

        XCTAssertTrue(tick.waitForExistence(timeout: 4), "reading it didn't complete it")
    }

    func testTheCircleTicksAndUndoTakesItBack() {
        let app = launch()
        let tick = app.buttons["Mark Call the plumber done"]
        XCTAssertTrue(tick.waitForExistence(timeout: 10), app.debugDescription)

        tick.tap()
        XCTAssertTrue(app.staticTexts["Completed \u{201C}Call the plumber\u{201D}"].waitForExistence(timeout: 3),
                      "a tick says what it did")
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        undo.tap()

        XCTAssertTrue(app.buttons["Mark Call the plumber done"].waitForExistence(timeout: 4),
                      "undone: it's outstanding again")
        XCTAssertFalse(app.buttons["Mark Call the plumber not done"].exists)
    }

    func testTheCircleTappedAgainIsTheUndo() {
        let app = launch()
        let tick = app.buttons["Mark Renew passport done"]
        XCTAssertTrue(tick.waitForExistence(timeout: 10), app.debugDescription)
        tick.tap()
        let untick = app.buttons["Mark Renew passport not done"]
        // A ticked reminder stays in the line while its toast is up, to be un-ticked in place.
        if untick.waitForExistence(timeout: 2) {
            untick.tap()
            XCTAssertTrue(app.buttons["Mark Renew passport done"].waitForExistence(timeout: 4))
        } else {
            // Gone from the line at once: Undo is the toast's.
            app.buttons["Undo"].tap()
            XCTAssertTrue(app.buttons["Mark Renew passport done"].waitForExistence(timeout: 4))
        }
    }

    // MARK: On the grid

    /// A reminder's block among the hours. `-mobileWeekHourHeight`: the simulator's stored zoom
    /// would otherwise decide how far down the evening is.
    private func launchGrid(mode: String) throws -> XCUIApplication {
        // The dedicated fixture keeps the wide and overlapping reminders at midday.
        // It does not drift into Wind down or tomorrow during an evening release run.
        let app = XCUIApplication()
        app.launchArguments = ["--plan", "--reminder-grid-preview", "-mobileDayScrollOffset", "0",
                               "-planMode", mode, "-mobileWeekHourHeight", "56",
                               "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    func testOnTheDayGridTheBlockOpensAndItsCircleTicks() throws {
        let app = try launchGrid(mode: "day")
        let tick = app.buttons["Mark Review launch notes done"]
        _ = try revealCalendarButton("Review launch notes,", in: app, referenceLabelPattern: "12\\s*PM")
        XCTAssertTrue(tick.isHittable, "the block's own circle\n\(app.debugDescription)")

        // The words: the far side of the block from the circle.
        let block = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Review launch notes")).firstMatch
        XCTAssertTrue(block.exists, app.debugDescription)
        block.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Edit reminder"].waitForExistence(timeout: 4), "the block opens the reminder")
        XCTAssertTrue(app.buttons["task.tick"].exists, "and it can be ticked from there")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(tick.waitForExistence(timeout: 4), "reading it didn't complete it")

        tick.tap()
        XCTAssertTrue(app.staticTexts["Completed \u{201C}Review launch notes\u{201D}"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mark Review launch notes not done"].waitForExistence(timeout: 2),
                      "ticked on its block at once")
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Mark Review launch notes done"].waitForExistence(timeout: 4), "undone")
    }

    func testABlockTooNarrowForACircleOpensAndIsTickedFromThere() throws {
        // The phone's week: three days across, and "Book team travel" overlaps the
        // fixed meeting, so its block is half a column: about 57 pt.
        let app = try launchGrid(mode: "week")
        guard app.windows.firstMatch.frame.width < 600 else { throw XCTSkip("an iPad's half column has room for the circle") }
        // Check the earlier full-width reminder before scrolling to the later narrow block.
        // UIKit can evict its cell once it leaves the viewport.
        let wideTick = app.buttons["Mark Review launch notes done"]
        _ = try revealCalendarButton("Review launch notes,", in: app, referenceLabelPattern: "12\\s*PM")
        XCTAssertTrue(wideTick.isHittable, "a full column has room for its circle\n\(app.debugDescription)")
        let block = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Book team travel")).firstMatch
        _ = try revealCalendarButton("Book team travel,", in: app, referenceLabelPattern: "1\\s*PM")
        XCTAssertTrue(block.isHittable, app.debugDescription)
        XCTAssertLessThan(block.frame.width, 80, "the sample no longer has a narrow reminder")
        XCTAssertFalse(app.buttons["Mark Book team travel done"].exists,
                       "no circle to hit by accident on a block this narrow")

        block.tap()
        XCTAssertTrue(app.navigationBars["Edit reminder"].waitForExistence(timeout: 4), "the whole block opens it")
        app.buttons["task.tick"].tap()
        let toast = app.staticTexts["Completed \u{201C}Book team travel\u{201D}"]
        XCTAssertTrue(toast.waitForExistence(timeout: 4), "ticked from what it opened, with the same Undo")
        app.buttons["Undo"].tap()
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: toast)], timeout: 4)
    }
}
