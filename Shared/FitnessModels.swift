import Foundation

/// One recorded data point during a session. Kept compact (short keys) because
/// high-frequency motion produces a lot of these before they sync to the phone.
struct FitnessSample: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heartRate      // v1 = bpm
        case energy         // v1 = cumulative active kcal
        case distance       // v1 = cumulative meters
        case accel          // v1,v2,v3 = x,y,z (g)
        case gyro           // v1,v2,v3 = x,y,z (rad/s)
        case location       // v1,v2 = lat,lon ; v3 = speed (m/s)
        case altitude       // v1 = metres above sea level
        case cadence        // v1 = steps/crank revolutions per minute
        case power          // v1 = watts (measured by HealthKit/sensor)
        case strideLength   // v1 = metres
        case verticalOscillation // v1 = metres
        case groundContactTime   // v1 = seconds
        case strokeCount    // v1 = cumulative strokes
        case speed          // v1 = metres per second (native workout metric)
        /// v1,v2,v3 = rotation vector (axis × angle, radians — Rodrigues form; see
        /// `RotationVector`). Captured from `CMDeviceMotion.attitude` in place of raw gyro
        /// when the gyro is unavailable or silent (`WorkoutRecorder.startOrientationFallback`).
        case orientation
        // Added when explicit `enableCollection(for:predicate:)` replaced reliance on
        // HealthKit's undocumented per-activity default type set (see `WorkoutRecorder
        // .performanceTypes`) — appended after `orientation`, never inserted, per the on-disk
        // byte contract documented on `Kind.code` below.
        case stepCount           // v1 = cumulative steps (HKQuantityTypeIdentifierStepCount)
        case physicalEffort      // v1 = kcal/(kg·hr), system-derived, no new sensor
        case effortScore         // v1 = appleEffortScore, system-ESTIMATED (not user-rated RPE)
        case perfusionIndex      // v1 = %, PPG signal-quality companion to `.heartRate`
        case underwaterDepth     // v1 = metres, pool/open-water swims only
        case waterTemperature    // v1 = degrees C, pool/open-water swims only
        /// Absolute barometric altitude (`CMAltimeter`), metres above sea level. A separate
        /// signal from `.altitude` (GPS-derived) — see `WorkoutRecorder.startSensors` for why
        /// both are kept: GPS altitude is left exactly as it was so nothing regresses.
        case barometricAltitude
        /// `HKSwimmingStrokeStyle` raw value, one sample per completed lap (from the lap event's
        /// `HKMetadataKeySwimmingStrokeStyle`, not a `didCollectDataOf` quantity callback).
        case strokeStyle
    }

    var t: TimeInterval     // seconds since session start
    var kind: Kind
    var v1: Double
    var v2: Double?
    var v3: Double?
}

/// A complete recorded workout session with its raw samples and a summary.
/// This is the "custom store" that syncs to the iPhone for later analysis.
struct FitnessSession: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var start: Date
    var end: Date?
    var activity: String

    // Live-updated summary
    var avgHeartRate: Double?
    var totalEnergy: Double?      // kcal
    var totalDistance: Double?    // meters
    var poolLengthMeters: Double? = nil
    var laps: [FitnessLap] = []
    var outdoorConditions: OutdoorConditions? = nil
    /// The stretches it was paused for (`WorkoutPauses`).
    var pauses: [FitnessPause] = []

    var samples: [FitnessSample]

    var duration: TimeInterval {
        (end ?? Date()) .timeIntervalSince(start)
    }
}

/// A single GPS point (kept tiny; a downsampled route lives in the summary).
struct RoutePoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
}

extension Array where Element == RoutePoint {
    /// How far a track may wander and still be one place: a gym, a studio, a session with a
    /// trainer. GPS indoors jitters by tens of metres; a trace of that is noise, not a route.
    static let placeRadiusMeters = 100.0

    /// The middle of the track.
    var center: RoutePoint? {
        guard !isEmpty else { return nil }
        return RoutePoint(lat: map(\.lat).reduce(0, +) / Double(count), lon: map(\.lon).reduce(0, +) / Double(count))
    }

    /// Every point within `placeRadiusMeters` of the middle: shown as a place (a dot), not a line.
    var isOnePlace: Bool {
        guard count > 1, let center else { return false }
        let metersPerDegree = 111_320.0
        let lonScale = cos(center.lat * .pi / 180)
        return allSatisfy { point in
            let dy = (point.lat - center.lat) * metersPerDegree
            let dx = (point.lon - center.lon) * metersPerDegree * lonScale
            return (dx * dx + dy * dy).squareRoot() <= Self.placeRadiusMeters
        }
    }
}

extension FitnessSessionSummary {
    /// Its GPS never left one place (a gym, a studio): speed, moving time and climb worked out
    /// from that track are jitter, not facts, and aren't shown.
    var stayedInOnePlace: Bool { route.isOnePlace }
}

/// One heart-rate reading at a time offset, downsampled into the summary so a device without the
/// raw sample file (the Mac) can still draw the HR graph. Same idea as the route track.
struct HRPoint: Codable, Hashable, Sendable {
    var t: TimeInterval   // seconds since session start
    var bpm: Double
}

struct SpeedPoint: Codable, Hashable, Sendable {
    var t: TimeInterval
    var metersPerSecond: Double
}

/// A compact time/value series for measured workout metrics. Values are deliberately raw SI
/// units; each surface formats them for the athlete's chosen units without losing precision.
struct WorkoutMetricPoint: Codable, Hashable, Sendable {
    var t: TimeInterval
    var value: Double
}

/// Derived only from recorded measurements — no estimated power, cadence, or elevation is ever
/// shown as though a sensor supplied it. This compact roll-up makes a workout comparable across
/// devices while the full stream remains available for deeper analysis.
struct WorkoutInsights: Codable, Hashable, Sendable {
    var movingDuration: TimeInterval?
    var averageSpeed: Double?
    var maxSpeed: Double?
    var averageCadence: Double?
    var averagePower: Double?
    var elevationGain: Double?
    var elevationLoss: Double?
}

struct DistanceSplit: Codable, Hashable, Identifiable, Sendable {
    var number: Int
    var distanceMeters: Double
    var duration: TimeInterval
    var id: Int { number }
}

struct DistancePoint: Codable, Hashable, Sendable {
    var t: TimeInterval
    var meters: Double
}

/// Weather captured with an outdoor workout. It is stored with the workout so a later forecast
/// refresh cannot rewrite history.
struct OutdoorConditions: Codable, Hashable, Sendable {
    var temperatureF: Double
    var humidity: Double
    var condition: String
}

/// A completed pool length. It is part of the compact synced summary so the phone and Mac can
/// show the same exact lap table without needing the Watch's raw sample file.
struct FitnessLap: Codable, Hashable, Identifiable, Sendable {
    var number: Int
    var duration: TimeInterval
    var id: Int { number }
}

