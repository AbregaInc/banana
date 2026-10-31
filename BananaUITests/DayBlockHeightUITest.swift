import XCTest

/// A short event stays within its own minutes when the Day grid is zoomed out. Every event was
/// drawn at least 24 pt tall for its title, so zoomed out a 15-minute blocker straight before a
/// swim grew down over the swim, while everything else stayed end to end.
final class DayBlockHeightUITest: XCTestCase {

    private func block(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title),")).firstMatch
    }

    func testAShortEventDoesNotCoverTheNextOneAtAnyZoom() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--day", "--back-to-back-sample", "--reset-day-scroll-offset",
                                "-planMode", "day", "-mobileWeekHourHeight", "56",
                                "-planNotificationsLater", "YES", "-planRemindersLater", "YES"]
        app.withoutSpaceSync()
        app.launch()
        let grid = app.calendarTimeGrid()
        XCTAssertTrue(grid.waitForExistence(timeout: 25))

        for (scale, zoom) in [(0.2, "zoomed out"), (4.0, "zoomed in")] {
            grid.pinch(withScale: scale, velocity: scale < 1 ? -1.5 : 1.5)
            _ = try revealCalendarButton("Blocker,", in: app, referenceLabelPattern: "3\\s*PM")
            // At high zoom the blocker can be fully visible at the bottom edge while
            // its adjacent swim is still evicted. Mount both before measuring overlap.
            _ = try revealCalendarButton("Swim,", in: app, referenceLabelPattern: "3\\s*PM")
            let blocker = block(app, "Blocker"), swim = block(app, "Swim")
            XCTAssertTrue(waitUntil { blocker.exists && swim.exists })
            XCTAssertTrue(blocker.exists, "no blocker \(zoom)")
            XCTAssertTrue(swim.exists, "no swim \(zoom)")
            // Other fixture meetings can put these back-to-back events in different
            // lanes. Require no actual 2-D overlap, rather than comparing Y alone.
            let overlap = blocker.frame.intersection(swim.frame)
            XCTAssertTrue(overlap.isNull || overlap.isEmpty || overlap.height <= 1,
                          "Blocker \(blocker.frame) must not cover Swim \(swim.frame) \(zoom)")
        }
    }
}
