import XCTest

/// Plan is one switch with two positions, Day and Week. What's outstanding — every reminder past
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
        app.launchArguments = ["--ui-preview", "--tab", "plan", "--modules", "everything", "--plan", "-planMode", "list", "--untimed-reminders", "--outstanding-reminders",
                               "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"] + extra
        app.withoutSpaceSync()
        app.launch()

        let day = app.segmentedControls.buttons["Day"]
        XCTAssertTrue(day.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(day.isSelected, "a stored List opens on Day")
        XCTAssertTrue(app.segmentedControls.buttons["Week"].exists)
        XCTAssertFalse(app.segmentedControls.buttons["List"].exists)

        // Due two days ago and last week: on no part of today, and here all the same.
        let plumber = app.buttons["Mark Call the plumber done"]
        XCTAssertTrue(plumber.waitForExistence(timeout: 5), "today's reminders line\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Mark Renew passport done"].exists)
        XCTAssertTrue(app.buttons["Mark Creatine done"].exists)
        // The line stops at a few and says how many more; the day's own untimed one is among those.
        // So is "Take vitamin D", overdue since just after midnight — and it isn't drawn among
        // the hours as well: what the line holds, the grid doesn't repeat.
        XCTAssertFalse(app.staticTexts["Take vitamin D"].exists, "an overdue reminder is in the line only")
        XCTAssertFalse(app.buttons["Mark Water the plants done"].exists)
        let more = app.buttons["mobile.reminders.more"]
        XCTAssertTrue(more.exists, app.debugDescription)
        XCTAssertEqual(more.label, "+2 more")
        more.tap()
        XCTAssertTrue(app.buttons["Mark Water the plants done"].waitForExistence(timeout: 3),
                      "the day's own untimed one, after the overdue")
        XCTAssertTrue(app.buttons["Mark Take vitamin D done"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Take vitamin D")).count, 1,
                       "once, in the line")

        // To Week and back: Day draws again (a Day switched to used to draw nothing).
        app.segmentedControls.buttons["Week"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Week"].isSelected)
        day.tap()
        XCTAssertTrue(plumber.waitForExistence(timeout: 5), "Day drew nothing after the switch")

        // The forecast is on the day's header, where the List's stripe was the only weather.
        XCTAssertTrue(app.buttons["plan.weather"].exists, app.debugDescription)
    }
}
