import XCTest

/// Reminders with no time — overdue ones especially — are on the iPhone's calendar, above the
/// grid, and can be ticked off there. They weren't drawn anywhere on it, so a badge could count
/// one nobody could find.
final class RemindersBandUITest: XCTestCase {
    func testUntimedRemindersShowAboveTheDayAndTickOff() {
        let app = XCUIApplication()
        app.launchArguments = ["--day", "--untimed-reminders", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        let overdue = app.buttons["mobile.reminder.preview-untimed-0"]
        XCTAssertTrue(overdue.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(overdue.value as? String, "Overdue")
        XCTAssertTrue(app.buttons["mobile.reminder.preview-untimed-1"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
