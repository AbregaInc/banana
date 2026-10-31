import CoreLocation
import Foundation

/// A stay somewhere, as iOS's visit service reports it: where, when you arrived, when you left.
/// Kept on the phone only.
struct VisitRecord: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var arrival: Date
    var departure: Date?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// A trip you actually made: left one place, arrived at the next, how long it took, and how.
struct ObservedTrip: Codable, Equatable {
    var from: CLLocationCoordinate2D
    var to: CLLocationCoordinate2D
    var departure: Date
    var arrival: Date
    var mode: TransitMode

    var seconds: TimeInterval { arrival.timeIntervalSince(departure) }

    enum CodingKeys: CodingKey { case fromLat, fromLon, toLat, toLon, departure, arrival, mode }

    init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, departure: Date, arrival: Date, mode: TransitMode) {
        self.from = from; self.to = to; self.departure = departure; self.arrival = arrival; self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = .init(latitude: try c.decode(Double.self, forKey: .fromLat), longitude: try c.decode(Double.self, forKey: .fromLon))
        to = .init(latitude: try c.decode(Double.self, forKey: .toLat), longitude: try c.decode(Double.self, forKey: .toLon))
        departure = try c.decode(Date.self, forKey: .departure)
        arrival = try c.decode(Date.self, forKey: .arrival)
        mode = try c.decode(TransitMode.self, forKey: .mode)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from.latitude, forKey: .fromLat); try c.encode(from.longitude, forKey: .fromLon)
        try c.encode(to.latitude, forKey: .toLat); try c.encode(to.longitude, forKey: .toLon)
        try c.encode(departure, forKey: .departure); try c.encode(arrival, forKey: .arrival)
        try c.encode(mode, forKey: .mode)
    }

    static func == (a: ObservedTrip, b: ObservedTrip) -> Bool {
        a.departure == b.departure && a.arrival == b.arrival && a.mode == b.mode
            && a.from.latitude == b.from.latitude && a.to.latitude == b.to.latitude
    }
}

/// What the trips taught, small enough to sync with the settings so the Mac times trips the
/// same way the phone does (the raw visits never leave the phone):
/// - per mode, how your real times compare with Apple Maps' estimates ("you walk 0.9×");
/// - per place, how long getting there from home usually takes, by mode.
struct LearnedTravel: Codable, Equatable {
    /// Median of observed ÷ estimated, per mode (raw values of `TransitMode`).
    var factors: [String: Double] = [:]
    var factorSamples: [String: Int] = [:]
    /// Place key (`SavedPlace.key`) → mode → recent door-to-door minutes from home, newest last.
    var placeMinutes: [String: [String: [Double]]] = [:]
    var tripsLearned = 0

    init() {}

    /// Tolerant, like the settings it rides in: anything unreadable is simply not learned yet.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        factors = (try? c.decodeIfPresent([String: Double].self, forKey: .factors)) ?? [:]
        factorSamples = (try? c.decodeIfPresent([String: Int].self, forKey: .factorSamples)) ?? [:]
        placeMinutes = (try? c.decodeIfPresent([String: [String: [Double]]].self, forKey: .placeMinutes)) ?? [:]
        tripsLearned = (try? c.decodeIfPresent(Int.self, forKey: .tripsLearned)) ?? 0
    }
}

enum TripLearning {
    /// Trips shorter than this aren't trips (moving between rooms, a GPS wobble).
    static let minimumDistance: CLLocationDistance = 200
    /// A gap longer than this between leaving and arriving is an errand chain, not one trip.
    static let maximumDuration: TimeInterval = 3 * 3_600
    /// How close a visit must be to a place to count as being there.
    static let placeRadius: CLLocationDistance = 150
    static let minimumFactorSamples = 3
    static let minimumPlaceSamples = 2
    static let keptPlaceSamples = 5

