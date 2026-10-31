import Foundation
import SwiftUI
import HealthKit
import CoreMotion
import CoreLocation
import WatchKit
import os

/// Lightweight record of a finished workout kept on the Watch for display.
/// The raw samples themselves are streamed to a file and transferred to the
/// phone (not held here), so the Watch's memory and storage stay bounded.
struct WorkoutSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var start: Date
    var end: Date
    var activity: String
    var avgHeartRate: Double?
    var totalEnergy: Double?
    var totalDistance: Double?
    var sampleCount: Int
    var poolLengthMeters: Double? = nil
    var lapDurations: [TimeInterval] = []
    /// W3C trace context for the phone's ingest/HealthKit child span.
    var traceparent: String? = nil
    /// The stretches it was paused for (`WorkoutPauses`).
    var pauses: [FitnessPause] = []

    /// The workout's time, pauses left out: what the history shows.
    var duration: TimeInterval { max(0, end.timeIntervalSince(start) - WorkoutPauses.pausedSeconds(pauses)) }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, activity, avgHeartRate, totalEnergy, totalDistance, sampleCount
        case poolLengthMeters, lapDurations, traceparent, pauses
    }
}

extension WorkoutSummary {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        activity = try container.decode(String.self, forKey: .activity)
        avgHeartRate = try container.decodeIfPresent(Double.self, forKey: .avgHeartRate)
        totalEnergy = try container.decodeIfPresent(Double.self, forKey: .totalEnergy)
        totalDistance = try container.decodeIfPresent(Double.self, forKey: .totalDistance)
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        poolLengthMeters = try container.decodeIfPresent(Double.self, forKey: .poolLengthMeters)
        lapDurations = try container.decodeIfPresent([TimeInterval].self, forKey: .lapDurations) ?? []
        traceparent = try container.decodeIfPresent(String.self, forKey: .traceparent)
        pauses = try container.decodeIfPresent([FitnessPause].self, forKey: .pauses) ?? []
    }
}

/// A completed distance split. `elapsed` is retained so the current split can keep counting from
/// the exact crossing time, while `duration` is what the athlete sees in the recent-splits list.
struct WorkoutSplit: Identifiable, Equatable {
    let number: Int
    let duration: TimeInterval
    let elapsed: TimeInterval

    var id: Int { number }
}

/// The 1 Hz-ticking workout numbers live in their own observation object, mirroring
/// `WatchPlaybackClock` (WatchAudioPlayer.swift). A view that only needs isRecording /
/// isSwimTouchInputLocked / etc. can observe `WorkoutRecorder` without being invalidated
/// every second; only a view that actually renders the live numbers observes `live`.
@MainActor
final class WorkoutLiveMetrics: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var heartRate: Double = 0     // bpm
    @Published var energy: Double = 0        // kcal
    @Published var distance: Double = 0      // meters
    @Published var pace: Double = 0
    /// Paused: the clock has stopped and nothing is being recorded.
    @Published fileprivate(set) var isPaused = false
    @Published fileprivate(set) var splits: [WorkoutSplit] = []
    @Published fileprivate(set) var splitDistanceMeters: Double?

    var supportsDistanceSplits: Bool { splitDistanceMeters != nil }
    var currentSplitElapsed: TimeInterval {
        max(0, elapsed - (splits.last?.elapsed ?? 0))
    }
    var currentSplitDistanceMeters: Double {
        guard let splitDistanceMeters else { return 0 }
        return min(splitDistanceMeters, max(0, distance - Double(splits.count) * splitDistanceMeters))
    }
}

/// Records a real workout on the Watch: a HealthKit workout session collects
/// heart rate / energy / distance, CoreMotion captures raw accel + gyro, and
/// CoreLocation captures GPS. Samples stream to disk (via `SampleWriter`); on
/// finish the file transfers to the phone and is deleted locally.
///
/// Device-only: HealthKit workout sessions, motion, and GPS don't work in the Simulator.
@MainActor
final class WorkoutRecorder: NSObject, ObservableObject {
    static let shared = WorkoutRecorder()
    @Published var isAuthorized = false
    @Published var isRecording = false
    @Published private(set) var isRecovering = false
    @Published private(set) var isFinishing = false
    /// Storage + Combine publishing for the 1 Hz-ticking numbers (see `WorkoutLiveMetrics`
    /// doc comment above). `elapsed`/`heartRate`/etc. below are read-only forwarders onto this
    /// so every existing call site keeps compiling unchanged.
    let live = WorkoutLiveMetrics()
    @Published private(set) var isPoolSwimming = false
    /// A belt-and-suspenders guard around the system Water Lock. It covers the brief period
    /// between starting a pool swim and watchOS confirming that Water Lock is active, then drops
    /// only after the swimmer has explicitly cleared Water Lock with the Digital Crown.
    @Published private(set) var isSwimTouchInputLocked = false
    @Published var lastError: String?
    @Published var savedSessions: [WorkoutSummary] = []

    /// Pace means something when you're moving under your own steam over ground. It doesn't on a
    /// rowing machine or under a barbell, and cyclists read speed, not minutes per mile.
    @Published private(set) var restDeadline: Date?
    private var restTask: Task<Void, Never>?

    var showsRestTimer: Bool {
        [.traditionalStrengthTraining, .functionalStrengthTraining, .crossTraining, .other].contains(activity)
    }

