import XCTest

/// Swiping to another day with the finger starting on a block must turn the page and nothing
/// else. The Day view's sideways swipe never took the touch from the block under it, so the block
/// still saw a tap on lift-off and opened (an event's preview, a cue's editor) while the day changed.
///
/// Uses the "Wind down" cue: the Simulator has no calendar, and every block on the grid — event
/// or cue — is the same kind of button in the same scroll view, so the swipe treats them alike.
final class SwipeOnEventUITest: XCTestCase {

    private func launch(_ mode: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [mode == "Day" ? "--day" : "--week", "-planMode", mode.lowercased(), "--ui-audit", "--disable-icloud", "--reset-day-scroll-offset"]
        app.withoutSpaceSync()
        app.launch()
        // The Day/Week choice persists across launches: select it rather than assume it.
        let button = app.buttons[mode]
        if button.waitForExistence(timeout: 25) { button.tap() }
        return app
    }

    private func block(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Wind down'")).firstMatch
    }

    private func editorOpened(_ app: XCUIApplication, within timeout: TimeInterval) -> Bool {
        app.navigationBars["Wind down"].waitForExistence(timeout: timeout)
    }

    func testSwipingFromABlockTurnsThePageWithoutOpeningIt() throws {
        let app = launch("Day")
        var windDown = try revealCalendarButton("Wind down", in: app)

        // Control: a plain tap does open it, so a pass below means something.
        windDown.tap()
        XCTAssertTrue(editorOpened(app, within: 5), "tapping the block didn't open it")
        app.buttons["Done"].tap()   // the routine's sheet closes with Done
        windDown = try revealCalendarButton("Wind down", in: app)

        let title = app.descendants(matching: .any)["mobile.day.title"].firstMatch
        let dayBefore = title.exists ? title.label : ""
        let start = windDown.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -220, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertFalse(editorOpened(app, within: 2.5), "the swipe opened the block it started on")
        XCTAssertNotEqual(title.label, dayBefore, "the swipe didn't change the day")
    }

    /// Week scrolls its day columns sideways instead of paging: a swipe starting on a block moves
    /// the columns and must not open the block either.
    func testScrollingTheWeekFromABlockDoesNotOpenIt() throws {
        let app = launch("Week")
        let windDown = try revealCalendarButton("Wind down", in: app)
        let start = windDown.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -200, dy: 0)))
        XCTAssertFalse(editorOpened(app, within: 2.5), "scrolling the week opened the block it started on")
    }
}
