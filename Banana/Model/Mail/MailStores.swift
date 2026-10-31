#if !BANANA_PUBLIC
import Foundation
import GRDB

/// The four SQLite stores of mail's cache and the door to the fifth, opened exactly as
/// MAIL-ENGINE 4.2 says — one `Configuration` per row of its table — and nothing more.
///
/// GRDB is used for what it brings (statement caching, serial queues per connection, WAL pools,
/// migrations, interruption) and for nothing else: no `ValueObservation`, no record types on the
/// list path (4.2, 13.7). It has behaviours the design depends on knowing:
///
/// - **GRDB sets `synchronous = NORMAL` on a WAL database after `prepareDatabase` has run.** A
///   store opened with any configuration reads back `synchronous = 1`, so the intent store's
///   FULL and full fsync are set *after* it is opened, on its connection, and read back
///   (`openIntentQueue(at:)`). `MailStoresTests` pins the trap itself.
/// - `interrupt()` on a pool interrupts every connection of that pool, so search gets a
///   connection of its own.
/// - GRDB advises one object per database file. The search reader attaches `index.sqlite` and
///   `blobs.sqlite`, which pools own, so those files are open on more connections than one
///   object's: ordinary SQLite, and the reason the search reader is read-only.
///
/// **What runs where.** The handles are `internal`, by rule (18.1), so a later package's
/// extension can use them. Nothing here, and nothing built on it, calls a blocking GRDB method
/// from the main thread, and that is checked rather than hoped: opening is guarded, and so is
/// **every statement run on any connection made here** (`MailMainQueueGuard`), because GRDB's
/// `read` and `write` have a blocking form and an `async` one under one spelling, and in a
/// synchronous function on the main actor the blocking one is chosen and compiles. From `async`
/// code the engine uses the `async` ones, which run the closure on the connection's own queue.
/// GRDB's `read` and `write` closures are synchronous, so a transaction cannot be held across a
/// suspension point (invariant 11) — it does not compile. (A snapshot, an observation or a cursor
/// kept past its read could; nothing here uses them, and a source test holds that.)
///
/// **Every connection is made here.** The configuration is private, so a connection made
/// elsewhere would have none of 4.2's settings; a source test refuses `DatabasePool(` and
/// `DatabaseQueue(` in every other file.
struct MailStores: Sendable {

    /// `index.sqlite`: one writer, two readers, 4 MB of page cache each.
    let index: DatabasePool
    /// `blobs.sqlite`: one writer, two readers, 2 MB each. Created with incremental
    /// auto-vacuum so that eviction can give pages back.
    let blobs: DatabasePool
    /// `search.sqlite`, writing: the full-text indexer's one connection, 4 MB.
    let searchWriter: DatabaseQueue
    /// `search.sqlite`, reading: a read-only connection of its own, 8 MB, with `index.sqlite`
    /// attached as `idx` and `blobs.sqlite` as `blobs` — so cancelling a search can never cancel
    /// a list read, and a search can join what it finds to the index.
    let searchReader: DatabaseQueue

    let directories: MailDirectories

    /// What the search reader calls the files it attaches. `idx` is the name 9.2's query uses.
    static let attachedIndexName = "idx"
    static let attachedBlobsName = "blobs"

    // MARK: - Opening

