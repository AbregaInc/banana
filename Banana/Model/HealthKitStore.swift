import Foundation
import HealthKit
import CoreLocation

// HealthWorkout and its supporting trend types (MetricPoint, RhythmHealth, HealthTrends,
// MetricKind) moved to HealthWorkout.swift — see that file's header comment.

/// Reads workouts + daily health-metric trends from Apple Health and caches them
/// for offline review. Read-only; aggregates every source that writes to Health.
@MainActor
final class HealthKitStore: ObservableObject {
    /// Hidden-filtered view of `allWorkouts` — this is what every UI (Fitness, Mac Workouts,
    /// Rhythm, the morning briefing, the post-workout review coordinator) reads, so a hide
    /// takes effect everywhere at once without each call site filtering it out itself.
    @Published private(set) var workouts: [HealthWorkout] = []
    /// The full imported cache, hidden entries included — the anchored-query merge base and
    /// the only place a hidden workout still lives (so `unhide` can bring it back without a
    /// fresh HealthKit import, which an anchored query wouldn't even offer again).
    private var allWorkouts: [HealthWorkout] = []
    /// Workouts the owner asked Banana to hide instead of delete (source app isn't Banana, so
    /// HealthKit deletion isn't allowed — see `canDeleteFromHealth`). The phone sends this to
    /// the other devices as part of the health snapshot; a hide made on an iPad or the Mac is
    /// asked of the phone (`HealthRemovalInbox`), which hides it and sends it on. Never deletes
    /// anything in Apple Health itself.
    @Published private(set) var hiddenWorkoutIDs: Set<UUID> = []
    /// Tombstones for a Banana-summary delete whose paired HealthKit workout hadn't imported
    /// yet — see `expectRemoval`. Device-local only; not part of the synced snapshot.
    private var pendingRemovals: [PendingRemoval] = []
    /// The trends as read or adopted here; `trends` is what's shown.
    private var storedTrends = HealthTrends() { didSet { showTrends() } }
    @Published private(set) var trends = HealthTrends()

    private func showTrends() {
        trends = showsNoHealth ? HealthTrends() : storedTrends
    }
    /// An iPad or a Mac without the Health consent shows no Health (DATA-PLATFORM.md §7, with
    /// the data platform on, `SpaceSyncFlag`): the cache stays, out of sight. Set by the data platform.
    @Published private(set) var showsNoHealth = false

    func setShowsNoHealth(_ hidden: Bool) {
        guard hidden != showsNoHealth, !(hidden && DeviceRole.current.isHub) else { return }
        showsNoHealth = hidden
        refreshVisibleWorkouts()
        showTrends()
    }
    @Published private(set) var isImporting = false
    @Published private(set) var didAttemptImport = false   // true once a read has run (for empty-state guidance)
    @Published var errorMessage: String?

