import CryptoKit
import Foundation

/// What every Stage D adapter is built from (docs/design/DATA-PLATFORM.md §3, §6): one adapter
/// per area, made of one `Binding` per catalog type, each a few closures over a store's existing
/// seams. Nothing in here knows a store; `SyncAdapters+Other.swift` binds the real ones, and the
/// tests bind fakes and the stores they can compile.

/// A store's item as the engine sees it: its record's fields, worked out when the engine encodes
/// the item, which it does off the main actor (§3 seeding rule 8). Taking a snapshot only copies
/// values; decoding a store's bytes, the canonical encoding and hashing a blob file happen here.
struct PreparedItem: Encodable, Sendable {
    let make: @Sendable () throws -> JSONValue

    init(_ make: @escaping @Sendable () throws -> JSONValue) { self.make = make }

    /// An item already encoded.
    init(fields: [String: JSONValue]) { make = { .object(fields) } }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(try make())
    }
}

/// A value carried into a `@Sendable` encoding closure. Only for plain value types a store hands
/// over as a copy (its models don't all say `Sendable`); nothing shares them.
struct Carried<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// How a store's value becomes a record's fields, and back.
///
/// - `fields`: a struct's own top-level keys are the fields (§3, "Fields, worked out
///   generically"); each merges on its own.
/// - `wrapped`: the whole value is the one field `v`. For a value that isn't an object (a number,
///   a string enum), for one whose parts only make sense together (an enum with associated
///   values, `whole` types), and for one entry of a former key-value dictionary.
enum SyncShape: Sendable {
    case fields, wrapped

    static let wrappedKey = "v"

    func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let json = try CanonicalJSON.value(of: value)
        switch self {
        case .wrapped:
            return .object([Self.wrappedKey: json])
        case .fields:
            guard case .object = json else { throw CanonicalJSON.NotAnObject() }
            return json
        }
    }

    /// A record's fields as the store's value. `null` is a cleared field (§3): it reads as absent,
    /// so an optional comes back nil and a tolerant decoder uses its default.
    func decode<T: Decodable>(_ type: T.Type, from fields: [String: JSONValue]) throws -> T {
        switch self {
        case .wrapped:
            guard let value = fields[Self.wrappedKey], !value.isNull else { throw SyncShapeError.missingValue }
            return try CanonicalJSON.decode(type, from: value)
        case .fields:
            return try CanonicalJSON.decode(type, from: fields.filter { !$0.value.isNull })
        }
    }
}

enum SyncShapeError: Error { case missingValue, wrongID }

/// What a store did with one record it was handed (`RecordAdapter.apply`).
enum SyncApplied: Sendable, Equatable {
    /// In the store (or, for an item the store can't read, deliberately left out of it).
    case taken
    /// Can't be taken yet, its parent isn't here: the mirror keeps it for `replay`.
    case notYet
    /// The store kept its own copy, which beats this one by the store's rule: it goes up.
    case keptOwn
}

/// One catalog type of an area, as closures over its store.
@MainActor
struct SyncBinding {
    let type: String
    /// Every item, by the store's own id.
    var snapshot: @MainActor () -> [String: any Encodable & Sendable]
    /// Some items; nil: the matching part of `snapshot`.
    var items: (@MainActor (Set<String>) -> [String: any Encodable & Sendable])?
    var apply: @MainActor ([(id: String, fields: [String: JSONValue])]) -> [String: SyncApplied]
    /// Out of the store through its usual delete path, with no cascade.
    var remove: @MainActor ([String]) -> Void
    var seedClock: @MainActor (String) -> Date? = { _ in nil }
    var seedRank: @MainActor (String) -> Int = { _ in 0 }
    /// The compiled default of a `default`-seeded singleton (§3 seeding rule 5).
    var defaultEncoding: (@MainActor () -> [String: JSONValue]?)?
    var blobFile: @MainActor (_ id: String, _ field: String) -> URL? = { _, _ in nil }
    var storeBlob: @MainActor (_ id: String, _ field: String, _ file: URL) -> Void = { _, _, _ in }
    /// `RecordAdapter.pullCompleted`.
    var pullCompleted: @MainActor () -> Void = {}