    func startRest(seconds: Int) {
        guard isRecording, showsRestTimer, [30, 60].contains(seconds) else { return }
        restTask?.cancel()
        restDeadline = Date().addingTimeInterval(TimeInterval(seconds))
        restTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard let self, self.isRecording else { return }
            self.restDeadline = nil
            // watchOS owns haptic intensity. Repeat its notification pattern so the
            // end of a rest is noticeable while lifting, without an endless alarm.
            for pulse in 0..<3 {
                guard !Task.isCancelled else { return }
                if pulse > 0 {
                    do { try await Task.sleep(for: .milliseconds(1200)) }
                    catch { return }
                }
                guard !Task.isCancelled, self.isRecording else { return }
                WKInterfaceDevice.current().play(.notification)
            }
        }
    }

    func cancelRest() {
        restTask?.cancel(); restTask = nil; restDeadline = nil
    }

    private(set) var activity: HKWorkoutActivityType = .other
    var showsPace: Bool { [.running, .walking, .hiking].contains(activity) }

    /// (elapsed, meters) samples for the rolling distance pace window.
    private var paceSamples: [(t: TimeInterval, d: Double)] = []
    private var paceWindowMeters: Double = 400
    private var lastSplitSample: (elapsed: TimeInterval, distance: Double)?

    // Read-only forwarders onto `live` — see the `WorkoutLiveMetrics` doc comment. Internal
    // methods below write through `live.*` directly; nothing outside this file writes these.
    var elapsed: TimeInterval { live.elapsed }
    var heartRate: Double { live.heartRate }     // bpm
    var energy: Double { live.energy }           // kcal
    var distance: Double { live.distance }       // meters
    /// Seconds per meter, over a rolling window. 0 = not enough movement to say yet.
    ///
    /// Deliberately NOT elapsed/distance: an average over a whole run barely moves by the middle
    /// of it, so it can't tell you whether you're going too fast *now* — which is the only reason
    /// to put a pace on a watch face.
    var pace: Double { live.pace }
    var splits: [WorkoutSplit] { live.splits }
    var splitDistanceMeters: Double? { live.splitDistanceMeters }
    var supportsDistanceSplits: Bool { live.supportsDistanceSplits }
    var currentSplitElapsed: TimeInterval { live.currentSplitElapsed }
    var currentSplitDistanceMeters: Double { live.currentSplitDistanceMeters }

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var recoveredSession = false
    private let recoveryStore = WorkoutRecoveryStore(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkoutRecovery", isDirectory: true))

    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let locationManager = CLLocationManager()
    /// Barometric altitude — a new standalone sensor subscription (not already running for any
    /// other purpose), so it's started only outdoors, mirroring the GPS gate in `startSensors`,
    /// rather than adding a sustained cost to indoor/strength/yoga sessions where elevation is
    /// meaningless. See `startSensors` for why it's worth the cost: GPS's vertical component is
    /// its weakest dimension, while the barometer gives near-instant, sub-metre-precision relative
    /// elevation change. `.altitude` (GPS) is left completely unchanged so nothing regresses.
    private let altimeter = CMAltimeter()

    private var writer: SampleWriter?
    private var sessionID = UUID()
    private var startDate: Date?
    /// The pauses so far, and when the open one began, in seconds since the start by the clock.
    private var pauses: [FitnessPause] = []
    private var pausedSince: TimeInterval?
    /// Kept for starting the sensors again after a pause.
    private var sessionIndoor = false
    var isPaused: Bool { live.isPaused }
    private var activityName = "Workout"
    private var hrSum = 0.0
    private var hrCount = 0
    private var timer: Timer?
    private var waterLockTimer: Timer?
    private var hasObservedWaterLock = false
    private var diagnosticSpan: DiagnosticSpan?
    private var lastDiagnosticCheckpointMinute = 0
    /// Set from the gyro's own callback (a background `motionQueue`), read from a main-actor
    /// timer a few seconds later — see `startSensors`'s silent-gyro check.
    private let gyroSampleObserved = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var gyroSilenceCheckTimer: Timer?
    /// Set from the altimeter's own callback (background `motionQueue`) the first time it
    /// delivers a sample; checked-and-cleared from that same callback so the one-time
    /// `observedOpportunisticKinds` main-actor hop below fires once per workout, not once per
    /// ~1 Hz barometer sample.
    private let barometricAltitudeObserved = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// How many of `builder.workoutEvents` have already been scanned for a lap's swim stroke
    /// style — `workoutBuilderDidCollectEvent` re-delivers the WHOLE array each time, not just
    /// what's new, so this is what keeps stroke-style extraction from re-processing every prior
    /// lap on every single new event of any kind (pause/resume/marker included, not just laps).
    private var processedWorkoutEventCount = 0

    /// Which of the new opportunistic types (2026-09: explicit-collection pass) this session
    /// actually observed at least one sample of, vs which ones this activity/location made
    /// plausible to expect. HealthKit never reports a read denial — `HKAuthorizationStatus`
    /// only distinguishes SHARING (write) permission, not read (see `readTypes` above) — and it
    /// silently accepts `enableCollection(for:)` for a type the current activity can't produce.
    /// So a genuinely denied/unsupported type and one that's simply not applicable to this
    /// workout are otherwise indistinguishable from "just never showed up". Diffing these two
    /// sets at `finalize()` and leaving a dated checkpoint is this task's answer to that, the
    /// same way `gyroscope_silent` makes the CoreMotion equivalent visible instead of silent.
    private var observedOpportunisticKinds = Set<FitnessSample.Kind>()
    private var expectedOpportunisticKinds = Set<FitnessSample.Kind>()

    private let summaryStore = SummaryStore()

    private let hrType = HKQuantityType(.heartRate)
    private let energyType = HKQuantityType(.activeEnergyBurned)
    private let distanceType = HKQuantityType(.distanceWalkingRunning)
    private let cyclingDistanceType = HKQuantityType(.distanceCycling)
    private let swimmingDistanceType = HKQuantityType(.distanceSwimming)
    private let runningSpeedType = HKQuantityType(.runningSpeed)
    private let cyclingSpeedType = HKQuantityType(.cyclingSpeed)
    private let runningPowerType = HKQuantityType(.runningPower)
    private let cyclingPowerType = HKQuantityType(.cyclingPower)
    private let cyclingCadenceType = HKQuantityType(.cyclingCadence)
    private let strideLengthType = HKQuantityType(.runningStrideLength)
    private let verticalOscillationType = HKQuantityType(.runningVerticalOscillation)
    private let groundContactType = HKQuantityType(.runningGroundContactTime)
    private let strokeCountType = HKQuantityType(.swimmingStrokeCount)
    // Added for the explicit-collection pass (see `performanceTypes` below): each is free per the
    // capability research (system-computed from sensors already running, or a companion output of
    // one already-running sensor) except the two swim-only water types, which are a real but
    // modest new cost worth it given the owner regularly swims with this Ultra.
    private let stepCountType = HKQuantityType(.stepCount)
    private let physicalEffortType = HKQuantityType(.physicalEffort)
    private let estimatedEffortType = HKQuantityType(.estimatedWorkoutEffortScore)
    private let perfusionIndexType = HKQuantityType(.peripheralPerfusionIndex)
    private let underwaterDepthType = HKQuantityType(.underwaterDepth)
    private let waterTemperatureType = HKQuantityType(.waterTemperature)

    /// HealthKit reports distance under a type that depends on the activity, and
    /// `HKLiveWorkoutDataSource` delivers whichever one matches the session's configuration.
    /// Only `.distanceWalkingRunning` was ever recognised, so anything else silently recorded
    /// zero distance — swimming would have, and cycling already did.
    ///
    /// Matching the whole set instead of resolving one per activity means a future activity type
    /// can't reintroduce the bug by forgetting to extend a switch.
    private var distanceTypes: Set<HKQuantityType> {
        [distanceType, cyclingDistanceType, swimmingDistanceType]
    }
    private var performanceTypes: Set<HKQuantityType> {
        [runningSpeedType, cyclingSpeedType, runningPowerType, cyclingPowerType,
         cyclingCadenceType, strideLengthType, verticalOscillationType,
         groundContactType, strokeCountType,
         stepCountType, physicalEffortType, estimatedEffortType, perfusionIndexType,
         underwaterDepthType, waterTemperatureType]
    }

    /// Which opportunistic `Kind`s a given activity/location makes plausible to expect at least
    /// one sample of, for the silence check in `finalize()`. Swim-only water types on a run, or
    /// barometric altitude indoors, are never "missing" — they're simply not applicable, and
    /// listing them as gaps would just be noise obscuring a genuine one.
    private static func computeExpectedOpportunisticKinds(activity: HKWorkoutActivityType, indoor: Bool) -> Set<FitnessSample.Kind> {
        var kinds: Set<FitnessSample.Kind> = [.stepCount, .physicalEffort, .effortScore, .perfusionIndex]
        if activity == .swimming {
            kinds.formUnion([.underwaterDepth, .waterTemperature, .strokeStyle])
        }
        if !indoor {
            kinds.insert(.barometricAltitude)
        }
        return kinds
    }

    override init() {
        super.init()
        savedSessions = summaryStore.load()
        WatchSyncManager.shared.resendPending(savedSessions)   // re-send any un-acked workouts
        locationManager.delegate = self
        motionQueue.maxConcurrentOperationCount = 1
        motion.accelerometerUpdateInterval = 1.0 / 25.0   // 25 Hz, no sensor-fusion pipeline
        motion.gyroUpdateInterval = 1.0 / 25.0
    }

    /// Remove a saved workout (summary + any leftover sample file) from the Watch.
    func deleteSession(_ id: UUID) {
        savedSessions.removeAll { $0.id == id }
        summaryStore.save(savedSessions)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        for ext in ["lz", "bin", "jsonl"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("session-\(id.uuidString).\(ext)"))
        }
    }

    // MARK: - Authorization

    // Every distance type is requested up front, because authorization happens long before the
    // user picks an activity — asking mid-workout would prompt with a swim already underway.
    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType(), energyType, hrType]
        types.formUnion(distanceTypes.map { $0 as HKSampleType })
        return types
    }
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [hrType, energyType, HKQuantityType(.heartRateVariabilitySDNN)]
        types.formUnion(distanceTypes.map { $0 as HKObjectType })
        types.formUnion(performanceTypes.map { $0 as HKObjectType })
        return types
    }

    /// Reflect HealthKit's remembered decision so we don't re-prompt every launch:
    /// if no request is needed, we're already authorized.
    func refreshAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let status: HKAuthorizationRequestStatus = await withCheckedContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: shareTypes, read: readTypes) { status, _ in
                continuation.resume(returning: status)
            }
        }
        isAuthorized = (status == .unnecessary)   // .unnecessary = HealthKit already has our answer
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Health data isn't available on this device."
            return
        }
        let share = shareTypes
        let read = readTypes
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
            isAuthorized = true
            locationManager.requestWhenInUseAuthorization()
        } catch {
            lastError = "Health permission failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Start / stop

    func start(
        activity activity_: HKWorkoutActivityType = .other,
        name: String = "Workout",
        indoor: Bool = false,
        splitDistanceMeters requestedSplitDistance: Double? = nil,
        paceWindowMeters requestedPaceWindow: Double = 400,
        swimmingLocation: HKWorkoutSwimmingLocationType? = nil,
        lapLengthMeters: Double? = nil
    ) {
        guard !isRecording, !isRecovering, !isFinishing, session == nil, builder == nil else { return }
        sessionID = UUID()
        let diagnostic = DiagnosticJournal.shared.startSpan(
            "workout.capture",
            attributes: [
                "session_id": sessionID.uuidString.lowercased(),
                "activity_type": String(activity_.rawValue),
                "indoor": indoor ? "true" : "false",
            ])
        diagnosticSpan = diagnostic
        let config = HKWorkoutConfiguration()
        config.activityType = activity_
        config.locationType = indoor ? .indoor : .outdoor
        // A swim is the one activity HealthKit cannot interpret from the activity type alone.
        // Without the location type it can't tell a pool set from open water, and without a lap
        // length a pool swim yields no laps and no stroke counts — the numbers that make the
        // recording worth having.
        if let swimmingLocation { config.swimmingLocationType = swimmingLocation }
        if let lapLengthMeters, lapLengthMeters > 0 {
            config.lapLength = HKQuantity(unit: .meter(), doubleValue: lapLengthMeters)
        }
        do {
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            // Make collection explicit instead of relying on Apple's undocumented per-activity
            // default type set — the same silent dependency that lost five running metrics
            // (power/speed/stride length/vertical oscillation/ground contact time) until it
            // happened to change on 17 Aug. Per `HKLiveWorkoutDataSource.h`, `enableCollection
            // (for:predicate:)` is ADDITIVE — `typesToCollect` starts pre-populated with the
            // activity's defaults, and enabling a type already in that default set just
            // re-applies the (nil) predicate, never removing anything — so this can never
            // suppress a default the app still relies on; it only ever adds explicit types the
            // defaults might not have included (which is exactly what happened before 17 Aug).
            for type in performanceTypes {
                b.dataSource?.enableCollection(for: type, predicate: nil)
            }
            s.delegate = self
            b.delegate = self

            let now = Date()
            writer = SampleWriter(sessionID: sessionID, start: now)
            if writer == nil {
                DiagnosticJournal.shared.checkpoint(
                    diagnostic,
                    "sample_writer_unavailable")
            }
            session = s
            builder = b
            startDate = now
            activityName = name
            activity = activity_
            hrSum = 0; hrCount = 0
            live.energy = 0; live.distance = 0; live.heartRate = 0; live.elapsed = 0
            live.pace = 0; paceSamples.removeAll()
            pauses = []; pausedSince = nil; live.isPaused = false
            sessionIndoor = indoor
            paceWindowMeters = max(100, requestedPaceWindow)
            isPoolSwimming = activity_ == .swimming && swimmingLocation == .pool
            // A pool length is the split interval for swimming. Previously this was guarded by
            // `showsPace`, which is false for swimming, so every pool swim silently had no laps
            // or splits even though its HealthKit configuration supplied the lap length.
            let splitInterval = isPoolSwimming ? lapLengthMeters : (showsPace ? requestedSplitDistance : nil)
            resetSplits(distance: splitInterval)
            hasObservedWaterLock = false
            isSwimTouchInputLocked = activity_ == .swimming
            lastDiagnosticCheckpointMinute = 0
            processedWorkoutEventCount = 0
            observedOpportunisticKinds.removeAll()
            expectedOpportunisticKinds = Self.computeExpectedOpportunisticKinds(activity: activity_, indoor: indoor)

            // Save identity/configuration before starting HealthKit. A relaunch must not invent
            // a second workout ID or overwrite this recording's raw samples.
            try saveRecoveryCheckpoint()
            recoveredSession = false

            s.startActivity(with: now)
            b.beginCollection(withStart: now) { [weak self] succeeded, error in
                Task { @MainActor in
                    guard let self, self.session === s, let diagnostic = self.diagnosticSpan else { return }
                    DiagnosticJournal.shared.checkpoint(
                        diagnostic,
                        succeeded ? "healthkit_collection_started" : "healthkit_collection_failed",
                        attributes: error.map { ["error": $0.localizedDescription] } ?? [:])
                    if !succeeded {
                        self.lastError = error?.localizedDescription ?? "HealthKit couldn’t start recording the workout."
                        s.end()
                        self.sensorsShouldStop(reason: "healthkit_collection_failed", error: error)
                    }
                }
            }
            startSensors(indoor: indoor)
            startTimer()
            isRecording = true
        } catch {
            writer?.close()
            writer = nil
            session = nil
            builder = nil
            startDate = nil
            lastError = "Couldn't start workout: \(error.localizedDescription)"
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .failed,
                reason: "healthkit_session_start_failed",
                attributes: ["error": error.localizedDescription])
            diagnosticSpan = nil
            isPoolSwimming = false
            isSwimTouchInputLocked = false
        }
    }

    private func saveRecoveryCheckpoint() throws {
        guard let startDate else { return }
        let value = WorkoutRecoveryCheckpoint(sessionID: sessionID, start: startDate,
            activityType: activity.rawValue, name: activityName, indoor: sessionIndoor,
            paceWindowMeters: paceWindowMeters, splitDistanceMeters: splitDistanceMeters,
            splits: splits.map { .init(number: $0.number, duration: $0.duration, elapsed: $0.elapsed) },
            splitSampleElapsed: lastSplitSample?.elapsed ?? 0,
            splitSampleDistance: lastSplitSample?.distance ?? 0)
        try recoveryStore.save(value)
    }

    func recoverActiveWorkout() {
        guard !isRecording, !isRecovering, !isFinishing, session == nil, builder == nil else { return }
        isRecovering = true
        healthStore.recoverActiveWorkoutSession { [weak self] recovered, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.isRecovering = false }
                do {
                    if let error { throw error }
                    guard let recovered, let start = recovered.startDate else {
                        throw CocoaError(.coderValueNotFound)
                    }
                    try self.restore(recovered, start: start)
                } catch {
                    // If HealthKit recovered a session but its app-owned recording is not
                    // recoverable, stop its background runtime instead of leaving it orphaned.
                    recovered?.end()
                    self.lastError = "Couldn’t recover the active workout: \(error.localizedDescription)"
                    DiagnosticJournal.shared.record(operation: "workout.capture", name: "recovery_failed",
                        attributes: ["error": error.localizedDescription])
                    WatchSyncManager.shared.queueDiagnosticSnapshot(reason: "workout_recovery_failed")
                }
            }
        }
    }

    private func restore(_ recovered: HKWorkoutSession, start sessionStart: Date) throws {
        let config = recovered.workoutConfiguration
        guard let checkpoint = try recoveryStore.load(),
              checkpoint.matches(start: sessionStart, activityType: config.activityType.rawValue),
              let recoveredWriter = SampleWriter(sessionID: checkpoint.sessionID, start: checkpoint.start, resuming: true) else {
            // Preserve unmatched files. Never stitch another workout's samples into this one.
            throw CocoaError(.fileReadCorruptFile)
        }
        let start = checkpoint.start
        sessionID = checkpoint.sessionID
        startDate = start
        activity = config.activityType
        activityName = checkpoint.name
        sessionIndoor = checkpoint.indoor
        paceWindowMeters = checkpoint.paceWindowMeters
        writer = recoveredWriter
        session = recovered
        let b = recovered.associatedWorkoutBuilder()
        builder = b
        recoveredSession = true
        b.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
        for type in performanceTypes { b.dataSource?.enableCollection(for: type, predicate: nil) }
        isPoolSwimming = activity == .swimming && config.swimmingLocationType == .pool
        isSwimTouchInputLocked = activity == .swimming
        resetSplits(distance: checkpoint.splitDistanceMeters)
        live.splits = checkpoint.splits.map { WorkoutSplit(number: $0.number, duration: $0.duration, elapsed: $0.elapsed) }
        lastSplitSample = (checkpoint.splitSampleElapsed, checkpoint.splitSampleDistance)
        pauses = []; pausedSince = nil
        for event in b.workoutEvents.sorted(by: { $0.dateInterval.start < $1.dateInterval.start }) {
            let offset = max(0, event.dateInterval.start.timeIntervalSince(start))
            if event.type == .pause { pausedSince = pausedSince ?? offset }
            if event.type == .resume, let since = pausedSince {
                pauses.append(FitnessPause(start: since, end: offset))
                pausedSince = nil
            }
        }
        live.isPaused = recovered.state == .paused
        if live.isPaused, pausedSince == nil { pausedSince = Date().timeIntervalSince(start) }
        if !live.isPaused { pausedSince = nil }
        live.elapsed = WorkoutPauses.activeElapsed(wall: Date().timeIntervalSince(start), pauses: pauses, openSince: pausedSince)
        diagnosticSpan = DiagnosticJournal.shared.startSpan("workout.capture", attributes: [
            "session_id": sessionID.uuidString.lowercased(), "recovered": "true",
            "buffer_tail_may_be_missing": "true"
        ])
        processedWorkoutEventCount = b.workoutEvents.count
        expectedOpportunisticKinds = Self.computeExpectedOpportunisticKinds(activity: activity, indoor: sessionIndoor)
        // The associated builder retains cumulative statistics; do not begin a new collection.
        for type in readTypes.compactMap({ $0 as? HKQuantityType }) {
            if let stats = b.statistics(for: type) { handleStatistics(type, stats) }
        }
        recovered.delegate = self
        b.delegate = self
        isAuthorized = true
        isRecording = true
        WatchSyncManager.shared.announceWorkoutStarted(id: sessionID, start: start)
        startTimer()
        if !live.isPaused { startSensors(indoor: sessionIndoor) }
        if recovered.state == .ended || recovered.state == .stopped {
            sensorsShouldStop(reason: "recovered_ended_session")
        }
    }

    /// Water Lock can only be enabled once HealthKit has moved the session to `.running`.
    /// `startActivity(with:)` is asynchronous, so requesting it immediately after that call can be
    /// silently ignored while the session is still starting.
    private func enableWaterLockIfNeeded(for activeSession: HKWorkoutSession) {
        guard activeSession === session, activity == .swimming else { return }
        let device = WKInterfaceDevice.current()
        if !device.isWaterLockEnabled {
            device.enableWaterLock()
        }
        if device.isWaterLockEnabled {
            hasObservedWaterLock = true
            if !isSwimTouchInputLocked { isSwimTouchInputLocked = true }
        }
        startWaterLockMonitoring()
        if let diagnosticSpan {
            DiagnosticJournal.shared.checkpoint(
                diagnosticSpan,
                "water_lock_requested",
                attributes: ["enabled": device.isWaterLockEnabled ? "true" : "false"])
        }
    }

    /// The 0.25s cadence used only while Water Lock hasn't been confirmed active yet — brief
    /// (typically under a couple of seconds), so sub-second responsiveness here doesn't cost much.
    private static let waterLockPollingInterval: TimeInterval = 0.25
    /// Once Water Lock is confirmed active, the shield only needs to react to a Crown-unlock —
    /// an explicit, deliberate gesture, not something that needs 4 Hz responsiveness. Dropping to
    /// 1 Hz here (also a harmonic of the existing elapsed-time timer) cuts a 45-90 min pool swim
    /// from ~10,800-21,600 main-actor timer fires down to a few hundred, for the same UX.
    private static let waterLockSteadyStateInterval: TimeInterval = 1.0

    /// Water Lock is owned by watchOS, including its crown-to-eject-water interaction. Polling
    /// its state is only used to make the app's transparent touch shield match that system state:
    /// no workout controls can receive a stray wet-screen gesture before lock comes up, and the
    /// shield releases as soon as the swimmer has intentionally cleared it with the Crown.
    private func startWaterLockMonitoring() {
        startWaterLockMonitoring(interval: Self.waterLockPollingInterval)
    }

    private func startWaterLockMonitoring(interval: TimeInterval) {
        waterLockTimer?.invalidate()
        waterLockTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording, self.activity == .swimming else { return }
                let device = WKInterfaceDevice.current()
                if device.isWaterLockEnabled {
                    let wasAlreadyObserved = self.hasObservedWaterLock
                    self.hasObservedWaterLock = true
                    if !self.isSwimTouchInputLocked { self.isSwimTouchInputLocked = true }
                    if !wasAlreadyObserved, interval != Self.waterLockSteadyStateInterval {
                        self.startWaterLockMonitoring(interval: Self.waterLockSteadyStateInterval)
                    }
                } else if self.hasObservedWaterLock {
                    // The only supported way out of Water Lock is the system Crown gesture.
                    if self.isSwimTouchInputLocked { self.isSwimTouchInputLocked = false }
                } else {
                    // The session can reach `.running` a beat before watchOS accepts the first
                    // request. Keep the screen inert and retry until it does.
                    device.enableWaterLock()
                }
            }
        }
        waterLockTimer?.tolerance = interval == Self.waterLockPollingInterval ? 0.05 : 0.2
    }

    private func stopWaterLockMonitoring() {
        waterLockTimer?.invalidate()
        waterLockTimer = nil
        hasObservedWaterLock = false
        isSwimTouchInputLocked = false
    }

    #if DEBUG
    /// Simulator-only: fake an in-progress workout so the redesigned active-workout screen
    /// can be reviewed without a real `HKWorkoutSession` (which the Simulator can't run).
    /// Ticks elapsed/HR/energy/distance so the live metrics animate.
    func startFakeWorkout(splitDistanceMeters: Double, poolSwimming: Bool = false) {
        guard !isRecording else { return }
        isAuthorized = true
        isRecording = true
        // Mid-run, not from zero: the screenshot is taken about four seconds after launch.
        let seeded: TimeInterval = 32 * 60 + 18
        startDate = Date().addingTimeInterval(-seeded)
        pauses = []; pausedSince = nil; live.isPaused = false
        live.elapsed = seeded
        live.heartRate = 128
        live.energy = 402
        live.distance = 5_240
        live.pace = 0; paceSamples.removeAll()
        activityName = poolSwimming ? "Pool Swim" : "Running"
        activity = ProcessInfo.processInfo.arguments.contains("--strength-workout") ? .traditionalStrengthTraining : poolSwimming ? .swimming : .running
        isPoolSwimming = poolSwimming
        resetSplits(distance: showsRestTimer ? nil : splitDistanceMeters)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.startDate, !self.live.isPaused else { return }
                self.live.elapsed = WorkoutPauses.activeElapsed(wall: Date().timeIntervalSince(start),
                                                                pauses: self.pauses, openSince: nil)
                self.live.heartRate = 120 + 20 * sin(self.live.elapsed / 12)   // drifts 100–140 bpm
                self.live.energy = self.live.elapsed * 0.18
                // Speed drifts around ~2.8 m/s (a shade under 10 min/mile) so the rolling pace
                // visibly moves — a pace that never changes would prove nothing.
                let speed = 2.8 + 0.4 * sin(self.live.elapsed / 20)
                self.live.distance += speed
                self.updatePace()
                self.updateSplits()
            }
        }
    }

    /// Seed enough deterministic data to visually verify all recent-split rows in the Simulator.
    func debugSeedSplits() {
        guard let splitDistanceMeters else { return }
        live.elapsed = 31 * 60 + 24
        startDate = Date().addingTimeInterval(-elapsed)
        live.distance = splitDistanceMeters * 3.42
        updatePace()
        updateSplits()
    }
    #endif

    func stop() {
        cancelRest()
        #if DEBUG
        if session == nil, isRecording {            // fake workout — just tear down the UI state
            isRecording = false
            timer?.invalidate(); timer = nil
            startDate = nil
            pauses = []; pausedSince = nil; live.isPaused = false
            return
        }
        #endif
        guard isRecording, let s = session, let b = builder, let start = startDate else { return }
        if let diagnosticSpan {
            DiagnosticJournal.shared.checkpoint(
                diagnosticSpan,
                "user_requested_stop",
                attributes: workoutDiagnosticAttributes())
        }
        isFinishing = true
        isRecording = false
        stopSensors()               // no more motion/location appends after this
        timer?.invalidate(); timer = nil
        stopWaterLockMonitoring()

        let end = Date()
        s.end()
        b.endCollection(withEnd: end) { [weak self] succeeded, error in
            // Hub-and-spoke: the phone is the sole HealthKit writer. We run the session
            // purely for background runtime + live sensors and do NOT finishWorkout(), so
            // no HKWorkout is saved here — the phone writes the single record from our
            // streamed samples. (Avoids duplicate/round-trip editing of HealthKit.)
            Task { @MainActor in
                guard let self, self.session === s else { return }
                self.finalize(
                    start: start,
                    end: end,
                    requestedStatus: succeeded ? .succeeded : .failed,
                    reason: succeeded ? "user_stopped" : "healthkit_end_collection_failed",
                    error: error)
            }
        }
    }

    private func finalize(
        start: Date,
        end: Date,
        requestedStatus: DiagnosticSpanStatus,
        reason: String,
        error: Error? = nil
    ) {
        writer?.close()
        let sampleCount = writer?.count ?? 0
        let transferURL = writer?.compressedForTransfer()
        // Ended while paused: that pause runs to the end, and is left out like the others.
        let recordedPauses = WorkoutPauses.closed(pauses, openSince: pausedSince, at: end.timeIntervalSince(start))
        let summary = WorkoutSummary(
            id: sessionID, start: start, end: end, activity: activityName,
            avgHeartRate: recoveredSession
                ? builder?.statistics(for: hrType)?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                : hrCount > 0 ? hrSum / Double(hrCount) : nil,
            totalEnergy: energy, totalDistance: distance,
            sampleCount: sampleCount,
            poolLengthMeters: isPoolSwimming ? splitDistanceMeters : nil,
            lapDurations: isPoolSwimming ? splits.map(\.duration) : [],
            traceparent: diagnosticSpan?.context.traceparent,
            pauses: recordedPauses
        )
        savedSessions.insert(summary, at: 0)
        let summarySaved = summaryStore.save(savedSessions)
        WatchSyncManager.shared.announceWorkoutEnded(summary)

        if let url = transferURL {
            WatchSyncManager.shared.sendWorkout(fileURL: url, summary: summary)
        }
        if let diagnosticSpan {
            // See `expectedOpportunisticKinds`'s doc comment: HealthKit reports neither a read
            // denial nor an unsupported-type error, so a genuinely missing grant and a type this
            // activity simply never produces are otherwise indistinguishable from "just didn't
            // show up". This is what makes that gap visible, dated, instead of silent — the same
            // role `gyroscope_silent` plays for CoreMotion.
            let missingOpportunisticKinds = expectedOpportunisticKinds.subtracting(observedOpportunisticKinds)
            if !missingOpportunisticKinds.isEmpty {
                DiagnosticJournal.shared.checkpoint(
                    diagnosticSpan,
                    "opportunistic_signals_silent",
                    attributes: ["missing": missingOpportunisticKinds.map(\.rawValue).sorted().joined(separator: ",")])
            }
            var attributes = workoutDiagnosticAttributes()
            attributes["sample_count"] = String(sampleCount)
            attributes["sample_file_available"] = transferURL == nil ? "false" : "true"
            if let error {
                let failure = error as NSError
                attributes["error"] = failure.localizedDescription
                attributes["error_domain"] = failure.domain
                attributes["error_code"] = String(failure.code)
                attributes["error_user_info_keys"] = failure.userInfo.keys.sorted().joined(separator: ",")
                if let reason = failure.localizedFailureReason { attributes["error_failure_reason"] = reason }
                if let suggestion = failure.localizedRecoverySuggestion { attributes["error_recovery_suggestion"] = suggestion }
                if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                    attributes["underlying_error_domain"] = underlying.domain
                    attributes["underlying_error_code"] = String(underlying.code)
                }
            }
            let status: DiagnosticSpanStatus =
                requestedStatus == .succeeded && transferURL != nil ? .succeeded : .failed
            let finalReason = transferURL == nil ? "sample_file_unavailable" : reason
            DiagnosticJournal.shared.finish(
                diagnosticSpan,
                status: status,
                reason: finalReason,
                attributes: attributes)
            if status == .failed {
                WatchSyncManager.shared.queueDiagnosticSnapshot(reason: finalReason)
            }
        }
        diagnosticSpan = nil
        // The saved summary and transfer queue own the recording now. A stale callback must
        // never remove a later session's checkpoint.
        if summarySaved { try? recoveryStore.remove(sessionID: sessionID) }
        writer = nil
        session = nil
        builder = nil
        startDate = nil
        isPoolSwimming = false
        pauses = []; pausedSince = nil; live.isPaused = false
        isFinishing = false
    }

    // MARK: - Pause and resume

    /// Pause, or carry on: the button on the workout's second page, and both of the Watch's
    /// buttons pressed together (the system's own gesture, which is all there is in Water Lock).
    func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    /// Stop the clock and stop recording, until `resume()`. Take a call mid-workout and the
    /// minutes on the phone aren't part of it.
    func pause() {
        guard isRecording, !isPaused, let start = startDate else { return }
        notePaused(at: Date().timeIntervalSince(start))
        session?.pause()
    }

    func resume() {
        guard isRecording, isPaused, let start = startDate else { return }
        noteResumed(at: Date().timeIntervalSince(start))
        session?.resume()
    }

    /// Paused at `offset` seconds after the start: by the button, or by the system (the session's
    /// delegate reports both; whichever comes second finds it already done).
    private func notePaused(at offset: TimeInterval) {
        guard isRecording, !live.isPaused else { return }
        live.elapsed = WorkoutPauses.activeElapsed(wall: offset, pauses: pauses, openSince: nil)
        pausedSince = offset
        live.isPaused = true
        // Nothing is recorded while paused, and the sensors don't run for nothing.
        if session != nil { stopSensors() }
        if let diagnosticSpan {
            DiagnosticJournal.shared.checkpoint(diagnosticSpan, "paused", attributes: workoutDiagnosticAttributes())
        }
    }

    private func noteResumed(at offset: TimeInterval) {
        guard isRecording, live.isPaused else { return }
        if let since = pausedSince, offset > since { pauses.append(FitnessPause(start: since, end: offset)) }
        pausedSince = nil
        live.isPaused = false
        if session != nil { startSensors(indoor: sessionIndoor) }
        if let diagnosticSpan {
            DiagnosticJournal.shared.checkpoint(diagnosticSpan, "resumed", attributes: workoutDiagnosticAttributes())
        }
    }

    // MARK: - Sensors (append directly on the callback thread — accurate timestamps)

    /// How long to wait after starting raw gyro updates before concluding it isn't actually
    /// delivering samples — long enough that a slow first callback isn't mistaken for silence,
    /// short enough that the orientation fallback (below) engages early in the workout rather
    /// than after most of it has already gone unrecorded.
    private static let gyroSilenceCheckDelay: TimeInterval = 4

    private func startSensors(indoor: Bool) {
        let w = writer
        // We store raw acceleration + rotation only. `deviceMotion` also runs Apple's fused
        // attitude/magnetometer pipeline, then we discarded those results — needless sustained
        // compute for the entire workout. See `startOrientationFallback` for when that trade-off
        // no longer holds.
        if motion.isAccelerometerAvailable {
            motion.startAccelerometerUpdates(to: motionQueue) { sample, _ in
                guard let a = sample?.acceleration else { return }
                w?.append(.accel, v1: a.x, v2: a.y, v3: a.z)
            }
        } else if let diagnosticSpan {
            DiagnosticJournal.shared.checkpoint(diagnosticSpan, "accelerometer_unavailable")
        }

        if motion.isGyroAvailable {
            gyroSampleObserved.withLock { $0 = false }
            let observed = gyroSampleObserved
            // Thread-confined to this closure's serial `motionQueue` delivery — no lock needed
            // for this half. It exists only so the shared, lock-protected `observed` flag (read
            // by the main-actor silence check below) is written once, not on every one of the
            // ~24.9 Hz samples for the rest of the workout.
            var loggedObservation = false
            motion.startGyroUpdates(to: motionQueue) { sample, _ in
                guard let r = sample?.rotationRate else { return }
                if !loggedObservation {
                    loggedObservation = true
                    observed.withLock { $0 = true }
                }
                w?.append(.gyro, v1: r.x, v2: r.y, v3: r.z)
            }
            // Every recording since 2026-07-24 has exactly zero gyro samples, across every
            // activity, indoor and outdoor alike, while this code never changed — so the cause is
            // device or OS state, most likely Low Power Mode or a watchOS change. Which of the two
            // shapes it takes is precisely what we could not tell: whether `isGyroAvailable` was
            // already false, or whether it was true and the sensor simply never delivered. Both
            // ended as an indistinguishable zero. That is what these checkpoints settle, and the
            // fallback covers either case. Give it a few seconds, then check.
            gyroSilenceCheckTimer?.invalidate()
            gyroSilenceCheckTimer = Timer.scheduledTimer(
                withTimeInterval: Self.gyroSilenceCheckDelay, repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording else { return }
                    self.gyroSilenceCheckTimer = nil
                    guard !observed.withLock({ $0 }) else { return }
                    if let diagnosticSpan = self.diagnosticSpan {
                        DiagnosticJournal.shared.checkpoint(diagnosticSpan, "gyroscope_silent")
                    }
                    self.startOrientationFallback()
                }
            }
        } else {
            if let diagnosticSpan {
                DiagnosticJournal.shared.checkpoint(diagnosticSpan, "gyroscope_unavailable")
            }
            startOrientationFallback()
        }

        // Continuous best-accuracy GNSS is the most expensive thing a Watch can do, and indoors it
        // buys nothing but drifting fixes. The `indoor` flag was already threaded into the workout
        // configuration — startSensors just never read it.
        guard !indoor else { return }
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        locationManager.distanceFilter = 5      // metres; no filter meant a callback per fix
        locationManager.startUpdatingLocation()

        // Absolute (sea-level-relative) altitude, not relative — comparable to GPS altitude
        // rather than a per-workout 0-reset, and directly analogous to what `.altitude` already
        // records. Gated to outdoor only, same as GPS just above: this is a genuinely new sensor
        // subscription (nothing else in this recorder already runs the barometer), so it isn't
        // paid for on an indoor/strength/yoga session that has no elevation to speak of.
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            barometricAltitudeObserved.withLock { $0 = false }
            let altObserved = barometricAltitudeObserved
            altimeter.startAbsoluteAltitudeUpdates(to: motionQueue) { [weak self] data, _ in
                guard let data else { return }
                w?.append(.barometricAltitude, v1: data.altitude)
                // Delivered at ~1 Hz for the whole outdoor portion of the workout, so this must
                // stay a cheap check-and-set on `motionQueue` — spawning a `Task { @MainActor }`
                // per sample (as this once did) meant ~4,500 Task allocations/hour for a
                // one-shot "seen" flag only ever read at `finalize()`.
                var flipped = false
                altObserved.withLock { if !$0 { $0 = true; flipped = true } }
                if flipped {
                    Task { @MainActor in self?.observedOpportunisticKinds.insert(.barometricAltitude) }
                }
            }
        } else if let diagnosticSpan {
            DiagnosticJournal.shared.checkpoint(diagnosticSpan, "barometric_altitude_unavailable")
        }
    }

    /// Fallback for when raw gyro is unavailable, or is available but isn't actually delivering
    /// samples (see `startSensors`). Without SOME source of orientation the wrist's real 3D path
    /// can't be reconstructed at all — a spike proved this quantitatively (cycle-local double
    /// integration with closure was barely distinguishable from time-shuffled noise) — so this
    /// pays the `deviceMotion` cost the comment above deliberately avoided, but only when raw
    /// gyro has genuinely failed, and only for orientation: no other device-motion field is read.
    ///
    /// Reference frame `.xArbitraryZVertical` is the one CoreMotion offers that never touches the
    /// magnetometer — a pool deck (the activity this gap was found on) is full of metal (ladders,
    /// lane-rope anchors, filtration hardware), and the compass-corrected frames would silently
    /// degrade there rather than failing loud.
    private func startOrientationFallback() {
        guard motion.isDeviceMotionAvailable else { return }
        let w = writer
        motion.deviceMotionUpdateInterval = 1.0 / 25.0   // match the accelerometer's rate
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { sample, _ in
            guard let q = sample?.attitude.quaternion else { return }
            let v = RotationVector.encode(x: q.x, y: q.y, z: q.z, w: q.w)
            w?.append(.orientation, v1: v.x, v2: v.y, v3: v.z)
        }
    }

    private func stopSensors() {
        gyroSilenceCheckTimer?.invalidate()
        gyroSilenceCheckTimer = nil
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        motion.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
        altimeter.stopAbsoluteAltitudeUpdates()   // no-op if never started (indoor workout)
    }

    /// Idempotent teardown for a session that ended without the user tapping stop.
    ///
    /// Beyond stopping the sensors (the battery half), finish the recording too: without this,
    /// a HealthKit-ended session left `isRecording` frozen true, the SampleWriter's FileHandle
    /// open with its buffer tail unflushed, and the whole workout unsaved and unsent. The
    /// `isRecording` guard makes the normal path safe — `stop()` clears it before HK's `.ended`
    /// delegate lands here, so nothing finalizes twice.
    func sensorsShouldStop(reason: String, error: Error? = nil) {
        cancelRest()
        stopSensors()
        timer?.invalidate()
        timer = nil
        stopWaterLockMonitoring()
        guard isRecording, let start = startDate else { return }
        isRecording = false
        finalize(
            start: start,
            end: Date(),
            requestedStatus: .failed,
            reason: reason,
            error: error)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop; avoid allocating and scheduling a new Task for
            // every elapsed-time tick throughout every workout.
            MainActor.assumeIsolated {
                // Paused: the clock stands where it stopped.
                guard let self, let start = self.startDate, !self.live.isPaused else { return }
                self.live.elapsed = WorkoutPauses.activeElapsed(wall: Date().timeIntervalSince(start),
                                                                pauses: self.pauses, openSince: nil)
                let minute = Int(self.elapsed / 60)
                if minute > self.lastDiagnosticCheckpointMinute,
                   let diagnosticSpan = self.diagnosticSpan {
                    self.lastDiagnosticCheckpointMinute = minute
                    DiagnosticJournal.shared.checkpoint(
                        diagnosticSpan,
                        "workout_minute",
                        attributes: self.workoutDiagnosticAttributes())
                }
            }
        }
        timer?.tolerance = 0.15
    }

    private func workoutDiagnosticAttributes() -> [String: String] {
        [
            "elapsed_seconds": String(Int(elapsed)),
            "distance_meters": String(Int(distance)),
            "heart_rate_bpm": String(Int(heartRate)),
            "sample_count": String(writer?.count ?? 0),
        ]
    }

    /// Pace over a fixed rolling distance (¼ mile or 400 m), rather than an arbitrary time span.
    /// HealthKit may publish cumulative distance in batches; a substantial fixed window prevents
    /// one late batch or GPS wobble from making the watch-face value jump wildly.
    private func updatePace() {
        paceSamples.append((t: elapsed, d: distance))
        guard let last = paceSamples.last, last.d >= paceWindowMeters else { return }
        let targetDistance = last.d - paceWindowMeters

        // Keep the sample immediately before the target, which lets us interpolate the exact
        // ¼-mile/400m boundary even when HealthKit reports distance in coarse batches.
        while paceSamples.count > 1 && paceSamples[1].d <= targetDistance {
            paceSamples.removeFirst()
        }
        guard let first = paceSamples.first else { return }
        let windowStart: TimeInterval
        if paceSamples.count > 1, first.d < targetDistance {
            let next = paceSamples[1]
            let distanceDelta = next.d - first.d
            let fraction = distanceDelta > 0 ? (targetDistance - first.d) / distanceDelta : 0
            windowStart = first.t + (next.t - first.t) * min(1, max(0, fraction))
        } else {
            windowStart = first.t
        }
        let duration = last.t - windowStart
        guard duration >= 20 else { return }
        live.pace = duration / paceWindowMeters
    }

    private func resetSplits(distance: Double?) {
        live.splitDistanceMeters = distance
        live.splits.removeAll(keepingCapacity: true)
        lastSplitSample = distance == nil ? nil : (elapsed: 0, distance: 0)
    }

    /// HealthKit publishes cumulative distance in batches. Interpolate each threshold crossing
    /// within that batch so a late callback does not make the completed split artificially slow.
    private func updateSplits() {
        guard let interval = splitDistanceMeters, interval > 0 else { return }
        let previousCount = splits.count
        let previous = lastSplitSample ?? (elapsed: 0, distance: 0)
        guard distance >= previous.distance else {
            lastSplitSample = (elapsed: elapsed, distance: distance)
            return
        }

        let distanceDelta = distance - previous.distance
        let elapsedDelta = max(0, elapsed - previous.elapsed)
        var threshold = Double(splits.count + 1) * interval

        while threshold <= distance {
            let fraction = distanceDelta > 0
                ? min(1, max(0, (threshold - previous.distance) / distanceDelta))
                : 1
            let crossingElapsed = previous.elapsed + elapsedDelta * fraction
            let priorCrossing = splits.last?.elapsed ?? 0
            live.splits.append(WorkoutSplit(
                number: splits.count + 1,
                duration: max(0, crossingElapsed - priorCrossing),
                elapsed: crossingElapsed
            ))
            threshold = Double(splits.count + 1) * interval
        }

        lastSplitSample = (elapsed: elapsed, distance: distance)
        if splits.count != previousCount {
            do { try saveRecoveryCheckpoint() }
            catch {
                DiagnosticJournal.shared.record(operation: "workout.capture", name: "recovery_checkpoint_failed",
                    attributes: ["error": error.localizedDescription])
            }
        }
    }

    /// kcal/(kg·hr) — the unit `HKUnit.h` documents for `HKQuantityTypeIdentifierPhysicalEffort`.
    /// Composed via `HKUnit` algebra (not the string-parsing `HKUnit(from:)` initializer) so a
    /// typo in the unit string would be a compile error, not a runtime one.
    private static let physicalEffortUnit = HKUnit.kilocalorie()
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))

    fileprivate func handleStatistics(_ type: HKQuantityType, _ stats: HKStatistics) {
        if type == hrType, let q = stats.mostRecentQuantity() {
            let bpm = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            live.heartRate = bpm
            hrSum += bpm; hrCount += 1
            writer?.append(.heartRate, v1: bpm)
        } else if type == energyType, let q = stats.sumQuantity() {
            live.energy = q.doubleValue(for: .kilocalorie())
            writer?.append(.energy, v1: energy)
        } else if distanceTypes.contains(type), let q = stats.sumQuantity() {
            live.distance = q.doubleValue(for: .meter())
            writer?.append(.distance, v1: distance)
            updatePace()
            updateSplits()
        } else if (type == runningSpeedType || type == cyclingSpeedType), let q = stats.mostRecentQuantity() {
            writer?.append(.speed, v1: max(0, q.doubleValue(for: .meter().unitDivided(by: .second()))))
        } else if (type == runningPowerType || type == cyclingPowerType), let q = stats.mostRecentQuantity() {
            writer?.append(.power, v1: max(0, q.doubleValue(for: .watt())))
        } else if type == cyclingCadenceType, let q = stats.mostRecentQuantity() {
            writer?.append(.cadence, v1: max(0, q.doubleValue(for: .count().unitDivided(by: .minute()))))
        } else if type == strideLengthType, let q = stats.mostRecentQuantity() {
            writer?.append(.strideLength, v1: q.doubleValue(for: .meter()))
        } else if type == verticalOscillationType, let q = stats.mostRecentQuantity() {
            writer?.append(.verticalOscillation, v1: q.doubleValue(for: .meter()))
        } else if type == groundContactType, let q = stats.mostRecentQuantity() {
            writer?.append(.groundContactTime, v1: q.doubleValue(for: .second()))
        } else if type == strokeCountType, let q = stats.sumQuantity() {
            writer?.append(.strokeCount, v1: q.doubleValue(for: .count()))
        } else if type == stepCountType, let q = stats.sumQuantity() {
            writer?.append(.stepCount, v1: q.doubleValue(for: .count()))
            observedOpportunisticKinds.insert(.stepCount)
        } else if type == physicalEffortType, let q = stats.mostRecentQuantity() {
            writer?.append(.physicalEffort, v1: max(0, q.doubleValue(for: Self.physicalEffortUnit)))
            observedOpportunisticKinds.insert(.physicalEffort)
        } else if type == estimatedEffortType, let q = stats.mostRecentQuantity() {
            writer?.append(.effortScore, v1: max(0, q.doubleValue(for: .appleEffortScore())))
            observedOpportunisticKinds.insert(.effortScore)
        } else if type == perfusionIndexType, let q = stats.mostRecentQuantity() {
            // `.percent()` is HealthKit's 0.0-1.0 fraction convention (100% == 1.0), but
            // `FitnessSample.Kind.perfusionIndex`'s contract is a plain percent number
            // (`v1 = %`) — scale here so a caller can format `v1` directly, e.g. "1.4%".
            writer?.append(.perfusionIndex, v1: max(0, q.doubleValue(for: .percent()) * 100))
            observedOpportunisticKinds.insert(.perfusionIndex)
        } else if type == underwaterDepthType, let q = stats.mostRecentQuantity() {
            writer?.append(.underwaterDepth, v1: max(0, q.doubleValue(for: .meter())))
            observedOpportunisticKinds.insert(.underwaterDepth)
        } else if type == waterTemperatureType, let q = stats.mostRecentQuantity() {
            writer?.append(.waterTemperature, v1: q.doubleValue(for: .degreeCelsius()))
            observedOpportunisticKinds.insert(.waterTemperature)
        }
    }

    /// Only the events newer than `processedWorkoutEventCount` are inspected — see the delegate
    /// method's doc comment for why (the array is re-delivered in full each call). One
    /// `.strokeStyle` sample is appended per completed lap whose metadata carries a recognized
    /// `HKSwimmingStrokeStyle`; a lap with no stroke-style metadata (or a raw value HealthKit adds
    /// a case for later, that this SDK doesn't recognize) is skipped, not force-cast into garbage.
    fileprivate func handleNewWorkoutEvents(_ events: [HKWorkoutEvent]) {
        guard events.count > processedWorkoutEventCount else { return }
        for event in events[processedWorkoutEventCount...] {
            guard event.type == .lap,
                  let raw = event.metadata?[HKMetadataKeySwimmingStrokeStyle] as? Int,
                  let style = HKSwimmingStrokeStyle(rawValue: raw) else { continue }
            writer?.append(.strokeStyle, v1: Double(style.rawValue))
            observedOpportunisticKinds.insert(.strokeStyle)
        }
        processedWorkoutEventCount = events.count
    }
}

