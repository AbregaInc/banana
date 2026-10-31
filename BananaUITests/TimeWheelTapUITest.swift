import XCTest

/// Tapping an hour in the new-event time picker has to choose it — it didn't: only scrolling the
/// wheel did. Driven for real, because only a real tap shows whether the row lands.
final class TimeWheelTapUITest: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // `--redraw-churn`: redraws like a live phone's, which the quiet route has none of.
        app.launchArguments = ["--new-calendar-event", "--redraw-churn", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    func testTappingAnHourChoosesIt() throws {
        try tapAnHour(typingFirst: false)
    }

    /// As it's really used: the title has the keyboard up, then the time is picked straight away
    /// — the form redraws while the keyboard goes, and each redraw used to put the old time back.
    func testTappingAnHourRightAfterTypingTheTitleChoosesIt() throws {
        try tapAnHour(typingFirst: true)
    }

    private func tapAnHour(typingFirst: Bool) throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 8))
        if typingFirst {
            let title = app.textFields.firstMatch
            title.tap()
            title.typeText("Lunch")
            XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        }
        let starts = app.datePickers["Starts"]
        XCTAssertTrue(starts.waitForExistence(timeout: 4), app.debugDescription)
        // The time half of the pill ("11:05 PM"): the one whose label isn't the date.
        let time = starts.buttons.matching(NSPredicate(format: "label CONTAINS ':'")).firstMatch
        let before = time.label
        time.tap()

        let hours = app.pickerWheels.element(boundBy: 0)
        XCTAssertTrue(hours.waitForExistence(timeout: 4), app.debugDescription)
        let hourBefore = hours.value as? String ?? ""
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "time picker open \(typingFirst ? "after typing" : "")"
        shot.lifetime = .keepAlways
        add(shot)
        // Two rows below the chosen hour: a tap, no scroll.
        if !typingFirst { sleep(1) }
        hours.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 64)).tap()
        let moved = NSPredicate(format: "value != %@", hourBefore)
        expectation(for: moved, evaluatedWith: hours)
        waitForExpectations(timeout: 3)
        sleep(1)   // let the wheel settle and the form redraw
        XCTAssertNotEqual(hours.value as? String, hourBefore, "the tapped hour has to stay chosen")
        let hourAfter = hours.value as? String ?? ""

        // Close the popover; the pill shows the new time.
        app.navigationBars["New event"].tap()
        let after = starts.buttons.matching(NSPredicate(format: "label CONTAINS ':'")).firstMatch
        let changed = NSPredicate(format: "label != %@", before)
        expectation(for: changed, evaluatedWith: after)
        waitForExpectations(timeout: 3)
        print("TIMEDEBUG \(before) → \(after.label) (wheel \(hourBefore) → \(hourAfter))")
    }
}
