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

/// The forecast is never on screen without Apple Weather's mark and legal link (App Review 5.2.5).
final class WeatherAttributionFooterTests: XCTestCase {
    private let light = URL(string: "https://weatherkit.apple.com/assets/branding/combined-mark-light.png")!
    private let dark = URL(string: "https://weatherkit.apple.com/assets/branding/combined-mark-dark.png")!
    private let legal = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    func testWeatherKitsOwnMarkAndPageWhenItHasHandedThemOver() {
        XCTAssertEqual(WeatherAttributionFooter.resolve(markLight: light, markDark: dark, legalPage: legal, name: "Apple Weather"),
                       .mark(light: light, dark: dark, legalPage: legal, name: "Apple Weather"))
    }

    func testWithoutWeatherKitsAttributionTheMarkIsTextAndTheLegalLinkStays() {
        let footer = WeatherAttributionFooter.resolve(markLight: nil, markDark: nil, legalPage: nil, name: nil)
        XCTAssertEqual(footer, .text("\u{F8FF}\u{00A0}Weather", legalPage: WeatherAttributionFooter.legalPage))
        XCTAssertEqual(footer.legalPage.host, "weatherkit.apple.com")
    }

    func testAnEmptyServiceNameStillLabelsTheMark() {
        guard case let .mark(_, _, _, name) = WeatherAttributionFooter.resolve(markLight: light, markDark: dark, legalPage: legal, name: "") else {
            return XCTFail("expected WeatherKit's mark")
        }
        XCTAssertEqual(name, WeatherAttributionFooter.markText)
    }
}
