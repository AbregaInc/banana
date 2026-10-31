import CryptoKit
import Foundation

/// What the health and food adapters (Stage C, docs/design/DATA-PLATFORM.md §3, §6) share: where
/// they send what they notice themselves, file blobs hashed off the main actor, `whole` items, and
/// one adapter for every store that already syncs through `CloudControlSource`.
enum HealthFood {
    /// Every type `SyncAdapters.healthAndFood` covers, one adapter each: the catalog's health and
    /// food types (`HealthFoodAdapterTests` checks them against `Shared/DataCatalog.json`).
    static let types = [
        "food.meal", "food.supplement", "food.dose",
        "health.workoutPlan", "health.workoutCompletion", "food.correction",
        "food.myFood", "food.mealInbox", "food.mealPhoto", "food.mealPhotoFound",
        "food.searchPick", "food.estimatorStatus", "food.photoScanReport",
        "health.snapshot", "health.workout", "health.removalRequest", "health.workoutRevert",
    ]

    /// Where an adapter reports what it notices itself (a debounced Health snapshot, a request
    /// carried out): `MoveOver`, as the stores do, so a legacy arrival is told from this device's
    /// edit. Tests point it at an engine.
    struct Reports {
        var changed: @MainActor (_ type: String, _ ids: [String]) -> Void
        var deleted: @MainActor (_ type: String, _ ids: [String]) -> Void
        var offered: @MainActor (_ type: String, _ ids: [String]) -> Void

        @MainActor static let moveOver = Reports(
            changed: { MoveOver.changed(type: $0, ids: $1) },
            deleted: { MoveOver.deleted(type: $0, ids: $1) },
            offered: { MoveOver.offered(type: $0, ids: $1) })

        /// Straight to an engine (tests).
        static func engine(_ engine: SpaceSync) -> Reports {
            Reports(changed: { engine.changed(type: $0, ids: $1) },
                    deleted: { engine.deleted(type: $0, ids: $1) },
                    offered: { engine.offered(type: $0, ids: $1) })
        }
    }

    /// What an adapter may ask of the engine it belongs to: a lazy blob fetched now, and the
    /// records a store couldn't take yet offered again. `SyncAdapters` points these at the running
    /// engine; tests at theirs.
    struct EngineHooks: Sendable {
        var ensureBlob: @Sendable (_ type: String, _ id: String, _ field: String) async -> Bool
        var replay: @Sendable (_ types: [String]) async -> Void

        static let none = EngineHooks(ensureBlob: { _, _, _ in false }, replay: { _ in })

        static func engine(_ engine: SpaceSync) -> EngineHooks {
            EngineHooks(ensureBlob: { await engine.ensureBlob(type: $0, id: $1, field: $2) },
                        replay: { await engine.replay(types: $0) })
        }
    }

    /// A record's fields as a store's item, the way the canonical encoding wrote them (dates in
    /// ms, `null` as nil). Nil when they don't make one: such a record is dropped, as the legacy
    /// syncs drop an item that won't decode.
    static func decode<T: Decodable>(_ type: T.Type, _ fields: [String: JSONValue]) -> T? {
        try? CanonicalJSON.decode(type, from: fields)
    }

    /// Without cleared (`null`) fields: for a record kept one per key whose values aren't optional.
    static func present(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        fields.filter { !$0.value.isNull }
    }

    /// The `v` of a `whole` record (§3).
    static func whole<T: Decodable>(_ type: T.Type, _ fields: [String: JSONValue]) -> T? {
        guard let v = fields["v"], !v.isNull else { return nil }
        return try? CanonicalJSON.decode(type, from: v)
    }

    /// Own times at or before 1970 are "unedited" markers (`ControlEnvelope.unedited`): no own time.
    static func ownTime(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    /// The service takes ids of at most 200 characters (`Service/src/space.js`).
    static let longestID = 200

    /// A folder for the data platform's own copies of health data (a packed snapshot, a recording
    /// on its way in), left out of device backups as the mirror is (§6).
    static func makeUnbackedDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(values)
    }

