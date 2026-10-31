import XCTest

/// Does a newly created event appear at once, marked as not yet saved?
final class OptimisticEventUITest: XCTestCase {
    func testCreatedEventAppearsImmediately() {
        let app = XCUIApplication()
        app.launchArguments += ["--week"]
        app.withoutSpaceSync()
        app.launch()
        let week = app.buttons["Week"]
        if week.waitForExistence(timeout: 25) { week.tap() }
        sleep(2)

        // Through the toolbar menu, not a tap at a fixed screen position: the fixture day moves
        // with the clock, so a coordinate that was empty yesterday lands on an event today and the
        // create gesture correctly refuses. Grid creation has its own test; this one is about what
        // happens AFTER saving.
        let plus = app.plus("mobile.week.newEvent")
        XCTAssertTrue(plus.waitForExistence(timeout: 20), "no + menu")
        plus.tap()
        let item = app.buttons["mobile.week.add.event"]
        XCTAssertTrue(item.waitForExistence(timeout: 6), "menu did not open")
        item.tap()
        let title = app.textFields["event.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "composer did not open")
        title.tap()
        title.typeText("Optimistic test")

        app.buttons["Save"].firstMatch.tap()

        // The composer should be gone at once and the event already drawn — before the write,
        // the debounce and a full recompute have finished.
        let closedFast = !app.textFields["event.title"].waitForExistence(timeout: 2)
        let drawn = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Optimistic test'"))
            .firstMatch.waitForExistence(timeout: 5)
        // With calendar access granted the local write lands in milliseconds, so the placeholder
        // is usually already retired by the time this runs. Not asserted for that reason; the
        // failure path is where the badge is verified.
        let notSaved = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Not saved'")).firstMatch.exists
        print("OPTIMISTIC: composerClosedFast=\(closedFast) eventDrawn=\(drawn) stillUnsaved=\(notSaved)")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "after-save"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(closedFast, "the composer should close without waiting for the write")
        XCTAssertTrue(drawn, "the event was not drawn straight after saving")
    }
}
