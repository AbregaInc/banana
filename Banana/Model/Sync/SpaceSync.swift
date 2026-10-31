import Foundation
import os

/// The sync engine for one space (docs/design/DATA-PLATFORM.md §3, §4, §6).
///
/// Stores report their edits (`changed`, `deleted`, `offered`); after two seconds of quiet, or on
/// a push, the foreground or the minute's tick, one pass runs:
/// 1. seeds waiting types (§3, "Seeding");
/// 2. turns the stores' reported edits into waiting fields, each with a new clock;
/// 3. hands its store again each record marked to be handed over (edited here when it arrived, or
///    a write of this device's that lost);
/// 4. sends what waits, at most 500 records and about 1.5 MB a request, each record's blobs first;
///    then pulls after the cursor until the service says there's no more, handing what changed to
///    the stores on the main actor, one batch per type.
///
/// Eager blobs come down on their own queue, with retries, after the pass. Records a store couldn't
/// take yet are offered again only on `replay(types:)`, when a type their catalog entry lists in
/// `after` arrives, and once after their adapter registers.
///
/// Passes never overlap. Everything a pass writes to the mirror goes through it, and what the
/// stores report while their records are applied (the echo) is ignored.
actor SpaceSync {
    struct Configuration: Sendable {
        var device: String
        var isHub: Bool
        var catalog: DataCatalog
        var space: String?
        /// The quiet after a local change before a pass.
        var debounce: Duration = .seconds(2)
        /// Records per request (the service takes at most 500).
        var batchSize = 500
        /// Canonical bytes per request (the service takes a body of at most 2 MB).
        var batchBytes = 1_500_000
        /// Seconds before a failed blob is tried again, doubling with each try up to 30 min.
        var blobRetryBase: Double = 5
        var now: @Sendable () -> Date = { Date() }
        var log: @Sendable (String) -> Void = { _ in }
        /// Held for the length of every pass, so it can finish with the app in the background (on
        /// iOS, a background task); what it returns lets go.
        var holdWhilePassing: (@Sendable (_ reason: String) async -> @Sendable () async -> Void)?
        /// Blobs uploaded at once: a first seed has hundreds of photos and recordings.
        var uploadsAtOnce = 4

        init(device: String, isHub: Bool, catalog: DataCatalog, space: String? = nil) {
            self.device = device
            self.isHub = isHub
            self.catalog = catalog
            self.space = space
        }
    }

    /// What the account says of its iPhone (§3 seeding rule 2), from `/v1/account`: a spoke seeds a
    /// type once the iPhone has; with no iPhone active in 30 days it seeds on its own, phone-set
    /// kinds as `edited`.
    enum HubPresence: Sendable, Equatable {
        case unknown
        case seeded(Set<String>)
        case none
    }

    struct Status: Sendable, Equatable {
        var cursor: Int64
        var epoch: String?
        var pendingRecords: Int
        var seeded: Set<String>
        var waitingToSeed: Set<String>
        var awaitingPhoneSet: Set<String>
        var healthConsent: Bool
        var offset: Int64
        var isSeeded: Bool
        /// Records the service refused for good, kept here until their store reports them again.
        var refused: Int
        /// Eager blobs still to fetch.
        var blobsWanted: Int
    }

    let mirror: RecordMirror
    let transport: SyncTransport
    let config: Configuration

    private var clock: HLCClock
    private var adapters: [String: AdapterRef] = [:]
    private nonisolated let intents = LocalIntents()
    private var hub: HubPresence = .unknown
    private(set) var healthConsent = false
    /// When the consent was last withdrawn here or learned withdrawn, and when the withdrawal was
    /// confirmed done: a `health: true` from an answer to a request sent before then is stale (§7).
    private var consentWithdrawnAt: Int64?
    private var withdrawalConfirmedAt: Int64?
    /// Whether the mirror may hold T2 rows, so a `health: false` answer doesn't scan it each time.
    private var healthRows = false
    private var seeded: Set<String> = []
    private var wantSeed: Set<String> = []
    private var awaitingPhoneSet: Set<String> = []
    private var arrivals: [String: Set<String>] = [:]
    private var cursor: Int64 = 0
    private var epoch: String?
    private var seedAcknowledgedReported = false
    private var onSeedAcknowledged: (@Sendable () async -> Void)?
    private var onHealthConsent: (@Sendable (Bool) async -> Void)?
    private var stopped = false

    // Passes, one at a time.
    private var locked = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private var requested = 0
    private var completed = 0
    private var passAgain = false
    private var debounceTask: Task<Void, Never>?
    /// Records per request in this pass: halved after a 413.
    private var batchLimit = 500

    // Blobs.
    private var blobBackoff: [String: (attempts: Int, notBefore: Int64)] = [:]
    private var blobDrain: Task<Void, Never>?
    private var blobWake: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.boris.banana", category: "space-sync")

    init(mirror: RecordMirror, transport: SyncTransport, config: Configuration) throws {
        self.mirror = mirror
        self.transport = transport
        self.config = config
        let health = config.catalog.healthTypes
        let saved = try mirror.read { tx -> SavedState in
            SavedState(
                hlc: try tx.meta(Meta.hlc, as: HLCState.self) ?? HLCState(),
                cursor: try tx.meta(Meta.cursor, as: Int64.self) ?? 0,
                epoch: try tx.meta(Meta.epoch, as: String.self),
                seeded: try tx.meta(Meta.seeded, as: Set<String>.self) ?? [],
                wantSeed: try tx.meta(Meta.wantSeed, as: Set<String>.self) ?? [],
                awaitingPhoneSet: try tx.meta(Meta.awaitingPhoneSet, as: Set<String>.self) ?? [],
                healthConsent: try tx.meta(Meta.healthConsent, as: Bool.self) ?? false,
                consentWithdrawnAt: try tx.meta(Meta.consentWithdrawnAt, as: Int64.self),
                withdrawalConfirmedAt: try tx.meta(Meta.withdrawalConfirmedAt, as: Int64.self),
                seedAcknowledged: try tx.meta(Meta.seedAcknowledged, as: Bool.self) ?? false,
                healthRows: try tx.hasRecords(types: health))
        }
        clock = HLCClock(device: config.device, state: saved.hlc)
        cursor = saved.cursor
        epoch = saved.epoch
        seeded = saved.seeded
        wantSeed = saved.wantSeed
        awaitingPhoneSet = saved.awaitingPhoneSet
        healthConsent = saved.healthConsent
        consentWithdrawnAt = saved.consentWithdrawnAt
        withdrawalConfirmedAt = saved.withdrawalConfirmedAt
        seedAcknowledgedReported = saved.seedAcknowledged
        healthRows = saved.healthRows
        batchLimit = config.batchSize
    }

    private struct SavedState {
        var hlc: HLCState, cursor: Int64, epoch: String?, seeded: Set<String>, wantSeed: Set<String>
        var awaitingPhoneSet: Set<String>, healthConsent: Bool, consentWithdrawnAt: Int64?
        var withdrawalConfirmedAt: Int64?, seedAcknowledged: Bool, healthRows: Bool
    }

    private enum Meta {
        static let hlc = "hlc", cursor = "cursor", epoch = "epoch", seeded = "seeded", wantSeed = "wantSeed"
        static let awaitingPhoneSet = "awaitingPhoneSet", healthConsent = "healthConsent"
        static let consentWithdrawnAt = "consentWithdrawnAt", withdrawalConfirmedAt = "withdrawalConfirmedAt"
        static let seedAcknowledged = "seedAcknowledged"
        /// Per phone-set type: ids the store reported while it waited for the phone's set, kept
        /// across a relaunch so taking the set doesn't drop them.
        static let touchedAwaiting = "touchedAwaiting"
    }

    private var nowMs: Int64 { HLCClock.ms(config.now()) }

    // MARK: - Adapters and inputs

    /// An area's stores join. Records of its types that waited (they arrived first, or a store
    /// couldn't take them) are offered to it once.
    func registerAdapter(_ adapter: any RecordAdapter) async {
        let ref = AdapterRef(adapter)
        let types = await MainActor.run { ref.adapter.types }
        var joined: [String] = []
        for type in types {
            if config.catalog[type] == nil { log("adapter type \(type) is not in the catalog: ignored"); continue }
            adapters[type] = ref
            joined.append(type)
        }
        await replay(types: joined)
    }

    /// The engine stops for good: no more passes, retries or downloads (another account signed in,
    /// or the account was deleted).
    func stop() {
        stopped = true
        debounceTask?.cancel()
        blobDrain?.cancel()
        blobWake?.cancel()
    }

    /// The Health consent as given or withdrawn on this device (§7). A withdrawal here stays until
    /// `consentWithdrawalConfirmed()`: until then no answer brings the consent back.
    func setHealthConsent(_ granted: Bool) async {
        if granted {
            consentWithdrawnAt = nil
            withdrawalConfirmedAt = nil
            saveMeta { tx in
                try tx.setMeta(Meta.consentWithdrawnAt, Optional<Int64>.none)
                try tx.setMeta(Meta.withdrawalConfirmedAt, Optional<Int64>.none)
            }
            guard !healthConsent else { return }
            healthConsent = true
            saveMeta { try $0.setMeta(Meta.healthConsent, true) }
        } else {
            // Only a consent that was there can be withdrawn; never having said yes changes nothing.
            guard healthConsent || healthRows else { return }
            withdraw(confirmedAt: nil)
        }
        notifyConsent(granted)
    }

    /// The service has the withdrawal (`DELETE /v2/consents/health` answered): answers to requests
    /// sent from now on say the consent as it is.
    func consentWithdrawalConfirmed() {
        withdrawalConfirmedAt = nowMs
        saveMeta { try $0.setMeta(Meta.withdrawalConfirmedAt, self.withdrawalConfirmedAt) }
    }

    private func notifyConsent(_ granted: Bool) {
        // Outside the pass that learned it: the handler may well call `seed(types:)`.
        if let handler = onHealthConsent { Task { await handler(granted) } }
    }

    func setHubPresence(_ presence: HubPresence) async {
        guard presence != hub else { return }
        hub = presence
        if !wantSeed.isEmpty || !awaitingPhoneSet.isEmpty { await syncNow(reason: "hub seeded") }
    }

    func setSeedAcknowledgedHandler(_ handler: (@Sendable () async -> Void)?) { onSeedAcknowledged = handler }
    func setHealthConsentHandler(_ handler: (@Sendable (Bool) async -> Void)?) { onHealthConsent = handler }

    /// An item edited on this device. Any thread; the pass after two seconds of quiet sends it.
    /// Whether a store's report of this item, now, is the echo of the engine handing it a record
    /// (`MoveOver` then leaves what it holds for the item alone).
    nonisolated func isApplying(type: String, id: String) -> Bool { intents.isSuppressed(type, id) }

    nonisolated func changed(type: String, ids: [String]) {
        if intents.note(type, ids, .changed) { Task { await self.scheduleDebounced() } }
    }

    /// An item deleted on purpose on this device (never a cap's pruning: §3).
    nonisolated func deleted(type: String, ids: [String]) {
        if intents.note(type, ids, .deleted) { Task { await self.scheduleDebounced() } }
    }

    /// Offered rather than edited (`ControlChangeReporter.offered`): written at clock 0, so any real
    /// edit made anywhere beats it.
    nonisolated func offered(type: String, ids: [String]) {
        if intents.note(type, ids, .offered) { Task { await self.scheduleDebounced() } }
    }

    /// Today's items of these types enter the mirror under the seeding rules (§3), at the next pass.
    func seed(types: [String]) async {
        wantSeed.formUnion(types)
        saveMeta { try $0.setMeta(Meta.wantSeed, self.wantSeed) }
        await syncNow(reason: "seed")
    }

    /// Items the legacy drain brought in after the seed (§3 seeding rule 6): they enter with their
    /// seed clocks, never a fresh one.
    func seedArrived(type: String, ids: [String]) async {
        arrivals[type, default: []].formUnion(ids)
        await syncNow(reason: "drain")
    }

    /// Hands every waiting record of these types to its store again (§5): a show arrived, so the
    /// settings held back for it can go in now.
    func replay(types: [String]) async {
        await acquire()
        defer { release() }
        for type in types.sorted() { await replayWaiting(type: type, only: nil) }
    }

    /// Whether every record this device seeded came back in an answer, and none was refused: what
    /// it reports as `seededAt` (§4).
    var isSeeded: Bool { computeIsSeeded() }

    func status() -> Status {
        let counts = read { tx in (try tx.pendingCount(), try tx.refusedCount(), try tx.wantedCount()) } ?? (0, 0, 0)
        return Status(cursor: cursor, epoch: epoch, pendingRecords: counts.0, seeded: seeded, waitingToSeed: wantSeed,
                      awaitingPhoneSet: awaitingPhoneSet, healthConsent: healthConsent, offset: clock.state.offset,
                      isSeeded: computeIsSeeded(), refused: counts.1, blobsWanted: counts.2)
    }

    // MARK: - Passes

    private func scheduleDebounced() {
        guard !stopped else { return }
        debounceTask?.cancel()
        let quiet = config.debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "change")
        }
    }

    /// One pass, now (a push, the foreground, the minute's tick, or a test). Calls that arrive
    /// while one runs share the next.
    func syncNow(reason: String) async {
        requested += 1
        let ticket = requested
        await acquire()
        defer { release() }
        guard completed < ticket, !stopped else { return }
        let letGo = await config.holdWhilePassing?(reason)
        var rounds = 0
        repeat {
            let target = requested
            passAgain = false
            await pass(reason: reason)
            completed = target
            rounds += 1
        } while passAgain && rounds < 3 && !stopped
        await letGo?()
    }

    private func acquire() async {
        guard locked else { locked = true; return }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    private func release() {
        if lockWaiters.isEmpty { locked = false } else { lockWaiters.removeFirst().resume() }
    }

    private func pass(reason: String) async {
        batchLimit = config.batchSize
        blobsSentThisPass = 0
        var recordsSent = 0
        defer {
            if recordsSent > 0 || blobsSentThisPass > 0 {
                let waiting = read { try $0.pendingCount() } ?? 0
                log("\(reason): sent \(recordsSent) record(s) and \(blobsSentThisPass) blob(s); \(waiting) record(s) waiting")
            }
        }
        await seedWaitingTypes()
        await seedArrivals()
        await collectLocalEdits()
        for type in adapters.keys.sorted() where seeded.contains(type) {
            await replayWaiting(type: type, only: .redeliver)
        }

        var sentThisPass = Set<RecordKey>(), restampedThisPass = Set<RecordKey>()
        var pullComplete = false
        var rounds = 0
        while rounds < 100_000, !stopped {
            rounds += 1
            let (changes, keys) = await nextBatch(excluding: &sentThisPass)
            let sentAt = config.now()
            let answer: SyncAnswer
            do {
                answer = try await transport.sync(SyncRequest(space: config.space, device: config.device,
                                                              since: cursor, changes: changes))
            } catch let error as SyncTransportError where error.isTooLarge && !changes.isEmpty {
                if changes.count > 1 {
                    batchLimit = max(1, changes.count / 2)
                    sentThisPass.subtract(keys)
                    log("\(reason): request too large; \(batchLimit) record(s) a request from now on in this pass")
                } else {
                    refuseLocally(keys[0], reason: "too_large")
                }
                continue
            } catch {
                log("\(reason): sync failed, \(changes.count) record(s) wait: \(error)")
                return
            }
            recordsSent += answer.applied.count
            let outcome = await process(answer, sentAt: sentAt, receivedAt: config.now())
            if outcome.restart {
                passAgain = true
                return
            }
            for key in outcome.restamped where !restampedThisPass.contains(key) {
                // Stamped again after a "clock" refusal: once more in this pass.
                restampedThisPass.insert(key)
                sentThisPass.remove(key)
            }
            if changes.isEmpty && !answer.more {
                pullComplete = true
                break
            }
        }
        if pullComplete {
            await adoptPhoneSets()
            await tellPullCompleted()
        }
        await reportSeedIfAcknowledged()
        kickBlobDrain()
    }

    /// The next records to send, with their blobs uploaded first: at most `batchLimit` records
    /// and `batchBytes` of canonical text. A blob the store can't hand over yet, or the service
    /// refused for good, holds back only its own field; one whose upload fails holds back its
    /// record, alone.
    private func nextBatch(excluding sent: inout Set<RecordKey>) async -> ([SyncRequest.Change], [RecordKey]) {
        guard let keys = read({ try $0.pendingKeys() }) else { return ([], []) }
        await uploadAhead(Array(keys.filter { !sent.contains($0) && mayWrite($0.type) }.prefix(batchLimit)))
        var changes: [SyncRequest.Change] = [], included: [RecordKey] = []
        var bytes = 0
        for key in keys where !sent.contains(key) && mayWrite(key.type) {
            if changes.count >= batchLimit { break }
            guard let pending = read({ try $0.pending(key) }) ?? nil else { sent.insert(key); continue }
            guard let change = await prepare(pending) else { sent.insert(key); continue }
            let size = (try? CanonicalJSON.string(CanonicalJSON.value(of: change)).utf8.count) ?? 0
            if !changes.isEmpty && bytes + size > config.batchBytes { break }
            sent.insert(key)
            bytes += size
            changes.append(change)
            included.append(key)
        }
        if blobConsentRefused {
            blobConsentRefused = false
            withdraw(confirmedAt: nowMs)
            notifyConsent(false)
            let health = config.catalog.healthTypes
            return (changes.filter { !health.contains($0.type) }, included.filter { !health.contains($0.type) })
        }
        return (changes, included)
    }

    /// A T2 blob the service refused for want of the consent: T2 stops, as for a refused record.
    private var blobConsentRefused = false

    private func prepare(_ pending: RecordMirror.Pending) async -> SyncRequest.Change? {
        let key = pending.key
        let blobFields = config.catalog[key.type]?.blobFields ?? [:]
        var set: [String: JSONValue] = [:], clocks: [String: String] = [:]
        for (field, entry) in pending.fields {
            if blobFields[field] != nil, let ref = entry.value.blobReference {
                switch await upload(ref, key: key, field: field) {
                case .ready: break
                case .notYet: continue
                case .failed: return nil
                }
            }
            set[field] = entry.value
            clocks[field] = entry.clock.clock
        }
        guard !set.isEmpty || pending.delete != nil else { return nil }
        return SyncRequest.Change(type: key.type, id: key.id, set: set, clocks: clocks, delete: pending.delete?.clock)
    }

    private enum UploadOutcome { case ready, notYet, failed }

    /// Blobs uploaded in the pass under way, for its log line.
    private var blobsSentThisPass = 0

    /// The blobs of the next records, several at a time (`uploadsAtOnce`), before the records are
    /// prepared one by one: each record still goes only once its own blobs are there (`prepare`),
    /// and one that failed waits alone, as before.
    private func uploadAhead(_ keys: [RecordKey]) async {
        var jobs: [(ref: BlobReference, key: RecordKey, field: String)] = []
        var shas = Set<String>()
        for key in keys {
            guard let blobFields = config.catalog[key.type]?.blobFields, !blobFields.isEmpty,
                  let pending = read({ try $0.pending(key) }) ?? nil else { continue }
            for (field, entry) in pending.fields where blobFields[field] != nil {
                guard let ref = entry.value.blobReference, read({ try $0.isUploaded(ref.sha256) }) != true,
                      shas.insert(ref.sha256).inserted else { continue }
                jobs.append((ref, key, field))
            }
        }
        guard jobs.count > 1 else { return }   // one: `prepare` uploads it in turn
        let most = max(1, config.uploadsAtOnce)
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for job in jobs {
                if running >= most {
                    await group.next()
                    running -= 1
                }
                group.addTask { _ = await self.upload(job.ref, key: job.key, field: job.field) }
                running += 1
            }
        }
    }

    /// Milliseconds before trying a blob again after its `attempts`-th failure: 5 s doubling, at
    /// most 30 min.
    private func backoff(_ attempts: Int) -> Int64 {
        Int64(min(config.blobRetryBase * pow(2.0, Double(max(0, attempts - 1))), 1_800) * 1000)
    }

    private func upload(_ ref: BlobReference, key: RecordKey, field: String) async -> UploadOutcome {
        if read({ try $0.isUploaded(ref.sha256) }) == true { return .ready }
        // The consent was refused for one health blob in this pass: the rest aren't tried.
        if blobConsentRefused, config.catalog[key.type]?.isHealth == true { return .failed }
        if read({ try $0.isBlobRefused(key, field: field, sha: ref.sha256) }) == true { return .notYet }
        if let wait = blobBackoff[ref.sha256], wait.notBefore > nowMs { return .failed }
        guard let adapter = adapters[key.type] else { return .notYet }
        let file = await MainActor.run { adapter.adapter.blobFile(key.type, id: key.id, field: field, sha: ref.sha256) }
        guard let file else { return .notYet }
        do {
            try await transport.putBlob(sha256: ref.sha256, file: file, type: key.type)
            blobBackoff[ref.sha256] = nil
            blobsSentThisPass += 1
            saveMeta { tx in
                try tx.setUploaded(ref.sha256, true)
                try tx.setLocalBlob(key, field: field, sha: ref.sha256)
            }
            return .ready
        } catch let error as SyncTransportError where error.isConsent {
            blobConsentRefused = true
            log("blob for \(key.type) \(key.id).\(field) refused for want of the Health consent")
            return .failed
        } catch let error as SyncTransportError where error.isPermanent {
            // Refused for good: the field waits until the store reports the record again; the rest
            // of the record goes.
            saveMeta { try $0.refuseBlob(key, field: field, sha: ref.sha256, reason: "\(error)", at: self.nowMs) }
            log("blob for \(key.type) \(key.id).\(field) refused: \(error); its field waits for the next change")
            return .notYet
        } catch {
            let attempts = (blobBackoff[ref.sha256]?.attempts ?? 0) + 1
            blobBackoff[ref.sha256] = (attempts, nowMs + backoff(attempts))
            log("blob for \(key.type) \(key.id).\(field) didn't go up (try \(attempts)), its record waits: \(error)")
            return .failed
        }
    }

    private func refuseLocally(_ key: RecordKey, reason: String) {
        saveMeta { tx in
            try tx.dropPending(key)
            try tx.rejectSeed(key)
            try tx.refuse(key, reason: reason, at: self.nowMs)
        }
        log("\(key.type) \(key.id) refused: \(reason)")
        tellRefused([(key, reason)])
    }

    private func tellRefused(_ refusals: [(RecordKey, String)]) {
        let byAdapter = refusals.compactMap { key, reason in adapters[key.type].map { ($0, key, reason) } }
        guard !byAdapter.isEmpty else { return }
        Task { @MainActor in
            for (adapter, key, reason) in byAdapter { adapter.adapter.refused(type: key.type, id: key.id, reason: reason) }
        }
    }

    // MARK: - Answers

    private struct Outcome {
        /// Records stamped again after a "clock" refusal, to send again.
        var restamped: Set<RecordKey> = []
        /// The space was started over: the pass ends, the next seeds and reads from the start.
        var restart = false
    }

    private func process(_ answer: SyncAnswer, sentAt: Date, receivedAt: Date) async -> Outcome {
        clock.learn(serverNow: answer.now, sent: sentAt, received: receivedAt)
        if let answered = answer.epoch, answered != epoch {
            if epoch != nil {
                startOver(epoch: answered)
                return Outcome(restart: true)
            }
            epoch = answered
            saveMeta { try $0.setMeta(Meta.epoch, answered) }
        }
        if let health = answer.consents?.health { takeConsent(health, sentAt: sentAt, receivedAt: receivedAt) }

        var deliver: [String: [String]] = [:]
        var tooFast: [RecordKey] = []
        var refusals: [(RecordKey, String)] = []
        var restored = false
        let catalog = config.catalog
        let health = catalog.healthTypes
        saveMeta { tx in
            for applied in answer.applied {
                let key = RecordKey(type: applied.type, id: applied.id)
                applied.clocks.values.forEach { self.clock.observe($0, fromService: true) }
                if let deleted = applied.deleted { self.clock.observe(deleted, fromService: true) }
                try tx.acknowledge(key, clocks: applied.clocks, deleted: applied.deleted)
                try tx.clearSeedPending(key)
            }
            for rejected in answer.rejected {
                let key = RecordKey(type: rejected.type, id: rejected.id)
                self.log("\(rejected.type) \(rejected.id) refused: \(rejected.reason)")
                switch rejected.reason {
                case "blob_missing":
                    // The service lost track of a blob: it goes up again, then the record.
                    for (field, entry) in try tx.pending(key)?.fields ?? [:] where catalog[key.type]?.blobFields[field] != nil {
                        if let sha = entry.value.blobReference?.sha256 { try tx.setUploaded(sha, false) }
                    }
                case "consent":
                    break   // the whole of T2 stops below
                case "clock":
                    tooFast.append(key)   // stamped again below
                default:
                    try tx.dropPending(key)
                    try tx.rejectSeed(key)
                    try tx.refuse(key, reason: rejected.reason, at: self.nowMs)
                    refusals.append((key, rejected.reason))
                }
            }
            for record in answer.changes {
                let key = RecordKey(type: record.type, id: record.id)
                record.clocks.values.forEach { self.clock.observe($0, fromService: true) }
                if let deleted = record.deleted { self.clock.observe(deleted, fromService: true) }
                let kind = catalog[record.type]?.merge ?? .field
                let current = try tx.record(key)
                let server = RecordState(fields: record.fields, clocks: record.clocks, deleted: record.deleted)
                let (merged, changed) = RecordMerge.join(current?.state, server, kind: kind)
                try tx.save(RecordMirror.Stored(key: key, state: merged, seq: record.seq,
                                               localEncoding: current?.localEncoding, waiting: current?.waiting ?? .no))
                if health.contains(record.type) { self.healthRows = true }
                // A delete this device sent and the service now holds is done.
                if let deleted = record.deleted { try tx.acknowledge(key, clocks: [:], deleted: deleted) }
                if changed || current == nil || current?.waiting == .redeliver {
                    deliver[record.type, default: []].append(record.id)
                }
            }
            if let head = answer.head, head < self.cursor {
                // Same space, but behind this device's cursor: restored to an earlier point. The
                // service read it from the start; what this device knows goes up again.
                self.log("the space's head \(head) is behind this device's cursor \(self.cursor): restored; reading from the start and sending what this device holds")
                self.cursor = 0
                try tx.setMeta(Meta.cursor, Int64(0))
                restored = true
            }
            if let next = answer.next, next > self.cursor {
                self.cursor = next
                try tx.setMeta(Meta.cursor, next)
            }
            try tx.setMeta(Meta.hlc, self.clock.state)
        }
        if answer.rejected.contains(where: { $0.reason == "consent" }), healthConsent || healthRows {
            withdraw(confirmedAt: HLCClock.ms(receivedAt))
            notifyConsent(false)
        }
        if restored { resendEverything() }
        var outcome = Outcome()
        if !tooFast.isEmpty { outcome.restamped = restampTooFast(serverNow: answer.now, refused: tooFast.count) }
        tellRefused(refusals)
        for type in deliver.keys.sorted() {
            let taken = await deliverRecords(type: type, ids: deliver[type]!)
            if taken > 0 {
                for child in catalog.replayed(after: type) { await replayWaiting(type: child, only: nil) }
            }
        }
        return outcome
    }

    /// The consent an answer carries (§7). `false` always stops T2 here. `true` counts only from
    /// an answer to a request sent after this device's withdrawal was confirmed done, so a stale
    /// answer never undoes a withdrawal.
    private func takeConsent(_ granted: Bool, sentAt: Date, receivedAt: Date) {
        if !granted {
            if healthConsent || healthRows {
                withdraw(confirmedAt: HLCClock.ms(receivedAt))
                notifyConsent(false)
            } else if consentWithdrawnAt != nil, withdrawalConfirmedAt == nil {
                withdrawalConfirmedAt = HLCClock.ms(receivedAt)   // the service says it's gone: done
                saveMeta { try $0.setMeta(Meta.withdrawalConfirmedAt, self.withdrawalConfirmedAt) }
            }
            return
        }
        guard !healthConsent else { return }
        if consentWithdrawnAt != nil {
            guard let confirmed = withdrawalConfirmedAt, HLCClock.ms(sentAt) > confirmed else { return }
        }
        healthConsent = true
        consentWithdrawnAt = nil
        withdrawalConfirmedAt = nil
        saveMeta { tx in
            try tx.setMeta(Meta.healthConsent, true)
            try tx.setMeta(Meta.consentWithdrawnAt, Optional<Int64>.none)
            try tx.setMeta(Meta.withdrawalConfirmedAt, Optional<Int64>.none)
        }
        passAgain = true   // the T2 types waiting to seed can now
        notifyConsent(true)
    }

    /// The service refused clocks as more than five minutes ahead (§3): every clock this device
    /// made out of reach is stamped again at its physical time plus the offset known now, wherever
    /// it waits; then the clock itself comes down.
    private func restampTooFast(serverNow: Int64, refused: Int) -> Set<RecordKey> {
        let most = serverNow + HLCClock.mostAhead
        let clock = self.clock
        let now = config.now()
        var restamped = Set<RecordKey>()
        saveMeta { tx in
            for key in try tx.pendingKeys() {
                let moved = try tx.restamp(key, offset: clock.state.offset) {
                    clock.restamped($0.clock, offsetAtIssue: $0.offset, mostMs: most, now: now)
                }
                if moved { restamped.insert(key) }
            }
        }
        self.clock.lower(mostMs: most)
        saveMeta { try $0.setMeta(Meta.hlc, self.clock.state) }
        log("\(refused) record(s) refused for a fast clock: \(restamped.count) stamped again (offset \(self.clock.state.offset) ms)")
        return restamped
    }

    /// A new epoch: the space was emptied (§4). Everything from the old one leaves the mirror, the
    /// clock stays, and every store seeds again with its own times.
    private func startOver(epoch new: String) {
        log("the space was started over (epoch \(epoch ?? "?") → \(new)): seeding again from the stores")
        saveMeta { try $0.clearForNewEpoch() }
        epoch = new
        cursor = 0
        // Only what was asked to seed before (a tier `MoveOver` has moved): seeding a type still
        // waiting would apply the space's records into stores whose legacy sync still writes iCloud.
        wantSeed.formUnion(seeded.union(awaitingPhoneSet))
        seeded = []
        awaitingPhoneSet = []
        seedAcknowledgedReported = false
        healthRows = false
        blobBackoff = [:]
        saveMeta { tx in
            try tx.setMeta(Meta.epoch, new)
            try tx.setMeta(Meta.cursor, Int64(0))
            try tx.setMeta(Meta.wantSeed, self.wantSeed)
            try tx.setMeta(Meta.seeded, self.seeded)
            try tx.setMeta(Meta.awaitingPhoneSet, self.awaitingPhoneSet)
            try tx.setMeta(Meta.seedAcknowledged, false)
            try tx.setMeta(Meta.touchedAwaiting, Optional<[String: Set<String>]>.none)
        }
    }

    /// After a restore: every record this device holds goes up again with the clocks it holds, so
    /// the space gets back what it lost and nothing older wins.
    private func resendEverything() {
        let offset = clock.state.offset
        saveMeta { tx in
            for record in try tx.allRecords() where self.mayWrite(record.key.type) {
                for (field, value) in record.state.fields {
                    guard let at = record.state.clocks[field] else { continue }
                    try tx.enqueue(record.key, fields: [field: value], clock: at, offset: offset)
                }
                if let deleted = record.state.deleted { try tx.enqueueDelete(record.key, clock: deleted, offset: offset) }
            }
        }
        passAgain = true
    }

    // MARK: - Handing records to the stores

    /// Hands the mirror's merged records to their store, on the main actor, in one batch, and
    /// returns how many it took. A record waits instead when its store isn't registered or seeded
    /// yet, when it was edited here and the edit hasn't been collected, or when the store can't
    /// take it yet (`apply` said false). What the store reports while this runs is the echo, and
    /// is ignored.
    @discardableResult
    private func deliverRecords(type: String, ids: [String]) async -> Int {
        guard !ids.isEmpty, !stopped else { return 0 }
        guard let adapter = adapters[type], seeded.contains(type),
              let stored = read({ try $0.records(type: type, ids: ids) }) else {
            saveMeta { tx in
                for id in ids {
                    let key = RecordKey(type: type, id: id)
                    if try tx.record(key)?.waiting != .refused { try tx.setWaiting(key, .redeliver) }
                }
            }
            return 0
        }
        let intents = self.intents
        let visible = stored.filter(\.state.isVisible).map { (id: $0.key.id, fields: $0.state.fields) }
        let gone = stored.filter { !$0.state.isVisible }.map(\.key.id)
        let outcome = await MainActor.run { () -> DeliveryOutcome in
            // Checked and applied in one go on the main actor: no store edit can come between.
            let editedHere = intents.pendingIDs(type)
            let applying = visible.filter { !editedHere.contains($0.id) }
            let removing = gone.filter { !editedHere.contains($0) }
            intents.suppress(type, Set(applying.map(\.id)).union(removing))
            defer { intents.suppress(type, []) }
            let results = applying.isEmpty ? [:] : adapter.adapter.apply(type, records: applying)
            if !removing.isEmpty { adapter.adapter.remove(type, ids: removing) }
            let taken = Set(applying.map(\.id).filter { results[$0] ?? false })
            let kept = applying.isEmpty ? [] : adapter.adapter.keptOwn(type).intersection(taken)
            let items = taken.isEmpty ? [:] : adapter.adapter.items(type, ids: taken)
            return DeliveryOutcome(taken: taken, refused: Set(applying.map(\.id)).subtracting(taken),
                                   removed: Set(removing), deferred: editedHere.intersection(ids), kept: kept, items: items)
        }
        let encoded = outcome.items.compactMapValues { try? CanonicalJSON.fields(of: $0) }
        let eager = (config.catalog[type]?.blobFields ?? [:]).filter { $0.value == .eager }.map(\.key)
        saveMeta { tx in
            for record in stored where outcome.taken.contains(record.key.id) {
                try tx.setWaiting(record.key, .no)
                // A store that kept its own copy is compared with what arrived, so its copy goes
                // up as an edit.
                try tx.setLocalEncoding(record.key, outcome.kept.contains(record.key.id)
                                        ? record.state.fields : encoded[record.key.id])
                for field in eager {
                    guard let sha = record.state.fields[field]?.blobReference?.sha256,
                          try tx.localBlob(record.key, field: field) != sha else { continue }
                    try tx.want(record.key, field: field, sha: sha)
                }
            }
            for id in outcome.removed {
                let key = RecordKey(type: type, id: id)
                try tx.setWaiting(key, .no)
                try tx.setLocalEncoding(key, nil)
            }
            for id in outcome.refused { try tx.setWaiting(RecordKey(type: type, id: id), .refused) }
            for id in outcome.deferred { try tx.setWaiting(RecordKey(type: type, id: id), .redeliver) }
        }
        if !outcome.kept.isEmpty {
            log("\(type): the store kept its own copy of \(outcome.kept.count) record(s); they go up")
            changed(type: type, ids: outcome.kept.sorted())
            passAgain = true
        }
        return outcome.taken.count
    }

    private struct DeliveryOutcome: Sendable {
        var taken: Set<String>, refused: Set<String>, removed: Set<String>, deferred: Set<String>, kept: Set<String>
        var items: [String: any Encodable & Sendable]
    }

    private func replayWaiting(type: String, only state: RecordMirror.Waiting?) async {
        guard let ids = read({ try $0.waitingIDs(type: type, state) }), !ids.isEmpty else { return }
        for start in stride(from: 0, to: ids.count, by: config.batchSize) {
            await deliverRecords(type: type, ids: Array(ids[start..<min(start + config.batchSize, ids.count)]))
        }
    }

    // MARK: - Blobs down

    /// Eager blobs come down on their own, after the pass, with retries: 5 s doubling to 30 min.
    private func kickBlobDrain() {
        guard blobDrain == nil, !stopped else { return }
        blobDrain = Task { [weak self] in await self?.drainBlobs() }
    }

    /// Waits for the eager blobs due now to be fetched (or fail): for tests and the push.
    func blobsSettled() async {
        kickBlobDrain()
        await blobDrain?.value
    }

    private func drainBlobs() async {
        while !stopped, !Task.isCancelled {
            guard let due = read({ try $0.dueBlobs(now: self.nowMs, limit: 20) }), !due.isEmpty else { break }
            for wanted in due {
                guard !stopped else { break }
                await fetch(wanted)
            }
        }
        blobDrain = nil
        blobWake?.cancel()
        if !stopped, let next = read({ try $0.nextBlobDue() }) ?? nil {
            let wait = max(0, next - nowMs)
            blobWake = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled else { return }
                await self?.kickBlobDrain()
            }
        }
    }

    private func fetch(_ wanted: RecordMirror.WantedBlob) async {
        let key = wanted.key
        let current = read { tx in (try tx.record(key)?.state.fields[wanted.field]?.blobReference?.sha256, try tx.localBlob(key, field: wanted.field)) }
        // The field names another blob now, or the store has this one: nothing to fetch.
        guard let current, current.0 == wanted.sha, current.1 != wanted.sha else {
            saveMeta { try $0.blobFetched(wanted) }
            return
        }
        guard let adapter = adapters[key.type] else {
            saveMeta { try $0.blobFailed(wanted, notBefore: self.nowMs + backoff(wanted.attempts + 1)) }
            return
        }
        do {
            let file = try await transport.getBlob(sha256: wanted.sha)
            defer { try? FileManager.default.removeItem(at: file) }
            await MainActor.run { adapter.adapter.storeBlob(key.type, id: key.id, field: wanted.field, file: file) }
            saveMeta { tx in
                try tx.setLocalBlob(key, field: wanted.field, sha: wanted.sha)
                try tx.blobFetched(wanted)
            }
        } catch {
            log("blob for \(key.type) \(key.id).\(wanted.field) didn't come down (try \(wanted.attempts + 1)): \(error)")
            saveMeta { try $0.blobFailed(wanted, notBefore: self.nowMs + backoff(wanted.attempts + 1)) }
        }
    }

    /// A lazy blob (§3: workout samples on spokes, transcripts), fetched on first use. True once
    /// the store has the file.
    func ensureBlob(type: String, id: String, field: String) async -> Bool {
        let key = RecordKey(type: type, id: id)
        guard let record = read({ try $0.record(key) }) ?? nil, let ref = record.state.fields[field]?.blobReference else { return false }
        if read({ try $0.localBlob(key, field: field) }) == ref.sha256 { return true }
        guard let adapter = adapters[type] else { return false }
        do {
            let file = try await transport.getBlob(sha256: ref.sha256)
            defer { try? FileManager.default.removeItem(at: file) }
            await MainActor.run { adapter.adapter.storeBlob(type, id: id, field: field, file: file) }
            saveMeta { try $0.setLocalBlob(key, field: field, sha: ref.sha256) }
            return true
        } catch {
            log("blob for \(type) \(id).\(field) didn't come down: \(error)")
            return false
        }
    }

    // MARK: - Local edits

    private func mayWrite(_ type: String) -> Bool {
        guard let entry = config.catalog[type] else { return false }
        if entry.isHealth && !healthConsent { return false }
        if entry.writers == .hub && !config.isHub { return false }
        return true
    }

    /// Encodes an item, logging any number written as `null` for not being finite.
    private func encode(_ item: any Encodable & Sendable, _ key: RecordKey) -> [String: JSONValue]? {
        do {
            let (fields, nonFinite) = try CanonicalJSON.fieldsReporting(of: item)
            if !nonFinite.isEmpty {
                log("\(key.type) \(key.id): not a finite number at \(nonFinite.joined(separator: ", ")), sent as null")
            }
            return fields
        } catch {
            log("\(key.type) \(key.id) didn't encode: \(error)")
            return nil
        }
    }

    /// What the stores reported, as waiting fields: each changed key gets a new clock (an offer
    /// gets clock 0), a cleared key goes as `null`, a delete as a tombstone. Edits of a type not
    /// seeded yet are kept until it is: its seed reads the store as it is then, and what the
    /// store reported meanwhile is still this device's (a delete becomes a tombstone once the
    /// record is here; a spoke keeps what it added while it waited for the phone's set). A batch
    /// the mirror couldn't write is reported again, for the next pass.
    private func collectLocalEdits() async {
        let writable = Set(adapters.keys.filter { seeded.contains($0) && mayWrite($0) })
        let unseeded = Set(adapters.keys.filter { !seeded.contains($0) })
        let awaiting = awaitingPhoneSet
        let adapters = self.adapters
        let intents = self.intents
        let taken = await MainActor.run { () -> (work: [(type: String, intents: [String: LocalIntents.Intent], items: [String: any Encodable & Sendable])], touched: [String: Set<String>]) in
            var touched: [String: Set<String>] = [:]
            let work = intents.takeAll().sorted { $0.key < $1.key }.compactMap { type, byID -> (type: String, intents: [String: LocalIntents.Intent], items: [String: any Encodable & Sendable])? in
                guard writable.contains(type), let adapter = adapters[type] else {
                    if unseeded.contains(type) { intents.restore(type, byID) }   // until the type seeds
                    if awaiting.contains(type) { touched[type, default: []].formUnion(byID.keys) }
                    return nil
                }
                let wanted = Set(byID.filter { $0.value != .deleted }.map(\.key))
                return (type, byID, wanted.isEmpty ? [:] : adapter.adapter.items(type, ids: wanted))
            }
            return (work, touched)
        }
        let work = taken.work
        if !taken.touched.isEmpty {
            // Kept for taking the phone's set, also after a relaunch.
            saveMeta { tx in
                var kept = try tx.meta(Meta.touchedAwaiting, as: [String: Set<String>].self) ?? [:]
                for (type, ids) in taken.touched { kept[type, default: []].formUnion(ids) }
                try tx.setMeta(Meta.touchedAwaiting, kept)
            }
        }
        for unit in work {
            let kind = config.catalog[unit.type]?.merge ?? .field
            let ids = unit.intents.keys.sorted()
            for start in stride(from: 0, to: ids.count, by: config.batchSize) {
                let chunk = Array(ids[start..<min(start + config.batchSize, ids.count)])
                let encodings = Dictionary(uniqueKeysWithValues: chunk.compactMap { id -> (String, [String: JSONValue])? in
                    guard let item = unit.items[id], let fields = encode(item, RecordKey(type: unit.type, id: id)) else { return nil }
                    return (id, fields)
                })
                do {
                    try mirror.write { tx in
                        for id in chunk {
                            try self.collect(RecordKey(type: unit.type, id: id), intent: unit.intents[id]!,
                                             encoding: encodings[id], kind: kind, tx: tx)
                        }
                        try tx.setMeta(Meta.hlc, self.clock.state)
                    }
                } catch {
                    log("couldn't write \(chunk.count) \(unit.type) edit(s) to the mirror, kept for the next pass: \(error)")
                    intents.restore(unit.type, unit.intents.filter { chunk.contains($0.key) })
                }
            }
        }
    }

    private func collect(_ key: RecordKey, intent: LocalIntents.Intent, encoding: [String: JSONValue]?,
                         kind: RecordMerge.Kind, tx: MirrorTransaction) throws {
        let stored = try tx.record(key)
        // The store reported the record again: what the service refused may go once more, whole.
        let wasRefused = try tx.isRefused(key)
        try tx.clearRefusals(key)
        switch intent {
        case .deleted:
            // Nothing to delete if it never left, or is already gone (an echo).
            guard let stored, stored.state.isVisible else { return }
            let d = clock.issue(now: config.now()).text
            let (state, _) = RecordMerge.apply(RecordChange(delete: d), to: stored.state, kind: kind)
            try tx.save(RecordMirror.Stored(key: key, state: state, seq: stored.seq, localEncoding: nil, waiting: .no))
            try tx.enqueueDelete(key, clock: d, offset: clock.state.offset)
        case .changed, .offered:
            guard let encoding else { return }
            let diff = FieldDiff.changes(from: wasRefused ? nil : previous(stored), to: encoding)
            guard !diff.isEmpty else { return }
            let at = intent == .offered ? HLC.fixed(0, device: config.device).text : clock.issue(now: config.now()).text
            try write(key, fields: diff.fields, clock: at, encoding: encoding, over: stored, kind: kind, tx: tx)
        }
    }

    /// What a new encoding is compared with: the last one this app made, or, for an item made again
    /// over a tombstone, the record's last fields that weren't null, so every field the new item
    /// lacks goes up as null and the record comes back exactly as the store has it.
    private func previous(_ stored: RecordMirror.Stored?) -> [String: JSONValue]? {
        guard let stored else { return nil }
        if let encoding = stored.localEncoding { return encoding }
        guard !stored.state.isVisible else { return nil }
        return stored.state.fields.filter { !$0.value.isNull }
    }

    /// Fields this device writes at `clock`: merged into its own copy and queued to go up. When
    /// the copy already holds something newer for one of them, the store is handed the copy again.
    private func write(_ key: RecordKey, fields: [String: JSONValue], clock at: String, encoding: [String: JSONValue],
                       over stored: RecordMirror.Stored?, kind: RecordMerge.Kind, tx: MirrorTransaction,
                       seed: Bool = false) throws {
        let change = RecordChange(set: fields, clocks: fields.mapValues { _ in at })
        let (state, _) = RecordMerge.apply(change, to: stored?.state, kind: kind)
        let lost = fields.contains { state.fields[$0.key] != $0.value }
        try tx.save(RecordMirror.Stored(key: key, state: state, seq: stored?.seq, localEncoding: encoding,
                                       waiting: lost ? .redeliver : (stored?.waiting ?? .no)))
        try tx.enqueue(key, fields: fields, clock: at, offset: clock.state.offset)
        if seed { try tx.addSeedPending(key) }
        if config.catalog[key.type]?.isHealth == true { healthRows = true }
        let blobFields = config.catalog[key.type]?.blobFields ?? [:]
        for (field, value) in encoding where blobFields[field] != nil {
            if let sha = value.blobReference?.sha256 { try tx.setLocalBlob(key, field: field, sha: sha) }
        }
    }

    // MARK: - Seeding (§3)

    private func seedWaitingTypes() async {
        for type in wantSeed.sorted() {
            guard let entry = config.catalog[type] else { wantSeed.remove(type); continue }
            guard let adapter = adapters[type] else { continue }
            if entry.isHealth && !healthConsent { continue }
            if entry.writers == .hub && !config.isHub {
                finishSeeding(type)   // nothing of its own to seed: a spoke only takes the hub's
                continue
            }
            var mode = entry.seed
            if !config.isHub {
                switch hub {
                case .unknown: continue
                case .seeded(let types) where !types.contains(type): continue
                case .seeded:
                    if mode == .phoneSet {
                        // Seeds nothing yet: takes the phone's set on its first full pull that has one.
                        wantSeed.remove(type)
                        awaitingPhoneSet.insert(type)
                        saveMeta { tx in
                            try tx.setMeta(Meta.wantSeed, self.wantSeed)
                            try tx.setMeta(Meta.awaitingPhoneSet, self.awaitingPhoneSet)
                        }
                        continue
                    }
                case .none:
                    break
                }
            }
            if mode == .phoneSet { mode = .edited }
            let snapshot = await takeSeedSnapshot(type: type, adapter: adapter, ids: nil)
            seedItems(type: type, snapshot: snapshot, mode: mode, trackAcknowledgement: true)
            finishSeeding(type)
            log("seeded \(type): \(snapshot.items.count) item(s)")
        }
    }

    private func finishSeeding(_ type: String) {
        wantSeed.remove(type)
        seeded.insert(type)
        saveMeta { tx in
            try tx.setMeta(Meta.wantSeed, self.wantSeed)
            try tx.setMeta(Meta.seeded, self.seeded)
        }
    }

    private func seedArrivals() async {
        let waiting = arrivals
        arrivals = [:]
        for (type, ids) in waiting.sorted(by: { $0.key < $1.key }) {
            guard let entry = config.catalog[type], let adapter = adapters[type], mayWrite(type) else { continue }
            let snapshot = await takeSeedSnapshot(type: type, adapter: adapter, ids: ids)
            seedItems(type: type, snapshot: snapshot, mode: entry.seed == .phoneSet ? .edited : entry.seed,
                      trackAcknowledgement: false)
        }
    }

    private struct SeedSnapshot: Sendable {
        var items: [String: any Encodable & Sendable]
        var dates: [String: Date]
        var ranks: [String: Int]
        var defaults: [String: JSONValue]?
    }

    private func takeSeedSnapshot(type: String, adapter: AdapterRef, ids: Set<String>?) async -> SeedSnapshot {
        await MainActor.run {
            let items = ids.map { adapter.adapter.items(type, ids: $0) } ?? adapter.adapter.snapshot(type)
            var dates: [String: Date] = [:], ranks: [String: Int] = [:]
            for id in items.keys {
                if let date = adapter.adapter.seedClock(type, id: id) { dates[id] = date }
                let rank = adapter.adapter.seedRank(type, id: id)
                if rank != 0 { ranks[id] = rank }
            }
            return SeedSnapshot(items: items, dates: dates, ranks: ranks, defaults: adapter.adapter.defaultEncoding(type))
        }
    }

    /// Encoded, diffed and written off the main actor, 500 at a time (§3 seeding rule 8).
    private func seedItems(type: String, snapshot: SeedSnapshot, mode: DataCatalog.Seed, trackAcknowledgement: Bool) {
        let kind = config.catalog[type]?.merge ?? .field
        let lowClock = HLC.fixed(config.isHub ? 1 : 0, device: config.device).text
        let ids = snapshot.items.keys.sorted()
        for start in stride(from: 0, to: ids.count, by: config.batchSize) {
            let chunk = ids[start..<min(start + config.batchSize, ids.count)]
            let encodings = Dictionary(uniqueKeysWithValues: chunk.compactMap { id -> (String, [String: JSONValue])? in
                encode(snapshot.items[id]!, RecordKey(type: type, id: id)).map { (id, $0) }
            })
            saveMeta { tx in
                for id in chunk {
                    guard let encoding = encodings[id] else { continue }
                    let key = RecordKey(type: type, id: id)
                    let stored = try tx.record(key)
                    var fields = FieldDiff.changes(from: self.previous(stored), to: encoding).fields
                    let at: String
                    if mode == .default {
                        // Only what differs from the compiled default; the hub at 1, a spoke at 0.
                        if let defaults = snapshot.defaults {
                            fields = fields.filter { field, value in
                                defaults[field].map { CanonicalJSON.string($0) != CanonicalJSON.string(value) } ?? true
                            }
                        }
                        at = lowClock
                    } else if let date = snapshot.dates[id] {
                        let hlc = HLC(ms: self.clock.seedMs(date, now: self.config.now()), counter: snapshot.ranks[id] ?? 0,
                                      device: self.config.device)
                        self.clock.observe(hlc.text)
                        at = hlc.text
                    } else {
                        at = lowClock
                    }
                    if fields.isEmpty {
                        var kept = stored ?? RecordMirror.Stored(key: key, state: RecordState(), seq: nil, localEncoding: nil, waiting: .no)
                        kept.localEncoding = encoding
                        try tx.save(kept)
                        continue
                    }
                    try self.write(key, fields: fields, clock: at, encoding: encoding, over: stored, kind: kind,
                                   tx: tx, seed: trackAcknowledgement)
                }
                try tx.setMeta(Meta.hlc, self.clock.state)
            }
        }
    }

    /// A spoke's phone-set kinds (§3 seeding rule 4), after a complete pull: once the service holds
    /// any item of the kind, the items only this device has are dropped and the phone's set comes
    /// in. If the iPhone has seeded the kind and the service holds none, the phone's set is empty,
    /// and this device's own items seed as `edited`.
    /// Every seeded type's store hears that the pull is whole (`RecordAdapter.pullCompleted`).
    private func tellPullCompleted() async {
        let refs = adapters.filter { seeded.contains($0.key) }
        guard !refs.isEmpty else { return }
        await MainActor.run {
            for (type, ref) in refs.sorted(by: { $0.key < $1.key }) { ref.adapter.pullCompleted(type) }
        }
    }

    private func adoptPhoneSets() async {
        for type in awaitingPhoneSet.sorted() {
            guard let adapter = adapters[type], let serverIDs = read({ try $0.ids(type: type) }) else { continue }
            if serverIDs.isEmpty {
                guard case .seeded(let types) = hub, types.contains(type) else { continue }
                let snapshot = await takeSeedSnapshot(type: type, adapter: adapter, ids: nil)
                seedItems(type: type, snapshot: snapshot, mode: .edited, trackAcknowledgement: true)
                awaitingPhoneSet.remove(type)
                saveMeta { tx in
                    try tx.setMeta(Meta.awaitingPhoneSet, self.awaitingPhoneSet)
                    var kept = try tx.meta(Meta.touchedAwaiting, as: [String: Set<String>].self) ?? [:]
                    kept[type] = nil
                    try tx.setMeta(Meta.touchedAwaiting, kept)
                }
                finishSeeding(type)
                log("the phone's \(type) set is empty: seeded this device's \(snapshot.items.count)")
                passAgain = true
                continue
            }
            let intents = self.intents
            let keptTouched = (read({ try $0.meta(Meta.touchedAwaiting, as: [String: Set<String>].self) }) ?? nil)?[type] ?? []
            let (drop, touched) = await MainActor.run { () -> ([String], Set<String>) in
                // Today's `ControlMerge.localOnly`: what only this device has goes, except what
                // was touched here since syncing began (reported while it waited for this set).
                let touched = intents.pendingIDs(type).union(keptTouched)
                let drop = Set(adapter.adapter.snapshot(type).keys).subtracting(serverIDs).subtracting(touched).sorted()
                intents.suppress(type, Set(drop))
                defer { intents.suppress(type, []) }
                if !drop.isEmpty { adapter.adapter.remove(type, ids: drop) }
                return (drop, touched)
            }
            awaitingPhoneSet.remove(type)
            saveMeta { tx in
                var kept = try tx.meta(Meta.touchedAwaiting, as: [String: Set<String>].self) ?? [:]
                kept[type] = nil
                try tx.setMeta(Meta.touchedAwaiting, kept)
            }
            // What was touched here goes up as this device's, at its own edit time.
            let kept = touched.subtracting(serverIDs)
            if !kept.isEmpty {
                let snapshot = await takeSeedSnapshot(type: type, adapter: adapter, ids: kept)
                seedItems(type: type, snapshot: snapshot, mode: .edited, trackAcknowledgement: true)
                passAgain = true
            }
            seeded.insert(type)
            saveMeta { tx in
                try tx.setMeta(Meta.awaitingPhoneSet, self.awaitingPhoneSet)
                try tx.setMeta(Meta.seeded, self.seeded)
            }
            log("took the phone's \(type) set; dropped \(drop.count) of this device's own, kept \(kept.count) touched here")
            await replayWaiting(type: type, only: nil)
        }
    }

    private func computeIsSeeded() -> Bool {
        let waitingTypes = wantSeed.filter { type in
            !(config.catalog[type]?.isHealth == true && !healthConsent)
        }
        guard waitingTypes.isEmpty, !seeded.isEmpty, let counts = read({ try $0.seedCounts() }) else { return false }
        return counts.waiting == 0 && counts.rejected == 0
    }

    private func reportSeedIfAcknowledged() async {
        guard !seedAcknowledgedReported, computeIsSeeded() else { return }
        seedAcknowledgedReported = true
        saveMeta { try $0.setMeta(Meta.seedAcknowledged, true) }
        log("every seeded record acknowledged")
        if let handler = onSeedAcknowledged { Task { await handler() } }
    }

    // MARK: - Health consent (§7)

    /// The consent is gone: T2 stops leaving this device, and its rows leave the mirror (the stores
    /// keep theirs). Its types seed again when the consent comes back. `confirmedAt`: the service
    /// already has the withdrawal (it said so); nil when it was withdrawn here and is on its way.
    private func withdraw(confirmedAt: Int64?) {
        let health = config.catalog.healthTypes
        healthConsent = false
        healthRows = false
        consentWithdrawnAt = consentWithdrawnAt ?? nowMs
        if let confirmedAt { withdrawalConfirmedAt = max(withdrawalConfirmedAt ?? 0, confirmedAt) }
        wantSeed.formUnion(seeded.intersection(health).filter { adapters[$0] != nil })
        seeded.subtract(health)
        saveMeta { tx in
            try tx.drop(types: health)
            try tx.setMeta(Meta.healthConsent, false)
            try tx.setMeta(Meta.consentWithdrawnAt, self.consentWithdrawnAt)
            try tx.setMeta(Meta.withdrawalConfirmedAt, self.withdrawalConfirmedAt)
            try tx.setMeta(Meta.seeded, self.seeded)
            try tx.setMeta(Meta.wantSeed, self.wantSeed)
        }
        log("no Health consent: health records stay on this device")
    }

    // MARK: - Plumbing

    private func saveMeta(_ body: (MirrorTransaction) throws -> Void) {
        do { try mirror.write(body) } catch { log("mirror write failed: \(error)") }
    }

    private func read<T>(_ body: (MirrorTransaction) throws -> T) -> T? {
        do { return try mirror.read(body) } catch {
            log("mirror read failed: \(error)")
            return nil
        }
    }

    private nonisolated func log(_ text: String) {
        Self.logger.notice("\(text, privacy: .public)")
        config.log(text)
    }
}

