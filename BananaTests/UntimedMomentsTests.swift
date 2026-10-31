import XCTest

/// A routine moment with no time of its own is above the hours only while it's due
/// (`UntimedMoments`): today, from its own time, until it's done.
final class UntimedMomentsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func due(_ start: Date, done: Bool = false, skipped: Bool = false, now: Date) -> Bool {
        UntimedMoments.isDue(start: start, done: done, skipped: skipped, now: now, calendar: calendar)
    }

    func testNotBeforeItsTime() {
        // Sleep, 10:30 PM: nothing at lunch.
        XCTAssertFalse(due(at(6, 22, 30), now: at(6, 12)))
    }

    func testFromItsTimeOnItsDay() {
        XCTAssertTrue(due(at(6, 22, 30), now: at(6, 22, 30)))
        XCTAssertTrue(due(at(6, 22, 30), now: at(6, 23, 45)))
    }

    func testNotOnAnyOtherDay() {
        XCTAssertFalse(due(at(7, 7), now: at(6, 12)), "tomorrow's isn't on this week's Wednesday column")
        XCTAssertFalse(due(at(5, 7), now: at(6, 12)), "yesterday's is over")
    }

    func testNotOnceItIsDoneOrSkipped() {
        XCTAssertFalse(due(at(6, 7), done: true, now: at(6, 12)), "the workout happened")
        XCTAssertFalse(due(at(6, 7), skipped: true, now: at(6, 12)))
    }
}