/// Lightweight per-session metadata kept in memory for the Fitness list. The heavy
/// `samples` array lives in a separate binary file, loaded only when a session is opened.
struct FitnessSessionSummary: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var start: Date = .distantPast
    var end: Date?
    var activity: String = "Workout"
    var avgHeartRate: Double?
    var totalEnergy: Double?
    var totalDistance: Double?
    var sampleCount: Int = 0
    var signalCounts: [String: Int] = [:]   // kind.rawValue -> count (for the detail view)
    var route: [RoutePoint] = []            // downsampled GPS for the row trace
    var heartRateSeries: [HRPoint] = []     // downsampled HR, so the Mac can chart it without raw samples
    var speedSeries: [SpeedPoint] = []      // GPS speed for outdoor activities
    var elevationSeries: [WorkoutMetricPoint] = []
    var cadenceSeries: [WorkoutMetricPoint] = []
    var powerSeries: [WorkoutMetricPoint] = []
    var strideLengthSeries: [WorkoutMetricPoint] = []
    var verticalOscillationSeries: [WorkoutMetricPoint] = []
    var groundContactSeries: [WorkoutMetricPoint] = []
    var strokeSeries: [WorkoutMetricPoint] = []
    /// Running cadence (steps/min), computed from measured speed × stride length — see
    /// `derivedCadenceSeries(from:)`. Deliberately its own field, not folded into `cadenceSeries`
    /// (the genuinely sensor-reported cycling cadence): see that property's `Kind` doc comment
    /// and the `WorkoutInsights` doc comment on never showing a computed number as though a
    /// sensor supplied it.
    var derivedCadenceSeries: [WorkoutMetricPoint] = []
    var insights: WorkoutInsights?
    /// Standard 1 km checkpoints reconstructed from the recorded cumulative distance stream.
    /// Unlike display units, these are immutable workout facts and can be formatted as mi or km.
    var distanceSplits: [DistanceSplit] = []
    var distanceSeries: [DistancePoint] = []
    /// Present for pool swims. Persisted at workout time, rather than inferred from the current
    /// preference, because a later pool-setting change must not rewrite history.
    var poolLengthMeters: Double?
    var laps: [FitnessLap] = []
    var outdoorConditions: OutdoorConditions?
    /// Set while this workout stands edited (trimmed, or its pool length corrected) and the
    /// original can be brought back. It travels with the summary, so every device offers Revert.
    var edit: SessionEdit?
    /// The stretches it was paused for (`WorkoutPauses`).
    var pauses: [FitnessPause] = []

    /// Start to end, by the clock: what the charts and the trim handles span.
    var duration: TimeInterval { (end ?? start).timeIntervalSince(start) }
    /// The workout's time as it's shown, and what pace is worked out over: pauses left out.
    var activeDuration: TimeInterval { max(0, duration - WorkoutPauses.pausedSeconds(pauses)) }

    init(session: FitnessSession) {
        id = session.id; start = session.start; end = session.end; activity = session.activity
        avgHeartRate = session.avgHeartRate; totalEnergy = session.totalEnergy; totalDistance = session.totalDistance
        sampleCount = session.samples.count
        var counts: [String: Int] = [:]
        var locs: [RoutePoint] = []
        var heartRates: [HRPoint] = []
        for sample in session.samples {
            counts[sample.kind.rawValue, default: 0] += 1
            if sample.kind == .location {
                if let lon = sample.v2 { locs.append(RoutePoint(lat: sample.v1, lon: lon)) }
            } else if sample.kind == .heartRate {
                heartRates.append(HRPoint(t: sample.t, bpm: sample.v1))
            }
        }
        signalCounts = counts

        // Downsample the GPS track to ~40 points for the row trace.
        let step = max(1, locs.count / 40)
        route = locs.enumerated().compactMap { i, point in i % step == 0 ? point : nil }

        // Downsample HR to ~120 points — enough for a smooth graph, a few KB to sync.
        let hrStep = max(1, heartRates.count / 120)
        heartRateSeries = heartRates.enumerated().compactMap { i, point in i % hrStep == 0 ? point : nil }
        speedSeries = Self.speedSeries(from: session.samples)
        elevationSeries = Self.metricSeries(from: session.samples, kind: .altitude)
        cadenceSeries = Self.metricSeries(from: session.samples, kind: .cadence)
        powerSeries = Self.metricSeries(from: session.samples, kind: .power)
        strideLengthSeries = Self.metricSeries(from: session.samples, kind: .strideLength)
        verticalOscillationSeries = Self.metricSeries(from: session.samples, kind: .verticalOscillation)
        groundContactSeries = Self.metricSeries(from: session.samples, kind: .groundContactTime)
        strokeSeries = Self.metricSeries(from: session.samples, kind: .strokeCount)
        derivedCadenceSeries = Self.derivedCadenceSeries(from: session.samples)
        insights = Self.insights(speed: speedSeries, cadence: cadenceSeries, power: powerSeries,
                                 elevation: elevationSeries)
        distanceSplits = Self.distanceSplits(from: session.samples)
        distanceSeries = Self.distanceSeries(from: session.samples)
        poolLengthMeters = session.poolLengthMeters
        laps = session.laps
        outdoorConditions = session.outdoorConditions
        pauses = session.pauses
    }

    /// Prefer Core Location's instantaneous speed. For pre-existing recordings where that was
    /// not persisted, calculate speed between adjacent GPS fixes so historic outdoor workouts
    /// receive the same chart when their summaries are upgraded.
    static func speedSeries(from samples: [FitnessSample]) -> [SpeedPoint] {
        let native = samples.compactMap { $0.kind == .speed && $0.v1 >= 0 ? SpeedPoint(t: $0.t, metersPerSecond: $0.v1) : nil }
        if native.count > 1 {
            let step = max(1, native.count / 120)
            return native.enumerated().compactMap { index, point in index % step == 0 ? point : nil }
        }
        let locations = samples.filter { $0.kind == .location && $0.v2 != nil }
        guard locations.count > 1 else { return [] }

        var speeds: [SpeedPoint] = []
        for (index, sample) in locations.enumerated() {
            if let speed = sample.v3, speed >= 0 {
                speeds.append(SpeedPoint(t: sample.t, metersPerSecond: speed))
            } else if index > 0 {
                let previous = locations[index - 1]
                guard let previousLon = previous.v2, let lon = sample.v2 else { continue }
                let elapsed = sample.t - previous.t
                guard elapsed > 0 else { continue }
                let distance = haversineMeters(lat1: previous.v1, lon1: previousLon,
                                               lat2: sample.v1, lon2: lon)
                speeds.append(SpeedPoint(t: sample.t, metersPerSecond: distance / elapsed))
            }
        }
        let step = max(1, speeds.count / 120)
        return speeds.enumerated().compactMap { index, point in index % step == 0 ? point : nil }
    }

    static func metricSeries(from samples: [FitnessSample], kind: FitnessSample.Kind) -> [WorkoutMetricPoint] {
        let values = samples.compactMap { $0.kind == kind && $0.v1.isFinite ? WorkoutMetricPoint(t: $0.t, value: $0.v1) : nil }
        let step = max(1, values.count / 120)
        return values.enumerated().compactMap { index, point in index % step == 0 ? point : nil }
    }

    /// Running cadence isn't a HealthKit quantity at all — the only cadence identifier HealthKit
    /// defines is `HKQuantityTypeIdentifierCyclingCadence` (cycling-only; confirmed by grepping
    /// `HKTypeIdentifiers.h`, no running-cadence identifier exists). So it's derived once here,
    /// from two independently-timed measured streams already recorded for a run:
    /// steps/min = (speed in m/s × 60) ÷ stride length in metres.
    ///
    /// `.speed` and `.strideLength` samples arrive from separate HealthKit callbacks at their own
    /// rates and offsets, never paired. Each stride-length sample is matched against the most
    /// recently known speed at or before its timestamp (forward-fill) — a stride-length sample
    /// with no speed sample at or before it yet (nothing to hold) is skipped, not zero-filled.
    /// A zero (or non-finite) stride length is skipped outright: dividing by it would produce
    /// `.infinity`, and a fabricated cadence value from a bad denominator is worse than a gap.
    ///
    /// Full resolution (not downsampled) — `derivedCadenceSeries` below thins this to ~120 points
    /// for the chart; `WorkoutMotionAnalysis.stepRateAnchorHz` needs the un-thinned series so a
    /// 10 s analysis window can match against a nearby sample instead of one smeared across the
    /// ~38 s a 120-point-over-an-hour downsample would otherwise space them at.
    static func matchedStepRatePoints(from samples: [FitnessSample]) -> [WorkoutMetricPoint] {
        let strides = samples
            .filter { $0.kind == .strideLength && $0.v1.isFinite }
            .sorted { $0.t < $1.t }
        guard !strides.isEmpty else { return [] }
        let speeds = samples
            .filter { $0.kind == .speed && $0.v1.isFinite && $0.v1 >= 0 }
            .sorted { $0.t < $1.t }
        guard !speeds.isEmpty else { return [] }

        var points: [WorkoutMetricPoint] = []
        points.reserveCapacity(strides.count)
        var speedIndex = 0
        for stride in strides {
            while speedIndex + 1 < speeds.count, speeds[speedIndex + 1].t <= stride.t {
                speedIndex += 1
            }
            guard speeds[speedIndex].t <= stride.t, stride.v1 > 0 else { continue }
            let cadence = speeds[speedIndex].v1 * 60 / stride.v1
            guard cadence.isFinite else { continue }
            points.append(WorkoutMetricPoint(t: stride.t, value: cadence))
        }
        return points
    }

    static func derivedCadenceSeries(from samples: [FitnessSample]) -> [WorkoutMetricPoint] {
        let points = matchedStepRatePoints(from: samples)
        let step = max(1, points.count / 120)
        return points.enumerated().compactMap { index, point in index % step == 0 ? point : nil }
    }

    static func insights(speed: [SpeedPoint], cadence: [WorkoutMetricPoint], power: [WorkoutMetricPoint],
                         elevation: [WorkoutMetricPoint]) -> WorkoutInsights? {
        func average(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        let speeds = speed.map(\.metersPerSecond).filter { $0.isFinite && $0 >= 0 }
        var moving: TimeInterval = 0
        for pair in zip(speed, speed.dropFirst()) {
            if (pair.0.metersPerSecond + pair.1.metersPerSecond) / 2 >= 0.5 {
                moving += max(0, pair.1.t - pair.0.t)
            }
        }
        // Ignore sub-1.5 m GPS/barometer jitter rather than converting it into fictitious climb.
        var gain = 0.0, loss = 0.0
        for pair in zip(elevation, elevation.dropFirst()) {
            let delta = pair.1.value - pair.0.value
            if delta >= 1.5 { gain += delta }
            else if delta <= -1.5 { loss -= delta }
        }
        let result = WorkoutInsights(
            movingDuration: moving > 0 ? moving : nil,
            averageSpeed: average(speeds), maxSpeed: speeds.max(),
            averageCadence: average(cadence.map(\.value).filter { $0 > 0 }),
            averagePower: average(power.map(\.value).filter { $0 > 0 }),
            elevationGain: gain > 0 ? gain : nil, elevationLoss: loss > 0 ? loss : nil)
        return result.movingDuration != nil || result.averageSpeed != nil || result.averageCadence != nil
            || result.averagePower != nil || result.elevationGain != nil ? result : nil
    }

    static func distanceSplits(from samples: [FitnessSample], interval: Double = 1_000) -> [DistanceSplit] {
        distanceSplits(from: samples.filter { $0.kind == .distance && $0.v1.isFinite }
            .map { DistancePoint(t: $0.t, meters: $0.v1) }, interval: interval)
    }

    static func distanceSeries(from samples: [FitnessSample]) -> [DistancePoint] {
        let points = samples.compactMap { $0.kind == .distance && $0.v1.isFinite ? DistancePoint(t: $0.t, meters: $0.v1) : nil }
        let step = max(1, points.count / 240)
        return points.enumerated().compactMap { index, point in index % step == 0 ? point : nil }
    }

    func distanceSplits(interval: Double) -> [DistanceSplit] {
        Self.distanceSplits(from: distanceSeries, interval: interval)
    }

    static func distanceSplits(from distance: [DistancePoint], interval: Double) -> [DistanceSplit] {
        guard distance.count > 1, interval > 0 else { return [] }
        var result: [DistanceSplit] = []
        var prior = distance[0]
        var next = interval
        var lastCrossing: TimeInterval = 0
        for current in distance.dropFirst() {
            guard current.meters >= prior.meters else { prior = current; continue }
            while current.meters >= next {
                let delta = current.meters - prior.meters
                let fraction = delta > 0 ? (next - prior.meters) / delta : 1
                let crossing = prior.t + (current.t - prior.t) * min(1, max(0, fraction))
                result.append(DistanceSplit(number: result.count + 1, distanceMeters: next,
                                            duration: max(0, crossing - lastCrossing)))
                lastCrossing = crossing
                next += interval
            }
            prior = current
        }
        return result
    }

    private static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Tolerant decoder (keeps saved index valid if fields are added later) — this store gained
    /// several fields in a single session (new sample kinds, `speedSeries`,
    /// `derivedCadenceSeries`, and more), and Swift's synthesized `Decodable` throws `keyNotFound`
    /// for an absent key even when the stored property declares a default, so any one of those
    /// additions would otherwise have made every summary saved before it existed fail to decode.
    ///
    /// `id`/`start` are the two fields kept required rather than defaulted — the same "point of
    /// the record" reasoning `MealEntry.items`/`WorkoutCompletion.startedAt`/`.endedAt` use
    /// elsewhere, but sharper here: defaulting either wouldn't just drop descriptive metadata, it
    /// would fabricate false history. A fabricated fresh `id` would silently orphan this session's
    /// real `<id>.samples` file — looked up by id, see `FitnessStore`'s doc comment on the
    /// index/samples split — forever, since nothing would reference that file's true id again. A
    /// fabricated `.distantPast` `start` would misplace a real recorded workout at the dawn of
    /// time in every chronological list and chart. Both stay required so a summary that can't
    /// produce them is dropped by the enclosing `LossyArray<FitnessSessionSummary>`
    /// (`FitnessIndexSnapshot`, below) instead of being kept with invented identity or history.
    /// Every other field here is genuinely descriptive-once-`id`/`start` are known, so it keeps
    /// its existing default.
    ///
    /// Every downsampled point series (`route`, `heartRateSeries`, `speedSeries`, …) decodes via
    /// `LossyArray` rather than a plain `[Element]`: `RoutePoint`/`HRPoint`/etc. have no
    /// defaultable fields of their own (a route point with no `lon` isn't a recoverable point), so
    /// a synthesized array decode fails ENTIRELY the moment one element is malformed — and without
    /// `LossyArray` here that failure propagates out of this whole `init(from:)`, costing an
    /// entire workout, and its multi-megabyte `.samples` companion file's only index, over one bad
    /// point. `insights`/`outdoorConditions` use `FailableDecodable` for the same reason at
    /// single-value granularity: plain `decodeIfPresent` only tolerates an ABSENT key, not a
    /// malformed VALUE at a key that IS present.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? "Workout"
        avgHeartRate = try c.decodeIfPresent(Double.self, forKey: .avgHeartRate)
        totalEnergy = try c.decodeIfPresent(Double.self, forKey: .totalEnergy)
        totalDistance = try c.decodeIfPresent(Double.self, forKey: .totalDistance)
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        signalCounts = try c.decodeIfPresent(LossyDictionary<Int>.self, forKey: .signalCounts)?.elements ?? [:]

        func points<T: Decodable & Sendable>(_ key: CodingKeys) throws -> [T] {
            try c.decodeIfPresent(LossyArray<T>.self, forKey: key)?.elements ?? []
        }
        route = try points(.route)
        heartRateSeries = try points(.heartRateSeries)
        speedSeries = try points(.speedSeries)
        elevationSeries = try points(.elevationSeries)
        cadenceSeries = try points(.cadenceSeries)
        powerSeries = try points(.powerSeries)
        strideLengthSeries = try points(.strideLengthSeries)
        verticalOscillationSeries = try points(.verticalOscillationSeries)
        groundContactSeries = try points(.groundContactSeries)
        strokeSeries = try points(.strokeSeries)
        derivedCadenceSeries = try points(.derivedCadenceSeries)
        insights = try c.decodeIfPresent(FailableDecodable<WorkoutInsights>.self, forKey: .insights)?.value
        distanceSplits = try points(.distanceSplits)
        distanceSeries = try points(.distanceSeries)
        poolLengthMeters = try c.decodeIfPresent(Double.self, forKey: .poolLengthMeters)
        laps = try points(.laps)
        outdoorConditions = try c.decodeIfPresent(FailableDecodable<OutdoorConditions>.self, forKey: .outdoorConditions)?.value
        edit = try c.decodeIfPresent(FailableDecodable<SessionEdit>.self, forKey: .edit)?.value
        pauses = try points(.pauses)
    }
}