/// An adapter held off the main actor; only ever called on it.
struct AdapterRef: @unchecked Sendable {
    let adapter: any RecordAdapter
    init(_ adapter: any RecordAdapter) { self.adapter = adapter }
}

/// The edits stores have reported and the next pass hasn't collected, by type and id. Written from
/// any thread; read on the main actor while records are applied, so an item edited here is never
/// overwritten before its edit is collected. What a store reports about the very records being
/// applied to it (its echo) is not noted.
final class LocalIntents: @unchecked Sendable {
    enum Intent: Sendable { case changed, deleted, offered }

    private let lock = NSLock()
    private var byType: [String: [String: Intent]] = [:]
    private var suppressed: (type: String, ids: Set<String>)?

    /// Notes an edit; false when nothing was noted (all of it was the echo of an apply).
    @discardableResult
    func note(_ type: String, _ ids: [String], _ intent: Intent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var noted = false
        for id in ids {
            if let suppressed, suppressed.type == type, suppressed.ids.contains(id) { continue }
            // An offer never takes the place of a real edit or delete waiting for the same item.
            if intent == .offered, let current = byType[type]?[id], current != .offered { continue }
            byType[type, default: [:]][id] = intent
            noted = true
        }
        return noted
    }

    /// While records of `type` are applied: their own reports are the echo. Empty ends it.
    func isSuppressed(_ type: String, _ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let suppressed else { return false }
        return suppressed.type == type && suppressed.ids.contains(id)
    }

    func suppress(_ type: String, _ ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        suppressed = ids.isEmpty ? nil : (type, ids)
    }

    /// Edits taken but not written: back, unless a newer one for the same item came meanwhile.
    func restore(_ type: String, _ intents: [String: Intent]) {
        lock.lock()
        defer { lock.unlock() }
        for (id, intent) in intents where byType[type]?[id] == nil { byType[type, default: [:]][id] = intent }
    }

    func takeAll() -> [String: [String: Intent]] {
        lock.lock()
        defer { lock.unlock() }
        let taken = byType
        byType = [:]
        return taken
    }

    func pendingIDs(_ type: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return byType[type].map { Set($0.keys) } ?? []
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return byType.isEmpty
    }
}
