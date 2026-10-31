import XCTest

/// A routine can follow your wake-up as one follows a workout (`WakeFollowing`): it starts at the
/// day's wake plus its minutes, and moves when the wake does.
final class WakeFollowingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testItStartsItsMinutesAfterTheDaysPlannedWake() {
        // An early meeting moved Wednesday's wake to 5:40.
        let start = WakeFollowing.start(on: at(7, 0), plannedWake: at(7, 5, 40), wakeRoutine: (6, 30), own: (8, 0),
                                        minutesAfter: 15, calendar: calendar)
        XCTAssertEqual(start, at(7, 5, 55))
    }

    func testWithNoPlannedWakeItFollowsTheWakeRoutinesOwnTime() {
        let start = WakeFollowing.start(on: at(10, 0), plannedWake: nil, wakeRoutine: (6, 30), own: (8, 0),
                                        minutesAfter: 0, calendar: calendar)
        XCTAssertEqual(start, at(10, 6, 30))
    }

    func testWithNoWakeRoutineItKeepsItsOwnTime() {
        let start = WakeFollowing.start(on: at(10, 0), plannedWake: nil, wakeRoutine: nil, own: (8, 0),
                                        minutesAfter: 30, calendar: calendar)
        XCTAssertEqual(start, at(10, 8, 0), "nothing to follow: its own time, not that plus the minutes")
    }

    func testItSaysWhatItFollows() {
        XCTAssertEqual(WakeFollowing.describe(minutesAfter: 0), "When you wake up")
        XCTAssertEqual(WakeFollowing.describe(minutesAfter: 20), "20 min after you wake up")
    }
}
