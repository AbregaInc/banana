#if !BANANA_PUBLIC
import Foundation
import GRDB

/// One piece of work for the writer's queue (MAIL-ENGINE 4.2, 6.2).
///
/// The writer takes everything that is waiting, lets each piece absorb the next where it can,
/// then runs each: the intent step, and only if that did not throw, one index transaction.
protocol MailWriterWork: AnyObject {
    /// Fold `next` into this piece so the two commit together. False: it runs on its own.
    func absorb(_ next: MailWriterWork) -> Bool
    /// 6.2 step 6. The piece calls `MailIntentStore` itself — the writer cannot name that type,
    /// and the intent store's connection is private. Sync's pieces do nothing here.
    func writeIntent() throws
    /// 6.2 step 7, inside the index writer's transaction.
    func writeIndex(_ db: Database) throws -> MailStoreChange
    /// Either step threw. Called on the writer's queue; the writer then goes on to the next piece.
    ///
    /// One call for two outcomes — the intent step threw, so nothing was saved, or it returned and
    /// the index step threw, so the change is saved and not indexed — and the call does not say
    /// which: a piece that needs to know remembers whether its own `writeIntent` returned. And one
    /// call for the piece that was run, covering everything it absorbed.
    func failed(_ error: Error)
}

/// A write-ahead log other than the index's whose writes happen on the writer's queue:
/// `intent.sqlite`'s, which only `MailIntentStore` can reach (4.2). The writer keeps it
/// (`MailWriter.keep`) and asks it after every piece of work — one that failed too, since a
/// piece whose index step failed has still written intent.
protocol MailWriterLog: AnyObject {
    /// After a piece, on the writer's queue: a `PASSIVE` checkpoint if the log is due.
    func checkpointIfDue()
    /// From `MailWriter.truncateCheckpoint()`, on the writer's queue: empty the log.
    func truncateCheckpoint()
}

/// What one index transaction touched. Handed to the sink after the commit.
struct MailStoreChange: Equatable, Sendable {
    /// `view.key` of each view touched (4.3).
    var viewKeys: Set<String> = []
    var conversations: Set<MailConversationID> = []
    var labelsChanged = false
    /// The highest command sequence carried; 0 for sync.
    var through: UInt64 = 0

    mutating func formUnion(_ other: MailStoreChange) {
        viewKeys.formUnion(other.viewKeys)
        conversations.formUnion(other.conversations)
        labelsChanged = labelsChanged || other.labelsChanged
        through = max(through, other.through)
    }
}

/// Told of every index commit, on the writer's queue, once it has happened.
protocol MailChangeSink: AnyObject {
    func committed(_ change: MailStoreChange)
}

/// The one writer for what a person's action touches, and for sync's batches (MAIL-ENGINE 4.2,
/// 6.2): a serial queue, `mail.writer`, of the engine's own.
///
/// **Why one queue.** A change he makes is written to `intent.sqlite` with a full fsync and then
/// to `index.sqlite`, in that order, each synchronously; sync's index batches go to the same
/// queue, so an action waits behind at most one batch of twenty messages, not behind a
/// transaction of unknown length.
///
/// **Group commit, with no window.** `submit` returns at once. The writer takes everything that
/// is waiting, in the order it came, and lets each piece fold the next into itself (`absorb`),
/// so that what arrived while one commit was on its way is carried by the next one — one key
/// press alone is committed at once; a burst makes as many commits as the disk can take and no
/// more, with nothing waiting longer than one commit. There is no timer. (MEASURED: one intent
/// commit carrying 1, 5, 20 or 50 actions costs 0.8, 0.3, 0.6 and 1.1 ms — the cost is per
/// commit.) How many changes one piece will fold in is the piece's to decide, with
/// `MailKnobs.groupCommitChanges`; the writer asks only whether it would.
///
/// **Order is kept across `perform` too:** work handed to `perform` runs where it was
/// submitted, between the pieces before it and the pieces after, and ends a run of pieces that
/// could have been folded together.
///
/// **A piece that fails does not stop the writer.** If its intent step throws, its index step is
/// not run (6.2: nothing reaches the index that is not in `intent.sqlite`); either way it is told
/// (`failed`), on the writer's queue, and the next piece runs.
///
/// **Checkpoints** happen between pieces of work, never inside one, and never by waiting for a
/// quiet moment (invariant 12): a log over 8 MB gets a `PASSIVE` checkpoint before the next
/// piece, which never waits for a reader. `truncateCheckpoint()` is the one that does wait,
/// for suspend and quit. The index's log is the writer's own; `intent.sqlite`'s is handed to it
/// (`keep`), because only `MailIntentStore` can reach it. See `MailLogCheckpointer` for the rule,
/// which the other stores' writers use too (4.2).
final class MailWriter: @unchecked Sendable {

    private let stores: MailStores
    private let sink: MailChangeSink?
    private let queue = DispatchQueue(label: "mail.writer", qos: .userInitiated)
    private let checkpointer: MailLogCheckpointer

