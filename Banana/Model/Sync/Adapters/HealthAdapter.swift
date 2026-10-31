import Foundation

// Health (T2): the phone's Health snapshot, Banana workouts with their recordings, and the
// requests devices make of each other about them (docs/design/DATA-PLATFORM.md §3, §5, §6).

// MARK: - The Health snapshot

/// What `HealthKitStore` is to the snapshot's adapter.
@MainActor protocol HealthSnapshotPort: AnyObject {
    var hasData: Bool { get }
    /// The portable snapshot (`HealthKitStore.cloudSnapshot`), packed, made when called: the values
    /// are taken now, on the main actor; the encoding and packing run where it's called.
    func snapshotMaker() -> @Sendable () -> Data?
    /// When the cache last changed here: the snapshot's own time (§3 seeding rule 3).
    var snapshotDate: Date? { get }
    /// The phone's snapshot, arrived (`adoptCloudSnapshot`).
    func adoptSnapshot(_ packed: Data)
}

/// How often the Health snapshot goes up (§3 "The Health snapshot"): at most once an hour, and at
/// once when a workout is removed or hidden. Today every `persist()` publishes, and
/// each publish is a new blob of a megabyte or more, kept for good. Pure.
struct SnapshotPace: Codable, Equatable, Sendable {
    /// At most hourly: each publish is a new blob of 1 MB or more, kept for good (§3).
    static let interval: TimeInterval = 60 * 60

    var lastPublished: Date?
    /// A publish waiting for its time.
    var due: Date?

    /// A change to the snapshot: when it should go up (now, or when the hour is over).
    mutating func changed(urgent: Bool, now: Date) -> Date {
        if urgent || lastPublished.map({ now.timeIntervalSince($0) >= Self.interval }) ?? true {
            due = nil
            return now
        }
        let next = lastPublished!.addingTimeInterval(Self.interval)
        due = min(due ?? next, next)
        return due!
    }

    mutating func published(at now: Date) {
        lastPublished = now
        due = nil
    }
}

/// `health.snapshot` (hub only, `whole`, blob `v`): the packed `HealthKitStore.Payload` as one blob,
/// eager on the spokes, which adopt it whole. Only the iPhone publishes it, at most once an hour
/// (`SnapshotPace`); the engine never sends a spoke's (`writers: hub`).
@MainActor
final class HealthSnapshotAdapter: RecordAdapter {
    static let type = "health.snapshot"
    static let id = "health-cache"

    let port: any HealthSnapshotPort
    let isHub: Bool
    var reports: HealthFood.Reports
    private let files: SnapshotFiles
    private let now: () -> Date
    /// Runs `work` at `date` (a sleeping task; tests run it themselves).
    private let schedule: (_ at: Date, _ work: @escaping @MainActor () -> Void) -> Void
    private let defaults: UserDefaults
    private static let paceKey = "spaceSync.healthSnapshotPace"
    private(set) var pace: SnapshotPace
    private var scheduled = false

    init(port: any HealthSnapshotPort, isHub: Bool, directory: URL, reports: HealthFood.Reports = .moveOver,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
         schedule: ((Date, @escaping @MainActor () -> Void) -> Void)? = nil) {
        self.port = port
        self.isHub = isHub
        self.reports = reports
        files = SnapshotFiles(directory: directory)
        self.defaults = defaults
        self.now = now
        self.schedule = schedule ?? { date, work in
            Task { @MainActor in
                let wait = max(0, date.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(wait))
                work()
            }
        }
        pace = defaults.data(forKey: Self.paceKey).flatMap { try? JSONDecoder().decode(SnapshotPace.self, from: $0) }
            ?? SnapshotPace()
        // A publish that was waiting when the app last stopped still goes, once the engine has had
        // a moment to start.
        if isHub, let due = pace.due { wait(until: max(due, now().addingTimeInterval(5))) }
    }

    var types: [String] { [Self.type] }

    /// The cache changed here (`HealthKitStore.persist`); `urgent` when a workout was removed or
    /// hidden. On the hub it goes up now or when the hour is over; elsewhere never.
    func snapshotChanged(urgent: Bool) {
        guard isHub else { return }
        let at = pace.changed(urgent: urgent, now: now())
        if at <= now() {
            publish()
        } else {
            wait(until: at)
        }
        savePace()
    }

