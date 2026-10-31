import Foundation

// This file holds the plain-data types that used to live at the top of HealthKitStore.swift
// (HealthWorkout and its supporting trend types). Split out so BananaTests can source
// HealthWorkout (needed transitively by WorkoutEntry.swift) without also pulling in
// HealthKitStore's HealthKit-backed class body and ITS dependency chain (AppSupport,
// CloudFitnessSync, LaunchClock, Log) into the test target.

/// A workout imported from Apple Health — no matter which app or device recorded
/// it (Apple Watch, WorkoutDoors, Whoop, …). `source` names the writer.
struct HealthWorkout: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var activity: String = "Workout"
    var start: Date = .distantPast
    var end: Date = .distantPast
    var duration: TimeInterval = 0
    var energyKcal: Double?
    var distanceMeters: Double?
    var avgHeartRate: Double?
    var maxHeartRate: Double?
    var source: String = ""
    /// The writing app's bundle identifier (`workout.sourceRevision.source.bundleIdentifier`).
    /// Only a workout Banana itself wrote (hub-and-spoke: the phone is the sole HKWorkout
    /// author) can be deleted from Health — everything else (Watch app's own older build,
    /// Apple's auto-detection, third-party apps) can only be hidden inside Banana. Optional so
    /// cached data from before this field existed decodes as "unknown, therefore undeletable".
    var sourceBundleID: String?
    /// The writing device's model ("iPhone16,2", "Watch7,5"), from the source revision. Tells a
    /// phone-written copy from one the Watch or another device wrote.
    var productType: String?
    /// Pool length the workout was recorded with (`HKMetadataKeyLapLength`), for pool swims.
    var lapLengthMeters: Double?
    /// `HKMetadataKeySyncIdentifier` — Banana stamps its own saves with the session id, so a
    /// second save of the same session replaces the first instead of adding a copy.
    var syncIdentifier: String?
}

extension HealthWorkout {
    /// Tolerant decoder so cached data survives adding fields later.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? activity
        start = try c.decodeIfPresent(Date.self, forKey: .start) ?? start
        end = try c.decodeIfPresent(Date.self, forKey: .end) ?? end
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? duration
        energyKcal = try c.decodeIfPresent(Double.self, forKey: .energyKcal)
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters)
        avgHeartRate = try c.decodeIfPresent(Double.self, forKey: .avgHeartRate)
        maxHeartRate = try c.decodeIfPresent(Double.self, forKey: .maxHeartRate)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? source
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        productType = try c.decodeIfPresent(String.self, forKey: .productType)
        lapLengthMeters = try c.decodeIfPresent(Double.self, forKey: .lapLengthMeters)
        syncIdentifier = try c.decodeIfPresent(String.self, forKey: .syncIdentifier)
    }
}

/// What `HealthKitStore.remove(workoutID:)` actually did — the phone can only ever delete a
/// workout it wrote itself; everything else is hidden inside Banana instead (see
/// `HealthWorkout.sourceBundleID`).
enum HealthWorkoutRemoval: Sendable, Equatable {
    case deletedFromHealth
    case hiddenInBanana
    case notFound
}

/// Recorded when a Banana summary is deleted but its paired Apple Health workout hasn't been
/// imported yet (still in flight, or written by a slower device) — so the *next* import can
/// find and remove/hide it instead of letting it surface as an orphan "map gone, row stays"
/// row. Matched against a new workout's start time within `matchWindow`, same tolerance
/// `WorkoutEntry.matchTolerance` uses to pair a summary with its Health copy — AND against the
/// workout having already ended by the time this tombstone was created, so a genuinely new
/// workout that merely *starts* within the window (e.g. the owner mis-taps, deletes within
/// seconds, then starts a real session close enough in time to fall inside `matchWindow`) can
/// never be swept up and deleted just because its start lines up with an unrelated delete.
struct PendingRemoval: Codable, Hashable, Sendable {
    var start: Date
    var expiresAt: Date

    /// A tombstone this old is almost certainly for a workout Health will never receive
    /// (deleted before it synced, or never written at all) — stop matching against it so a
    /// coincidentally-timed *unrelated* future workout can't be swept up by a stale entry.
    static let ttl: TimeInterval = 24 * 60 * 60
    static let matchWindow: TimeInterval = WorkoutEntry.matchTolerance

    init(start: Date, now: Date = Date()) {
        self.start = start
        self.expiresAt = now.addingTimeInterval(Self.ttl)
    }

    /// Derived rather than stored so old cached tombstones (written before this check existed)
    /// still decode fine — `expiresAt` was always `creation time + ttl`, so this recovers the
    /// creation time exactly without adding a field that could fail to decode.
    private var createdAt: Date { expiresAt.addingTimeInterval(-Self.ttl) }