    /// Whether this device reads (and writes) Apple Health itself. Only the phone does: an iPad
    /// has a Health database too, but it works from the phone's synced copy like the Mac —
    /// otherwise it would import its own (possibly partial) history, publish it over the phone's,
    /// and write, trim and delete workouts a second time.
    let isAvailable = HKHealthStore.isHealthDataAvailable() && DeviceRole.current.isHub
    private let store = HKHealthStore()
    private let fileURL: URL
    private var workoutAnchorData: Data?
    private var lastRefreshAt: Date?
    private var refreshTask: Task<Void, Never>?
    private static let maxPendingRemovals = 50
    private struct RangeKey: Hashable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var bucket: Int
    }
    private struct MetricRangeKey: Hashable, Sendable {
        var range: RangeKey
        var kind: MetricKind
    }
    private struct Cached<Value> {
        var value: Value
        var fetchedAt: Date
    }
    private var rhythmCache: [RangeKey: Cached<RhythmHealth>] = [:]
    private var metricCache: [MetricRangeKey: Cached<[MetricPoint]>] = [:]
    private var rhythmTasks: [RangeKey: Task<RhythmHealth, Never>] = [:]
    private var metricTasks: [MetricRangeKey: Task<[MetricPoint], Never>] = [:]
    private static let rangeCacheTTL: TimeInterval = 5 * 60
    private static let maxRhythmRanges = 16
    private static let maxMetricRanges = 40
    private static let persistenceQueue = DispatchQueue(
        label: "com.boris.banana.health-persistence",
        qos: .utility)

    #if DEBUG
    /// Any audit scene that SHOWS fitness needs data, or `hasData` is false and the view renders
    /// the "Connect Apple Health" CTA instead of the content the screenshot is meant to sell.
    /// Previously only --dummy-health did this, and the workout scene never passed it.
    private let dummyMode: Bool = {
        let a = ProcessInfo.processInfo.arguments
        return a.contains("--dummy-health") || a.contains("--workout") || a.contains("--sleep")
            || a.contains("--trends") || a.contains("--trend")
    }()
    #endif

    /// Based on the full cache, not the hidden-filtered `workouts` — hiding everything the
    /// owner has ever recorded must not flip the UI back into "Connect Apple Health" mode.
    var hasData: Bool { !showsNoHealth && (!allWorkouts.isEmpty || !storedTrends.isEmpty) }

    /// Whether Health says Banana may save workouts: the one answer it gives about access. Kept
    /// here, and read when it can have changed (a connect, a refresh), never from a view's body.
    @Published private(set) var canSaveWorkouts = false

    /// Where Health stands on the setup list and in Settings (`HealthAccess`): connected only
    /// when something proves it, and "asked" when its sheet was shown and nothing does.
    var setupState: SetupState {
        // The saved mark, not `accessRequested`: that is also true after a pull-to-refresh that
        // read nothing, which is not Health's sheet having been shown.
        HealthAccess.state(asked: UserDefaults.standard.bool(forKey: Self.accessRequestedKey),
                           hasData: hasData, canSave: canSaveWorkouts)
    }

    /// This synchronous HealthKit API can wait on the Health daemon. Never let that
    /// cross-process wait occupy the UI actor (including permission checks before saving).
    private func authorizationStatus(for type: HKObjectType) async -> HKAuthorizationStatus {
        let started = Date()
        let status = await HealthAuthorization.read { [store] in
            store.authorizationStatus(for: type)
        }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 2 { Log.sync.notice("health: authorization check took \(elapsed, privacy: .public) seconds") }
        return status
    }

    private func noteWriteStanding() async {
        let can = isAvailable ? await authorizationStatus(for: .workoutType()) == .sharingAuthorized : false
        if canSaveWorkouts != can { canSaveWorkouts = can }
    }

    init() {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("health.json")
        #if DEBUG
        if dummyMode { loadSampleData(); return }
        // `--energy-balance`: the weigh-ins and Watch energy the logs-against-weight card reads.
        if let preview = EnergyBalance.Preview.requested() {
            let sample = preview.sample()
            storedTrends.bodyMassKg = sample.weightKg
            storedTrends.activeEnergyKcal = sample.activeKcal
            storedTrends.basalEnergyKcal = sample.restingKcal
            return
        }
        #endif
        // Cache decode off the main thread; a live refresh() completing first wins (fresher).
        let url = fileURL
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The anchor and its cached workout snapshot are one transaction. If a live
                // refresh won the launch race, keep that fresher data; otherwise install both.
                if !self.hasData {
                    self.allWorkouts = payload.workouts
                    self.hiddenWorkoutIDs = payload.hiddenWorkoutIDs ?? []
                    self.pendingRemovals = payload.pendingRemovals ?? []
                    self.storedTrends = payload.trends
                    self.workoutAnchorData = payload.workoutAnchor
                    self.snapshotChangedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                    self.refreshVisibleWorkouts()
                    CloudFitnessSync.shared.seedLocalHealthIfPresent()
                }
            }
        }
        LaunchClock.mark("health.init")
    }

    private var readTypes: Set<HKObjectType> {
        [
            .workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.distanceRowing),
            HKQuantityType(.swimmingStrokeCount),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.vo2Max),
            HKQuantityType(.bodyMass),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.leanBodyMass),
            HKQuantityType(.bodyMassIndex),
            HKQuantityType(.height),
            HKQuantityType(.stepCount),
            HKQuantityType(.basalEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.flightsClimbed),
            HKQuantityType(.walkingSpeed),
            HKQuantityType(.walkingHeartRateAverage),
            HKCategoryType(.sleepAnalysis),
            // The Watch's hand-washing detection: a wash in the night is the bathroom.
            HKCategoryType(.handwashingEvent),
        ]
    }

    /// Types the phone WRITES: it is the sole author of workouts (hub-and-spoke) — the
    /// Watch streams samples and the phone saves the single HKWorkout (with route).
    private var shareTypes: Set<HKSampleType> {
        [
            .workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.distanceRowing),
            HKQuantityType(.swimmingStrokeCount),
            HKQuantityType(.heartRate),
        ]
    }

    /// Ask for Health access, then import. (HealthKit read authorization is opaque —
    /// if nothing comes back, it's either not granted or there's simply no data.)
    /// Whether Health access has ever been asked for on this device. HealthKit never says whether
    /// reads were granted, and `didAttemptImport` only turns true once a refresh runs this
    /// launch — so without this, Health read as "off" after every cold launch.
    static let accessRequestedKey = "healthAccessRequested"   // dot-free
    var accessRequested: Bool {
        didAttemptImport || hasData || UserDefaults.standard.bool(forKey: Self.accessRequestedKey)
    }

    func connect() async {
        guard isAvailable else { errorMessage = "Health data isn't available on this device."; return }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            UserDefaults.standard.set(true, forKey: Self.accessRequestedKey)
            await noteWriteStanding()
            await refresh()
        } catch {
            errorMessage = "Couldn't access Apple Health: \(error.localizedDescription)"
        }
    }

    /// Ask Health about types a later build added to `readTypes` — only once Health is connected,
    /// and only from a page that uses them, since it shows Health's sheet. True when it asked.
    @discardableResult
    func requestNewReadAccessIfNeeded() async -> Bool {
        #if DEBUG
        if dummyMode { return false }
        #endif
        guard isAvailable, accessRequested,
              (try? await store.statusForAuthorizationRequest(toShare: shareTypes, read: readTypes)) == .shouldRequest
        else { return false }
        try? await store.requestAuthorization(toShare: shareTypes, read: readTypes)
        return true
    }

    // MARK: - Writing workouts (hub-and-spoke: the phone owns the HKWorkout)

    /// Ensure we can WRITE workouts — request share access if it was never asked for
    /// (e.g. Health was connected read-only before the phone became the writer).
    private func ensureWriteAccess() async -> Bool {
        switch await authorizationStatus(for: .workoutType()) {
        case .sharingAuthorized:
            return true
        case .notDetermined:
            try? await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            return await authorizationStatus(for: .workoutType()) == .sharingAuthorized
        default:
            return false
        }
    }

    /// Sessions being written right now. Two saves of one session racing each other is how the
    /// same workout reached Apple Health twice; the second waits its turn and then finds the first.
    private var writesInFlight: Set<UUID> = []

    /// Save a Watch-recorded session as a single HKWorkout with energy, distance, heart
    /// rate, and the GPS route. No-op if the data isn't available.
    ///
    /// Idempotent: every save carries the session id as `HKMetadataKeySyncIdentifier`, and a
    /// session Banana has already saved is not saved again unless `syncVersion` is higher — a
    /// deliberate rewrite (trim, pool-length correction), which HealthKit then applies as a
    /// replacement of the earlier save rather than a second copy.
    @discardableResult
    func writeWorkout(_ session: FitnessSession, refreshAfter: Bool = true, syncVersion: Int = 1) async -> Bool {
        guard isAvailable, let end = session.end, end > session.start else { return false }
        // Beta's workouts stay in Beta: Stable reads Health, so one saved there would show in both.
        guard AppVariant.current.mayWriteHealth else { return false }
        while writesInFlight.contains(session.id) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        writesInFlight.insert(session.id)
        defer { writesInFlight.remove(session.id) }
        if syncVersion <= 1, await hasOwnWorkout(for: session) {
            Log.sync.notice("health: \(session.id.uuidString, privacy: .public) already in Apple Health — not saving it again")
            return true
        }
        guard await ensureWriteAccess() else {
            errorMessage = "Banana can't save to Apple Health yet. Turn on Workouts for Banana in Settings › Health › Data Access, then trim again."
            return false
        }
        let activity = HKWorkoutActivityType(displayName: session.activity)
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        // The Watch session already knew the activity-specific configuration. Recreate that
        // meaning here instead of saving every imported workout as an outdoor run.
        let indoorActivities: Set<HKWorkoutActivityType> = [
            .yoga, .traditionalStrengthTraining, .highIntensityIntervalTraining,
            .coreTraining, .rowing
        ]
        config.locationType = indoorActivities.contains(activity) || session.poolLengthMeters != nil
            ? .indoor : .outdoor
        if activity == .swimming {
            let pool = session.poolLengthMeters
            config.swimmingLocationType = pool == nil ? .openWater : .pool
            if let pool, pool > 0 {
                config.lapLength = HKQuantity(unit: .meter(), doubleValue: pool)
            }
        }
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        do {
            try await builder.beginCollection(at: session.start)
            // A pause is a pause in Apple Health too: its time comes out of the workout's.
            if !session.pauses.isEmpty {
                let events = session.pauses.flatMap { pause -> [HKWorkoutEvent] in
                    let paused = session.start.addingTimeInterval(pause.start)
                    let resumed = min(session.start.addingTimeInterval(pause.end), end)
                    guard resumed > paused else { return [] }
                    return [HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: paused, duration: 0), metadata: nil),
                            HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: resumed, duration: 0), metadata: nil)]
                }
                if !events.isEmpty { try await builder.addWorkoutEvents(events) }
            }
            // Only add samples whose type we're actually authorized to share, so an
            // un-granted extra (e.g. route) can't throw and fail the whole save.
            func canShare(_ t: HKSampleType) async -> Bool { await authorizationStatus(for: t) == .sharingAuthorized }
            var samples: [HKSample] = []
            let energyType = HKQuantityType(.activeEnergyBurned)
            if let e = session.totalEnergy, e > 0, await canShare(energyType) {
                samples.append(HKCumulativeQuantitySample(type: energyType,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: e), start: session.start, end: end))
            }
            let distanceType: HKQuantityType? = switch activity {
            case .swimming: HKQuantityType(.distanceSwimming)
            case .cycling: HKQuantityType(.distanceCycling)
            case .rowing: HKQuantityType(.distanceRowing)
            case .running, .walking, .hiking: HKQuantityType(.distanceWalkingRunning)
            default: nil
            }
            if let distanceType, let d = session.totalDistance, d > 0, await canShare(distanceType) {
                samples.append(HKCumulativeQuantitySample(type: distanceType,
                    quantity: HKQuantity(unit: .meter(), doubleValue: d), start: session.start, end: end))
            }
            if activity == .swimming,
               let finalStrokeCount = session.samples.last(where: { $0.kind == .strokeCount })?.v1,
               finalStrokeCount > 0 {
                let strokeType = HKQuantityType(.swimmingStrokeCount)
                if await canShare(strokeType) {
                    samples.append(HKCumulativeQuantitySample(type: strokeType,
                        quantity: HKQuantity(unit: .count(), doubleValue: finalStrokeCount),
                        start: session.start, end: end))
                }
            }
            let hrType = HKQuantityType(.heartRate)
            if await canShare(hrType) {
                let bpm = HKUnit.count().unitDivided(by: .minute())
                for s in session.samples where s.kind == .heartRate {
                    let t = session.start.addingTimeInterval(s.t)
                    samples.append(HKQuantitySample(type: hrType,
                        quantity: HKQuantity(unit: bpm, doubleValue: s.v1), start: t, end: t))
                    if samples.count >= 500 {
                        try await builder.addSamples(samples)
                        samples.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !samples.isEmpty { try await builder.addSamples(samples) }
            try await builder.addMetadata([
                HKMetadataKeySyncIdentifier: session.id.uuidString,
                HKMetadataKeySyncVersion: NSNumber(value: syncVersion),
            ])
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { return false }

            if await canShare(HKSeriesType.workoutRoute()) {
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
                var locations: [CLLocation] = []
                var locationCount = 0
                for s in session.samples where s.kind == .location && s.v2 != nil {
                    locations.append(CLLocation(
                        coordinate: CLLocationCoordinate2D(latitude: s.v1, longitude: s.v2!),
                        altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                        course: -1, speed: s.v3 ?? -1,
                        timestamp: session.start.addingTimeInterval(s.t)))
                    locationCount += 1
                    if locations.count >= 500 {
                        try await routeBuilder.insertRouteData(locations)
                        locations.removeAll(keepingCapacity: true)
                    }
                }
                if !locations.isEmpty { try await routeBuilder.insertRouteData(locations) }
                if locationCount > 1 {
                    try await routeBuilder.finishRoute(with: workout, metadata: nil)
                }
            }
            if refreshAfter { await refresh() }
            return true
        } catch {
            errorMessage = "Couldn't save workout to Apple Health: \(error.localizedDescription)"
            return false
        }
    }

    /// Whether Apple Health already holds Banana's own save of this session: one stamped with
    /// its id, or (for saves from before the stamp) one of ours starting at the same second.
    private func hasOwnWorkout(for session: FitnessSession) async -> Bool {
        let window = HKQuery.predicateForSamples(withStart: session.start.addingTimeInterval(-2),
                                                 end: (session.end ?? session.start).addingTimeInterval(2))
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(window)], sortDescriptors: [], limit: nil)
        guard let found = try? await descriptor.result(for: store) else { return false }
        return found.contains { workout in
            guard workout.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier else { return false }
            if let id = workout.metadata?[HKMetadataKeySyncIdentifier] as? String {
                return id == session.id.uuidString
            }
            return abs(workout.startDate.timeIntervalSince(session.start)) < 2
        }
    }

    /// Apple Health's copy of a Banana workout follows the workout: after a trim, a revert or a
    /// correction, made here or on another device, write the session as it now stands and
    /// remove Banana's earlier save of it. Only Banana's own copies are ever touched (one that an
    /// older Watch build or another app wrote can't be deleted, and isn't).
    /// - Returns: false when Health couldn't be written (locked, or no permission): try again later.
    @discardableResult
    func follow(_ session: FitnessSession, previousStart: Date, previousEnd: Date) async -> Bool {
        guard isAvailable else { return false }
        // A save from before sessions carried their id can start a little off the recording's
        // own start: the nearest of ours, as a trim has always looked for it.
        let near = HKQuery.predicateForSamples(withStart: previousStart.addingTimeInterval(-120),
                                               end: previousStart.addingTimeInterval(120))
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(near)], sortDescriptors: [], limit: nil)
        let unstamped = (try? await descriptor.result(for: store))?
            .filter { $0.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier
                && $0.metadata?[HKMetadataKeySyncIdentifier] == nil }
            .min { abs($0.startDate.timeIntervalSince(previousStart)) < abs($1.startDate.timeIntervalSince(previousStart)) }
        guard await replaceOwnWorkout(with: session, originalStart: previousStart, originalEnd: previousEnd) else { return false }
        if let unstamped, (try? await store.delete(unstamped)) != nil { await refresh() }
        return true
    }

    /// A sync version higher than any earlier save of the same session: seconds since 1970.
    static func rewriteVersion(_ now: Date = Date()) -> Int { Int(now.timeIntervalSince1970) }

    /// Replace Banana's save(s) of a session with `session`: write it as a newer version, then
    /// delete every other copy Banana wrote over the same span. Only Banana's own copies are ever
    /// touched. Returns false (and deletes nothing) if the new save failed.
    @discardableResult
    func replaceOwnWorkout(with session: FitnessSession, originalStart: Date, originalEnd: Date) async -> Bool {
        guard isAvailable else { return false }
        let version = Self.rewriteVersion()
        guard await writeWorkout(session, refreshAfter: false, syncVersion: version) else { return false }
        let window = HKQuery.predicateForSamples(withStart: originalStart.addingTimeInterval(-2),
                                                 end: originalEnd.addingTimeInterval(2))
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(window)], sortDescriptors: [], limit: nil)
        let found = (try? await descriptor.result(for: store)) ?? []
        for workout in found where workout.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier
            && abs(workout.startDate.timeIntervalSince(originalStart)) < 2 {
            let sameSession = (workout.metadata?[HKMetadataKeySyncIdentifier] as? String) == session.id.uuidString
            let workoutVersion = (workout.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue ?? 0
            if sameSession && workoutVersion >= version { continue }   // the one just written
            try? await store.delete(workout)
        }
        await refresh()
        return true
    }

    /// Only a workout Banana itself wrote can be deleted from Apple Health (hub-and-spoke: the
    /// phone is the sole HKWorkout author). Everything else — an older Watch app build, Apple's
    /// own auto-detection, a third-party app like Whoop or WorkoutDoors — can only be hidden
    /// inside Banana; deleting someone else's Health record is never allowed, even on request.
    func canDeleteFromHealth(_ workout: HealthWorkout) -> Bool {
        workout.sourceBundleID == Bundle.main.bundleIdentifier
    }

    /// Hide a workout from every Banana screen without touching Apple Health. The full record
    /// stays in `allWorkouts` (and the persisted cache) so `unhide` can bring it back — an
    /// anchored HealthKit query never re-offers something it already returned once.
    func hide(_ id: UUID) {
        hideHere(id)
        // Health is the phone's: an iPad or the Mac hides its copy and asks the phone, so the
        // workout is hidden everywhere instead of on this device alone.
        HealthRemovalInbox.shared.ask(.healthWorkout(id))
    }

    private func hideHere(_ id: UUID) {
        guard hiddenWorkoutIDs.insert(id).inserted else { return }
        refreshVisibleWorkouts()
        persist(urgent: true)
    }

    func unhide(_ id: UUID) {
        guard hiddenWorkoutIDs.remove(id) != nil else { return }
        refreshVisibleWorkouts()
        persist()
    }

    /// Remove a workout from Banana: delete it from Apple Health when this app wrote it,
    /// otherwise hide it (never delete another source's data — see `canDeleteFromHealth`).
    /// Called when the user deletes a workout row, so it doesn't linger as an orphan after its
    /// paired Banana summary (if any) is gone — the "map gone, row stays" bug.
    @discardableResult
    func remove(workoutID: UUID) async -> HealthWorkoutRemoval {
        guard let workout = allWorkouts.first(where: { $0.id == workoutID }) else { return .notFound }
        guard DeviceRole.current.isHub else {
            // Not this device's to delete from: its copy goes out of sight now, and the phone,
            // which owns Health, is asked to remove the workout (delete or hide, by whose it
            // is). It used to be dropped from this device's copy alone, and came back with the
            // phone's next snapshot.
            hide(workoutID)
            return .hiddenInBanana
        }
        guard canDeleteFromHealth(workout) else {
            hideHere(workoutID)
            return .hiddenInBanana
        }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForObjects(with: [workoutID]))], sortDescriptors: [], limit: 1)
        if let hkWorkout = (try? await descriptor.result(for: store))?.first,
           hkWorkout.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier {
            try? await store.delete(hkWorkout)
        }
        allWorkouts.removeAll { $0.id == workoutID }
        hiddenWorkoutIDs.remove(workoutID)   // in case it had been hidden before this became reachable
        refreshVisibleWorkouts()
        persist(urgent: true)
        return .deletedFromHealth
    }

    /// The Apple Health half of a Banana workout being deleted on this device: removed with it.
    /// On the phone that is a delete from Health (or a hide, when another app wrote it; or a
    /// note to do so when Health delivers it). On an iPad or the Mac the copy here goes out of
    /// sight and the phone is asked to do the rest once the delete reaches it
    /// (`HealthRemovalRequest.Target.pairedWith`).
    func removeHealthHalf(ofWorkoutStarting start: Date) async {
        let paired = workouts.first { abs($0.start.timeIntervalSince(start)) < WorkoutEntry.matchTolerance }
        guard DeviceRole.current.isHub else {
            if let paired { hideHere(paired.id) } else { expectRemoval(near: start) }
            HealthRemovalInbox.shared.ask(.pairedWith(start: start))
            return
        }
        if let paired { await remove(workoutID: paired.id) } else { expectRemoval(near: start) }
    }

    /// Record that a just-deleted Banana summary's paired HealthKit workout hasn't imported yet
    /// (the Watch write is asynchronous), so the next `importWorkouts()` can catch it — remove or
    /// hide it per `canDeleteFromHealth` — the moment it arrives instead of leaving it to surface
    /// as an orphan row. Capped so a delete-heavy session can't grow this without bound.
    func expectRemoval(near start: Date) {
        let now = Date()
        pendingRemovals.removeAll { $0.expiresAt <= now }
        pendingRemovals.append(PendingRemoval(start: start, now: now))
        if pendingRemovals.count > Self.maxPendingRemovals {
            pendingRemovals.removeFirst(pendingRemovals.count - Self.maxPendingRemovals)
        }
        persist()
    }

    /// Recomputes the published, hidden-filtered `workouts` from the full cache. Called after
    /// any change to `allWorkouts` or `hiddenWorkoutIDs`.
    private func refreshVisibleWorkouts() {
        let visible = showsNoHealth ? [] : allWorkouts.filter { !hiddenWorkoutIDs.contains($0.id) }.sorted { $0.start > $1.start }
        if workouts != visible { workouts = visible }
    }

    func refresh() async {
        #if DEBUG
        if dummyMode { return }
        #endif
        guard isAvailable else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        isImporting = true
        defer { isImporting = false }
        await noteWriteStanding()
        await importWorkouts()
        await importTrends()
        didAttemptImport = true
        lastRefreshAt = Date()
        let connected = accessRequested
        HubStatusStore.shared.update {   // the phone only
            $0.healthConnected = connected
            $0.healthReadAt = Date()
        }
        rhythmCache.removeAll(keepingCapacity: true)
        metricCache.removeAll(keepingCapacity: true)
        persist()
    }

    /// Refresh only if the cache is older than `maxAge` — avoids a full HealthKit
    /// re-import every time the Fitness tab is shown.
    func refreshIfStale(maxAge: TimeInterval = 300) async {
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < maxAge { return }
        await refresh()
    }

    // MARK: - Workouts

    /// Bumped when `HealthWorkout` gains a field that only a fresh read can fill: the next
    /// import then starts from no anchor and rebuilds the whole cache (2: device, pool length,
    /// sync identifier — needed to tell Banana's duplicate saves apart).
    private static let workoutImportVersion = 2
    private static let workoutImportVersionKey = "healthWorkoutImportVersion"

    private func importWorkouts() async {
        let fullReimport = UserDefaults.standard.integer(forKey: Self.workoutImportVersionKey) < Self.workoutImportVersion
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout()],
            anchor: fullReimport ? nil : loadWorkoutAnchor(),
            limit: nil)
        guard let result = try? await descriptor.result(for: store) else { return }

        let energyType = HKQuantityType(.activeEnergyBurned)
        let walkRun = HKQuantityType(.distanceWalkingRunning)
        let cycling = HKQuantityType(.distanceCycling)
        let swimming = HKQuantityType(.distanceSwimming)
        let rowing = HKQuantityType(.distanceRowing)
        let hrType = HKQuantityType(.heartRate)
        let bpm = HKUnit.count().unitDivided(by: .minute())

        func summary(_ workout: HKWorkout) -> HealthWorkout {
            let energy = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie())
            let distance = [walkRun, cycling, swimming, rowing]
                .lazy
                .compactMap { workout.statistics(for: $0)?.sumQuantity() }
                .first?
                .doubleValue(for: .meter())
            let hr = workout.statistics(for: hrType)
            return HealthWorkout(
                id: workout.uuid,
                activity: workout.workoutActivityType.displayName,
                start: workout.startDate,
                end: workout.endDate,
                duration: workout.duration,
                energyKcal: energy,
                distanceMeters: distance,
                avgHeartRate: hr?.averageQuantity()?.doubleValue(for: bpm),
                maxHeartRate: hr?.maximumQuantity()?.doubleValue(for: bpm),
                source: workout.sourceRevision.source.name,
                sourceBundleID: workout.sourceRevision.source.bundleIdentifier,
                productType: workout.sourceRevision.productType,
                lapLengthMeters: (workout.metadata?[HKMetadataKeyLapLength] as? HKQuantity)?
                    .doubleValue(for: .meter()),
                syncIdentifier: workout.metadata?[HKMetadataKeySyncIdentifier] as? String)
        }
        // Track only what THIS import batch decided (removed vs. added/updated) instead of
        // snapshotting `allWorkouts` up front and replacing it wholesale at the end. The
        // `store.delete` await below is a suspension point on this @MainActor class, so a
        // concurrent user action (hide/unhide/remove tapped on another row) can interleave and
        // mutate `allWorkouts` directly; re-merging onto whatever `allWorkouts` holds at the end
        // — rather than the loop-start snapshot — means this batch's decisions land on top of
        // that instead of silently reverting it.
        var removedIDs = Set<UUID>()
        for deleted in result.deletedObjects { removedIDs.insert(deleted.uuid) }
        var decided: [UUID: HealthWorkout] = [:]

        // Reconcile against live tombstones from `expectRemoval`: a newly-imported workout that
        // matches one is the paired Health copy of a summary the owner already deleted before
        // Health had synced it — apply the same remove-or-hide rule now instead of letting it
        // sit as an orphan row.
        let now = Date()
        pendingRemovals.removeAll { $0.expiresAt <= now }
        for hkWorkout in result.addedSamples {
            let hw = summary(hkWorkout)
            if let i = pendingRemovals.firstIndex(where: { $0.matches(hw.start, hw.end, now: now) }) {
                pendingRemovals.remove(at: i)
                if canDeleteFromHealth(hw) {
                    try? await store.delete(hkWorkout)
                    removedIDs.insert(hw.id)
                } else {
                    hiddenWorkoutIDs.insert(hw.id)
                    decided[hw.id] = hw
                }
            } else {
                decided[hw.id] = hw
            }
        }
        // A full re-read is the whole truth: anything cached but not returned is gone.
        var merged = fullReimport ? [:] : Dictionary(uniqueKeysWithValues: allWorkouts.map { ($0.id, $0) })
        for id in removedIDs { merged[id] = nil }
        for (id, hw) in decided { merged[id] = hw }
        let updated = merged.values.sorted { $0.start > $1.start }
        if allWorkouts != updated { allWorkouts = updated }
        refreshVisibleWorkouts()
        saveWorkoutAnchor(result.newAnchor)
        if fullReimport { UserDefaults.standard.set(Self.workoutImportVersion, forKey: Self.workoutImportVersionKey) }
        let sources = Set(allWorkouts.map(\.source)).sorted().joined(separator: ",")
        let earliest = allWorkouts.map(\.start).min().map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "none"
        Log.sync.notice("health: imported \(self.allWorkouts.count) workouts · sources=[\(sources, privacy: .public)] · earliest=\(earliest, privacy: .public)")
    }

    // MARK: - Trends

    private func importTrends() async {
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: Date())
        // Two years of daily values: comparing the last 12 months with the 12 before needs both.
        guard let recentStart = cal.date(byAdding: .day, value: -30, to: anchor),
              let historyStart = cal.date(byAdding: .day, value: -730, to: anchor) else { return }
        let interval = DateComponents(day: 1)
        let bpm = HKUnit.count().unitDivided(by: .minute())

        async let restingHR = dailyAverages(.restingHeartRate, unit: bpm, start: historyStart, anchor: anchor, interval: interval)
        async let hrv = dailyAverages(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: historyStart, anchor: anchor, interval: interval)
        async let respiratory = dailyAverages(.respiratoryRate, unit: bpm, start: historyStart, anchor: anchor, interval: interval)
        async let vo2Max = dailyAverages(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: historyStart, anchor: anchor, interval: interval)
        async let sleepHours = dailySleep(start: historyStart)
        async let nights = recentNights(start: cal.date(byAdding: .day, value: -15, to: anchor) ?? recentStart)
        async let bodyMass = dailyAverages(.bodyMass, unit: .gramUnit(with: .kilo), start: historyStart, anchor: anchor, interval: interval)
        async let bodyFat = dailyAverages(.bodyFatPercentage, unit: .percent(), start: historyStart, anchor: anchor, interval: interval)
        async let leanBodyMass = dailyAverages(.leanBodyMass, unit: .gramUnit(with: .kilo), start: historyStart, anchor: anchor, interval: interval)
        async let bodyMassIndex = dailyAverages(.bodyMassIndex, unit: .count(), start: historyStart, anchor: anchor, interval: interval)
        async let height = dailyAverages(.height, unit: .meter(), start: historyStart, anchor: anchor, interval: interval)
        async let steps = dailySums(.stepCount, unit: .count(), start: historyStart, anchor: anchor, interval: interval)
        async let activeEnergy = dailySums(.activeEnergyBurned, unit: .kilocalorie(), start: historyStart, anchor: anchor, interval: interval)
        async let basalEnergy = dailySums(.basalEnergyBurned, unit: .kilocalorie(), start: historyStart, anchor: anchor, interval: interval)
        async let exercise = dailySums(.appleExerciseTime, unit: .minute(), start: historyStart, anchor: anchor, interval: interval)
        async let flights = dailySums(.flightsClimbed, unit: .count(), start: historyStart, anchor: anchor, interval: interval)
        async let walkingSpeed = dailyAverages(.walkingSpeed, unit: .meter().unitDivided(by: .second()), start: historyStart, anchor: anchor, interval: interval)
        async let walkingHeartRate = dailyAverages(.walkingHeartRateAverage, unit: bpm, start: historyStart, anchor: anchor, interval: interval)
        var t = HealthTrends()
        t.restingHR = await restingHR
        t.hrv = await hrv
        t.respiratory = await respiratory
        t.vo2Max = await vo2Max
        t.sleepHours = await sleepHours
        t.bodyMassKg = await bodyMass
        t.bodyFatPercentage = await bodyFat
        t.leanBodyMassKg = await leanBodyMass
        t.bodyMassIndex = await bodyMassIndex
        t.heightMeters = await height
        t.steps = await steps
        t.activeEnergyKcal = await activeEnergy
        t.basalEnergyKcal = await basalEnergy
        t.exerciseMinutes = await exercise
        t.flightsClimbed = await flights
        t.walkingSpeedMetersPerSecond = await walkingSpeed
        t.walkingHeartRate = await walkingHeartRate
        t.nights = await nights
        if !t.isEmpty { storedTrends.mergeNonEmpty(t) } // don't erase a synced series when one read type is denied
    }

    private func dailyAverages(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                               start: Date, anchor: Date, interval: DateComponents) async -> [MetricPoint] {
        await dailyValues(identifier, unit: unit, start: start, anchor: anchor, interval: interval,
                          options: .discreteAverage) { $0.averageQuantity() }
    }

    /// Cumulative HealthKit types must be summed per day. Averaging step/energy samples would
    /// produce plausible-looking but fundamentally wrong totals.
    private func dailySums(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                           start: Date, anchor: Date, interval: DateComponents) async -> [MetricPoint] {
        await dailyValues(identifier, unit: unit, start: start, anchor: anchor, interval: interval,
                          options: .cumulativeSum) { $0.sumQuantity() }
    }

    private func dailyValues(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                             start: Date, anchor: Date, interval: DateComponents,
                             options: HKStatisticsOptions,
                             quantity: @escaping (HKStatistics) -> HKQuantity?) async -> [MetricPoint] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate),
            options: options,
            anchorDate: anchor,
            intervalComponents: interval)
        guard let collection = try? await descriptor.result(for: store) else { return [] }
        var points: [MetricPoint] = []
        collection.enumerateStatistics(from: start, to: Date()) { stats, _ in
            if let q = quantity(stats) {
                points.append(MetricPoint(date: stats.startDate, value: q.doubleValue(for: unit)))
            }
        }
        return points
    }

    /// The last two weeks of nights with their wake-ups: Health's sleep stages (asleep and awake —
    /// "in bed" says nothing about sleep) and step samples, handed to `SleepNights`.
    private func recentNights(start: Date) async -> [NightSummary] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let sleepQuery = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [], limit: nil)
        let stepQuery = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.stepCount), predicate: predicate)],
            sortDescriptors: [], limit: nil)
        let handwashQuery = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.handwashingEvent), predicate: predicate)],
            sortDescriptors: [], limit: nil)
        guard let sleep = try? await sleepQuery.result(for: store) else { return [] }
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let segments = sleep.compactMap { sample -> SleepNights.Segment? in
            if asleep.contains(sample.value) {
                return .init(start: sample.startDate, end: sample.endDate, stage: .asleep)
            }
            if sample.value == HKCategoryValueSleepAnalysis.awake.rawValue {
                return .init(start: sample.startDate, end: sample.endDate, stage: .awake)
            }
            return nil
        }
        let stepSamples = (try? await stepQuery.result(for: store)) ?? []
        // The phone and the Watch both count a walk they're both on; at night it's the Watch on
        // your wrist that knows, so use only its steps when it has any.
        let fromWatch = stepSamples.filter { $0.sourceRevision.productType?.hasPrefix("Watch") == true }
        let chunks = (fromWatch.isEmpty ? stepSamples : fromWatch).map {
            SleepNights.StepSample(start: $0.startDate, end: $0.endDate, count: $0.quantity.doubleValue(for: .count()))
        }
        // Where the Watch has sent its minute-by-minute steps, they replace Health's chunks.
        let steps = SleepNights.preferringMinutes(chunks, windows: NightMotionStore.shared.windows)
        let handwashes = ((try? await handwashQuery.result(for: store)) ?? []).map(\.startDate)
        return SleepNights.nights(segments: segments, steps: steps, handwashes: handwashes)
    }

    private func dailySleep(start: Date) async -> [MetricPoint] {
        let cal = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [],
            limit: nil)
        guard let samples = try? await descriptor.result(for: store) else { return [] }
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        // Multiple sources (Apple Watch, iPhone, third-party sleep apps) often log the SAME
        // night with overlapping samples. Summing raw durations double-counts and yields
        // impossible totals (15h+). Merge all "asleep" samples into a union of non-overlapping
        // intervals first, then sum — so overlapping time is counted once.
        let intervals = samples
            .filter { asleep.contains($0.value) && $0.endDate > $0.startDate }
            .map { (start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for iv in intervals {
            if var last = merged.last, iv.start <= last.end {
                last.end = max(last.end, iv.end)          // overlap/adjacent → extend
                merged[merged.count - 1] = last
            } else {
                merged.append(iv)                          // gap → new night/interval
            }
        }
        var byDay: [Date: Double] = [:]
        for iv in merged {
            let day = cal.startOfDay(for: iv.end)          // attribute a night to the morning it ended
            byDay[day, default: 0] += iv.end.timeIntervalSince(iv.start) / 3600
        }
        return byDay.sorted { $0.key < $1.key }.map { MetricPoint(date: $0.key, value: $0.value) }
    }

    // MARK: - Ranged aggregation (for Rhythm's week/month/quarter/year views)

    /// Sleep + recovery (HRV) + resting HR over an arbitrary window, bucketed by `bucket`
    /// (day / week / month). Queried on demand so long ranges (quarter/year) don't need a
    /// giant cached daily array. In dummy/preview mode it buckets the cached sample series.
    func rhythmHealth(from start: Date, to end: Date, bucket: Calendar.Component) async -> RhythmHealth {
        #if DEBUG
        if dummyMode {
            return RhythmHealth(
                sleep: Self.bucketed(trends.sleepHours, from: start, to: end, bucket: bucket),
                hrv: Self.bucketed(trends.hrv, from: start, to: end, bucket: bucket),
                restingHR: Self.bucketed(trends.restingHR, from: start, to: end, bucket: bucket))
        }
        #endif
        guard isAvailable else { return RhythmHealth() }
        let key = Self.rangeKey(from: start, to: end, bucket: bucket)
        if let cached = rhythmCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < Self.rangeCacheTTL {
            return cached.value
        }
        if let task = rhythmTasks[key] { return await task.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { return RhythmHealth() }
            return await self.fetchRhythmHealth(from: start, to: end, bucket: bucket)
        }
        rhythmTasks[key] = task
        let value = await task.value
        rhythmTasks[key] = nil
        rhythmCache[key] = Cached(value: value, fetchedAt: Date())
        pruneRangeCaches()
        return value
    }

    private func fetchRhythmHealth(
        from start: Date,
        to end: Date,
        bucket: Calendar.Component
    ) async -> RhythmHealth {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let interval = Self.dateComponents(for: bucket)
        async let hrv = rangedAverages(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli),
                                       start: start, end: end, interval: interval)
        async let rhr = rangedAverages(.restingHeartRate, unit: bpm, start: start, end: end, interval: interval)
        async let sleep = rangedSleep(start: start, end: end, bucket: bucket)
        return RhythmHealth(sleep: await sleep, hrv: await hrv, restingHR: await rhr)
    }

    /// A single metric bucketed over an arbitrary window — powers Fitness's period-scoped
    /// trend cards (all five MetricKinds, unlike `rhythmHealth` which returns only three).
    func metricSeries(_ kind: MetricKind, from start: Date, to end: Date,
                      bucket: Calendar.Component) async -> [MetricPoint] {
        #if DEBUG
        if dummyMode { return Self.bucketed(kind.series(trends), from: start, to: end, bucket: bucket) }
        #endif
        guard isAvailable else { return [] }
        let key = MetricRangeKey(
            range: Self.rangeKey(from: start, to: end, bucket: bucket),
            kind: kind)
        if let cached = metricCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < Self.rangeCacheTTL {
            return cached.value
        }
        if let task = metricTasks[key] { return await task.value }
        let task: Task<[MetricPoint], Never> = Task { @MainActor [weak self] in
            guard let self else { return [MetricPoint]() }
            return await self.fetchMetricSeries(
                kind, from: start, to: end, bucket: bucket)
        }
        metricTasks[key] = task
        let value = await task.value
        metricTasks[key] = nil
        metricCache[key] = Cached(value: value, fetchedAt: Date())
        pruneRangeCaches()
        return value
    }

    private func fetchMetricSeries(
        _ kind: MetricKind,
        from start: Date,
        to end: Date,
        bucket: Calendar.Component
    ) async -> [MetricPoint] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let interval = Self.dateComponents(for: bucket)
        switch kind {
        case .restingHR:   return await rangedAverages(.restingHeartRate, unit: bpm, start: start, end: end, interval: interval)
        case .hrv:         return await rangedAverages(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end, interval: interval)
        case .respiratory: return await rangedAverages(.respiratoryRate, unit: bpm, start: start, end: end, interval: interval)
        case .vo2Max:      return await rangedAverages(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: start, end: end, interval: interval)
        case .sleep:       return await rangedSleep(start: start, end: end, bucket: bucket)
        case .bodyMass:    return await rangedAverages(.bodyMass, unit: .gramUnit(with: .kilo), start: start, end: end, interval: interval)
        case .bodyFat:     return await rangedAverages(.bodyFatPercentage, unit: .percent(), start: start, end: end, interval: interval)
        case .leanBodyMass:return await rangedAverages(.leanBodyMass, unit: .gramUnit(with: .kilo), start: start, end: end, interval: interval)
        case .bodyMassIndex:return await rangedAverages(.bodyMassIndex, unit: .count(), start: start, end: end, interval: interval)
        case .height:      return await rangedAverages(.height, unit: .meter(), start: start, end: end, interval: interval)
        case .steps:       return await rangedSums(.stepCount, unit: .count(), start: start, end: end, interval: interval)
        case .activeEnergy:return await rangedSums(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end, interval: interval)
        case .basalEnergy: return await rangedSums(.basalEnergyBurned, unit: .kilocalorie(), start: start, end: end, interval: interval)
        case .exercise:    return await rangedSums(.appleExerciseTime, unit: .minute(), start: start, end: end, interval: interval)
        case .flightsClimbed:return await rangedSums(.flightsClimbed, unit: .count(), start: start, end: end, interval: interval)
        case .walkingSpeed:return await rangedAverages(.walkingSpeed, unit: .meter().unitDivided(by: .second()), start: start, end: end, interval: interval)
        case .walkingHeartRate:return await rangedAverages(.walkingHeartRateAverage, unit: bpm, start: start, end: end, interval: interval)
        }
    }

    private nonisolated static func rangeKey(
        from start: Date,
        to end: Date,
        bucket: Calendar.Component
    ) -> RangeKey {
        let bucketID: Int
        switch bucket {
        case .day: bucketID = 1
        case .weekOfYear: bucketID = 2
        case .month: bucketID = 3
        default: bucketID = 0
        }
        return RangeKey(
            start: start.timeIntervalSinceReferenceDate,
            end: end.timeIntervalSinceReferenceDate,
            bucket: bucketID)
    }

    private func pruneRangeCaches() {
        let cutoff = Date().addingTimeInterval(-Self.rangeCacheTTL)
        rhythmCache = rhythmCache.filter { $0.value.fetchedAt >= cutoff }
        metricCache = metricCache.filter { $0.value.fetchedAt >= cutoff }
        if rhythmCache.count > Self.maxRhythmRanges {
            for key in rhythmCache.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt })
                .prefix(rhythmCache.count - Self.maxRhythmRanges).map(\.key) {
                rhythmCache[key] = nil
            }
        }
        if metricCache.count > Self.maxMetricRanges {
            for key in metricCache.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt })
                .prefix(metricCache.count - Self.maxMetricRanges).map(\.key) {
                metricCache[key] = nil
            }
        }
    }

    private func rangedAverages(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                                start: Date, end: Date, interval: DateComponents) async -> [MetricPoint] {
        await rangedValues(identifier, unit: unit, start: start, end: end, interval: interval,
                           options: .discreteAverage) { $0.averageQuantity() }
    }

    private func rangedSums(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                            start: Date, end: Date, interval: DateComponents) async -> [MetricPoint] {
        await rangedValues(identifier, unit: unit, start: start, end: end, interval: interval,
                           options: .cumulativeSum) { $0.sumQuantity() }
    }

    private func rangedValues(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                              start: Date, end: Date, interval: DateComponents,
                              options: HKStatisticsOptions,
                              quantity: @escaping (HKStatistics) -> HKQuantity?) async -> [MetricPoint] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate),
            options: options, anchorDate: start, intervalComponents: interval)
        guard let collection = try? await descriptor.result(for: store) else { return [] }
        var points: [MetricPoint] = []
        collection.enumerateStatistics(from: start, to: end) { stats, _ in
            if let q = quantity(stats) {
                points.append(MetricPoint(date: stats.startDate, value: q.doubleValue(for: unit)))
            }
        }
        return points
    }

    private func rangedSleep(start: Date, end: Date, bucket: Calendar.Component) async -> [MetricPoint] {
        let cal = Calendar.app
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [], limit: nil)
        guard let samples = try? await descriptor.result(for: store) else { return [] }
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        // Union-merge overlapping samples (same night from multiple sources) before summing.
        let intervals = samples
            .filter { asleep.contains($0.value) && $0.endDate > $0.startDate }
            .map { (start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for iv in intervals {
            if var last = merged.last, iv.start <= last.end {
                last.end = max(last.end, iv.end); merged[merged.count - 1] = last
            } else { merged.append(iv) }
        }
        // Total hours per night, then average across the nights in each bucket.
        var perNight: [Date: Double] = [:]
        for iv in merged {
            let day = cal.startOfDay(for: iv.end)
            perNight[day, default: 0] += iv.end.timeIntervalSince(iv.start) / 3600
        }
        if bucket == .day {
            return perNight.sorted { $0.key < $1.key }.map { MetricPoint(date: $0.key, value: $0.value) }
        }
        var byBucket: [Date: (sum: Double, count: Int)] = [:]
        for (day, hours) in perNight {
            let key = cal.dateInterval(of: bucket, for: day)?.start ?? day
            let cur = byBucket[key] ?? (0, 0)
            byBucket[key] = (cur.sum + hours, cur.count + 1)
        }
        return byBucket.sorted { $0.key < $1.key }
            .map { MetricPoint(date: $0.key, value: $0.value.sum / Double(max(1, $0.value.count))) }
    }

    private static func dateComponents(for bucket: Calendar.Component) -> DateComponents {
        switch bucket {
        case .day:        return DateComponents(day: 1)
        case .weekOfYear: return DateComponents(weekOfYear: 1)
        case .month:      return DateComponents(month: 1)
        default:          return DateComponents(day: 1)
        }
    }

    /// Bucket a daily series into per-bucket averages within [start, end).
    private static func bucketed(_ points: [MetricPoint], from start: Date, to end: Date,
                                 bucket: Calendar.Component, calendar cal: Calendar = .app) -> [MetricPoint] {
        let inRange = points.filter { $0.date >= start && $0.date < end }
        if bucket == .day { return inRange.sorted { $0.date < $1.date } }
        var byBucket: [Date: (sum: Double, count: Int)] = [:]
        for p in inRange {
            let key = cal.dateInterval(of: bucket, for: p.date)?.start ?? p.date
            let cur = byBucket[key] ?? (0, 0)
            byBucket[key] = (cur.sum + p.value, cur.count + 1)
        }
        return byBucket.sorted { $0.key < $1.key }
            .map { MetricPoint(date: $0.key, value: $0.value.sum / Double(max(1, $0.value.count))) }
    }

    // MARK: - Persistence

    private struct Payload: Codable, Sendable {
        var workouts: [HealthWorkout] = []
        var trends = HealthTrends()
        /// Archived `HKQueryAnchor`. It lives in the same atomic payload as the rows produced
        /// from it: after a kill we either have both new values or both old values, never an
        /// advanced anchor paired with a stale cache that permanently skips a workout.
        var workoutAnchor: Data?
        /// Optional so a payload written before this field existed (local disk cache, or an
        /// older cloud snapshot) decodes fine — a missing key means "nothing hidden yet".
        var hiddenWorkoutIDs: Set<UUID>?
        /// Local-only bookkeeping for `expectRemoval` — never included in `cloudSnapshot()`,
        /// since another device's HealthKit import race is its own to reconcile.
        var pendingRemovals: [PendingRemoval]?
    }

    /// - Parameter urgent: a workout was removed or hidden: the data platform's copy goes up now,
    ///   not after its ten minutes (`SnapshotPace`).
    private func persist(publish: Bool = true, urgent: Bool = false) {
        let payload = Payload(workouts: allWorkouts, trends: storedTrends, workoutAnchor: workoutAnchorData,
                              hiddenWorkoutIDs: hiddenWorkoutIDs, pendingRemovals: pendingRemovals)
        let url = fileURL
        snapshotChangedAt = Date()
        if publish { onSnapshotChange?(urgent) }
        // Trigger the CloudKit publish synchronously, on the same call stack as persist(), before
        // the disk write is even scheduled: pushHealthSnapshot()'s markDirty()/engine.state.add()
        // must land before this function returns so a background/terminate race can't skip both
        // the async disk write and the async publish hop and lose the dirty bit for this edit.
        if publish {
            CloudFitnessSync.shared.pushHealthSnapshot()
        }
        Self.persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? HealthFileProtection.write(data, to: url)
        }
    }

    /// The portable portion of HealthKit data. The query anchor is intentionally excluded: it is
    /// valid only for this device's Health database and would make another device skip changes.
    /// `hiddenWorkoutIDs` rides along (a hide should apply everywhere the workout is visible);
    /// `pendingRemovals` does not — it is this device's own bookkeeping: the phone's for a
    /// workout Health hasn't delivered yet, an iPad's or the Mac's for one it removed that a
    /// snapshot may still carry (`adoptCloudSnapshot`).
    func cloudSnapshot() -> Data? {
        (try? JSONEncoder().encode(Payload(workouts: allWorkouts, trends: storedTrends, workoutAnchor: nil,
                                           hiddenWorkoutIDs: hiddenWorkoutIDs)))
            .flatMap(HealthSnapshotCoding.pack)
    }

    /// Another account signed in on an iPad or a Mac and the person said to clear this device: the
    /// phone's Health cache from the account before goes (the phone's own Health is its own).
    func clearForAccountChange() {
        guard !DeviceRole.current.isHub else { return }
        allWorkouts = []
        storedTrends = HealthTrends()
        hiddenWorkoutIDs = []
        pendingRemovals = []
        rhythmCache.removeAll()
        metricCache.removeAll()
        refreshVisibleWorkouts()
        persist(publish: false)
    }

    /// The data platform's snapshot (`HealthSnapshotAdapter`): the same portable portion as
    /// `cloudSnapshot`, its values taken now and encoded and packed where the maker is called, off
    /// the main actor.
    func spaceSnapshotMaker() -> @Sendable () -> Data? {
        let payload = Payload(workouts: allWorkouts, trends: storedTrends, workoutAnchor: nil, hiddenWorkoutIDs: hiddenWorkoutIDs)
        return { (try? JSONEncoder().encode(payload)).flatMap(HealthSnapshotCoding.pack) }
    }

    /// The cache changed here and the other devices should hear (`urgent`: a workout was removed or
    /// hidden). The data platform's snapshot adapter listens.
    var onSnapshotChange: ((_ urgent: Bool) -> Void)?
    /// When the cache last changed here: the snapshot's own time. Nil until it changes or loads.
    private(set) var snapshotChangedAt: Date?

    /// Adopt the phone's read-only Health cache on a device that cannot query that database.
    /// A later local Health refresh simply replaces this cache with fresher local facts.
    /// Hidden IDs are unioned rather than replaced, so a hide already applied locally on this
    /// device (e.g. a Mac's own context-menu Hide) survives adopting an older remote snapshot —
    /// the tradeoff is that an *unhide* made on another device only catches up once this device
    /// unhides the same workout itself, since the synced field never shrinks the local set.
    func adoptCloudSnapshot(_ data: Data) {
        guard let json = HealthSnapshotCoding.unpack(data),
              let payload = try? JSONDecoder().decode(Payload.self, from: json) else { return }
        allWorkouts = payload.workouts
        hiddenWorkoutIDs.formUnion(payload.hiddenWorkoutIDs ?? [])
        // A workout deleted here whose Health half this snapshot still carries (it was made
        // before the phone heard) stays out of sight, instead of returning as a row of its own
        // until the next one.
        let now = Date()
        pendingRemovals.removeAll { $0.expiresAt <= now }
        hiddenWorkoutIDs.formUnion(HealthRemovalRequests.removedHere(in: payload.workouts,
                                                                    tombstones: pendingRemovals, now: now))
        storedTrends = payload.trends
        rhythmCache.removeAll(keepingCapacity: true)
        metricCache.removeAll(keepingCapacity: true)
        refreshVisibleWorkouts()
        persist(publish: false)
    }

    private func loadWorkoutAnchor() -> HKQueryAnchor? {
        guard let data = workoutAnchorData else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveWorkoutAnchor(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: anchor, requiringSecureCoding: true) else { return }
        workoutAnchorData = data
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        allWorkouts = payload.workouts
        hiddenWorkoutIDs = payload.hiddenWorkoutIDs ?? []
        pendingRemovals = payload.pendingRemovals ?? []
        storedTrends = payload.trends
        workoutAnchorData = payload.workoutAnchor
        refreshVisibleWorkouts()
    }

    #if DEBUG
    /// Two weeks of nights for the Sleep page: bathroom trips, a baby stretch, brief and long
    /// stretches awake in bed, a night slept through — built through `SleepNights` like real ones.
    static func sampleNights(now: Date, calendar: Calendar) -> [NightSummary] {
        (0..<14).flatMap { daysAgo -> [NightSummary] in
            guard let morning = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)),
                  let bed = calendar.date(byAdding: .minute, value: -(60 + daysAgo % 3 * 20), to: morning) else { return [] }
            func at(_ minutes: Int) -> Date { bed.addingTimeInterval(Double(minutes * 60)) }
            var segments: [SleepNights.Segment] = []
            var steps: [SleepNights.StepSample] = []
            var cursor = 0
            // (minutes asleep before it, minutes awake, steps)
            // Brief stretches awake in bed (no steps) between the trips, as real nights have.
            let wakes: [(Int, Int, Double)] = daysAgo % 4 == 3 ? [] :
                daysAgo % 2 == 0 ? [(60, 3, 0), (110, 4, 38), (90, 5, 0), (60, 26, 180), (40, 12, 0)]
                    : [(120, 3, 0), (90, 5, 44)]
            for (asleepFor, awakeFor, stepCount) in wakes {
                segments.append(.init(start: at(cursor), end: at(cursor + asleepFor), stage: .asleep))
                cursor += asleepFor
                segments.append(.init(start: at(cursor), end: at(cursor + awakeFor), stage: .awake))
                steps.append(.init(start: at(cursor), end: at(cursor + awakeFor), count: stepCount))
                cursor += awakeFor
            }
            segments.append(.init(start: at(cursor), end: at(460 - daysAgo % 5 * 15), stage: .asleep))
            return SleepNights.nights(segments: segments, steps: steps, calendar: calendar)
        }
    }

    /// Dummy data covering many stat combinations, for layout verification.
    private func loadSampleData() {
        let now = Date()
        let cal = Calendar.current
        func ago(_ h: Int) -> Date { cal.date(byAdding: .hour, value: -h, to: now) ?? now }

        if SmartScheduleStore.isStoreCapture {
            // A marketing capture: a plausible week, no strings written to break a layout.
            workouts = [
                // Today's is the ride the Watch recorded (`FitnessStore.injectSampleForPreview`):
                // the same three hours and distance, so the list and its totals agree.
                HealthWorkout(activity: "Cycling", start: ago(3), end: now, duration: 10_800,
                              energyKcal: 1_980, distanceMeters: 82_241, avgHeartRate: 138, maxHeartRate: 171, source: "Banana"),
                HealthWorkout(activity: "Yoga", start: ago(26), end: ago(25), duration: 1800,
                              energyKcal: 96, distanceMeters: nil, avgHeartRate: 92, maxHeartRate: 118, source: "Banana"),
                HealthWorkout(activity: "Running", start: ago(50), end: ago(49), duration: 2710,
                              energyKcal: 498, distanceMeters: 8050, avgHeartRate: 152, maxHeartRate: 176, source: "Banana"),
                HealthWorkout(activity: "Strength", start: ago(74), end: ago(73), duration: 2700,
                              energyKcal: 310, distanceMeters: nil, avgHeartRate: 121, maxHeartRate: 158, source: "Banana"),
                HealthWorkout(activity: "Walking", start: ago(98), end: ago(97), duration: 2740,
                              energyKcal: 190, distanceMeters: 3120, avgHeartRate: 104, maxHeartRate: 126, source: "Apple Watch"),
                // The week before, so "this week" has something to be compared with.
                HealthWorkout(activity: "Running", start: ago(171), end: ago(170), duration: 2580,
                              energyKcal: 470, distanceMeters: 7600, avgHeartRate: 154, maxHeartRate: 178, source: "Banana"),
                HealthWorkout(activity: "Strength", start: ago(195), end: ago(194), duration: 2400,
                              energyKcal: 280, distanceMeters: nil, avgHeartRate: 119, maxHeartRate: 152, source: "Banana"),
                HealthWorkout(activity: "Cycling", start: ago(219), end: ago(218), duration: 4200,
                              energyKcal: 590, distanceMeters: 29800, avgHeartRate: 136, maxHeartRate: 168, source: "Banana"),
                HealthWorkout(activity: "Yoga", start: ago(243), end: ago(242), duration: 1800,
                              energyKcal: 92, distanceMeters: nil, avgHeartRate: 90, maxHeartRate: 114, source: "Banana"),
            ]
        } else {
        workouts = [
            // All stats + long distance (wrapping stress test).
            HealthWorkout(activity: "Cycling", start: ago(3), end: ago(1), duration: 7200,
                          energyKcal: 980, distanceMeters: 42195, avgHeartRate: 141, maxHeartRate: 176, source: "Whoop"),
            // Very long source (badge truncation stress test).
            HealthWorkout(activity: "Yoga", start: ago(26), end: ago(25), duration: 1800,
                          energyKcal: 96, distanceMeters: nil, avgHeartRate: nil, maxHeartRate: nil, source: "A Very Long Third-Party App Name"),
            // Long activity name + long source together.
            HealthWorkout(activity: "High Intensity Interval Training", start: ago(50), end: ago(49), duration: 1500,
                          energyKcal: 305, distanceMeters: nil, avgHeartRate: 158, maxHeartRate: 189, source: "A Very Long Third-Party App Name"),
            HealthWorkout(activity: "Running", start: ago(74), end: ago(73), duration: 3011,
                          energyKcal: 612, distanceMeters: 8450, avgHeartRate: 154, maxHeartRate: 182, source: "WorkoutDoors"),
            HealthWorkout(activity: "Walking", start: ago(98), end: ago(97), duration: 2740,
                          energyKcal: nil, distanceMeters: 3120, avgHeartRate: nil, maxHeartRate: nil, source: "iPhone"),
            HealthWorkout(activity: "Strength", start: ago(120), end: ago(119), duration: 3600,
                          energyKcal: 420, distanceMeters: nil, avgHeartRate: 128, maxHeartRate: 165, source: "Apple Watch"),
        ]
        }
        allWorkouts = workouts

        // Two years a day, oldest first, like the real import: `day` counts up to today (730 − 1).
        // A slow seasonal swing, a weekly rhythm and a little noise, so every Trends window —
        // a week to a year — has something to say.
        let days = 730
        func series(every: Int = 1, _ value: (Double) -> Double) -> [MetricPoint] {
            stride(from: 0, to: days, by: every).map { i in
                let date = cal.date(byAdding: .day, value: i - (days - 1), to: cal.startOfDay(for: now)) ?? now
                return MetricPoint(date: date, value: value(Double(i)))
            }
        }
        func noise(_ d: Double) -> Double { sin(d * 12.9898) * 0.5 + sin(d * 4.1414) * 0.5 }
        func weekend(_ d: Double) -> Double {
            let weekday = cal.component(.weekday, from: cal.date(byAdding: .day, value: Int(d) - (days - 1), to: now) ?? now)
            return weekday == 1 || weekday == 7 ? 1 : 0
        }
        var t = HealthTrends()
        t.restingHR = series { 60 - $0 * 0.006 + 2 * sin($0 / 9) + noise($0) }          // improving (down)
        t.hrv = series { 44 + $0 * 0.012 + 6 * sin($0 / 5) + 2 * noise($0) }             // improving (up)
        t.respiratory = series { 15 + 0.2 * sin($0 / 7) }                                // flat
        t.vo2Max = series(every: 5) { 44 - $0 * 0.004 + sin($0 / 20) }                   // sparse, easing off
        t.sleepHours = series { 7.1 + 0.6 * sin($0 / 3.1) + 0.3 * noise($0) }
        t.bodyMassKg = series(every: 4) { 79 - $0 * 0.003 + 0.4 * sin($0 / 11) }
        t.bodyFatPercentage = series(every: 7) { 0.19 - $0 * 0.00002 }
        t.leanBodyMassKg = series(every: 7) { 63.5 + $0 * 0.001 }
        t.bodyMassIndex = series(every: 4) { 24.4 - $0 * 0.001 }
        // Totals: busier lately than a year ago, a bit quieter than last quarter's peak.
        let season = { (d: Double) in 1 + 0.18 * sin((d - 520) / 60) }
        // Which way the last week went depends on the day the sample is made; a marketing capture
        // shouldn't come out all red one morning and all green the next. Steps and energy up a
        // little on the week, the others as they fall.
        let lift = { (d: Double) in SmartScheduleStore.isStoreCapture && d >= Double(days - 8) ? 1.14 : 1.0 }
        t.steps = series { d in (17_000 * season(d) * (1 + 0.25 * weekend(d)) + 2_500 * noise(d)) * lift(d) }
        t.activeEnergyKcal = series { d in (820 * season(d) + 120 * noise(d)) * lift(d) }
        t.basalEnergyKcal = series { 1_760 + 25 * noise($0) }
        t.exerciseMinutes = series { d in max(0, 62 * season(d) + 25 * noise(d)) }
        t.flightsClimbed = series { d in max(0, 12 * season(d) + 5 * noise(d)) }
        t.walkingSpeedMetersPerSecond = series { 1.36 + 0.03 * sin($0 / 45) }
        t.walkingHeartRate = series { 104 - $0 * 0.004 + 3 * noise($0) }
        // Today so far: an unfinished day, which Trends leaves out.
        for key in [\HealthTrends.steps, \.activeEnergyKcal, \.exerciseMinutes, \.flightsClimbed] {
            if let last = t[keyPath: key].indices.last { t[keyPath: key][last].value *= 0.3 }
        }
        t.nights = Self.sampleNights(now: now, calendar: cal)
        storedTrends = t
    }
    #endif
}