    private func wait(until at: Date) {
        guard !scheduled else { return }
        scheduled = true
        schedule(at) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let due = self.pace.due else { return }
            if due <= self.now() { self.publish() } else { self.wait(until: due) }
        }
    }

    private func publish() {
        pace.published(at: now())
        savePace()
        reports.changed(Self.type, [Self.id])
    }

    private func savePace() {
        if let data = try? JSONEncoder().encode(pace) { defaults.set(data, forKey: Self.paceKey) }
    }

    func snapshot(_ type: String) -> [String: any Encodable & Sendable] {
        guard type == Self.type, isHub, port.hasData else { return [:] }
        return [Self.id: HealthFood.Whole(v: SnapshotBlob(make: port.snapshotMaker(), files: files))]
    }

    func seedClock(_ type: String, id: String) -> Date? { port.snapshotDate }

    /// The bytes come as the blob (eager): nothing to wait for. The phone keeps its own.
    func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
        Dictionary(records.map { ($0.id, true) }, uniquingKeysWith: { first, _ in first })
    }

    /// A snapshot is never deleted.
    func remove(_ type: String, ids: [String]) {}

    func blobFile(_ type: String, id: String, field: String) -> URL? {
        guard field == "v", isHub else { return nil }
        return files.latest
    }

    /// The file with exactly the bytes the record names: a newer snapshot written since must not
    /// go up under an older one's hash.
    func blobFile(_ type: String, id: String, field: String, sha: String) -> URL? {
        guard field == "v", isHub else { return nil }
        return files.file(sha: sha)
    }

    func storeBlob(_ type: String, id: String, field: String, file: URL) {
        // The phone reads Health itself: another copy of its own snapshot is nothing to it.
        guard field == "v", !isHub, let data = try? Data(contentsOf: file) else { return }
        port.adoptSnapshot(data)
    }
}

/// The packed snapshot files, by content: the latest is what goes up as the record's blob.
final class SnapshotFiles: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var newest: URL?

    init(directory: URL) {
        self.directory = directory
        HealthFood.makeUnbackedDirectory(directory)
    }

    var latest: URL? {
        lock.lock()
        defer { lock.unlock() }
        return newest
    }

    /// The file written for these bytes, while it's kept (the latest and the one before it).
    func file(sha: String) -> URL? {
        let url = directory.appendingPathComponent("health-\(sha).packed")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Writes the packed bytes under their hash (once), keeps the one before it (an upload may
    /// still be reading it), and removes older ones.
    func write(_ data: Data) -> BlobReference? {
        let sha = HealthFood.BlobHashes.sha256(of: data)
        let url = directory.appendingPathComponent("health-\(sha).packed")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        }
        lock.lock()
        let previous = newest
        newest = url
        lock.unlock()
        let keep = Set([url.lastPathComponent, previous?.lastPathComponent].compactMap { $0 })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("health-") && name.hasSuffix(".packed") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return BlobReference(sha256: sha, size: Int64(data.count), ext: "packed")
    }
}