/// A workout that stands edited: what its original looked like, and when the edit was made.
/// The first lets a device tell whether the recording it holds is that original (so it can keep
/// it, and revert by itself); the second names the edit, for a Revert asked for on another device.
struct SessionEdit: Codable, Hashable, Sendable {
    var originalStart: Date
    var originalEnd: Date?
    var originalSampleCount: Int
    var originalPoolLength: Double?
    var editedAt: Date

    init(original: FitnessSessionSummary, at now: Date) {
        originalStart = original.start
        originalEnd = original.end
        originalSampleCount = original.sampleCount
        originalPoolLength = original.poolLengthMeters
        editedAt = now
    }

    /// Whether `summary` is the original this edit was made from.
    func describes(_ summary: FitnessSessionSummary) -> Bool {
        abs(summary.start.timeIntervalSince(originalStart)) < 1
            && abs((summary.end ?? summary.start).timeIntervalSince(originalEnd ?? originalStart)) < 1
            && summary.sampleCount == originalSampleCount
            && summary.poolLengthMeters == originalPoolLength
    }
}

// MARK: - Plausibility guard (closes the hole a syntactically valid but corrupt `start` leaves)
//
// `start`'s tolerant-decoder doc comment above already explains why a MISSING `start` is refused
// (required, not defaulted) rather than silently becoming `.distantPast`. This guard is for the
// harder case: a `start` that IS present and decodes without error, but whose value is
// `.distantPast` (or something equally implausible) anyway — e.g. a `FitnessSessionSummary`
// literal built with no explicit `start` (this struct's own default), then encoded and handed to
// this app by something other than a normal `install(_:)`/`ingest`. `id`/`start`-required decode
// cannot catch this: the JSON is perfectly well-formed. Only a plausibility check on the decoded
// VALUE can. See `CloudFitnessRecordRouting`'s doc comment for the concrete bug (a misrouted
// CloudKit record) that this guard exists to close, and `CloudFitnessSync.apply`/
// `FitnessIndexSnapshot.init(from:)` below for the two places it is actually enforced — every path
// a workout can reach this app's index through, cloud and local disk alike.
extension FitnessSessionSummary {
    /// The earliest `start` a genuine workout recording can plausibly carry.
    ///
    /// Anchored to HealthKit's own existence rather than to this app's: every real source this
    /// app ever adopts a workout from — live capture on the Watch/phone, or `FitnessStore`'s
    /// launch-time HealthKit backfill sweep — ultimately reads through HealthKit, which shipped
    /// with iOS 8 in September 2014. No genuine `HKWorkout` can predate that, no matter how old
    /// the recording a backfill later imports. This floor sits a few years earlier still, for
    /// margin, and is otherwise arbitrary — the goal is not to model exactly where "real" begins,
    /// only to sit far below every real workout's `start` (earliest on this account: 7 Jul 2026)
    /// and far above every implausible one, chiefly `Date.distantPast` (year 1 on the Gregorian
    /// calendar) — the value a corrupt or misrouted payload decodes `start` to when it falls back
    /// to this struct's own default instead of carrying a real recording.
    ///
    /// A floor is used instead of comparing against the exact sentinel (`start == .distantPast`)
    /// on purpose: it also catches any other implausible value a future bug might produce
    /// (`Date(timeIntervalSince1970: 0)`, a zeroed struct, a mis-decoded field, …) without needing
    /// to know its exact shape in advance — "simpler and safer than detecting the exact sentinel."
    static let earliestPlausibleStart = Date(timeIntervalSince1970: 1_262_304_000)   // 2010-01-01 UTC

