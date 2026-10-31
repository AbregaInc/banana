import SwiftUI
import XCTest

/// `ClockTime`: a clock time stored as minutes after midnight, for a `TimeField`.
final class ClockTimeTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    func testMinutesSurviveTheTripThroughADate() {
        for minutes in [0, 1, 6 * 60 + 30, 12 * 60, 23 * 60 + 59] {
            XCTAssertEqual(ClockTime.minutes(of: ClockTime.date(minutes: minutes, calendar: calendar), calendar: calendar),
                           minutes)
        }
    }

    func testMinutesOutsideADayArePinnedToIt() {
        XCTAssertEqual(ClockTime.minutes(of: ClockTime.date(minutes: -5, calendar: calendar), calendar: calendar), 0)
        XCTAssertEqual(ClockTime.minutes(of: ClockTime.date(minutes: 24 * 60, calendar: calendar), calendar: calendar),
                       23 * 60 + 59)
    }

    func testMinutesReadOnlyTheClock() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 7, minute: 45, second: 30))!
        XCTAssertEqual(ClockTime.minutes(of: date, calendar: calendar), 7 * 60 + 45)
    }

    func testStoredStaysInsideItsRange() {
        let range = 17 * 60 ... 23 * 60 + 59
        XCTAssertEqual(ClockTime.stored(ClockTime.date(minutes: 9 * 60, calendar: calendar), in: range, calendar: calendar),
                       17 * 60)
        XCTAssertEqual(ClockTime.stored(ClockTime.date(minutes: 21 * 60 + 15, calendar: calendar), in: range, calendar: calendar),
                       21 * 60 + 15)
        XCTAssertEqual(ClockTime.stored(ClockTime.date(minutes: 9 * 60, calendar: calendar), calendar: calendar), 9 * 60)
    }

    func testRangeRunsBetweenItsTwoTimesOnOneDay() {
        let range = ClockTime.range(3 * 60 ... 12 * 60, calendar: calendar)
        XCTAssertEqual(ClockTime.minutes(of: range.lowerBound, calendar: calendar), 3 * 60)
        XCTAssertEqual(ClockTime.minutes(of: range.upperBound, calendar: calendar), 12 * 60)
        XCTAssertTrue(calendar.isDate(range.lowerBound, inSameDayAs: range.upperBound))
        XCTAssertTrue(range.contains(ClockTime.date(minutes: 7 * 60, calendar: calendar)))
    }

    func testBindingReadsAndWritesMinutes() {
        var minutes = 7 * 60
        let stored = Binding(get: { minutes }, set: { minutes = $0 })
        let time = ClockTime.binding(stored, in: 3 * 60 ... 12 * 60)
        XCTAssertEqual(ClockTime.minutes(of: time.wrappedValue), 7 * 60)
        time.wrappedValue = ClockTime.date(minutes: 8 * 60 + 20)
        XCTAssertEqual(minutes, 8 * 60 + 20)
        time.wrappedValue = ClockTime.date(minutes: 15 * 60)
        XCTAssertEqual(minutes, 12 * 60)
    }
}

/// `WeekdaySelection`: which days are on after a tap in `WeekdayToggleRow`.
final class WeekdaySelectionTests: XCTestCase {
    func testATapTurnsADayOnOrOff() {
        XCTAssertEqual(WeekdaySelection.toggled(3, in: [2], allowsEmpty: false), [2, 3])
        XCTAssertEqual(WeekdaySelection.toggled(3, in: [2, 3], allowsEmpty: false), [2])
    }

    func testTheLastDayStaysOnUnlessEmptyIsAllowed() {
        XCTAssertEqual(WeekdaySelection.toggled(2, in: [2], allowsEmpty: false), [2])
        XCTAssertFalse(WeekdaySelection.canToggle(2, in: [2], allowsEmpty: false))
        XCTAssertEqual(WeekdaySelection.toggled(2, in: [2], allowsEmpty: true), Set<Int>())
        XCTAssertTrue(WeekdaySelection.canToggle(2, in: [2], allowsEmpty: true))
    }

    func testAnyOtherDayCanAlwaysBeTapped() {
        XCTAssertTrue(WeekdaySelection.canToggle(4, in: [2], allowsEmpty: false))
        XCTAssertTrue(WeekdaySelection.canToggle(2, in: [2, 4], allowsEmpty: false))
        XCTAssertEqual(WeekdaySelection.toggled(4, in: Set<Int>(), allowsEmpty: false), [4])
    }
}
