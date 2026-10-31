import XCTest

/// A Taken reminder is rung a day at a time, so today's can be left out once the dose is marked
/// (`DoseReminderPlan`). It was one notification repeating daily, which rang regardless.
final class DoseReminderPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { now.addingTimeInterval(3_600) }
    private var earlier: Date { now.addingTimeInterval(-3_600) }

    func testTodaysRingsAtItsTimeWhileTheDoseIsNotMarked() {
        XCTAssertEqual(DoseReminderPlan.fixedTime(usual: later, isToday: true, marked: false, now: now), later)
    }

    func testTodaysIsLeftOutOnceTheDoseIsMarked() {
        XCTAssertNil(DoseReminderPlan.fixedTime(usual: later, isToday: true, marked: true, now: now),
                     "ticked at eight: nothing at nine")
    }

    func testATimeAlreadyGoneByIsNotRungLate() {
        XCTAssertNil(DoseReminderPlan.fixedTime(usual: earlier, isToday: true, marked: false, now: now))
    }

    func testAnotherDayRingsAtItsTimeWhateverTodayIs() {
        let tomorrow = later.addingTimeInterval(86_400)
        XCTAssertEqual(DoseReminderPlan.fixedTime(usual: tomorrow, isToday: false, marked: true, now: now), tomorrow)
    }

    func testAFewDosesAreScheduledAWeekAheadAndManyNoFewerThanThreeDays() {
        XCTAssertEqual(DoseReminderPlan.daysAhead(reminders: 1), 6)
        XCTAssertEqual(DoseReminderPlan.daysAhead(reminders: 5), 6)
        XCTAssertEqual(DoseReminderPlan.daysAhead(reminders: 9), 3)
        XCTAssertEqual(DoseReminderPlan.daysAhead(reminders: 30), 2)
        // Never more than about forty pending, of the 64 iOS keeps.
        for count in 1...40 {
            XCTAssertLessThanOrEqual(count * (DoseReminderPlan.daysAhead(reminders: count) + 1), max(42, count * 3))
        }
    }

    func testTheDoseAReminderIsForIsReadFromItsID() {
        let id = UUID()
        let prefix = "banana.supplement."
        XCTAssertEqual(DoseReminderPlan.supplementID(notificationID: prefix + id.uuidString + ".1800000000", prefix: prefix), id)
        XCTAssertEqual(DoseReminderPlan.supplementID(notificationID: prefix + id.uuidString, prefix: prefix), id,
                       "one scheduled before reminders were per day")
        XCTAssertNil(DoseReminderPlan.supplementID(notificationID: "banana.event.123", prefix: prefix))
    }

    func testADeletedItemsRemindersAreAllTheDaysAndTheOldRepeatingOne() {
        let id = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let ids = SupplementSchedule.reminderIDs(id, from: now, daysAhead: 7, calendar: calendar)
        XCTAssertEqual(ids.count, 9)
        XCTAssertEqual(Set(ids).count, 9)
        XCTAssertTrue(ids.contains(SupplementSchedule.reminderID(id, on: now, calendar: calendar)))
        XCTAssertTrue(ids.contains("banana.supplement." + id.uuidString))
        for one in ids {
            XCTAssertEqual(DoseReminderPlan.supplementID(notificationID: one, prefix: SupplementSchedule.notificationPrefix), id)
        }
    }
}