    /// Whether `start` is late enough to be a real recording rather than a corrupt/sentinel
    /// payload. Deliberately `start`-only — NOT also gated on `sampleCount`/empty series, even
    /// though every phantom record observed in this bug's blast radius happened to have
    /// `sampleCount == 0`: a real workout logged without HealthKit sample access (a manual Health
    /// app entry, or an import from a third-party app that reports only summary totals) can be
    /// genuine and still carry zero raw samples. That correlation held for the corruption this
    /// guard was written for, but it is not a safe REJECTION rule on its own — rejecting on
    /// `start` alone is the one check that has zero false-positive risk against real data.
    var hasPlausibleStart: Bool { start >= Self.earliestPlausibleStart }
}

// MARK: - Index snapshot persistence (decode-and-quarantine)
//
// `FitnessStore` decoded `summaries.json` via a single
// `try? JSONDecoder().decode([FitnessSessionSummary].self, ...) ?? []` — the exact anti-pattern
// `Shared/SnapshotPersistence.swift` documents: ONE summary that failed to decode (a corrupt byte,
// or simply a field added without the tolerant decoder above) failed the WHOLE array decode,
// `try?` swallowed it to nil, and the store started completely empty. The very next `saveIndex()`
// — any workout ingested from the Watch, any trim — would then have written that emptiness
// permanently over `summaries.json`, discarding years of recorded history. Of every store in this
// sweep this one is the highest-value and the most asymmetric: a dropped summary also leaves its
// multi-megabyte `<id>.samples` companion file orphaned on disk (see `FitnessStore`'s doc comment
// on the index/samples split).
//
// Kept free of `FitnessStore`'s CloudKit/AppSupport/singleton dependency chain — Foundation only —
// so it's directly testable against throwaway temp files (and, read-only, against the real
// `summaries.json`), the same reasoning `WellnessSnapshot`/`WellnessSnapshotLoader`
// (`Shared/WellnessModels.swift`) were split out for.

