import Foundation
import CoreLocation

/// Where you are and what zone you're in for a slice of a day. `place == nil` means "in transit"
/// (mid-flight) — weather is genuinely undefined there, so the stripe draws a gap, not a guess.
struct ResolvedPlace: Equatable {
    let coordinate: CLLocationCoordinate2D
    let placeName: String
    let timeZone: TimeZone

    static func == (a: ResolvedPlace, b: ResolvedPlace) -> Bool {
        // Grid-quantised equality: same ~cell + zone is the "same place" for republish-suppression.
        Int(a.coordinate.latitude * 20) == Int(b.coordinate.latitude * 20)
            && Int(a.coordinate.longitude * 20) == Int(b.coordinate.longitude * 20)
            && a.timeZone.identifier == b.timeZone.identifier
    }
}

/// One contiguous stretch of a day spent in one place (or in transit). Boundaries are minute-
/// quantised so the timeline republishes only on a real itinerary change, never per frame.
struct LocationSegment: Equatable {
    let start: Date
    let end: Date
    let place: ResolvedPlace?   // nil = in transit
    var isTransit: Bool { place == nil }
}

enum LocationTimeline {
    /// A flight reduced to its transition: depart/arrive instants + resolved endpoints.
    private struct Leg { let depart: Date; let arrive: Date; let origin: ResolvedPlace?; let destination: ResolvedPlace }
    /// A point where your location changes going forward (a flight arrival or a distant meeting).
    private struct Setter { let time: Date; let place: ResolvedPlace }

    /// Anything within this distance is "the same city" — meetings closer than this to the base
    /// don't fragment the day (all your NYC meetings are still just NYC).
    private static let sameCityKm = 40.0

    /// Build the location segments for `day`'s active window. `travelEvents` should span at least
    /// the day before through the day after, so a flight or hotel from an earlier day sets the base.
    static func segments(for day: Date,
                         travelEvents: [TravelEvent],
                         currentLocation: CLLocationCoordinate2D?,
                         startHour: Int = 6,
                         endHour: Int = 22) -> [LocationSegment] {
        let cal = Calendar.current
        let dayStart = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day) ?? day
        let dayEnd = cal.date(bySettingHour: endHour, minute: 0, second: 0, of: day) ?? day
        guard dayEnd > dayStart else { return [] }

        // Classify events into flights, accommodation spans, and located meetings.
        var legs: [Leg] = []
        var lodging: [(range: ClosedRange<Date>, place: ResolvedPlace)] = []
        var meetings: [(time: Date, place: ResolvedPlace)] = []

        for e in travelEvents {
            if let f = FlightParser.parse(title: e.title, location: e.location, notes: e.notes) {
                legs.append(Leg(depart: e.start, arrive: e.end,
                                origin: f.origin.map(place(airport:)),
                                destination: place(airport: f.destination)))
                continue
            }
            guard let coord = e.coordinate, let p = place(coordinate: coord) else { continue }
            if e.isAllDay || e.end.timeIntervalSince(e.start) > 20 * 3600 {
                lodging.append((e.start...max(e.start, e.end), p))     // multi-day stay = background base
            } else {
                meetings.append((e.start, p))
            }
        }
        legs.sort { $0.depart < $1.depart }
        // Collapse the Google-auto + airline copies of ONE flight (same slot + destination). Keep
        // the copy that resolved an ORIGIN — otherwise the origin-less copy can sort first, leave no
        // pre-flight origin, and the morning falls through to the destination hotel's all-day span
        // (which is why Friday morning read "Miami" before the flight had even left).
        var merged: [Leg] = []
        for leg in legs {
            if let i = merged.firstIndex(where: {
                abs($0.depart.timeIntervalSince(leg.depart)) < 120 && $0.destination == leg.destination
            }) {
                if merged[i].origin == nil, leg.origin != nil { merged[i] = leg }
            } else {
                merged.append(leg)
            }
        }
        legs = merged

