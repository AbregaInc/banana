import XCTest

/// A routine can follow your wake-up, as one follows a workout: it says so in Routines, and it is
/// on the day at the Wake routine's time plus its minutes.
final class RoutineFollowsWakeUITest: XCTestCase {
    func testTheRoutineSaysWhatItFollows() {
        let app = XCUIApplication()
        app.launchArguments = ["--routines", "--wake-following-sample", "--disable-icloud", "--no-space-sync", "--ui-audit",
                               "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.staticTexts["Stretch"].waitForExistence(timeout: 10), app.debugDescription)
        let rule = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "15 min after you wake up")).firstMatch
        XCTAssertTrue(rule.exists, app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// A routine moment with no time of its own — a workout "on start", a manual one — is above the
/// hours on the phone's Day view while it's due, and only then: from its own time today (the
/// sample's Workout is 7:00 AM, its Sleep 10:30 PM) until it's done. It was only in List.
final class UntimedRoutineMomentsUITest: XCTestCase {
    /// Minutes into today, as the app sees them.
    static var minutesNow: Int {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (now.hour ?? 0) * 60 + (now.minute ?? 0)
    }
    static var workoutIsDue: Bool { minutesNow >= 7 * 60 }
    static var sleepIsDue: Bool { minutesNow >= 22 * 60 + 30 }

    func testTheDayShowsThemOnlyWhileTheyAreDue() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "plan", "--modules", "everything", "--plan",
                               "--untimed-reminders", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        let picker = app.descendants(matching: .any)["plan.mode"].firstMatch
        let day = app.descendants(matching: .any)["plan.surface.day"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        if !day.exists {
            picker.tap()
            app.buttons["Day"].firstMatch.tap()
        }
        XCTAssertTrue(day.waitForExistence(timeout: 8))
        let workout = app.buttons["Workout, no set time"]
        let sleep = app.buttons["Sleep, no set time"]
        XCTAssertEqual(workout.waitForExistence(timeout: 4), Self.workoutIsDue, "Workout, from 7:00 AM")
        XCTAssertEqual(sleep.exists, Self.sleepIsDue, "Sleep, not before 10:30 PM")
        // The phone puts routines and reminders in the same scrollable row in Day and Week.
        let shared = app.descendants(matching: .any)["mobile.plan.todo"].firstMatch
        XCTAssertTrue(shared.exists, app.debugDescription)
        XCTAssertTrue(shared.buttons["mobile.reminder.preview-untimed-0"].exists)
        if Self.workoutIsDue { XCTAssertTrue(shared.buttons["Workout, no set time"].exists) }
        picker.tap()
        let week = app.buttons["Week"].firstMatch
        XCTAssertTrue(week.waitForExistence(timeout: 5))
        week.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan.surface.week"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(shared.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(shared.buttons["mobile.reminder.preview-untimed-0"].exists)
        if Self.workoutIsDue { XCTAssertTrue(shared.buttons["Workout, no set time"].exists) }
    }
}