/// The on-disk shape of `summaries.json`: a bare JSON array (unlike the keyed-object snapshots the
/// other stores use), so this wraps `LossyArray<FitnessSessionSummary>` directly against the
/// decoder itself rather than pulling values out of a keyed container.
struct FitnessIndexSnapshot: Sendable {
    var summaries: [FitnessSessionSummary] = []
    /// How many summaries failed to decode and were dropped — diagnostic only. This type is never
    /// encoded (`FitnessStore.saveIndex` writes `[FitnessSessionSummary]` directly), so there's no
    /// risk of this leaking onto disk.
    var droppedCount = 0
    /// Summaries that decoded fine but were dropped by the plausibility guard
    /// (`FitnessSessionSummary.hasPlausibleStart`) because `start` isn't a real recording — the
    /// local-disk half of the same guard `CloudFitnessSync.apply` enforces on the cloud-adopt
    /// side. Kept separate from `droppedCount` (a genuine decode failure) rather than folded in:
    /// the two have different causes and a caller may want to log them differently. The ids alone
    /// (not the full summaries) are enough for a caller's log line, and cost nothing extra to
    /// keep since `summaries.rejected` would otherwise need re-deriving from `summaries` after
    /// the fact.
    var rejectedImplausibleIDs: [UUID] = []
}

extension FitnessIndexSnapshot: Decodable {
    init(from decoder: Decoder) throws {
        let lossy = try LossyArray<FitnessSessionSummary>(from: decoder)
        droppedCount = lossy.droppedCount
        var plausible: [FitnessSessionSummary] = []
        plausible.reserveCapacity(lossy.elements.count)
        for summary in lossy.elements {
            if summary.hasPlausibleStart {
                plausible.append(summary)
            } else {
                rejectedImplausibleIDs.append(summary.id)
            }
        }
        summaries = plausible
    }
}

/// Outcome of attempting to load a `summaries.json`-shaped file. A type-specific alias over the
/// generic `SnapshotLoadResult` (`Shared/SnapshotPersistence.swift`).
typealias FitnessIndexLoadResult = SnapshotLoadResult<FitnessIndexSnapshot>

/// Reads and decodes a `summaries.json`-shaped file without ever risking the original — see
/// `SnapshotLoader` for the mechanics (decode-or-quarantine, never mutating `url` itself).
enum FitnessIndexLoader {
    static func load(from url: URL, now: Date = Date()) -> FitnessIndexLoadResult {
        SnapshotLoader.load(from: url, as: FitnessIndexSnapshot.self, now: now)
    }
}

// MARK: - Compact binary coding for samples (≈33 bytes/sample vs ~80 for JSON)

extension FitnessSample.Kind {
    // New kinds are always APPENDED here, never inserted — this code is the on-disk byte, and
    // an older build decoding a code it doesn't recognise skips that one record rather than
    // failing (see `decodeBinary`'s `guard let kind = Kind(code:)`), so renumbering an existing
    // case would silently reinterpret old recordings as the wrong signal instead.
    var code: UInt8 {
        switch self {
        case .heartRate: return 0; case .energy: return 1; case .distance: return 2
        case .accel: return 3; case .gyro: return 4; case .location: return 5
        case .altitude: return 6; case .cadence: return 7; case .power: return 8
        case .strideLength: return 9; case .verticalOscillation: return 10
        case .groundContactTime: return 11; case .strokeCount: return 12
        case .speed: return 13; case .orientation: return 14
        case .stepCount: return 15; case .physicalEffort: return 16
        case .effortScore: return 17; case .perfusionIndex: return 18
        case .underwaterDepth: return 19; case .waterTemperature: return 20
        case .barometricAltitude: return 21; case .strokeStyle: return 22
        }
    }
    init?(code: UInt8) {
        switch code {
        case 0: self = .heartRate; case 1: self = .energy; case 2: self = .distance
        case 3: self = .accel; case 4: self = .gyro; case 5: self = .location
        case 6: self = .altitude; case 7: self = .cadence; case 8: self = .power
        case 9: self = .strideLength; case 10: self = .verticalOscillation
        case 11: self = .groundContactTime; case 12: self = .strokeCount
        case 13: self = .speed; case 14: self = .orientation
        case 15: self = .stepCount; case 16: self = .physicalEffort
        case 17: self = .effortScore; case 18: self = .perfusionIndex
        case 19: self = .underwaterDepth; case 20: self = .waterTemperature
        case 21: self = .barometricAltitude; case 22: self = .strokeStyle
        default: return nil
        }
    }
}

