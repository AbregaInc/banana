import XCTest

/// Pinching the Day grid zooms around the fingers: the time between them stays between them.
/// Before, the pinch changed the hour height without moving the scroll, so the day grew from its
/// top and slid away under the fingers — and the scroll's pan followed the first finger down.
final class PinchZoomUITest: XCTestCase {

    private struct HourLabel {
        var hour: String
        var y: CGFloat
    }

    /// The gutter's hour labels inside the visible grid ("3 PM"), top to bottom. By frame, not
    /// `isHittable`, which came back false for labels plainly on screen now and then.
    private func hourLabels(_ app: XCUIApplication, in grid: XCUIElement) -> [HourLabel] {
        let predicate = NSPredicate(format: "label MATCHES %@", "^[0-9]{1,2}.(AM|PM)$")
        let visible = grid.frame
        return app.staticTexts.matching(predicate).allElementsBoundByIndex
            .map { HourLabel(hour: $0.label, y: $0.frame.midY) }
            .filter { $0.y > visible.minY + 8 && $0.y < visible.maxY - 8 }
            .sorted { $0.y < $1.y }
    }

    func testPinchingTheDayZoomsAroundTheFingers() throws {
        try pinchZoomsAroundTheFingers(mode: "Day")
    }

    /// The 3-day grid is a SwiftUI scroll view, anchored the same way through its scroll position.
    func testPinchingTheWeekZoomsAroundTheFingers() throws {
        try pinchZoomsAroundTheFingers(mode: "Week")
    }

    private func pinchZoomsAroundTheFingers(mode: String) throws {
        let app = XCUIApplication()
        // `--day` is the Day view and `--week` the 3-day one, whatever the toggle says.
        app.launchArguments += [mode == "Day" ? "--day" : "--week"]
        // The zoom is kept between launches, and a test before this one may have left it at
        // either end: start from the default.
        app.launchArguments += ["-mobileWeekHourHeight", "56", "-planMode", mode.lowercased()]
        app.withoutSpaceSync()
        app.launch()
        let grid = app.calendarTimeGrid()
        XCTAssertTrue(grid.waitForExistence(timeout: 25))
        XCTAssertTrue(waitUntil { self.hourLabels(app, in: grid).count >= 3 })
        // The zoom is kept between launches: start from zoomed out, so there's room to zoom in.
        grid.pinch(withScale: 0.3, velocity: -1.5)
        XCTAssertTrue(waitUntil { self.hourLabels(app, in: grid).count >= 3 })

        let before = hourLabels(app, in: grid)
        if before.count < 3 {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "tree"; dump.lifetime = .keepAlways; add(dump)
            print("TREE-START\n\(app.debugDescription)\nTREE-END")
        }
        guard before.count >= 3 else { return XCTFail("hour labels should be on screen") }
        let hourBefore = before[1].y - before[0].y

        grid.pinch(withScale: 1.8, velocity: 1.5)
        XCTAssertTrue(waitUntil {
            let labels = self.hourLabels(app, in: grid)
            return labels.count >= 2 && labels[1].y - labels[0].y > hourBefore * 1.2
        })

        let after = hourLabels(app, in: grid)
        guard after.count >= 2 else { return XCTFail("hour labels should still be on screen") }
        let hourAfter = after[1].y - after[0].y
        XCTAssertGreaterThan(hourAfter, hourBefore * 1.2, "the pinch should have made the hours taller")

        // Zooming around the fingers leaves one point where it was and scales every hour's
        // distance from it. Where that point is comes from what moved, not from the middle of the
        // grid's frame: XCUITest puts its fingers around the middle of the part of the grid
        // nothing covers, and the 3-day grid's foot is under the tab bar. Measured on 8 Oct 2026,
        // the touches were centred 25 pt above the frame's middle, exactly where the app held
        // the hour; this test assumed the frame's middle, and that 25 pt times the zoom was its
        // failure.
        let scale = hourAfter / hourBefore
        let fixed: [CGFloat] = after.compactMap { later in
            guard let earlier = before.first(where: { $0.hour == later.hour }) else { return nil }
            return (later.y - scale * earlier.y) / (1 - scale)
        }
        guard !fixed.isEmpty else { return XCTFail("the hours that were on screen scrolled away") }
        let point = fixed.reduce(0, +) / CGFloat(fixed.count)
        // Evenly spaced hours always agree on the point; a disagreement means the grid was read
        // mid-change.
        for value in fixed {
            XCTAssertEqual(value, point, accuracy: 8, "the hours were still moving: \(fixed.map { Int($0) })")
        }
        // What this can tell: the point is where fingers could have been, the middle of the grid.
        // A zoom that keeps the scroll offset, or grows from the first hour or the top of the
        // screen, holds a point far outside it. (It can't tell a point a little off the fingers:
        // XCUITest doesn't say where it put them.)
        let frame = grid.frame
        XCTAssertGreaterThan(point, frame.minY + frame.height / 3, "zoomed around a point near the top of the grid")
        XCTAssertLessThan(point, frame.minY + frame.height * 2 / 3, "zoomed around a point near the foot of the grid")
    }
}