    private enum Item {
        case work(MailWriterWork)
        case task(@Sendable () -> Void)
    }

    private let lock = NSLock()
    private var waiting: [Item] = []
    private var kept: [MailWriterLog] = []
    /// A drain is queued or running, so a new item need not start one.
    private var draining = false

    private static let queueKey = DispatchSpecificKey<Void>()

    /// The sink is held for the writer's whole life. The engine's hub does not hold the writer,
    /// so this is not a cycle.
    init(stores: MailStores, sink: MailChangeSink?) {
        self.stores = stores
        self.sink = sink
        self.checkpointer = MailLogCheckpointer(
            logPath: stores.directories.indexDatabase.path + "-wal")
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    /// How many `PASSIVE` checkpoints the writer has run on the index. For tests; read it from
    /// inside `perform`, which is on the queue that changes it.
    var passiveCheckpointsRun: Int { checkpointer.passiveCheckpointsRun }

    /// Whether the caller is running on `mail.writer`. For a piece's `writeIntent`, which must
    /// be, and for a test that says so. **False inside `writeIndex`**: that runs on the index
    /// database's own queue, where the only connection to use is the `db` it is handed —
    /// calling `stores.index.read` from there is GRDB's "not reentrant" trap.
    static var isOnWriterQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    /// Hands the writer another log to look after: it is asked to checkpoint after every piece,
    /// and emptied by `truncateCheckpoint()` after the index's. Safe from any thread. The writer
    /// keeps it for its life.
    func keep(_ log: MailWriterLog) {
        lock.lock(); kept.append(log); lock.unlock()
    }

    private func keptLogs() -> [MailWriterLog] {
        lock.lock(); defer { lock.unlock() }
        return kept
    }

    /// Hands a piece of work to the writer. Returns at once; safe from any thread.
    func submit(_ work: MailWriterWork) {
        enqueue(.work(work))
    }

    /// The form of `perform` that does not wait: hands `task` to the queue, where it runs in its
    /// place in the order, and returns at once.
    func submit(task: @escaping @Sendable () -> Void) {
        enqueue(.task(task))
    }

    /// Runs `body` on the writer's queue, after everything submitted before it and before
    /// everything submitted after, and returns what it returns. For anything else that must
    /// not overlap the writer: reading `intent.sqlite` for a place, a checkpoint, a repair.
    func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(.task {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            })
        }
    }

    /// A bounded provider/cache batch, in the same queue as durable user actions.
    /// User mutations must continue through writeIntent before their index step.
    func transact(_ body: @escaping (Database) throws -> MailStoreChange) async throws -> MailStoreChange {
        try await perform {
            defer { self.checkpoints() }
            let change = try self.stores.index.write(body)
            self.sink?.committed(change)
            return change
        }
    }

    /// Provider transactions can return continuation work without capturing mutable
    /// state across queues. Publication still happens only after the index commits.
    func transactValue<T: Sendable>(_ body: @escaping (Database) throws -> (T, MailStoreChange)) async throws -> T {
        try await perform {
            defer { self.checkpoints() }
            let (value, change) = try self.stores.index.write(body)
            self.sink?.committed(change)
            return value
        }
    }

    /// Checkpoints the index's log with `TRUNCATE` — everything in the log is copied back and the
    /// file is made empty — and then each kept log's. For suspend and quit (`MailRuntime.suspend`, P24), when a log left
    /// behind would be one more thing to replay at the next launch. It waits for the readers
    /// that stand in the way, up to the busy timeout, and if it still cannot, gives up
    /// quietly: nothing is lost, the log is as durable as it was, and the next checkpoint of
    /// either kind takes it.
    func truncateCheckpoint() async {
        _ = try? await perform { [self] in
            _ = checkpointer.truncate(on: stores.index)
            for log in keptLogs() { log.truncateCheckpoint() }
        }
    }

    // MARK: - The queue

    private func enqueue(_ item: Item) {
        lock.lock()
        waiting.append(item)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }

    /// Takes everything waiting, runs it, and looks again — which is the group commit: what
    /// arrived while that ran is taken together next.
    private func drain() {
        while true {
            lock.lock()
            let items = waiting
            waiting = []
            if items.isEmpty { draining = false }
            lock.unlock()
            if items.isEmpty { return }
            process(items)
        }
    }

    private func process(_ items: [Item]) {
        var pieces: [MailWriterWork] = []
        for item in items {
            switch item {
            case .work(let piece):
                pieces.append(piece)
            case .task(let task):
                run(pieces); pieces = []
                task()
            }
        }
        run(pieces)
    }

    /// Folds each piece into the one before it where that piece agrees, and runs what is left.
    private func run(_ pieces: [MailWriterWork]) {
        guard var head = pieces.first else { return }
        for next in pieces.dropFirst() {
            if head.absorb(next) { continue }
            commit(head)
            head = next
        }
        commit(head)
    }

    private func commit(_ piece: MailWriterWork) {
        // After every piece, a failed one included: its intent step may have written, and an index
        // that keeps refusing (a full disk) must not leave the logs growing with nobody looking.
        // After the piece, never between its two steps.
        defer { checkpoints() }

        do {
            try piece.writeIntent()
        } catch {
            piece.failed(error)
            return
        }

        let change: MailStoreChange
        do {
            change = try stores.index.write { db in try piece.writeIndex(db) }
        } catch {
            piece.failed(error)
            return
        }
        // `write` returned, so the transaction committed: a rolled-back one throws, and is not
        // announced. The sink is told here rather than inside GRDB's commit callback, after the
        // write has finished and on this queue, so that it may read any store, and a sink that
        // submitted work in reply could not be waiting on a writer it is inside.
        sink?.committed(change)
    }

    /// The index's log, and then each kept log.
    private func checkpoints() {
        checkpointer.afterPiece(on: stores.index)
        for log in keptLogs() { log.checkpointIfDue() }
    }
}

