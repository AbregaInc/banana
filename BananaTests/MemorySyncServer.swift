import Foundation

/// The service's side of `/v2/sync` and the blob routes (docs/design/DATA-PLATFORM.md §4), in
/// memory, for engine tests: the catalog checks, the Health consent, hub-only writers, the blob
/// index, clamping, one merge (`RecordMerge`, as `space.js` does it), `seq`, and paging by count.
final class MemorySyncServer: @unchecked Sendable {
    struct Stored { var state: RecordState; var seq: Int64 }

    private let lock = NSLock()
    let catalog: DataCatalog
    private(set) var records: [RecordKey: Stored] = [:]
    private(set) var seq: Int64 = 0
    private(set) var blobs: [String: Data] = [:]
    private(set) var requests: [SyncRequest] = []
    private(set) var blobPuts: [String] = []
    var syncStates: [String: (seededAt: Date?, flippedAt: Date?, seeded: [String]?)] = [:]

    var consent = true
    var hubDevices: Set<String> = []
    /// This life of the space; new at every wipe.
    private(set) var epoch = UUID().uuidString
    var pageSize = 1000
    /// The service's clock, in ms.
    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Devices that can't reach the service.
    var offline: Set<String> = []
    /// Blobs whose upload fails, as the network does.
    var failingPuts: Set<String> = []
    /// Blobs whose upload the service refuses with this status, for good.
    var refusingPuts: [String: Int] = [:]
    /// Blobs whose download fails.
    var failingGets: Set<String> = []
    /// Requests with more changes than this are refused as too large (413).
    var tooLargeAbove: Int?
    /// Types refused with a reason, as the service would for a rule this stand-in doesn't model.
    var refuse: [String: String] = [:]
    /// Awaited with each request before the service handles it: a test edits a store mid-flight.
    var beforeSync: (@Sendable (SyncRequest) async -> Void)?
    /// Answers lost after the request was applied, per device.
    var dropAnswers: [String: Int] = [:]

    init(catalog: DataCatalog) { self.catalog = catalog }

    func with<T>(_ body: (MemorySyncServer) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(self)
    }

    /// The visible records, as a store would hold them: fields without `null`s.
    func visible(type: String) -> [String: [String: JSONValue]] {
        with { server in
            var out: [String: [String: JSONValue]] = [:]
            for (key, stored) in server.records where key.type == type && stored.state.isVisible {
                out[key.id] = stored.state.fields.filter { !$0.value.isNull }
            }
            return out
        }
    }

    func record(_ type: String, _ id: String) -> RecordState? {
        with { $0.records[RecordKey(type: type, id: id)]?.state }
    }

    struct Offline: Error {}
    struct AnswerLost: Error {}

    /// A change made by some other device, straight into the space.
    func inject(_ type: String, _ id: String, set: [String: JSONValue], clock: String, delete: String? = nil) {
        with { server in
            let key = RecordKey(type: type, id: id)
            let (state, changed) = RecordMerge.apply(RecordChange(set: set, clocks: set.mapValues { _ in clock }, delete: delete),
                                                     to: server.records[key]?.state, kind: server.catalog[type]?.merge ?? .field)
            if changed {
                server.seq += 1
                server.records[key] = Stored(state: state, seq: server.seq)
            }
        }
    }

    /// Started over, as after an account's space was wiped: a new epoch, nothing in it.
    func wipe() {
        with { server in
            server.records = [:]
            server.seq = 0
            server.blobs = [:]
            server.epoch = UUID().uuidString
        }
    }

    /// Back to an earlier point, as a point-in-time restore: what changed after `seq` is gone.
    func restore(toSeq point: Int64) {
        with { server in
            server.records = server.records.filter { $0.value.seq <= point }
            server.seq = point
        }
    }

    /// The blob index lost a blob the device thinks is there (`blob_missing` next time).
    func forgetBlob(_ sha: String) { with { _ = $0.blobs.removeValue(forKey: sha) } }

