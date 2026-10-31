import Foundation

/// A record's state (docs/design/DATA-PLATFORM.md §3): its fields, one clock per field, and the
/// delete register.
struct RecordState: Equatable, Sendable {
    var fields: [String: JSONValue] = [:]
    var clocks: [String: String] = [:]
    var deleted: String?

    /// Gone while the delete clock is higher than every field clock; a later edit brings it back.
    var isVisible: Bool {
        guard let deleted else { return true }
        return clocks.values.contains { $0 >= deleted }
    }
}

/// One change to a record: fields with their clocks, and perhaps a delete clock.
struct RecordChange: Equatable, Sendable {
    var set: [String: JSONValue] = [:]
    var clocks: [String: String] = [:]
    var delete: String?
}

/// The one merge rule, the same on the devices and the service (`Service/src/space.js`), checked
/// against the same cases (`Shared/SyncMergeFixtures.json`).
enum RecordMerge {
    enum Kind: String, Codable, Sendable { case field, whole, append }

    /// Whether `incoming` (at clock `c`) beats `current` (at clock `e`): the higher clock; on equal
    /// clocks the greater canonical value, `null` lowest.
    static func wins(_ incoming: JSONValue, at c: String, over current: JSONValue?, at e: String?) -> Bool {
        guard let e else { return true }
        if c != e { return c > e }
        guard let current else { return true }
        return CanonicalJSON.compare(incoming, current) > 0
    }

    /// `state` (nil: no record yet) with `change` merged in, and whether anything changed. A field
    /// without a clock in the change is ignored.
    static func apply(_ change: RecordChange, to state: RecordState?, kind: Kind) -> (state: RecordState, changed: Bool) {
        var next = state ?? RecordState()
        var changed = false
        let ignoreSets = kind == .append && !next.fields.isEmpty
        if !ignoreSets {
            for (key, value) in change.set {
                guard let clock = change.clocks[key] else { continue }
                guard wins(value, at: clock, over: next.fields[key], at: next.clocks[key]) else { continue }
                next.fields[key] = value
                next.clocks[key] = clock
                changed = true
            }
        }
        if let delete = change.delete, next.deleted.map({ delete > $0 }) ?? true {
            next.deleted = delete
            changed = true
        }
        return (next, changed)
    }

    /// Two states joined: what each side holds, field by field. Commutative and idempotent.
    static func join(_ a: RecordState?, _ b: RecordState, kind: Kind) -> (state: RecordState, changed: Bool) {
        apply(RecordChange(set: b.fields, clocks: b.clocks, delete: b.deleted), to: a, kind: kind)
    }
}

/// What changed in a record since the last encoding this app made of it (§3, "A local change").
enum FieldDiff {
    struct Result: Equatable, Sendable {
        /// Keys whose value is new, with the new value; a cleared key carries `null`.
        var fields: [String: JSONValue]
        /// The keys among `fields` that were present before and are absent now.
        var cleared: Set<String>
        var isEmpty: Bool { fields.isEmpty }
    }

    /// `previous` is the last encoding this app made of the record (nil: none yet); `current` is
    /// today's. Values compare as canonical text, so a re-encoded `Set` is no change. A key in
    /// neither, such as one a newer app wrote, is never touched.
    static func changes(from previous: [String: JSONValue]?, to current: [String: JSONValue]) -> Result {
        var fields: [String: JSONValue] = [:]
        var cleared = Set<String>()
        for (key, value) in current {
            if let before = previous?[key], CanonicalJSON.string(before) == CanonicalJSON.string(value) { continue }
            fields[key] = value
        }
        for (key, before) in previous ?? [:] where current[key] == nil && !before.isNull {
            fields[key] = .null
            cleared.insert(key)
        }
        return Result(fields: fields, cleared: cleared)
    }
}