    /// Opens the four stores in `directories`, runs each one's migrations, and refuses a store
    /// that has been migrated by a newer version of the code (`MailStoreError.newerThanThisVersion`:
    /// a cache file that is newer than the code is not opened — it is rebuilt, by the caller).
    /// A store SQLite will not open — not a database, damaged, cannot be made — is refused by name
    /// too (`MailStoreError.cannotOpen(file, code:)`), because 4.10 does a different thing for
    /// each file. Whatever is on disk is left as it was.
    ///
    /// Blocking and not for the main thread: it opens files, may replay a write-ahead log, and
    /// runs migrations. `dispatchPrecondition(condition: .notOnQueue(.main))` says so.
    static func open(_ directories: MailDirectories, migrations: MailMigrations) throws -> MailStores {
        MailMainQueueGuard.requireOffMainQueue("MailStores.open", store: nil)

        let index = try opening(.index) {
            try DatabasePool(path: directories.indexDatabase.path, configuration: configuration(Settings.index))
        }
        try migrate(index, with: migrations.index, file: .index)

        let blobs = try opening(.blobs) {
            try DatabasePool(path: directories.blobsDatabase.path, configuration: configuration(Settings.blobs))
        }
        try migrate(blobs, with: migrations.blobs, file: .blobs)

        let searchWriter = try opening(.search) {
            try DatabaseQueue(path: directories.searchDatabase.path,
                              configuration: configuration(Settings.searchWriter))
        }
        try migrate(searchWriter, with: migrations.search, file: .search)

        // After the writer: a read-only connection cannot create the file it reads.
        let searchReader = try opening(.search) {
            try DatabaseQueue(
                path: directories.searchDatabase.path,
                configuration: configuration(Settings.searchReader, attaching: [
                    Attachment(url: directories.indexDatabase, name: attachedIndexName,
                               cacheKiB: Settings.searchReaderIndexCacheKiB),
                    Attachment(url: directories.blobsDatabase, name: attachedBlobsName,
                               cacheKiB: Settings.searchReaderBlobsCacheKiB),
                ]))
        }

        return MailStores(index: index, blobs: blobs, searchWriter: searchWriter,
                          searchReader: searchReader, directories: directories)
    }

    /// Opens `intent.sqlite`, and sets what makes a commit to it durable.
    ///
    /// **Only `MailIntentStore` (P14a) calls this**, and it keeps what it returns private
    /// (4.8, 18.1): the intent store has no delete, reset or erase. It runs its own migrations on
    /// the queue it is given. The returned queue is the file's only connection — it is a
    /// `DatabaseQueue` and must never be opened as a pool.
    func openIntent() throws -> DatabaseQueue {
        try Self.openIntentQueue(at: directories.intentDatabase)
    }

    /// The intent store's connection at `url`: `openIntent()` for the real file, and the way the
    /// salvage path of 4.10 opens its fresh file, which needs the same settings before its first
    /// row.
    ///
    /// `synchronous = FULL` and `fullfsync = ON` are set in `prepareDatabase` **and again after
    /// opening** — GRDB's own `PRAGMA synchronous = NORMAL` runs between the two — and then read
    /// back: if the connection does not say FULL and full fsync, this throws, rather than hand
    /// out a store whose commits are not what invariant 4 says they are. The second setting is
    /// made outside a transaction (`writeWithoutTransaction`): inside one, SQLite refuses it.
    static func openIntentQueue(at url: URL) throws -> DatabaseQueue {
        MailMainQueueGuard.requireOffMainQueue("MailStores.openIntentQueue", store: .intent)

        return try opening(.intent) {
            let queue = try DatabaseQueue(path: url.path, configuration: configuration(Settings.intent))
            try queue.writeWithoutTransaction { db in
                try makeDurable(db)
                let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous")
                let fullfsync = try Int.fetchOne(db, sql: "PRAGMA fullfsync")
                guard synchronous == Pragmas.synchronousFull, fullfsync == 1 else {
                    throw MailStoreError.notDurable
                }
            }
            return queue
        }
    }

    // MARK: - The settings, one row of 4.2 each

    /// One row of the table in 4.2. Page caches are in KiB, so that the five rows' worst case
    /// adds up to the 31 MB the document states: 3 × 4 + 3 × 2 + 1 + 4 + 8.
    private struct Settings {
        var label: String
        /// Which store the connection is for, named when a statement is run where it should not be.
        var file: MailStoreFile
        var qos: DispatchQoS
        var cacheKiB: Int
        var readers: Int?
        var readonly = false
        var incrementalAutoVacuum = false
        var fullSync = false

