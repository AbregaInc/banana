import Foundation
import SwiftUI
import os

/// Stores recorded workout sessions from the Watch. Only lightweight per-session
/// **summaries** are kept in memory (and in a small index file); each session's raw
/// samples live in a separate compact binary file, read from disk **only when the
/// session is opened**. This keeps memory flat no matter how much history accrues
/// (a 1-hour run is ~180k motion samples).
///
/// This index/samples split is also this store's central data-safety asymmetry: `summaries.json`
/// and each `<id>.samples` file are two independent files on disk, and either can go missing
/// without the other. A summary surviving with no local `.samples` file is a normal, already-
/// handled state — `hasLocalSamples`/`samples(for:)` below treat it as "not yet downloaded," never
/// as an error (a CloudKit-synced summary commonly outlives its multi-megabyte asset landing
/// locally). The other direction is the dangerous one: a `.samples` file surviving with NO
/// matching summary — which is exactly what happens to a summary that fails to decode and gets
/// dropped when `init()` loads `summaries.json` (see its doc comment, and
/// `FitnessSessionSummary.init(from:)`). Nothing here ever deletes that orphaned file, but nothing
/// automatically reconnects it to the index either; see `logOrphanedSampleFilesIfAny` for how that
/// loss is at least made discoverable rather than silent.
@MainActor
final class FitnessStore: ObservableObject {
    static let shared = FitnessStore()
    /// Fixed ID used exclusively by the debug screenshot fixture. It must never survive into a
    /// real profile (an earlier audit build accidentally persisted it into production storage).
    private static let previewSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    /// The screenshot run's gym session: GPS that never left the building.
    private static let previewGymSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    // `nonisolated` — `Logger` is inherently thread-safe, and this needs to be usable from both
    // MainActor call sites and the background decode task in `init()`, which runs off the main
    // actor by design (see its doc comment).
    private nonisolated static let log = Logger(subsystem: "com.boris.banana", category: "fitness")

    @Published private(set) var summaries: [FitnessSessionSummary] = []
    private var isLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set when `summaries.json` failed to decode AND could not even be quarantined (copied aside
    /// for safekeeping) — see `init()`'s decode. In that situation there is no backup
    /// anywhere, so `saveIndex`/`persistIndexNow` refuse to run rather than risk being the thing
    /// that actually destroys years of the owner's only copy of his recorded workouts. Stays true
    /// for the rest of this launch; a relaunch (after the underlying problem — e.g. a full disk —
    /// is resolved by hand) gets a fresh attempt.
    private var saveIsUnsafe = false

    /// Nesting depth of `applyingCloudBatch`. >0 while a CloudKit fetched-changes batch is being
    /// applied record-by-record, so `adoptCloudSummary`/`removeCloudSummary` mutate
    /// `cloudBatchWorking` instead of `summaries` directly — see `applyingCloudBatch`.
    private var cloudBatchDepth = 0
    /// Working copy of `summaries` mutated in place while a batch is open; `nil` outside a batch.
    /// Seeded from `summaries` when the outermost batch opens, assigned back — ONE publish — when
    /// it closes.
    private var cloudBatchWorking: [FitnessSessionSummary]?
    /// Whether any record inside the current batch actually changed `cloudBatchWorking`, so an
    /// all-no-op batch (e.g. a re-delivered fetch with nothing new) skips the index write too.
    private var cloudBatchIndexDirty = false
    /// What a batch found out and tells once `summaries` holds the batch's result: recordings
    /// replaced by another device's edit, and copies that have to be marked edited again.
    private var cloudBatchRecordingChanges: [(id: UUID, start: Date, end: Date)] = []
    private var cloudBatchRemarks: [UUID] = []

    /// A workout's recording was replaced: trimmed or reverted here, or by an edit that arrived
    /// from another device. Called with the span it had before. The phone hangs Apple Health's
    /// copy on this (`WorkoutHealthFollow`); nothing listens on an iPad or the Mac.
    var onRecordingChanged: ((_ id: UUID, _ previousStart: Date, _ previousEnd: Date) -> Void)?

    private var dir: URL {
        let d = AppSupport.directory
            .appendingPathComponent("Fitness", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        HealthFileProtection.protectExisting(d)
        return d
    }
    private var indexURL: URL { dir.appendingPathComponent("summaries.json") }
    private func samplesURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).samples") }
    /// Where `WorkoutMotionDiskCache` persists its derived-analysis cache for one workout — see
    /// that type's doc comment (`WorkoutMotionDiskCache.swift`) for why this lives beside the raw
    /// `.samples` file instead of inside `summaries.json`/CloudKit.
    func motionCacheURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).motion-cache.json") }
    private static let persistenceQueue = DispatchQueue(
        label: "com.boris.banana.fitness-persistence",
        qos: .utility)

