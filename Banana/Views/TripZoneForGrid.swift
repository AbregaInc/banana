import SwiftUI

/// The second time zone for the days a grid shows, from the flights the schedule knows
/// (`TripTimeZone`). One rule for the Mac's week and the phone's and iPad's: the Mac had it
/// alone, in a column of its own; the narrow grids say it as a second line in the hour column.
@MainActor
enum TripZoneForGrid {
    static func zone(first: Date?, last: Date?, legs: [SmartScheduleStore.FlightLeg]) -> TimeZone? {
        guard TripTimeZone.isEnabled, let first, let last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return nil }
        let flights = legs.compactMap { leg -> TripTimeZone.Flight? in
            guard let airport = AirportTable.lookup(leg.destCode) else { return nil }
            return TripTimeZone.Flight(departs: leg.flightStart, arrives: leg.arriveAt, zone: airport.timeZone)
        }
        return TripTimeZone.secondaryZone(visible: DateInterval(start: first, end: end), flights: flights,
                                          home: TripTimeZone.home, current: .current)
    }
}

/// The two zones' names, stacked: this device's over the other's, as the hours below are. Both
/// by city ("New York", "Berlin"): it was this device's abbreviation over the other's city
/// ("EDT" over "Berlin"), two kinds of name, and the abbreviation read at midnight said EDT on
/// the day clocks went back.
struct TripZoneNames: View {
    let secondary: TimeZone
    let date: Date

    static func city(_ zone: TimeZone) -> String {
        zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? zone.identifier
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(Self.city(.current)).foregroundStyle(.secondary)
            Text(Self.city(secondary)).foregroundStyle(DS.Palette.quietText)
        }
        .font(DS.Typeface.small(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hours in \(TimeZone.current.identifier) and \(secondary.identifier)")
        .accessibilityIdentifier("plan.tripZones")
    }
}