    /// `platform`: the device row's platform, as the service reads it (nil: by `hubDevices`).
    /// `pageRecords`: the page size for this request (nil: `pageSize`).
    func handle(_ request: SyncRequest, platform: String? = nil, pageRecords: Int? = nil) throws -> SyncAnswer {
        lock.lock()
        defer { lock.unlock() }
        guard !offline.contains(request.device) else { throw Offline() }
        requests.append(request)
        let nowMs = now()
        let ceiling = nowMs + 5 * 60 * 1000
        var applied: [SyncAnswer.Applied] = [], rejected: [SyncAnswer.Rejected] = []
        for change in request.changes {
            let key = RecordKey(type: change.type, id: change.id)
            func refuse(_ reason: String) { rejected.append(.init(type: change.type, id: change.id, reason: reason)) }
            guard let entry = catalog[change.type] else { refuse("unknown_type"); continue }
            if let reason = self.refuse[change.type] { refuse(reason); continue }
            // In the service's order (Service/src/space.js): the record's checks, then its clocks,
            // then its blobs.
            let isHub = platform.map { $0 == "iphone" } ?? hubDevices.contains(request.device)
            if entry.writers == .hub && !isHub { refuse("hub_only"); continue }
            if entry.isHealth && !consent { refuse("consent"); continue }
            // A clock more than five minutes ahead is refused, never brought down (the device
            // stamps it again).
            let clocks = change.clocks
            let fast = (Array(clocks.values) + [change.delete].compactMap { $0 }).contains { (HLC($0)?.ms ?? 0) > ceiling }
            if fast { refuse("clock"); continue }
            let missing = change.set.contains { field, value in
                entry.blobFields[field] != nil && value.blobReference.map { blobs[$0.sha256] == nil } == true
            }
            if missing { refuse("blob_missing"); continue }
            let (state, changed) = RecordMerge.apply(RecordChange(set: change.set, clocks: clocks, delete: change.delete),
                                                     to: records[key]?.state, kind: entry.merge)
            if CanonicalJSON.string(state.fields).utf8.count > 256 * 1024 { refuse("too_large"); continue }
            if changed {
                seq += 1
                records[key] = Stored(state: state, seq: seq)
            }
            applied.append(.init(type: change.type, id: change.id, clocks: state.clocks, deleted: state.deleted))
        }
        // A cursor past the head means the space was started over: read it from the start.
        let from = request.since >= 0 && request.since <= seq ? request.since : 0
        let after = records.filter { $0.value.seq > from }.sorted { $0.value.seq < $1.value.seq }
        let page = after.prefix(pageRecords ?? pageSize)
        let changes = page.map { key, stored in
            SyncAnswer.Record(type: key.type, id: key.id, fields: stored.state.fields, clocks: stored.state.clocks,
                              deleted: stored.state.deleted, seq: stored.seq)
        }
        if let left = dropAnswers[request.device], left > 0 {
            dropAnswers[request.device] = left - 1
            throw AnswerLost()
        }
        return SyncAnswer(now: nowMs, epoch: epoch, head: seq, next: page.last?.value.seq ?? from, more: after.count > page.count,
                          applied: applied, changes: changes, rejected: rejected,
                          consents: .init(health: consent))
    }

    func put(_ sha: String, _ data: Data, device: String) throws {
        try with { server in
            guard !server.offline.contains(device), !server.failingPuts.contains(sha) else { throw Offline() }
            server.blobs[sha] = data
            server.blobPuts.append(sha)
        }
    }

    func blob(_ sha: String, device: String) throws -> Data {
        try with { server in
            guard !server.offline.contains(device), let data = server.blobs[sha] else { throw Offline() }
            return data
        }
    }

    func set(_ body: (MemorySyncServer) -> Void) { with(body) }
}

/// One device's connection to a `MemorySyncServer`.
struct MemoryTransport: SyncTransport {
    let server: MemorySyncServer
    let device: String

    func sync(_ request: SyncRequest) async throws -> SyncAnswer {
        // Through the wire format, as the real one goes.
        let body = try request.body()
        let decoded = try JSONDecoder().decode(WireRequest.self, from: body)
        if let hook = server.with({ $0.beforeSync }) { await hook(decoded.request) }
        if let most = server.with({ $0.tooLargeAbove }), decoded.request.changes.count > most {
            throw SyncTransportError.status(413, "too_large")
        }
        let answer = try server.handle(decoded.request)
        return try JSONDecoder().decode(SyncAnswer.self, from: JSONEncoder().encode(EncodableAnswer(answer)))
    }

    func putBlob(sha256: String, file: URL, type: String) async throws {
        if server.catalog[type]?.isHealth == true, !server.with({ $0.consent }) {
            throw SyncTransportError.status(403, "consent")
        }
        if let status = server.with({ $0.refusingPuts[sha256] }) { throw SyncTransportError.status(status, "bad_request") }
        try server.put(sha256, try Data(contentsOf: file), device: device)
    }

    func getBlob(sha256: String) async throws -> URL {
        if server.with({ $0.failingGets.contains(sha256) }) { throw MemorySyncServer.Offline() }
        let data = try server.blob(sha256, device: device)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("memblob-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    func hasBlob(sha256: String) async throws -> Bool { server.with { $0.blobs[sha256] != nil } }

    func reportSyncState(device: String, seededAt: Date?, flippedAt: Date?, seeded: [String]?) async throws {
        server.with { $0.syncStates[device] = (seededAt, flippedAt, seeded) }
    }
}

/// The request as the service reads it off the wire.
private struct WireRequest: Decodable {
    struct Change: Decodable {
        var type: String, id: String, set: [String: JSONValue], clocks: [String: String], delete: String?, schema: Int
    }
    var space: String?
    var device: String
    var since: Int64
    var changes: [Change]

    var request: SyncRequest {
        SyncRequest(space: space, device: device, since: since, changes: changes.map {
            SyncRequest.Change(type: $0.type, id: $0.id, set: $0.set, clocks: $0.clocks, delete: $0.delete, schema: $0.schema)
        })
    }
}

/// The answer as the service writes it.
private struct EncodableAnswer: Encodable {
    let answer: SyncAnswer
    init(_ answer: SyncAnswer) { self.answer = answer }

    // No `clamped`: the service refuses fast clocks now, and the engine mustn't depend on it.
    private enum Keys: String, CodingKey { case now, epoch, head, next, more, applied, changes, rejected, consents }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(answer.now, forKey: .now)
        try c.encodeIfPresent(answer.epoch, forKey: .epoch)
        try c.encodeIfPresent(answer.head, forKey: .head)
        try c.encodeIfPresent(answer.next, forKey: .next)
        try c.encode(answer.more, forKey: .more)
        try c.encode(answer.applied, forKey: .applied)
        try c.encode(answer.changes, forKey: .changes)
        try c.encode(answer.rejected, forKey: .rejected)
        try c.encodeIfPresent(answer.consents, forKey: .consents)
    }
}
