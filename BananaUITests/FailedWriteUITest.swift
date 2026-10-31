import XCTest

/// With calendar access revoked, the write cannot succeed. The event the user typed must still be
/// on the grid, marked as not saved, rather than silently vanishing.
final class FailedWriteUITest: XCTestCase {
    func testAFailedWriteKeepsTheEventOnTheGrid() {
        let app = XCUIApplication()
        app.launchArguments = ["--week", "--ui-audit", "--empty-create-grid-preview", "--modules", "everything",
                               "--reset-day-scroll-offset", "-mobileWeekHourHeight", "56", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        guard let viewport = app.calendarGridViewport() else { XCTFail("no visible time grid"); return }
        print("CREATE CANVAS: \(viewport)")

        // A hold, then a drag: a tap on the grid creates nothing (it stops a scroll).
        let from = app.calendarPoint(in: viewport, y: 0.35)
        from.press(forDuration: 0.8, thenDragTo: app.calendarPoint(in: viewport, y: 0.52))
        let title = app.textFields["event.title"]
        guard title.waitForExistence(timeout: 8) else {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "no-composer"; shot.lifetime = .keepAlways; add(shot)
            XCTFail("composer did not open")
            return
        }
        title.tap()
        title.typeText("Unsaved event")
        app.buttons["Save"].firstMatch.tap()
        // Until the write has failed and the block says so.
        waitUntil(timeout: 6) {
            app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS 'Not saved'")).firstMatch.exists
                || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Not saved'")).firstMatch.exists
        }

        // The badge is folded into the block's combined accessibility element, so it cannot be
        // queried by identifier — but its label is part of what the block announces, which is
        // what someone using VoiceOver would actually hear. Assert on that.
        let failed = app.descendants(matching: .any)
            .containing(NSPredicate(format: "label CONTAINS 'Not saved'")).firstMatch.exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Not saved'")).firstMatch.exists
        let syncing = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Saving'")).firstMatch.exists
        let drawn = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Unsaved event'")).firstMatch.exists
        print("FAILED-WRITE: drawn=\(drawn) failedBadge=\(failed) syncingBadge=\(syncing)")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "failed-write"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(drawn, "the event vanished instead of staying on the grid")
        XCTAssertTrue(failed, "it should be marked as not saved, not merely present")
    }
}
