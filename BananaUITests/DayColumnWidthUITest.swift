import XCTest

/// The Day column always fills the width it has. The Day grid is hosted in a UIKit scroll view
/// that only redrew when a hand-kept token of its inputs changed, and the column's width wasn't
/// one of them: a launch that measured the view narrow left every event squeezed to the left
/// until you paged to another day and back. Rotating changes the width the same way.
final class DayColumnWidthUITest: XCTestCase {

    /// Measure the painted isolated event as well as its native viewport, after layout settles.
    private func assertFills(_ app: XCUIApplication, _ moment: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let dinner = try revealCalendarButton("Dinner,", in: app, referenceLabelPattern: "12\\s*PM")
        let grid = app.calendarTimeGrid()
        XCTAssertTrue(waitUntil { dinner.frame.width > (grid.frame.width - 36) * 0.95 },
                      "Day event does not fill its column \(moment): \(dinner.frame), viewport \(grid.frame)", file: file, line: line)
    }

    func testTheDayColumnFollowsTheWidth() throws {
        let device = XCUIDevice.shared
        // A failed geometry assertion must not leave the next class in landscape.
        defer { device.orientation = .portrait }
        device.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--day", "--shared-mirror-preview", "--reset-day-scroll-offset", "-planMode", "day",
                                "-mobileWeekHourHeight", "56", "-planNotificationsLater", "YES", "-planRemindersLater", "YES"]
        app.withoutSpaceSync()
        app.launch()
        try assertFills(app, "at launch")

        device.orientation = .landscapeLeft
        try assertFills(app, "after turning to landscape")

        device.orientation = .portrait
        try assertFills(app, "after turning back")
    }
}
