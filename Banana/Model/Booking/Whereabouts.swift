import Foundation

/// Where the owner will be, for booking hours that follow travel (docs/design/BOOKING.md §13): the
/// `plan.whereabouts` record the phone publishes and the service reads
/// (`Service/src/booking/whereabouts.js`). Times and IANA zones only — no airports, cities,
/// titles or places leave the phone.
///
/// | Field | |
/// |---|---|
/// | `current` | the zone the phone is in now |
/// | `home` | the zone of home (`TripTimeZone.home`, else `current`) |
/// | `stays` | `[{from, to, zone}]`: time where the clock differs from home, landing to the next departure |
/// | `flights` | `[{departs, arrives}]`: time in the air |
/// | `updatedAt` | when the phone worked it out; the service trusts a record for 14 days |
///
/// On the service: the stay covering an instant; else, before the first flight, `current`; else
/// `home`.
struct Whereabouts: Codable, Equatable, Sendable {
    struct Stay: Codable, Equatable, Sendable {
        var from: Date
        var to: Date
        var zone: String
    }

    struct Flight: Codable, Equatable, Sendable {
        var departs: Date
        var arrives: Date
    }

    var current: String
    var home: String
    var stays: [Stay]
    var flights: [Flight]
    var updatedAt: Date

    /// The same but for when it was worked out: nothing to publish.
    func sameContent(as other: Whereabouts?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return other == self
    }
}

/// Works out `Whereabouts` from the flights on the calendar. Pure, and cheap enough for any
/// thread: the store runs it off the main thread (`WhereaboutsStore`).
enum WhereaboutsBuilder {
    /// The longest booking horizon (90 days) and a day either side.
    static let horizonDays = 92
    /// A flight longer than this is a misread event, not a flight (the service drops them too).
    static let longestFlight: TimeInterval = 36 * 3600

    /// What the builder reads of a calendar event: the words a flight is recognised by and its times.
    struct Event: Sendable {
        var title: String
        var location: String?
        var notes: String?
        var start: Date
        var end: Date
    }

    /// The flights among the events, each to its destination airport's zone. Two copies of one
    /// flight (the airline's and Google's own) are one: same destination, departing within 2
    /// minutes (the rule `SmartScheduleStore.resolvedFlightLegs` uses).
    static func flights(from events: [Event]) -> [TripTimeZone.Flight] {
        var found: [(departs: Date, code: String, flight: TripTimeZone.Flight)] = []
        for event in events {
            guard event.end > event.start, event.end.timeIntervalSince(event.start) <= longestFlight,
                  let parsed = FlightParser.parse(title: event.title, location: event.location, notes: event.notes)
            else { continue }
            let code = parsed.destination.code
            if found.contains(where: { $0.code == code && abs($0.departs.timeIntervalSince(event.start)) < 120 }) { continue }
            found.append((event.start, code, TripTimeZone.Flight(departs: event.start, arrives: event.end,
                                                                 zone: parsed.destination.timeZone)))
        }
        return found.map(\.flight).sorted { $0.departs < $1.departs }
    }

    /// The record for `now`: the flights from yesterday to `horizonDays` ahead, and the stays they
    /// make (`TripTimeZone.stays`). A stay at home's clock is no stay: it reads as home.
    static func build(flights: [TripTimeZone.Flight], current: TimeZone, home: TimeZone, now: Date,
                      horizonDays: Int = horizonDays) -> Whereabouts {
        let from = now.addingTimeInterval(-86_400)
        let to = now.addingTimeInterval(TimeInterval(horizonDays) * 86_400)
        let kept = flights
            .filter { $0.arrives > $0.departs && $0.arrives > from && $0.departs < to }
            .sorted { $0.departs < $1.departs }
        let stays = TripTimeZone.stays(flights: kept, home: home).map {
            Whereabouts.Stay(from: $0.interval.start, to: $0.interval.end, zone: BookingType.deviceZone($0.zone))
        }
        return Whereabouts(current: BookingType.deviceZone(current), home: BookingType.deviceZone(home),
                           stays: stays, flights: kept.map { Whereabouts.Flight(departs: $0.departs, arrives: $0.arrives) },
                           updatedAt: now)
    }

    /// Whether to publish `next`: it says something new, or the copy out there is a day old (the
    /// service stops trusting one after 14 days, so a quiet phone still says it's there).
    static func shouldPublish(_ next: Whereabouts, over published: Whereabouts?, heartbeat: TimeInterval = 86_400) -> Bool {
        guard let published, next.sameContent(as: published) else { return true }
        return next.updatedAt.timeIntervalSince(published.updatedAt) >= heartbeat
    }
}