/// The snapshot's blob reference, made when the engine encodes it: the payload is encoded, packed,
/// written and hashed then, off the main actor.
struct SnapshotBlob: Encodable, Sendable {
    let make: @Sendable () -> Data?
    let files: SnapshotFiles

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let data = make(), let reference = files.write(data) {
            try container.encode(reference.value)
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - Workouts

/// What `FitnessStore` is to the workouts' adapter.
@MainActor protocol WorkoutSyncPort: AnyObject {
    var summaries: [FitnessSessionSummary] { get }
    /// The workout's recording here, if it's here (`samplesFileForCloudSync`).
    func samplesFile(_ id: UUID) -> URL?
    /// Other devices' summaries, in one batch and one publish, never reported back
    /// (`applyingCloudBatch` + `adoptCloudSummary`). Their recordings come on their own.
    func adoptSpaceSummaries(_ summaries: [FitnessSessionSummary])
    /// Another device's edit with the recording it replaced this one's with: the store's own path
    /// for that (`adoptCloudWorkout`), which keeps the original and has Health follow.
    func adoptSpaceWorkout(_ summary: FitnessSessionSummary, samples: URL) async -> Bool
    /// Other devices' deletes (`removeCloudSummary`).
    func removeSpaceWorkouts(_ ids: [UUID])
    /// A recording for a workout that has none here yet.
    @discardableResult func installSpaceSamples(_ id: UUID, from file: URL) -> Bool
    /// When the legacy sync last saw it edited (§3 seeding rule 3).
    func editedAt(_ id: UUID) -> Date?
}

/// `health.workout`: a `FitnessSessionSummary`'s keys are the record's fields, and its recording is
/// the blob field `samples` (lazy: a spoke fetches it when a workout's detail needs it; the phone,
/// which writes Health from it, fetches it at once).
@MainActor
final class WorkoutAdapter: RecordAdapter {
    static let type = "health.workout"
    static let samples = "samples"

    let port: any WorkoutSyncPort
    let isHub: Bool
    var hooks: HealthFood.EngineHooks
    private let hashes: HealthFood.BlobHashes
    private let staging: URL
    private let refsFile: URL?
    /// The recording each workout's record names, as last seen: what a device that never fetched
    /// it encodes, so it never clears it for everyone.
    private var known: [String: BlobReference]
    /// Edits whose new recording is on its way: the store takes them with it.
    private var replacing: [String: FitnessSessionSummary] = [:]
    private var staged: [String: URL] = [:]
    /// Each workout's own time, from the last snapshot (the seed asks for every id right after).
    private var ownTimes: [String: Date] = [:]
    /// Edits whose recording turned out to be the one here already.
    private var confirmed: Set<String> = []
    /// The phone's recordings still to fetch, kept across launches, fetched one at a time with
    /// a growing wait after each failure.
    private var wanted: [String: Want]
    private let wantedFile: URL?
    private var pumping = false
    private var wake: Task<Void, Never>?
    /// Failed fetches of an edit's new recording, by workout: its wait grows the same way.
    private var replaceAttempts: [String: Int] = [:]
    var now: () -> Date = { Date() }
    var retryBase: TimeInterval = 5

    private struct Want: Codable { var attempts = 0; var notBefore = Date.distantPast }

    /// 5 s, doubling, at most 30 min.
    private func backoff(_ attempts: Int) -> TimeInterval {
        min(retryBase * pow(2, Double(max(0, attempts - 1))), 1_800)
    }

    init(port: any WorkoutSyncPort, isHub: Bool, hooks: HealthFood.EngineHooks = .none, directory: URL,
         hashes: HealthFood.BlobHashes = .shared) {
        self.port = port
        self.isHub = isHub
        self.hooks = hooks
        self.hashes = hashes
        staging = directory.appendingPathComponent("staged", isDirectory: true)
        refsFile = directory.appendingPathComponent("workout-samples.json")
        HealthFood.makeUnbackedDirectory(staging)
        known = refsFile.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: KnownRef].self, from: $0) }?
            .mapValues { BlobReference(sha256: $0.sha, size: $0.size, ext: "samples") } ?? [:]
        wantedFile = directory.appendingPathComponent("workout-samples-wanted.json")
        wanted = wantedFile.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Want].self, from: $0) } ?? [:]
        // What a relaunch left unfetched, once the engine has had a moment to start.
        if isHub, !wanted.isEmpty { wakeUp(at: Date().addingTimeInterval(10)) }
    }

    private struct KnownRef: Codable { var sha: String; var size: Int64 }

    var types: [String] { [Self.type] }

    private func item(_ summary: FitnessSessionSummary) -> any Encodable & Sendable {
        let id = summary.id.uuidString
        return WorkoutItem(summary: summary,
                           samples: HealthFood.FileBlob(url: port.samplesFile(summary.id), ext: "samples",
                                                        known: known[id], hashes: hashes))
    }

    func snapshot(_ type: String) -> [String: any Encodable & Sendable] {
        guard type == Self.type else { return [:] }
        var items: [String: any Encodable & Sendable] = [:]
        var own: [String: Date] = [:]
        for summary in port.summaries {
            items[summary.id.uuidString] = item(summary)
            own[summary.id.uuidString] = summary.edit?.editedAt ?? summary.end ?? summary.start
        }
        ownTimes = own
        return items
    }

    func items(_ type: String, ids: Set<String>) -> [String: any Encodable & Sendable] {
        guard type == Self.type else { return [:] }
        var items: [String: any Encodable & Sendable] = [:]
        for summary in port.summaries where ids.contains(summary.id.uuidString) {
            items[summary.id.uuidString] = item(summary)
            ownTimes[summary.id.uuidString] = summary.edit?.editedAt ?? summary.end ?? summary.start
        }
        return items
    }

    func seedClock(_ type: String, id: String) -> Date? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return HealthFood.ownTime(port.editedAt(uuid)) ?? ownTimes[id]
    }

    func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
        var results: [String: Bool] = [:]
        var plain: [FitnessSessionSummary] = []
        var fetch: [String] = [], want: [String] = []
        var knownChanged = false
        let local = Dictionary(port.summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records {
            guard let summary = HealthFood.decode(FitnessSessionSummary.self, record.fields),
                  summary.id.uuidString == record.id, summary.hasPlausibleStart else {
                results[record.id] = true   // as the Fitness zone: a malformed workout is dropped
                continue
            }
            let reference = record.fields[Self.samples]?.blobReference
            if let reference, known[record.id] != reference {
                known[record.id] = reference
                knownChanged = true
            }
            let file = port.samplesFile(summary.id)
            // The recording here is the one the record names (an edit that kept it: a pool length
            // corrected), by its known hash, or as the engine found when asked for it.
            let sameFile = confirmed.remove(record.id) != nil
                || (file.flatMap { hashes.cachedReference(of: $0, ext: "samples") }?.sha256 == reference?.sha256)
            if let reference, file != nil, !sameFile, let mine = local[summary.id], !WorkoutEdits.sameRecording(mine, summary) {
                // Its recording changed elsewhere (a trim, a revert): the store takes the edit with
                // the new recording, once that's here, through its own path.
                if let ready = staged[record.id] {
                    replacing[record.id] = nil
                    staged[record.id] = nil
                    results[record.id] = false
                    replace(summary, with: ready)
                } else {
                    results[record.id] = false
                    if replacing[record.id] == nil { fetch.append(record.id) }
                    replacing[record.id] = summary
                }
                continue
            }
            plain.append(summary)
            results[record.id] = true
            // The phone writes Health from the recording: it keeps every one.
            if isHub, file == nil, reference != nil { want.append(record.id) }
        }
        if !plain.isEmpty { port.adoptSpaceSummaries(plain) }
        if knownChanged { saveKnown() }
        for id in fetch { fetchRecording(id) }
        if !want.isEmpty {
            for id in want where wanted[id] == nil { wanted[id] = Want() }
            saveWanted()
            pump()
        }
        return results
    }

    /// The phone's recordings, one at a time: fetched, or tried again later.
    private func pump() {
        guard !pumping else { return }
        pumping = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let id = self.wanted.filter({ $0.value.notBefore <= self.now() }).keys.sorted().first {
                guard let uuid = UUID(uuidString: id), self.port.summaries.contains(where: { $0.id == uuid }) else {
                    self.wanted[id] = nil   // deleted meanwhile
                    continue
                }
                let fetched = await self.hooks.ensureBlob(Self.type, id, Self.samples)
                if fetched || self.port.samplesFile(uuid) != nil {
                    self.wanted[id] = nil
                } else {
                    var want = self.wanted[id] ?? Want()
                    want.attempts += 1
                    want.notBefore = self.now().addingTimeInterval(self.backoff(want.attempts))
                    self.wanted[id] = want
                }
                self.saveWanted()
            }
            self.pumping = false
            if let next = self.wanted.values.map(\.notBefore).min() { self.wakeUp(at: next) }
        }
    }

    private func wakeUp(at date: Date) {
        wake?.cancel()
        wake = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    private func saveWanted() {
        guard let wantedFile else { return }
        if let data = try? JSONEncoder().encode(wanted) { try? data.write(to: wantedFile, options: .atomic) }
    }

    /// The recordings still to fetch here (tests).
    var wantedRecordings: Set<String> { Set(wanted.keys) }

    private func fetchRecording(_ id: String) {
        let hooks = self.hooks
        Task { @MainActor [weak self] in
            guard await hooks.ensureBlob(Self.type, id, Self.samples) else {
                // Not now: the edit waits in the mirror and is offered again after a while,
                // which asks for its recording again.
                guard let self else { return }
                self.replacing[id] = nil
                let attempts = (self.replaceAttempts[id] ?? 0) + 1
                self.replaceAttempts[id] = attempts
                try? await Task.sleep(for: .seconds(self.backoff(attempts)))
                await hooks.replay([Self.type])
                return
            }
            guard let self else { return }
            self.replaceAttempts[id] = nil
            guard let summary = self.replacing[id] else { return }
            self.replacing[id] = nil
            guard let file = self.staged[id] else {
                // Nothing came down: the engine has this recording here already. The edit is taken
                // as it is.
                self.confirmed.insert(id)
                await hooks.replay([Self.type])
                return
            }
            self.staged[id] = nil
            self.replace(summary, with: file)
        }
    }

    /// The edit and its recording, through the store's own path; then the record is offered again,
    /// and the store, now holding it, takes it.
    private func replace(_ summary: FitnessSessionSummary, with file: URL) {
        let hooks = self.hooks
        let port = self.port
        Task { @MainActor in
            _ = await port.adoptSpaceWorkout(summary, samples: file)
            try? FileManager.default.removeItem(at: file)
            await hooks.replay([Self.type])
        }
    }

    func remove(_ type: String, ids: [String]) {
        let uuids = ids.compactMap(UUID.init(uuidString:))
        guard !uuids.isEmpty else { return }
        port.removeSpaceWorkouts(uuids)
        for id in ids { known[id] = nil }
        saveKnown()
    }

    func blobFile(_ type: String, id: String, field: String) -> URL? {
        guard field == Self.samples, let uuid = UUID(uuidString: id) else { return nil }
        return port.samplesFile(uuid)
    }

    func storeBlob(_ type: String, id: String, field: String, file: URL) {
        guard field == Self.samples, let uuid = UUID(uuidString: id) else { return }
        if replacing[id] != nil {
            // Kept aside until the edit it belongs to is taken with it.
            let kept = staging.appendingPathComponent("\(id).samples")
            try? FileManager.default.removeItem(at: kept)
            guard (try? FileManager.default.moveItem(at: file, to: kept)) != nil
                    || (try? FileManager.default.copyItem(at: file, to: kept)) != nil else { return }
            staged[id] = kept
        } else if port.samplesFile(uuid) == nil {
            port.installSpaceSamples(uuid, from: file)
        }
    }

    private func saveKnown() {
        guard let refsFile else { return }
        let plain = known.mapValues { KnownRef(sha: $0.sha256, size: $0.size) }
        if let data = try? JSONEncoder().encode(plain) { try? data.write(to: refsFile, options: .atomic) }
    }
}

