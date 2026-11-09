import XCTest

/// The sample week the preview and App Store captures show reads like a real forecast: days
/// differ, and the forecast page's header, hour strip and week list agree with each other.
final class WeatherSampleTests: XCTestCase {
    private let week = WeatherSample.week()

    func testItIsAWeekOfDifferentDays() {
        XCTAssertEqual(week.count, 7)
        XCTAssertTrue(week.allSatisfy { $0.hours.map(\.hour) == Array(0..<24) })
        XCTAssertGreaterThan(Set(week.map(\.highF)).count, 4, "every day the same temperature")
        XCTAssertGreaterThan(Set(week.map(\.symbol)).count, 3, "every day the same sky")
        // Some dry days and some wet ones, not the same shower every afternoon.
        XCTAssertGreaterThanOrEqual(week.filter { $0.wettest < 0.2 }.count, 2)
        XCTAssertGreaterThanOrEqual(week.filter { $0.wettest >= WeatherSample.rainy }.count, 2)
        XCTAssertGreaterThan(Set(week.map(\.wettest)).count, 4)
    }

    func testADayIsWhatItsHoursSay() {
        for (index, day) in week.enumerated() {
            let rainyHours = day.hours.filter { $0.precip >= WeatherSample.rainy }
            // The week row's sky is rain exactly when an hour is.
            let rainSymbol = day.symbol.contains("rain")
            XCTAssertEqual(rainSymbol, !rainyHours.isEmpty, "day \(index): \(day.symbol)")
            for hour in day.hours {
                XCTAssertEqual(hour.symbol.contains("rain"), hour.precip >= WeatherSample.rainy, "day \(index) \(hour.hour):00")
                XCTAssertTrue((0...1).contains(hour.precip) && (0...1).contains(hour.humidity))
            }
            XCTAssertLessThan(day.lowF, day.highF)
        }
    }

    func testTodayIsDryAsItsHoursAre() {
        // Today leads the page: no hour of it is wetter than the week row shows (none, under 20%).
        let today = week[0]
        XCTAssertLessThan(today.wettest, 0.2)
        XCTAssertFalse(today.symbol.contains("rain"))
    }

    // MARK: - Symbol colours (`WeatherSymbol`)

    func testEverySymbolTheForecastShowsHasItsLayersKnown() {
        // Each of the sample's symbols is measured, not guessed from its name.
        for symbol in Set(week.flatMap { [$0.symbol] + $0.hours.map(\.symbol) }) {
            let base = symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol
            XCTAssertNotNil(WeatherSymbolLayers.table[base], symbol)
        }
    }

    func testCloudsLightAndRainEachGetTheirOwnColour() {
        typealias P = WeatherSymbolLayers.Part
        XCTAssertEqual(WeatherSymbolLayers.parts(of: "sun.max.fill"), [P.light])
        XCTAssertEqual(WeatherSymbolLayers.parts(of: "cloud.fill"), [P.cloud])
        XCTAssertEqual(WeatherSymbolLayers.parts(of: "cloud.sun.rain.fill"), [P.cloud, .light, .wet])
        // Lightning is drawn with the cloud in cloud.bolt.rain, so that layer is the cloud's.
        XCTAssertEqual(WeatherSymbolLayers.parts(of: "cloud.bolt.rain.fill"), [P.cloud, .wet])
        for (base, parts) in WeatherSymbolLayers.table {
            let words = Set(base.split(separator: ".").map(String.init))
            XCTAssertTrue((1...3).contains(parts.count), base)
            if words.contains("cloud") { XCTAssertEqual(parts.first, .cloud, base) }
            if !words.isDisjoint(with: ["rain", "drizzle", "heavyrain", "snow", "sleet", "hail"]) || base == "snowflake" {
                XCTAssertTrue(parts.contains(.wet), base)
            }
            if !words.isDisjoint(with: ["sun", "moon"]) { XCTAssertTrue(parts.contains(.light), base) }
        }
        // A name WeatherKit might add later still gets a cloud, its light and its rain.
        XCTAssertEqual(WeatherSymbolLayers.parts(of: "cloud.moon.sleet.fill"), [P.cloud, .light, .wet])
    }
}
