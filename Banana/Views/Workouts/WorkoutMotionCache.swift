import Foundation

/// Off-main-actor loading of `WorkoutMotionAnalysis.Result`/`WorkoutHandPath.Analysis`, kept in
/// memory for this launch AND persisted to disk across launches via `WorkoutMotionDiskCache`.
///
/// This used to be memory-only, by design: the original doc comment here reasoned that a disk
/// cache would be invalidated by CloudKit's per-launch re-download churn. That concern was real
/// but the fix was wrong — the answer is a cache keyed on the raw `.samples` file's byte count
/// (survives a same-content re-download) rather than no disk cache at all. See
/// `WorkoutMotionDiskCache`'s doc comment for the measured cost this was leaving on the table:
/// opening a workout's Motion section re-ran the full decode/band-pass/autocorrelate/FFT pipeline
/// from scratch on EVERY launch, for every workout ever reopened — measured at up to ~1.1 seconds
/// for the owner's real 72-lap swim in the Debug configuration `tools/ios-install.sh` actually
/// installs. The view still never touches the raw sample array directly: a `Task.detached` builds
/// a `Sendable` payload and hands back only the finished result.
@MainActor
final class WorkoutMotionCache: ObservableObject {
    static let shared = WorkoutMotionCache()

    /// In-memory copy of whatever `entry(for:fitness:)` last resolved — a disk-cache hit or a
    /// fresh derivation, either way. Keeps a second open of the same workout free within one
    /// launch even though `entry(for:fitness:)` would itself resolve quickly from disk.
    private var cache: [UUID: WorkoutMotionCacheEntry] = [:]
    private var inFlight: [UUID: Task<WorkoutMotionCacheEntry, Never>] = [:]
    private var rawCache: [UUID: [FitnessSample]] = [:]
    private var rawInFlight: [UUID: Task<[FitnessSample], Never>] = [:]

    /// The single read/decode of the raw `.accel`/`.distance`/`.strokeCount`/`.speed`/
    /// `.strideLength` sample stream that `entry(for:fitness:)` builds both derived products
    /// from. `FitnessStore.samples(for:kinds:)` has no cache of its own — every call re-reads and
    /// re-decodes the raw sample file from disk — so without this shared fetch, loading a pool
    /// swim's Motion section (the one case that needs both derived products) read and decoded the
    /// same file twice, back-to-back, before anything rendered. `.speed`/`.strideLength` were
    /// added alongside `.accel` here (not fetched separately) for the same reason —
    /// `WorkoutMotionAnalysis.analyze` needs them for `stepRateAnchorHz`; `WorkoutHandPath.analyze`
    /// simply ignores the two kinds it has no use for.
    ///
    /// Only reached on a disk-cache miss now (see `entry(for:fitness:)`) — a warm disk cache never
    /// touches the raw `.samples` file at all.
    private func rawMotionSamples(for workout: FitnessSessionSummary, fitness: FitnessStore) async -> [FitnessSample] {
        if let cached = rawCache[workout.id] { return cached }
        if let running = rawInFlight[workout.id] { return await running.value }
        let task = Task<[FitnessSample], Never> {
            guard fitness.hasLocalSamples(workout.id) else { return [] }
            return await fitness.samples(for: workout.id, kinds: [.accel, .distance, .strokeCount, .speed, .strideLength])
        }
        rawInFlight[workout.id] = task
        let raw = await task.value
        rawInFlight[workout.id] = nil
        rawCache[workout.id] = raw
        return raw
    }

    /// Returns `nil` when there is no local raw-sample file (`FitnessStore.hasLocalSamples` is
    /// false) or the file has no `.accel` records. Never touches the main actor with the raw
    /// array — `FitnessStore.samples(for:kinds:)` already hops to `Task.detached` internally;
    /// `WorkoutMotionAnalysis.analyze` itself also runs detached.
    func result(for workout: FitnessSessionSummary, fitness: FitnessStore) async -> WorkoutMotionAnalysis.Result? {
        await entry(for: workout, fitness: fitness).result
    }

    /// Same disk/memory-backed cache as `result(for:fitness:)` — both come from the same
    /// `entry(for:fitness:)` derivation, see that method's doc comment for why they're always
    /// computed together rather than independently.
    func handPath(for workout: FitnessSessionSummary, fitness: FitnessStore) async -> WorkoutHandPath.Analysis? {
        await entry(for: workout, fitness: fitness).handPath
    }