    /// A `whole` record's one field (§3, "Kinds of merge").
    struct Whole<V: Encodable & Sendable>: Encodable, Sendable {
        let v: V
    }

    // MARK: - Blobs

    /// The SHA-256 of files that become blobs, worked out off the main actor and kept by size and
    /// modification time, so a 20 MB workout recording is read once, not at every encoding.
    /// Thread-safe: encodings run on the engine's actor.
    final class BlobHashes: @unchecked Sendable {
        private struct Entry: Codable { var size: Int64; var modified: Double; var sha: String }

        private let lock = NSLock()
        private let file: URL?
        private var entries: [String: Entry]
        private var unsaved = 0

        init(file: URL?) {
            self.file = file
            entries = file.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        }

        /// The app's, in Application Support (worked out again when lost).
        static let shared = BlobHashes(file: AppSupport.directory.appendingPathComponent("sync-blob-hashes.json"))

        /// The blob reference of a file as it is now, or nil when it isn't there.
        func reference(of url: URL, ext: String?) -> BlobReference? {
            let path = url.standardizedFileURL.path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = Self.key(path)
            lock.lock()
            let known = entries[key]
            lock.unlock()
            if let known, known.size == size, known.modified == modified {
                return BlobReference(sha256: known.sha, size: size, ext: ext)
            }
            guard let sha = Self.sha256(of: url) else { return nil }
            lock.lock()
            entries[key] = Entry(size: size, modified: modified, sha: sha)
            unsaved += 1
            lock.unlock()
            save(force: false)
            return BlobReference(sha256: sha, size: size, ext: ext)
        }

        /// The reference already worked out for the file as it is now; nil when it would have to be
        /// read (for the main actor, which never hashes a file).
        func cachedReference(of url: URL, ext: String?) -> BlobReference? {
            let path = url.standardizedFileURL.path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            lock.lock()
            defer { lock.unlock() }
            guard let known = entries[Self.key(path)], known.size == size, known.modified == modified else { return nil }
            return BlobReference(sha256: known.sha, size: size, ext: ext)
        }

        /// Written every few new hashes (a first seed hashes hundreds), and when asked.
        func save(force: Bool = true) {
            lock.lock()
            guard let file, unsaved > 0, force || unsaved >= 16 else { lock.unlock(); return }
            unsaved = 0
            let snapshot = entries
            lock.unlock()
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }

        /// The path below Application Support when it's there: the container's own path can
        /// change across updates on iOS.
        private static func key(_ path: String) -> String {
            let base = AppSupport.directory.standardizedFileURL.path
            return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        }

