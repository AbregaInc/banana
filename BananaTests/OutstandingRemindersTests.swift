import XCTest

/// Today's reminders line carries everything outstanding (`OutstandingReminders`): what the Plan
/// badge counts is in the Day view, not only in List.
final class OutstandingRemindersTests: XCTestCase {
    private struct Reminder: Equatable {
        let id: String
        let due: Date
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func line(untimed: [Reminder], overdue: [Reminder], isToday: Bool) -> [String] {
        OutstandingReminders.line(untimed: untimed, overdue: overdue, isToday: isToday, id: \.id, due: \.due).map(\.id)
    }

    func testTodayLeadsWithEverythingOverdueOldestFirst() {
        let saturday = Reminder(id: "call-plumber", due: at(3, 9))
        let thisMorning = Reminder(id: "creatine", due: at(5, 8))
        let untimed = Reminder(id: "book-travel", due: at(5, 0))
        XCTAssertEqual(line(untimed: [untimed], overdue: [thisMorning, saturday], isToday: true),
                       ["call-plumber", "creatine", "book-travel"])
    }

    func testAnUntimedOneThatIsAlsoOverdueShowsOnce() {
        let stale = Reminder(id: "renew-passport", due: at(1, 0))
        XCTAssertEqual(line(untimed: [stale], overdue: [stale], isToday: true), ["renew-passport"])
    }

    func testAnotherDayShowsOnlyItsOwn() {
        let saturday = Reminder(id: "call-plumber", due: at(3, 9))
        let tomorrows = Reminder(id: "water-plants", due: at(6, 0))
        XCTAssertEqual(line(untimed: [tomorrows], overdue: [saturday], isToday: false), ["water-plants"])
        XCTAssertEqual(line(untimed: [], overdue: [saturday], isToday: false), [])
    }

    func testHowLateReadsByHowLongAgo() {
        let now = at(5, 14)   // Monday 5 October
        XCTAssertEqual(OutstandingReminders.since(at(5, 8), now: now, calendar: calendar), "Overdue")
        XCTAssertEqual(OutstandingReminders.since(at(4, 23), now: now, calendar: calendar), "since yesterday")
        XCTAssertEqual(OutstandingReminders.since(at(3, 9), now: now, calendar: calendar), "since Sat")
        XCTAssertEqual(OutstandingReminders.since(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9))!,
                                                  now: now, calendar: calendar), "since Sep 28")
    }

    func testAnOverdueReminderIsInTheLineNotAmongTheHours() {
        XCTAssertTrue(OutstandingReminders.leavesTheGrid(overdueReminder: true, onToday: true, lineIsTodays: true))
        XCTAssertFalse(OutstandingReminders.leavesTheGrid(overdueReminder: false, onToday: true, lineIsTodays: true),
                       "a reminder still to come keeps its place at its time")
        XCTAssertFalse(OutstandingReminders.leavesTheGrid(overdueReminder: true, onToday: true, lineIsTodays: false),
                       "with another day's line on screen it would be nowhere")
    }
}