        // Setters — points where your location is fixed going forward. The pre-first-flight origin
        // holds from the window start, so the MORNING of an outbound-flight day is the origin
        // airport's city, NOT the hotel you check into that night (whose all-day span starts at
        // local midnight and would otherwise claim the whole morning). Each flight arrival then
        // sets its destination; distant meetings set their own place. Lodging/GPS only fill a time
        // that no flight fixes (a stay with no flight in the window, or a normal non-travel day).
        var setters: [Setter] = []
        if let first = legs.first, let origin = first.origin {
            setters.append(Setter(time: .distantPast, place: origin))
        } else if cal.isDateInToday(day), let here = currentLocation, let p = place(coordinate: here) {
            setters.append(Setter(time: .distantPast, place: p))
        }
        for leg in legs { setters.append(Setter(time: leg.arrive, place: leg.destination)) }
        for m in meetings where m.time >= dayStart && m.time <= dayEnd {
            let ref = placeAt(m.time, setters: setters, lodging: lodging)?.coordinate
            if ref == nil || distanceKm(ref!, m.place.coordinate) > sameCityKm {
                setters.append(Setter(time: m.time, place: m.place))
            }
        }
        setters.sort { $0.time < $1.time }

        // Cut the day at every boundary, resolve the middle of each slice, then coalesce.
        var cuts: Set<Date> = [dayStart, dayEnd]
        for leg in legs {
            if leg.depart > dayStart && leg.depart < dayEnd { cuts.insert(leg.depart) }
            if leg.arrive > dayStart && leg.arrive < dayEnd { cuts.insert(leg.arrive) }
        }
        for s in setters where s.time > dayStart && s.time < dayEnd { cuts.insert(s.time) }
        let ordered = cuts.sorted()

        var out: [LocationSegment] = []
        for i in 0..<(ordered.count - 1) {
            let a = ordered[i], b = ordered[i + 1]
            let mid = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
            let seg: LocationSegment
            if legs.contains(where: { mid >= $0.depart && mid < $0.arrive }) {
                seg = LocationSegment(start: minute(a), end: minute(b), place: nil)   // in transit
            } else {
                seg = LocationSegment(start: minute(a), end: minute(b), place: placeAt(mid, setters: setters, lodging: lodging))
            }
            if let last = out.last, last.place == seg.place {
                out[out.count - 1] = LocationSegment(start: last.start, end: seg.end, place: last.place)
            } else {
                out.append(seg)
            }
        }
        // A single located segment covering the whole day = no travel; still valid (one place).
        return out
    }

    // MARK: - helpers

    private static func placeAt(_ t: Date, setters: [Setter],
                                lodging: [(range: ClosedRange<Date>, place: ResolvedPlace)]) -> ResolvedPlace? {
        if let s = setters.filter({ $0.time <= t }).max(by: { $0.time < $1.time }) { return s.place }
        if let stay = lodging.first(where: { $0.range.contains(t) }) { return stay.place }   // fill: stay with no flight
        return nil
    }

    private static func place(airport a: Airport) -> ResolvedPlace {
        ResolvedPlace(coordinate: a.coordinate, placeName: a.city, timeZone: a.timeZone)
    }

    /// Resolve a bare coordinate offline: keep the real coordinate for the weather fetch, borrow
    /// the nearest airport's city + IANA zone (no geocode, no network).
    private static func place(coordinate c: CLLocationCoordinate2D) -> ResolvedPlace? {
        guard let (airport, _) = AirportTable.nearest(to: c) else { return nil }
        return ResolvedPlace(coordinate: c, placeName: airport.city, timeZone: airport.timeZone)
    }

    private static func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        AirportTable.haversineKm(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    private static func minute(_ d: Date) -> Date {
        let cal = Calendar.current
        return cal.date(bySetting: .second, value: 0, of: d) ?? d
    }
}