        static let index = Settings(label: "mail.index", file: .index, qos: .userInitiated, cacheKiB: 4096, readers: 2)
        // Utility, not userInitiated, as the table says. The table adds that reads for an open
        // conversation are userInitiated; GRDB gives a pool one quality of service, so that
        // elevation is the blob store's to arrange (P07).
        static let blobs = Settings(label: "mail.blobs", file: .blobs, qos: .utility, cacheKiB: 2048, readers: 2,
                                    incrementalAutoVacuum: true)
        static let searchWriter = Settings(label: "mail.search.write", file: .search, qos: .utility, cacheKiB: 4096)
        // 4.2 gives the search reader 8 MB, and the 31 MB of its total is counted with that figure,
        // so the 8 MB is for the whole connection — `search.sqlite` and the two files attached to
        // it, each of which has a cache of its own (`PRAGMA <name>.cache_size`). 4.2 does not say
        // how it is split; 4 + 3 + 1: the full-text index it scans, the index it joins what it
        // finds to, and the bodies it takes an excerpt from.
        static let searchReaderIndexCacheKiB = 3072
        static let searchReaderBlobsCacheKiB = 1024
        static let searchReader = Settings(label: "mail.search.read", file: .search, qos: .userInitiated,
                                           cacheKiB: 4096, readonly: true)
        static let intent = Settings(label: "mail.intent", file: .intent, qos: .userInitiated, cacheKiB: 1024,
                                     fullSync: true)
    }

    private enum Pragmas {
        static let busyTimeoutMilliseconds = 2000
        /// What `PRAGMA synchronous` reads back for FULL.
        static let synchronousFull = 2
    }

    /// A file the search reader attaches, with the cache it is given.
    private struct Attachment {
        var url: URL
        var name: String
        var cacheKiB: Int
    }

    private static func configuration(_ settings: Settings,
                                      attaching files: [Attachment] = []) -> Configuration {
        var configuration = Configuration()
        configuration.label = settings.label
        configuration.qos = settings.qos
        // Relations are kept in code and checked by the repair pass (4.2).
        configuration.foreignKeysEnabled = false
        // Bound values never appear in an error's description (invariant 21). The default, said.
        configuration.publicStatementArguments = false
        configuration.readonly = settings.readonly
        if let readers = settings.readers { configuration.maximumReaderCount = readers }
        // A pool is put in WAL by GRDB; a queue is not, unless told.
        if !settings.readonly { configuration.journalMode = .wal }

        configuration.prepareDatabase { db in
            if !db.configuration.readonly {
                // Before the journal mode: auto_vacuum is fixed by the first page written, and
                // WAL's first write is that page.
                if settings.incrementalAutoVacuum {
                    try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                }
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            // GRDB gives a pool's readers a ten-second busy timeout of its own; this says two,
            // for every connection, as 4.2 does.
            try db.execute(sql: "PRAGMA busy_timeout = \(Pragmas.busyTimeoutMilliseconds)")
            try db.execute(sql: "PRAGMA cache_size = -\(settings.cacheKiB)")
            if !db.configuration.readonly {
                // Checkpoints are the writer's, between pieces of work (invariant 12).
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
                // So that the log's file is as long as what the log holds: when a checkpoint has
                // copied the log back and SQLite starts it again, the file is cut to this. It is
                // what makes "the log holds more than 8 MiB" mean "the file is longer than 8 MiB"
                // (4.2). SQLite's own default is a compile-time 32 KB that nobody promised.
                try db.execute(sql: "PRAGMA journal_size_limit = \(MailKnobs.checkpointOverBytes)")
                if !settings.fullSync {
                    // A cache store is `synchronous = NORMAL`, which syncs the log when it is
                    // checkpointed; this makes that sync a full one, so the log is on the disk
                    // before its pages are copied back and a power cut cannot lose both.
                    try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
                }
            }
            if settings.fullSync {
                // Set here as 4.2 says; GRDB sets NORMAL again straight after, and
                // `openIntentQueue` sets this a second time.
                try makeDurable(db)
            }
            for file in files {
                // The attached file is opened the way the connection is: read-only, here. A
                // pragma without a schema name speaks of `main` only, so each attached file's
                // cache is set by its own name.
                try db.execute(sql: "ATTACH DATABASE ? AS \(file.name)", arguments: [file.url.path])
                try db.execute(sql: "PRAGMA \(file.name).cache_size = -\(file.cacheKiB)")
            }
            // Last, so that nothing above is traced: invariant 10 on every connection that can
            // exist, the readers a pool makes later included. A statement run on the main thread
            // is a violation, whichever way the handle was reached — and what a violation does is
            // `MailMainQueueGuard`'s to say. **One trace is all SQLite keeps per connection**: a
            // later `db.trace(…)` — for timing, say — would replace this one silently, and nothing
            // would then guard that connection. A source test refuses `.trace(` anywhere else.
            let file = settings.file
            db.trace(options: .statement) { _ in
                MailMainQueueGuard.requireOffMainQueue("a statement", store: file)
            }
        }
        return configuration
    }

    private static func makeDurable(_ db: Database) throws {
        try db.execute(sql: "PRAGMA synchronous = FULL")
        try db.execute(sql: "PRAGMA fullfsync = ON")
    }

    /// Runs `migrator` on `writer` — after refusing a file that has been migrated by a newer
    /// migrator than this one (`hasBeenSuperseded`: it knows a step this one does not). Internal,
    /// so that `MailIntentStore` (P14a) refuses a newer `intent.sqlite` by the same test and does
    /// not write it again.
    static func migrate(_ writer: some DatabaseWriter,
                        with migrator: DatabaseMigrator,
                        file: MailStoreFile) throws {
        try opening(file) {
            let superseded = try writer.read { try migrator.hasBeenSuperseded($0) }
            if superseded { throw MailStoreError.newerThanThisVersion(file) }
            try migrator.migrate(writer)
        }
    }

    /// Runs one store's opening, and says which store it was if SQLite refuses: 4.10 does a
    /// different thing for each file (the intent store is never reset; a derived store is
    /// rebuilt), and `open` opens all four in one call.
    private static func opening<T>(_ file: MailStoreFile, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DatabaseError {
            throw MailStoreError.cannotOpen(file, code: error.resultCode)
        }
    }
}

/// The migrations of the three cache stores, one migrator each. Built by whoever opens: a test
/// builds what it needs, and the engine asks `MailSlices.migrations()`. `intent.sqlite`'s are
/// registered inside `MailIntentStore` (P14a), which nothing else opens.
struct MailMigrations {
    var index = DatabaseMigrator()
    var blobs = DatabaseMigrator()
    var search = DatabaseMigrator()
}

/// The four files, by the name a journal line gives them.
enum MailStoreFile: String, MailJournalCode {
    case index, blobs, search, intent
}

/// Why a store would not open for use. Says which file and nothing of what is in it.
enum MailStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file has been migrated by a newer version of the code than this one. A cache file is
    /// rebuilt; `intent.sqlite` is never reset, and mail is read-only until the app is updated
    /// (4.9).
    case newerThanThisVersion(MailStoreFile)
    /// The intent connection does not read back as FULL with full fsync.
    case notDurable
    /// SQLite refused to open the file, or to migrate it: not a database, damaged, cannot be
    /// made, no permission. The file and SQLite's result code (`.SQLITE_NOTADB`,
    /// `.SQLITE_CORRUPT`, …), and nothing of the message, which can carry what the file holds.
    /// The file is left as it was.
    case cannotOpen(MailStoreFile, code: ResultCode)