    /// The raw `.samples` file's current size in bytes, or `nil` if it isn't on disk.
    /// `WorkoutMotionDiskCache` uses this as its content fingerprint — see that type's doc comment
    /// for why a byte count survives a CloudKit re-download where a file timestamp would not.
    func samplesFileSize(_ id: UUID) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: samplesURL(id).path) else { return nil }
        return attrs[.size] as? Int
    }

    /// Whether this workout's raw `.samples` file is actually present on disk right now — the
    /// authoritative "raw data on this Mac" signal for the hero badge, the Replay map's
    /// full-rate/coarse fork, and the Motion section's gate. `sampleCount > 0` on the summary is
    /// NOT sufficient by itself: a summary can sync (and report a nonzero sample count) well
    /// before — or without ever having — its much larger raw `.samples` companion file land here.
    func hasLocalSamples(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: samplesURL(id).path)
    }

    /// A summary `init()`'s decode drops (one corrupt record among many — see `init()` above and
    /// `FitnessSessionSummary.init(from:)`) leaves its raw `<id>.samples` companion, often
    /// several MB, sitting on disk with nothing left in `summaries` to reference it. Deliberately
    /// never deleted (this fix, like the rest of the data-safety sweep, never destroys a file only
    /// suspected of being orphaned), and — absent the dropped summary's `id`, exactly the field
    /// decoding failed to recover — not automatically reconnectable here either. This makes the
    /// loss discoverable instead of silent: every `.samples` file with no matching summary id,
    /// once the index has finished loading, is logged so a human can decide whether to
    /// hand-rebuild its summary (`FitnessSessionSummary(session:)` from the raw file — the same
    /// reconstruction `backfillDerivedSeriesIfPossible`/`migrateLegacyIfNeeded` already do) or
    /// leave it be. Only called when `init()`'s decode actually dropped something, so an ordinary
    /// launch never pays for the directory listing.
    private func logOrphanedSampleFilesIfAny() {
        let knownIDs = Set(summaries.map(\.id))
        let directory = dir
        Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
            for entry in entries where entry.pathExtension == "samples" {
                guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
                      !knownIDs.contains(id) else { continue }
                let bytes = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                Self.log.error("orphaned raw sample file \(entry.lastPathComponent, privacy: .public) (\(bytes, privacy: .public) bytes) has no matching summary in summaries.json — left on disk untouched.")
            }
        }
    }

    func flushPendingWrites() async {
        await withCheckedContinuation { continuation in
            Self.persistenceQueue.async { continuation.resume() }
        }
    }

    /// Cloud sync must not seed from an empty observable array while the on-disk workout index is
    /// still decoding. An empty initial seed looks valid but silently omits the whole history.
    func whenLoaded() async {
        if isLoaded { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    init() {
        // Decode + legacy-migration probe off the main thread (they were ~40 ms of first-frame
        // path and grow with workout count). A Watch workout ingested before the decode lands
        // is merged, not clobbered.
        //
        // `try? JSONDecoder().decode([FitnessSessionSummary].self, ...) ?? []` used to treat ANY
        // decode failure — one corrupt summary among hundreds, or simply a field added without a
        // tolerant decoder (see `FitnessSessionSummary.init(from:)`) — as "nothing here," and the
        // very next `saveIndex()` (any workout ingested from the Watch, any trim) would then have
        // written that emptiness permanently over `summaries.json`. `FitnessIndexLoader`/
        // `LossyArray` (`Shared/FitnessModels.swift`) fix that: one bad summary costs one summary,
        // and a wholly unparseable file is quarantined before anything can overwrite it.
        let url = indexURL
        Task.detached(priority: .userInitiated) { [weak self] in
            var decoded: [FitnessSessionSummary] = []
            var droppedCount = 0
            var mustRefuseSaves = false
            switch FitnessIndexLoader.load(from: url) {
            case .empty:
                break
            case let .loaded(snapshot):
                droppedCount = snapshot.droppedCount
                if droppedCount > 0 {
                    Self.log.error("summaries.json: dropped \(droppedCount, privacy: .public) corrupt summary/summaries on load; everything else loaded normally. Each dropped summary's raw <id>.samples file, if it has one, is left on disk — orphaned, not deleted.")
                }
                // Same guard `CloudFitnessSync.apply` enforces on the way in from CloudKit (see
                // `FitnessSessionSummary.hasPlausibleStart`), enforced again here so a phantom
                // record that somehow already reached this disk — adopted by a build that
                // predates the guard, or restored from an old backup — cannot repopulate the
                // in-memory index either. Each rejection is logged by id so the scale of a
                // recurrence stays visible, matching the cloud side's per-record logging.
                for id in snapshot.rejectedImplausibleIDs {
                    Self.log.error("summaries.json: rejected workout \(id.uuidString, privacy: .public) — implausible start date; not loaded into the index.")
                }
                decoded = snapshot.summaries
            case let .corrupt(error, quarantinedTo):
                if let quarantinedTo {
                    Self.log.error("summaries.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public). Starting empty — history is recoverable from the quarantine copy, and normal saves will only ever touch summaries.json from here on.")
                } else {
                    mustRefuseSaves = true
                    Self.log.fault("summaries.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save until this is resolved by hand; the original is still at summaries.json, untouched.")
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if mustRefuseSaves { self.saveIsUnsafe = true }
                if self.summaries.isEmpty {
                    self.summaries = decoded
                } else if !decoded.isEmpty {
                    let existing = Set(self.summaries.map(\.id))
                    self.summaries.append(contentsOf: decoded.filter { !existing.contains($0.id) })
                    self.summaries.sort { $0.start > $1.start }
                }
                self.removeLeakedPreviewFixture()
                self.migrateLegacyIfNeeded()
                self.markEditsMadeBeforeTheMark()
                CloudFitnessSync.shared.seedLocalSummaries(self.summaries)
                self.isLoaded = true
                for waiter in self.loadWaiters { waiter.resume() }
                self.loadWaiters.removeAll()
                self.backfillDerivedSeriesIfPossible()
                if droppedCount > 0 { self.logOrphanedSampleFilesIfAny() }
                LaunchClock.mark("fitness.loaded")
            }
        }
        LaunchClock.mark("fitness.init")
    }

    /// Fired once when a genuinely new session is ingested (phone writes it to HealthKit). One
    /// that arrives before it's set — the Watch's queued workout delivered as the app starts,
    /// before startup has wired this — is held and handed over when it is, not dropped (it used
    /// to miss Apple Health, and what's due after a workout never heard of it).
    var onIngest: ((FitnessSession) -> Void)? {
        didSet {
            guard let onIngest, !heldForIngest.isEmpty else { return }
            let held = heldForIngest
            heldForIngest = []
            held.forEach(onIngest)
        }
    }
    private var heldForIngest: [FitnessSession] = []

    private func ingested(_ session: FitnessSession) {
        if let onIngest { onIngest(session) } else { heldForIngest.append(session) }
    }

    /// Called by `PhoneConnectivity` when a session arrives from the Watch.
    @discardableResult
    func ingest(_ session: FitnessSession, stagedSamplesURL: URL? = nil) -> Bool {
        guard let inserted = install(session, stagedSamplesURL: stagedSamplesURL) else { return false }
        saveIndex()
        if inserted, let summary = summaries.first(where: { $0.id == session.id }) {
            sendEverywhere(summary)
        }
        if inserted { ingested(session) }
        return true
    }

    /// Watch receipt has stronger durability semantics than local/debug ingest: the Watch deletes
    /// its sole copy only after our ACK, so wait until both the raw sample file and summaries.json
    /// are on disk before returning true.
    func ingestFromWatch(_ session: FitnessSession, stagedSamplesURL: URL?) async -> Bool {
        guard let inserted = install(session, stagedSamplesURL: stagedSamplesURL) else { return false }
        let persisted = await persistIndexNow()
        guard persisted else { return false }
        CloudBackup.shared.schedule()
        if inserted, let summary = summaries.first(where: { $0.id == session.id }) {
            sendEverywhere(summary)
        }
        if inserted { ingested(session) }
        return true
    }

    /// Install the raw file and, for a genuinely new id, its in-memory summary.
    /// Returns `true` for a new row, `false` for an already-known row, nil on failure.
    private func install(_ session: FitnessSession, stagedSamplesURL: URL?) -> Bool? {
        let destination = samplesURL(session.id)
        let alreadyKnown = summaries.contains(where: { $0.id == session.id })

        // A retry can arrive after the index persisted but before/without the raw file. Do not
        // throw away the Watch's retry merely because the lightweight row already exists.
        if alreadyKnown, FileManager.default.fileExists(atPath: destination.path) {
            if let stagedSamplesURL { try? FileManager.default.removeItem(at: stagedSamplesURL) }
            return false
        }
        if let stagedSamplesURL {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: stagedSamplesURL, to: destination)
            } catch {
                // The decoded session is still available, so a failed temp-file move is
                // recoverable without dropping the workout.
                try? FitnessSample.encodeBinary(session.samples).write(to: destination, options: .atomic)
                try? FileManager.default.removeItem(at: stagedSamplesURL)
            }
        } else {
            try? FitnessSample.encodeBinary(session.samples).write(to: destination, options: .atomic)
        }
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        guard !alreadyKnown else { return false }
        summaries.insert(FitnessSessionSummary(session: session), at: 0)
        summaries.sort { $0.start > $1.start }
        return true
    }

    /// Reconstruct a full session (summary + samples) — for re-saving a trimmed HKWorkout.
    func session(for id: UUID) async -> FitnessSession? {
        guard let s = summaries.first(where: { $0.id == id }) else { return nil }
        let samples = await samples(for: id)
        return FitnessSession(id: s.id, start: s.start, end: s.end, activity: s.activity,
                              avgHeartRate: s.avgHeartRate, totalEnergy: s.totalEnergy,
                              totalDistance: s.totalDistance, poolLengthMeters: s.poolLengthMeters,
                              laps: s.laps, outdoorConditions: s.outdoorConditions, pauses: s.pauses, samples: samples)
    }

    /// Load a session's raw samples from disk, off the main thread. Call from the
    /// detail view; never held in `summaries`.
    /// - Parameter kinds: forwarded to `FitnessSample.decodeBinary(_:kinds:)` — pass the subset a
    ///   caller actually renders (e.g. `[.heartRate, .location]`) so the retained array doesn't
    ///   hold the full raw accel/gyro stream when only a couple of series are ever displayed.
    func samples(for id: UUID, kinds: Set<FitnessSample.Kind>? = nil) async -> [FitnessSample] {
        let url = samplesURL(id)
        return await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return FitnessSample.decodeBinary(data, kinds: kinds)
        }.value
    }

    /// The complete, opaque workout stream is the canonical record for cross-device analysis.
    /// CloudKit reads this file directly into a CKAsset; callers must never rewrite it while an
    /// upload is being prepared.
    func samplesFileForCloudSync(_ id: UUID) -> URL? {
        let url = samplesURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A remote workout becomes visible only once its companion raw asset is safely local. This
    /// avoids a summary looking "complete" on the Mac while later analysis has no samples.
    ///
    /// An edit made on another device arrives here too (`WorkoutEdits`): the original this device
    /// holds is kept so it can revert by itself, dropped once the workout is the original again,
    /// and the phone is told the recording changed so Apple Health follows.
    func adoptCloudWorkout(_ summary: FitnessSessionSummary, samplesAssetURL: URL?) async -> Bool {
        var summary = summary
        let id = summary.id
        let local = (cloudBatchWorking ?? summaries).first { $0.id == id }
        let original = originalSummary(id)
        let destination = samplesURL(id)
        let replacesRecording = samplesAssetURL != nil && FileManager.default.fileExists(atPath: destination.path)
        let keeping = WorkoutEdits.keeping(local: local, incoming: summary, original: original,
                                           replacesRecording: replacesRecording)
        if keeping == .keepOriginal, let local {
            // Before the edited recording replaces it. Without the copy the edit still arrives:
            // this device then asks another one to revert, as one that never had the original does.
            let kept = await keepOriginal(of: local)
            if !kept { Self.log.error("couldn't keep the original of \(id.uuidString, privacy: .public) before another device's edit replaced it") }
        }
        if let samplesAssetURL {
            let staged = dir.appendingPathComponent(".\(summary.id.uuidString).samples.download")
            let installed = await Task.detached(priority: .utility) {
                let files = FileManager.default
                do {
                    try? files.removeItem(at: staged)
                    try files.copyItem(at: samplesAssetURL, to: staged)
                    if files.fileExists(atPath: destination.path) {
                        _ = try files.replaceItemAt(destination, withItemAt: staged)
                    } else {
                        try files.moveItem(at: staged, to: destination)
                    }
                    return true
                } catch {
                    try? files.removeItem(at: staged)
                    return false
                }
            }.value
            guard installed else { return false }
        }
        switch keeping {
        case .dropOriginal:
            try? FileManager.default.removeItem(at: backupSamplesURL(id))
            try? FileManager.default.removeItem(at: backupSummaryURL(id))
        case .markEdited:
            if let original {
                summary.edit = SessionEdit(original: original, at: local?.edit?.editedAt ?? Date())
                if cloudBatchDepth > 0 { cloudBatchRemarks.append(id) } else { sendSoon(id) }
            }
        case .keepOriginal, .nothing:
            break
        }
        adoptCloudSummary(summary)
        if let local, WorkoutEdits.healthMustFollow(local: local, incoming: summary,
                                                    recordingArrived: samplesAssetURL != nil) {
            let change = (id: id, start: local.start, end: local.end ?? local.start)
            if cloudBatchDepth > 0 {
                cloudBatchRecordingChanges.append(change)
            } else {
                onRecordingChanged?(change.id, change.start, change.end)
            }
        }
        return true
    }

    /// Send a workout's summary once the record that is being applied right now has been dealt
    /// with (its bookkeeping would otherwise count this as already sent).
    private func sendSoon(_ id: UUID) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let summary = self.summaries.first(where: { $0.id == id }) else { return }
            self.sendEverywhere(summary)
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: samplesURL(id))
        try? FileManager.default.removeItem(at: backupSamplesURL(id))
        try? FileManager.default.removeItem(at: backupSummaryURL(id))
        summaries.removeAll { $0.id == id }
        saveIndex()
        CloudFitnessSync.shared.delete(id)
        MoveOver.deleted(type: Self.spaceType, ids: [id.uuidString])
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md; `WorkoutAdapter`)

    static let spaceType = "health.workout"

    /// A workout changed here: iCloud's sync as before (its mode decides whether it writes), and
    /// the data platform (`MoveOver`).
    private func sendEverywhere(_ summary: FitnessSessionSummary) {
        CloudFitnessSync.shared.upsert(summary)
        MoveOver.changed(type: Self.spaceType, ids: [summary.id.uuidString])
    }

    /// Other devices' summaries from the data platform, in one publish and one index write; into an
    /// iCloud batch's working copy while one is open, as `adoptCloudSummary` does.
    func adoptSpaceSummaries(_ incoming: [FitnessSessionSummary]) {
        guard !incoming.isEmpty else { return }
        applySpaceChange { FitnessSpaceChanges.adopting(incoming, into: $0) }
    }

    /// Other devices' deletes from the data platform, in one publish (`removeCloudSummary`'s rule).
    func removeSpaceWorkouts(_ ids: [UUID]) {
        let gone = Set(ids)
        for id in gone {
            try? FileManager.default.removeItem(at: samplesURL(id))
            try? FileManager.default.removeItem(at: backupSamplesURL(id))
            try? FileManager.default.removeItem(at: backupSummaryURL(id))
        }
        applySpaceChange { $0.filter { !gone.contains($0.id) } }
    }

    private func applySpaceChange(_ change: ([FitnessSessionSummary]) -> [FitnessSessionSummary]) {
        var current = summaries
        var working = cloudBatchWorking
        let open = cloudBatchDepth > 0
        guard FitnessSpaceChanges.apply(change, summaries: &current, working: &working, batchOpen: open) else { return }
        if open {
            cloudBatchWorking = working
            cloudBatchIndexDirty = true
        } else {
            summaries = current
            saveIndex()
        }
    }

    /// A recording that arrived for a workout with none here yet (a move, which is instant on one
    /// volume). Views waiting on it look again (`samplesArrived`).
    @discardableResult
    func installSpaceSamples(_ id: UUID, from file: URL) -> Bool {
        let destination = samplesURL(id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return true }
        let files = FileManager.default
        guard (try? files.moveItem(at: file, to: destination)) != nil
                || (try? files.copyItem(at: file, to: destination)) != nil else { return false }
        samplesArrived += 1
        return true
    }

    /// Bumped when a recording arrives from another device.
    @Published private(set) var samplesArrived = 0

    /// Fetches a workout's recording from the data platform (`WorkoutAdapter`, lazy on an iPad or
    /// a Mac). Set while the engine runs.
    var fetchSpaceSamples: ((UUID) async -> Bool)?

    /// Whether the recording is here, fetching it first if the data platform has it: a detail
    /// that needs the samples asks this before reading them.
    func ensureSamples(_ id: UUID) async -> Bool {
        if hasLocalSamples(id) { return true }
        guard let fetch = fetchSpaceSamples else { return false }
        return await fetch(id) && hasLocalSamples(id)
    }

    /// Wrap a run of CloudKit-origin summary adoptions/removals (one `.fetchedRecordZoneChanges`
    /// event) so `summaries` — and therefore every observer, `WeekView` included — republishes
    /// ONCE for the whole batch instead of once per record. The CKSyncEngine backlog that
    /// delivered ~200 workout records in under a second (see the storm evidence that motivated
    /// this) used to mean ~200 `objectWillChange` fires and ~200 re-renders in that window.
    ///
    /// `adoptCloudSummary`/`removeCloudSummary` (and, through it, `adoptCloudWorkout`) still run
    /// their exact per-record logic — id dedup, sort-by-`start` descending, raw-sample file
    /// install — against a private working copy (`cloudBatchWorking`); only the single `summaries`
    /// assignment (one publish) and the index write move to batch end. Outside a batch (ingest
    /// from the Watch, a trim, the derived-series backfill sweep) nothing here changes: those
    /// paths never call this wrapper and keep publishing per call, exactly as before.
    ///
    /// Losslessness: the final `summaries` content and order are byte-for-byte identical to
    /// applying every record one at a time outside a batch — same dedup-by-id, same final sort,
    /// same file installs per record (unaffected by this wrapper; `adoptCloudWorkout` still moves
    /// each asset to disk immediately, per record, before ever touching `cloudBatchWorking`).
    /// `CloudFitnessSync`'s own per-record bookkeeping (`remember`, `revisions`, `dirty`) is
    /// untouched — this wrapper only changes when `FitnessStore` publishes and when it writes
    /// `summaries.json`, never what ends up in either.
    ///
    /// Durability: the index write moves from once-per-record to once-per-batch. This is no less
    /// durable in practice than before: CKSyncEngine only advances its persisted server change
    /// token after `handleEvent` returns for that fetch event, so a crash mid-batch makes the
    /// *next* launch's fetch re-deliver the very same un-acknowledged records — identical to a
    /// crash between two individual per-record saves under the old code, which likewise had to
    /// rely on redelivery for anything not yet reflected in `summaries.json`. Nothing fetched is
    /// ever considered durably applied mid-batch, before or after this change.
    ///
    /// Actor isolation: `FitnessStore` is `@MainActor`; `adoptCloudWorkout` awaits a file copy, so
    /// `body` may suspend with a batch open. That is safe because CKSyncEngine calls the
    /// delegate's `handleEvent` serially — one event fully handled (this `await` included) before
    /// the next is delivered (Apple's documented CKSyncEngine event-delivery contract) — and this
    /// wrapper is only ever invoked from inside `CloudFitnessSync.handleEvent`'s
    /// `.fetchedRecordZoneChanges` case, so no second batch can open concurrently on this actor.
    /// It is still written to nest (depth counter) rather than assert non-reentrancy, matching the
    /// same defensive stance `PodcastLibrary.applyingRemoteBatch` takes for the identical reason.
    func applyingCloudBatch(_ body: () async -> Void) async {
        cloudBatchDepth += 1
        if cloudBatchDepth == 1 {
            cloudBatchWorking = summaries
        }
        await body()
        cloudBatchDepth -= 1
        guard cloudBatchDepth == 0 else { return }
        let working = cloudBatchWorking
        cloudBatchWorking = nil
        let dirty = cloudBatchIndexDirty
        cloudBatchIndexDirty = false
        if let working, dirty {
            summaries = working   // one publish for the whole batch
            saveIndex()
        }
        // Only now does `summaries` hold what the batch brought.
        let changes = cloudBatchRecordingChanges
        cloudBatchRecordingChanges = []
        for change in changes { onRecordingChanged?(change.id, change.start, change.end) }
        let remarks = cloudBatchRemarks
        cloudBatchRemarks = []
        remarks.forEach(sendSoon)
    }

    /// Apply a record fetched from another one of the user's devices. This deliberately does not
    /// call the normal mutation methods: fetching a record must not echo it back to CloudKit.
    func adoptCloudSummary(_ summary: FitnessSessionSummary) {
        guard cloudBatchDepth == 0 else {
            var working = cloudBatchWorking ?? summaries
            if let index = working.firstIndex(where: { $0.id == summary.id }) {
                working[index] = summary
            } else {
                working.append(summary)
            }
            working.sort { $0.start > $1.start }
            cloudBatchWorking = working
            cloudBatchIndexDirty = true
            return
        }
        if let index = summaries.firstIndex(where: { $0.id == summary.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort { $0.start > $1.start }
        saveIndex()
    }

    /// Derivation-code version for the one-shot backfill below; bump when a rebuild would produce
    /// different derived series for the same samples. Bumped to 2 when `derivedCadenceSeries` was
    /// added — a summary already marked done at version 1 (e.g. it already had `speedSeries` and
    /// `insights`) would otherwise never be revisited even though it's missing the new series.
    private static let derivedBackfillVersion = 2
    private var derivedBackfillURL: URL { dir.appendingPathComponent("derived-backfill.json") }

    /// Older summaries predate the compact speed series. The phone still has their raw GPS
    /// samples, whereas the Mac intentionally only keeps synced summaries, so rebuild them at
    /// the source and let normal CloudKit sync deliver the upgrade everywhere.
    ///
    /// This used to run on the main actor and again on every launch: a summary whose rebuild
    /// legitimately yields no insights (no speed, no elevation) stayed a candidate forever, so
    /// each launch decoded every raw 25 Hz file and re-derived every series with the UI frozen
    /// behind it — minutes on a phone with a season of workouts. Now the decode and derivation
    /// run off the main actor, each id is attempted once per derivation version (recorded in
    /// `derived-backfill.json`), the store publishes once, and CloudKit sees only real changes.
    ///
    /// A summary `init()`'s decode drops on load (a corrupt record — see `init()` and
    /// `FitnessSessionSummary.init(from:)`) is simply never a candidate here: `candidates` is
    /// filtered from `summaries`, and a dropped summary was never added to `summaries` in the
    /// first place. Its id can be left behind in `derived-backfill.json`'s "done" map from a prior
    /// successful backfill; that entry just sits inert — nothing ever looks it up again for an id
    /// absent from `summaries` — rather than causing the every-launch storm described above.
    /// Dropping a record cannot make it a backfill candidate, let alone a repeating one.
    private func backfillDerivedSeriesIfPossible() {
        let candidates = summaries.filter(Self.needsDerivedBackfill)
        guard !candidates.isEmpty else { return }
        let sampleURLs = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, samplesURL($0.id)) })
        let doneURL = derivedBackfillURL
        let version = Self.derivedBackfillVersion

        Task.detached(priority: .utility) { [weak self] in
            var done = (try? Data(contentsOf: doneURL))
                .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
            let todo = candidates.filter { done[$0.id.uuidString] != version }
            guard !todo.isEmpty else { return }

            var rebuilt: [FitnessSessionSummary] = []
            for original in todo {
                done[original.id.uuidString] = version
                guard let url = sampleURLs[original.id], let data = try? Data(contentsOf: url) else { continue }
                let samples = FitnessSample.decodeBinary(data)
                guard !samples.isEmpty else { continue }
                let fresh = FitnessSessionSummary(session: FitnessSession(
                    id: original.id, start: original.start, end: original.end, activity: original.activity,
                    avgHeartRate: original.avgHeartRate, totalEnergy: original.totalEnergy,
                    totalDistance: original.totalDistance, poolLengthMeters: original.poolLengthMeters,
                    laps: original.laps, outdoorConditions: original.outdoorConditions,
                    pauses: original.pauses, samples: samples))
                let upgraded = Self.adoptingDerivedSeries(of: fresh, into: original)
                if upgraded != original { rebuilt.append(upgraded) }
            }
            try? JSONEncoder().encode(done).write(to: doneURL, options: .atomic)
            guard !rebuilt.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                var next = self.summaries
                var changedIDs: [UUID] = []
                for candidate in rebuilt {
                    guard let index = next.firstIndex(where: { $0.id == candidate.id }),
                          Self.needsDerivedBackfill(next[index]) else { continue }   // a trim or sync since wins
                    let upgraded = Self.adoptingDerivedSeries(of: candidate, into: next[index])
                    guard upgraded != next[index] else { continue }
                    next[index] = upgraded
                    changedIDs.append(candidate.id)
                }
                guard !changedIDs.isEmpty else { return }
                self.summaries = next   // one publish for the whole sweep
                for id in changedIDs {
                    if let summary = self.summaries.first(where: { $0.id == id }) { self.sendEverywhere(summary) }
                }
                self.saveIndex()
            }
        }
    }

    private nonisolated static func needsDerivedBackfill(_ summary: FitnessSessionSummary) -> Bool {
        (summary.speedSeries.isEmpty && (summary.signalCounts[FitnessSample.Kind.location.rawValue] ?? 0) > 1)
            || summary.insights == nil
            || (summary.distanceSeries.isEmpty && (summary.signalCounts[FitnessSample.Kind.distance.rawValue] ?? 0) > 1)
            // Recordings made before running cadence was derived have raw stride-length samples
            // (running dynamics have been collected since 17 Aug) but never got the computed series.
            || (summary.derivedCadenceSeries.isEmpty && (summary.signalCounts[FitnessSample.Kind.strideLength.rawValue] ?? 0) > 1)
    }

    /// The derived (from-samples) fields of `fresh`, applied onto `target` — everything else on
    /// `target` (trims, laps, weather, cloud-adopted metadata) is left as it is.
    private nonisolated static func adoptingDerivedSeries(of fresh: FitnessSessionSummary,
                                                          into target: FitnessSessionSummary) -> FitnessSessionSummary {
        var result = target
        result.speedSeries = fresh.speedSeries
        result.elevationSeries = fresh.elevationSeries
        result.cadenceSeries = fresh.cadenceSeries
        result.powerSeries = fresh.powerSeries
        result.strideLengthSeries = fresh.strideLengthSeries
        result.verticalOscillationSeries = fresh.verticalOscillationSeries
        result.groundContactSeries = fresh.groundContactSeries
        result.strokeSeries = fresh.strokeSeries
        result.derivedCadenceSeries = fresh.derivedCadenceSeries
        result.insights = fresh.insights
        result.distanceSplits = fresh.distanceSplits
        result.distanceSeries = fresh.distanceSeries
        return result
    }

    /// Apply a remote deletion without generating a second deletion operation.
    func removeCloudSummary(_ id: UUID) {
        try? FileManager.default.removeItem(at: samplesURL(id))
        try? FileManager.default.removeItem(at: backupSamplesURL(id))
        try? FileManager.default.removeItem(at: backupSummaryURL(id))
        guard cloudBatchDepth == 0 else {
            var working = cloudBatchWorking ?? summaries
            working.removeAll { $0.id == id }
            cloudBatchWorking = working
            cloudBatchIndexDirty = true
            return
        }
        summaries.removeAll { $0.id == id }
        saveIndex()
    }

    // MARK: - Trim / cleanup

    private func backupSamplesURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).samples.orig") }
    private func backupSummaryURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).summary.orig") }

    /// True if this device holds the original of a session that was trimmed or corrected.
    func hasOriginal(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: backupSamplesURL(id).path) }

    /// The summary of the original this device holds, if it holds one.
    private func originalSummary(_ id: UUID) -> FitnessSessionSummary? {
        guard hasOriginal(id), let data = try? Data(contentsOf: backupSummaryURL(id)) else { return nil }
        return try? JSONDecoder().decode(FitnessSessionSummary.self, from: data)
    }

    /// Keep the recording this device holds as the workout's original: both files, or neither.
    private func keepOriginal(of original: FitnessSessionSummary) async -> Bool {
        let source = samplesURL(original.id)
        let backupSamples = backupSamplesURL(original.id)
        let backupSummary = backupSummaryURL(original.id)
        return await Task.detached(priority: .utility) {
            do {
                try? FileManager.default.removeItem(at: backupSamples)
                try FileManager.default.copyItem(at: source, to: backupSamples)
                try JSONEncoder().encode(original).write(to: backupSummary, options: .atomic)
                return true
            } catch {
                try? FileManager.default.removeItem(at: backupSamples)
                try? FileManager.default.removeItem(at: backupSummary)
                return false
            }
        }.value
    }

    private static let editMarksKey = "fitness.editMarksMigrated"

    /// Once per device: a workout trimmed before the summary carried a mark says so now, so the
    /// other devices offer Revert for it too. (Revert was offered only where the trim was made.)
    private func markEditsMadeBeforeTheMark() {
        guard !UserDefaults.standard.bool(forKey: Self.editMarksKey) else { return }
        let directory = dir
        Task.detached(priority: .utility) { [weak self] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let suffix = ".summary.orig"
            let ids = names.filter { $0.hasSuffix(suffix) }.compactMap { UUID(uuidString: String($0.dropLast(suffix.count))) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                var marked: [FitnessSessionSummary] = []
                for id in ids {
                    guard let index = self.summaries.firstIndex(where: { $0.id == id }),
                          self.summaries[index].edit == nil,
                          let original = self.originalSummary(id),
                          !WorkoutEdits.sameRecording(original, self.summaries[index]) else { continue }
                    self.summaries[index].edit = SessionEdit(original: original, at: Date())
                    marked.append(self.summaries[index])
                }
                UserDefaults.standard.set(true, forKey: Self.editMarksKey)
                guard !marked.isEmpty else { return }
                self.saveIndex()
                marked.forEach { self.sendEverywhere($0) }
            }
        }
    }

    /// Crop a session to the window [startOffset, endOffset] (seconds since the original
    /// start). Recomputes distance/energy/HR/route, keeps an undoable backup the first time.
    func trim(_ id: UUID, startOffset: TimeInterval, endOffset: TimeInterval) async {
        guard let idx = summaries.firstIndex(where: { $0.id == id }), endOffset > startOffset else { return }
        let original = summaries[idx]
        let samples = await samples(for: id)
        guard !samples.isEmpty else { return }   // never destroy a session whose data we can't read

        // A one-hour session can carry ~180k motion samples. Filtering, rebasing, aggregating,
        // downsampling the route/HR series, binary-encoding, and copying its backup used to happen
        // on the main actor in one tap — a long UI freeze plus a large memory spike.
        guard let trimmed = await Task.detached(priority: .userInitiated, operation: {
            Self.makeTrim(original: original, samples: samples,
                          startOffset: startOffset, endOffset: endOffset)
        }).value else { return }

        // Back up the original once — and only proceed if we actually have a recoverable
        // backup, so a failed copy can never lead to unrecoverable data loss.
        if !hasOriginal(id) {
            let source = samplesURL(id)
            let backupSamples = backupSamplesURL(id)
            let backupSummary = backupSummaryURL(id)
            let backedUp = await Task.detached(priority: .utility) {
                do {
                    try? FileManager.default.removeItem(at: backupSamples)
                    try FileManager.default.copyItem(at: source, to: backupSamples)
                    let data = try JSONEncoder().encode(original)
                    try data.write(to: backupSummary, options: .atomic)
                    return true
                } catch {
                    try? FileManager.default.removeItem(at: backupSamples)
                    try? FileManager.default.removeItem(at: backupSummary)
                    return false
                }
            }.value
            guard backedUp else { return }
        }
        guard hasOriginal(id) else { return }

        let destination = samplesURL(id)
        let wrote = await Task.detached(priority: .utility) {
            do {
                let data = FitnessSample.encodeBinary(trimmed.samples)
                try data.write(to: destination, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
        guard wrote, let current = summaries.firstIndex(where: { $0.id == id }) else { return }
        var summary = trimmed.summary
        // Marked as edited, by what the original looked like: every device offers Revert, and
        // one that holds that original keeps it (`WorkoutEdits`).
        summary.edit = SessionEdit(original: originalSummary(id) ?? original, at: Date())
        summaries[current] = summary
        saveIndex()
        sendEverywhere(summary)
        onRecordingChanged?(id, original.start, original.end ?? original.start)
    }

    private struct TrimResult: Sendable {
        var samples: [FitnessSample]
        var summary: FitnessSessionSummary
    }

    private nonisolated static func makeTrim(
        original: FitnessSessionSummary,
        samples: [FitnessSample],
        startOffset: TimeInterval,
        endOffset: TimeInterval
    ) -> TrimResult? {
        func baseline(for kind: FitnessSample.Kind) -> Double {
            var before: (t: Double, value: Double)?
            var after: (t: Double, value: Double)?
            for sample in samples where sample.kind == kind {
                if sample.t <= startOffset {
                    if before == nil || sample.t > before!.t { before = (sample.t, sample.v1) }
                } else if after == nil || sample.t < after!.t {
                    after = (sample.t, sample.v1)
                }
            }
            return before?.value ?? after?.value ?? 0
        }

        let distanceBaseline = baseline(for: .distance)
        let energyBaseline = baseline(for: .energy)
        var kept: [FitnessSample] = []
        kept.reserveCapacity(samples.count)
        var hrSum = 0.0
        var hrCount = 0
        var maxDistance: Double?
        var maxEnergy: Double?

        for sample in samples where sample.t >= startOffset && sample.t <= endOffset {
            var value = sample.v1
            if sample.kind == .distance {
                value = max(0, sample.v1 - distanceBaseline)
                maxDistance = max(maxDistance ?? value, value)
            } else if sample.kind == .energy {
                value = max(0, sample.v1 - energyBaseline)
                maxEnergy = max(maxEnergy ?? value, value)
            } else if sample.kind == .heartRate {
                hrSum += value
                hrCount += 1
            }
            kept.append(FitnessSample(t: sample.t - startOffset, kind: sample.kind,
                                      v1: value, v2: sample.v2, v3: sample.v3))
        }
        guard !kept.isEmpty else { return nil }

        let start = original.start.addingTimeInterval(startOffset)
        let end = original.start.addingTimeInterval(endOffset)
        let session = FitnessSession(
            id: original.id,
            start: start,
            end: end,
            activity: original.activity,
            avgHeartRate: hrCount > 0 ? hrSum / Double(hrCount) : nil,
            totalEnergy: maxEnergy,
            totalDistance: maxDistance,
            // These used to be dropped, so trimming a pool swim erased its pool length and laps
            // and re-saved it to Apple Health as open water.
            poolLengthMeters: original.poolLengthMeters,
            laps: TrimmedLaps.kept(original.laps, startOffset: startOffset, endOffset: endOffset),
            outdoorConditions: original.outdoorConditions,
            pauses: WorkoutPauses.kept(original.pauses, startOffset: startOffset, endOffset: endOffset),
            samples: kept)
        return TrimResult(samples: kept, summary: FitnessSessionSummary(session: session))
    }

    /// Replace a session's samples and summary with a corrected copy (pool-length fix). The
    /// original is backed up first, exactly as a trim does, and nothing is written unless the
    /// backup exists — so the correction can always be reverted.
    @discardableResult
    func replaceSession(_ session: FitnessSession) async -> Bool {
        guard let idx = summaries.firstIndex(where: { $0.id == session.id }) else { return false }
        let original = summaries[idx]
        let id = session.id
        if !hasOriginal(id) {
            let source = samplesURL(id), backupSamples = backupSamplesURL(id), backupSummary = backupSummaryURL(id)
            let backedUp = await Task.detached(priority: .utility) {
                do {
                    try? FileManager.default.removeItem(at: backupSamples)
                    try FileManager.default.copyItem(at: source, to: backupSamples)
                    try JSONEncoder().encode(original).write(to: backupSummary, options: .atomic)
                    return true
                } catch {
                    try? FileManager.default.removeItem(at: backupSamples)
                    try? FileManager.default.removeItem(at: backupSummary)
                    return false
                }
            }.value
            guard backedUp else { return false }
        }
        let destination = samplesURL(id)
        let samples = session.samples
        let wrote = await Task.detached(priority: .utility) {
            (try? FitnessSample.encodeBinary(samples).write(to: destination, options: .atomic)) != nil
        }.value
        guard wrote, let current = summaries.firstIndex(where: { $0.id == id }) else { return false }
        var corrected = FitnessSessionSummary(session: session)
        corrected.edit = SessionEdit(original: originalSummary(id) ?? original, at: Date())
        summaries[current] = corrected
        saveIndex()
        sendEverywhere(summaries[current])
        return true
    }

    /// Restore the original. Here it comes back at once; the other devices get it by sync, and
    /// the phone puts Apple Health's copy back too (`onRecordingChanged`).
    /// - Returns: false when this device doesn't hold the original (ask another: `WorkoutRevertInbox`).
    @discardableResult
    func revertTrim(_ id: UUID) -> Bool {
        guard let idx = summaries.firstIndex(where: { $0.id == id }),
              var original = originalSummary(id) else { return false }
        let edited = summaries[idx]
        let files = FileManager.default
        let destination = samplesURL(id)
        let staged = dir.appendingPathComponent(".\(id.uuidString).samples.revert")
        do {
            // The original is put in place before its kept copy is let go.
            try? files.removeItem(at: staged)
            try files.copyItem(at: backupSamplesURL(id), to: staged)
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: staged)
            } else {
                try files.moveItem(at: staged, to: destination)
            }
        } catch {
            try? files.removeItem(at: staged)
            return false
        }
        original.edit = nil
        summaries[idx] = original
        try? files.removeItem(at: backupSamplesURL(id))
        try? files.removeItem(at: backupSummaryURL(id))
        saveIndex()
        sendEverywhere(original)
        onRecordingChanged?(id, edited.start, edited.end ?? edited.start)
        return true
    }

    /// Detect stationary lead-in / tail-out from an already time-ordered cumulative distance
    /// track. Pure/nonisolated so a detail view can run it beside route extraction off-main.
    nonisolated static func suggestedTrim(
        from dist: [(t: TimeInterval, meters: Double)],
        duration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard dist.count > 4, let total = dist.last?.meters, total > 100 else { return nil }
        let epsilon = 1.0   // meters — "moving" if distance is still climbing

        var firstMoving = dist.first!.t
        for i in 1..<dist.count where dist[i].meters - dist[i - 1].meters > epsilon {
            firstMoving = dist[i - 1].t
            break
        }
        var lastMoving = dist.last!.t
        for i in stride(from: dist.count - 1, to: 0, by: -1)
            where dist[i].meters - dist[i - 1].meters > epsilon {
            lastMoving = dist[i].t
            break
        }

        let start = firstMoving >= 120 ? max(0, firstMoving - 10) : 0
        let end = (duration - lastMoving) >= 120 ? min(duration, lastMoving + 10) : duration
        return (start > 0 || end < duration) ? (start, end) : nil
    }

    // MARK: - Persistence

    private func saveIndex() {
        // See `init()`'s decode / `saveIsUnsafe`: only set when summaries.json failed to decode AND
        // couldn't be quarantined, i.e. there is no backup of the original anywhere. Writing here
        // would risk being the actual data-loss event rather than just reflecting an earlier one.
        guard !saveIsUnsafe else {
            Self.log.fault("saveIndex() refused: no backup of a previously-corrupt summaries.json exists yet, so writing now would risk destroying the only copy. Resolve by hand and relaunch.")
            return
        }
        let snapshot = summaries
        let url = indexURL
        Self.persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        // summaries.json is part of the iCloud snapshot payload — mark it dirty so the next
        // on-background pass includes a workout ingested since the last one.
        CloudBackup.shared.schedule()
    }

    private func persistIndexNow() async -> Bool {
        guard !saveIsUnsafe else {
            Self.log.fault("persistIndexNow() refused: no backup of a previously-corrupt summaries.json exists yet, so writing now would risk destroying the only copy. Resolve by hand and relaunch.")
            return false
        }
        let snapshot = summaries
        let url = indexURL
        return await withCheckedContinuation { continuation in
            Self.persistenceQueue.async {
                guard let data = try? JSONEncoder().encode(snapshot) else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Synchronous decode. Not currently called anywhere (`FitnessStore`, unlike `WellnessStore`/
    /// `ListenHistoryStore`/`ExceptionStore`, has no `reloadFromDisk()` restore path — CloudKit
    /// sync is the only source of truth for a live app after the initial async load in `init()`)
    /// — kept correct, not removed, so a future restore path can't silently reintroduce the exact
    /// bug the rest of this file fixes. Same decode-and-quarantine treatment as `init()`.
    private func load() {
        switch FitnessIndexLoader.load(from: indexURL) {
        case .empty:
            return
        case let .loaded(snapshot):
            if snapshot.droppedCount > 0 {
                Self.log.error("summaries.json: dropped \(snapshot.droppedCount, privacy: .public) corrupt summary/summaries on load; everything else loaded normally.")
            }
            // See the equivalent branch in `init()` above for why this is separate from
            // `droppedCount`, and `FitnessSessionSummary.hasPlausibleStart` for the rule.
            for id in snapshot.rejectedImplausibleIDs {
                Self.log.error("summaries.json: rejected workout \(id.uuidString, privacy: .public) — implausible start date; not loaded into the index.")
            }
            summaries = snapshot.summaries
        case let .corrupt(error, quarantinedTo):
            if let quarantinedTo {
                Self.log.error("summaries.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public).")
            } else {
                saveIsUnsafe = true
                Self.log.fault("summaries.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save until this is resolved by hand.")
            }
        }
    }

    private func removeLeakedPreviewFixture() {
        // Use the normal delete path so a fixture that was already mirrored by an older build is
        // removed from the shared CloudKit record too, not merely hidden on this Mac.
        for id in [Self.previewSessionID, Self.previewGymSessionID] where summaries.contains(where: { $0.id == id }) {
            delete(id)
        }
    }

    #if DEBUG
    /// The screenshot run: an 8.2 km loop out of and back to 2066 Crist Drive, Los Altos, drawn
    /// as a banana.
    ///
    /// Replaces a Lissajous curve parked at 37.773, -122.418 — a shape with no meaning dropped in
    /// the middle of San Francisco, which read as exactly what it was. A closed crescent anchored
    /// on a real address sits on real streets in the map view and is the right length for the
    /// session it illustrates (8198 m against the 8200 m the summary claims).
    ///
    /// Built as two edges of one swept arc: out along the outer edge, back along the inner one,
    /// with the thickness tapering to nothing at both tips so the ends come to a point. `bulge`
    /// warps the taper so the fat part sits nearer the start, which is what makes it read as a
    /// banana rather than a crescent moon.
    /// The screenshot run: a real loop through the Los Altos streets north-west of the house.
    ///
    /// Replaces a smooth synthetic crescent that cut diagonally across I-280 and Route 85 — a
    /// shape no one could have run, and the tell was obvious on the map. This one is produced by
    /// map-matching a banana outline onto the OpenStreetMap street graph (Newson & Krumm style
    /// HMM matching, with a turn penalty so it commits to a street instead of weaving between
    /// parallel ones), so every segment lies on a road that exists.
    ///
    /// It reads as a rough crescent rather than a clean banana, and that is a property of the
    /// terrain rather than the fit: the streets here are an irregular 1950s cul-de-sac tract with
    /// 25-150 m spacing, and a Frechet analysis put a hard floor of 252 m on how closely ANY
    /// closed loop in this network can follow a crescent. Trails at Rancho San Antonio curve far
    /// better but form branching out-and-backs rather than concentric loops, so no banana-shaped
    /// circuit exists there either.
    /// The screenshot run: a real banana-shaped course, drawn in a route planner and exported
    /// from Garmin as a TCX, rotated so it starts and ends at 2066 Crist Drive.
    ///
    /// Every generated attempt at this was worse, and for a reason worth recording. Fitting a
    /// crescent onto a street graph is a shape-matching problem with no good solution here: a
    /// Frechet analysis put a hard floor of 252 m on how closely ANY closed loop in the Los Altos
    /// streets can follow a banana, and Rancho San Antonio's trails branch rather than forming
    /// circuits, so no banana-shaped loop exists there either. A person with a routing tool solved
    /// it in one pass by choosing roads that happen to trace the shape — which is what GPS art
    /// actually is.
    ///
    /// Stored as a string rather than an array literal purely for compile time: 2,537 coordinate
    /// pairs as a Swift array literal makes the type-checker crawl. The data is the export,
    /// unmodified apart from the rotation.
    static func bananaRoute() -> [(latitude: Double, longitude: Double)] {
        bananaCourse
            .split(separator: ";")
            .compactMap { pair in
                let parts = pair.split(separator: ",")
                guard parts.count == 2,
                      let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
                return (latitude: lat, longitude: lon)
            }
    }

    private static let bananaCourse: String =
        """
        37.340343,-122.068874;37.340276,-122.068635;37.340148,-122.068788;37.340130,-122.068810;37
        .340000,-122.068965;37.339990,-122.068976;37.339935,-122.069042;37.339836,-122.069160;37.3
        39693,-122.069330;37.339679,-122.069346;37.339612,-122.069426;37.339488,-122.069575;37.339
        471,-122.069593;37.339537,-122.069679;37.339577,-122.069748;37.339968,-122.070253;37.33998
        7,-122.070272;37.340027,-122.070277;37.340078,-122.070350;37.340143,-122.070427;37.340171,
        -122.070496;37.340230,-122.070569;37.340497,-122.070915;37.340627,-122.071083;37.341056,-1
        22.071636;37.341143,-122.071750;37.341235,-122.071862;37.341265,-122.071885;37.341291,-122
        .071899;37.341318,-122.071906;37.341410,-122.071906;37.341480,-122.071911;37.341530,-122.0
        71930;37.341583,-122.071961;37.341644,-122.072015;37.341690,-122.072080;37.341726,-122.072
        149;37.341758,-122.072314;37.341754,-122.072448;37.341759,-122.072493;37.341772,-122.07255
        3;37.341794,-122.072591;37.341845,-122.072659;37.341958,-122.072811;37.342110,-122.073014;
        37.342147,-122.073059;37.342167,-122.073085;37.342309,-122.073267;37.342350,-122.073295;37
        .342408,-122.073403;37.342423,-122.073385;37.342698,-122.073052;37.343761,-122.071762;37.3
        44007,-122.072112;37.344061,-122.072344;37.344063,-122.072562;37.343995,-122.072756;37.343
        794,-122.073048;37.343377,-122.073515;37.343338,-122.073570;37.343312,-122.073622;37.34329
        9,-122.073689;37.343297,-122.073768;37.343306,-122.073818;37.343297,-122.073768;37.343299,
        -122.073689;37.343312,-122.073622;37.343338,-122.073570;37.343377,-122.073515;37.343794,-1
        22.073048;37.343995,-122.072756;37.344063,-122.072562;37.344061,-122.072344;37.344007,-122
        .072112;37.343761,-122.071762;37.342698,-122.073052;37.342423,-122.073385;37.342408,-122.0
        73403;37.342477,-122.073537;37.342662,-122.073794;37.343215,-122.074519;37.343483,-122.074
        868;37.343689,-122.075143;37.343729,-122.075187;37.343942,-122.075462;37.344069,-122.07563
        0;37.344020,-122.075686;37.343984,-122.075733;37.344009,-122.075766;37.344205,-122.076020;
        37.344420,-122.076294;37.344686,-122.076640;37.344835,-122.076839;37.345038,-122.077071;37
        .345279,-122.077325;37.345397,-122.077441;37.345579,-122.077648;37.345607,-122.077696;37.3
        45609,-122.077742;37.345616,-122.077744;37.345615,-122.077759;37.345613,-122.077790;37.345
        611,-122.077828;37.345619,-122.077841;37.345660,-122.077896;37.345710,-122.077961;37.34571
        5,-122.077973;37.345702,-122.077993;37.345665,-122.078035;37.345569,-122.078143;37.345579,
        -122.078155;37.346075,-122.078843;37.345579,-122.078155;37.345569,-122.078143;37.345515,-1
        22.078205;37.345510,-122.078215;37.345491,-122.078204;37.345468,-122.078197;37.345449,-122
        .078196;37.345418,-122.078202;37.345400,-122.078211;37.345380,-122.078227;37.345315,-122.0
        78305;37.345246,-122.078388;37.345227,-122.078443;37.345161,-122.078521;37.345171,-122.078
        534;37.346385,-122.080102;37.347576,-122.081635;37.348057,-122.082249;37.348957,-122.08341
        3;37.349454,-122.084110;37.349707,-122.084291;37.349766,-122.084348;37.349969,-122.084649;
        37.350241,-122.084973;37.350725,-122.085448;37.351133,-122.085947;37.351978,-122.087124;37
        .352173,-122.087412;37.352216,-122.087484;37.352234,-122.087543;37.352244,-122.087598;37.3
        52246,-122.087629;37.352248,-122.087703;37.352249,-122.087749;37.352253,-122.087802;37.352
        259,-122.087817;37.352272,-122.087836;37.352314,-122.087893;37.352326,-122.087907;37.35236
        5,-122.087804;37.352366,-122.087793;37.352386,-122.087793;37.352401,-122.087778;37.352426,
        -122.087743;37.352443,-122.087713;37.352441,-122.087678;37.352487,-122.087634;37.352519,-1
        22.087601;37.352535,-122.087615;37.352548,-122.087617;37.352560,-122.087607;37.352725,-122
        .087404;37.352725,-122.087386;37.352714,-122.087368;37.352720,-122.087359;37.352746,-122.0
        87323;37.352783,-122.087270;37.352789,-122.087263;37.352819,-122.087299;37.352830,-122.087
        302;37.352838,-122.087301;37.352842,-122.087314;37.352876,-122.087359;37.352902,-122.08739
        4;37.352911,-122.087398;37.352908,-122.087409;37.352910,-122.087426;37.352936,-122.087462;
        37.353214,-122.087814;37.353416,-122.088069;37.353435,-122.088078;37.353443,-122.088077;37
        .353443,-122.088092;37.353473,-122.088133;37.353508,-122.088179;37.353517,-122.088182;37.3
        53520,-122.088193;37.353522,-122.088204;37.353933,-122.088746;37.354038,-122.088883;37.354
        073,-122.088925;37.354093,-122.088954;37.354111,-122.088974;37.354134,-122.088985;37.35415
        8,-122.088992;37.354180,-122.088986;37.354193,-122.088980;37.354201,-122.088977;37.354209,
        -122.088969;37.354216,-122.088980;37.354295,-122.088968;37.354334,-122.088963;37.354341,-1
        22.088962;37.354340,-122.089005;37.354341,-122.089061;37.354344,-122.089228;37.354440,-122
        .089353;37.354646,-122.089622;37.354732,-122.089734;37.354832,-122.089865;37.354910,-122.0
        89968;37.355189,-122.090332;37.355299,-122.090482;37.355476,-122.090750;37.355595,-122.090
        913;37.356234,-122.091743;37.356261,-122.091779;37.356543,-122.092149;37.356783,-122.09247
        3;37.357231,-122.093053;37.357284,-122.093108;37.357325,-122.093151;37.357538,-122.093436;
        37.357673,-122.093603;37.358148,-122.094219;37.358189,-122.094270;37.358255,-122.094350;37
        .358899,-122.095097;37.358967,-122.095214;37.359015,-122.095273;37.359033,-122.095287;37.3
        59054,-122.095294;37.359054,-122.095305;37.359130,-122.095401;37.359202,-122.095492;37.359
        210,-122.095491;37.359225,-122.095550;37.359549,-122.095915;37.359652,-122.096004;37.35985
        4,-122.096004;37.360177,-122.095996;37.360389,-122.095996;37.360660,-122.095997;37.360955,
        -122.095997;37.361277,-122.095998;37.361377,-122.095997;37.361394,-122.095966;37.361395,-1
        22.096007;37.361394,-122.096036;37.361394,-122.096103;37.361467,-122.096108;37.361553,-122
        .096110;37.361583,-122.096110;37.362818,-122.096110;37.363614,-122.096112;37.364274,-122.0
        96112;37.364974,-122.096106;37.364993,-122.096105;37.365083,-122.096099;37.365164,-122.096
        094;37.365183,-122.096092;37.366764,-122.096083;37.369111,-122.096062;37.370786,-122.09604
        6;37.370863,-122.096045;37.371304,-122.096044;37.371588,-122.096042;37.372005,-122.096041;
        37.372904,-122.096031;37.373389,-122.096009;37.373478,-122.096008;37.373604,-122.096006;37
        .373620,-122.096006;37.373718,-122.096005;37.373796,-122.096004;37.373816,-122.096004;37.3
        74069,-122.096002;37.374140,-122.096001;37.375938,-122.096027;37.376044,-122.096028;37.376
        344,-122.096027;37.376747,-122.096026;37.376896,-122.096030;37.377251,-122.096038;37.37743
        8,-122.096041;37.378185,-122.096056;37.378225,-122.096056;37.378884,-122.096058;37.379116,
        -122.096065;37.379161,-122.096066;37.379764,-122.096033;37.380007,-122.096020;37.380535,-1
        22.096018;37.381038,-122.096035;37.381034,-122.096173;37.381027,-122.096845;37.381021,-122
        .097034;37.380969,-122.097362;37.380972,-122.100465;37.380972,-122.100486;37.380971,-122.1
        00567;37.381102,-122.100564;37.381211,-122.100561;37.381285,-122.100565;37.381298,-122.100
        567;37.381325,-122.100572;37.381336,-122.100578;37.381351,-122.100592;37.381393,-122.10064
        3;37.381456,-122.100581;37.381508,-122.100678;37.381548,-122.100695;37.382869,-122.100683;
        37.384226,-122.100657;37.384359,-122.100651;37.384433,-122.100683;37.384495,-122.100714;37
        .384521,-122.100728;37.384571,-122.100757;37.384576,-122.100744;37.384613,-122.100732;37.3
        84672,-122.100731;37.384861,-122.100726;37.384959,-122.100723;37.385026,-122.100721;37.385
        023,-122.101154;37.385099,-122.101153;37.385119,-122.101153;37.386224,-122.101131;37.38760
        5,-122.101141;37.388668,-122.101128;37.388977,-122.101123;37.388977,-122.101064;37.388977,
        -122.101039;37.388976,-122.100806;37.388985,-122.100312;37.388992,-122.100037;37.389016,-1
        22.099967;37.389062,-122.099904;37.389116,-122.099850;37.389350,-122.099683;37.389338,-122
        .099622;37.389334,-122.099605;37.389321,-122.099538;37.389304,-122.099423;37.389298,-122.0
        99299;37.389296,-122.099095;37.389300,-122.099012;37.389307,-122.098856;37.389373,-122.098
        271;37.389386,-122.098110;37.389391,-122.098023;37.389389,-122.097946;37.389351,-122.09740
        6;37.389301,-122.096296;37.389294,-122.096150;37.389370,-122.096154;37.389659,-122.096143;
        37.389861,-122.096119;37.390298,-122.096065;37.390407,-122.096053;37.390559,-122.096043;37
        .390616,-122.096040;37.390638,-122.096043;37.390635,-122.096023;37.390628,-122.095941;37.3
        90625,-122.095904;37.390624,-122.095885;37.390618,-122.095816;37.390613,-122.095757;37.390
        613,-122.095751;37.390617,-122.095751;37.390731,-122.095468;37.390755,-122.095421;37.39078
        0,-122.095349;37.390796,-122.095297;37.390887,-122.095164;37.390955,-122.095077;37.390989,
        -122.095030;37.391103,-122.094871;37.391123,-122.094874;37.391181,-122.094794;37.391272,-1
        22.094912;37.391468,-122.095137;37.391572,-122.095242;37.391641,-122.095310;37.391669,-122
        .095352;37.391731,-122.095247;37.391826,-122.095079;37.391868,-122.095005;37.391474,-122.0
        94592;37.391058,-122.094058;37.390618,-122.093354;37.390545,-122.093184;37.390565,-122.093
        173;37.390594,-122.093159;37.390647,-122.093149;37.390748,-122.093136;37.390647,-122.09314
        9;37.390594,-122.093159;37.390565,-122.093173;37.390545,-122.093184;37.390494,-122.093063;
        37.390472,-122.093076;37.390235,-122.092565;37.390238,-122.092546;37.390216,-122.092536;37
        .390178,-122.092458;37.390143,-122.092387;37.390125,-122.092359;37.390083,-122.092289;37.3
        89993,-122.092107;37.389878,-122.091881;37.389801,-122.091725;37.389706,-122.091530;37.389
        664,-122.091449;37.389635,-122.091360;37.389591,-122.091274;37.389552,-122.091196;37.38953
        3,-122.091174;37.389483,-122.091083;37.389371,-122.090857;37.389192,-122.090492;37.389102,
        -122.090302;37.389065,-122.090223;37.389029,-122.090147;37.388990,-122.090082;37.388935,-1
        22.089972;37.388831,-122.089764;37.388770,-122.089643;37.388650,-122.089406;37.388631,-122
        .089364;37.388560,-122.089207;37.388536,-122.089153;37.388506,-122.089082;37.388446,-122.0
        88977;37.388309,-122.088716;37.388242,-122.088568;37.388230,-122.088525;37.388226,-122.088
        449;37.388235,-122.088369;37.388192,-122.088345;37.388173,-122.088335;37.388131,-122.08831
        4;37.388109,-122.088333;37.388030,-122.088356;37.387880,-122.088398;37.387816,-122.088416;
        37.387800,-122.088420;37.387799,-122.088434;37.387798,-122.088448;37.387785,-122.088506;37
        .387748,-122.088492;37.387701,-122.088480;37.387616,-122.088467;37.387503,-122.088463;37.3
        87316,-122.088465;37.387252,-122.088468;37.387140,-122.088450;37.387050,-122.088429;37.386
        998,-122.088428;37.386976,-122.088441;37.386960,-122.088446;37.386921,-122.088427;37.38688
        6,-122.088415;37.386869,-122.088408;37.386845,-122.088401;37.386823,-122.088395;37.386811,
        -122.088392;37.386825,-122.088562;37.386847,-122.088705;37.386873,-122.088792;37.387166,-1
        22.089332;37.387196,-122.089352;37.387175,-122.089378;37.387166,-122.089391;37.387154,-122
        .089403;37.387141,-122.089416;37.387102,-122.089429;37.387067,-122.089439;37.387034,-122.0
        89447;37.387000,-122.089462;37.386968,-122.089491;37.386937,-122.089516;37.386912,-122.089
        602;37.386917,-122.089642;37.386933,-122.089682;37.386877,-122.089764;37.386834,-122.08983
        2;37.386614,-122.089907;37.386476,-122.089963;37.386392,-122.090001;37.386336,-122.090048;
        37.386301,-122.090077;37.386264,-122.090108;37.386118,-122.090174;37.385891,-122.090205;37
        .385647,-122.090190;37.385648,-122.090255;37.385601,-122.090252;37.384987,-122.090237;37.3
        84886,-122.090236;37.384653,-122.090231;37.384603,-122.090245;37.384104,-122.090445;37.383
        021,-122.090949;37.382742,-122.090803;37.382624,-122.090754;37.381911,-122.090461;37.38262
        4,-122.090754;37.382742,-122.090803;37.383021,-122.090949;37.384104,-122.090445;37.384603,
        -122.090245;37.384653,-122.090231;37.384886,-122.090236;37.384987,-122.090237;37.385601,-1
        22.090252;37.385648,-122.090255;37.385647,-122.090190;37.385891,-122.090205;37.386118,-122
        .090174;37.386264,-122.090108;37.386301,-122.090077;37.386336,-122.090048;37.386243,-122.0
        89614;37.386188,-122.089506;37.386181,-122.089471;37.386073,-122.089476;37.385879,-122.089
        469;37.385818,-122.089464;37.385788,-122.089426;37.385785,-122.087273;37.385606,-122.08721
        6;37.384996,-122.087207;37.384834,-122.087207;37.384405,-122.087207;37.384339,-122.087207;
        37.384263,-122.087203;37.384179,-122.087203;37.384123,-122.087205;37.384102,-122.087227;37
        .384098,-122.087235;37.384051,-122.087234;37.384000,-122.087234;37.383961,-122.087206;37.3
        83917,-122.087198;37.383619,-122.087203;37.383597,-122.087213;37.383590,-122.087230;37.383
        535,-122.087229;37.383477,-122.087229;37.383473,-122.087220;37.383457,-122.087208;37.38332
        2,-122.087206;37.383243,-122.087204;37.383010,-122.087210;37.382906,-122.087215;37.382813,
        -122.087218;37.381797,-122.087197;37.381698,-122.087192;37.381574,-122.087186;37.381023,-1
        22.087152;37.380927,-122.087154;37.380825,-122.087155;37.380825,-122.087015;37.380791,-122
        .087014;37.380646,-122.087012;37.380257,-122.087008;37.379919,-122.087005;37.379164,-122.0
        87000;37.379156,-122.087000;37.379086,-122.086999;37.378379,-122.086992;37.377592,-122.086
        984;37.377493,-122.086983;37.377303,-122.086980;37.377206,-122.086981;37.377208,-122.08681
        8;37.377216,-122.086584;37.377291,-122.086241;37.377305,-122.086035;37.377305,-122.085143;
        37.377306,-122.084385;37.377306,-122.084363;37.377237,-122.084364;37.377237,-122.084240;37
        .377236,-122.084151;37.377249,-122.084130;37.377257,-122.084102;37.377259,-122.084015;37.3
        77247,-122.083904;37.377218,-122.083712;37.377200,-122.083571;37.377191,-122.083422;37.377
        189,-122.082990;37.377173,-122.082256;37.377172,-122.082215;37.377165,-122.082168;37.37716
        5,-122.082038;37.377165,-122.081923;37.377167,-122.081883;37.377157,-122.081360;37.377151,
        -122.081303;37.377141,-122.081279;37.377138,-122.081140;37.376721,-122.081181;37.376393,-1
        22.081282;37.376113,-122.081427;37.375793,-122.081548;37.375402,-122.081882;37.375128,-122
        .082225;37.374875,-122.082641;37.374815,-122.082741;37.374229,-122.082283;37.373751,-122.0
        82287;37.373727,-122.082287;37.373725,-122.082197;37.373725,-122.082166;37.373696,-122.082
        149;37.373650,-122.082137;37.373512,-122.082140;37.373485,-122.082140;37.373466,-122.08214
        2;37.373425,-122.082073;37.373414,-122.081749;37.373408,-122.081545;37.373417,-122.081318;
        37.373409,-122.081134;37.373399,-122.081000;37.373385,-122.080770;37.373392,-122.080536;37
        .373392,-122.080400;37.373400,-122.080307;37.373415,-122.080202;37.373481,-122.080202;37.3
        73617,-122.080196;37.373619,-122.080317;37.373667,-122.080317;37.373686,-122.080316;37.374
        238,-122.080311;37.373686,-122.080316;37.373667,-122.080317;37.373619,-122.080317;37.37361
        7,-122.080196;37.373481,-122.080202;37.373415,-122.080202;37.373399,-122.080122;37.373374,
        -122.080001;37.373372,-122.079831;37.373402,-122.079688;37.373418,-122.079560;37.373377,-1
        22.079546;37.373222,-122.079544;37.373054,-122.079552;37.372903,-122.079554;37.372647,-122
        .079551;37.372455,-122.079556;37.372312,-122.079586;37.372259,-122.079523;37.372207,-122.0
        79463;37.372193,-122.079407;37.372171,-122.079275;37.372147,-122.079227;37.372124,-122.079
        209;37.372089,-122.079205;37.372051,-122.079209;37.371926,-122.079256;37.371879,-122.07926
        1;37.371789,-122.079245;37.371747,-122.079229;37.371705,-122.079198;37.371656,-122.079147;
        37.371609,-122.079012;37.371555,-122.078798;37.371609,-122.078143;37.371570,-122.078094;37
        .371518,-122.078062;37.371496,-122.078057;37.371497,-122.077964;37.371496,-122.077869;37.3
        71492,-122.077802;37.371488,-122.077736;37.371568,-122.077741;37.371567,-122.077716;37.371
        579,-122.077122;37.371577,-122.076708;37.371578,-122.076493;37.371624,-122.076496;37.37163
        8,-122.076495;37.372166,-122.076513;37.372174,-122.077049;37.372204,-122.077140;37.372255,
        -122.077160;37.372942,-122.077111;37.372255,-122.077160;37.372204,-122.077140;37.372174,-1
        22.077049;37.372166,-122.076513;37.371638,-122.076495;37.371624,-122.076496;37.371578,-122
        .076493;37.371573,-122.075709;37.371568,-122.074936;37.371567,-122.074918;37.371567,-122.0
        74811;37.371490,-122.074811;37.371472,-122.074812;37.370928,-122.074810;37.370575,-122.075
        086;37.369889,-122.075098;37.369882,-122.075098;37.369818,-122.075098;37.369818,-122.07499
        6;37.369818,-122.074702;37.369819,-122.074455;37.369820,-122.074188;37.369820,-122.074159;
        37.369494,-122.073959;37.369093,-122.073961;37.368467,-122.074063;37.368418,-122.074028;37
        .368090,-122.074131;37.367790,-122.074079;37.367770,-122.073890;37.367678,-122.073597;37.3
        67592,-122.073262;37.367531,-122.073118;37.367456,-122.072938;37.367579,-122.072421;37.367
        532,-122.072336;37.367613,-122.072118;37.367619,-122.072097;37.367642,-122.072000;37.36767
        1,-122.071875;37.367676,-122.071858;37.367688,-122.071762;37.367684,-122.070958;37.367689,
        -122.070207;37.367695,-122.070105;37.367699,-122.070019;37.367701,-122.069297;37.367657,-1
        22.069179;37.367545,-122.069082;37.367657,-122.069179;37.367701,-122.069297;37.367699,-122
        .070019;37.367695,-122.070105;37.367870,-122.070193;37.368067,-122.070240;37.369744,-122.0
        70245;37.369814,-122.070209;37.369816,-122.069344;37.369819,-122.068468;37.369819,-122.068
        368;37.369890,-122.068370;37.370209,-122.068366;37.370692,-122.068375;37.370980,-122.06837
        3;37.371306,-122.068371;37.371410,-122.068370;37.371477,-122.068383;37.371562,-122.068285;
        37.371614,-122.068261;37.371693,-122.068197;37.371783,-122.068068;37.371800,-122.067995;37
        .371835,-122.067545;37.371852,-122.067431;37.371170,-122.067024;37.370905,-122.066869;37.3
        70490,-122.066509;37.370438,-122.066471;37.369754,-122.065959;37.369716,-122.065900;37.369
        703,-122.065828;37.369712,-122.065774;37.369865,-122.065380;37.369901,-122.065345;37.36993
        9,-122.065324;37.369971,-122.065320;37.370028,-122.065336;37.370362,-122.065530;37.370465,
        -122.065558;37.370474,-122.065585;37.370470,-122.065613;37.370450,-122.065638;37.370426,-1
        22.065634;37.370033,-122.065389;37.369978,-122.065291;37.369975,-122.065274;37.369938,-122
        .065251;37.369849,-122.065166;37.369812,-122.065100;37.369579,-122.064510;37.369431,-122.0
        64138;37.369042,-122.063154;37.369019,-122.063093;37.368955,-122.062925;37.368887,-122.062
        766;37.368867,-122.062725;37.368851,-122.062690;37.368828,-122.062661;37.368798,-122.06264
        9;37.368733,-122.062539;37.368693,-122.062472;37.368684,-122.062459;37.368675,-122.062429;
        37.368643,-122.062364;37.368542,-122.062161;37.368516,-122.062111;37.368453,-122.061941;37
        .368442,-122.061913;37.368427,-122.061888;37.368411,-122.061878;37.368391,-122.061874;37.3
        68339,-122.061892;37.368252,-122.061941;37.367881,-122.062171;37.367656,-122.062311;37.367
        571,-122.062352;37.367481,-122.062386;37.367424,-122.062408;37.367381,-122.062424;37.36728
        1,-122.062443;37.367174,-122.062457;37.367082,-122.062462;37.367064,-122.062473;37.367049,
        -122.062488;37.367038,-122.062472;37.366951,-122.062460;37.366843,-122.062445;37.366834,-1
        22.062462;37.366818,-122.062443;37.366792,-122.062429;37.366622,-122.062375;37.366549,-122
        .062341;37.366427,-122.062272;37.366345,-122.062219;37.366290,-122.062175;37.366234,-122.0
        62131;37.366195,-122.062096;37.366119,-122.062017;37.366033,-122.061919;37.365946,-122.061
        795;37.365899,-122.061730;37.365852,-122.061659;37.365826,-122.061635;37.365798,-122.06162
        4;37.365796,-122.061599;37.365742,-122.061522;37.365688,-122.061444;37.365672,-122.061436;
        37.365669,-122.061417;37.365654,-122.061386;37.365388,-122.061007;37.365371,-122.060998;37
        .365353,-122.060992;37.365307,-122.061003;37.365286,-122.061013;37.365252,-122.061051;37.3
        64916,-122.061419;37.364863,-122.061475;37.364830,-122.061500;37.364776,-122.061534;37.364
        737,-122.061552;37.364652,-122.061594;37.364589,-122.061613;37.364530,-122.061621;37.36440
        5,-122.061626;37.364274,-122.061589;37.364123,-122.061493;37.364060,-122.061429;37.364022,
        -122.061375;37.363987,-122.061339;37.363954,-122.061335;37.363905,-122.061349;37.363711,-1
        22.061422;37.363569,-122.061472;37.363495,-122.061500;37.363443,-122.061505;37.363361,-122
        .061514;37.363312,-122.061511;37.363256,-122.061508;37.363194,-122.061494;37.363127,-122.0
        61468;37.362910,-122.061397;37.362841,-122.061375;37.362784,-122.061341;37.362718,-122.061
        288;37.362686,-122.061249;37.362645,-122.061202;37.362610,-122.061139;37.362582,-122.06107
        6;37.362558,-122.061018;37.362544,-122.060968;37.362534,-122.060954;37.362601,-122.060930;
        37.362562,-122.060810;37.362751,-122.060732;37.362733,-122.060648;37.362652,-122.060678;37
        .362632,-122.060700;37.362575,-122.060721;37.362165,-122.060860;37.362127,-122.060868;37.3
        62107,-122.060871;37.362088,-122.060864;37.362076,-122.060854;37.361945,-122.060828;37.361
        837,-122.060807;37.361822,-122.060818;37.361810,-122.060822;37.361751,-122.060816;37.36148
        4,-122.060729;37.361392,-122.060700;37.361359,-122.060688;37.361311,-122.060675;37.361241,
        -122.060665;37.361175,-122.060664;37.360913,-122.060673;37.360886,-122.060672;37.360859,-1
        22.060657;37.360771,-122.060658;37.360700,-122.060658;37.360705,-122.060650;37.360712,-122
        .060632;37.360713,-122.060609;37.360703,-122.060227;37.360700,-122.060180;37.360688,-122.0
        60154;37.360678,-122.060145;37.360664,-122.060132;37.360649,-122.060123;37.360621,-122.060
        118;37.360552,-122.060107;37.360488,-122.060089;37.360319,-122.060031;37.360146,-122.05994
        0;37.360002,-122.059849;37.359957,-122.059826;37.359909,-122.059801;37.359862,-122.059782;
        37.359728,-122.059740;37.359689,-122.059738;37.359669,-122.059741;37.359654,-122.059748;37
        .359649,-122.059754;37.359538,-122.059730;37.359513,-122.059574;37.359513,-122.059485;37.3
        59513,-122.059453;37.359513,-122.059200;37.359514,-122.059112;37.359514,-122.058547;37.359
        514,-122.058367;37.359516,-122.055440;37.359387,-122.055441;37.359364,-122.055441;37.35891
        8,-122.055448;37.358831,-122.055451;37.358830,-122.055374;37.358742,-122.055377;37.358742,
        -122.055345;37.358715,-122.055113;37.358648,-122.054694;37.358639,-122.054065;37.358631,-1
        22.052758;37.358630,-122.052711;37.358627,-122.052050;37.358620,-122.050900;37.358617,-122
        .050342;37.358616,-122.050182;37.358407,-122.050181;37.357635,-122.050177;37.357420,-122.0
        50188;37.357255,-122.050197;37.357251,-122.050103;37.357230,-122.049685;37.357235,-122.049
        290;37.357236,-122.049177;37.357151,-122.049177;37.356963,-122.049188;37.356782,-122.04924
        0;37.356635,-122.049296;37.356555,-122.049306;37.356481,-122.049276;37.356437,-122.049157;
        37.356252,-122.048338;37.356497,-122.048260;37.357657,-122.048259;37.357736,-122.048244;37
        .357812,-122.048207;37.357877,-122.048153;37.357923,-122.048094;37.357961,-122.048032;37.3
        57989,-122.047962;37.358006,-122.047883;37.358015,-122.047802;37.358012,-122.047273;37.358
        006,-122.046387;37.356940,-122.046397;37.356662,-122.046412;37.356615,-122.046390;37.35657
        6,-122.046346;37.356559,-122.046274;37.356559,-122.046189;37.356588,-122.046023;37.356595,
        -122.045839;37.356586,-122.045494;37.357325,-122.045497;37.357323,-122.045399;37.357322,-1
        22.044586;37.357321,-122.043663;37.357320,-122.042748;37.357319,-122.042524;37.357335,-122
        .042241;37.357333,-122.041618;37.357332,-122.041521;37.356491,-122.041512;37.356046,-122.0
        41512;37.355800,-122.041512;37.355819,-122.041379;37.355815,-122.040552;37.355817,-122.040
        343;37.355838,-122.040144;37.355874,-122.039953;37.355924,-122.039770;37.356030,-122.03956
        6;37.356160,-122.039372;37.356351,-122.039095;37.356495,-122.038819;37.356619,-122.038542;
        37.356700,-122.038254;37.356775,-122.037914;37.356815,-122.037583;37.356866,-122.037436;37
        .356807,-122.037405;37.356849,-122.037332;37.356843,-122.037310;37.356856,-122.037303;37.3
        56922,-122.037240;37.357000,-122.037163;37.357101,-122.037104;37.357429,-122.037017;37.357
        472,-122.036991;37.357550,-122.036966;37.357649,-122.036936;37.357694,-122.036945;37.35805
        5,-122.036853;37.358247,-122.036814;37.358445,-122.036784;37.358578,-122.036779;37.358869,
        -122.036779;37.358896,-122.036755;37.358911,-122.036710;37.358906,-122.035058;37.358911,-1
        22.035022;37.358923,-122.034997;37.358911,-122.033788;37.358896,-122.033712;37.358896,-122
        .033580;37.358895,-122.033476;37.358908,-122.033448;37.358918,-122.033394;37.358918,-122.0
        32943;37.358916,-122.032729;37.358914,-122.032664;37.358902,-122.032614;37.358876,-122.032
        565;37.358858,-122.032545;37.358834,-122.032524;37.358817,-122.032513;37.358822,-122.03250
        3;37.358820,-122.032408;37.358818,-122.032338;37.358805,-122.032205;37.358797,-122.032119;
        37.358794,-122.032107;37.358764,-122.032114;37.358707,-122.032118;37.358502,-122.032127;37
        .358023,-122.032147;37.357418,-122.032171;37.357202,-122.032180;37.357172,-122.032182;37.3
        57148,-122.032182;37.356604,-122.032200;37.356570,-122.032194;37.356541,-122.032180;37.356
        513,-122.032156;37.356506,-122.032166;37.356405,-122.032169;37.356312,-122.032171;37.35630
        5,-122.032165;37.356290,-122.032181;37.356277,-122.032193;37.356247,-122.032206;37.356207,
        -122.032214;37.355916,-122.032208;37.355426,-122.032182;37.355425,-122.032096;37.355397,-1
        22.031912;37.355354,-122.031672;37.355299,-122.031409;37.355292,-122.031376;37.355258,-122
        .031220;37.355292,-122.031376;37.355299,-122.031409;37.355354,-122.031672;37.355397,-122.0
        31912;37.355425,-122.032096;37.355426,-122.032182;37.355916,-122.032208;37.356207,-122.032
        214;37.356247,-122.032206;37.356277,-122.032193;37.356290,-122.032181;37.356305,-122.03216
        5;37.356329,-122.032129;37.356341,-122.032069;37.356344,-122.031716;37.356345,-122.031630;
        37.356340,-122.031559;37.356321,-122.031456;37.356235,-122.031078;37.356064,-122.030268;37
        .355940,-122.029694;37.355878,-122.029404;37.355766,-122.028885;37.355738,-122.028759;37.3
        55696,-122.028564;37.355619,-122.028208;37.355669,-122.028189;37.355576,-122.027701;37.355
        243,-122.026217;37.355072,-122.025446;37.355056,-122.025377;37.354892,-122.024568;37.35480
        2,-122.024159;37.354734,-122.023818;37.354643,-122.023677;37.354574,-122.023605;37.354442,
        -122.023579;37.354159,-122.023581;37.353550,-122.023584;37.353183,-122.023586;37.353114,-1
        22.023586;37.352701,-122.023588;37.352553,-122.023632;37.352347,-122.023677;37.352333,-122
        .023678;37.352333,-122.023562;37.352332,-122.023437;37.352321,-122.023386;37.352312,-122.0
        23343;37.352312,-122.023001;37.352319,-122.022970;37.352328,-122.022944;37.352338,-122.022
        930;37.352321,-122.022906;37.352335,-122.022884;37.352335,-122.022779;37.352334,-122.02266
        1;37.352328,-122.022623;37.352338,-122.022617;37.352330,-122.022594;37.352323,-122.022558;
        37.352318,-122.022511;37.352323,-122.021162;37.352330,-122.021131;37.352341,-122.021108;37
        .352351,-122.021091;37.352338,-122.021075;37.352340,-122.020963;37.352343,-122.020819;37.3
        52359,-122.020807;37.352349,-122.020780;37.352347,-122.020742;37.352365,-122.020477;37.352
        369,-122.020308;37.352369,-122.020127;37.352371,-122.018627;37.352374,-122.018023;37.35237
        3,-122.017250;37.352363,-122.016994;37.352351,-122.016847;37.352330,-122.016408;37.352327,
        -122.016289;37.352330,-122.016081;37.352330,-122.015751;37.352333,-122.014836;37.352335,-1
        22.014517;37.352339,-122.014473;37.352351,-122.014439;37.352369,-122.014405;37.352391,-122
        .014378;37.352414,-122.014365;37.352455,-122.014350;37.352481,-122.014343;37.352680,-122.0
        14323;37.352901,-122.014315;37.352923,-122.014317;37.352946,-122.014322;37.352971,-122.014
        331;37.352998,-122.014345;37.353023,-122.014365;37.353127,-122.014351;37.353299,-122.01432
        9;37.353381,-122.014318;37.353391,-122.014312;37.353419,-122.014370;37.353472,-122.014385;
        37.353497,-122.014394;37.353530,-122.014405;37.353544,-122.014411;37.353558,-122.014362;37
        .353585,-122.014329;37.353626,-122.014307;37.353810,-122.014309;37.353984,-122.014311;37.3
        54015,-122.014309;37.354046,-122.014288;37.354072,-122.014268;37.354443,-122.014265;37.354
        564,-122.014264;37.354564,-122.014299;37.354567,-122.014391;37.354594,-122.014390;37.35454
        7,-122.014491;37.354564,-122.015018;37.354639,-122.015125;37.354787,-122.015117;37.354789,
        -122.015124;37.354797,-122.015400;37.354797,-122.015414;37.354798,-122.015418;37.354803,-1
        22.015435;37.354827,-122.015462;37.354836,-122.015464;37.354821,-122.015537;37.354826,-122
        .015540;37.354829,-122.015546;37.354831,-122.015552;37.354832,-122.015567;37.354833,-122.0
        15581;37.354835,-122.015591;37.354839,-122.015596;37.354838,-122.015612;37.354848,-122.015
        643;37.354846,-122.015736;37.354861,-122.015762;37.354871,-122.015780;37.354877,-122.01579
        2;37.354894,-122.015823;37.354911,-122.015853;37.354937,-122.015901;37.354948,-122.015900;
        37.354936,-122.015945;37.354928,-122.015976;37.354930,-122.016018;37.354943,-122.016009;37
        .354965,-122.016067;37.354957,-122.016073;37.354962,-122.016087;37.354965,-122.016099;37.3
        54968,-122.016114;37.354969,-122.016129;37.354967,-122.016142;37.354963,-122.016154;37.354
        960,-122.016161;37.354958,-122.016164;37.354953,-122.016171;37.354957,-122.016181;37.35496
        2,-122.016189;37.354971,-122.016200;37.354971,-122.016191;37.354973,-122.016183;37.354977,
        -122.016176;37.354983,-122.016172;37.354990,-122.016170;37.354996,-122.016171;37.355002,-1
        22.016174;37.355007,-122.016180;37.355008,-122.016183;37.355035,-122.016164;37.355035,-122
        .016131;37.355038,-122.016129;37.355044,-122.016124;37.355045,-122.016121;37.355044,-122.0
        16124;37.355038,-122.016129;37.355035,-122.016131;37.355035,-122.016164;37.355008,-122.016
        183;37.355007,-122.016180;37.355002,-122.016174;37.354996,-122.016171;37.354990,-122.01617
        0;37.354983,-122.016172;37.354977,-122.016176;37.354973,-122.016183;37.354971,-122.016191;
        37.354971,-122.016200;37.354962,-122.016189;37.354957,-122.016181;37.354953,-122.016171;37
        .354958,-122.016164;37.354960,-122.016161;37.354963,-122.016154;37.354967,-122.016142;37.3
        54969,-122.016129;37.354968,-122.016114;37.354965,-122.016099;37.354962,-122.016087;37.354
        957,-122.016073;37.354965,-122.016067;37.354943,-122.016009;37.354930,-122.016018;37.35492
        8,-122.015976;37.354936,-122.015945;37.354948,-122.015900;37.354937,-122.015901;37.354911,
        -122.015853;37.354894,-122.015823;37.354877,-122.015792;37.354871,-122.015780;37.354861,-1
        22.015762;37.354846,-122.015736;37.354848,-122.015643;37.354838,-122.015612;37.354839,-122
        .015596;37.354835,-122.015591;37.354833,-122.015581;37.354832,-122.015567;37.354831,-122.0
        15552;37.354829,-122.015546;37.354826,-122.015540;37.354821,-122.015537;37.354836,-122.015
        464;37.354827,-122.015462;37.354803,-122.015435;37.354798,-122.015418;37.354797,-122.01541
        4;37.354797,-122.015400;37.354789,-122.015124;37.354787,-122.015117;37.354639,-122.015125;
        37.354564,-122.015018;37.354547,-122.014491;37.354594,-122.014390;37.354567,-122.014391;37
        .354564,-122.014299;37.354564,-122.014264;37.354443,-122.014265;37.354072,-122.014268;37.3
        54046,-122.014288;37.354015,-122.014309;37.353984,-122.014311;37.353810,-122.014309;37.353
        626,-122.014307;37.353585,-122.014329;37.353558,-122.014362;37.353544,-122.014411;37.35353
        0,-122.014405;37.353497,-122.014394;37.353472,-122.014385;37.353419,-122.014370;37.353391,
        -122.014312;37.353385,-122.014276;37.353345,-122.014177;37.353305,-122.014076;37.353281,-1
        22.014016;37.353291,-122.013985;37.353264,-122.013969;37.353242,-122.013948;37.353225,-122
        .013932;37.353216,-122.013918;37.353183,-122.013877;37.353155,-122.013828;37.353074,-122.0
        13630;37.353002,-122.013449;37.352969,-122.013363;37.352938,-122.013282;37.352828,-122.012
        973;37.352801,-122.012884;37.352748,-122.012707;37.352705,-122.012555;37.352658,-122.01237
        9;37.352614,-122.012201;37.352559,-122.011960;37.352526,-122.011815;37.352494,-122.011641;
        37.352465,-122.011483;37.352435,-122.011271;37.352399,-122.010992;37.352381,-122.010778;37
        .352366,-122.010541;37.352361,-122.010397;37.352359,-122.010236;37.352353,-122.009787;37.3
        52353,-122.009554;37.352353,-122.009504;37.352353,-122.009464;37.352354,-122.009019;37.352
        354,-122.008968;37.352353,-122.008936;37.352351,-122.008457;37.352353,-122.008257;37.35235
        9,-122.008215;37.352364,-122.008200;37.352371,-122.008183;37.352365,-122.008178;37.352365,
        -122.008053;37.352383,-122.008053;37.352509,-122.008057;37.352709,-122.008062;37.352784,-1
        22.008063;37.352961,-122.008065;37.353110,-122.008067;37.353418,-122.008071;37.353590,-122
        .008073;37.353747,-122.008075;37.353879,-122.008077;37.354083,-122.008080;37.354112,-122.0
        08080;37.354238,-122.008082;37.354406,-122.008084;37.354742,-122.008088;37.354899,-122.008
        090;37.354907,-122.008091;37.355279,-122.008095;37.355285,-122.005953;37.355974,-122.00597
        9;37.355965,-122.007177;37.355974,-122.005979;37.356647,-122.005988;37.357778,-122.006006;
        37.357831,-122.005594;37.357833,-122.005171;37.357834,-122.005043;37.356755,-122.005034;37
        .356432,-122.005030;37.355884,-122.005024;37.355622,-122.005022;37.355194,-122.005017;37.3
        54735,-122.005013;37.354574,-122.005012;37.354296,-122.005009;37.353957,-122.005001;37.353
        831,-122.004998;37.353601,-122.004995;37.353379,-122.004993;37.353222,-122.004992;37.35313
        2,-122.004991;37.352864,-122.004988;37.352763,-122.004987;37.352542,-122.004986;37.352405,
        -122.004984;37.352405,-122.004891;37.352412,-122.004879;37.352404,-122.004871;37.352385,-1
        22.004848;37.352365,-122.004797;37.352360,-122.004766;37.352356,-122.004718;37.352358,-122
        .004651;37.352363,-122.004414;37.352367,-122.004177;37.352370,-122.003919;37.352371,-122.0
        03784;37.352376,-122.003539;37.352381,-122.003274;37.352384,-122.003007;37.352385,-122.002
        930;37.352388,-122.002899;37.352392,-122.002881;37.352400,-122.002860;37.352393,-122.00285
        6;37.352395,-122.002793;37.352398,-122.002641;37.352398,-122.002592;37.352406,-122.002587;
        37.352397,-122.002563;37.352392,-122.002520;37.352398,-122.001988;37.352407,-122.001547;37
        .352409,-122.001435;37.352424,-122.001430;37.352424,-122.001367;37.352425,-122.001301;37.3
        52410,-122.001289;37.352410,-122.001247;37.352413,-122.001211;37.352422,-122.001161;37.352
        431,-122.001142;37.352449,-122.001114;37.352441,-122.001106;37.352443,-122.001002;37.35244
        5,-122.000909;37.352451,-122.000897;37.352439,-122.000880;37.352428,-122.000860;37.352419,
        -122.000810;37.352433,-122.000066;37.352439,-121.999724;37.352449,-121.999681;37.352499,-1
        21.999556;37.352551,-121.999514;37.352623,-121.999487;37.352905,-121.999481;37.353313,-121
        .999473;37.353760,-121.999464;37.353851,-121.999448;37.353869,-121.999441;37.353991,-121.9
        99395;37.354014,-121.999380;37.354107,-121.999321;37.354162,-121.999278;37.354254,-121.999
        176;37.354310,-121.999096;37.354413,-121.998889;37.354529,-121.998624;37.354629,-121.99842
        9;37.354677,-121.998363;37.354721,-121.998325;37.354753,-121.998297;37.354848,-121.998235;
        37.354921,-121.998214;37.354978,-121.998199;37.356062,-121.998214;37.356271,-121.998217;37
        .356272,-121.998132;37.356570,-121.998104;37.356744,-121.998023;37.356763,-121.998016;37.3
        56958,-121.997948;37.357531,-121.997947;37.357825,-121.997953;37.358222,-121.997958;37.358
        546,-121.997959;37.358547,-121.997888;37.358725,-121.997888;37.358845,-121.997889;37.35921
        6,-121.997891;37.359420,-121.997892;37.359448,-121.997879;37.359459,-121.997868;37.359464,
        -121.997864;37.359482,-121.997824;37.359487,-121.997155;37.359489,-121.997112;37.359485,-1
        21.997083;37.359480,-121.997074;37.359477,-121.997066;37.359482,-121.996955;37.359489,-121
        .996820;37.359506,-121.996777;37.359548,-121.996481;37.359534,-121.996402;37.359516,-121.9
        96370;37.359549,-121.996339;37.359587,-121.996303;37.359605,-121.996267;37.359639,-121.996
        136;37.359696,-121.995920;37.359727,-121.995800;37.359719,-121.995715;37.359714,-121.99567
        1;37.359768,-121.995628;37.359806,-121.995545;37.359818,-121.995454;37.359821,-121.995374;
        37.359815,-121.995359;37.359822,-121.995234;37.359829,-121.995112;37.359840,-121.995074;37
        .359845,-121.993468;37.359839,-121.993425;37.359835,-121.993402;37.359800,-121.993366;37.3
        59593,-121.993324;37.359276,-121.993322;37.359274,-121.993242;37.359272,-121.993148;37.359
        196,-121.993147;37.359109,-121.993145;37.359081,-121.993164;37.357832,-121.993153;37.35776
        1,-121.993155;37.357735,-121.993132;37.357720,-121.993100;37.357715,-121.993076;37.357714,
        -121.992946;37.357705,-121.992820;37.357681,-121.992659;37.357647,-121.992544;37.357609,-1
        21.992432;37.357538,-121.992289;37.357501,-121.992206;37.357409,-121.992085;37.357346,-121
        .992002;37.357317,-121.991993;37.356970,-121.991589;37.356957,-121.991557;37.356894,-121.9
        91483;37.356839,-121.991416;37.356818,-121.991416;37.356791,-121.991392;37.356433,-121.990
        980;37.356393,-121.991034;37.356351,-121.990989;37.356351,-121.990989;37.354305,-121.99081
        7;37.354337,-121.988554;37.352225,-121.988396;37.349026,-121.993420;37.349017,-121.994388;
        37.348545,-121.994368;37.348973,-121.994392;37.348915,-121.994847;37.348462,-121.995631;37
        .344226,-121.998044;37.343065,-121.999691;37.340850,-122.005638;37.340839,-122.006258;37.3
        40549,-122.005616;37.337891,-122.005599;37.337887,-122.007144;37.337032,-122.023186;37.336
        198,-122.023084;37.336255,-122.022330;37.337499,-122.028947;37.336863,-122.029216;37.33533
        4,-122.029575;37.335451,-122.030503;37.335334,-122.029575;37.336784,-122.029597;37.337578,
        -122.029183;37.337506,-122.032425;37.337533,-122.036762;37.334944,-122.038111;37.337331,-1
        22.044202;37.334957,-122.044065;37.337527,-122.044275;37.337520,-122.053268;37.336993,-122
        .053254;37.337520,-122.053268;37.337511,-122.058472;37.337594,-122.064988;37.338873,-122.0
        64989;37.339092,-122.066239;37.340530,-122.066546;37.340835,-122.065625;37.341585,-122.065
        649;37.341505,-122.066838;37.339577,-122.069748;37.342408,-122.073403;37.343761,-122.07176
        2;37.343377,-122.073515;37.343761,-122.071762;37.342477,-122.073537;37.345569,-122.078143;
        37.346075,-122.078843;37.345161,-122.078521;37.352936,-122.087462;37.361394,-122.096103;37
        .381038,-122.096035;37.380971,-122.100567;37.381393,-122.100643;37.385026,-122.100721;37.3
        88668,-122.101128;37.389350,-122.099683;37.389370,-122.096154;37.391868,-122.095005;37.390
        545,-122.093184;37.387196,-122.089352;37.385647,-122.090190;37.381911,-122.090461;37.38564
        8,-122.090255;37.386336,-122.090048;37.385606,-122.087216;37.383917,-122.087198;37.380825,
        -122.087015;37.377206,-122.086981;37.377191,-122.083422;37.377138,-122.081140;37.374815,-1
        22.082741;37.373466,-122.082142;37.373617,-122.080196;37.374238,-122.080311;37.373619,-122
        .080317;37.373418,-122.079560;37.371555,-122.078798;37.371609,-122.078143;37.371578,-122.0
        76493;37.372166,-122.076513;37.372204,-122.077140;37.372942,-122.077111;37.372255,-122.077
        160;37.372166,-122.076513;37.371578,-122.076493;37.371567,-122.074811;37.369818,-122.07509
        8;37.369820,-122.074159;37.367790,-122.074079;37.367531,-122.073118;37.367579,-122.072421;
        37.367657,-122.069179;37.367695,-122.070105;37.369814,-122.070209;37.369819,-122.068368;37
        .371477,-122.068383;37.371852,-122.067431;37.369754,-122.065959;37.369865,-122.065380;37.3
        70362,-122.065530;37.369812,-122.065100;37.368252,-122.061941;37.365252,-122.061051;37.362
        601,-122.060930;37.359538,-122.059730;37.359516,-122.055440;37.358742,-122.055377;37.35861
        6,-122.050182;37.357255,-122.050197;37.357236,-122.049177;37.356555,-122.049306;37.356252,
        -122.048338;37.357657,-122.048259;37.358006,-122.046387;37.356662,-122.046412;37.356586,-1
        22.045494;37.357325,-122.045497;37.357332,-122.041521;37.355800,-122.041512;37.356866,-122
        .037436;37.357101,-122.037104;37.355426,-122.032182;37.355258,-122.031220;37.355426,-122.0
        32182;37.356341,-122.032069;37.355619,-122.028208;37.354574,-122.023605;37.352312,-122.023
        343;37.354564,-122.014264;37.354930,-122.016018;37.352365,-122.008053;37.355279,-122.00809
        5;37.355285,-122.005953;37.355974,-122.005979;37.355965,-122.007177;37.355974,-122.005979;
        37.357778,-122.006006;37.357834,-122.005043;37.352392,-122.002520;37.352623,-121.999487;37
        .356271,-121.998217;37.358845,-121.997889;37.359482,-121.997824;37.356351,-121.990989;37.3
        56306,-121.991037;37.356231,-121.990959;37.356219,-121.990919;37.356188,-121.990877;37.355
        977,-121.990631;37.355884,-121.990526;37.355848,-121.990504;37.355798,-121.990443;37.35574
        8,-121.990382;37.355717,-121.990423;37.355599,-121.990549;37.355478,-121.990651;37.355312,
        -121.990757;37.355163,-121.990823;37.355003,-121.990871;37.354848,-121.990893;37.354373,-1
        21.990894;37.354346,-121.990886;37.354318,-121.990858;37.354305,-121.990817;37.354309,-121
        .990240;37.354322,-121.990198;37.354326,-121.990097;37.354329,-121.990007;37.354311,-121.9
        89961;37.354325,-121.988701;37.354337,-121.988663;37.354337,-121.988554;37.354326,-121.988
        555;37.354261,-121.988556;37.354201,-121.988554;37.354188,-121.988555;37.354187,-121.98845
        0;37.354171,-121.988468;37.354137,-121.988480;37.353492,-121.988478;37.353332,-121.988477;
        37.353130,-121.988477;37.352909,-121.988476;37.352586,-121.988475;37.352547,-121.988448;37
        .352457,-121.988433;37.352292,-121.988407;37.352225,-121.988396;37.352224,-121.988783;37.3
        52221,-121.989442;37.352221,-121.989621;37.352220,-121.989897;37.352219,-121.990122;37.352
        217,-121.990538;37.352217,-121.990753;37.352213,-121.991628;37.352211,-121.992375;37.35221
        3,-121.992746;37.352196,-121.992797;37.352168,-121.992826;37.351785,-121.993101;37.351648,
        -121.993199;37.351564,-121.993251;37.351483,-121.993283;37.351379,-121.993303;37.351317,-1
        21.993310;37.350748,-121.993299;37.350673,-121.993299;37.350446,-121.993295;37.350313,-121
        .993288;37.350207,-121.993271;37.349937,-121.993206;37.349746,-121.993159;37.349556,-121.9
        93140;37.349286,-121.993137;37.349245,-121.993124;37.349242,-121.993224;37.349237,-121.993
        397;37.349131,-121.993388;37.349012,-121.993378;37.349026,-121.993420;37.349025,-121.99392
        9;37.349017,-121.994388;37.348973,-121.994392;37.348959,-121.994393;37.348611,-121.994400;
        37.348591,-121.994394;37.348545,-121.994368;37.348524,-121.994363;37.348494,-121.994358;37
        .348467,-121.994365;37.348447,-121.994324;37.348443,-121.994256;37.348441,-121.994090;37.3
        48433,-121.994045;37.348409,-121.993976;37.348407,-121.993946;37.348409,-121.993976;37.348
        433,-121.994045;37.348441,-121.994090;37.348443,-121.994256;37.348447,-121.994324;37.34846
        7,-121.994365;37.348494,-121.994358;37.348524,-121.994363;37.348545,-121.994368;37.348591,
        -121.994394;37.348611,-121.994400;37.348959,-121.994393;37.348973,-121.994392;37.348982,-1
        21.994459;37.348981,-121.994525;37.348968,-121.994605;37.348950,-121.994680;37.348927,-121
        .994742;37.348912,-121.994786;37.348921,-121.994829;37.348915,-121.994847;37.348925,-121.9
        94852;37.348916,-121.994873;37.348802,-121.995193;37.348779,-121.995254;37.348781,-121.995
        307;37.348707,-121.995479;37.348656,-121.995566;37.348635,-121.995590;37.348578,-121.99562
        7;37.348462,-121.995631;37.347934,-121.995635;37.346705,-121.995609;37.345672,-121.995503;
        37.345611,-121.995477;37.345583,-121.995526;37.345551,-121.995583;37.345482,-121.995579;37
        .345369,-121.995573;37.345312,-121.995570;37.345302,-121.995693;37.345286,-121.995911;37.3
        45277,-121.996036;37.345249,-121.996091;37.345225,-121.996138;37.345265,-121.996178;37.345
        289,-121.996235;37.345306,-121.996344;37.345326,-121.996675;37.345317,-121.996841;37.34529
        0,-121.997094;37.345244,-121.997359;37.345220,-121.997420;37.345172,-121.997433;37.345130,
        -121.997428;37.344908,-121.997352;37.344806,-121.997334;37.344752,-121.997329;37.344688,-1
        21.997345;37.344639,-121.997357;37.344495,-121.997460;37.344422,-121.997555;37.344342,-121
        .997720;37.344221,-121.997945;37.344172,-121.997988;37.344226,-121.998044;37.344172,-121.9
        98128;37.344114,-121.998187;37.344159,-121.998251;37.344034,-121.998378;37.343927,-121.998
        468;37.343826,-121.998537;37.343696,-121.998613;37.343582,-121.998662;37.343450,-121.99870
        0;37.343314,-121.998723;37.343078,-121.998734;37.342992,-121.998748;37.342966,-121.998761;
        37.342890,-121.998801;37.342831,-121.998880;37.342702,-121.999087;37.342539,-121.999303;37
        .342488,-121.999360;37.342475,-121.999398;37.342479,-121.999454;37.342525,-121.999675;37.3
        42538,-121.999697;37.342548,-121.999789;37.342556,-121.999859;37.342598,-121.999859;37.342
        707,-121.999839;37.342821,-121.999780;37.342952,-121.999703;37.343065,-121.999691;37.34343
        6,-121.999677;37.343611,-121.999637;37.343631,-121.999644;37.343674,-121.999683;37.343761,
        -121.999942;37.343954,-122.000313;37.343962,-122.000371;37.344011,-122.000467;37.344061,-1
        22.000567;37.344105,-122.000600;37.344344,-122.001067;37.344380,-122.001155;37.344412,-122
        .001249;37.344439,-122.001409;37.344429,-122.001454;37.344424,-122.001572;37.344419,-122.0
        01661;37.344446,-122.001706;37.344451,-122.001753;37.344470,-122.002379;37.344462,-122.002
        420;37.344432,-122.002456;37.344389,-122.002469;37.344257,-122.002483;37.344087,-122.00248
        4;37.343195,-122.002448;37.342976,-122.002439;37.342890,-122.002437;37.342880,-122.002436;
        37.342837,-122.002435;37.342807,-122.002434;37.342491,-122.002426;37.342397,-122.002423;37
        .342363,-122.002402;37.342314,-122.002387;37.342275,-122.002387;37.342223,-122.002406;37.3
        42160,-122.002470;37.342137,-122.002556;37.342137,-122.002654;37.342149,-122.002725;37.342
        149,-122.002801;37.342103,-122.002988;37.342054,-122.003125;37.342015,-122.003204;37.34200
        1,-122.003240;37.341922,-122.003345;37.341842,-122.003451;37.341830,-122.003535;37.341772,
        -122.003636;37.341702,-122.003799;37.341649,-122.003956;37.341602,-122.004157;37.341577,-1
        22.004346;37.341562,-122.004570;37.341547,-122.004979;37.341536,-122.005244;37.341530,-122
        .005346;37.341523,-122.005473;37.341513,-122.005490;37.341490,-122.005473;37.341467,-122.0
        05466;37.341436,-122.005476;37.341271,-122.005534;37.341161,-122.005565;37.341073,-122.005
        584;37.341002,-122.005590;37.340960,-122.005602;37.340936,-122.005630;37.340850,-122.00563
        8;37.340839,-122.006258;37.340850,-122.005638;37.340765,-122.005645;37.340748,-122.005624;
        37.340724,-122.005617;37.340549,-122.005616;37.340222,-122.005602;37.340200,-122.005608;37
        .340184,-122.005622;37.340098,-122.005616;37.339998,-122.005610;37.339975,-122.005593;37.3
        39943,-122.005587;37.339459,-122.005572;37.339437,-122.005576;37.339421,-122.005593;37.339
        327,-122.005589;37.339238,-122.005586;37.339220,-122.005566;37.339200,-122.005559;37.33896
        1,-122.005552;37.338661,-122.005545;37.338641,-122.005551;37.338628,-122.005566;37.338612,
        -122.005539;37.338533,-122.005536;37.338451,-122.005532;37.338435,-122.005557;37.338403,-1
        22.005537;37.337936,-122.005522;37.337908,-122.005541;37.337895,-122.005568;37.337891,-122
        .005599;37.337882,-122.006987;37.337889,-122.007016;37.337900,-122.007034;37.337889,-122.0
        07056;37.337887,-122.007144;37.337754,-122.007137;37.337749,-122.007427;37.337736,-122.009
        156;37.337728,-122.010775;37.337720,-122.012376;37.337719,-122.012715;37.337718,-122.01291
        3;37.337716,-122.013361;37.337714,-122.013664;37.337712,-122.014075;37.337713,-122.014278;
        37.337710,-122.014477;37.337710,-122.014619;37.337709,-122.014944;37.337709,-122.014971;37
        .337708,-122.015286;37.337706,-122.015526;37.337705,-122.015829;37.337705,-122.015896;37.3
        37704,-122.016071;37.337702,-122.016387;37.337702,-122.016477;37.337704,-122.016703;37.337
        704,-122.016931;37.337702,-122.017182;37.337702,-122.017291;37.337700,-122.017614;37.33769
        8,-122.017788;37.337698,-122.018113;37.337697,-122.018276;37.337697,-122.018383;37.337696,
        -122.018475;37.337695,-122.018639;37.337673,-122.020805;37.337673,-122.020842;37.337672,-1
        22.021135;37.337671,-122.021293;37.337671,-122.021380;37.337670,-122.021495;37.337673,-122
        .022219;37.337671,-122.022394;37.337669,-122.022628;37.337669,-122.022753;37.337665,-122.0
        23176;37.337558,-122.023174;37.337548,-122.023161;37.337544,-122.023166;37.337535,-122.023
        175;37.337519,-122.023184;37.337492,-122.023190;37.337239,-122.023187;37.337032,-122.02318
        6;37.336739,-122.023187;37.336611,-122.023187;37.336567,-122.023188;37.336469,-122.023192;
        37.336388,-122.023196;37.336343,-122.023202;37.336272,-122.023217;37.336206,-122.023238;37
        .336198,-122.023084;37.336252,-122.023051;37.336257,-122.022890;37.336255,-122.022330;37.3
        36257,-122.022890;37.336252,-122.023051;37.336198,-122.023084;37.336206,-122.023238;37.336
        272,-122.023217;37.336343,-122.023202;37.336388,-122.023196;37.336469,-122.023192;37.33656
        7,-122.023188;37.336611,-122.023187;37.336739,-122.023187;37.337032,-122.023186;37.337239,
        -122.023187;37.337492,-122.023190;37.337519,-122.023184;37.337535,-122.023175;37.337543,-1
        22.023190;37.337544,-122.023296;37.337547,-122.023439;37.337540,-122.023445;37.337555,-122
        .023466;37.337563,-122.023488;37.337569,-122.023523;37.337570,-122.023552;37.337568,-122.0
        23724;37.337530,-122.023772;37.337536,-122.024153;37.337530,-122.024174;37.337520,-122.024
        200;37.337517,-122.024223;37.337515,-122.024511;37.337524,-122.024547;37.337526,-122.02457
        1;37.337528,-122.024607;37.337527,-122.024662;37.337527,-122.024714;37.337523,-122.025334;
        37.337522,-122.025346;37.337517,-122.025362;37.337512,-122.025374;37.337510,-122.025388;37
        .337509,-122.025679;37.337510,-122.025691;37.337515,-122.025702;37.337519,-122.025710;37.3
        37521,-122.025720;37.337520,-122.025823;37.337520,-122.025874;37.337519,-122.025927;37.337
        518,-122.026112;37.337517,-122.026288;37.337514,-122.026307;37.337504,-122.026328;37.33750
        3,-122.026349;37.337502,-122.026541;37.337501,-122.026662;37.337503,-122.026708;37.337511,
        -122.026734;37.337521,-122.026755;37.337519,-122.026812;37.337517,-122.026869;37.337515,-1
        22.026953;37.337514,-122.026967;37.337508,-122.026980;37.337501,-122.026993;37.337499,-122
        .027005;37.337499,-122.027216;37.337498,-122.027282;37.337499,-122.027294;37.337504,-122.0
        27305;37.337509,-122.027316;37.337511,-122.027332;37.337512,-122.027344;37.337511,-122.028
        013;37.337509,-122.028032;37.337502,-122.028053;37.337499,-122.028073;37.337496,-122.02809
        8;37.337493,-122.028627;37.337492,-122.028655;37.337495,-122.028676;37.337504,-122.028725;
        37.337512,-122.028820;37.337515,-122.028848;37.337498,-122.028868;37.337503,-122.028877;37
        .337499,-122.028947;37.337440,-122.028959;37.337383,-122.028982;37.337269,-122.029031;37.3
        37198,-122.029084;37.337158,-122.029169;37.337099,-122.029199;37.337034,-122.029209;37.336
        957,-122.029214;37.336898,-122.029215;37.336863,-122.029216;37.336793,-122.029296;37.33678
        4,-122.029597;37.336506,-122.029585;37.336384,-122.029580;37.335864,-122.029574;37.335605,
        -122.029575;37.335575,-122.029576;37.335334,-122.029575;37.335338,-122.029640;37.335357,-1
        22.029931;37.335451,-122.030503;37.335357,-122.029931;37.335338,-122.029640;37.335334,-122
        .029575;37.335575,-122.029576;37.335605,-122.029575;37.335864,-122.029574;37.336384,-122.0
        29580;37.336506,-122.029585;37.336784,-122.029597;37.336793,-122.029296;37.336863,-122.029
        216;37.336898,-122.029215;37.336957,-122.029214;37.337034,-122.029209;37.337099,-122.02919
        9;37.337158,-122.029169;37.337231,-122.029176;37.337305,-122.029130;37.337371,-122.029095;
        37.337435,-122.029075;37.337492,-122.029065;37.337486,-122.029158;37.337475,-122.029176;37
        .337481,-122.029190;37.337486,-122.029220;37.337514,-122.029209;37.337578,-122.029183;37.3
        37569,-122.029622;37.337526,-122.031060;37.337519,-122.031305;37.337519,-122.031414;37.337
        516,-122.032053;37.337511,-122.032207;37.337506,-122.032425;37.337502,-122.032564;37.33750
        3,-122.032922;37.337505,-122.033433;37.337504,-122.033627;37.337507,-122.034107;37.337502,
        -122.035139;37.337498,-122.036638;37.337533,-122.036762;37.337434,-122.036779;37.337433,-1
        22.036889;37.337440,-122.036895;37.337443,-122.036915;37.337443,-122.036959;37.337421,-122
        .036960;37.337344,-122.037000;37.337366,-122.037084;37.337346,-122.037160;37.337328,-122.0
        37197;37.337291,-122.037201;37.337238,-122.037183;37.337145,-122.037152;37.337076,-122.037
        165;37.337021,-122.037189;37.337047,-122.037278;37.337016,-122.037374;37.337017,-122.03749
        4;37.336897,-122.037497;37.336613,-122.037492;37.336615,-122.037686;37.336615,-122.037721;
        37.336390,-122.037724;37.336390,-122.037934;37.336112,-122.037937;37.335970,-122.037936;37
        .335850,-122.037935;37.335762,-122.037935;37.335504,-122.037935;37.335453,-122.037951;37.3
        35390,-122.037972;37.335327,-122.037975;37.334945,-122.037970;37.334945,-122.038007;37.334
        944,-122.038111;37.334814,-122.038108;37.334812,-122.038423;37.334810,-122.038694;37.33499
        6,-122.038694;37.334997,-122.038840;37.334997,-122.038964;37.334904,-122.038963;37.334903,
        -122.039135;37.334902,-122.039184;37.334951,-122.039193;37.334954,-122.039885;37.335144,-1
        22.039886;37.335243,-122.039901;37.335218,-122.040110;37.335210,-122.040383;37.335225,-122
        .040425;37.335229,-122.040500;37.335300,-122.040497;37.335296,-122.040522;37.335261,-122.0
        40548;37.335231,-122.040569;37.335224,-122.040606;37.335232,-122.040722;37.335239,-122.040
        743;37.335246,-122.040765;37.335291,-122.040782;37.335385,-122.040771;37.335420,-122.04077
        2;37.335478,-122.040773;37.335524,-122.040775;37.335555,-122.040787;37.335576,-122.040825;
        37.335579,-122.040871;37.335579,-122.040922;37.335568,-122.040977;37.335559,-122.041012;37
        .335563,-122.041037;37.335565,-122.041079;37.335567,-122.041121;37.335565,-122.041314;37.3
        35813,-122.041312;37.335838,-122.041313;37.335916,-122.041316;37.336277,-122.041314;37.336
        989,-122.041314;37.337048,-122.041312;37.337074,-122.041308;37.337114,-122.041275;37.33731
        4,-122.041276;37.337332,-122.041307;37.337371,-122.041287;37.337388,-122.041271;37.337394,
        -122.041279;37.337382,-122.041455;37.337370,-122.041637;37.337361,-122.041658;37.337370,-1
        22.041671;37.337390,-122.041706;37.337403,-122.041753;37.337408,-122.042038;37.337408,-122
        .042091;37.337423,-122.042127;37.337422,-122.042256;37.337429,-122.042869;37.337431,-122.0
        43285;37.337434,-122.044003;37.337431,-122.044097;37.337398,-122.044165;37.337331,-122.044
        202;37.336877,-122.044226;37.336664,-122.044229;37.336347,-122.044220;37.336269,-122.04421
        6;37.336076,-122.044201;37.335836,-122.044172;37.335530,-122.044117;37.335387,-122.044102;
        37.335091,-122.044094;37.335062,-122.044087;37.335021,-122.044064;37.334981,-122.044061;37
        .334957,-122.044065;37.335007,-122.044217;37.334957,-122.044065;37.334981,-122.044061;37.3
        35021,-122.044064;37.335062,-122.044087;37.335091,-122.044094;37.335387,-122.044102;37.335
        530,-122.044117;37.335836,-122.044172;37.336076,-122.044201;37.336269,-122.044216;37.33634
        7,-122.044220;37.336664,-122.044229;37.336877,-122.044226;37.337331,-122.044202;37.337398,
        -122.044165;37.337431,-122.044097;37.337423,-122.044277;37.337527,-122.044275;37.337524,-1
        22.044897;37.337522,-122.045159;37.337520,-122.045543;37.337520,-122.045647;37.337519,-122
        .045768;37.337518,-122.046007;37.337519,-122.046033;37.337520,-122.046123;37.337519,-122.0
        46235;37.337518,-122.046288;37.337518,-122.046425;37.337518,-122.046496;37.337517,-122.047
        322;37.337516,-122.047572;37.337516,-122.047704;37.337515,-122.048344;37.337516,-122.04919
        0;37.337517,-122.049368;37.337518,-122.049728;37.337518,-122.049799;37.337519,-122.050008;
        37.337519,-122.050276;37.337520,-122.050691;37.337520,-122.051110;37.337519,-122.051368;37
        .337517,-122.052026;37.337516,-122.052330;37.337522,-122.052989;37.337520,-122.053268;37.3
        37409,-122.053265;37.337382,-122.053265;37.336993,-122.053254;37.337382,-122.053265;37.337
        409,-122.053265;37.337520,-122.053268;37.337516,-122.054440;37.337516,-122.054840;37.33751
        6,-122.054859;37.337516,-122.054998;37.337516,-122.055108;37.337516,-122.055129;37.337516,
        -122.055463;37.337519,-122.056900;37.337514,-122.057533;37.337514,-122.057701;37.337513,-1
        22.057832;37.337512,-122.057989;37.337512,-122.058146;37.337511,-122.058472;37.337511,-122
        .058519;37.337510,-122.058728;37.337510,-122.058938;37.337509,-122.059187;37.337508,-122.0
        59675;37.337507,-122.060030;37.337506,-122.060279;37.337506,-122.060388;37.337505,-122.060
        587;37.337504,-122.060800;37.337504,-122.060950;37.337503,-122.061339;37.337502,-122.06147
        9;37.337502,-122.061602;37.337501,-122.061960;37.337500,-122.062238;37.337499,-122.062539;
        37.337495,-122.062801;37.337458,-122.062873;37.337457,-122.063627;37.337493,-122.063708;37
        .337489,-122.064142;37.337485,-122.064524;37.337534,-122.064596;37.337533,-122.064864;37.3
        37564,-122.064865;37.337588,-122.064854;37.337594,-122.064911;37.337594,-122.064988;37.337
        609,-122.064988;37.337813,-122.064988;37.337822,-122.064989;37.338031,-122.064989;37.33818
        4,-122.064989;37.338873,-122.064989;37.338978,-122.065102;37.339060,-122.065250;37.339097,
        -122.065443;37.339102,-122.065625;37.339092,-122.066239;37.339136,-122.066411;37.339258,-1
        22.066530;37.340530,-122.066546;37.340589,-122.066543;37.340648,-122.066531;37.340701,-122
        .066501;37.340748,-122.066457;37.340784,-122.066396;37.340811,-122.066321;37.340823,-122.0
        66244;37.340826,-122.066149;37.340831,-122.065715;37.340835,-122.065625;37.340947,-122.065
        632;37.341585,-122.065649;37.341574,-122.066185;37.341572,-122.066279;37.341569,-122.06637
        1;37.341559,-122.066502;37.341546,-122.066623;37.341526,-122.066730;37.341505,-122.066838;
        37.341433,-122.067108;37.341415,-122.067180;37.341388,-122.067287;37.341358,-122.067384;37
        .341318,-122.067459;37.341283,-122.067501;37.341273,-122.067512;37.341055,-122.067698;37.3
        41016,-122.067745;37.340905,-122.067879;37.340820,-122.067982;37.340766,-122.068047;37.340
        678,-122.068153;37.340458,-122.068416;37.340429,-122.068451;37.340373,-122.068519;37.34034
        3,-122.068874
        """
        .replacingOccurrences(of: "\n", with: "")

    /// Inject one sample session (with a GPS route + HR) for layout verification.
    func injectSampleForPreview() {
        let id = Self.previewSessionID
        guard !summaries.contains(where: { $0.id == id }) else { return }
        var samples: [FitnessSample] = []
        for i in 0..<360 { samples.append(FitnessSample(t: Double(i) * 10, kind: .heartRate, v1: 142 + sin(Double(i) / 40) * 12, v2: nil, v3: nil)) }
        for (i, point) in Self.bananaRoute().enumerated() {
            samples.append(FitnessSample(t: Double(i) * 12.9, kind: .location,
                                         v1: point.latitude, v2: point.longitude, v3: 3.1))
        }
        // Preview data must stay process-local. Calling `ingest` here used the production
        // persistence and CloudKit paths, so a screenshot run could leave a fictional ride in a
        // person's actual history.
        let session = FitnessSession(id: id, start: Date().addingTimeInterval(-3600 * 3), end: Date(),
                                     activity: "Cycling", avgHeartRate: 138, totalEnergy: 1980,
                                     totalDistance: 82241, samples: samples)
        summaries.insert(FitnessSessionSummary(session: session), at: 0)
        injectGymSampleForPreview()
    }

    /// Strength at a gym yesterday, its GPS wandering ~30 m around the building: drawn as a
    /// place (a dot), not a route.
    private func injectGymSampleForPreview() {
        let id = Self.previewGymSessionID
        guard !summaries.contains(where: { $0.id == id }) else { return }
        let gym = (latitude: 37.3861, longitude: -122.0839)
        var samples: [FitnessSample] = []
        for i in 0..<120 {
            samples.append(FitnessSample(t: Double(i) * 30, kind: .heartRate, v1: 118 + sin(Double(i) / 9) * 14, v2: nil, v3: nil))
            let wobble = Double(i)
            samples.append(FitnessSample(t: Double(i) * 30, kind: .location,
                                         v1: gym.latitude + sin(wobble * 1.7) * 0.00025,
                                         v2: gym.longitude + cos(wobble * 1.3) * 0.0003, v3: 12))
        }
        // 6 PM yesterday: clear of the sample Health workouts, which sit at this time of day.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let start = yesterday.addingTimeInterval(3600 * 18)
        let session = FitnessSession(id: id, start: start, end: start.addingTimeInterval(3600),
                                     activity: "Strength", avgHeartRate: 121, totalEnergy: 310,
                                     totalDistance: nil, samples: samples)
        let summary = FitnessSessionSummary(session: session)
        let at = summaries.firstIndex { $0.start < start } ?? summaries.endIndex
        summaries.insert(summary, at: at)
    }
    #endif

    /// One-time migration: the old single JSON file held full sessions (with samples
    /// in memory). Split it into the index + per-session binary, then remove it.
    private func migrateLegacyIfNeeded() {
        let legacy = AppSupport.directory
            .appendingPathComponent("fitness_sessions_ios.json")
        guard let data = try? Data(contentsOf: legacy),
              let old = try? JSONDecoder().decode([FitnessSession].self, from: data) else { return }
        for session in old { ingest(session) }
        try? FileManager.default.removeItem(at: legacy)
    }
}
