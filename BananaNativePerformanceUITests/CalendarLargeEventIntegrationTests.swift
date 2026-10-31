import AppKit
import XCTest

/// Functional acceptance for oversized artwork in the real Calendar hierarchy.
/// Requires an explicit isolated fixture binary; never launches the installed Beta.
final class CalendarLargeEventIntegrationTests: XCTestCase {
    private var reviewApp: XCUIApplication?

    override func tearDownWithError() throws {
        // XCTest's stop-on-failure does not reliably unwind a function's defer.
        // Cleanup belongs to XCTest's lifecycle, including failed startup checks.
        reviewApp?.terminate()
        reviewApp = nil
    }

    func testOversizedDayEventOpensAfterScrolling() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["BANANA_LARGE_EVENT_APP"])
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(bundle.bundleIdentifier, "com.boris.banana.mac.large-event-review")
        guard bundle.bundleIdentifier == "com.boris.banana.mac.large-event-review" else { return }
        XCTAssertFalse(NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundle.bundleIdentifier
        }, "Do not replace an existing review session")
        let app = XCUIApplication(url: url)
        app.launchArguments = ["--ui-audit", "--stress-days", "30", "--stress-measure",
            "--stress-calendar-fixture", "varied-v1", "--stress-events-per-day", "1",
            "--stress-mail-days", "1", "--stress-notes", "100", "--stress-podcasts", "1",
            "--stress-episodes-per-show", "10", "--disable-icloud", "--mail-fresh",
            "--mac-section", "plan", "-onboardingCompleted", "YES"]
        app.launchEnvironment["STRESS_INITIAL_PLAN_MODE"] = "day"
        reviewApp = app
        app.launch()
        app.activate()
        let ready = app.staticTexts["stress.ready"].waitForExistence(timeout: 30)
        if !ready {
            let running = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == bundle.bundleIdentifier
            }
            let state = "XCTest state: \(app.state.rawValue); windows: \(app.windows.count); "
                + "pid: \(running?.processIdentifier ?? -1); "
                + "finishedLaunching: \(running?.isFinishedLaunching.description ?? "missing"); "
                + "active: \(running?.isActive.description ?? "missing")"
            let attachment = XCTAttachment(string: state + "\n" + app.debugDescription)
            attachment.name = "calendar-startup-state"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(ready, "Calendar fixture did not become ready; inspect calendar-startup-state")
        // XCTest's window capture fails on this host's secondary display. Move only
        // this isolated test window onto the primary display before visual evidence.
        let window = app.windows.firstMatch
        let initialFrame = window.frame
        let primarySize = try XCTUnwrap(NSScreen.screens.first).frame.size
        if initialFrame.minX < 0 || initialFrame.minY < 0
            || initialFrame.maxX > primarySize.width || initialFrame.maxY > primarySize.height {
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let title = origin.withOffset(CGVector(dx: initialFrame.width / 2, dy: 12))
            let destination = origin.withOffset(CGVector(
                dx: 100 + initialFrame.width / 2 - initialFrame.minX,
                dy: 112 - initialFrame.minY))
            title.press(forDuration: 0.2, thenDragTo: destination)
            XCTAssertGreaterThanOrEqual(window.frame.minX, 0)
            XCTAssertGreaterThanOrEqual(window.frame.minY, 0)
            XCTAssertLessThanOrEqual(window.frame.maxX, primarySize.width)
            XCTAssertLessThanOrEqual(window.frame.maxY, primarySize.height)
        }
        app.menuButtons["mac.planner.view"].click()
        app.menuItems["Day"].click()
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let event = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'mac.week.occurrence.' AND label CONTAINS 'Family appointment · 0-0'"
        )).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        // Even at 1x, this event must exceed the unchanged 2 MiB prepared-image cap.
        XCTAssertGreaterThan(event.frame.width * event.frame.height * 4, 2 * 1024 * 1024)
        for delta in [-400.0, 400.0] { grid.scroll(byDeltaX: 0, deltaY: delta) }
        let visible = event.frame.intersection(grid.frame)
        XCTAssertFalse(visible.isNull)
        XCTAssertGreaterThan(visible.height, 20)
        let geometry = XCTAttachment(string: "Event: \(event.frame); grid: \(grid.frame); window: \(app.windows.firstMatch.frame)")
        geometry.name = "oversized-event-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "oversized-day-event-visible"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Click the visible portion; the event's midpoint may be below the viewport.
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let windowFrame = app.windows.firstMatch.frame
        origin.withOffset(CGVector(dx: visible.midX - windowFrame.minX,
                                   dy: visible.midY - windowFrame.minY)).click()
        let detail = app.staticTexts["mac.eventInspector.title"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.value as? String ?? detail.label, "Family appointment · 0-0")
    }
}