    /// - Parameter workoutEnd: the newly-imported workout's end time. A workout that started
    ///   after this tombstone was created will also have *ended* after it (Health always reports
    ///   an end time later than the start), so requiring `workoutEnd <= createdAt` rules out a
    ///   new, unrelated workout while still matching the original one that had already finished
    ///   (and was then deleted) before this tombstone was written.
    func matches(_ workoutStart: Date, _ workoutEnd: Date, now: Date) -> Bool {
        expiresAt > now && abs(workoutStart.timeIntervalSince(start)) < Self.matchWindow && workoutEnd <= createdAt
    }
}

/// One daily data point in a metric's trend series.
/// The Health cache as it travels to the Mac: one CloudKit record, which can't pass 1 MB — and
/// the workout list alone had reached 830 KB of JSON and grows with every workout. Compressed,
/// it's a small fraction of that. A leading marker tells it from the plain JSON older builds sent.
enum HealthSnapshotCoding {
    static let marker = Data("LZFSE1".utf8)

    static func pack(_ json: Data) -> Data? {
        guard let compressed = try? (json as NSData).compressed(using: .lzfse) else { return nil }
        return marker + (compressed as Data)
    }

    /// The JSON inside, whichever way it was sent; nil when it won't decompress.
    static func unpack(_ data: Data) -> Data? {
        guard data.starts(with: marker) else { return data }
        return try? (Data(data.dropFirst(marker.count)) as NSData).decompressed(using: .lzfse) as Data
    }

    /// What the record's `payload` says when the snapshot itself rides in the record's asset —
    /// outside the 1 MB a record may hold, however many workouts and days of history there are.
    static let inAsset = Data("IN-ASSET".utf8)

    /// The packed snapshot a fetched record carries: in its asset, or (a record from before
    /// assets, or while the asset field is being refused) in its payload.
    static func snapshot(payload: Data, asset: () -> Data?) -> Data? {
        payload == inAsset ? asset() : payload
    }
}

struct MetricPoint: Codable, Hashable, Sendable {
    var date: Date
    var value: Double
}

/// Health metrics aggregated over a Rhythm period, bucketed for charting.
struct RhythmHealth: Sendable {
    var sleep: [MetricPoint] = []
    var hrv: [MetricPoint] = []
    var restingHR: [MetricPoint] = []
}

/// Daily HealthKit series used for fitness, body-composition, and recovery context.
/// Recovery data is refreshed over the recent month; slower-moving body and activity history
/// is retained for a year so correlations are meaningful rather than just a seven-day snapshot.
struct HealthTrends: Codable, Sendable {
    var restingHR: [MetricPoint] = []
    var hrv: [MetricPoint] = []
    var respiratory: [MetricPoint] = []
    var vo2Max: [MetricPoint] = []
    var sleepHours: [MetricPoint] = []
    var bodyMassKg: [MetricPoint] = []
    var bodyFatPercentage: [MetricPoint] = []
    var leanBodyMassKg: [MetricPoint] = []
    var bodyMassIndex: [MetricPoint] = []
    var heightMeters: [MetricPoint] = []
    var steps: [MetricPoint] = []
    var activeEnergyKcal: [MetricPoint] = []
    var basalEnergyKcal: [MetricPoint] = []
    var exerciseMinutes: [MetricPoint] = []
    var flightsClimbed: [MetricPoint] = []
    var walkingSpeedMetersPerSecond: [MetricPoint] = []
    var walkingHeartRate: [MetricPoint] = []
    /// The last two weeks of nights, with their wake-ups — worked out on the phone from Health's
    /// sleep stages and steps (see `SleepNights`), synced so the Mac shows the same nights.
    /// What each wake-up was is decided where it's shown (`SleepNights.classified`).
    var nights: [NightSummary] = []

    var isEmpty: Bool {
        [restingHR, hrv, respiratory, vo2Max, sleepHours,
         bodyMassKg, bodyFatPercentage, leanBodyMassKg, bodyMassIndex, heightMeters,
         steps, activeEnergyKcal, basalEnergyKcal, exerciseMinutes, flightsClimbed,
         walkingSpeedMetersPerSecond, walkingHeartRate].allSatisfy(\.isEmpty)
    }

    init() {}

