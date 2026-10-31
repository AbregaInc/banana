import Foundation
import GRDB

/// A record and its type, as one key.
struct RecordKey: Hashable, Sendable, Comparable {
    var type: String
    var id: String

    static func < (lhs: RecordKey, rhs: RecordKey) -> Bool { (lhs.type, lhs.id) < (rhs.type, rhs.id) }
}

/// The device's copy of the space (docs/design/DATA-PLATFORM.md §6): every record with its clocks,
/// what waits to go up, and the engine's state. One SQLite file per signed-in account,
/// `sync/<account>.sqlite` in Application Support, made on first use and left out of backups.
///
/// The mirror never prunes: a store's caps drop items from the store only, so a later edit
/// elsewhere is never mistaken for a re-creation.
final class RecordMirror: Sendable {
    let queue: DatabaseQueue

    /// Whether a record waits to be handed to its store.
    enum Waiting: Int, Sendable {
        case no = 0
        /// The store couldn't take it yet (its parent isn't there): offered again only on a replay.
        case refused = 1
        /// To hand over at the next pass: edited here when it arrived, a write of this device's
        /// lost to something newer, or its type wasn't seeded yet.
        case redeliver = 2
    }

    /// A record as the mirror keeps it: its merged state (everything known, from the service and
    /// from this device), its change number, the last encoding this app made of it, and whether
    /// it waits to be handed to its store again.
    struct Stored: Equatable, Sendable {
        var key: RecordKey
        var state: RecordState
        var seq: Int64?
        var localEncoding: [String: JSONValue]?
        var waiting: Waiting
    }

    /// A clock waiting to go up, with the offset this device's clock had when it was made (to
    /// stamp it again, §3: a fast clock moves back by what was learned since).
    struct PendingClock: Equatable, Sendable {
        var clock: String
        var offset: Int64
    }

    /// What waits to go up for one record: fields at their pending clocks, and perhaps a delete.
    struct Pending: Equatable, Sendable {
        var key: RecordKey
        var fields: [String: (clock: PendingClock, value: JSONValue)]
        var delete: PendingClock?

        static func == (lhs: Pending, rhs: Pending) -> Bool {
            lhs.key == rhs.key && lhs.delete == rhs.delete
                && lhs.fields.mapValues(\.clock) == rhs.fields.mapValues(\.clock)
                && lhs.fields.mapValues(\.value) == rhs.fields.mapValues(\.value)
        }
    }

    /// An eager blob to fetch, with its retries.
    struct WantedBlob: Equatable, Sendable {
        var key: RecordKey
        var field: String
        var sha: String
        var attempts: Int
    }

    /// The account's mirror file.
    static func url(account: String, in directory: URL = AppSupport.directory) -> URL {
        let safe = account.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("sync", isDirectory: true).appendingPathComponent("\(safe).sqlite")
    }

    /// Opens (or makes) the mirror at `url`, its folder excluded from backup.
    init(url: URL) throws {
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        queue = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(queue)
    }