extension HKWorkoutActivityType {
    /// Reverse of `displayName`, for writing a Watch session back as an HKWorkout.
    init(displayName: String) {
        switch displayName {
        case "Running":     self = .running
        case "Walking":     self = .walking
        case "Cycling":     self = .cycling
        case "Hiking":      self = .hiking
        // The Watch offers pool and open water as separate rows because HealthKit configures the
        // two sessions differently. Both are still swims: without these the name falls through to
        // `.other` and a recorded swim lands in Apple Health as an unnamed workout.
        case "Swimming", "Pool Swim", "Open Water":
            self = .swimming
        case "Strength":    self = .traditionalStrengthTraining
        case "HIIT":        self = .highIntensityIntervalTraining
        case "Yoga":        self = .yoga
        case "Pilates":     self = .pilates
        case "Core":        self = .coreTraining
        case "Elliptical":  self = .elliptical
        case "Rowing":      self = .rowing
        case "Stairs":      self = .stairClimbing
        case "Tennis":      self = .tennis
        case "Soccer":      self = .soccer
        case "Basketball":  self = .basketball
        case "Golf":        self = .golf
        case "Kickboxing":  self = .kickboxing
        case "Jump Rope":   self = .jumpRope
        case "Dance":       self = .cardioDance
        case "Cardio":      self = .mixedCardio
        case "Flexibility": self = .flexibility
        case "Cooldown":    self = .cooldown
        default:            self = .other
        }
    }

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .coreTraining: return "Core"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stairs"
        case .tennis: return "Tennis"
        case .soccer: return "Soccer"
        case .basketball: return "Basketball"
        case .golf: return "Golf"
        case .kickboxing: return "Kickboxing"
        case .jumpRope: return "Jump Rope"
        case .cardioDance, .socialDance: return "Dance"
        case .mixedCardio: return "Cardio"
        case .flexibility: return "Flexibility"
        case .cooldown: return "Cooldown"
        default: return "Workout"
        }
    }
}

/// The Watch's minute-by-minute night steps (`NightMotionReport`), kept for two weeks. Only
/// the phone gets them; the Mac sees the nights they shaped.
@MainActor final class NightMotionStore {
    static let shared = NightMotionStore()

    private(set) var windows: [NightMotionReport.Window] = []
    private let url = AppSupport.directory.appendingPathComponent("night-motion.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([NightMotionReport.Window].self, from: data) {
            windows = saved
        }
    }

    /// A window the Watch sends again (it was still going the first time) replaces the old one.
    func merge(_ report: NightMotionReport) {
        let incoming = Set(report.windows.map(\.start))
        let cutoff = Date().addingTimeInterval(-16 * 86_400)
        windows = (windows.filter { !incoming.contains($0.start) } + report.windows)
            .filter { $0.end > cutoff }
            .sorted { $0.start < $1.start }
        if let data = try? JSONEncoder().encode(windows) { try? HealthFileProtection.write(data, to: url) }
    }
}