    /// Tolerant decoder (arrays default to empty).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restingHR = try c.decodeIfPresent([MetricPoint].self, forKey: .restingHR) ?? []
        hrv = try c.decodeIfPresent([MetricPoint].self, forKey: .hrv) ?? []
        respiratory = try c.decodeIfPresent([MetricPoint].self, forKey: .respiratory) ?? []
        vo2Max = try c.decodeIfPresent([MetricPoint].self, forKey: .vo2Max) ?? []
        sleepHours = try c.decodeIfPresent([MetricPoint].self, forKey: .sleepHours) ?? []
        bodyMassKg = try c.decodeIfPresent([MetricPoint].self, forKey: .bodyMassKg) ?? []
        bodyFatPercentage = try c.decodeIfPresent([MetricPoint].self, forKey: .bodyFatPercentage) ?? []
        leanBodyMassKg = try c.decodeIfPresent([MetricPoint].self, forKey: .leanBodyMassKg) ?? []
        bodyMassIndex = try c.decodeIfPresent([MetricPoint].self, forKey: .bodyMassIndex) ?? []
        heightMeters = try c.decodeIfPresent([MetricPoint].self, forKey: .heightMeters) ?? []
        steps = try c.decodeIfPresent([MetricPoint].self, forKey: .steps) ?? []
        activeEnergyKcal = try c.decodeIfPresent([MetricPoint].self, forKey: .activeEnergyKcal) ?? []
        basalEnergyKcal = try c.decodeIfPresent([MetricPoint].self, forKey: .basalEnergyKcal) ?? []
        exerciseMinutes = try c.decodeIfPresent([MetricPoint].self, forKey: .exerciseMinutes) ?? []
        flightsClimbed = try c.decodeIfPresent([MetricPoint].self, forKey: .flightsClimbed) ?? []
        walkingSpeedMetersPerSecond = try c.decodeIfPresent([MetricPoint].self, forKey: .walkingSpeedMetersPerSecond) ?? []
        walkingHeartRate = try c.decodeIfPresent([MetricPoint].self, forKey: .walkingHeartRate) ?? []
        nights = (try? c.decodeIfPresent([NightSummary].self, forKey: .nights)) ?? []
    }

    /// HealthKit read permission is per-type and intentionally opaque. Preserve an already
    /// synced series when a refresh returns nothing for one particular type.
    mutating func mergeNonEmpty(_ newer: HealthTrends) {
        if !newer.restingHR.isEmpty { restingHR = newer.restingHR }
        if !newer.hrv.isEmpty { hrv = newer.hrv }
        if !newer.respiratory.isEmpty { respiratory = newer.respiratory }
        if !newer.vo2Max.isEmpty { vo2Max = newer.vo2Max }
        if !newer.sleepHours.isEmpty { sleepHours = newer.sleepHours }
        if !newer.bodyMassKg.isEmpty { bodyMassKg = newer.bodyMassKg }
        if !newer.bodyFatPercentage.isEmpty { bodyFatPercentage = newer.bodyFatPercentage }
        if !newer.leanBodyMassKg.isEmpty { leanBodyMassKg = newer.leanBodyMassKg }
        if !newer.bodyMassIndex.isEmpty { bodyMassIndex = newer.bodyMassIndex }
        if !newer.heightMeters.isEmpty { heightMeters = newer.heightMeters }
        if !newer.steps.isEmpty { steps = newer.steps }
        if !newer.activeEnergyKcal.isEmpty { activeEnergyKcal = newer.activeEnergyKcal }
        if !newer.basalEnergyKcal.isEmpty { basalEnergyKcal = newer.basalEnergyKcal }
        if !newer.exerciseMinutes.isEmpty { exerciseMinutes = newer.exerciseMinutes }
        if !newer.flightsClimbed.isEmpty { flightsClimbed = newer.flightsClimbed }
        if !newer.walkingSpeedMetersPerSecond.isEmpty { walkingSpeedMetersPerSecond = newer.walkingSpeedMetersPerSecond }
        if !newer.walkingHeartRate.isEmpty { walkingHeartRate = newer.walkingHeartRate }
        if !newer.nights.isEmpty { nights = newer.nights }
    }
}

/// The metrics we chart, with per-metric display + interpretation.
enum MetricKind: CaseIterable, Hashable, Sendable {
    case restingHR, hrv, respiratory, vo2Max, sleep
    case bodyMass, bodyFat, leanBodyMass, bodyMassIndex, height
    case steps, activeEnergy, basalEnergy, exercise, flightsClimbed, walkingSpeed, walkingHeartRate

    var title: String {
        switch self {
        case .restingHR: return "Resting HR"
        case .hrv: return "HRV"
        case .respiratory: return "Respiratory"
        case .vo2Max: return "VO₂ max"
        case .sleep: return "Sleep"
        case .bodyMass: return "Weight"
        case .bodyFat: return "Body fat"
        case .leanBodyMass: return "Lean body mass"
        case .bodyMassIndex: return "BMI"
        case .height: return "Height"
        case .steps: return "Steps"
        case .activeEnergy: return "Active energy"
        case .basalEnergy: return "Resting energy"
        case .exercise: return "Exercise"
        case .flightsClimbed: return "Flights climbed"
        case .walkingSpeed: return "Walking speed"
        case .walkingHeartRate: return "Walking HR"
        }
    }

