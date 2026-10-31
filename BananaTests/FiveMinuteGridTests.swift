import XCTest

final class FiveMinuteGridTests: XCTestCase {
    private struct DateParts: Equatable {
        let day: Int
        let hour: Int
        let minute: Int
    }

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ hour: Int, _ minute: Int, day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }

    private func parts(_ date: Date) -> DateParts {
        let c = calendar.dateComponents([.day, .hour, .minute], from: date)
        return DateParts(day: c.day!, hour: c.hour!, minute: c.minute!)
    }

    func testRoundsDownWhenCloserToThePreviousFiveMinuteMark() {
        let result = parts(FiveMinuteGrid.snapped(date(9, 7), calendar: calendar))
        XCTAssertEqual(result, DateParts(day: 1, hour: 9, minute: 5))
    }

    func testRoundsUpWhenCloserToTheNextFiveMinuteMark() {
        let result = parts(FiveMinuteGrid.snapped(date(9, 8), calendar: calendar))
        XCTAssertEqual(result, DateParts(day: 1, hour: 9, minute: 10))
    }

    /// No integer minute lands exactly halfway between two 5-minute marks (the halfway point
    /// is :x2.5), so :x2 and :x3 bracket it — the last minute that still rounds down and the
    /// first that rounds up.
    func testMinutesBracketingTheMidpointRoundInOppositeDirections() {
        XCTAssertEqual(parts(FiveMinuteGrid.snapped(date(9, 2), calendar: calendar)),
                        DateParts(day: 1, hour: 9, minute: 0))
        XCTAssertEqual(parts(FiveMinuteGrid.snapped(date(9, 3), calendar: calendar)),
                        DateParts(day: 1, hour: 9, minute: 5))
    }

    func testValueAlreadyOnABoundaryIsUnchanged() {
        for minute in stride(from: 0, to: 60, by: 5) {
            let input = date(11, minute)
            XCTAssertEqual(FiveMinuteGrid.snapped(input, calendar: calendar), input,
                            "minute \(minute) is already on the grid and must not move")
        }
    }

    /// :58 rounds toward :60 — the next hour, not backward to :55 — and that has to carry
    /// forward into the next day when the hour itself is 23.
    func testRoundingPastTheTopOfTheHourCarriesIntoTheNextHour() {
        let result = parts(FiveMinuteGrid.snapped(date(9, 58), calendar: calendar))
        XCTAssertEqual(result, DateParts(day: 1, hour: 10, minute: 0))
    }

    func testRoundingAcrossMidnightCarriesTheDayForward() {
        let result = parts(FiveMinuteGrid.snapped(date(23, 58), calendar: calendar))
        XCTAssertEqual(result, DateParts(day: 2, hour: 0, minute: 0))
    }

    func testRoundingDownNearMidnightStaysOnTheSameDay() {
        let result = parts(FiveMinuteGrid.snapped(date(23, 56), calendar: calendar))
        XCTAssertEqual(result, DateParts(day: 1, hour: 23, minute: 55))
    }

    // MARK: - A field that only steps by single minutes (the Mac's)

    private func at(_ hour: Int, _ minute: Int, day: Int = 11) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testOnePressOfTheMinuteArrowMovesFiveMinutes() {
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 10), to: at(9, 11), calendar: utc), at(9, 15))
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 10), to: at(9, 9), calendar: utc), at(9, 5))
    }

    func testTheArrowCarriesAcrossTheHourWhereTheFieldWraps() {
        // The field shows 9:59 → 9:00 for "up"; that is five minutes on, into the next hour.
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 55), to: at(9, 56), calendar: utc), at(10, 0))
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 59), to: at(9, 0), calendar: utc), at(10, 5))
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 0), to: at(9, 59), calendar: utc), at(8, 55))
    }

    func testATypedTimeOrAnotherHourLandsOnTheNearestMark() {
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 10), to: at(9, 33), calendar: utc), at(9, 35))
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 10), to: at(14, 10), calendar: utc), at(14, 10))
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 10), to: at(9, 10, day: 12), calendar: utc), at(9, 10, day: 12))
    }

    func testAnOffGridTimeStepsFromItsNearestMark() {
        XCTAssertEqual(FiveMinuteGrid.stepped(from: at(9, 7), to: at(9, 8), calendar: utc), at(9, 10))
    }
}
