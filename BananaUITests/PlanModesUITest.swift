import XCTest

/// Plan has one period picker with two options, Day and Week. What's outstanding — every reminder past
/// its time and not done, whenever it was due — is in Day's reminders line, where it can be
/// ticked. There was a third position, List, which was the only place they were.
final class PlanModesUITest: XCTestCase {
    func testPlanIsDayAndWeekAndWhatsOutstandingIsInDay() { checkModes(extra: []) }

    func testCachedNativeCalendarDoesNotRepeatOutstandingReminders() {
        checkModes(extra: ["--calendar-cache-layout"])
    }

    private func checkModes(extra: [String]) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // A stored "list" from before: it opens on Day.
        let arguments = ["--ui-preview", "--tab", "plan", "--modules", "everything", "--plan",
                         "--untimed-reminders", "--outstanding-reminders", "--disable-icloud",
                         "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"] + extra
        app.launchArguments = arguments + ["-planMode", "list"]
        app.withoutSpaceSync()
        app.launch()

        let picker = app.descendants(matching: .any)["plan.mode"].firstMatch
        let day = app.descendants(matching: .any)["plan.surface.day"].firstMatch
        let week = app.descendants(matching: .any)["plan.surface.week"].firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 10), "a stored List opens on Day\n\(app.debugDescription)")
        XCTAssertTrue(picker.exists)

        // Today's untimed row includes overdue reminders from earlier days.
        let reminders = app.descendants(matching: .any)["mobile.plan.todo"].firstMatch
        XCTAssertTrue(reminders.waitForExistence(timeout: 5), "today's reminders row")
        let plumber = reminders.buttons["Mark Call the plumber done"]
        XCTAssertTrue(plumber.exists)
        XCTAssertTrue(reminders.buttons["Mark Renew passport done"].exists)
        XCTAssertTrue(reminders.buttons["Mark Creatine done"].exists)
        XCTAssertFalse(app.buttons["mobile.reminders.more"].exists)

        // Scroll the current shell's row to reach the later reminders.
        let plants = reminders.buttons["Mark Water the plants done"]
        let window = app.windows.firstMatch
        func plantsAreVisible() -> Bool {
            guard let frame = try? plants.snapshot().frame else { return false }
            return reminders.frame.intersection(window.frame).contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        for _ in 0..<8 where !plantsAreVisible() { reminders.swipeLeft() }
        XCTAssertTrue(plantsAreVisible(), "the day's untimed reminder is reachable")
        XCTAssertTrue(reminders.buttons["Mark Take vitamin D done"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Take vitamin D")).count, 1,
                       "once, in the reminders row")

        // Relaunch without the argument-domain override so the picker can store a new mode.
        app.terminate()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        if !day.exists {
            picker.tap()
            app.buttons["Day"].firstMatch.tap()
            XCTAssertTrue(day.waitForExistence(timeout: 8))
        }

        // To Week and back: Day draws again.
        picker.tap()
        let weekOption = app.buttons["Week"].firstMatch
        XCTAssertTrue(weekOption.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Day"].firstMatch.exists)
        XCTAssertFalse(app.buttons["List"].exists)
        weekOption.tap()
        XCTAssertTrue(week.waitForExistence(timeout: 8))
        picker.tap()
        app.buttons["Day"].firstMatch.tap()
        XCTAssertTrue(day.waitForExistence(timeout: 8))
        XCTAssertTrue(plumber.waitForExistence(timeout: 5), "Day drew nothing after the switch")

        // The forecast is on the day's header, where the List's stripe was the only weather.
        XCTAssertTrue(app.buttons["plan.weather"].exists, app.debugDescription)
    }
}