/// A workout as its record: the summary's keys, and its recording's blob reference as `samples`,
/// left out when this device knows none (a field this device never writes is never cleared).
struct WorkoutItem: Encodable, Sendable {
    let summary: FitnessSessionSummary
    let samples: HealthFood.FileBlob

    private enum Keys: String, CodingKey { case samples }

    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        guard let reference = samples.reference else { return }
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(reference.value, forKey: .samples)
    }
}

// MARK: - Requests between devices

/// A request one device makes and another carries out: a Health removal (iPad, Mac → the phone) or
/// a workout revert (any → whoever holds the original). One record per request, `field` with
/// disjoint keys (§3): the asker writes `request`, the device that carried it out `outcome`.
@MainActor protocol HealthRequestPort: AnyObject {
    associatedtype Request: Codable & Sendable & Identifiable where Request.ID == UUID
    /// Every request this device knows: its own, the old key-value list's, and the space's.
    var requests: [Request] { get }
    /// What this device has carried out, by request.
    var outcomes: [UUID: String] { get }
    /// Requests from the space, kept beside the old list, then carried out if they're this
    /// device's to do; `done` already carry an outcome (a restored phone mustn't do them again).
    /// Never reported back.
    func adoptRequests(_ requests: [Request], done: Set<UUID>)
    func removeRequests(_ ids: [UUID])
    func askedAt(_ request: Request) -> Date
}