    var description: String {
        switch self {
        case .newerThanThisVersion(let file): return "MailStoreError.newerThanThisVersion(\(file.rawValue))"
        case .notDurable: return "MailStoreError.notDurable"
        case .cannotOpen(let file, let code): return "MailStoreError.cannotOpen(\(file.rawValue), \(code.rawValue))"
        }
    }
}

/// Invariant 10: the main thread does no SQLite.
///
/// Where it is required: the two ways of opening a store; **every statement run on any
/// connection `MailStores` makes** (a trace callback set in each connection's `prepareDatabase`,
/// so a blocking `read` from a synchronous function on the main actor is stopped too, which the
/// compiler does not prevent); the disk watch's read of the free space. Files are guarded where
/// they are made, through `MailFileAttributes.requireOffMain`.
///
/// **What it costs.** `requireOffMainQueue` is a thread check and nothing else — one call to
/// `pthread_main_np`, no lock, no handler load, no string — and runs once per SQL statement. The
/// lock, the handler and everything below are reached only by a call that has already failed.
///
/// **What a violation does** is a decision, not a default:
///
/// - **In Debug, and so in the unit tests: it traps** (`dispatchPrecondition(condition:
///   .notOnQueue(.main))` and a precondition on the thread, which a block run by the main thread
///   inside a database queue's `sync` would not trip the first of). A bug is found where it is
///   made.
/// - **In Release: it does not crash the app.** This is a performance rule — a hitch on the main
///   thread — not a data-safety one, and a mail bug must not be able to crash the app its owner
///   uses every day for his calendar. It is recorded **once per call site and store** in the
///   diagnostic journal — a line of the `store` event naming the store, the call site and a
///   count, never the SQL (invariant 21: a statement can carry what he wrote) — counted every
///   time after that, and the work goes on.
///
/// The journal is handed in at wiring (`use(journal:)`, P23a); until then it is silent.
///
/// A trap cannot be asserted on, so two seams exist for tests: `replaceForTesting` puts a handler
/// in place of the whole policy, and `setPolicyForTesting` chooses the policy and the journal —
/// which is how the Release behaviour is driven without a Release build.
enum MailMainQueueGuard {

