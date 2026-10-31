import XCTest

/// What a background pass may do to the wake alarm (`WakeFollow`): add one, or make one earlier.
final class WakeFollowTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { at(8, 22) }   // the evening of the 8th

    private func changes(armed: [Date], computed: [Date], healthy: Bool = true) -> [WakeFollow.Change] {
        WakeFollow.changes(armed: armed, computed: computed, sourcesHealthy: healthy, now: now, calendar: calendar)
    }

    func testAMeetingAddedForTheMorningMovesTheAlarmEarlier() {
        // Armed for 7:30; an 8:00 meeting landed after the app was last open, so the wake is 6:30.
        XCTAssertEqual(changes(armed: [at(9, 7, 30)], computed: [at(9, 6, 30)]),
                       [.init(new: at(9, 6, 30), replacing: at(9, 7, 30))])
    }

    func testADayWithNoAlarmGetsOne() {
        XCTAssertEqual(changes(armed: [at(9, 7, 30)], computed: [at(9, 7, 30), at(10, 7)]),
                       [.init(new: at(10, 7), replacing: nil)])
    }

    func testAWakeThatWouldBeLaterIsLeftForTheNextTimeTheAppIsOpen() {
        // The early meeting was cancelled. Ringing early is put right on the next open; it is
        // never the background's to push an alarm back.
        XCTAssertEqual(changes(armed: [at(9, 6, 30)], computed: [at(9, 7, 30)]), [])
    }

    func testADayThatLostItsWakeKeepsItsAlarm() {
        XCTAssertEqual(changes(armed: [at(9, 6, 30), at(10, 7)], computed: [at(10, 7)]), [])
    }

    func testNothingChangesWhenACalendarCouldNotBeRead() {
        XCTAssertEqual(changes(armed: [at(9, 7, 30)], computed: [at(9, 6, 30), at(10, 7)], healthy: false), [])
    }

    func testTheSameWakeIsNotArmedAgain() {
        XCTAssertEqual(changes(armed: [at(9, 7, 30)], computed: [at(9, 7, 30)]), [])
        XCTAssertEqual(changes(armed: [at(9, 7, 30)], computed: [at(9, 7, 29).addingTimeInterval(30)]), [],
                       "half a minute earlier is the same wake")
    }

    func testAWakeAlreadyPastIsNotArmed() {
        XCTAssertEqual(changes(armed: [], computed: [at(8, 7)]), [])
    }

    func testSeveralDaysAtOnceInOrder() {
        XCTAssertEqual(changes(armed: [at(9, 7, 30), at(10, 7, 30)], computed: [at(11, 8), at(10, 6), at(9, 7, 30)]),
                       [.init(new: at(10, 6), replacing: at(10, 7, 30)), .init(new: at(11, 8), replacing: nil)])
    }
}