extension FitnessSample {
    static let recordSize = 33   // 1 (kind) + 4×8 (t, v1, v2, v3 as Double bit patterns)

    static func encodeBinary(_ samples: [FitnessSample]) -> Data {
        var data = Data(capacity: samples.count * recordSize)
        for sample in samples { appendBinary(sample, to: &data) }
        return data
    }

    /// Append one compact record into an existing buffer. The Watch's sensor hot path uses this
    /// directly; wrapping every 33-byte sample in a temporary one-element Array + Data at 50 Hz
    /// created thousands of short-lived allocations per workout minute.
    static func appendBinary(_ sample: FitnessSample, to data: inout Data) {
        data.append(sample.kind.code)
        appendBits(&data, sample.t)
        appendBits(&data, sample.v1)
        appendBits(&data, sample.v2 ?? .nan)   // NaN = "absent"
        appendBits(&data, sample.v3 ?? .nan)
    }

    /// - Parameter kinds: when non-nil, records whose `kind` isn't in this set are skipped before
    ///   any of the per-field decode work — lets a caller that only needs a couple of kinds (e.g.
    ///   heart rate + location for a chart) avoid allocating/retaining the full 25Hz accel+gyro
    ///   stream, which can be tens of MB for a long workout. `nil` decodes everything, unchanged.
    static func decodeBinary(_ data: Data, kinds: Set<Kind>? = nil) -> [FitnessSample] {
        let count = data.count / recordSize
        var out: [FitnessSample] = []
        out.reserveCapacity(kinds == nil ? count : 0)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for r in 0..<count {
                let base = r * recordSize
                guard let kind = Kind(code: raw.load(fromByteOffset: base, as: UInt8.self)) else { continue }
                if let kinds, !kinds.contains(kind) { continue }
                let t = Double(bitPattern: raw.loadUnaligned(fromByteOffset: base + 1, as: UInt64.self))
                let v1 = Double(bitPattern: raw.loadUnaligned(fromByteOffset: base + 9, as: UInt64.self))
                let v2 = Double(bitPattern: raw.loadUnaligned(fromByteOffset: base + 17, as: UInt64.self))
                let v3 = Double(bitPattern: raw.loadUnaligned(fromByteOffset: base + 25, as: UInt64.self))
                out.append(FitnessSample(t: t, kind: kind, v1: v1,
                                         v2: v2.isNaN ? nil : v2, v3: v3.isNaN ? nil : v3))
            }
        }
        return out
    }

    private static func appendBits(_ data: inout Data, _ value: Double) {
        var bits = value.bitPattern
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}

// MARK: - Fast Float-array packing (shared by any `Codable` type with a large `[Float]` payload)

/// A plain synthesized `Codable [Float]` calls its `Encoder`/`Decoder` once per element — measured
/// at roughly 2 µs/element on real motion-analysis data (`WorkoutMotionAnalysis.Cycle.phaseX/Y/Z`,
/// `SpectrogramFrame.bins`, `WorkoutHandPath.Lap.points`): a real swim's ~530,000 combined floats
/// took ~920 ms to encode+decode as plain JSON arrays, close to as slow as `WorkoutMotionCache`'s
/// own from-scratch re-derivation — which would defeat the entire point of
/// `WorkoutMotionDiskCache`. Packing the same floats as one raw `Data` blob per array turns that
/// into a single bulk memory copy, encoded by `JSONEncoder`/`JSONDecoder` as one base64 string
/// (Foundation's `Data` has its own efficient `Codable` conformance) instead of thousands of
/// individual container calls. Used by any type that hand-writes its own `Codable` to route a big
/// `[Float]` field through `Data` instead of the type's default array coding.
extension Array where Element == Float {
    var packedData: Data {
        withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// `nil` only when `data`'s length isn't a whole number of `Float`s — never expected from a
    /// blob this same type wrote, but a corrupt/truncated cache file must not crash the reader.
    init?(packedData data: Data) {
        guard data.count % MemoryLayout<Float>.stride == 0 else { return nil }
        let n = data.count / MemoryLayout<Float>.stride
        self = [Float](unsafeUninitializedCapacity: n) { buffer, initializedCount in
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress, n > 0 {
                    memcpy(buffer.baseAddress!, base, n * MemoryLayout<Float>.stride)
                }
            }
            initializedCount = n
        }
    }
}

// MARK: - Tolerant decoders
// Custom `init(from:)` in extensions (so the memberwise init is preserved):
// missing keys fall back to defaults, so adding a field later won't fail-and-drop
// data saved by an earlier version. `FitnessSample` being lenient also lets a
// `FitnessSession` decode succeed even if individual samples gain fields.

extension FitnessSample {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decodeIfPresent(TimeInterval.self, forKey: .t) ?? 0
        kind = try c.decode(Kind.self, forKey: .kind)
        v1 = try c.decodeIfPresent(Double.self, forKey: .v1) ?? 0
        v2 = try c.decodeIfPresent(Double.self, forKey: .v2)
        v3 = try c.decodeIfPresent(Double.self, forKey: .v3)
    }
}

extension FitnessSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decodeIfPresent(Date.self, forKey: .start) ?? Date(timeIntervalSince1970: 0)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? "Workout"
        avgHeartRate = try c.decodeIfPresent(Double.self, forKey: .avgHeartRate)
        totalEnergy = try c.decodeIfPresent(Double.self, forKey: .totalEnergy)
        totalDistance = try c.decodeIfPresent(Double.self, forKey: .totalDistance)
        samples = try c.decodeIfPresent([FitnessSample].self, forKey: .samples) ?? []
    }
}

// MARK: - CloudKit record routing (fitness zone)

/// What a "Fitness" zone CloudKit record name resolves to. `Banana/Model/CloudProgressSync.swift`
/// (`CloudFitnessSync`) is the only writer/reader of this zone; every one of its three record
/// name-driven code paths — apply a fetched record, apply a deletion, and the LWW resend when a
/// local edit is newer than the server's copy — routes through `CloudFitnessRecordRouting
/// .classify(_:healthRecordName:)` below instead of repeating its own `hasPrefix`/parse chain,
/// so the routing decision has exactly one implementation to get right.
enum CloudFitnessRecordKind: Equatable {
    case health
    case note(UUID)
    case workout(UUID)
    /// Anything that isn't the health snapshot and doesn't parse as a `note-<uuid>` or
    /// `workout-<uuid>` name. Every caller must handle this case explicitly (no default arm on
    /// the classifying switch) and log it — see the doc comment on `classify` for why.
    case unrecognised
}