    enum Policy: Equatable, Sendable {
        /// Stop the process where the violation is.
        case trap
        /// Record it once per call site and store, and carry on.
        case reportAndContinue
    }

    /// The policy of this build: trap in Debug, report and continue in Release.
    static let defaultPolicy: Policy = {
        #if DEBUG
        return .trap
        #else
        return .reportAndContinue
        #endif
    }()

    private static let lock = NSLock()
    private static var override: ((StaticString) -> Void)?
    private static var policy = defaultPolicy
    private static var journal = MailJournal.silent
    private static var counts: [String: Int] = [:]

    /// Requires that the caller is not on the main thread. `what` names the entry point; `store`
    /// the store, where there is one.
    ///
    /// The thread check is all that a call from the right thread costs; see the type's comment.
    static func requireOffMainQueue(_ what: StaticString, store: MailStoreFile?) {
        guard pthread_main_np() != 0 else { return }
        violated(what, store: store)
    }

    /// Where the journal lines of a violation go. Called once, at wiring.
    static func use(journal: MailJournal) {
        lock.lock(); defer { lock.unlock() }
        self.journal = journal
    }

    /// How many times `what` has been run on the main thread for `store` since the policy was
    /// last set, when the policy has been to continue. For the journal's minute line, and tests.
    static func violationCount(_ what: StaticString, store: MailStoreFile?) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key(what, store)] ?? 0
    }

    // MARK: - After a failed check

    private static func violated(_ what: StaticString, store: MailStoreFile?) {
        lock.lock()
        let replaced = override
        let current = policy
        lock.unlock()

        if let replaced { replaced(what); return }
        switch current {
        case .trap:
            dispatchPrecondition(condition: .notOnQueue(.main))
            preconditionFailure("mail's SQLite is not for the main thread (invariant 10): \(what)")
        case .reportAndContinue:
            record(what, store: store)
        }
    }

    private static func record(_ what: StaticString, store: MailStoreFile?) {
        lock.lock()
        let name = key(what, store)
        let seen = (counts[name] ?? 0) + 1
        counts[name] = seen
        let line = journal.line
        lock.unlock()

        guard seen == 1 else { return }
        var fields: [MailJournalField] = [.code("event", MailGuardViolation.onMainThread), .flag(what, true), .count("calls", seen)]
        if let store { fields.insert(.code("file", store), at: 0) }
        line(.store, fields)
    }

    private static func key(_ what: StaticString, _ store: MailStoreFile?) -> String {
        "\(what)|\(store?.rawValue ?? "")"
    }

    // MARK: - For tests

    /// What is done in place of the whole policy, so that a call from the main thread can be seen
    /// to reach it without ending the test run. Pass nil to put the policy back.
    static func replaceForTesting(_ replacement: ((StaticString) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        override = replacement
    }

    /// Chooses the policy and the journal, and forgets every count — to drive the Release
    /// behaviour in a Debug build.
    static func setPolicyForTesting(_ policy: Policy, journal: MailJournal) {
        lock.lock(); defer { lock.unlock() }
        self.policy = policy
        self.journal = journal
        counts = [:]
    }

    /// Back to what the build does: no replacement, the build's policy, a silent journal.
    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        override = nil
        policy = defaultPolicy
        journal = .silent
        counts = [:]
    }
}

/// What the `store` journal line says happened, when the guard saw SQLite or a file run where it
/// should not (a closed enum, so that the line has nowhere to put anything else).
enum MailGuardViolation: String, MailJournalCode {
    case onMainThread
}

#endif