    /// The one place `result`/`handPath` are actually derived (or loaded from disk). Both fields
    /// are always resolved together, even when only one is ultimately read: attempting
    /// `WorkoutHandPath.analyze` for a non-swim is a single cheap guard on `poolLengthMeters`
    /// (no accel/lap work happens before that check fails), so computing both up front avoids
    /// ever needing a read-modify-write against an already-written disk cache file — there is
    /// exactly one derive-and-persist pass per workout per cache version, not two independently
    /// timed ones that would otherwise have to merge.
    private func entry(for workout: FitnessSessionSummary, fitness: FitnessStore) async -> WorkoutMotionCacheEntry {
        if let cached = cache[workout.id] { return cached }
        if let running = inFlight[workout.id] { return await running.value }
        let task = Task<WorkoutMotionCacheEntry, Never> {
            let sampleFileSize = fitness.samplesFileSize(workout.id)
            let cacheURL = fitness.motionCacheURL(workout.id)
            // `Task.detached`, not a direct call: decoding a multi-megabyte cache file (measured
            // 24-50 ms — see `WorkoutMotionDiskCache`'s doc comment) must not block the main actor
            // any more than the raw-sample decode this cache exists to avoid does.
            if let sampleFileSize {
                let diskLoad = Task.detached(priority: .userInitiated) {
                    WorkoutMotionDiskCache.load(from: cacheURL, sampleFileSize: sampleFileSize)
                }
                if let disk = await diskLoad.value {
                    return disk
                }
            }

            let raw = await self.rawMotionSamples(for: workout, fitness: fitness)
            let accel = raw.filter { $0.kind == .accel }

            let result: WorkoutMotionAnalysis.Result?
            if accel.isEmpty {
                result = nil
            } else {
                let kind = WorkoutActivityKind(activity: workout.activity)
                // `.distance` samples are appended for every activity kind (run/cycle statistics
                // batches included, not just pool-swim lap turns — see
                // BananaWatch/WorkoutRecorder.swift), so `lapMarks` must only run for activities
                // that actually have laps. Otherwise a run or ride gets spurious "lap" boundaries
                // and `Cycle.lap` gets populated where the field's contract says it must stay empty.
                let boundaries = kind.usesLaps ? Self.lapBoundaries(from: raw) : []
                // `hasFootstepPeriodicity`, NOT `usesPace` — see that property's doc comment.
                // `usesPace` is a display decision (does the interface show a pace figure) that
                // also happens to be true for strength/yoga, since neither is a swim or a ride;
                // using it here to pick the SIGNAL band routed strength/yoga into `.runOrWalk`'s
                // footstep band and gate, which is exactly what fabricated the 1,526 "cycles"
                // measured on a real 77-minute strength recording (id 32D848BF…, ~115k accel
                // samples) at a median of 107/min — there is no repeating 107/min motion in a
                // strength session. `.other`'s much stricter periodicity gate (see
                // `WorkoutMotionAnalysis.ActivityHint.correlationFloor`) is what actually erases
                // those on the same recording: 0 cycles, down from 1,526.
                let hint: WorkoutMotionAnalysis.ActivityHint = kind.isSwim ? .swim : kind.hasFootstepPeriodicity ? .runOrWalk : .other
                // Ground-truth step-rate anchor from measured speed ÷ strideLength — see
                // `WorkoutMotionAnalysis.stepRateAnchorHz`'s doc comment. Harmless to compute and
                // pass for every hint: `analyze` only consults it for `.runOrWalk`, and it's empty
                // for any workout without `.strideLength`/`.speed` samples (pre-17-Aug recordings,
                // or an activity that never records them), which is exactly when that hint falls
                // back to a spectral estimate instead.
                let anchor = WorkoutMotionAnalysis.stepRateAnchorHz(from: raw)
                result = await Task.detached(priority: .userInitiated) {
                    WorkoutMotionAnalysis.analyze(accelSamples: accel, lapBoundaries: boundaries, hint: hint,
                                                  cadenceAnchorHz: anchor)
                }.value
            }

            let handPath: WorkoutHandPath.Analysis?
            if raw.isEmpty {
                handPath = nil
            } else {
                let poolLengthMeters = workout.poolLengthMeters
                handPath = await Task.detached(priority: .userInitiated) {
                    WorkoutHandPath.analyze(samples: raw, poolLengthMeters: poolLengthMeters)
                }.value
            }

            let fresh = WorkoutMotionCacheEntry(version: WorkoutMotionDiskCache.version,
                                                 sampleFileSize: sampleFileSize ?? -1,
                                                 result: result, handPath: handPath)
            // Only a real file size is a trustworthy fingerprint — see `samplesFileSize`'s doc
            // comment. Without one (the raw file went missing mid-derivation, an edge case the
            // `hasLocalSamples` gate at the call site already makes rare) this workout's result
            // still gets returned and held in memory for the rest of this launch; it just never
            // lands on disk for a future one to find.
            if let sampleFileSize {
                await Task.detached(priority: .utility) {
                    WorkoutMotionDiskCache.save(fresh, to: cacheURL)
                }.value
            }
            return fresh
        }
        inFlight[workout.id] = task
        let fresh = await task.value
        inFlight[workout.id] = nil
        cache[workout.id] = fresh
        return fresh
    }

    /// Lap-start timestamps, cumulative seconds since the workout start — `boundaries[i]` is the
    /// start time of lap `i + 1`.
    ///
    /// This used to sum `FitnessLap.duration` sequentially. That is a real bug: `duration` is
    /// computed independently on-device and drifts roughly 50 seconds from the true lap-turn
    /// times over one long swim (measured in the hand-path validation prototype — see
    /// `scratchpad/handpath/run_output.txt`). The watch stamps a `.distance` sample AND a
    /// `.strokeCount` sample at every lap turn, both carrying the real elapsed-time timestamp of
    /// that turn; `WorkoutHandPath.lapMarks` reads those timestamps directly, so this now uses
    /// the actually-measured turn events instead of a derived, drifting estimate of them.
    private static func lapBoundaries(from samples: [FitnessSample]) -> [TimeInterval] {
        [0] + WorkoutHandPath.lapMarks(from: samples)
    }

    /// Called by the detail view on disappear if the workout was long (>60 min accel stream) so a
    /// large analysis result isn't held forever just because the workout stays in `summaries`.
    /// Memory-only: this never touches the disk cache `entry(for:fitness:)` writes, so a workout
    /// evicted here is still a fast disk-cache hit (not a full re-derivation) the next time its
    /// Motion section opens, in this launch or a later one.
    func evict(_ id: UUID) {
        cache[id] = nil
        rawCache[id] = nil
    }
}
