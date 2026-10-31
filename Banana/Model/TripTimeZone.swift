import Foundation

/// The second time zone the calendar shows while you travel — decided from the flights already
/// on your calendar, with no setting to remember to change.
///
/// - Planning a trip from home: the week that holds the stay shows the destination's hours next
///   to your own, so a call booked "at 10" can be checked against where you will be.
/// - Away (the Mac's clock is on local time): home's hours, so you can see what time it is for
///   everyone you left behind.
/// - Otherwise: nothing. One column is the right answer most weeks.
enum TripTimeZone {
    struct Flight: Equatable {
        let departs: Date
        let arrives: Date
        /// The destination airport's zone.
        let zone: TimeZone
    }

    struct Stay: Equatable {
        let interval: DateInterval
        let zone: TimeZone
    }

    /// Longest a stay is assumed to last when no flight home is on the calendar yet.
    static let openEndedStay: TimeInterval = 14 * 86_400

    /// Time spent somewhere whose clock differs from home: from landing until the next flight
    /// leaves (or `openEndedStay`, when there is no next flight).
    static func stays(flights: [Flight], home: TimeZone) -> [Stay] {
        let ordered = flights.sorted { $0.departs < $1.departs }
        var result: [Stay] = []
        for (index, flight) in ordered.enumerated() {
            let leaves = index + 1 < ordered.count ? ordered[index + 1].departs
                                                   : flight.arrives.addingTimeInterval(openEndedStay)
            guard leaves > flight.arrives,
                  !sameClock(flight.zone, home, at: flight.arrives) else { continue }
            result.append(Stay(interval: DateInterval(start: flight.arrives, end: leaves), zone: flight.zone))
        }
        return result
    }

    /// The extra zone for a range of visible days, or nil for a single column.
    static func secondaryZone(visible: DateInterval, flights: [Flight], home: TimeZone,
                              current: TimeZone) -> TimeZone? {
        if !sameClock(current, home, at: visible.start) { return home }
        var overlapByZone: [String: (zone: TimeZone, seconds: TimeInterval)] = [:]
        for stay in stays(flights: flights, home: home) {
            guard let overlap = stay.interval.intersection(with: visible), overlap.duration > 0 else { continue }
            guard !sameClock(stay.zone, current, at: overlap.start) else { continue }
            overlapByZone[stay.zone.identifier, default: (stay.zone, 0)].seconds += overlap.duration
        }
        return overlapByZone.values.max { $0.seconds < $1.seconds }?.zone
    }

    /// The label for an hour of the primary grid, read in `zone`: "3 PM", or "3:30 PM" where the
    /// offsets differ by a part-hour.
    static func label(forHour hour: Int, on day: Date, primary: Calendar, zone: TimeZone,
                      locale: Locale = .current) -> String {
        let instant = primary.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: zone).hour()
        var other = Calendar(identifier: .gregorian)
        other.timeZone = zone
        if other.component(.minute, from: instant) != 0 { style = style.minute() }
        return instant.formatted(style)
    }

    /// A short name for the column header: "CEST", or the city when the zone has no abbreviation.
    static func shortName(_ zone: TimeZone, at date: Date) -> String {
        if let abbreviation = zone.abbreviation(for: date), !abbreviation.hasPrefix("GMT") {
            return abbreviation
        }
        return zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? zone.identifier
    }

    /// Where "home" is: recorded the first time it is asked for, changeable in Settings.
    // No dots in these keys: UserDefaults observation reads a dot as a key path.
    static let homeKey = "tripTimeZoneHome"
    static let enabledKey = "tripTimeZoneEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var home: TimeZone {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: homeKey), let zone = TimeZone(identifier: id) { return zone }
        defaults.set(TimeZone.current.identifier, forKey: homeKey)
        return .current
    }

    static func sameClock(_ a: TimeZone, _ b: TimeZone, at date: Date) -> Bool {
        a.secondsFromGMT(for: date) == b.secondsFromGMT(for: date)
    }
}