@MainActor
final class HealthRequestsAdapter<Port: HealthRequestPort>: RecordAdapter {
    let type: String
    let port: Port

    init(type: String, port: Port) {
        self.type = type
        self.port = port
    }

    var types: [String] { [type] }

    func snapshot(_ type: String) -> [String: any Encodable & Sendable] {
        guard type == self.type else { return [:] }
        let outcomes = port.outcomes
        var items: [String: any Encodable & Sendable] = [:]
        for request in port.requests {
            items[request.id.uuidString] = RequestItem(request: request, outcome: outcomes[request.id])
            ownTimes[request.id.uuidString] = port.askedAt(request)
        }
        return items
    }

    private var ownTimes: [String: Date] = [:]

    func seedClock(_ type: String, id: String) -> Date? { ownTimes[id] }

    func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
        let requests = records.compactMap { record -> Port.Request? in
            guard let value = record.fields["request"], !value.isNull,
                  let request = try? CanonicalJSON.decode(Port.Request.self, from: value),
                  request.id.uuidString == record.id else { return nil }
            return request
        }
        let done = Set(records.filter { !($0.fields["outcome"]?.isNull ?? true) }.compactMap { UUID(uuidString: $0.id) })
        if !requests.isEmpty { port.adoptRequests(requests, done: done) }
        return Dictionary(records.map { ($0.id, true) }, uniquingKeysWith: { first, _ in first })
    }

    func remove(_ type: String, ids: [String]) {
        let uuids = ids.compactMap(UUID.init(uuidString:))
        if !uuids.isEmpty { port.removeRequests(uuids) }
    }

    func blobFile(_ type: String, id: String, field: String) -> URL? { nil }
    func storeBlob(_ type: String, id: String, field: String, file: URL) {}
}

/// A request's record: `request` from the asker, `outcome` from whoever carried it out. A key this
/// device has nothing for is left out, so it never clears the other side's.
struct RequestItem<R: Encodable & Sendable>: Encodable, Sendable {
    let request: R
    let outcome: String?

    private enum Keys: String, CodingKey { case request, outcome }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(outcome, forKey: .outcome)
    }
}