/// Pure, CloudKit-free classification of a fitness-zone record name — kept in `Shared/`, deriving
/// no CloudKit/CKSyncEngine dependency, for the same reason `FitnessSessionSummary`'s tolerant
/// decoder lives here rather than in `CloudProgressSync.swift`: it is directly unit-testable
/// without constructing a `CKSyncEngine`/`CKContainer`, which `CloudFitnessSync`'s own doc comment
/// warns can terminate the process outside a signed-in run.
///
/// This is the fix for the bug that let CloudKit corrupt the local fitness index: the note branch
/// used to guard on `hasPrefix("note-")`, but the workout branch was a bare `else` with no
/// `hasPrefix("workout-")` guard of its own, so ANY record name this app didn't otherwise
/// recognise fell through and was attempted as a workout decode. When that attempt happened to
/// decode successfully it was silently adopted as a phantom workout; when it failed, it vanished
/// with no trace. Both failure modes are gone now that `.unrecognised` is its own case every
/// caller must handle (and log) rather than a fallthrough nobody wrote on purpose.
enum CloudFitnessRecordRouting {
    static let notePrefix = "note-"
    static let workoutPrefix = "workout-"

    static func classify(_ recordName: String, healthRecordName: String) -> CloudFitnessRecordKind {
        if recordName == healthRecordName { return .health }
        if recordName.hasPrefix(notePrefix),
           let id = UUID(uuidString: String(recordName.dropFirst(notePrefix.count))) {
            return .note(id)
        }
        if recordName.hasPrefix(workoutPrefix),
           let id = UUID(uuidString: String(recordName.dropFirst(workoutPrefix.count))) {
            return .workout(id)
        }
        return .unrecognised
    }
}

// MARK: - Fitness-zone purge delete list (pure, CloudKit-free)
//
// `CloudFitnessSync`'s zone-corruption purge tool (`Banana/Model/CloudProgressSync.swift`'s
// `#if DEBUG` extension, driven by `CloudFitnessZonePurgeTool`) used to discover which records to
// delete by querying the zone. That cannot work in this container: CloudKit rejects any query
// against `SettingsSnapshot` records — including a match-everything `NSPredicate(value: true)` —
// because `recordName` isn't marked Queryable in this container's schema, and CloudKit needs an
// index on it to enumerate records of the type at all. Observed live:
//
//     CKError "Invalid Arguments" (12/2015); server message = "Field 'recordName' is not marked
//     queryable"
//
// So the tool instead deletes a known list of record names, generated ahead of time from evidence
// gathered entirely outside CloudKit (the pre-dedup backup of the local index). Deletion by record
// ID needs no queryable index — only the list has to be right, which is what the types below
// exist to check, twice, before a single record is deleted.
//
// Kept pure and CloudKit-free — like `CloudFitnessRecordRouting` above — so the file-loading and
// overlap-checking logic is directly unit-testable without constructing a
// `CKSyncEngine`/`CKContainer` (which `CloudFitnessSync`'s own doc comment warns can terminate the
// process outside a signed-in run). The actual deletion call stays in `CloudProgressSync.swift`,
// which is CloudKit-dependent and deliberately excluded from the test target.

/// The on-disk shape of a purge run's delete list — decoded from the JSON file path given via
/// `--purge-fitness-zone-delete-list`.
struct FitnessZonePurgeDeleteList: Sendable, Codable {
    /// CloudKit record names (`workout-<uuid>`) that out-of-band evidence judged phantom — the
    /// candidates a run will delete, pending `FitnessZonePurgePlan.validate` below.
    let phantomRecordNames: [String]
    /// Record names of workouts that same evidence judged real. Never deleted — carried only so
    /// `validate` can assert, independent of anything CloudKit reports, that the file's own two
    /// lists do not overlap each other.
    let realRecordNames: [String]
}

/// Why `FitnessZonePurgePlan.validate` refused to proceed. Either case means the whole run aborts
/// — never "delete everything except the offending name" — because a delete list that overlaps
/// reality anywhere means the list itself is wrong, not that one entry is.
enum FitnessZonePurgeValidationError: Error, Equatable, CustomStringConvertible {
    /// The delete list's own two arrays overlap — it claims the same record name is both a
    /// phantom to delete and a real workout to preserve, which means whatever generated the file
    /// disagrees with itself. Caught before the live index is even consulted.
    case deleteListSelfContradicts(overlap: Set<String>)
    /// A record name in the delete list matches a workout the live local index still considers
    /// real. The list is stale or wrong — abort entirely rather than silently skip just that name.
    case deleteListOverlapsLiveRealWorkouts(overlap: Set<String>)

    var description: String {
        switch self {
        case .deleteListSelfContradicts(let overlap):
            return "delete list contradicts itself — \(overlap.count) name(s) appear in both phantomRecordNames and realRecordNames: \(overlap.sorted())"
        case .deleteListOverlapsLiveRealWorkouts(let overlap):
            return "delete list overlaps \(overlap.count) surviving real workout(s) in the live local index: \(overlap.sorted())"
        }
    }
}

enum FitnessZonePurgePlan {
    /// The CloudKit record name for a workout — the inverse of the `.workout(id)` case
    /// `CloudFitnessRecordRouting.classify` decodes back out of a record name. Needed here to
    /// turn the live local index's real ids (`UUID`) into the same namespace as the record names
    /// loaded from a delete-list file (`String`), so `validate` can compare them.
    static func workoutRecordName(for id: UUID) -> String {
        CloudFitnessRecordRouting.workoutPrefix + id.uuidString
    }

    /// Validates a loaded delete list BEFORE any deletion is attempted: first that the file does
    /// not contradict itself, then — the primary safety rule — that none of its phantom names
    /// match a workout `liveRealRecordNames` (a FRESH read of the live local index, not anything
    /// cached from the file or an earlier run) still considers real. Throws to abort the whole run
    /// on either failure; does nothing (a clean no-op) when `list.phantomRecordNames` is empty.
    static func validate(_ list: FitnessZonePurgeDeleteList, liveRealRecordNames: Set<String>) throws {
        let selfOverlap = Set(list.phantomRecordNames).intersection(list.realRecordNames)
        guard selfOverlap.isEmpty else {
            throw FitnessZonePurgeValidationError.deleteListSelfContradicts(overlap: selfOverlap)
        }
        let liveOverlap = Set(list.phantomRecordNames).intersection(liveRealRecordNames)
        guard liveOverlap.isEmpty else {
            throw FitnessZonePurgeValidationError.deleteListOverlapsLiveRealWorkouts(overlap: liveOverlap)
        }
    }
}

// MARK: - Fitness cloud sync state (pure derivation)

