import XCTest

/// The plan's weather chip shows the hour it is now for today, and midday for another day
/// (`WeatherGlance`).
final class WeatherGlanceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func hours(of day: Int, from first: Int = 0, through last: Int = 23) -> [Date] {
        (first...last).map { at(day, $0) }
    }

    func testTodayShowsTheHourItIs() {
        let index = WeatherGlance.hourIndex(of: hours(of: 8), on: at(8, 0), now: at(8, 15, 20), calendar: calendar)
        XCTAssertEqual(index, 15)
    }

    func testLateInTheHourItIsNearerTheNext() {
        XCTAssertEqual(WeatherGlance.hourIndex(of: hours(of: 8), on: at(8, 0), now: at(8, 15, 50), calendar: calendar), 16)
    }

    func testAnotherDayShowsMidday() {
        XCTAssertEqual(WeatherGlance.hourIndex(of: hours(of: 9), on: at(9, 0), now: at(8, 15), calendar: calendar), 12)
    }

    func testAForecastThatStartsLaterShowsItsNearestHour() {
        // The forecast for today may begin at the hour it was fetched.
        XCTAssertEqual(WeatherGlance.hourIndex(of: hours(of: 8, from: 18), on: at(8, 0), now: at(8, 15), calendar: calendar), 0)
    }

    func testNoForecastShowsNothing() {
        XCTAssertNil(WeatherGlance.hourIndex(of: [], on: at(8, 0), now: at(8, 15), calendar: calendar))
    }
}
