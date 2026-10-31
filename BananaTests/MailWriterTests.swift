import XCTest
import GRDB

/// The one writer's queue: group commit, what happens to a piece that fails, what the sink is
/// told, and when the log is checkpointed.
///
/// The risks it guards are quiet ones. A burst of changes that commits once each instead of once
/// for what arrived (the full fsync is paid per commit, not per change). A failed intent step
/// that still writes the index, so that a change shows and survives a relaunch without ever
/// having been durable. A sink told of a transaction that rolled back. A log that is never
/// checkpointed because "idle" never comes, or one checkpointed after every piece because its
/// file never shrinks.
///
/// Nothing here depends on how long anything takes. Where a test needs the writer to be in the
/// middle of a commit it makes the commit wait for it (`MailTestGate`), and where it needs the
/// writer to have finished it sends a piece of work through and waits for that.
final class MailWriterTests: MailStoreTestCase {

    // MARK: - The test's end of the writer

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
        func clear() { lock.lock(); events = []; lock.unlock() }
    }

    /// A piece of work whose every step is the test's to script.
    private final class Piece: MailWriterWork, @unchecked Sendable {
        let name: String
        let log: EventLog?
        private let lock = NSLock()

        /// Whether this piece folds the next one into itself.
        var absorbsNext = false
        var intentStep: (() throws -> Void)?
        var indexStep: ((Database) throws -> MailStoreChange)?
        var onFailed: ((Error) -> Void)?
        var onAbsorb: (() -> Void)?

        private var absorbedPieces: [Piece] = []
        private var intents = 0, indexes = 0
        private var failures: [Error] = []
        private var intentOnWriterQueue: [Bool] = []
        private var failedOnQueue: [Bool] = []

        init(_ name: String, log: EventLog? = nil, absorbs: Bool = false) {
            self.name = name; self.log = log; self.absorbsNext = absorbs
        }

        var absorbed: [Piece] { lock.lock(); defer { lock.unlock() }; return absorbedPieces }
        var intentCalls: Int { lock.lock(); defer { lock.unlock() }; return intents }
        var indexCalls: Int { lock.lock(); defer { lock.unlock() }; return indexes }
        var failed: [Error] { lock.lock(); defer { lock.unlock() }; return failures }
        var intentRanOnWriterQueue: [Bool] { lock.lock(); defer { lock.unlock() }; return intentOnWriterQueue }
        var failedRanOnWriterQueue: [Bool] { lock.lock(); defer { lock.unlock() }; return failedOnQueue }

        func absorb(_ next: MailWriterWork) -> Bool {
            guard absorbsNext, let next = next as? Piece else { return false }
            lock.lock(); absorbedPieces.append(next); lock.unlock()
            log?.add("\(name) absorbs \(next.name)")
            onAbsorb?()
            return true
        }

        func writeIntent() throws {
            lock.lock(); intents += 1; intentOnWriterQueue.append(MailWriter.isOnWriterQueue); lock.unlock()
            log?.add("\(name) intent")
            try intentStep?()
        }

        func writeIndex(_ db: Database) throws -> MailStoreChange {
            lock.lock(); indexes += 1; lock.unlock()
            log?.add("\(name) index")
            return try indexStep?(db) ?? MailStoreChange()
        }

        func failed(_ error: Error) {
            lock.lock(); failures.append(error); failedOnQueue.append(MailWriter.isOnWriterQueue); lock.unlock()
            log?.add("\(name) failed")
            onFailed?(error)
        }
    }

    /// A log the writer is asked to look after, which records when it is asked.
    private final class KeptLog: MailWriterLog, @unchecked Sendable {
        let name: String
        let log: EventLog
        private let lock = NSLock()
        private var onQueue: [Bool] = []
        var onTruncate: (() -> Void)?
        init(_ name: String = "kept", log: EventLog) { self.name = name; self.log = log }
        var askedOnWriterQueue: [Bool] { lock.lock(); defer { lock.unlock() }; return onQueue }
        func checkpointIfDue() {
            lock.lock(); onQueue.append(MailWriter.isOnWriterQueue); lock.unlock()
            log.add("\(name) asked")
        }
        func truncateCheckpoint() {
            log.add("\(name) truncated")
            onTruncate?()
        }
    }

    private final class Sink: MailChangeSink, @unchecked Sendable {
        private let lock = NSLock()
        private var told: [MailStoreChange] = []
        private var queues: [Bool] = []
        var onCommitted: ((MailStoreChange) -> Void)?
        var changes: [MailStoreChange] { lock.lock(); defer { lock.unlock() }; return told }
        var onWriterQueue: [Bool] { lock.lock(); defer { lock.unlock() }; return queues }
        func committed(_ change: MailStoreChange) {
            lock.lock(); told.append(change); queues.append(MailWriter.isOnWriterQueue); lock.unlock()
            onCommitted?(change)
        }
    }

    private struct Boom: Error, Equatable { let n: Int }

    /// A migrator with a table `t(id)` and a table `big(x)`.
    private func migrations() -> MailMigrations {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "t") { $0.column("id", .integer).primaryKey() }
            try db.create(table: "big") { $0.column("x", .blob) }
        }
        return MailMigrations(index: migrator)
    }

    private func makeWriter(sink: MailChangeSink? = nil) async throws -> (MailStores, MailWriter) {
        let stores = try await openStores(migrations: migrations())
        return (stores, MailWriter(stores: stores, sink: sink))
    }

    /// Returns once the writer has run everything submitted before this call. Fails the test, and
    /// returns, if it has not in thirty seconds, so that a writer that has forgotten the wake-up
    /// for this very call fails a test instead of hanging it.
    private func settle(_ writer: MailWriter) async throws {
        let done = MailTestGate("the writer to run everything submitted before the test settled", limit: 30)
        writer.submit(task: { done.open() })
        await done.waitAsync()
    }

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Group commit

    /// Submits a piece that is in the middle of its commit, and returns the gate that lets it go.
    private func holdTheWriter(_ writer: MailWriter) async -> (Piece, release: MailTestGate) {
        let started = MailTestGate("the slow piece to begin"), release = MailTestGate("the test to let it go")
        let slow = Piece("slow")
        slow.intentStep = { started.open(); release.waitBlocking() }
        writer.submit(slow)
        await started.waitAsync()
        return (slow, release)
    }

    func testThirtySubmissionsMadeDuringOneSlowCommitRunAsOnePieceWhenEachAbsorbsTheNext() async throws {
        let (_, writer) = try await makeWriter()
        let (slow, release) = await holdTheWriter(writer)

        let rest = (1...30).map { Piece("p\($0)", absorbs: true) }
        rest.forEach(writer.submit)
        release.open()
        try await settle(writer)

        XCTAssertEqual(slow.indexCalls, 1)
        XCTAssertEqual(rest[0].intentCalls, 1)
        XCTAssertEqual(rest[0].indexCalls, 1, "the first of them carries the other twenty-nine")
        XCTAssertEqual(rest[0].absorbed.count, 29)
        for piece in rest.dropFirst() {
            XCTAssertEqual(piece.intentCalls, 0, "\(piece.name) ran on its own, but had been folded in")
            XCTAssertEqual(piece.indexCalls, 0, piece.name)
        }
    }

    func testThirtySubmissionsMadeDuringOneSlowCommitRunAsThirtyWhenNoneAbsorbs() async throws {
        let (_, writer) = try await makeWriter()
        let (slow, release) = await holdTheWriter(writer)

        let rest = (1...30).map { Piece("p\($0)") }
        rest.forEach(writer.submit)
        release.open()
        try await settle(writer)

        XCTAssertEqual(slow.indexCalls, 1)
        for piece in rest {
            XCTAssertEqual(piece.intentCalls, 1, piece.name)
            XCTAssertEqual(piece.indexCalls, 1, piece.name)
            XCTAssertTrue(piece.absorbed.isEmpty)
        }
    }

    func testAPieceThatRefusesTheNextRunsAloneAndTheNextBecomesTheHeadOfWhatFollows() async throws {
        let (_, writer) = try await makeWriter()
        let (_, release) = await holdTheWriter(writer)

        let a = Piece("a", absorbs: false), b = Piece("b", absorbs: true)
        let c = Piece("c"), d = Piece("d")
        [a, b, c, d].forEach(writer.submit)
        release.open()
        try await settle(writer)

        XCTAssertEqual(a.indexCalls, 1, "a refused b, so a is a commit of its own")
        XCTAssertTrue(a.absorbed.isEmpty)
        XCTAssertEqual(b.indexCalls, 1)
        XCTAssertEqual(b.absorbed.map(\.name), ["c", "d"], "b then took what followed it")
        XCTAssertEqual([c, d].map(\.indexCalls), [0, 0])
    }

    func testPiecesBeforeAndAfterPerformedWorkAreNotFoldedAcrossIt() async throws {
        let (_, writer) = try await makeWriter()
        let log = EventLog()
        let started = MailTestGate(), release = MailTestGate()
        let slow = Piece("slow", log: log)
        slow.intentStep = { started.open(); release.waitBlocking() }
        writer.submit(slow)
        await started.waitAsync()

        let p1 = Piece("p1", log: log, absorbs: true), p2 = Piece("p2", log: log)
        let p3 = Piece("p3", log: log, absorbs: true), p4 = Piece("p4", log: log)
        writer.submit(p1); writer.submit(p2)
        writer.submit(task: { log.add("task") })
        writer.submit(p3); writer.submit(p4)
        release.open()
        try await settle(writer)

        XCTAssertEqual(log.all, [
            "slow intent", "slow index",
            "p1 absorbs p2", "p1 intent", "p1 index",
            "task",
            "p3 absorbs p4", "p3 intent", "p3 index",
        ], "work runs in the order it was handed over, and a task ends a run of pieces that could have been one")
    }

    // MARK: - A piece that fails

    func testAPieceWhoseIntentStepThrowsRunsNoIndexStepIsToldFailedAndTheNextPieceRuns() async throws {
        let (stores, writer) = try await makeWriter()
        let bad = Piece("bad"), good = Piece("good")
        bad.intentStep = { throw Boom(n: 1) }
        // If the index step ran it would leave this row behind.
        bad.indexStep = { db in try db.execute(sql: "INSERT INTO t VALUES (100)"); return MailStoreChange() }
        good.indexStep = { db in try db.execute(sql: "INSERT INTO t VALUES (200)"); return MailStoreChange() }

        writer.submit(bad); writer.submit(good)
        try await settle(writer)

        XCTAssertEqual(bad.intentCalls, 1)
        XCTAssertEqual(bad.indexCalls, 0, "nothing reaches the index that is not in intent.sqlite (6.2)")
        XCTAssertEqual(bad.failed.count, 1)
        XCTAssertEqual(bad.failed.first as? Boom, Boom(n: 1))
        XCTAssertEqual(good.indexCalls, 1)
        XCTAssertTrue(good.failed.isEmpty)
        let rows = try await stores.index.read { try Int.fetchAll($0, sql: "SELECT id FROM t ORDER BY id") }
        XCTAssertEqual(rows, [200])
    }

    func testAPieceWhoseIndexStepThrowsIsRolledBackToldFailedAndNotAnnounced() async throws {
        let sink = Sink()
        let (stores, writer) = try await makeWriter(sink: sink)
        let bad = Piece("bad"), good = Piece("good")
        bad.indexStep = { db in
            try db.execute(sql: "INSERT INTO t VALUES (100)")
            throw Boom(n: 2)
        }
        good.indexStep = { _ in MailStoreChange(through: 7) }

        writer.submit(bad); writer.submit(good)
        try await settle(writer)

        XCTAssertEqual(bad.intentCalls, 1, "its intent step had already happened: the change is durable and will be delivered")
        XCTAssertEqual(bad.failed.first as? Boom, Boom(n: 2))
        let rows = try await stores.index.read { try Int.fetchAll($0, sql: "SELECT id FROM t") }
        XCTAssertEqual(rows, [], "the half-written index transaction was rolled back")
        XCTAssertEqual(sink.changes, [MailStoreChange(through: 7)], "a rolled-back transaction never announces itself")
    }

    // MARK: - What the sink is told

    func testTheSinkIsToldOnceAfterEachCommitOnTheWritersQueueAndMayReadWhatWasWritten() async throws {
        let sink = Sink()
        let (stores, writer) = try await makeWriter(sink: sink)
        let conversation = MailConversationID(account: "me@example.com", thread: "t1")
        let readByTheSink = MailTestList<[Int]>()
        sink.onCommitted = { _ in
            // After the commit: a read finds the row, and it does not deadlock the writer.
            let ids = (try? stores.index.read { try Int.fetchAll($0, sql: "SELECT id FROM t ORDER BY id") }) ?? []
            readByTheSink.add(ids)
        }

        let first = Piece("first"), second = Piece("second")
        first.indexStep = { db in
            try db.execute(sql: "INSERT INTO t VALUES (1)")
            return MailStoreChange(viewKeys: ["inbox"], conversations: [conversation], through: 11)
        }
        second.indexStep = { db in
            try db.execute(sql: "INSERT INTO t VALUES (2)")
            return MailStoreChange(labelsChanged: true, through: 12)
        }
        writer.submit(first); writer.submit(second)
        try await settle(writer)

        XCTAssertEqual(sink.changes, [
            MailStoreChange(viewKeys: ["inbox"], conversations: [conversation], through: 11),
            MailStoreChange(labelsChanged: true, through: 12),
        ])
        XCTAssertEqual(sink.onWriterQueue, [true, true])
        XCTAssertEqual(readByTheSink.all, [[1], [1, 2]])
    }

    func testAPieceThatWritesNothingStillAnnouncesTheSequenceItCarried() async throws {
        // A change to a message already in that state touches no row, and the list that is
        // waiting to drop its optimistic copy needs to hear that it was seen (6.2).
        let sink = Sink()
        let (_, writer) = try await makeWriter(sink: sink)
        let piece = Piece("nothing")
        piece.indexStep = { _ in MailStoreChange(through: 99) }
        writer.submit(piece)
        try await settle(writer)
        XCTAssertEqual(sink.changes.map(\.through), [99])
    }

    func testTheIntentStepRunsOnTheWritersQueueBeforeTheIndexStepOfTheSamePiece() async throws {
        let log = EventLog()
        let (_, writer) = try await makeWriter()
        let a = Piece("a", log: log), b = Piece("b", log: log)
        writer.submit(a); writer.submit(b)
        try await settle(writer)
        XCTAssertEqual(log.all, ["a intent", "a index", "b intent", "b index"])
        XCTAssertEqual(a.intentRanOnWriterQueue, [true])
        XCTAssertEqual(b.intentRanOnWriterQueue, [true])
        XCTAssertFalse(MailWriter.isOnWriterQueue, "the test is not on the writer's queue")
    }

    func testSubmitReturnsAtOnceEvenWhileACommitIsInProgress() async throws {
        let (_, writer) = try await makeWriter()
        let (slow, release) = await holdTheWriter(writer)
        // The writer is inside a commit that cannot finish until the gate is opened. These
        // return all the same: if either waited for the commit, this test could not get past
        // them to open it.
        let waiting = Piece("waiting")
        writer.submit(waiting)
        XCTAssertEqual(slow.indexCalls, 0)
        XCTAssertEqual(waiting.intentCalls, 0)
        release.open()
        try await settle(writer)
        XCTAssertEqual(waiting.indexCalls, 1)
    }

    func testPerformRunsOnTheWritersQueueReturnsWhatItReturnsAndRethrows() async throws {
        let (_, writer) = try await makeWriter()
        let onQueue = try await writer.perform { MailWriter.isOnWriterQueue }
        XCTAssertTrue(onQueue)
        let value = try await writer.perform { 6 * 7 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await writer.perform { throw Boom(n: 3) as Error }
            XCTFail("an error thrown by the work must reach the caller")
        } catch {
            XCTAssertEqual(error as? Boom, Boom(n: 3))
        }
        // And the writer is still there afterwards.
        let after = try await writer.perform { 1 }
        XCTAssertEqual(after, 1)
    }

    func testAStoreChangeUnitesWhatTwoTransactionsTouched() {
        var change = MailStoreChange(viewKeys: ["inbox"],
                                     conversations: [MailConversationID(account: "a@x.com", thread: "1")],
                                     labelsChanged: false, through: 5)
        change.formUnion(MailStoreChange(viewKeys: ["starred"],
                                         conversations: [MailConversationID(account: "a@x.com", thread: "2")],
                                         labelsChanged: true, through: 3))
        XCTAssertEqual(change.viewKeys, ["inbox", "starred"])
        XCTAssertEqual(change.conversations.count, 2)
        XCTAssertTrue(change.labelsChanged)
        XCTAssertEqual(change.through, 5, "the highest sequence carried")
        XCTAssertEqual(MailStoreChange(), MailStoreChange(viewKeys: [], conversations: [], labelsChanged: false, through: 0))
    }

    // MARK: - Checkpoints

    private func heavyPiece(megabytes: Int) -> Piece {
        let piece = Piece("heavy\(megabytes)")
        piece.indexStep = { db in
            try db.execute(sql: "INSERT INTO big VALUES (zeroblob(?))", arguments: [megabytes * 1_048_576])
            return MailStoreChange()
        }
        return piece
    }

    func testALogOverEightMegabytesIsCheckpointedBeforeTheNextPieceAndAShortOneIsNot() async throws {
        let (stores, writer) = try await makeWriter()
        let database = stores.directories.indexDatabase

        writer.submit(heavyPiece(megabytes: 4))
        try await settle(writer)
        var run = try await writer.perform { writer.passiveCheckpointsRun }
        XCTAssertEqual(run, 0, "four megabytes of log is not over eight")
        XCTAssertLessThan(fileSize(database), 1_000_000, "auto-checkpoint is off: nothing has been copied back")

        writer.submit(heavyPiece(megabytes: 6))      // ten in the log now
        try await settle(writer)
        run = try await writer.perform { writer.passiveCheckpointsRun }
        XCTAssertEqual(run, 1)
        XCTAssertGreaterThan(fileSize(database), 9_000_000, "the log has been copied back into the database file")
    }

    func testAfterACheckpointTheLogIsNotCheckpointedAgainUntilItOutgrowsItself() async throws {
        // A PASSIVE checkpoint copies the log back and does not shorten the file; it is cut to
        // 8 MiB when the log next restarts (`journal_size_limit`). In between, and after, small
        // commits are not a reason to checkpoint — two fsyncs each — and a log is due again only
        // when it holds more than 8 MiB again.
        let (_, writer) = try await makeWriter()
        writer.submit(heavyPiece(megabytes: 9))
        try await settle(writer)
        var run = try await writer.perform { writer.passiveCheckpointsRun }
        XCTAssertEqual(run, 1)

        for id in 1...25 {
            let small = Piece("small\(id)")
            small.indexStep = { db in try db.execute(sql: "INSERT INTO t VALUES (?)", arguments: [id]); return MailStoreChange() }
            writer.submit(small)
            try await settle(writer)
        }
        run = try await writer.perform { writer.passiveCheckpointsRun }
        XCTAssertEqual(run, 1, "twenty-five small commits are not a reason to checkpoint")

        writer.submit(heavyPiece(megabytes: 14))     // the log holds more than 8 MiB again
        try await settle(writer)
        run = try await writer.perform { writer.passiveCheckpointsRun }
        XCTAssertEqual(run, 2)
    }

    /// MEASURED here, on this host's SQLite — whichever the Simulator is running — because the
    /// rule of 4.2 stands on a behaviour the SQLite documentation promises and nothing here had
    /// seen: that with `journal_size_limit` set, a log that has been checkpointed and is then
    /// written to once more is cut back to that length. If this fails the rule needs another
    /// measure, and that is a design question, not an adjustment.
    func testALogGrownToTwelveMegabytesAndCheckpointedIsCutToEightMebibytesByTheNextWrite() async throws {
        let (stores, writer) = try await makeWriter()
        let log = URL(fileURLWithPath: stores.directories.indexDatabase.path + "-wal")

        writer.submit(heavyPiece(megabytes: 12))
        try await settle(writer)
        var run = try await writer.perform { writer.passiveCheckpointsRun }
        XCTAssertEqual(run, 1, "twelve megabytes is over eight")
        XCTAssertGreaterThan(fileSize(log), 12 * 1_048_576, "a PASSIVE checkpoint does not shorten the file")
        print("mail-checkpoint log after the 12 MiB checkpoint: \(fileSize(log)) bytes")

        let small = Piece("small")
        small.indexStep = { db in try db.execute(sql: "INSERT INTO t VALUES (1)"); return MailStoreChange() }
        writer.submit(small)
        try await settle(writer)
        print("mail-checkpoint log after one more write: \(fileSize(log)) bytes")
        XCTAssertEqual(fileSize(log), Int(MailKnobs.checkpointOverBytes),
                       "the file was not cut to journal_size_limit when the log restarted")
        run = try await writer.perform { writer.passiveCheckpointsRun }
        XCTAssertEqual(run, 1, "and a log of exactly 8 MiB is not over it: no further checkpoint")

        // Until it holds more than that again.
        writer.submit(heavyPiece(megabytes: 9))
        try await settle(writer)
        run = try await writer.perform { writer.passiveCheckpointsRun }
        XCTAssertEqual(run, 2)
    }

    func testTheStandingMarkComesDownWithTheFile() {
        let limit = MailKnobs.checkpointOverBytes
        let twelve = 12 * 1_048_576 as Int64
        XCTAssertEqual(MailCheckpointRule.clamped(standing: twelve, logBytes: limit), limit,
                       "the file was cut to 8 MiB: the mark comes down to it")
        XCTAssertEqual(MailCheckpointRule.clamped(standing: 5, logBytes: limit), 5, "never raised")
        XCTAssertEqual(MailCheckpointRule.clamped(standing: 0, logBytes: twelve), 0)
        // So after the cut, a log that grows to just over the limit is due, as it must be.
        let standing = MailCheckpointRule.clamped(standing: twelve, logBytes: limit)
        XCTAssertTrue(MailCheckpointRule.isDue(logBytes: limit + 4096, standing: standing))
        XCTAssertFalse(MailCheckpointRule.isDue(logBytes: limit, standing: standing))
    }

    func testTheCheckpointRuleIsDueOnlyOverTheLimitAndOverWhatTheLastCheckpointLeft() {
        let limit = MailKnobs.checkpointOverBytes
        XCTAssertFalse(MailCheckpointRule.isDue(logBytes: limit - 1, standing: 0))
        XCTAssertFalse(MailCheckpointRule.isDue(logBytes: limit, standing: 0), "over eight megabytes, not at")
        XCTAssertTrue(MailCheckpointRule.isDue(logBytes: limit + 1, standing: 0))
        let left = 12 * 1_048_576 as Int64
        XCTAssertFalse(MailCheckpointRule.isDue(logBytes: left, standing: left))
        XCTAssertFalse(MailCheckpointRule.isDue(logBytes: left - 4096, standing: left))
        XCTAssertTrue(MailCheckpointRule.isDue(logBytes: left + 1, standing: left))
        XCTAssertTrue(MailCheckpointRule.isDue(logBytes: limit + 1, standing: limit - 100),
                      "a checkpoint that left the file under the limit leaves nothing to outgrow but the limit")
    }

    func testTruncateCheckpointEmptiesTheIndexLogAndStartsTheCountAgain() async throws {
        let (stores, writer) = try await makeWriter()
        let log = URL(fileURLWithPath: stores.directories.indexDatabase.path + "-wal")

        writer.submit(heavyPiece(megabytes: 3))
        try await settle(writer)
        XCTAssertGreaterThan(fileSize(log), 3_000_000)

        await writer.truncateCheckpoint()
        XCTAssertEqual(fileSize(log), 0, "the log was copied back and the file emptied")
        let rows = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT length(x) FROM big") }
        XCTAssertEqual(rows, 3 * 1_048_576, "and nothing was lost")
    }

    // MARK: - A checkpoint a reader holds up

    func testACheckpointThatAReaderHeldUpLeavesTheLogDueUntilTheReaderLetsGo() async throws {
        let (stores, writer) = try await makeWriter()

        // A reader that has seen the database and then stays — its snapshot stops the log from
        // being copied back past what it can see.
        let readerHolds = MailTestGate("the reader to hold its snapshot")
        let letReaderGo = MailTestGate("the test to let the reader go")
        let reader = Task {
            try await stores.index.read { db -> Int in
                let seen = try Int.fetchOne(db, sql: "SELECT count(*) FROM t") ?? -1
                readerHolds.open()
                letReaderGo.waitBlocking()
                return seen
            }
        }
        await readerHolds.waitAsync()

        func small(_ id: Int) -> Piece {
            let piece = Piece("small\(id)")
            piece.indexStep = { db in try db.execute(sql: "INSERT INTO t VALUES (?)", arguments: [id]); return MailStoreChange() }
            return piece
        }
        func checkpoints() async throws -> Int { try await writer.perform { writer.passiveCheckpointsRun } }

        writer.submit(heavyPiece(megabytes: 9))
        try await settle(writer)
        let afterHeavy = try await checkpoints()
        XCTAssertEqual(afterHeavy, 1, "the log held more than 8 MiB")

        // The checkpoint could not copy it all: the reader still needs what it has not.
        writer.submit(small(1)); try await settle(writer)
        let whileHeld = try await checkpoints()
        XCTAssertEqual(whileHeld, 2, "the log is still due, and is tried again")

        letReaderGo.open()
        _ = try await reader.value
        writer.submit(small(2)); try await settle(writer)
        let afterRelease = try await checkpoints()
        XCTAssertEqual(afterRelease, 3, "now it can all be copied back")

        writer.submit(small(3)); try await settle(writer)
        let afterwards = try await checkpoints()
        XCTAssertEqual(afterwards, 3, "and it is not due again")
    }

    // MARK: - Logs the writer keeps

    func testAKeptLogIsAskedAfterEachPieceOnTheWritersQueueNeverBetweenItsTwoSteps() async throws {
        let (_, writer) = try await makeWriter()
        let events = EventLog()
        let kept = KeptLog(log: events)
        writer.keep(kept)

        writer.submit(Piece("a", log: events)); writer.submit(Piece("b", log: events))
        try await settle(writer)

        XCTAssertEqual(events.all, ["a intent", "a index", "kept asked", "b intent", "b index", "kept asked"])
        XCTAssertEqual(kept.askedOnWriterQueue, [true, true])
    }

    func testAKeptLogIsAskedAfterAPieceThatFailedToo() async throws {
        // A piece whose index step failed has still written intent; an index that keeps refusing
        // (a full disk) must not leave the intent log growing with nobody looking.
        let (_, writer) = try await makeWriter()
        let events = EventLog()
        let kept = KeptLog(log: events)
        writer.keep(kept)

        let intentFails = Piece("p1", log: events), indexFails = Piece("p2", log: events)
        intentFails.intentStep = { throw Boom(n: 1) }
        indexFails.indexStep = { _ in throw Boom(n: 2) }
        writer.submit(intentFails); writer.submit(indexFails)
        try await settle(writer)

        XCTAssertEqual(events.all, [
            "p1 intent", "p1 failed", "kept asked",
            "p2 intent", "p2 index", "p2 failed", "kept asked",
        ])
    }

    func testTruncateCheckpointEmptiesEachKeptLogAfterTheIndexsOwn() async throws {
        let (stores, writer) = try await makeWriter()
        let events = EventLog()
        let first = KeptLog("first", log: events), second = KeptLog("second", log: events)
        let indexLog = URL(fileURLWithPath: stores.directories.indexDatabase.path + "-wal")
        let sizeWhenAsked = MailTestList<Int>()
        let onQueue = MailTestList<Bool>()
        first.onTruncate = { sizeWhenAsked.add(self.fileSize(indexLog)); onQueue.add(MailWriter.isOnWriterQueue) }
        writer.keep(first); writer.keep(second)

        writer.submit(heavyPiece(megabytes: 3))
        try await settle(writer)
        XCTAssertGreaterThan(fileSize(indexLog), 3_000_000)
        events.clear()

        await writer.truncateCheckpoint()
        XCTAssertEqual(events.all, ["first truncated", "second truncated"], "each, in the order kept")
        XCTAssertEqual(sizeWhenAsked.all, [0], "the index's own log was emptied before the first kept log was")
        XCTAssertEqual(onQueue.all, [true])
    }

    func testALogCanBeKeptFromAnotherThreadWhilePiecesRun() async throws {
        let (_, writer) = try await makeWriter()
        let events = EventLog()
        let logs = (0..<8).map { KeptLog("log\($0)", log: events) }

        let keeping = Task { [writer] in
            try await offMain { DispatchQueue.concurrentPerform(iterations: logs.count) { writer.keep(logs[$0]) } }
        }
        for id in 1...200 { writer.submit(Piece("p\(id)")) }
        try await keeping.value
        // A piece after every log has been kept is asked of every one of them.
        writer.submit(Piece("last"))
        try await settle(writer)
        for log in logs {
            XCTAssertGreaterThanOrEqual(log.askedOnWriterQueue.count, 1, log.name)
            XCTAssertTrue(log.askedOnWriterQueue.allSatisfy { $0 })
        }
    }

    // MARK: - The hand-off, from many threads

    func testPiecesSubmittedFromEightThreadsAllRunOnceAndEachThreadsRunInItsOwnOrder() async throws {
        let (_, writer) = try await makeWriter()
        let threads = 8, each = 250, total = threads * each
        let ran = MailTestList<[Int]>()
        let count = MailTestCounter()
        let allHaveRun = MailTestGate("all \(total) pieces to have run", limit: 30)
        let pieces = (0..<threads).map { thread in
            (0..<each).map { n -> Piece in
                let piece = Piece("t\(thread).\(n)")
                piece.intentStep = { ran.add([thread, n]); if count.increment() == total { allHaveRun.open() } }
                return piece
            }
        }
        try await offMain {
            DispatchQueue.concurrentPerform(iterations: threads) { thread in
                for piece in pieces[thread] { writer.submit(piece) }
            }
        }
        // Wait for the pieces themselves — not for a submission of the test's own, which would
        // wake a queue that had forgotten work and hide the fault this test is for.
        await allHaveRun.waitAsync()
        try await settle(writer)

        XCTAssertEqual(ran.all.count, total, "a piece was lost, or run twice")
        for thread in 0..<threads {
            XCTAssertEqual(ran.all.filter { $0[0] == thread }.map { $0[1] }, Array(0..<each),
                           "thread \(thread)'s pieces ran out of the order it handed them over")
        }
        XCTAssertTrue(pieces.joined().allSatisfy { $0.indexCalls == 1 })
    }

    func testPiecesFromEightThreadsThatAbsorbEachOtherAreAccountedForExactlyOnce() async throws {
        let (_, writer) = try await makeWriter()
        let threads = 8, each = 250, total = threads * each
        // A piece is accounted for when it has run (a head) or been folded into one that will.
        let accounted = MailTestCounter()
        let allAccounted = MailTestGate("all \(total) pieces to be run or folded in", limit: 30)
        let account = { if accounted.increment() == total { allAccounted.open() } }
        let pieces = (0..<threads).map { thread in
            (0..<each).map { n -> Piece in
                let piece = Piece("t\(thread).\(n)", absorbs: true)
                piece.intentStep = account
                piece.onAbsorb = account
                return piece
            }
        }
        try await offMain {
            DispatchQueue.concurrentPerform(iterations: threads) { thread in
                for piece in pieces[thread] { writer.submit(piece) }
            }
        }
        await allAccounted.waitAsync()
        try await settle(writer)

        let all = Array(pieces.joined())
        let heads = all.filter { $0.indexCalls == 1 }
        let absorbed = all.filter { $0.indexCalls == 0 }
        XCTAssertEqual(heads.count + absorbed.count, total)
        XCTAssertTrue(all.allSatisfy { $0.indexCalls <= 1 && $0.intentCalls <= 1 })
        let foldedIn = heads.flatMap { $0.absorbed.map(\.name) }
        XCTAssertEqual(Set(foldedIn), Set(absorbed.map(\.name)), "a piece was folded into one that did not carry it, or twice")
        XCTAssertEqual(foldedIn.count, absorbed.count)
    }

    // MARK: - Work submitted from inside the writer

    func testASinkThatSubmitsWorkInReplyDoesNotDeadlockTheWriterAndItsWorkRuns() async throws {
        let sink = Sink()
        let (_, writer) = try await makeWriter(sink: sink)
        let followUpRan = MailTestGate("the piece the sink submitted")
        let followUp = Piece("followUp")
        followUp.indexStep = { _ in followUpRan.open(); return MailStoreChange(through: 2) }
        let submitted = MailTestList<Bool>()
        sink.onCommitted = { change in
            if change.through == 1 { submitted.add(true); writer.submit(followUp) }
        }

        let first = Piece("first")
        first.indexStep = { _ in MailStoreChange(through: 1) }
        writer.submit(first)
        await followUpRan.waitAsync()
        try await settle(writer)
        XCTAssertEqual(submitted.all, [true])
        XCTAssertEqual(sink.changes.map(\.through), [1, 2])
    }

    func testAPieceThatSubmitsFromItsIntentStepOrFromBeingToldItFailedHasItsWorkRun() async throws {
        let (_, writer) = try await makeWriter()
        let ran = MailTestGate("the pieces submitted from inside the writer")
        let count = MailTestList<String>()
        func follow(_ name: String) -> Piece {
            let piece = Piece(name)
            piece.indexStep = { _ in count.add(name); if count.all.count == 2 { ran.open() }; return MailStoreChange() }
            return piece
        }

        let intentSubmits = Piece("intentSubmits")
        intentSubmits.intentStep = { writer.submit(follow("fromIntent")) }
        let failedSubmits = Piece("failedSubmits")
        failedSubmits.intentStep = { throw Boom(n: 4) }
        failedSubmits.onFailed = { _ in writer.submit(follow("fromFailed")) }
        writer.submit(intentSubmits); writer.submit(failedSubmits)

        await ran.waitAsync()
        try await settle(writer)
        XCTAssertEqual(Set(count.all), ["fromIntent", "fromFailed"])
    }

    func testFailedIsCalledOnTheWritersQueueWhicheverStepThrew() async throws {
        let (_, writer) = try await makeWriter()
        let intentThrows = Piece("intent"), indexThrows = Piece("index")
        intentThrows.intentStep = { throw Boom(n: 5) }
        indexThrows.indexStep = { _ in throw Boom(n: 6) }
        writer.submit(intentThrows); writer.submit(indexThrows)
        try await settle(writer)
        XCTAssertEqual(intentThrows.failedRanOnWriterQueue, [true])
        XCTAssertEqual(indexThrows.failedRanOnWriterQueue, [true])
    }
}