// MARK: - HealthKit delegates

extension WorkoutRecorder: HKLiveWorkoutBuilderDelegate {
    /// Swim stroke style isn't a `didCollectDataOf` quantity — it's metadata
    /// (`HKMetadataKeySwimmingStrokeStyle`) on each completed lap's `HKWorkoutEvent`, delivered
    /// through this separate delegate callback. `workoutEvents` is re-delivered in full on every
    /// call (any event type, not just laps), so `processedWorkoutEventCount` is what keeps this
    /// from re-appending the same lap's stroke style each time a later, unrelated event arrives.
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        let events = workoutBuilder.workoutEvents
        Task { @MainActor in
            guard self.builder === workoutBuilder else { return }
            self.handleNewWorkoutEvents(events)
        }
    }

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // Gather every type this callback reported first, then hop to the main actor once — a
        // single HealthKit callback commonly reports heartRate+energy+distance together, and
        // handleStatistics() (WorkoutLiveMetrics's published fields) doesn't need a separate
        // Task/objectWillChange per type.
        var pairs: [(HKQuantityType, HKStatistics)] = []
        for type in collectedTypes {
            guard let qType = type as? HKQuantityType,
                  let stats = workoutBuilder.statistics(for: qType) else { continue }
            pairs.append((qType, stats))
        }
        guard !pairs.isEmpty else { return }
        Task { @MainActor in
            guard self.builder === workoutBuilder else { return }
            for (qType, stats) in pairs { self.handleStatistics(qType, stats) }
        }
    }
}