    var icon: String {
        switch self {
        case .restingHR: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .respiratory: return "lungs.fill"
        case .vo2Max: return "figure.run"
        case .sleep: return "bed.double.fill"
        case .bodyMass: return "scalemass.fill"
        case .bodyFat: return "percent"
        case .leanBodyMass: return "figure.strengthtraining.traditional"
        case .bodyMassIndex: return "sum"
        case .height: return "ruler"
        case .steps: return "figure.walk"
        case .activeEnergy: return "flame.fill"
        case .basalEnergy: return "flame"
        case .exercise: return "figure.mixed.cardio"
        case .flightsClimbed: return "stairs"
        case .walkingSpeed: return "figure.walk.motion"
        case .walkingHeartRate: return "heart.text.square.fill"
        }
    }

    /// Which direction of change is a good thing (drives trend color).
    var higherIsBetter: Bool? {
        switch self {
        case .hrv, .vo2Max, .sleep: return true
        case .restingHR, .respiratory: return false
        case .bodyFat, .walkingHeartRate: return false
        case .leanBodyMass, .steps, .exercise, .flightsClimbed, .walkingSpeed: return true
        case .bodyMass, .bodyMassIndex, .height, .activeEnergy, .basalEnergy: return nil
        }
    }

    func series(_ trends: HealthTrends) -> [MetricPoint] {
        switch self {
        case .restingHR: return trends.restingHR
        case .hrv: return trends.hrv
        case .respiratory: return trends.respiratory
        case .vo2Max: return trends.vo2Max
        case .sleep: return trends.sleepHours
        case .bodyMass: return trends.bodyMassKg
        case .bodyFat: return trends.bodyFatPercentage
        case .leanBodyMass: return trends.leanBodyMassKg
        case .bodyMassIndex: return trends.bodyMassIndex
        case .height: return trends.heightMeters
        case .steps: return trends.steps
        case .activeEnergy: return trends.activeEnergyKcal
        case .basalEnergy: return trends.basalEnergyKcal
        case .exercise: return trends.exerciseMinutes
        case .flightsClimbed: return trends.flightsClimbed
        case .walkingSpeed: return trends.walkingSpeedMetersPerSecond
        case .walkingHeartRate: return trends.walkingHeartRate
        }
    }

    /// Imperial (lb, ft/in, mph) or metric, following the distance unit in Settings — set by
    /// `AppSettings`, so every device shows your units. Weight, height and speed used to be
    /// fixed at kg, cm and km/h whatever the setting said.
    nonisolated(unsafe) static var imperial = false

    /// A stored value (Health's own units: kg, m, m/s) in the units shown — for chart axes.
    func displayValue(_ value: Double, imperial: Bool = MetricKind.imperial) -> Double {
        guard imperial else { return self == .walkingSpeed ? value * 3.6 : value }
        switch self {
        case .bodyMass, .leanBodyMass: return value * 2.204_622_6
        case .walkingSpeed: return value * 2.236_936_3
        case .height: return value / 0.0254   // inches
        default: return value
        }
    }

    func format(_ value: Double, imperial: Bool = MetricKind.imperial) -> String {
        if imperial {
            switch self {
            case .bodyMass, .leanBodyMass:
                return String(format: "%.1f lb", displayValue(value, imperial: true))
            case .height:
                let inches = Int(displayValue(value, imperial: true).rounded())
                return "\(inches / 12)\u{2032} \(inches % 12)\u{2033}"
            case .walkingSpeed:
                return String(format: "%.1f mph", displayValue(value, imperial: true))
            default:
                break
            }
        }
        switch self {
        case .restingHR: return "\(Int(value.rounded())) bpm"
        case .hrv: return "\(Int(value.rounded())) ms"
        case .respiratory: return String(format: "%.0f br/min", value)
        case .vo2Max: return String(format: "%.1f", value)
        case .sleep:
            return DS.duration(minutes: value * 60)
        case .bodyMass: return String(format: "%.1f kg", value)
        case .bodyFat: return String(format: "%.1f%%", value * 100)
        case .leanBodyMass: return String(format: "%.1f kg", value)
        case .bodyMassIndex: return String(format: "%.1f", value)
        case .height: return String(format: "%.0f cm", value * 100)
        case .steps: return "\(Int(value.rounded()).formatted())"
        case .activeEnergy, .basalEnergy: return "\(Int(value.rounded()).formatted()) kcal"
        case .exercise: return "\(Int(value.rounded())) min"
        case .flightsClimbed: return "\(Int(value.rounded()))"
        case .walkingSpeed: return String(format: "%.1f km/h", value * 3.6)
        case .walkingHeartRate: return "\(Int(value.rounded())) bpm"
    }
}
}
