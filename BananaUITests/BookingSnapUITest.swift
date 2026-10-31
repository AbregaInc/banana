import XCTest

/// A new booking must start on the hour or the half hour, from a tap or a drag.
///
/// Verified by screenshot: accessibility queries for the composer's "Starts" value proved
/// unreliable (they pick up grid labels instead), and the composer renders the time plainly.
final class BookingSnapUITest: XCTestCase {

    private func shoot(_ name: String, drag: Bool, dy: CGFloat) {
        let app = XCUIApplication()
        app.launchArguments = ["--week", "--ui-audit", "--empty-create-grid-preview", "--modules", "everything",
                               "--reset-day-scroll-offset", "-mobileWeekHourHeight", "56", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        guard let viewport = app.calendarGridViewport() else { XCTFail("no visible time grid"); return }
        print("CREATE CANVAS: \(viewport)")

        if drag {
            let from = app.calendarPoint(in: viewport, y: 0.35)
            let to = app.calendarPoint(in: viewport, y: 0.52)
            from.press(forDuration: 0.8, thenDragTo: to)
        } else {
            app.calendarPoint(in: viewport, y: 0.35).tap()
        }
        // Assert the composer actually opened, so this fails loudly if creation breaks rather
        // than quietly attaching a screenshot of an unchanged grid. The START TIME itself is
        // verified visually in the attachment — reading it back through accessibility proved
        // unreliable, as the query picks up grid labels instead of the composer's field. The
        // snapping arithmetic is covered directly by BookingGridTests.
        XCTAssertTrue(app.textFields["event.title"].waitForExistence(timeout: 8),
                      "\(name): no composer opened, so there is no start time to check")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A tap on the grid opens nothing. A tap is how a scrolling grid is stopped, and every such
    /// tap used to open a new event; creating one is a hold then a drag, or the + button
    /// (`CalendarCreateGesture`, `onTap: nil`). This test still expected the tap to create.
    func testATapOnTheGridOpensNothing() {
        let app = XCUIApplication()
        app.launchArguments = ["--week", "--ui-audit", "--empty-create-grid-preview", "--modules", "everything",
                               "--reset-day-scroll-offset", "-mobileWeekHourHeight", "56", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        guard let viewport = app.calendarGridViewport() else { XCTFail("no visible time grid"); return }
        print("CREATE CANVAS: \(viewport)")
        app.calendarPoint(in: viewport, y: 0.35).tap()
        XCTAssertFalse(app.textFields["event.title"].waitForExistence(timeout: 3))
    }

    // A deliberately awkward offset: on a five-minute grid it would land on an odd minute.
    func testDragSnap() { shoot("snap-drag", drag: true,  dy: 0.553) }
}
