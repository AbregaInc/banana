import XCTest

final class AvailabilityFinderTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Monday 28 Sep 2026 at the given local time.
    private func monday(_ hour: Int, _ minute: Int = 0, plusDays: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: plusDays, to: base)!
    }

    private func busy(_ from: Date, _ to: Date) -> DateInterval { DateInterval(start: from, end: to) }

    func testGapsBetweenMeetingsWithinWorkingHours() {
        var request = AvailabilityRequest()
        request.dayCount = 1
        let slots = AvailabilityFinder.freeSlots(
            busy: [busy(monday(10), monday(11)), busy(monday(13), monday(14, 30))],
            request: request, now: monday(7), calendar: calendar)
        XCTAssertEqual(slots, [
            busy(monday(9), monday(10)),
            busy(monday(11), monday(13)),
            busy(monday(14, 30), monday(18)),
        ])
    }

    func testNeverOffersThePastAndRoundsUpToTheGrid() {
        var request = AvailabilityRequest()
        request.dayCount = 1
        let slots = AvailabilityFinder.freeSlots(busy: [], request: request,
                                                 now: monday(15, 7), calendar: calendar)
        XCTAssertEqual(slots, [busy(monday(15, 15), monday(18))])
    }

    func testTodayIsSkippedOnceItsWorkingHoursAreOver() {
        var request = AvailabilityRequest()
        request.dayCount = 1
        let slots = AvailabilityFinder.freeSlots(busy: [], request: request,
                                                 now: monday(19), calendar: calendar)
        XCTAssertEqual(slots, [busy(monday(9, plusDays: 1), monday(18, plusDays: 1))])
    }

    func testGapsShorterThanTheMeetingAreNotOffered() {
        var request = AvailabilityRequest()
        request.dayCount = 1
        request.duration = 60 * 60
        let slots = AvailabilityFinder.freeSlots(
            busy: [busy(monday(9), monday(10)), busy(monday(10, 45), monday(17, 30))],
            request: request, now: monday(7), calendar: calendar)
        XCTAssertEqual(slots, [], "45 and 30 minute gaps cannot hold an hour")
    }

    func testOverlappingAndOutOfOrderBusyIntervals() {
        var request = AvailabilityRequest()
        request.dayCount = 1
        let slots = AvailabilityFinder.freeSlots(
            busy: [busy(monday(12), monday(15)), busy(monday(8), monday(9, 30)), busy(monday(11), monday(13))],
            request: request, now: monday(7), calendar: calendar)
        XCTAssertEqual(slots, [busy(monday(9, 30), monday(11)), busy(monday(15), monday(18))])
    }

    func testBufferKeepsRoomAroundMeetings() {
        var request = AvailabilityRequest()
        request.dayCount = 1
        request.buffer = 15 * 60
        let slots = AvailabilityFinder.freeSlots(
            busy: [busy(monday(12), monday(13))], request: request, now: monday(7), calendar: calendar)
        XCTAssertEqual(slots, [busy(monday(9), monday(11, 45)), busy(monday(13, 15), monday(18))])
    }

    func testWeekendsAreSkippedUnlessIncluded() {
        var request = AvailabilityRequest()
        request.dayCount = 6
        let friday = monday(7, plusDays: 4)
        let weekdays = AvailabilityFinder.days(for: request, now: friday, calendar: calendar)
        XCTAssertEqual(weekdays.map { calendar.component(.weekday, from: $0) }, [6, 2, 3, 4, 5, 6])
        request.includeWeekends = true
        let all = AvailabilityFinder.days(for: request, now: friday, calendar: calendar)
        XCTAssertEqual(all.map { calendar.component(.weekday, from: $0) }, [6, 7, 1, 2, 3, 4])
    }

    func testTextGroupsSlotsByDayAndNamesTheZone() {
        let slots = [busy(monday(9), monday(10)), busy(monday(14), monday(15, 30)),
                     busy(monday(9, plusDays: 1), monday(12, plusDays: 1))]
        let text = AvailabilityFinder.text(for: slots, request: AvailabilityRequest(),
                                           timeZone: calendar.timeZone, locale: Locale(identifier: "en_US"))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("30 minutes"))
        XCTAssertTrue(lines[0].contains("EDT"))
        XCTAssertEqual(lines[1], "• Mon, Sep 28: 9–10 AM, 2–3:30 PM")
        XCTAssertEqual(lines[2], "• Tue, Sep 29: 9 AM–12 PM")
    }

    func testTextSaysSoWhenNothingIsFree() {
        let text = AvailabilityFinder.text(for: [], request: AvailabilityRequest(), timeZone: calendar.timeZone)
        XCTAssertTrue(text.contains("don't have any open time"))
    }
}
