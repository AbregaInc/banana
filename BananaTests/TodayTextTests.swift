import XCTest

/// How Today talks about time.
final class TodayTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func later(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func testCountdownsReadLikeSpeech() {
        XCTAssertEqual(TodayText.countdown(to: later(12), now: now), "in 12 min")
        XCTAssertEqual(TodayText.countdown(to: later(11.2), now: now), "in 12 min", "rounded up: never late")
        XCTAssertEqual(TodayText.countdown(to: later(65), now: now), "in 1 hr 5 min")
        XCTAssertEqual(TodayText.countdown(to: later(120), now: now), "in 2 hr")
        XCTAssertEqual(TodayText.countdown(to: later(0.2), now: now), "now")
    }

    func testUpNextLeadsWithTheTripWhenThereIsOne() {
        XCTAssertEqual(TodayText.upNextLead(start: later(40), leaveBy: later(15), now: now), "Leave in 15 min")
        XCTAssertEqual(TodayText.upNextLead(start: later(40), leaveBy: nil, now: now), "Starts in 40 min")
        XCTAssertEqual(TodayText.upNextLead(start: later(20), leaveBy: later(0.1), now: now), "Leave now")
        XCTAssertNil(TodayText.upNextLead(start: later(300), leaveBy: nil, now: now), "far off: the clock time says it")
    }

    func testOnlyGapsWorthPlanningAreNamed() {
        XCTAssertNil(TodayText.freeGap(from: now, to: later(20)))
        XCTAssertEqual(TodayText.freeGap(from: now, to: later(47)), "45 min free")
        XCTAssertEqual(TodayText.freeGap(from: now, to: later(135)), "2 hr 15 min free")
        XCTAssertEqual(TodayText.freeGap(from: now, to: later(125)), "2 hr free")
    }

    func testThePartsOfTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: hour))! }
        XCTAssertEqual(DayPart.of(at(8), calendar: calendar), .morning)
        XCTAssertEqual(DayPart.of(at(12), calendar: calendar), .afternoon)
        XCTAssertEqual(DayPart.of(at(17), calendar: calendar), .evening)
    }

    // MARK: - The briefing's greeting

    func testTheGreetingFollowsTheHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: hour))! }
        XCTAssertEqual(TodayText.greeting(at: at(7), calendar: calendar), "Good morning")
        XCTAssertEqual(TodayText.greeting(at: at(11), calendar: calendar), "Good morning")
        // It said "Good morning" whenever it was opened.
        XCTAssertEqual(TodayText.greeting(at: at(12), calendar: calendar), "Good afternoon")
        XCTAssertEqual(TodayText.greeting(at: at(16), calendar: calendar), "Good afternoon")
        XCTAssertEqual(TodayText.greeting(at: at(17), calendar: calendar), "Good evening")
        XCTAssertEqual(TodayText.greeting(at: at(23), calendar: calendar), "Good evening")
        XCTAssertEqual(TodayText.greeting(at: at(3), calendar: calendar), "Good evening")
    }
}