/// What `CloudFitnessSync` currently believes about workouts (and the notes/health records it
/// shares a zone with) reaching iCloud from THIS device — the answer to "has this synced between
/// my phone and Mac?" Deliberately conservative about what it claims: CloudKit's private database
/// tells this app when a record has left a device, never when a *different* device has fetched
/// it, so nothing here — nor its per-workout sibling `WorkoutCloudUploadState` — ever asserts
/// delivery to the other side, only that this device's copy is (or isn't yet) on its way.
enum FitnessSyncState: Equatable {
    /// Either iCloud isn't usable right now (no container entitlement, Simulator, the
    /// `--disable-icloud` launch argument, or the account is signed out) or this device has never
    /// completed a single exchange yet. Both read the same to the user — there is no successful
    /// sync to report — so they share one case rather than inventing a distinction nothing on
    /// screen would act on differently.
    case unavailable
    /// A send/fetch exchange with CloudKit is in flight right now.
    case syncing
    /// Nothing is waiting. `Date` is when the backlog last reached zero — not necessarily "just
    /// now," since this device may not have made a change since.
    case upToDate(Date)
    /// `count` records — workouts, voice notes, or the Health cache — have a local change iCloud
    /// hasn't acknowledged yet, or (for a workout) have a summary saved but the raw-sample file
    /// still queued to attach. `lastSuccess` is the most recent time the backlog was empty, if
    /// ever, so a stalled backlog can still say when things last moved.
    case waiting(count: Int, lastSuccess: Date?)
}

/// Pure glue from the sets `CloudFitnessSync` already maintains (`dirty`, `assetPending`) plus its
/// own availability/exchange bits into one `FitnessSyncState` — kept CloudKit-free, like
/// `CloudFitnessRecordRouting` and `FitnessZonePurgePlan` above, so it is directly unit-testable
/// without constructing a `CKSyncEngine`/`CKContainer` (see those types' doc comments for why that
/// can terminate the process outside a signed-in run). `CloudFitnessSync.recomputeSyncState()` is
/// the only caller, and calls it at settle points — once per CloudKit event, never once per
/// record — so publishing `syncState` never fires per-record during a big batch.
enum FitnessSyncStateDerivation {
    static func derive(iCloudAvailable: Bool, exchanging: Bool, pendingCount: Int,
                       lastSuccess: Date?) -> FitnessSyncState {
        guard iCloudAvailable else { return .unavailable }
        if exchanging { return .syncing }
        if pendingCount > 0 { return .waiting(count: pendingCount, lastSuccess: lastSuccess) }
        guard let lastSuccess else { return .unavailable }   // nothing pending, but never confirmed
        return .upToDate(lastSuccess)
    }
}

/// Per-workout truth about whether ITS recording has left this device for iCloud — separate from
/// `FitnessStore.hasLocalSamples`, which only answers whether the raw file exists ON THIS DEVICE.
/// The two questions are independent: a workout can have the full recording locally and still be
/// mid-upload, or have no local recording at all (summary-only) and therefore nothing here to
/// send. Never claims delivery to another device — see `FitnessSyncState`'s doc comment for why.
enum WorkoutCloudUploadState: Equatable {
    /// This device has no raw file for the workout, so there is nothing here to send. Distinct
    /// from `waiting`: that means a local recording exists and has a send outstanding.
    case noLocalRecording
    /// This device HAS the recording, but iCloud sync isn't running right now (no entitlement,
    /// Simulator, `--disable-icloud`, or the account is signed out) — there is no honest answer
    /// to give. Distinct from `noLocalRecording`: this workout has something to say, this device
    /// just can't say it. Without this case, an unstarted sync engine's empty bookkeeping reads
    /// as indistinguishable from "everything already uploaded," which is exactly the false
    /// confidence this type exists to rule out.
    case unavailable
    /// A local change hasn't reached CloudKit yet — either never sent, or sent but rejected and
    /// waiting to retry (including a raw asset deferred behind a schema-rollout cooldown).
    case waiting
    /// A send/fetch exchange is in flight right now.
    case uploading
    /// This device's copy has left it — CloudKit acknowledged the record. This says nothing about
    /// whether the other device has fetched it yet.
    case uploaded
}

/// Pure derivation for `WorkoutCloudUploadState`, mirroring `FitnessSyncStateDerivation` above —
/// see that type's doc comment for why this stays CloudKit-free and is called only at settle
/// points. `CloudFitnessSync.uploadState(for:hasLocalSamples:)` supplies the live inputs.
enum WorkoutCloudUploadStateDerivation {
    static func derive(hasLocalSamples: Bool, iCloudAvailable: Bool, isPending: Bool,
                       exchanging: Bool) -> WorkoutCloudUploadState {
        guard hasLocalSamples else { return .noLocalRecording }
        guard iCloudAvailable else { return .unavailable }
        guard isPending else { return .uploaded }
        return exchanging ? .uploading : .waiting
    }
}

// MARK: - Night motion (Watch → phone)

/// A night's steps minute by minute, read on the Watch from Core Motion and sent to the phone to
/// time night wake-ups. Health keeps the Watch's steps only as chunks of several minutes, which
/// can't say which minutes you walked in; this can.
struct NightMotionReport: Codable, Sendable {
    struct Minute: Codable, Hashable, Sendable {
        var start: Date
        var steps: Int
    }

    struct Span: Codable, Hashable, Sendable {
        var start: Date
        var end: Date
    }

    struct Window: Codable, Hashable, Sendable {
        var start: Date
        var end: Date
        /// Minutes with steps; the rest of the window had none.
        var minutes: [Minute]
        /// When Core Motion thought you were walking.
        var walking: [Span]
    }

    /// Evening-to-morning windows.
    var windows: [Window]
    /// The last couple of hours, whatever the time — for checking against a walk you timed.
    var probe: Window?
    var generated: Date
}

// MARK: - Workouts from the data platform

/// Other devices' summaries and deletes from the data platform (`FitnessStore.adoptSpaceSummaries`
/// and `removeSpaceWorkouts`), worked out here so the rule is tested without the store: while an
/// iCloud batch is open (`FitnessStore.applyingCloudBatch`) the change goes into its working copy,
/// which the batch publishes and saves at its end; otherwise into the list itself, once.
enum FitnessSpaceChanges {
    /// `list` with `incoming` put in by id, newest first.
    static func adopting(_ incoming: [FitnessSessionSummary], into list: [FitnessSessionSummary]) -> [FitnessSessionSummary] {
        var next = list
        for summary in incoming {
            if let index = next.firstIndex(where: { $0.id == summary.id }) { next[index] = summary } else { next.append(summary) }
        }
        next.sort { $0.start > $1.start }
        return next
    }

    /// Applies `change` to the open batch's working copy (nil: no batch is open) or to
    /// `summaries`. True when something changed: the caller saves (no batch) or marks the batch's
    /// index dirty.
    static func apply(_ change: ([FitnessSessionSummary]) -> [FitnessSessionSummary],
                      summaries: inout [FitnessSessionSummary], working: inout [FitnessSessionSummary]?,
                      batchOpen: Bool) -> Bool {
        if batchOpen {
            let base = working ?? summaries
            let next = change(base)
            guard next != base else { return false }
            working = next
            return true
        }
        let next = change(summaries)
        guard next != summaries else { return false }
        summaries = next
        return true
    }
}
