import Foundation

/// The Controls zone's stores (`CloudControlSource`, DATA-INVENTORY.md "Zones Controls and Meals")
/// as adapter bindings, one per kind, all through the seam they already have: the store hands over
/// its items as the bytes it writes (`cloudItems`, `cloudItem`) and takes another device's version
/// through `applyCloud`, the same as from iCloud. Nothing here is per kind but the item's type.
///
/// - **Ids** are the stores' own (`ControlKind`, unhashed), as the legacy drain reports them.
/// - **Seed clocks** are each item's last edit as the Controls sync knows it (`editedAt`), the
///   time today's newer-edit rule compares; an item offered and never edited seeds at 0.
/// - **Fields**: the item's own keys, or the one field `v` for a value that isn't a struct.
/// - **Reports**: `ControlChangeReporter` already reaches every store's edit; `connectToCloud`
///   hands each to `MoveOver` too.
/// - **Phone-set kinds** (routine, alarm, wake) need nothing here: the engine seeds them on the
///   hub first, and a spoke drops its own once the phone's set arrives.
enum ControlsAdapter {
    /// A personal kind's catalog type (a listen's route is its listen's); nil for health and food.
    static func personalType(_ kind: ControlKind) -> String? {
        LegacyInventory.controlKinds[kind.rawValue].flatMap { LegacyInventory.isHealth($0) ? nil : $0 }
    }

    /// The type a store's own report of a personal item goes to `MoveOver` as; nil for health and
    /// food (`alsoReportHealthToSpace` has those), and while a legacy channel applies this very
    /// item, whose arrival `legacyApplied` reports, exactly once.
    @MainActor
    static func ownReport(_ kind: ControlKind, id: String) -> String? {
        guard let type = personalType(kind), !LegacyCloud.isApplyingFromCloud(type: type, id: id) else { return nil }
        return type
    }

    /// A Controls item an old build wrote, applied here after this device moved: a late arrival
    /// for the data platform, every kind (§3 seeding rule 6). A route's arrival is its listen's.
    @MainActor
    static func legacyApplied(_ kind: ControlKind, id: String, deleted: Bool) {
        guard let type = LegacyInventory.controlKinds[kind.rawValue] else { return }
        if deleted {
            guard kind != .listenRoute else { return }   // a route gone isn't its listen gone
            MoveOver.deleted(type: type, ids: [id])
        } else {
            MoveOver.changed(type: type, ids: [id])
        }
    }

    /// How one kind's bytes become a record and back.
    struct Codec: Sendable {
        /// The store's bytes (what `cloudItem` returns) as the record's fields.
        let fields: @Sendable (Data) throws -> JSONValue
        /// The record's fields as the bytes `applyCloud` takes.
        let data: @Sendable ([String: JSONValue]) throws -> Data

        /// A kind whose items are `T`, written by the store with a plain `JSONEncoder` (every
        /// Controls store does).
        static func model<T: Codable>(_ type: T.Type, shape: SyncShape = .fields) -> Codec {
            Codec(
                fields: { data in try shape.encode(try JSONDecoder().decode(T.self, from: data)) },
                data: { fields in try JSONEncoder().encode(try shape.decode(T.self, from: fields)) })
        }
    }

    /// A kind's binding. `editedAt`: the item's last edit as the Controls sync has it (nil: none).
    @MainActor
    static func binding(_ type: String, kind: ControlKind, source: CloudControlSource, codec: Codec,
                        editedAt: @escaping @MainActor (ControlKind, String) -> Date?) -> SyncBinding {
        weak var weakSource = source
        func prepared(_ data: Data) -> any Encodable & Sendable {
            PreparedItem { try codec.fields(data) }
        }
        func all() -> [String: Data] {
            guard let source = weakSource else { return [:] }
            let items = source.cloudItems(kind)
            if !items.isEmpty { return items }
            // A big store hands its items over one at a time.
            var one: [String: Data] = [:]
            for id in source.cloudItemIDs(kind) { one[id] = source.cloudItem(kind, id: id) }
            return one
        }
        var binding = SyncBinding(
            type: type,
            snapshot: { all().mapValues(prepared) },
            items: { ids in
                guard let source = weakSource else { return [:] }
                var found: [String: any Encodable & Sendable] = [:]
                for id in ids {
                    if let data = source.cloudItem(kind, id: id) { found[id] = prepared(data) }
                }
                return found
            },
            apply: { records in
                // What the store reports meanwhile isn't an edit for the Controls sync.
                ControlChangeReporter.fromSpace {
                    var results: [String: SyncApplied] = [:]
                    for record in records {
                        guard let source = weakSource else { results[record.id] = .notYet; continue }
                        // One a newer build wrote that this one can't read: left out, as from iCloud.
                        guard let data = try? codec.data(record.fields) else { results[record.id] = .taken; continue }
                        results[record.id] = source.applyCloud(kind, id: record.id, item: data) ? .taken : .notYet
                    }
                    return results
                }
            },
            remove: { ids in
                guard let source = weakSource else { return }
                // Not a delete for the Controls sync: no tombstone reaches iCloud (the account-
                // change clear, deletes from the space).
                ControlChangeReporter.fromSpace {
                    for id in ids { _ = source.applyCloud(kind, id: id, item: nil) }
                }
            })
        binding.seedClock = { editedAt(kind, $0) }
        return binding
    }
}