    /// A mirror in memory, for tests.
    init() throws {
        queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE record (
                    type TEXT NOT NULL, id TEXT NOT NULL,
                    fields TEXT NOT NULL, clocks TEXT NOT NULL, deleted TEXT,
                    seq INTEGER, localEncoding TEXT, waitingReplay INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (type, id)) WITHOUT ROWID;
                CREATE INDEX record_waiting ON record (type) WHERE waitingReplay = 1;
                CREATE TABLE outgoing (
                    type TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL,
                    clock TEXT NOT NULL, value TEXT NOT NULL,
                    PRIMARY KEY (type, id, field)) WITHOUT ROWID;
                CREATE TABLE outgoingDelete (
                    type TEXT NOT NULL, id TEXT NOT NULL, clock TEXT NOT NULL,
                    PRIMARY KEY (type, id)) WITHOUT ROWID;
                CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE blob (sha TEXT PRIMARY KEY NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
                CREATE TABLE localBlob (
                    type TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, sha TEXT NOT NULL,
                    PRIMARY KEY (type, id, field)) WITHOUT ROWID;
                CREATE TABLE seedPending (
                    type TEXT NOT NULL, id TEXT NOT NULL, rejected INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (type, id)) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE outgoing ADD COLUMN issuedOffset INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE outgoingDelete ADD COLUMN issuedOffset INTEGER NOT NULL DEFAULT 0;
                DROP INDEX record_waiting;
                CREATE INDEX record_waiting ON record (type, waitingReplay) WHERE waitingReplay > 0;
                CREATE TABLE blobWanted (
                    type TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, sha TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, notBefore INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (type, id, field)) WITHOUT ROWID;
                CREATE TABLE refused (
                    type TEXT NOT NULL, id TEXT NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL,
                    PRIMARY KEY (type, id)) WITHOUT ROWID;
                CREATE TABLE blobRefused (
                    type TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, sha TEXT NOT NULL,
                    reason TEXT NOT NULL, at INTEGER NOT NULL,
                    PRIMARY KEY (type, id, field)) WITHOUT ROWID;
                """)
        }
        return migrator
    }

    func read<T>(_ body: (MirrorTransaction) throws -> T) throws -> T {
        try queue.read { try body(MirrorTransaction(db: $0)) }
    }

    /// One transaction: everything in `body` lands, or none of it.
    func write<T>(_ body: (MirrorTransaction) throws -> T) throws -> T {
        try queue.write { try body(MirrorTransaction(db: $0)) }
    }

    /// Closes the file, before it's deleted (an account forgotten). Nothing reads or writes after.
    func close() throws { try queue.close() }
}

/// The mirror's calls, inside one read or write.
struct MirrorTransaction {
    let db: Database

    private static func text(_ fields: [String: JSONValue]) -> String { CanonicalJSON.string(fields) }

    private static func clocksText(_ clocks: [String: String]) -> String {
        CanonicalJSON.string(.object(clocks.mapValues { .string($0) }))
    }

    private static func clocks(_ text: String) -> [String: String] {
        CanonicalJSON.parseFields(text).compactMapValues(\.stringValue)
    }

    // MARK: Meta

    func meta<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    func setMeta<T: Encodable>(_ key: String, _ value: T?) throws {
        guard let value else {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            return
        }
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, text])
    }

    // MARK: Records

    private func stored(_ row: Row) -> RecordMirror.Stored {
        let encoding: String? = row["localEncoding"]
        return RecordMirror.Stored(
            key: RecordKey(type: row["type"], id: row["id"]),
            state: RecordState(fields: CanonicalJSON.parseFields(row["fields"]), clocks: Self.clocks(row["clocks"]),
                               deleted: row["deleted"]),
            seq: row["seq"],
            localEncoding: encoding.map(CanonicalJSON.parseFields),
            waiting: RecordMirror.Waiting(rawValue: row["waitingReplay"]) ?? .no)
    }

    func record(_ key: RecordKey) throws -> RecordMirror.Stored? {
        try Row.fetchOne(db, sql: "SELECT * FROM record WHERE type = ? AND id = ?", arguments: [key.type, key.id]).map(stored)
    }

    func records(type: String) throws -> [RecordMirror.Stored] {
        try Row.fetchAll(db, sql: "SELECT * FROM record WHERE type = ? ORDER BY id", arguments: [type]).map(stored)
    }

    func records(type: String, ids: [String]) throws -> [RecordMirror.Stored] {
        var out: [RecordMirror.Stored] = []
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            out += try Row.fetchAll(db, sql: "SELECT * FROM record WHERE type = ? AND id IN (\(marks))",
                                    arguments: StatementArguments([type] + chunk)).map(stored)
        }
        return out
    }

    func ids(type: String) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT id FROM record WHERE type = ?", arguments: [type]))
    }

    func count(type: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record WHERE type = ?", arguments: [type]) ?? 0
    }

    /// Records of a type waiting to be handed to their store: all of them, or in one state.
    func waitingIDs(type: String, _ state: RecordMirror.Waiting? = nil) throws -> [String] {
        if let state {
            return try String.fetchAll(db, sql: "SELECT id FROM record WHERE type = ? AND waitingReplay = ? ORDER BY id",
                                       arguments: [type, state.rawValue])
        }
        return try String.fetchAll(db, sql: "SELECT id FROM record WHERE type = ? AND waitingReplay > 0 ORDER BY id", arguments: [type])
    }

    func allRecords() throws -> [RecordMirror.Stored] {
        try Row.fetchAll(db, sql: "SELECT * FROM record ORDER BY type, id").map(stored)
    }

    func save(_ record: RecordMirror.Stored) throws {
        try db.execute(sql: """
            INSERT INTO record (type, id, fields, clocks, deleted, seq, localEncoding, waitingReplay)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(type, id) DO UPDATE SET fields = excluded.fields, clocks = excluded.clocks,
                deleted = excluded.deleted, seq = excluded.seq, localEncoding = excluded.localEncoding,
                waitingReplay = excluded.waitingReplay
            """, arguments: [record.key.type, record.key.id, Self.text(record.state.fields), Self.clocksText(record.state.clocks),
                             record.state.deleted, record.seq, record.localEncoding.map(Self.text), record.waiting.rawValue])
    }

    func setWaiting(_ key: RecordKey, _ waiting: RecordMirror.Waiting) throws {
        try db.execute(sql: "UPDATE record SET waitingReplay = ? WHERE type = ? AND id = ?",
                       arguments: [waiting.rawValue, key.type, key.id])
    }

    func setLocalEncoding(_ key: RecordKey, _ encoding: [String: JSONValue]?) throws {
        try db.execute(sql: "UPDATE record SET localEncoding = ? WHERE type = ? AND id = ?",
                       arguments: [encoding.map(Self.text), key.type, key.id])
    }

    // MARK: Outgoing

    /// A field to send at `clock`, made while this device's offset was `offset`. Of two waiting
    /// for the same field, the later clock stays.
    func enqueue(_ key: RecordKey, fields: [String: JSONValue], clock: String, offset: Int64 = 0) throws {
        for (field, value) in fields {
            try db.execute(sql: """
                INSERT INTO outgoing (type, id, field, clock, value, issuedOffset) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(type, id, field) DO UPDATE SET clock = excluded.clock, value = excluded.value,
                    issuedOffset = excluded.issuedOffset
                WHERE excluded.clock > outgoing.clock
                """, arguments: [key.type, key.id, field, clock, CanonicalJSON.string(value), offset])
        }
    }

    func enqueueDelete(_ key: RecordKey, clock: String, offset: Int64 = 0) throws {
        try db.execute(sql: """
            INSERT INTO outgoingDelete (type, id, clock, issuedOffset) VALUES (?, ?, ?, ?)
            ON CONFLICT(type, id) DO UPDATE SET clock = excluded.clock, issuedOffset = excluded.issuedOffset
            WHERE excluded.clock > outgoingDelete.clock
            """, arguments: [key.type, key.id, clock, offset])
    }

    /// Every record with something waiting to go up.
    func pendingKeys() throws -> [RecordKey] {
        try Row.fetchAll(db, sql: """
            SELECT type, id FROM outgoing UNION SELECT type, id FROM outgoingDelete ORDER BY type, id
            """).map { RecordKey(type: $0["type"], id: $0["id"]) }
    }

    func pending(_ key: RecordKey) throws -> RecordMirror.Pending? {
        var fields: [String: (clock: RecordMirror.PendingClock, value: JSONValue)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT field, clock, value, issuedOffset FROM outgoing WHERE type = ? AND id = ?",
                                    arguments: [key.type, key.id]) {
            let value: String = row["value"]
            fields[row["field"]] = (RecordMirror.PendingClock(clock: row["clock"], offset: row["issuedOffset"]),
                                    (try? CanonicalJSON.parse(Data(value.utf8))) ?? .null)
        }
        let delete = try Row.fetchOne(db, sql: "SELECT clock, issuedOffset FROM outgoingDelete WHERE type = ? AND id = ?",
                                      arguments: [key.type, key.id])
            .map { RecordMirror.PendingClock(clock: $0["clock"], offset: $0["issuedOffset"]) }
        guard !fields.isEmpty || delete != nil else { return nil }
        return RecordMirror.Pending(key: key, fields: fields, delete: delete)
    }

    func pendingCount() throws -> Int { try pendingKeys().count }

    /// The answer's clocks for a record this device sent (§4, "Acknowledging"): a waiting field is
    /// done when the space holds its clock or a later one. An edit made while the request was out
    /// has a later clock than any the answer can hold for it, so it stays.
    func acknowledge(_ key: RecordKey, clocks: [String: String], deleted: String?) throws {
        for (field, clock) in clocks {
            try db.execute(sql: "DELETE FROM outgoing WHERE type = ? AND id = ? AND field = ? AND clock <= ?",
                           arguments: [key.type, key.id, field, clock])
        }
        if let deleted {
            try db.execute(sql: "DELETE FROM outgoingDelete WHERE type = ? AND id = ? AND clock <= ?",
                           arguments: [key.type, key.id, deleted])
        }
    }

    /// What waits for a record, its clocks moved by `move` (nil: keep it), each then made at
    /// `offset`: the service refused them as too far ahead. The mirror's own copy moves where it
    /// held the refused clock. True when anything moved.
    @discardableResult
    func restamp(_ key: RecordKey, offset: Int64, _ move: (RecordMirror.PendingClock) -> String?) throws -> Bool {
        guard let pending = try pending(key) else { return false }
        var stored = try record(key)
        var moved = false
        for (field, entry) in pending.fields {
            guard let clock = move(entry.clock) else { continue }
            moved = true
            try db.execute(sql: "UPDATE outgoing SET clock = ?, issuedOffset = ? WHERE type = ? AND id = ? AND field = ?",
                           arguments: [clock, offset, key.type, key.id, field])
            if stored?.state.clocks[field] == entry.clock.clock { stored?.state.clocks[field] = clock }
        }
        if let delete = pending.delete, let clock = move(delete) {
            moved = true
            try db.execute(sql: "UPDATE outgoingDelete SET clock = ?, issuedOffset = ? WHERE type = ? AND id = ?",
                           arguments: [clock, offset, key.type, key.id])
            if stored?.state.deleted == delete.clock { stored?.state.deleted = clock }
        }
        if moved, let stored { try save(stored) }
        return moved
    }

    func dropPending(_ key: RecordKey) throws {
        try db.execute(sql: "DELETE FROM outgoing WHERE type = ? AND id = ?", arguments: [key.type, key.id])
        try db.execute(sql: "DELETE FROM outgoingDelete WHERE type = ? AND id = ?", arguments: [key.type, key.id])
    }

    // MARK: Blobs

    func isUploaded(_ sha: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT uploaded FROM blob WHERE sha = ?", arguments: [sha]) == 1
    }

    func setUploaded(_ sha: String, _ uploaded: Bool) throws {
        try db.execute(sql: "INSERT INTO blob (sha, uploaded) VALUES (?, ?) ON CONFLICT(sha) DO UPDATE SET uploaded = excluded.uploaded",
                       arguments: [sha, uploaded ? 1 : 0])
    }

    /// The blob this device's store holds for a field, by hash.
    func localBlob(_ key: RecordKey, field: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT sha FROM localBlob WHERE type = ? AND id = ? AND field = ?",
                            arguments: [key.type, key.id, field])
    }

    func setLocalBlob(_ key: RecordKey, field: String, sha: String) throws {
        try db.execute(sql: """
            INSERT INTO localBlob (type, id, field, sha) VALUES (?, ?, ?, ?)
            ON CONFLICT(type, id, field) DO UPDATE SET sha = excluded.sha
            """, arguments: [key.type, key.id, field, sha])
    }

    // MARK: Seeds

    func addSeedPending(_ key: RecordKey) throws {
        try db.execute(sql: "INSERT INTO seedPending (type, id) VALUES (?, ?) ON CONFLICT DO NOTHING", arguments: [key.type, key.id])
    }

    /// The record came back in an answer: its seed is acknowledged, whatever happened before.
    func clearSeedPending(_ key: RecordKey) throws {
        try db.execute(sql: "DELETE FROM seedPending WHERE type = ? AND id = ?", arguments: [key.type, key.id])
    }

    func rejectSeed(_ key: RecordKey) throws {
        try db.execute(sql: "UPDATE seedPending SET rejected = 1 WHERE type = ? AND id = ?", arguments: [key.type, key.id])
    }

    /// Seeded records not yet acknowledged, and those the service refused.
    func seedCounts() throws -> (waiting: Int, rejected: Int) {
        let waiting = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seedPending WHERE rejected = 0") ?? 0
        let rejected = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seedPending WHERE rejected = 1") ?? 0
        return (waiting, rejected)
    }

    // MARK: Refusals

    /// The service refused a record for good: kept here with why, until the store reports it again.
    func refuse(_ key: RecordKey, reason: String, at: Int64) throws {
        try db.execute(sql: """
            INSERT INTO refused (type, id, reason, at) VALUES (?, ?, ?, ?)
            ON CONFLICT(type, id) DO UPDATE SET reason = excluded.reason, at = excluded.at
            """, arguments: [key.type, key.id, reason, at])
    }

    func isRefused(_ key: RecordKey) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM refused WHERE type = ? AND id = ?", arguments: [key.type, key.id]) != nil
    }

    func refusedCount() throws -> Int { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM refused") ?? 0 }

    /// The types with a seeded record the service refused for good.
    func refusedSeedTypes() throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT DISTINCT type FROM seedPending WHERE rejected = 1"))
    }

    /// A blob the service refused for good (a 4xx): its field waits until the store reports the
    /// record again.
    func refuseBlob(_ key: RecordKey, field: String, sha: String, reason: String, at: Int64) throws {
        try db.execute(sql: """
            INSERT INTO blobRefused (type, id, field, sha, reason, at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(type, id, field) DO UPDATE SET sha = excluded.sha, reason = excluded.reason, at = excluded.at
            """, arguments: [key.type, key.id, field, sha, reason, at])
    }

    func isBlobRefused(_ key: RecordKey, field: String, sha: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM blobRefused WHERE type = ? AND id = ? AND field = ? AND sha = ?",
                         arguments: [key.type, key.id, field, sha]) != nil
    }

    /// The store reported the record again: what was refused may be tried again.
    func clearRefusals(_ key: RecordKey) throws {
        try db.execute(sql: "DELETE FROM refused WHERE type = ? AND id = ?", arguments: [key.type, key.id])
        try db.execute(sql: "DELETE FROM blobRefused WHERE type = ? AND id = ?", arguments: [key.type, key.id])
    }

    // MARK: Blobs to fetch

    /// An eager blob to fetch; a new hash for the field starts its retries over.
    func want(_ key: RecordKey, field: String, sha: String) throws {
        try db.execute(sql: """
            INSERT INTO blobWanted (type, id, field, sha) VALUES (?, ?, ?, ?)
            ON CONFLICT(type, id, field) DO UPDATE SET sha = excluded.sha, attempts = 0, notBefore = 0
            WHERE excluded.sha <> blobWanted.sha
            """, arguments: [key.type, key.id, field, sha])
    }

    func dueBlobs(now: Int64, limit: Int) throws -> [RecordMirror.WantedBlob] {
        try Row.fetchAll(db, sql: "SELECT * FROM blobWanted WHERE notBefore <= ? ORDER BY notBefore, type, id LIMIT ?",
                         arguments: [now, limit]).map {
            RecordMirror.WantedBlob(key: RecordKey(type: $0["type"], id: $0["id"]), field: $0["field"], sha: $0["sha"],
                                    attempts: $0["attempts"])
        }
    }

    func nextBlobDue() throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT MIN(notBefore) FROM blobWanted")
    }

    func wantedCount() throws -> Int { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blobWanted") ?? 0 }

    func blobFetched(_ wanted: RecordMirror.WantedBlob) throws {
        try db.execute(sql: "DELETE FROM blobWanted WHERE type = ? AND id = ? AND field = ? AND sha = ?",
                       arguments: [wanted.key.type, wanted.key.id, wanted.field, wanted.sha])
    }

    func blobFailed(_ wanted: RecordMirror.WantedBlob, notBefore: Int64) throws {
        try db.execute(sql: "UPDATE blobWanted SET attempts = attempts + 1, notBefore = ? WHERE type = ? AND id = ? AND field = ? AND sha = ?",
                       arguments: [notBefore, wanted.key.type, wanted.key.id, wanted.field, wanted.sha])
    }

    // MARK: Whole types

    /// Everything of these types leaves the mirror: records, what waited to go up, seeds, blobs.
    /// For a withdrawn Health consent (§7); the stores keep their own copies.
    func drop(types: Set<String>) throws {
        for type in types {
            for table in ["record", "outgoing", "outgoingDelete", "localBlob", "seedPending", "blobWanted", "refused", "blobRefused"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE type = ?", arguments: [type])
            }
        }
    }

    /// The space was started over (a new epoch, §4): everything that came from it or waited to go
    /// to it goes. Meta (the clock) stays; the stores seed again.
    func clearForNewEpoch() throws {
        for table in ["record", "outgoing", "outgoingDelete", "seedPending", "localBlob", "blob", "blobWanted",
                      "refused", "blobRefused"] {
            try db.execute(sql: "DELETE FROM \(table)")
        }
    }

    func hasRecords(types: Set<String>) throws -> Bool {
        for type in types {
            if try count(type: type) > 0 { return true }
        }
        return try pendingKeys().contains { types.contains($0.type) }
    }
}