    init(type: String,
         snapshot: @escaping @MainActor () -> [String: any Encodable & Sendable],
         items: (@MainActor (Set<String>) -> [String: any Encodable & Sendable])? = nil,
         apply: @escaping @MainActor ([(id: String, fields: [String: JSONValue])]) -> [String: SyncApplied],
         remove: @escaping @MainActor ([String]) -> Void) {
        self.type = type
        self.snapshot = snapshot
        self.items = items
        self.apply = apply
        self.remove = remove
    }
}

/// An area's adapter: its bindings, one per type.
@MainActor
final class BoundAdapter: RecordAdapter {
    let name: String
    private let bindings: [String: SyncBinding]
    let types: [String]
    private var kept: [String: Set<String>] = [:]

    init(_ name: String, _ bindings: [SyncBinding]) {
        self.name = name
        types = bindings.map(\.type)
        self.bindings = Dictionary(bindings.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func snapshot(_ type: String) -> [String: any Encodable & Sendable] { bindings[type]?.snapshot() ?? [:] }

    func items(_ type: String, ids: Set<String>) -> [String: any Encodable & Sendable] {
        guard let binding = bindings[type] else { return [:] }
        if let items = binding.items { return items(ids) }
        return binding.snapshot().filter { ids.contains($0.key) }
    }

    func seedClock(_ type: String, id: String) -> Date? { bindings[type]?.seedClock(id) }
    func seedRank(_ type: String, id: String) -> Int { bindings[type]?.seedRank(id) ?? 0 }
    func defaultEncoding(_ type: String) -> [String: JSONValue]? { bindings[type]?.defaultEncoding?() }

    func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
        guard let binding = bindings[type] else { return [:] }
        let results = binding.apply(records)
        let keptOwn = Set(results.filter { $0.value == .keptOwn }.keys)
        kept[type] = keptOwn.isEmpty ? nil : keptOwn
        return results.mapValues { $0 != .notYet }
    }

    func keptOwn(_ type: String) -> Set<String> { kept.removeValue(forKey: type) ?? [] }

    func pullCompleted(_ type: String) { bindings[type]?.pullCompleted() }

    func remove(_ type: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        bindings[type]?.remove(ids)
    }

    func blobFile(_ type: String, id: String, field: String) -> URL? { bindings[type]?.blobFile(id, field) }
    func storeBlob(_ type: String, id: String, field: String, file: URL) { bindings[type]?.storeBlob(id, field, file) }
}

// MARK: - Blobs

/// A file a field names (§3, "Blobs"): its hash, size and extension, read off the main actor.
/// Hashes are kept per path, size and modification date, so a route or a recording that hasn't
/// changed isn't read again each time its record is encoded.
enum BlobFiles {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: (size: Int64, modified: Date, sha: String)] = [:]

    static func reference(_ url: URL, ext: String? = nil) -> BlobReference? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, size > 0 else { return nil }
        let modified = values.contentModificationDate ?? .distantPast
        let path = url.standardizedFileURL.path
        lock.lock()
        let known = cache[path]
        lock.unlock()
        if let known, known.size == Int64(size), known.modified == modified {
            return BlobReference(sha256: known.sha, size: known.size, ext: ext ?? url.pathExtension.nilIfEmpty)
        }
        guard let sha = sha256(of: url) else { return nil }
        lock.lock()
        cache[path] = (Int64(size), modified, sha)
        lock.unlock()
        return BlobReference(sha256: sha, size: Int64(size), ext: ext ?? url.pathExtension.nilIfEmpty)
    }

    /// The file's SHA-256 in lower-case hex, read in pieces.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Common bindings

/// Record ids for the keys of a former key-value dictionary.
enum SyncKeys {
    /// The field a hashed record keeps its key in.
    static let keyField = "key"
    static let longest = 200

    /// A key as a record id: as it is when it's short and says nothing of anyone; otherwise
    /// (a title, a person's name, a long key) a stable hash, the key travelling in `keyField`.
    /// Nil for an empty key: there is nothing to keep.
    static func recordID(_ key: String, hashed: Bool) -> String? {
        guard !key.isEmpty else { return nil }
        guard hashed || key.count > longest else { return key }
        return "h:" + String(BlobFiles.sha256(of: Data(key.utf8)).prefix(40))
    }
}