    /// Consecutive visits → trips: leave A, arrive at B, within a few hours, far enough apart.
    static func trips(from visits: [VisitRecord], modeFor: (Date, Date) -> TransitMode?) -> [ObservedTrip] {
        let ordered = visits.sorted { $0.arrival < $1.arrival }
        var trips: [ObservedTrip] = []
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            guard let left = a.departure, b.arrival > left,
                  b.arrival.timeIntervalSince(left) <= maximumDuration,
                  distance(a.coordinate, b.coordinate) >= minimumDistance,
                  let mode = modeFor(left, b.arrival) else { continue }
            trips.append(ObservedTrip(from: a.coordinate, to: b.coordinate, departure: left, arrival: b.arrival, mode: mode))
        }
        return trips
    }

    /// Adds one trip's lesson. `estimate` is what Apple Maps said for the same leg and mode;
    /// `destinationKey` is the saved place it ended at, when it left from home.
    static func learn(_ trip: ObservedTrip, estimate: TimeInterval?, destinationKey: String?,
                      into learned: inout LearnedTravel, recentRatios: inout [String: [Double]]) {
        let mode = trip.mode.rawValue
        learned.tripsLearned += 1
        if let estimate, estimate > 60 {
            let ratio = trip.seconds / estimate
            // A wildly different ratio is a trip with a stop in it, not a pace.
            if (0.5...2.0).contains(ratio) {
                var ratios = recentRatios[mode, default: []]
                ratios.append(ratio)
                ratios = Array(ratios.suffix(20))
                recentRatios[mode] = ratios
                learned.factors[mode] = median(ratios)
                learned.factorSamples[mode] = ratios.count
            }
        }
        if let destinationKey {
            var byMode = learned.placeMinutes[destinationKey, default: [:]]
            var minutes = byMode[mode, default: []]
            minutes.append((trip.seconds / 60 * 10).rounded() / 10)
            byMode[mode] = Array(minutes.suffix(keptPlaceSamples))
            learned.placeMinutes[destinationKey] = byMode
        }
    }

    /// The trip time to plan with: what you've actually taken to this place by this mode, when
    /// there's enough of it; else Apple Maps' estimate scaled by your pace for the mode; else the
    /// estimate as it is.
    static func adjusted(_ estimate: TimeInterval, mode: TransitMode, placeKey: String?,
                         learned: LearnedTravel) -> (seconds: TimeInterval, source: Source) {
        if let placeKey, let samples = learned.placeMinutes[placeKey]?[mode.rawValue],
           samples.count >= minimumPlaceSamples {
            return (median(samples) * 60, .observed(samples.count))
        }
        if let factor = learned.factors[mode.rawValue],
           (learned.factorSamples[mode.rawValue] ?? 0) >= minimumFactorSamples {
            return (estimate * factor, .paced(factor))
        }
        return (estimate, .estimate)
    }

    /// What the motion sensor says you were mostly doing between leaving and arriving.
    enum MotionKind: String { case walking, running, cycling, automotive }

    /// The mode a trip was made by, from seconds spent in each motion. On foot is a walk; in a
    /// vehicle is your default (drive or transit — the sensor can't tell a car from a train);
    /// cycling isn't a mode Banana times yet, and too little signal is no answer.
    static func mode(from seconds: [MotionKind: TimeInterval], defaultMode: TransitMode) -> TransitMode? {
        guard let (kind, time) = seconds.max(by: { $0.value < $1.value }), time >= 60 else { return nil }
        switch kind {
        case .walking, .running: return .walk
        case .automotive: return defaultMode == .walk ? .drive : defaultMode
        case .cycling: return nil
        }
    }

    /// A place's key in `LearnedTravel.placeMinutes`: its coordinate to about 10 m.
    static func placeKey(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", c.latitude, c.longitude)
    }

    /// The learned place within `placeRadius` of `coordinate`, if any — trips end a few dozen
    /// metres apart at the same door.
    static func nearestPlaceKey(to coordinate: CLLocationCoordinate2D, in learned: LearnedTravel) -> String? {
        learned.placeMinutes.keys
            .compactMap { key -> (String, CLLocationDistance)? in
                let parts = key.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { return nil }
                let d = distance(coordinate, .init(latitude: parts[0], longitude: parts[1]))
                return d <= placeRadius ? (key, d) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }

    enum Source: Equatable {
        case estimate
        case paced(Double)
        case observed(Int)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
