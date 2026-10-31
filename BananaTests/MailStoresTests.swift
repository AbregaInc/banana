import XCTest
import GRDB
import CryptoKit

// MARK: - What the three store-facing test classes share

/// A latch for the test's side of a handshake with a closure running on a GRDB queue: one
/// opens it, one waits for it. Nothing here is a sleep. The wait has an upper bound only so that
/// a test that has gone wrong stops instead of hanging — and **a wait that reaches it fails the
/// test**, with the name of what it was waiting for: a hang must never read as a pass.
final class MailTestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let limit: TimeInterval
    private let name: String

    init(_ name: String = "a gate", limit: TimeInterval = 60) { self.name = name; self.limit = limit }

    func open() { semaphore.signal() }

    /// For a closure that already has a thread of its own (a GRDB queue's). Fails the test if
    /// the gate is not opened in time, and says so by returning false too.
    @discardableResult
    func waitBlocking(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let opened = semaphore.wait(timeout: .now() + limit) == .success
        if !opened { XCTFail("timed out waiting for \(name)", file: file, line: line) }
        return opened
    }

    /// For a test, which must not hold a thread of the cooperative pool.
    @discardableResult
    func waitAsync(file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.waitBlocking(file: file, line: line)) }
        }
    }
}

/// A list that several threads may add to, read after they are done.
final class MailTestList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []
    func add(_ element: Element) { lock.lock(); elements.append(element); lock.unlock() }
    var all: [Element] { lock.lock(); defer { lock.unlock() }; return elements }
}

/// A count that several threads may add to; `increment` says what it has become.
final class MailTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Runs its action the first time `run()` is called, and never again.
final class MailTestOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func run() {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { action() }
    }
}

/// N threads that each wait for the others to have arrived, so that "two reads are running at
/// once" is something the test makes true rather than hopes for. If they do not all arrive in a
/// minute the test fails: with one reader, two reads can never meet.
final class MailTestRendezvous: @unchecked Sendable {
    private let condition = NSCondition()
    private let parties: Int
    private var arrived = 0

    init(parties: Int) { self.parties = parties }

    /// Blocks until all parties have arrived. Fails the test, and returns false, if they do not.
    @discardableResult
    func arriveAndWait(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        condition.lock()
        arrived += 1
        condition.broadcast()
        let deadline = Date().addingTimeInterval(60)
        while arrived < parties, condition.wait(until: deadline) {}
        let all = arrived >= parties
        condition.unlock()
        if !all { XCTFail("only \(arrived) of \(parties) arrived", file: file, line: line) }
        return all
    }
}

/// Records the calls mail makes to put attributes on files, in order, and can say what the
/// filesystem looked like at each one. The Simulator does not enforce protection classes, so
/// the order of the calls is what a test can know.
final class MailAttributeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var offMainChecks: [Bool] = []

    /// Called with each event as it happens, on the calling thread, before it is recorded.
    var onEvent: (@Sendable (String) -> Void)?
    /// Makes calls of this kind throw: "protect", "backup", "quarantine", "sync".
    var failing: Set<String> = []

    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    /// For each time something asked whether it was off the main thread, whether it was on it.
    var offMainCheckedOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return offMainChecks }

    struct Failure: Error {}

    private func note(_ event: String, kind: String) throws {
        onEvent?(event)
        lock.lock(); recorded.append(event); lock.unlock()
        if failing.contains(kind) { throw Failure() }
    }

    var attributes: MailFileAttributes {
        MailFileAttributes(
            protect: { [self] url, type in
                try note("protect \(url.lastPathComponent) \(MailAttributeRecorder.name(type))", kind: "protect")
            },
            excludeFromBackup: { [self] url in
                try note("backup \(url.lastPathComponent)", kind: "backup")
            },
            quarantine: { [self] url, _ in
                try note("quarantine \(url.lastPathComponent)", kind: "quarantine")
            },
            synchronize: { [self] url in
                try note("sync \(url.lastPathComponent)", kind: "sync")
            },
            requireOffMain: { [self] in
                lock.lock(); offMainChecks.append(Thread.isMainThread); lock.unlock()
            })
    }

    static func name(_ type: FileProtectionType) -> String {
        switch type {
        case .complete: return "complete"
        case .completeUntilFirstUserAuthentication: return "completeUntilFirstUserAuthentication"
        default: return type.rawValue
        }
    }
}

/// A base for tests that need a directory of their own, which is cleaned up afterwards. Never
/// under the real application-support path.
class MailStoreTestCase: XCTestCase {

    /// A new empty directory under the temporary folder.
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Runs `body` on a global queue — not the main queue, which opening a store forbids, and
    /// not the cooperative pool, which blocking file work should not hold.
    func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// The stores of a throwaway tree, opened as the engine opens them.
    func openStores(root: URL? = nil,
                    migrations: MailMigrations = MailMigrations(),
                    attributes: MailFileAttributes? = nil) async throws -> MailStores {
        let root = try root ?? makeRoot()
        let attributes = attributes ?? MailAttributeRecorder().attributes
        return try await offMain {
            try MailStores.open(try MailDirectories(root: root, attributes: attributes),
                                migrations: migrations)
        }
    }

    /// A migrator with one step, `v1`, that makes a table `t(id)`.
    func tableMigrator(_ table: String = "t") -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: table) { $0.column("id", .integer).primaryKey() }
        }
        return migrator
    }
}

// MARK: - The stores

/// The four stores, opened as 4.2 says, and what each setting actually reads back as.
///
/// The failures these exist for are the silent ones. A durability setting that is not what it
/// claims: GRDB puts `synchronous` back to NORMAL after `prepareDatabase` has run, so a store
/// configured for FULL in the obvious place is NORMAL, and every commit "with a full fsync" is
/// not. A reader that holds a transaction: the log it pins grew to 486 MB in five seconds when
/// one did. So almost nothing here trusts the configuration that was passed in: it asks the open
/// connection (`PRAGMA`), on every connection there is.
final class MailStoresTests: MailStoreTestCase {

    // MARK: - SQLite itself

    func testTheSystemSQLiteIsAtLeastVersion3_43() async throws {
        let version = try await DatabaseQueue().read { try String.fetchOne($0, sql: "SELECT sqlite_version()") }
        print("mail-sqlite version \(version ?? "?")")
        let parts = try XCTUnwrap(version).split(separator: ".").compactMap { Int($0) }
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        let atLeast343 = parts[0] > 3 || (parts[0] == 3 && parts[1] >= 43)
        XCTAssertTrue(atLeast343,
                      "SQLite \(version ?? "?") cannot make a contentless full-text table that deletes (`contentless_delete=1` needs 3.43), and search's whole design is that table")
    }

