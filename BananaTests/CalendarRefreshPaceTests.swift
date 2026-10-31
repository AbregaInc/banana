import XCTest

final class CalendarRefreshPaceTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testFiveMinutesAwayAndTwentyFiveInLowPowerMode() {
        XCTAssertEqual(CalendarRefreshPace.interval(inFront: false, lowPower: false), 5 * 60)
        XCTAssertEqual(CalendarRefreshPace.interval(inFront: false, lowPower: true), 25 * 60)
    }

    func testInFrontItStaysAtTwoMinutesWhateverThePower() {
        // The screen is on and someone is reading the calendar: a small request is nothing
        // beside that.
        XCTAssertEqual(CalendarRefreshPace.interval(inFront: true, lowPower: false), 2 * 60)
        XCTAssertEqual(CalendarRefreshPace.interval(inFront: true, lowPower: true), 2 * 60)
    }

    func testWhatIsLeftBeforeTheNextAsk() {
        XCTAssertEqual(CalendarRefreshPace.remaining(last: nil, now: now, inFront: false, lowPower: false), 0)
        let fourAgo = now.addingTimeInterval(-4 * 60)
        XCTAssertEqual(CalendarRefreshPace.remaining(last: fourAgo, now: now, inFront: false, lowPower: false), 60)
        XCTAssertEqual(CalendarRefreshPace.remaining(last: fourAgo, now: now, inFront: true, lowPower: false), 0,
                       "coming to the front, an ask four minutes old is overdue")
        XCTAssertEqual(CalendarRefreshPace.remaining(last: fourAgo, now: now, inFront: false, lowPower: true), 21 * 60,
                       "Low Power Mode coming on stretches the wait")
        XCTAssertEqual(CalendarRefreshPace.remaining(last: now.addingTimeInterval(-3_600), now: now, inFront: false, lowPower: true), 0)
    }

    func testALookRunsTheFullPassOnlyWhenSomethingChangedOrTimeHasMovedThings() {
        let recent = now.addingTimeInterval(-20 * 60)
        XCTAssertEqual(CalendarRefreshPace.afterLook(changed: true, lastFullPass: recent, now: now), .fullPass)
        XCTAssertEqual(CalendarRefreshPace.afterLook(changed: false, lastFullPass: recent, now: now), .nothing,
                       "nothing changed, and travel times are twenty minutes old")
        XCTAssertEqual(CalendarRefreshPace.afterLook(changed: false, lastFullPass: now.addingTimeInterval(-2 * 3_600), now: now), .fullPass,
                       "the old two-hourly pass still happens")
        XCTAssertEqual(CalendarRefreshPace.afterLook(changed: false, lastFullPass: nil, now: now), .fullPass)
        XCTAssertEqual(CalendarRefreshPace.afterLook(changed: nil, lastFullPass: nil, now: now), .nothing,
                       "the calendars couldn't be read: there is nothing to plan from")
    }

    func testAChangeIsToldToAPollOnce() {
        var seen = CalendarRefreshPace.Seen()
        XCTAssertFalse(seen.isNews(0), "nothing has changed yet")
        XCTAssertTrue(seen.isNews(1), "a read found someone's change")
        XCTAssertFalse(seen.isNews(1), "the next ask, five minutes on, with nothing new: not again")
        XCTAssertFalse(seen.isNews(1))
        XCTAssertTrue(seen.isNews(3), "two more reads found changes between asks: told once")
        XCTAssertFalse(seen.isNews(3))
    }
}
