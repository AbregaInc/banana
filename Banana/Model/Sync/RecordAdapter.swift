import Foundation

/// One area's stores, as the sync engine sees them (docs/design/DATA-PLATFORM.md §6). An adapter
/// wraps a store's existing seams; nothing in it is written per field: the store's items encode
/// through `CanonicalJSON`, and their top-level keys are the record's fields.
///
/// The contract:
/// - Items encode the same every time for the same value (sets and dictionaries are taken care
///   of). A number that isn't finite (NaN, infinity) is sent as `null`, logged with its type and
///   id, and comes back as nil: keep such values out of synced fields.
/// - `apply` and `remove` change the store through its usual mutators; what those report back to
///   the engine while they run is the engine's own echo and is ignored.
/// - A record that can't be taken yet (`apply` says false) waits, and is offered again on
///   `SpaceSync.replay(types:)`, when a type its catalog entry lists in `after` arrives, and once
///   after the adapter registers.
@MainActor protocol RecordAdapter: AnyObject {
    var types: [String] { get }
    /// Every local item of a type, taken once on the main actor; encoded and diffed off it.
    func snapshot(_ type: String) -> [String: any Encodable & Sendable]
    func seedClock(_ type: String, id: String) -> Date?          // nil: no own time (§3 seeding)
    /// false: can't take it yet (its parent isn't here); the mirror keeps it for replay.
    func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool]
    func remove(_ type: String, ids: [String])
    func blobFile(_ type: String, id: String, field: String) -> URL?
    /// The file with exactly these bytes (`sha` is the field's reference), or nil when the store no
    /// longer has them. By default, `blobFile(_:id:field:)`, for stores that keep one file per field.
    func blobFile(_ type: String, id: String, field: String, sha: String) -> URL?
    func storeBlob(_ type: String, id: String, field: String, file: URL)

    /// The compiled default of a `default`-seeded type (§3 seeding rule 5): only fields that
    /// differ from it are seeded. Nil: there is no default item (a dictionary kept one record per
    /// key), so every field differs.
    func defaultEncoding(_ type: String) -> [String: JSONValue]?
    /// The counter of an item's seed clock (§3 seeding rule 7): podcast progress seeds a completed
    /// copy at 1 and a position-only copy at 0, today's tie rule written into the clock. 0 by default.
    func seedRank(_ type: String, id: String) -> Int
    /// Some items of a type, for a store that can hand over a few without encoding everything.
    /// By default, the matching part of `snapshot`.
    func items(_ type: String, ids: Set<String>) -> [String: any Encodable & Sendable]
    /// The service refused a record for good (too large, malformed, …): it stays here and isn't
    /// sent again until the store reports it changed. For the store to note, if it wants to.
    func refused(type: String, id: String, reason: String)
    /// Records the last `apply` took (true) although the store kept its own copy, which beats
    /// them by the store's own rule: podcast progress stamped later, a transcript of a higher
    /// quality. Their store copy goes up as this device's edit, so every device settles on it.
    /// Asked once right after each `apply`, and cleared by asking. Empty by default.
    func keptOwn(_ type: String) -> Set<String>
    /// A pass pulled everything the service had, with this type seeded: what the space holds of it
    /// has been offered to the store. For a store that waits to send something until it knows
    /// what is already there (the booking type's default). Nothing by default.
    func pullCompleted(_ type: String)
}

extension RecordAdapter {
    func blobFile(_ type: String, id: String, field: String, sha: String) -> URL? { blobFile(type, id: id, field: field) }
    func defaultEncoding(_ type: String) -> [String: JSONValue]? { nil }
    func keptOwn(_ type: String) -> Set<String> { [] }
    func seedRank(_ type: String, id: String) -> Int { 0 }
    func items(_ type: String, ids: Set<String>) -> [String: any Encodable & Sendable] {
        snapshot(type).filter { ids.contains($0.key) }
    }
    func refused(type: String, id: String, reason: String) {}
    func pullCompleted(_ type: String) {}
}
