import XCTest

/// Every clock time is set with the system's compact field in five-minute steps (`TimeField`,
/// `MomentField`), and the routine editor is one form with the one weekday row. Driven for
/// real: only the open picker shows what its minute wheel offers.
final class TimeFieldUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the phone's sheets")
        XCUIDevice.shared.orientation = .portrait
    }

    /// The Commute routine's editor (a routine at a time: 8:15 on weekdays), from "…" › Routines.
    private func openCommuteEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "library", "--wake-following-sample",
                               "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        let more = app.buttons.matching(NSPredicate(format: "label == 'More'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        more.tap()
        let routines = app.buttons["page.more.routines"]
        XCTAssertTrue(routines.waitForExistence(timeout: 5), app.debugDescription)
        routines.tap()
        XCTAssertTrue(app.navigationBars["Routines"].waitForExistence(timeout: 6), app.debugDescription)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Commute'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.navigationBars["Commute"].waitForExistence(timeout: 5), "the editor didn't open\n\(app.debugDescription)")
        return app
    }

    /// The minutes a wheel or a field shows: "15 minutes" → 15, "8:15 AM" → 15.
    private func minutes(_ text: String) -> Int? {
        if let colon = text.firstIndex(of: ":") {
            return Int(text[text.index(after: colon)...].prefix(2))
        }
        return Int(text.prefix { $0.isNumber })
    }

    /// Opens the compact field `picker` and walks its minute wheel once round, a row at a time:
    /// every stop is a multiple of five, five after the last. Leaves the picker closed, one
    /// step on from where it was, and checks the field says so.
    private func assertTheMinuteWheelStepsInFives(_ app: XCUIApplication, _ picker: XCUIElement, closeOn bar: XCUIElement,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        // The time pill of the compact field: "Time Picker", its value the time ("8:15 AM").
        let field = picker.buttons["Time Picker"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no time field\n\(app.debugDescription)", file: file, line: line)
        let shownBefore = field.value as? String ?? ""
        XCTAssertEqual((minutes(shownBefore) ?? -1) % 5, 0, "the field starts off the five-minute grid, at \(shownBefore)", file: file, line: line)
        field.tap()

        let wheel = app.pickerWheels.matching(NSPredicate(format: "value CONTAINS 'minute'")).firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 4), "the field didn't open a minute wheel\n\(app.debugDescription)", file: file, line: line)
        sleep(1)
        guard var now = minutes(wheel.value as? String ?? "") else {
            return XCTFail("the minute wheel shows \(String(describing: wheel.value))", file: file, line: line)
        }
        XCTAssertEqual(now % 5, 0, "the wheel opens off the five-minute grid, at :\(now)", file: file, line: line)

        var seen: Set<Int> = [now]
        for _ in 0..<13 {
            let before = wheel.value as? String ?? ""
            // The row under the chosen one: a tap, which rolls the wheel one row on.
            wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 32)).tap()
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: wheel)
            XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 4), .completed, "the wheel didn't move from \(before)", file: file, line: line)
            usleep(700_000)   // let it settle on the row
            guard let next = minutes(wheel.value as? String ?? "") else {
                return XCTFail("the minute wheel shows \(String(describing: wheel.value))", file: file, line: line)
            }
            XCTAssertEqual(next, (now + 5) % 60, "one row on from :\(now) is :\(next), not five minutes later", file: file, line: line)
            now = next
            seen.insert(now)
        }
        XCTAssertEqual(seen, Set(stride(from: 0, to: 60, by: 5)), "the wheel's rows aren't the twelve five-minute marks", file: file, line: line)

        // Close the popover; the field holds what the wheel was left on. A bare part of the bar,
        // between the title and the right-hand button: the title's middle didn't reach past a
        // sheet's popover, and a quarter of the way along is Cancel's glass on iOS 27.
        let beforeDismiss = XCTAttachment(screenshot: app.screenshot())
        beforeDismiss.name = "Time picker before dismissal"
        beforeDismiss.lifetime = .keepAlways
        add(beforeDismiss)
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: wheel)
        // In a sheet's form the wheel opens in place rather than in a popover: closed, as a person
        // closes it, by tapping the time again.
        if XCTWaiter().wait(for: [closed], timeout: 2) != .completed, field.isHittable { field.tap() }
        let closedAfter = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: wheel)
        let closeResult = XCTWaiter().wait(for: [closedAfter], timeout: 4)
        if closeResult != .completed {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Time picker failed dismissal"
            image.lifetime = .keepAlways
            add(image)
            print(app.debugDescription)
        }
        XCTAssertEqual(closeResult, .completed, "the picker didn't close", file: file, line: line)
        let shown = field.value as? String ?? ""
        XCTAssertEqual(minutes(shown), now, "the field says \(shown) after the wheel was left on :\(now)", file: file, line: line)
        XCTAssertNotEqual(shown, shownBefore, "the field didn't take the wheel's time", file: file, line: line)
    }

    func testARoutinesTimeStepsInFives() {
        let app = openCommuteEditor()
        assertTheMinuteWheelStepsInFives(app, app.datePickers["Time"].firstMatch, closeOn: app.navigationBars["Commute"])
    }

    /// The reminder sheet's time, once "Schedule a time" is on.
    func testARemindersTimeStepsInFives() {
        let app = XCUIApplication()
        app.launchArguments = ["--new-task", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "task.title").firstMatch.waitForExistence(timeout: 20),
                      app.debugDescription)
        let schedule = app.switches.matching(NSPredicate(format: "label == 'Schedule a time'")).firstMatch
        XCTAssertTrue(schedule.waitForExistence(timeout: 4), app.debugDescription)
        if (schedule.value as? String) != "1" {
            // The switch itself, at the row's trailing end: the row's middle is its label.
            schedule.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        // The date is a picker too; the time field is the one with a time pill.
        let picker = app.datePickers.containing(.button, identifier: "Time Picker").firstMatch
        // The compact picker covers the Reminder heading in the medium sheet.
        // The When heading below it stays outside the popover and does not edit a value.
        assertTheMinuteWheelStepsInFives(app, picker, closeOn: app.staticTexts["When"].firstMatch)
    }

    /// One form, with the weekday row under the time: a day tapped changes whether it is on.
    func testTheRoutineEditorsWeekdayRowTurnsDaysOnAndOff() {
        let app = openCommuteEditor()
        func day(_ code: String) -> XCUIElement { app.buttons["routine.repeatDay.\(code)"] }
        for code in ["SU", "MO", "TU", "WE", "TH", "FR", "SA"] {
            XCTAssertTrue(day(code).waitForExistence(timeout: 4), "the weekday row has no \(code)\n\(app.debugDescription)")
        }
        // One row: the seven days side by side, under the time.
        XCTAssertEqual(day("MO").frame.midY, day("SA").frame.midY, accuracy: 2, "the days aren't one row")
        XCTAssertGreaterThan(day("MO").frame.minY, app.datePickers.firstMatch.frame.minY, "the days aren't under the time")
        // Commute runs on weekdays.
        XCTAssertTrue(day("MO").isSelected, "Monday should start on")
        XCTAssertFalse(day("SA").isSelected, "Saturday should start off")

        day("SA").tap()
        XCTAssertTrue(day("SA").isSelected, "tapping Saturday didn't turn it on")
        XCTAssertTrue(day("MO").isSelected, "tapping Saturday changed Monday")
        day("MO").tap()
        XCTAssertFalse(day("MO").isSelected, "tapping Monday didn't turn it off")
        day("SA").tap()
        XCTAssertFalse(day("SA").isSelected, "tapping Saturday again didn't turn it off")

        // Nothing is kept unless saved.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Routines"].waitForExistence(timeout: 5))
    }
}
