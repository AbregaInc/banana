import XCTest
import Foundation

final class MorningBriefingScheduleTests: XCTestCase {
    func testEmptyMorningDoesNotPresentAndCanPresentWhenContentArrives() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
        XCTAssertFalse(MorningBriefingSchedule.shouldShow(now: now, plannedWake: nil,
            lastShownDay: nil, hasContent: false, calendar: calendar))
        XCTAssertTrue(MorningBriefingSchedule.shouldShow(now: now, plannedWake: nil,
            lastShownDay: nil, hasContent: true, calendar: calendar))
        XCTAssertFalse(MorningBriefingSchedule.shouldShow(now: now, plannedWake: nil,
            lastShownDay: MorningBriefingSchedule.dayKey(now, calendar: calendar),
            hasContent: true, calendar: calendar))
    }

    func testContentIsNotQueriedOutsideMorningOrAfterShowing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15))!
        var queries = 0
        func content() -> Bool { queries += 1; return true }
        XCTAssertFalse(MorningBriefingSchedule.shouldShow(now: now, plannedWake: nil,
            lastShownDay: nil, hasContent: content(), calendar: calendar))
        XCTAssertEqual(queries, 0)
    }
}