// MARK: - When a log is checkpointed

/// The rule for when a log is due a checkpoint (MAIL-ENGINE 4.2: after any piece of work that
/// leaves a log **holding more than 8 MiB**, a `PASSIVE` checkpoint before the next piece). Pure.
///
/// **What "holding" is measured by.** The length of the `-wal` file, which needs nothing from
/// SQLite — once `PRAGMA journal_size_limit = 8388608` (set on every connection that can write)
/// has made that length mean what it should. A `PASSIVE` checkpoint copies the log back and does
/// not shorten the file: SQLite starts writing again from its beginning and leaves the file as
/// long as it was. With the limit set, it is cut back to 8 MiB when the log is restarted, so from
/// then on the file is longer than 8 MiB exactly when the log holds more than that.
///
/// Between a checkpoint that copied everything back and the restart that cuts the file, the file
/// is still as long as it was. `standing` is the length such a checkpoint left it at: a log is
/// due only when it is longer than the limit **and** longer than that, so a piece that wrote
/// nothing, and the pieces before the next write restarts the log, do not each cost a checkpoint
/// and its two fsyncs. A checkpoint that a reader held up copied only part and does not set it:
/// the log is still over what it may hold, and is tried again after the next piece — which is
/// what it should be. The mark is never more than the file's present length (`clamped`): when
/// the file is cut, the mark comes down with it. Without that it could only rise, and one long
/// reader would leave every later checkpoint at a hundred megabytes.
enum MailCheckpointRule {
    static func isDue(logBytes: Int64,
                      limit: Int64 = MailKnobs.checkpointOverBytes,
                      standing: Int64) -> Bool {
        logBytes > max(limit, standing)
    }

    /// `standing`, brought down to the file's present length if that is less.
    static func clamped(standing: Int64, logBytes: Int64) -> Int64 {
        min(standing, logBytes)
    }
}

/// Runs `MailCheckpointRule` for one store's log, between pieces of work on that store's one
/// writer. Used by `MailWriter` for the index; `MailIntentStore` (through `MailWriterLog`), the
/// blob store and the search indexer each use one for theirs (4.2: "each store's one writer
/// checkpoints its own log, by the same rule").
///
/// Not thread-safe: it belongs to the one queue that writes the store.
final class MailLogCheckpointer {

    private let logPath: String
    private let limit: Int64
    private var standing: Int64 = 0

    /// How many `PASSIVE` checkpoints it has run. For a test that says a checkpoint did not run.
    private(set) var passiveCheckpointsRun = 0

    /// - Parameter logPath: the store's `-wal` file.
    init(logPath: String, limit: Int64 = MailKnobs.checkpointOverBytes) {
        self.logPath = logPath
        self.limit = limit
    }

    /// Checkpoints the log, `PASSIVE`, if it is due. `PASSIVE` waits for nothing: it copies what
    /// no reader still needs and returns, so it holds up neither a reader nor the next piece
    /// for longer than the copying.
    func afterPiece(on writer: any DatabaseWriter) {
        let bytes = Self.fileSize(logPath)
        standing = MailCheckpointRule.clamped(standing: standing, logBytes: bytes)
        guard MailCheckpointRule.isDue(logBytes: bytes, limit: limit, standing: standing) else { return }

        passiveCheckpointsRun += 1
        // The counts are the frames in the log and the frames copied back.
        guard let counts = try? writer.writeWithoutTransaction({ try $0.checkpoint(.passive) }) else { return }
        // Only a checkpoint that copied everything back has emptied the log. One that a reader
        // held up has not, and the log is still due.
        if counts.walFrameCount == counts.checkpointedFrameCount { standing = bytes }
    }

    /// Empties the log with a `TRUNCATE` checkpoint, which waits for the readers in the way, up to
    /// the busy timeout, and fails if one is still there. Returns whether it emptied it.
    @discardableResult
    func truncate(on writer: any DatabaseWriter) -> Bool {
        guard (try? writer.writeWithoutTransaction({ try $0.checkpoint(.truncate) })) != nil else { return false }
        didTruncate()
        return true
    }

    /// The file has been emptied by a `TRUNCATE` checkpoint.
    func didTruncate() {
        standing = 0
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

#endif