    func testFTS5WithContentlessDeleteCreatesReplacesAndDeletes() async throws {
        let stores = try await openStores()
        // 4.6, as written there.
        try await stores.searchWriter.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE msg_fts USING fts5(
                  subject, sender, recipients, body, attachments,
                  content='', contentless_delete=1,
                  tokenize='unicode61 remove_diacritics 2',
                  prefix='2 3',
                  detail=full)
                """)
            try db.execute(sql: "INSERT INTO msg_fts(rowid, subject, body) VALUES (10, 'alpha', 'first body')")
            try db.execute(sql: "INSERT INTO msg_fts(rowid, subject, body) VALUES (20, 'gamma', 'second body')")
        }
        func matches(_ term: String) async throws -> [Int64] {
            try await stores.searchWriter.read {
                try Int64.fetchAll($0, sql: "SELECT rowid FROM msg_fts WHERE msg_fts MATCH ? ORDER BY rowid",
                                   arguments: [term])
            }
        }

        let created = try await matches("alpha")
        XCTAssertEqual(created, [10])

        // Replace: the old terms are gone and the new ones found.
        try await stores.searchWriter.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO msg_fts(rowid, subject, body) VALUES (10, 'beta', 'first body')")
        }
        let afterReplaceOld = try await matches("alpha")
        let afterReplaceNew = try await matches("beta")
        XCTAssertEqual(afterReplaceOld, [], "a replaced row must not keep answering to its old words")
        XCTAssertEqual(afterReplaceNew, [10])

        // Delete.
        try await stores.searchWriter.write { db in
            try db.execute(sql: "DELETE FROM msg_fts WHERE rowid = 20")
        }
        let afterDelete = try await matches("gamma")
        XCTAssertEqual(afterDelete, [])

        // And what the writer did is what the search reader sees.
        let seen = try await stores.searchReader.read {
            try Int64.fetchAll($0, sql: "SELECT rowid FROM msg_fts WHERE msg_fts MATCH 'beta'")
        }
        XCTAssertEqual(seen, [10])
    }

    // MARK: - The settings, read back from every connection

    /// What a connection says its settings are.
    private struct ReadBack: Sendable {
        var journalMode: String
        var values: [String: Int]
    }

    private static let numericPragmas = [
        "synchronous", "fullfsync", "temp_store", "foreign_keys", "busy_timeout", "cache_size",
        "wal_autocheckpoint", "auto_vacuum", "journal_size_limit", "checkpoint_fullfsync",
    ]
    private static let eightMiB = 8_388_608

    private static func readBack(_ db: Database) throws -> ReadBack {
        let journal = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "?"
        var values: [String: Int] = [:]
        for name in numericPragmas {
            values[name] = try Int.fetchOne(db, sql: "PRAGMA \(name)")
        }
        return ReadBack(journalMode: journal, values: values)
    }

    /// Both reader connections of a pool, read at the same moment, which is what makes them two.
    private func readers(of pool: DatabasePool) async throws -> [ReadBack] {
        let together = MailTestRendezvous(parties: 2)
        let first = Task { try await pool.read { db -> ReadBack in together.arriveAndWait(); return try Self.readBack(db) } }
        let second = Task { try await pool.read { db -> ReadBack in together.arriveAndWait(); return try Self.readBack(db) } }
        return [try await first.value, try await second.value]
    }

    private func writer(of pool: DatabasePool) async throws -> ReadBack {
        try await pool.writeWithoutTransaction { try Self.readBack($0) }
    }

    private func check(_ read: ReadBack, _ expected: [String: Int], journal: String = "wal",
                       _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = read.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("mail-pragmas \(label): journal_mode=\(read.journalMode) \(shown)")
        XCTAssertEqual(read.journalMode, journal, "\(label): journal_mode", file: file, line: line)
        for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(read.values[name], value, "\(label): \(name)", file: file, line: line)
        }
    }

    func testEveryPragmaOf4_2IsReadBackFromEveryConnection() async throws {
        let stores = try await openStores()
        let common = ["temp_store": 2, "foreign_keys": 0, "busy_timeout": 2000]

        // index.sqlite — one writer, two readers, 4 MB each. The writer is at GRDB's NORMAL.
        check(try await writer(of: stores.index),
              common.merging(["synchronous": 1, "fullfsync": 0, "cache_size": -4096,
                              "wal_autocheckpoint": 0, "auto_vacuum": 0,
                              "journal_size_limit": Self.eightMiB, "checkpoint_fullfsync": 1]) { $1 },
              "index writer")
        for (n, reader) in try await readers(of: stores.index).enumerated() {
            check(reader, common.merging(["cache_size": -4096, "auto_vacuum": 0]) { $1 },
                  "index reader \(n + 1)")
        }

        // blobs.sqlite — one writer, two readers, 2 MB each, incremental auto-vacuum (2).
        check(try await writer(of: stores.blobs),
              common.merging(["synchronous": 1, "fullfsync": 0, "cache_size": -2048,
                              "wal_autocheckpoint": 0, "auto_vacuum": 2,
                              "journal_size_limit": Self.eightMiB, "checkpoint_fullfsync": 1]) { $1 },
              "blobs writer")
        for (n, reader) in try await readers(of: stores.blobs).enumerated() {
            check(reader, common.merging(["cache_size": -2048, "auto_vacuum": 2]) { $1 },
                  "blobs reader \(n + 1)")
        }

        // search.sqlite — its writer 4 MB, its read-only reader 8 MB for the three files it holds
        // open: its own and the two attached (read back by name, below).
        check(try await stores.searchWriter.writeWithoutTransaction { try Self.readBack($0) },
              common.merging(["synchronous": 1, "fullfsync": 0, "cache_size": -4096,
                              "wal_autocheckpoint": 0,
                              "journal_size_limit": Self.eightMiB, "checkpoint_fullfsync": 1]) { $1 },
              "search writer")
        check(try await stores.searchReader.read { try Self.readBack($0) },
              common.merging(["cache_size": -4096]) { $1 },
              "search reader")

        // intent.sqlite — one connection, 1 MB, FULL with the full fsync, which GRDB would have
        // put back to NORMAL had they been set only where it looks.
        let intent = try await offMain { try stores.openIntent() }
        check(try await intent.writeWithoutTransaction { try Self.readBack($0) },
              common.merging(["synchronous": 2, "fullfsync": 1, "cache_size": -1024,
                              "wal_autocheckpoint": 0, "journal_size_limit": Self.eightMiB]) { $1 },
              "intent")
    }

    func testTheReadersOfAPoolStillHaveTheirPragmasAfterTheMemoryIsReleased() async throws {
        // Releasing memory closes a pool's readers; the next read opens new ones, which must be
        // set up the same way — the settings belong to a connection, not to the file.
        let stores = try await openStores()
        stores.index.releaseMemory()
        stores.blobs.releaseMemory()
        for reader in try await readers(of: stores.index) {
            check(reader, ["temp_store": 2, "foreign_keys": 0, "busy_timeout": 2000, "cache_size": -4096],
                  "index reader after release")
        }
        for reader in try await readers(of: stores.blobs) {
            check(reader, ["temp_store": 2, "foreign_keys": 0, "busy_timeout": 2000, "cache_size": -2048],
                  "blobs reader after release")
        }
    }

    func testTheIntentStoreIsStillFullySynchronousWhenItIsOpenedAgainOnTheExistingFile() async throws {
        let root = try makeRoot()
        let first = try await openStores(root: root)
        let intent = try await offMain { try first.openIntent() }
        try await intent.write { try $0.execute(sql: "CREATE TABLE kept(id INTEGER)") }

        let again = try await offMain { try first.openIntent() }
        let read = try await again.writeWithoutTransaction { try Self.readBack($0) }
        XCTAssertEqual(read.values["synchronous"], 2)
        XCTAssertEqual(read.values["fullfsync"], 1)
        again.releaseMemory()
        let afterRelease = try await again.writeWithoutTransaction { try Self.readBack($0) }
        XCTAssertEqual(afterRelease.values["synchronous"], 2, "releasing memory must not undo the setting")
        XCTAssertEqual(afterRelease.values["fullfsync"], 1)
    }

    /// The fact the intent store's own handling exists because of (4.2; reuse review B-1).
    func testAPlainGRDBOpenOfAWALStoreReadsBackSynchronousNormalWhateverTheConfigurationSaid() async throws {
        let path = try makeRoot().appendingPathComponent("plain.sqlite").path
        var configuration = Configuration()
        configuration.journalMode = .wal
        // The obvious place to ask for it.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA fullfsync = ON")
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)

        let synchronous = try await queue.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA synchronous") }
        XCTAssertEqual(synchronous, 1,
                       "if this is 2, GRDB has stopped resetting it and the second setting in openIntent is now redundant — good, but update 4.2")
        // GRDB resets `synchronous` and nothing else: what it does to `fullfsync` is reported, not
        // asserted (4.2 says it reads back 0; the reuse review's run read it back as 1).
        let fullfsync = try await queue.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA fullfsync") }
        print("mail-pragmas plain GRDB WAL queue, fullfsync set in prepareDatabase: synchronous=\(synchronous ?? -1) fullfsync=\(fullfsync ?? -1)")

        // Set after opening, outside a transaction, it holds.
        try await queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA synchronous = FULL") }
        let after = try await queue.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA synchronous") }
        XCTAssertEqual(after, 2)
    }

    func testSettingSynchronousInsideATransactionIsRefusedAndChangesNothing() async throws {
        // The second way to get it wrong: after opening, but through `write`, which wraps the
        // statement in a transaction. SQLite refuses ("Safety level may not be changed inside a
        // transaction"), so this one is loud; `openIntentQueue` uses `writeWithoutTransaction`.
        let path = try makeRoot().appendingPathComponent("in-transaction.sqlite").path
        var configuration = Configuration()
        configuration.journalMode = .wal
        let queue = try DatabaseQueue(path: path, configuration: configuration)

        do {
            try await queue.write { try $0.execute(sql: "PRAGMA synchronous = FULL") }
            XCTFail("SQLite accepted a change of safety level inside a transaction")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
        }
        let synchronous = try await queue.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA synchronous") }
        XCTAssertEqual(synchronous, 1)
    }

    func testBlobsIsCreatedWithIncrementalAutoVacuumAndTheOthersAreNot() async throws {
        // auto_vacuum is fixed by the first page written, and switching on WAL writes it, so the
        // setting has to come first. Read back from a store that did not exist a moment ago.
        let stores = try await openStores()
        let blobs = try await writer(of: stores.blobs)
        let index = try await writer(of: stores.index)
        XCTAssertEqual(blobs.values["auto_vacuum"], 2, "incremental, so eviction can give pages back")
        XCTAssertEqual(index.values["auto_vacuum"], 0)
    }

    func testEachStoreIsConfiguredAsTheTableOf4_2Says() async throws {
        let stores = try await openStores()
        let intent = try await offMain { try stores.openIntent() }
        XCTAssertEqual(stores.index.configuration.maximumReaderCount, 2)
        XCTAssertEqual(stores.blobs.configuration.maximumReaderCount, 2)
        XCTAssertEqual(stores.index.configuration.qos, .userInitiated)
        XCTAssertEqual(stores.blobs.configuration.qos, .utility)
        XCTAssertEqual(stores.searchWriter.configuration.qos, .utility)
        XCTAssertEqual(stores.searchReader.configuration.qos, .userInitiated)
        XCTAssertEqual(intent.configuration.qos, .userInitiated)
        XCTAssertTrue(stores.searchReader.configuration.readonly)
        XCTAssertFalse(stores.searchWriter.configuration.readonly)
        XCTAssertFalse(stores.index.configuration.publicStatementArguments)
        XCTAssertFalse(intent.configuration.publicStatementArguments)
    }

    func testThePageCacheOfAllTheConnectionsIsTheThirtyOneMegabytesOf4_2() async throws {
        // Counted from what the open connections say, not from what was asked for: the most page
        // cache that can be in use at once is three connections of 4 MB (the index's writer and
        // two readers), three of 2 (blobs), one of 1 (intent), one of 4 (the search writer) and
        // one of 8 — which is the search reader's *three* files, `search.sqlite` and the two
        // attached ones, each of which has a cache of its own that a bare `cache_size` pragma
        // does not reach.
        let stores = try await openStores()
        let intent = try await offMain { try stores.openIntent() }
        func kib(_ read: ReadBack) -> Int { -(read.values["cache_size"] ?? 0) }

        let indexConnections = [try await writer(of: stores.index)] + (try await readers(of: stores.index))
        let blobsConnections = [try await writer(of: stores.blobs)] + (try await readers(of: stores.blobs))
        let searchWriter = try await stores.searchWriter.writeWithoutTransaction { try Self.readBack($0) }
        let intentConnection = try await intent.writeWithoutTransaction { try Self.readBack($0) }
        let reader = try await stores.searchReader.read { db in
            [try Int.fetchOne(db, sql: "PRAGMA main.cache_size"),
             try Int.fetchOne(db, sql: "PRAGMA \(MailStores.attachedIndexName).cache_size"),
             try Int.fetchOne(db, sql: "PRAGMA \(MailStores.attachedBlobsName).cache_size")]
        }
        print("mail-pragmas search reader caches (main, idx, blobs): \(reader.map { $0 ?? 0 })")
        XCTAssertEqual(reader, [-4096, -3072, -1024], "main, idx, blobs: 8 MB in all")

        let total = indexConnections.map(kib).reduce(0, +) + blobsConnections.map(kib).reduce(0, +)
            + kib(searchWriter) + kib(intentConnection) + reader.compactMap { $0 }.map { -$0 }.reduce(0, +)
        XCTAssertEqual(total, 31 * 1024)
    }

    func testTwoReadsOnAPoolReallyRunAtTheSameTime() async throws {
        // Two readers is a claim about concurrency, so it is tested as one: each read waits in
        // its closure until the other has arrived. With one reader this never finishes.
        let stores = try await openStores()
        let results = try await readers(of: stores.index)
        XCTAssertEqual(results.count, 2)
    }

    func testTheSearchReaderIsReadOnlyAndSeesTheIndexAndBlobsAttached() async throws {
        let stores = try await openStores(migrations: MailMigrations(index: tableMigrator("indexed"),
                                                                      blobs: tableMigrator("kept")))
        try await stores.index.write { try $0.execute(sql: "INSERT INTO indexed VALUES (7)") }
        try await stores.blobs.write { try $0.execute(sql: "INSERT INTO kept VALUES (9)") }

        let joined = try await stores.searchReader.read { db in
            (try Int.fetchOne(db, sql: "SELECT id FROM \(MailStores.attachedIndexName).indexed"),
             try Int.fetchOne(db, sql: "SELECT id FROM \(MailStores.attachedBlobsName).kept"))
        }
        XCTAssertEqual(joined.0, 7)
        XCTAssertEqual(joined.1, 9)

        // Nothing can be written through it: not to its own file, and not to what is attached.
        for sql in ["CREATE TABLE nope(id)",
                    "INSERT INTO \(MailStores.attachedIndexName).indexed VALUES (8)",
                    "INSERT INTO \(MailStores.attachedBlobsName).kept VALUES (8)"] {
            do {
                try await stores.searchReader.writeWithoutTransaction { try $0.execute(sql: sql) }
                XCTFail("the search reader accepted: \(sql)")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_READONLY, sql)
            }
        }
    }

    // MARK: - Concurrency the design depends on

    func testAReaderSeesTheLastCommitWhileAWriteIsOpen() async throws {
        let stores = try await openStores(migrations: MailMigrations(index: tableMigrator()))
        try await stores.index.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") }

        let writeIsOpen = MailTestGate(), letWriteFinish = MailTestGate()
        let writing = Task {
            try await stores.index.write { db in
                try db.execute(sql: "INSERT INTO t VALUES (2)")
                writeIsOpen.open()
                letWriteFinish.waitBlocking()
            }
        }
        await writeIsOpen.waitAsync()

        let during = try await stores.index.read { try Int.fetchAll($0, sql: "SELECT id FROM t ORDER BY id") }
        XCTAssertEqual(during, [1], "a reader sees the last commit, not the write in progress, and is not made to wait for it")

        letWriteFinish.open()
        try await writing.value
        let after = try await stores.index.read { try Int.fetchAll($0, sql: "SELECT id FROM t ORDER BY id") }
        XCTAssertEqual(after, [1, 2])
    }

    func testInterruptingTheSearchReaderEndsALongSearchAndLeavesAnIndexReadAlone() async throws {
        let stores = try await openStores()

        // A read on the index pool, held open while the search is interrupted.
        let indexReadStarted = MailTestGate(), letIndexReadFinish = MailTestGate()
        let indexRead = Task {
            try await stores.index.read { db -> Int in
                indexReadStarted.open()
                letIndexReadFinish.waitBlocking()
                return try Int.fetchOne(db, sql: "SELECT 41 + 1") ?? -1
            }
        }
        await indexReadStarted.waitAsync()

        // A search that would never end, which says when it has begun — from inside the
        // statement, because an interrupt that arrives before one is running is lost.
        let searchRunning = MailTestGate()
        let announce = MailTestOnce { searchRunning.open() }
        let search = Task { () -> Error? in
            do {
                try await stores.searchReader.read { db in
                    db.add(function: DatabaseFunction("running", argumentCount: 0, pure: false) { _ in
                        announce.run()
                        return 1
                    })
                    _ = try Int.fetchOne(db, sql: """
                        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c)
                        SELECT count(*) FROM c WHERE running() = 1
                        """)
                }
                return nil
            } catch {
                return error
            }
        }
        await searchRunning.waitAsync()
        stores.searchReader.interrupt()

        let ended = await search.value
        XCTAssertEqual((ended as? DatabaseError)?.resultCode, .SQLITE_INTERRUPT)

        letIndexReadFinish.open()
        let answer = try await indexRead.value
        XCTAssertEqual(answer, 42, "interrupting search must not touch a list read")
    }

    func testNoReaderKeepsATransactionOpenAfterItsReadReturns() async throws {
        // Invariant 11, from the other side: a reader that holds a snapshot stops the log from
        // being checkpointed, and a log nothing can checkpoint is the 486 MB. After reads have
        // returned — the async ones, as the engine makes them — a checkpoint copies everything.
        let stores = try await openStores(migrations: MailMigrations(index: tableMigrator()))
        for id in 1...50 {
            try await stores.index.write { try $0.execute(sql: "INSERT INTO t VALUES (?)", arguments: [id]) }
            _ = try await stores.index.read { try Int.fetchAll($0, sql: "SELECT id FROM t") }
        }
        let both = try await readers(of: stores.index)
        XCTAssertEqual(both.count, 2)

        let counts = try await stores.index.writeWithoutTransaction { try $0.checkpoint(.passive) }
        XCTAssertGreaterThan(counts.walFrameCount, 0)
        XCTAssertEqual(counts.checkpointedFrameCount, counts.walFrameCount,
                       "a reader is still pinning part of the log after its read returned")
    }

    // MARK: - Migrations

    func testAStoreNewerThanTheMigrationsItIsOpenedWithIsRefused() async throws {
        for file in [MailStoreFile.index, .blobs, .search] {
            let root = try makeRoot()
            var newer = MailMigrations()
            switch file {
            case .index: newer.index = tableMigrator()
            case .blobs: newer.blobs = tableMigrator()
            case .search: newer.search = tableMigrator()
            case .intent: break
            }
            // Opened by a build that knows the step, then by one that does not.
            _ = try await openStores(root: root, migrations: newer)

            do {
                _ = try await openStores(root: root, migrations: MailMigrations())
                XCTFail("\(file.rawValue) was opened by code older than its schema")
            } catch let error as MailStoreError {
                XCTAssertEqual(error, .newerThanThisVersion(file))
            }
        }
    }

    func testAStoreAtTheCurrentVersionOpensAgainWithItsMigrationsApplied() async throws {
        let root = try makeRoot()
        let migrations = MailMigrations(index: tableMigrator(), blobs: tableMigrator(), search: tableMigrator())
        _ = try await openStores(root: root, migrations: migrations)
        let again = try await openStores(root: root, migrations: migrations)
        let tables = try await again.index.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE name = 't'") }
        XCTAssertEqual(tables, ["t"])
    }

    func testTheEnginesMigrationsOpenAnEmptyTree() async throws {
        let stores = try await openStores(migrations: MailSlices.migrations())
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master") }
        XCTAssertNotNil(count)
    }

    /// The code of a source file with its line comments taken off, so that a sentence that says
    /// what is not done does not count as doing it.
    private func code(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    func testNoMailSourceFileNamesWhatErasesADatabaseHoldsATransactionOrShowsBoundValues() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Banana/Model/Mail")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path),
                          "the source tree is not on this machine")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var looked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            looked += 1
            let name = file.lastPathComponent
            let text = try code(of: file)
            XCTAssertFalse(text.contains("eraseDatabaseOnSchemaChange"),
                           "\(name): a schema step is added, never a reset (4.2, invariant 5)")
            XCTAssertFalse(text.contains("expandedDescription"),
                           "\(name): shows the values bound to a statement (invariant 21)")
            XCTAssertFalse(text.contains("publicStatementArguments = true"),
                           "\(name): would put bound values in every error (invariant 21)")
            // Ways to keep a read transaction open after the closure that made it has returned,
            // which compile (invariant 11): a snapshot, an observation, a cursor that outlives its
            // read, a transaction left open on purpose.
            for token in ["makeSnapshot", "ValueObservation", "allowsUnsafeTransactions"] {
                XCTAssertFalse(text.contains(token), "\(name): \(token) can hold a transaction open (invariant 11)")
            }
            // `erase` of a database, and `vacuum(into:)`, are what the intent store has no method for.
            XCTAssertFalse(text.contains(".erase("), "\(name): erases a database (invariant 5)")
            // Every connection that can exist is made by `MailStores`, so that every one has the
            // settings of 4.2 and the guard of invariant 10; and the intent store's durability is
            // set where `openIntentQueue` can see it was.
            if name != "MailStores.swift" {
                XCTAssertFalse(text.contains("DatabasePool(") || text.contains("DatabaseQueue("),
                               "\(name): opens a connection that MailStores did not make")
                // SQLite keeps one trace per connection: a second would silently replace the guard
                // of invariant 10 that `MailStores` sets on every connection.
                XCTAssertFalse(text.contains(".trace("),
                               "\(name): a trace replaces the main-thread guard on the connection it is set on")
            }
        }
        XCTAssertGreaterThan(looked, 5)
    }

    // MARK: - Damaged files, and what an error says

    func testAFileThatIsNotADatabaseIsRefusedByNameAndLeftAsItWas() async throws {
        // 4.10 does a different thing for each file — the intent store is never reset, the
        // index is renamed and rebuilt, search is deleted and re-indexed, blobs is renamed and
        // fetched again — and `open` opens all four, so the error says which.
        let garbage = Data("this is not a database, and it is not mail's to delete".utf8)
        for file in [MailStoreFile.index, .blobs, .search] {
            let root = try makeRoot()
            let directories = try await offMain { try MailDirectories(root: root, attributes: MailAttributeRecorder().attributes) }
            let damaged: URL
            switch file {
            case .index: damaged = directories.indexDatabase
            case .blobs: damaged = directories.blobsDatabase
            case .search: damaged = directories.searchDatabase
            case .intent: continue
            }
            try garbage.write(to: damaged)
            do {
                _ = try await offMain { try MailStores.open(directories, migrations: MailMigrations()) }
                XCTFail("a \(file.rawValue) that is not a database was opened")
            } catch let error as MailStoreError {
                XCTAssertEqual(error, .cannotOpen(file, code: .SQLITE_NOTADB))
                XCTAssertFalse(String(describing: error).contains("database"), "nothing of SQLite's message: \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: damaged), garbage,
                           "opening must not rewrite, rename or delete what it cannot read")
        }

        // `intent.sqlite` above all (invariant 5).
        let root = try makeRoot()
        let directories = try await offMain { try MailDirectories(root: root, attributes: MailAttributeRecorder().attributes) }
        try garbage.write(to: directories.intentDatabase)
        do {
            _ = try await offMain { try MailStores.openIntentQueue(at: directories.intentDatabase) }
            XCTFail("a file that is not a database was opened as the intent store")
        } catch let error as MailStoreError {
            XCTAssertEqual(error, .cannotOpen(.intent, code: .SQLITE_NOTADB))
        }
        XCTAssertEqual(try Data(contentsOf: directories.intentDatabase), garbage)
    }

    func testAStoreThatCannotBeCreatedIsRefusedByNameToo() async throws {
        // Not a damaged file but one that cannot be made: its place is taken by a directory.
        for file in [MailStoreFile.index, .blobs, .search] {
            let root = try makeRoot()
            let directories = try await offMain { try MailDirectories(root: root, attributes: MailAttributeRecorder().attributes) }
            let inTheWay: URL
            switch file {
            case .index: inTheWay = directories.indexDatabase
            case .blobs: inTheWay = directories.blobsDatabase
            case .search: inTheWay = directories.searchDatabase
            case .intent: continue
            }
            try FileManager.default.createDirectory(at: inTheWay, withIntermediateDirectories: false)
            do {
                _ = try await offMain { try MailStores.open(directories, migrations: MailMigrations()) }
                XCTFail("a \(file.rawValue) was opened where a directory is")
            } catch let error as MailStoreError {
                guard case .cannotOpen(let named, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(named, file)
            }
        }
    }

    func testErrorDescriptionsCarryNoBoundValues() async throws {
        // Invariant 21: nothing mail writes to a log carries content, and an error's description
        // is the thing most likely to be written. A value bound to a statement must not be in it.
        // (GRDB's `expandedDescription` and `arguments` do show them, by design, for a developer
        // who asks; the next test is that no mail file does.)
        let marker = "SECRET-SUBJECT-4f1a9c"
        let stores = try await openStores(migrations: MailMigrations(index: tableMigrator(),
                                                                      blobs: tableMigrator(),
                                                                      search: tableMigrator()))
        let intent = try await offMain { try stores.openIntent() }
        try await intent.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY, text TEXT UNIQUE NOT NULL)") }
        for pool in [stores.index, stores.blobs] {
            try await pool.write { try $0.execute(sql: "ALTER TABLE t ADD COLUMN text TEXT") }
            try await pool.write { try $0.execute(sql: "CREATE UNIQUE INDEX t_text ON t(text)") }
        }
        try await stores.searchWriter.write { try $0.execute(sql: "ALTER TABLE t ADD COLUMN text TEXT") }
        try await stores.searchWriter.write { try $0.execute(sql: "CREATE UNIQUE INDEX t_text ON t(text)") }

        var errors: [Error] = []
        func collect(_ body: () async throws -> Void) async {
            do { try await body(); XCTFail("the statement should have failed") } catch { errors.append(error) }
        }
        for pool in [stores.index, stores.blobs] {
            await collect {
                try await pool.write { db in
                    try db.execute(sql: "INSERT INTO t(id, text) VALUES (1, ?)", arguments: [marker])
                    try db.execute(sql: "INSERT INTO t(id, text) VALUES (2, ?)", arguments: [marker])
                }
            }
        }
        await collect {
            try await stores.searchWriter.write { db in
                try db.execute(sql: "INSERT INTO t(id, text) VALUES (1, ?)", arguments: [marker])
                try db.execute(sql: "INSERT INTO t(id, text) VALUES (2, ?)", arguments: [marker])
            }
        }
        await collect {
            try await intent.write { db in
                try db.execute(sql: "INSERT INTO t(id, text) VALUES (1, ?)", arguments: [marker])
                try db.execute(sql: "INSERT INTO t(id, text) VALUES (2, ?)", arguments: [marker])
            }
        }
        await collect {
            try await intent.write { db in
                try db.execute(sql: "INSERT INTO t(id, text) VALUES (3, ?)", arguments: [DatabaseValue.null])
            }
        }
        XCTAssertEqual(errors.count, 5)
        for error in errors {
            let said = [String(describing: error), "\(error)", error.localizedDescription,
                        (error as? DatabaseError)?.description ?? "",
                        (error as? DatabaseError)?.message ?? ""]
            for text in said {
                XCTAssertFalse(text.contains(marker), "an error carries a bound value: \(text)")
            }
        }
    }

    // MARK: - Invariant 10: the main thread does no SQLite

    /// What the guard was asked, and whether the thread that asked was the main one.
    private final class GuardLog: @unchecked Sendable {
        private let list = MailTestList<String>()
        func record(_ what: StaticString) { list.add("\(what) \(Thread.isMainThread ? "on main" : "off main")") }
        var all: [String] { list.all }
        var onMain: [String] { all.filter { $0.hasSuffix("on main") } }
    }

    private func watchTheGuard() -> GuardLog {
        let log = GuardLog()
        MailMainQueueGuard.replaceForTesting { log.record($0) }
        addTeardownBlock { MailMainQueueGuard.resetForTesting() }
        return log
    }

    func testOpeningAStoreChecksThatItIsNotOnTheMainQueue() async throws {
        // A trap cannot be asserted on, so the check is replaced by one that records, and what is
        // proved is that each way of opening reaches it, on whatever thread opens. The real one is
        // `dispatchPrecondition(condition: .notOnQueue(.main))` and a check of the thread, and
        // every other test in this class runs with it in place and opens from a background queue.
        let root = try makeRoot()
        let directories = try await offMain { try MailDirectories(root: root, attributes: MailAttributeRecorder().attributes) }
        let log = watchTheGuard()

        // From the main thread, as the test runs: both ways in reach the check, and see the main thread.
        let stores = try await MainActor.run { try MailStores.open(directories, migrations: MailMigrations()) }
        XCTAssertTrue(log.onMain.contains("MailStores.open on main"), "\(log.all)")
        _ = try await MainActor.run { try stores.openIntent() }
        XCTAssertTrue(log.onMain.contains("MailStores.openIntentQueue on main"), "\(log.all)")
        // And from a background queue it is asked and finds it is not: nothing reaches the handler,
        // which is only for a call that has already failed the thread check.
        let before = log.all.count
        _ = try await offMain { try MailStores.openIntentQueue(at: directories.intentDatabase) }
        XCTAssertEqual(log.all.count, before, "\(log.all)")
    }

    func testABlockingReadOrWriteFromTheMainThreadReachesTheGuardOnEveryStore() async throws {
        // The hole that opening alone leaves: GRDB's `read` and `write` have a blocking form and an
        // `async` one under the same name, and in a synchronous function on the main actor the
        // blocking one is chosen and compiles. A statement run on any connection is guarded, so
        // each store's handle is tried the blocking way from the main thread, as a synchronous
        // main-actor function would, and the guard must see it. (`MainActor.run`'s closure is
        // synchronous.)
        let stores = try await openStores(migrations: MailMigrations(index: tableMigrator(),
                                                                      blobs: tableMigrator(),
                                                                      search: tableMigrator()))
        let intent = try await offMain { try stores.openIntent() }
        // Readers a pool makes later are connections too: let go of the ones it has.
        stores.index.releaseMemory()
        stores.blobs.releaseMemory()
        let log = watchTheGuard()

        let handles: [(String, @Sendable () throws -> Void)] = [
            ("index.read", { _ = try stores.index.read { try Int.fetchOne($0, sql: "SELECT 1") } }),
            ("index.write", { try stores.index.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") } }),
            ("blobs.read", { _ = try stores.blobs.read { try Int.fetchOne($0, sql: "SELECT 1") } }),
            ("blobs.write", { try stores.blobs.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") } }),
            ("searchWriter.write", { try stores.searchWriter.write { try $0.execute(sql: "INSERT INTO t VALUES (1)") } }),
            ("searchReader.read", { _ = try stores.searchReader.read { try Int.fetchOne($0, sql: "SELECT 1") } }),
            ("intent.write", { try intent.write { try $0.execute(sql: "CREATE TABLE IF NOT EXISTS i(x)") } }),
        ]
        for (name, body) in handles {
            let before = log.onMain.count
            try await MainActor.run { try body() }
            XCTAssertGreaterThan(log.onMain.count, before, "\(name) ran SQLite on the main thread and nothing noticed")
        }
        XCTAssertTrue(log.onMain.allSatisfy { $0 == "a statement on main" })
    }

    func testTheAsyncFormsOfReadAndWriteNeverReachTheGuardsHandler() async throws {
        // The other half: what the engine does — `await`, so the closure runs on the connection's
        // own queue — passes the thread check and never reaches the handler, which is only for a
        // violation. A control at the end shows the guard was live throughout: the same handle,
        // read the blocking way from the main thread, does reach it.
        let stores = try await openStores(migrations: MailMigrations(index: tableMigrator()))
        let log = watchTheGuard()
        for id in 1...20 {
            try await stores.index.write { try $0.execute(sql: "INSERT INTO t VALUES (?)", arguments: [id]) }
            _ = try await stores.index.read { try Int.fetchAll($0, sql: "SELECT id FROM t") }
        }
        _ = try await stores.searchReader.read { try Int.fetchOne($0, sql: "SELECT 1") }
        XCTAssertEqual(log.all, [], "an async read or write was taken for a violation")

        try await MainActor.run { _ = try stores.index.read { try Int.fetchOne($0, sql: "SELECT 1") } }
        XCTAssertFalse(log.onMain.isEmpty, "the control: the guard was not live, so the empty log above proves nothing")
    }

    /// A journal that keeps what it is told, as text that can be searched.
    private final class RecordingJournal: @unchecked Sendable {
        private let list = MailTestList<[String]>()
        var journal: MailJournal {
            MailJournal(line: { [list] event, fields in
                list.add(["event=\(event.rawValue)"] + fields.map(RecordingJournal.describe))
            }, begin: { _ in MailSignpost(end: {}) })
        }
        var lines: [[String]] { list.all }
        static func describe(_ field: MailJournalField) -> String {
            switch field {
            case .count(let name, let n): return "count \(name)=\(n)"
            case .ms(let name, let v): return "ms \(name)=\(v)"
            case .flag(let name, let on): return "flag \(name)=\(on)"
            case .account(let n): return "account a\(n)"
            case .id(let name, let id): return "id \(name)=\(id)"
            case .code(let name, let code): return "code \(name)=\(code.rawValue)"
            }
        }
    }

    func testTheDefaultPolicyOfADebugBuildIsToTrapAndOfAReleaseBuildToReportAndContinue() {
        #if DEBUG
        XCTAssertEqual(MailMainQueueGuard.defaultPolicy, .trap)
        #else
        XCTAssertEqual(MailMainQueueGuard.defaultPolicy, .reportAndContinue)
        #endif
    }

    func testInReleaseAViolationIsRecordedOncePerCallSiteAndStoreAndTheWorkGoesOn() async throws {
        // Driven through the policy seam, not a Release build: choose what a Release build does,
        // and run SQLite on the main thread the blocking way.
        let stores = try await openStores(migrations: MailMigrations(index: tableMigrator(), blobs: tableMigrator()))
        let recorder = RecordingJournal()
        MailMainQueueGuard.setPolicyForTesting(.reportAndContinue, journal: recorder.journal)
        addTeardownBlock { MailMainQueueGuard.resetForTesting() }

        // The work is not stopped: three reads of the index and two of blobs run on the main thread
        // and answer — one of them with a statement that carries something he wrote.
        let secret = "SECRET-SUBJECT-9d3e"
        let answers = try await MainActor.run { () -> [Int] in
            var all: [Int] = []
            for _ in 1...3 { all.append(try stores.index.read { try Int.fetchOne($0, sql: "SELECT 1") } ?? -1) }
            for _ in 1...2 { all.append(try stores.blobs.read { try Int.fetchOne($0, sql: "SELECT 2") } ?? -1) }
            all.append(try stores.index.read { try Int.fetchOne($0, sql: "SELECT length('\(secret)')") } ?? -1)
            return all
        }
        XCTAssertEqual(answers, [1, 1, 1, 2, 2, secret.count])

        // One line for each (call site, store): the index's statements and the blobs'.
        let lines = recorder.lines
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertEqual(Set(lines.map { $0.joined(separator: " ") }), [
            "event=store code file=index code event=onMainThread flag a statement=true count calls=1",
            "event=store code file=blobs code event=onMainThread flag a statement=true count calls=1",
        ])
        for line in lines {
            XCTAssertFalse(line.contains { $0.contains(secret) || $0.contains("SELECT") }, "SQL reached the journal: \(line)")
        }
        // Counted every time, reported once.
        XCTAssertGreaterThanOrEqual(MailMainQueueGuard.violationCount("a statement", store: .index), 4)
        XCTAssertGreaterThanOrEqual(MailMainQueueGuard.violationCount("a statement", store: .blobs), 2)
        XCTAssertEqual(MailMainQueueGuard.violationCount("a statement", store: .search), 0)
    }

    func testInReleaseOpeningAndTheDiskWatchReportAndContinueToo() async throws {
        let root = try makeRoot()
        let directories = try await offMain { try MailDirectories(root: root, attributes: MailAttributeRecorder().attributes) }
        let recorder = RecordingJournal()
        MailMainQueueGuard.setPolicyForTesting(.reportAndContinue, journal: recorder.journal)
        addTeardownBlock { MailMainQueueGuard.resetForTesting() }

        // Opened on the main thread, which it must not be — and it is.
        let stores = try await MainActor.run { try MailStores.open(directories, migrations: MailMigrations()) }
        let intent = try await MainActor.run { try stores.openIntent() }
        XCTAssertNotNil(intent)
        let free: Int64 = 10 * 1_073_741_824
        let state = await MainActor.run { MailDiskWatch(floor: 1_073_741_824, clock: ManualMailClock(), freeBytes: { free }).state() }
        XCTAssertEqual(state, .ok)

        let said = recorder.lines.map { $0.joined(separator: " ") }
        XCTAssertTrue(said.contains { $0.contains("flag MailStores.open=true") && !$0.contains("code file=") }, "\(said)")
        XCTAssertTrue(said.contains { $0.contains("flag MailStores.openIntentQueue=true") && $0.contains("code file=intent") }, "\(said)")
        XCTAssertTrue(said.contains { $0.contains("flag MailDiskWatch.state=true") }, "\(said)")
        // Each of those, once.
        XCTAssertEqual(said.filter { $0.contains("flag MailStores.open=true") }.count, 1)
    }

    func testTheFirstPagePathIsPathArithmeticOnTheMainThreadWithNoFileWorkAndNoStore() async throws {
        // 4.11: the first frame reads `first-page.json` on the main thread, before anything else of
        // mail's has started. The path to it must not need the tree: this is called on the main
        // thread with the real guards live (a trap would end the run), for a root that does not
        // exist, and it makes nothing.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail-never-made-\(UUID().uuidString)", isDirectory: true)
        let path = await MainActor.run { MailDirectories.firstPage(under: root) }
        XCTAssertEqual(path.path, root.appendingPathComponent("Cache").appendingPathComponent("first-page.json").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "asking for the path made a directory")

        // It is the tree's own path, so the two cannot drift.
        let real = try makeRoot()
        let directories = try await offMain { try MailDirectories(root: real, attributes: MailAttributeRecorder().attributes) }
        XCTAssertEqual(directories.firstPage.path, MailDirectories.firstPage(under: real).path)

        // And what 4.11 does with it, on the main thread — read one small file, and nothing else —
        // works with nothing opened: the file is written the way mail writes it, off the main
        // thread, and read back here.
        let snapshot = Data("{\"rows\": []}".utf8)
        try await offMain {
            try MailFiles.install(snapshot, at: MailDirectories.firstPage(under: real), protection: .complete,
                                  quarantine: nil, durability: .atomic, attributes: MailAttributeRecorder().attributes)
        }
        let read = try await MainActor.run { try Data(contentsOf: MailDirectories.firstPage(under: real)) }
        XCTAssertEqual(read, snapshot)
        // Reading it opened no store and made no connection.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.indexDatabase.path))
    }

    func testAPoolsReaderCannotWrite() async throws {
        // K7's argument — a reader commits nothing, so it can never run a checkpoint inside an
        // action — rests on this.
        let stores = try await openStores()
        for pool in [stores.index, stores.blobs] {
            do {
                _ = try await pool.read { try $0.execute(sql: "CREATE TABLE nope(id)") }
                XCTFail("a reader of \(pool.path) wrote")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_READONLY)
            }
        }
    }

    // MARK: - Directories: backup, and the order of the protection calls

    func testBothDirectoriesAreExcludedFromBackup() async throws {
        let root = try makeRoot()
        let directories = try await offMain { try MailDirectories(root: root, attributes: .live) }
        for url in [directories.intent, directories.cache] {
            let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true, "\(url.lastPathComponent) would be restored from an old backup")
        }
    }

    func testTheTreeIsMadeAsTheDocumentDrawsIt() async throws {
        let root = try makeRoot()
        let directories = try await offMain { try MailDirectories(root: root, attributes: MailAttributeRecorder().attributes) }
        for url in [directories.intent, directories.intentAttachments, directories.cache,
                    directories.attachments, directories.remote] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), url.path)
            XCTAssertTrue(isDirectory.boolValue, url.path)
        }
        XCTAssertEqual(directories.attachments.lastPathComponent, "Attachments.noindex")
        XCTAssertEqual(directories.remote.lastPathComponent, "Remote.noindex")
        XCTAssertEqual(directories.indexDatabase.deletingLastPathComponent().path, directories.cache.path)
        XCTAssertEqual(directories.intentDatabase.deletingLastPathComponent().path, directories.intent.path)
        XCTAssertEqual(directories.firstPage.lastPathComponent, "first-page.json")
    }

    func testEachDirectorysClassIsSetBeforeTheFirstStoreIsOpened() async throws {
        let root = try makeRoot()
        let recorder = MailAttributeRecorder()
        // At every call, the filesystem must have no database in it yet: classes are set while
        // the directories are still empty, which is what lets `-wal` and `-shm` be born with them.
        let early = MailTestList<String>()
        recorder.onEvent = { event in
            let found = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
                .filter { $0.hasSuffix(".sqlite") || $0.contains(".sqlite-") }
            if !found.isEmpty { early.add("\(event): \(found)") }
        }

        let directories = try await offMain { try MailDirectories(root: root, attributes: recorder.attributes) }
        let beforeOpening = recorder.events
        XCTAssertEqual(early.all, [])

        // What was set, and to what.
        XCTAssertTrue(beforeOpening.contains("protect Intent completeUntilFirstUserAuthentication"))
        XCTAssertTrue(beforeOpening.contains("protect Attachments completeUntilFirstUserAuthentication"),
                      "Intent/Attachments")
        XCTAssertTrue(beforeOpening.contains("protect Cache completeUntilFirstUserAuthentication"))
        XCTAssertTrue(beforeOpening.contains("protect Attachments.noindex complete"))
        XCTAssertTrue(beforeOpening.contains("protect Remote.noindex complete"))
        XCTAssertTrue(beforeOpening.contains("backup Intent"))
        XCTAssertTrue(beforeOpening.contains("backup Cache"))

        // Then the stores open, and nothing more is set: the log files are born into directories
        // that already have their class.
        let stores = try await offMain { try MailStores.open(directories, migrations: MailMigrations()) }
        _ = try await offMain { try stores.openIntent() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directories.indexDatabase.path + "-wal"),
                      "the test would prove nothing if no log file had been made")
        XCTAssertEqual(recorder.events, beforeOpening)
    }

    func testReportsWhatThisHostSaysAboutProtectionClassesWithoutAssertingAny() async throws {
        // The Simulator does not enforce classes and may not report them (18.4), so nothing is
        // asserted. What the host says is printed, for the person reading the test log.
        let root = try makeRoot()
        let directories = try await offMain { try MailDirectories(root: root, attributes: .live) }
        let stores = try await offMain { try MailStores.open(directories, migrations: MailMigrations()) }
        _ = try await offMain { try stores.openIntent() }
        try await stores.index.write { try $0.execute(sql: "CREATE TABLE report(id INTEGER)") }
        var lines: [String] = []
        for (name, url) in [("Intent/", directories.intent), ("Cache/", directories.cache),
                            ("Attachments.noindex/", directories.attachments),
                            ("index.sqlite", directories.indexDatabase),
                            ("index.sqlite-wal", URL(fileURLWithPath: directories.indexDatabase.path + "-wal"))] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let reported = (attributes?[.protectionKey] as? FileProtectionType).map { MailAttributeRecorder.name($0) }
            lines.append("\(name)=\(reported ?? "not reported")")
        }
        print("mail-protection host reports: " + lines.joined(separator: ", "))
    }

    // MARK: - What a store costs (logged, never asserted)

    func testLogsTheCommitRateOfTheIndexAndTheCostOfAFullFsyncCommit() async throws {
        // 4.12: "none asserted. The commit rate of index.sqlite and the cost of a full-fsync commit
        // are logged." The only assertions are that the work was done.
        let stores = try await openStores(migrations: MailMigrations(index: tableMigrator()))
        let intent = try await offMain { try stores.openIntent() }
        try await intent.write { try $0.execute(sql: "CREATE TABLE a(id INTEGER)") }
        let commits = 300

        let clock = ContinuousClock()
        let indexTime = try await clock.measure {
            for id in 1...commits {
                try await stores.index.write { try $0.execute(sql: "INSERT INTO t VALUES (?)", arguments: [id]) }
            }
        }
        let intentTime = try await clock.measure {
            for id in 1...commits {
                try await intent.write { try $0.execute(sql: "INSERT INTO a VALUES (?)", arguments: [id]) }
            }
        }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        print(String(format: "mail-stores index: %d commits, %.2f ms each (%.0f/s); intent FULL+fullfsync: %.2f ms each; load %.1f %.1f %.1f",
                     commits, ms(indexTime) / Double(commits), Double(commits) / (ms(indexTime) / 1000),
                     ms(intentTime) / Double(commits), load[0], load[1], load[2]))

        let rows = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM t") }
        let intentRows = try await intent.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM a") }
        XCTAssertEqual(rows, commits)
        XCTAssertEqual(intentRows, commits)
    }

    // MARK: - The journal's shape

    func testAJournalIDIsTenHexDigitsAndIsTheSameForTheSameInputs() {
        let salt = Data([1, 2, 3, 4])
        let a = MailJournalID(salt: salt, account: "me@example.com", id: "18c3f0a1")
        let b = MailJournalID(salt: salt, account: "me@example.com", id: "18c3f0a1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.text.count, 10)
        XCTAssertTrue(a.text.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }, a.text)
        XCTAssertFalse(a.text.contains("example"))
    }

    func testAJournalIDDependsOnTheSaltTheAccountAndTheIDAndTheirBoundaries() {
        let salt = Data([1, 2, 3, 4])
        let base = MailJournalID(salt: salt, account: "ab", id: "c")
        XCTAssertNotEqual(base, MailJournalID(salt: Data([9]), account: "ab", id: "c"), "another install must not match")
        XCTAssertNotEqual(base, MailJournalID(salt: salt, account: "ab", id: "d"))
        XCTAssertNotEqual(base, MailJournalID(salt: salt, account: "a", id: "bc"), "the boundary between account and id counts")
    }

    func testAJournalIDIsTheFirstTenDigitsOfSHA256OfSaltAccountAndIDSeparatedByBars() {
        let salt = Data([0xde, 0xad])
        var input = salt
        input.append(Data("|me@example.com|abc".utf8))
        let expected = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined().prefix(10)
        XCTAssertEqual(MailJournalID(salt: salt, account: "me@example.com", id: "abc").text, String(expected))
    }

    func testTheSilentJournalWritesNothingAndItsSignpostsEnd() {
        let journal = MailJournal.silent
        journal.line(.store, [.count("rows", 3), .flag("ok", true)])
        journal.begin("mail.sync").end()
    }
}