extension SyncBinding {
    /// One record per key of a dictionary a store keeps whole, as its key-value dictionaries were
    /// (§3 seeding rule 5, `default`: no time per entry): each entry is its own record, so one
    /// device's write no longer erases another's entries. `set` takes the entries that arrived
    /// (nil: deleted) and keeps them the store's usual way.
    static func keyed<Value: Codable>(
        _ type: String, shape: SyncShape = .wrapped,
        hashKey: @escaping @Sendable (String) -> Bool = { _ in false },
        entries: @escaping @MainActor () -> [String: Value],
        set: @escaping @MainActor ([String: Value?]) -> Void,
        seedClock: (@MainActor (String) -> Date?)? = nil
    ) -> SyncBinding {
        // The key behind each record id, from the last entries handed over.
        var keys: [String: String] = [:]
        func current() -> [String: (key: String, value: Value)] {
            var byID: [String: (key: String, value: Value)] = [:]
            for (key, value) in entries() {
                guard let id = SyncKeys.recordID(key, hashed: hashKey(key)) else { continue }
                byID[id] = (key, value)
                keys[id] = key
            }
            return byID
        }
        var binding = SyncBinding(
            type: type,
            snapshot: {
                current().mapValues { entry -> any Encodable & Sendable in
                    let carried = Carried(entry.value)
                    let key = entry.key
                    let named = SyncKeys.recordID(key, hashed: hashKey(key)) != key
                    return PreparedItem {
                        guard named, case .object(var fields) = try shape.encode(carried.value) else {
                            return try shape.encode(carried.value)
                        }
                        fields[SyncKeys.keyField] = .string(key)
                        return .object(fields)
                    }
                }
            },
            apply: { records in
                var changes: [String: Value?] = [:]
                var results: [String: SyncApplied] = [:]
                for record in records {
                    results[record.id] = .taken
                    // A long or personal key travels in its own field; the record's id is its hash.
                    let key = record.fields[SyncKeys.keyField]?.stringValue ?? record.id
                    var fields = record.fields
                    fields[SyncKeys.keyField] = nil
                    // One a newer build wrote that this one can't read is left out.
                    guard !key.isEmpty, let value = try? shape.decode(Value.self, from: fields) else { continue }
                    changes[key] = .some(value)
                }
                if !changes.isEmpty { set(changes) }
                return results
            },
            remove: { ids in
                let here = current()
                let gone = ids.compactMap { here[$0]?.key }
                if !gone.isEmpty { set(Dictionary(gone.map { ($0, Value?.none) }, uniquingKeysWith: { first, _ in first })) }
            })
        if let seedClock {
            binding.seedClock = { id in keys[id].flatMap(seedClock) ?? seedClock(id) }
        }
        binding.defaultEncoding = { nil }   // nothing differs from "no entry": every entry seeds
        return binding
    }

    /// The one record of a store that is one value (settings, the hub's status), under `id`.
    static func single<Value: Codable>(
        _ type: String, id: String, shape: SyncShape,
        value: @escaping @MainActor () -> Value?,
        apply: @escaping @MainActor (_ value: Value, _ fields: [String: JSONValue]) -> SyncApplied,
        defaultValue: (@MainActor () -> Value)? = nil,
        seedClock: (@MainActor () -> Date?)? = nil
    ) -> SyncBinding {
        var binding = SyncBinding(
            type: type,
            snapshot: {
                guard let current = value() else { return [:] }
                let carried = Carried(current)
                return [id: PreparedItem { try shape.encode(carried.value) }]
            },
            apply: { records in
                var results: [String: SyncApplied] = [:]
                for record in records {
                    guard record.id == id, let decoded = try? shape.decode(Value.self, from: record.fields) else {
                        results[record.id] = .taken
                        continue
                    }
                    results[record.id] = apply(decoded, record.fields)
                }
                return results
            },
            remove: { _ in })   // a store that is one value is never deleted, only changed
        if let defaultValue {
            binding.defaultEncoding = {
                (try? shape.encode(defaultValue()))?.objectValue
            }
        }
        if let seedClock { binding.seedClock = { $0 == id ? seedClock() : nil } }
        return binding
    }
}
