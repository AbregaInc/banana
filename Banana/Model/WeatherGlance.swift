import Foundation

/// Which hour of a day's forecast the plan's weather chip shows (`WeatherChip`): for today, the
/// hour it is now (or the nearest one the forecast has); for another day, midday.
///
/// The forecast used to run down Plan's List as a stripe. With List gone the Day and Week
/// calendars had no weather at all, so the day's header carries it.
enum WeatherGlance {
    /// The moment the chip stands for: now, today; midday on another day.
    static func instant(on day: Date, now: Date, calendar: Calendar = .current) -> Date {
        if calendar.isDate(day, inSameDayAs: now) { return now }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    static func hourIndex(of hours: [Date], on day: Date, now: Date, calendar: Calendar = .current) -> Int? {
        guard !hours.isEmpty else { return nil }
        let target = instant(on: day, now: now, calendar: calendar)
        return hours.indices.min { abs(hours[$0].timeIntervalSince(target)) < abs(hours[$1].timeIntervalSince(target)) }
    }
}

/// What the forecast's footer shows for Apple Weather, which Apple requires wherever its
/// forecast shows: the mark and the legal link to its other data sources
/// (developer.apple.com/weatherkit/get-started). WeatherKit hands both over in `attribution`;
/// until it has, or when asking for it failed, the footer still shows the name with the Apple
/// logo and the same legal page, so the forecast is never on screen without them.
enum WeatherAttributionFooter: Equatable {
    /// WeatherKit's own mark images and legal page.
    case mark(light: URL, dark: URL, legalPage: URL, name: String)
    /// The mark as text: the Apple logo and "Weather".
    case text(String, legalPage: URL)

    /// The page WeatherKit's `legalPageURL` points at.
    static let legalPage = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
    /// The Apple logo (U+F8FF, drawn by the system fonts on Apple platforms) and "Weather".
    static let markText = "\u{F8FF}\u{00A0}Weather"

    static func resolve(markLight: URL?, markDark: URL?, legalPage: URL?, name: String?) -> Self {
        if let markLight, let markDark {
            return .mark(light: markLight, dark: markDark, legalPage: legalPage ?? Self.legalPage,
                         name: name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.markText)
        }
        return .text(Self.markText, legalPage: legalPage ?? Self.legalPage)
    }

    var legalPage: URL {
        switch self {
        case .mark(_, _, let page, _), .text(_, let page): page
        }
    }
}

/// What each palette layer of a forecast symbol draws, so `WeatherSymbol` can colour clouds,
/// light and precipitation apart. SF Symbols order a symbol's layers its own way (cloud.bolt
/// puts the bolt on its second layer; cloud.bolt.rain draws the bolt with the cloud, on the
/// first), so this is a table, measured by rendering each symbol with one colour per layer.
/// WeatherKit's symbol names and the sample's are in it; another falls back on its name.
enum WeatherSymbolLayers {
    enum Part: Equatable { case cloud, light, wet }

    static let table: [String: [Part]] = [
        "sun.max": [.light], "moon": [.light], "moon.stars": [.light, .light],
        "sun.horizon": [.cloud, .light], "sunrise": [.cloud, .light], "sunset": [.cloud, .light],
        "sun.haze": [.cloud, .light], "sun.dust": [.cloud, .light],
        "cloud": [.cloud], "cloud.sun": [.cloud, .light], "cloud.moon": [.cloud, .light],
        "cloud.rain": [.cloud, .wet], "cloud.drizzle": [.cloud, .wet], "cloud.heavyrain": [.cloud, .wet],
        "cloud.snow": [.cloud, .wet], "cloud.sleet": [.cloud, .wet], "cloud.hail": [.cloud, .wet],
        "cloud.sun.rain": [.cloud, .light, .wet], "cloud.moon.rain": [.cloud, .light, .wet],
        "cloud.bolt": [.cloud, .light], "cloud.bolt.rain": [.cloud, .wet],
        "cloud.sun.bolt": [.cloud, .light], "cloud.moon.bolt": [.cloud, .light],
        "cloud.fog": [.cloud, .cloud], "smoke": [.cloud], "wind": [.cloud], "wind.snow": [.cloud, .wet],
        "snowflake": [.wet], "tornado": [.cloud], "hurricane": [.cloud], "tropicalstorm": [.cloud],
    ]

    /// The parts of `symbol`'s layers, first layer first (".fill" or not draws the same parts).
    static func parts(of symbol: String) -> [Part] {
        let base = symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol
        if let known = table[base] { return known }
        let words = base.split(separator: ".")
        let light = words.contains { ["sun", "moon", "stars", "bolt"].contains($0) }
        let wet = words.contains { ["rain", "drizzle", "snow", "sleet", "hail", "heavyrain"].contains($0) }
        if words.first == "cloud" { return [.cloud] + (light ? [.light] : []) + (wet ? [.wet] : []) }
        return light ? [.light, .light] : wet ? [.wet] : [.cloud]
    }
}
