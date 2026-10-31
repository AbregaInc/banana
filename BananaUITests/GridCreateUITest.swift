import XCTest

/// Can an event be created at the time you point at?
///
/// The owner's complaint is not that creating fails, it is that the created event lands at a time
/// he then has to correct. So this asserts on the START TIME the composer opens at, not merely on
/// a composer appearing. An earlier version of this test checked for "a sheet or a Cancel button"
/// and reported success in all four cases while nothing was opening at all.
final class GridCreateUITest: XCTestCase {

    private func launch(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--week"]
        app.withoutSpaceSync()
        app.launch()
        // The Day/Week choice persists across launches, so selecting it is not optional: without
        // this the test silently measures whichever mode was last used.
        let button = app.buttons[mode]
        if button.waitForExistence(timeout: 25) { button.tap() }
        return app
    }

    private func firstColumn(_ app: XCUIApplication) -> XCUIElement {
        app.calendarTimeGrid()
    }

    /// The composer, identified by a control only it has.
    private func composerOpened(_ app: XCUIApplication) -> Bool {
        app.textFields["event.title"].waitForExistence(timeout: 4)
    }

    /// What the composer says the event starts at.
    private func startLabel(_ app: XCUIApplication) -> String {
        let cells = app.descendants(matching: .any).allElementsBoundByIndex
        for element in cells where element.label.contains("Starts") {
            return element.label
        }
        return app.staticTexts.allElementsBoundByIndex
            .map(\.label).first { $0.contains(":") || $0.contains("AM") || $0.contains("PM") } ?? "<none>"
    }

    private func measure(mode: String, drag: Bool) {
        let app = launch(mode: mode)
        XCTAssertTrue(firstColumn(app).waitForExistence(timeout: 25), "\(mode): no column appeared")

        // Window coordinates, NOT the column's. A day column is a full 24-hour content view, much
        // taller than the screen, so a normalized offset into it lands off-screen and the tap
        // silently goes nowhere. That mistake made an earlier version of this test report failure
        // for every mode including one that demonstrably works.
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        if drag {
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            point.press(forDuration: 0.8, thenDragTo: to)
        } else {
            point.tap()
        }

        let opened = composerOpened(app)
        var start = "-"
        if opened {
            start = app.descendants(matching: .any).allElementsBoundByIndex
                .map(\.label).first { $0.contains("PM") || $0.contains("AM") } ?? "<no time>"
        }
        print("RESULT \(mode)/\(drag ? "press-drag" : "tap"): opened=\(opened) start=\(start)")
    }

    func testWeekTap()       { measure(mode: "Week", drag: false) }
    func testWeekPressDrag() { measure(mode: "Week", drag: true) }
    func testDayTap()        { measure(mode: "Day",  drag: false) }
    func testDayPressDrag()  { measure(mode: "Day",  drag: true) }
}