        /// Read a megabyte at a time.
        static func sha256(of url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            do {
                // nil or empty at the end.
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            } catch {
                return nil
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        static func sha256(of data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// A file field (§3, "Blobs"): encoded as its blob reference, worked out when the engine
    /// encodes it, off the main actor. With no file here it encodes as the reference last known
    /// for it (`known`), so a device that never fetched a lazy blob never clears it for everyone;
    /// with neither, as `null`.
    struct FileBlob: Encodable, Sendable {
        let url: URL?
        let ext: String?
        var known: BlobReference?
        var hashes: BlobHashes = .shared

        var reference: BlobReference? {
            url.flatMap { hashes.reference(of: $0, ext: ext) } ?? known
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let reference { try container.encode(reference.value) } else { try container.encodeNil() }
        }
    }

    // MARK: - Stores that sync through `CloudControlSource`

    /// A `CloudControlSource` that takes a batch of another device's items in one save and one
    /// publish (the first pull can bring hundreds).
    @MainActor protocol BatchSource: CloudControlSource {
        /// Each item as `applyCloud` takes it (nil: deleted there); what each `applyCloud` says.
        func applyCloudBatch(_ kind: ControlKind, _ items: [(id: String, item: Data?)]) -> [String: Bool]
    }

    /// The stores that sync item by item through `CloudControlsSync` today (workout plans and
    /// completions, food corrections, your foods, the meal backlog, photos already found): their
    /// own `cloudItems` and `applyCloud` are the seam, so taking another device's copy goes
    /// through the same path it always has. Items travel as the store's Codable type, canonically
    /// encoded.
    @MainActor
    final class ControlSourceAdapter: RecordAdapter {
        struct Kind {
            var type: String
            var kind: ControlKind
            /// An item as `cloudItems` hands it over, as what the record holds, with its own time.
            var item: (Data) -> (value: any Encodable & Sendable, own: Date?)?
            /// A record's fields as `applyCloud` takes them; nil when they don't make an item.
            var data: ([String: JSONValue]) -> Data?

            /// A Codable item as it is: the record's fields are its keys.
            static func codable<T: Codable & Sendable>(_ t: T.Type, type: String, kind: ControlKind,
                                                       own: @escaping (T) -> Date? = { _ in nil }) -> Kind {
                Kind(type: type, kind: kind,
                     item: { data in (try? JSONDecoder().decode(T.self, from: data)).map { ($0, own($0)) } },
                     data: { fields in HealthFood.decode(T.self, fields).flatMap { try? JSONEncoder().encode($0) } })
            }
        }

        let source: any CloudControlSource
        private let kinds: [String: Kind]
        /// When the legacy sync last saw an item edited (§3 seeding rule 3); nil when unknown.
        private let editedAt: (ControlKind, String) -> Date?
        private var ownTimes: [String: [String: Date]] = [:]

        init(source: any CloudControlSource, kinds: [Kind],
             editedAt: @escaping (ControlKind, String) -> Date? = { _, _ in nil }) {
            self.source = source
            self.kinds = Dictionary(kinds.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
            self.editedAt = editedAt
        }

        var types: [String] { kinds.keys.sorted() }

        func snapshot(_ type: String) -> [String: any Encodable & Sendable] {
            guard let kind = kinds[type] else { return [:] }
            var items: [String: any Encodable & Sendable] = [:]
            var own: [String: Date] = [:]
            for (id, data) in source.cloudItems(kind.kind) where !id.isEmpty && id.count <= HealthFood.longestID {
                guard let item = kind.item(data) else { continue }
                items[id] = item.value
                if let date = HealthFood.ownTime(item.own) { own[id] = date }
            }
            ownTimes[type] = own
            return items
        }

        /// The few that changed, one at a time (`cloudItem`), never the whole store.
        func items(_ type: String, ids: Set<String>) -> [String: any Encodable & Sendable] {
            guard let kind = kinds[type] else { return [:] }
            var items: [String: any Encodable & Sendable] = [:]
            for id in ids where !id.isEmpty && id.count <= HealthFood.longestID {
                guard let data = source.cloudItem(kind.kind, id: id), let item = kind.item(data) else { continue }
                items[id] = item.value
                if let date = HealthFood.ownTime(item.own) { ownTimes[type, default: [:]][id] = date }
            }
            return items
        }

        func seedClock(_ type: String, id: String) -> Date? {
            guard let kind = kinds[type] else { return nil }
            return HealthFood.ownTime(editedAt(kind.kind, id)) ?? ownTimes[type]?[id]
        }

        /// Items are whole stored values, one record per id: a `default`-seeded kind (photos already
        /// found) has no default item (§3 seeding rule 5).
        func defaultEncoding(_ type: String) -> [String: JSONValue]? { nil }

        func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
            guard let kind = kinds[type] else { return [:] }
            var results: [String: Bool] = [:]
            var batch: [(id: String, item: Data?)] = []
            for record in records {
                guard let data = kind.data(record.fields) else {
                    results[record.id] = true   // malformed: dropped, as the legacy sync drops it
                    continue
                }
                batch.append((record.id, data))
            }
            results.merge(applyBatch(kind.kind, batch)) { _, new in new }
            return results
        }

        func remove(_ type: String, ids: [String]) {
            guard let kind = kinds[type], !ids.isEmpty else { return }
            _ = applyBatch(kind.kind, ids.map { ($0, nil) })
        }

        private func applyBatch(_ kind: ControlKind, _ batch: [(id: String, item: Data?)]) -> [String: Bool] {
            guard !batch.isEmpty else { return [:] }
            if let batched = source as? any BatchSource { return batched.applyCloudBatch(kind, batch) }
            var results: [String: Bool] = [:]
            for entry in batch { results[entry.id] = source.applyCloud(kind, id: entry.id, item: entry.item) }
            return results
        }

        func blobFile(_ type: String, id: String, field: String) -> URL? { nil }
        func storeBlob(_ type: String, id: String, field: String, file: URL) {}
    }

    // MARK: - Dictionaries kept one record per key

    /// A store that is one dictionary: search picks (query → food → count), each device's
    /// estimator status and photo-scan report (install id → value). One record per key.
    @MainActor protocol KeyedValues: AnyObject {
        associatedtype Value: Codable & Sendable
        var values: [String: Value] { get }
        /// Another device's values (nil: gone), in one save. Never reported back.
        func adopt(_ changes: [String: Value?])
    }

    /// The adapter for a `KeyedValues` store. `whole`: the value moves as one (`{v: value}`);
    /// otherwise the value is an object whose keys are the record's fields (a query's picks, food
    /// by food).
    @MainActor
    final class KeyedValuesAdapter<Port: KeyedValues>: RecordAdapter {
        let type: String
        let port: Port
        private let isWhole: Bool
        private let own: (Port.Value) -> Date?

        init(type: String, port: Port, whole: Bool, own: @escaping (Port.Value) -> Date? = { _ in nil }) {
            self.type = type
            self.port = port
            isWhole = whole
            self.own = own
        }

        var types: [String] { [type] }

        private func item(_ value: Port.Value) -> any Encodable & Sendable {
            isWhole ? HealthFood.Whole(v: value) : value
        }

        func snapshot(_ type: String) -> [String: any Encodable & Sendable] {
            guard type == self.type else { return [:] }
            var items: [String: any Encodable & Sendable] = [:]
            for (key, value) in port.values where !key.isEmpty && key.count <= HealthFood.longestID { items[key] = item(value) }
            return items
        }

        func items(_ type: String, ids: Set<String>) -> [String: any Encodable & Sendable] {
            guard type == self.type else { return [:] }
            let values = port.values
            var items: [String: any Encodable & Sendable] = [:]
            for id in ids { if let value = values[id] { items[id] = item(value) } }
            return items
        }

        func seedClock(_ type: String, id: String) -> Date? {
            port.values[id].flatMap(own).flatMap(HealthFood.ownTime)
        }

        /// One record per key, with no default item (§3 seeding rule 5).
        func defaultEncoding(_ type: String) -> [String: JSONValue]? { nil }

        func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
            var changes: [String: Port.Value?] = [:]
            for record in records {
                let value = isWhole ? HealthFood.whole(Port.Value.self, record.fields)
                                    : HealthFood.decode(Port.Value.self, HealthFood.present(record.fields))
                if let value { changes[record.id] = .some(value) }
            }
            if !changes.isEmpty { port.adopt(changes) }
            return Dictionary(records.map { ($0.id, true) }, uniquingKeysWith: { first, _ in first })
        }

        func remove(_ type: String, ids: [String]) {
            guard !ids.isEmpty else { return }
            port.adopt(Dictionary(ids.map { ($0, Port.Value?.none) }, uniquingKeysWith: { first, _ in first }))
        }

        func blobFile(_ type: String, id: String, field: String) -> URL? { nil }
        func storeBlob(_ type: String, id: String, field: String, file: URL) {}
    }
}