extension WorkoutRecorder: HKWorkoutSessionDelegate {
    /// stopSensors() used to be reachable only from the user tapping stop. If the session ended any
    /// other way — HealthKit ended it, the system killed it — CoreMotion kept delivering at 25Hz and
    /// the GPS kept running at best accuracy, indefinitely, until the app was killed.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        // Keep the exact system transition time and state, including an ended callback
        // after failure finalization has cleared diagnosticSpan. No per-tick logging.
        Task { @MainActor in
            DiagnosticJournal.shared.record(
                operation: "workout.session",
                name: "healthkit_state_changed",
                attributes: [
                    "from_state": String(fromState.rawValue),
                    "to_state": String(toState.rawValue),
                    "transition_unix_seconds": String(date.timeIntervalSince1970),
                    "session_start_unix_seconds": workoutSession.startDate.map { String($0.timeIntervalSince1970) } ?? "unknown",
                    "recording": self.isRecording ? "true" : "false",
                ])
        }
        if toState == .running {
            Task { @MainActor in
                guard self.session === workoutSession else { return }
                self.enableWaterLockIfNeeded(for: workoutSession)
                if fromState != .paused, let start = self.startDate {
                    WatchSyncManager.shared.announceWorkoutStarted(id: self.sessionID, start: start)
                }
                // Running again after a pause the system made: carry on here too.
                if fromState == .paused, let start = self.startDate {
                    self.noteResumed(at: date.timeIntervalSince(start))
                }
            }
            return
        }
        if toState == .paused {
            Task { @MainActor in
                guard self.session === workoutSession else { return }
                if let start = self.startDate { self.notePaused(at: date.timeIntervalSince(start)) }
            }
            return
        }
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.sensorsShouldStop(
                reason: "healthkit_session_ended",
                error: nil)
        }
    }

    /// Both buttons pressed together: the Watch's own way to pause a workout, and the only way
    /// while Water Lock has the screen.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didGenerate event: HKWorkoutEvent) {
        guard event.type == .pauseOrResumeRequest else { return }
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.togglePause()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.lastError = error.localizedDescription
            self.sensorsShouldStop(
                reason: "healthkit_session_failed",
                error: error)
        }
    }
}

// MARK: - Location delegate

extension WorkoutRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // writer is stable while recording; sensors are stopped before it's cleared.
        Task { @MainActor in
            self.writer?.append(.location, v1: loc.coordinate.latitude, v2: loc.coordinate.longitude, v3: max(0, loc.speed))
            if loc.verticalAccuracy >= 0 { self.writer?.append(.altitude, v1: loc.altitude) }
        }
    }
}

/// Persists lightweight workout summaries on the Watch (no raw samples).
private struct SummaryStore {
    private var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = dir.appendingPathComponent("workout_summaries.json")
        HealthFileProtection.protectExisting(file)
        return file
    }

    func load() -> [WorkoutSummary] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WorkoutSummary].self, from: data) else { return [] }
        return decoded
    }

    @discardableResult func save(_ summaries: [WorkoutSummary]) -> Bool {
        do {
            try HealthFileProtection.write(try JSONEncoder().encode(summaries), to: url)
            return true
        } catch { return false }
    }
}
