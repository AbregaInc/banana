#if !BANANA_PUBLIC
import Foundation

/// Every number of MAIL-ENGINE 4.12 and the connection rules around it, in one place.
///
/// These are the figures the design measured and then chose between (a sync batch of 20 rather
/// than 50, a checkpoint over 8 MB rather than "when idle"), so each is named once here and
/// nothing else in mail spells the number. Changing one is a design decision, not a tuning
/// tweak: `MailWorkPaceTests` pins them to the document's figures, so a change fails a test and
/// is made on purpose.
///
/// The free-space numbers (11.3) are `MailDiskRules`'s own.
enum MailKnobs {

    // MARK: - Writing (4.2)

    /// Messages in one sync transaction. MEASURED with a list reader running: 20 holds the
    /// writer 6.2 ms p95; the first design's 50 held it 23.7 ms.
    static let syncBatchMessages = 20

    /// Changes carried by one group commit at the most (6.2, step 4). There is no window
    /// beyond that: a commit takes what has arrived.
    static let groupCommitChanges = 50

    /// A write-ahead log longer than this is checkpointed (PASSIVE) before the next piece of
    /// work, never inside one. 8 MiB.
    static let checkpointOverBytes: Int64 = 8 * 1_048_576

    /// Rows a background read takes before it gives the connection back, so that with two
    /// readers a list read never waits behind more than one scan.
    static let backgroundReadRows = 500

    /// Messages the indexer writes to `search.sqlite` in one transaction.
    static let indexerBatchMessages = 50

    // MARK: - Delivery and polling

    /// Delivery waits this long after the last change before it sends (6.5), so a burst goes
    /// as one request and a change undone within the second sends nothing …
    static let deliveryDebounce: TimeInterval = 1.5
    /// … and this long at the most, however long the burst goes on.
    static let deliveryDebounceCeiling: TimeInterval = 5

    /// One poll a minute with Mail on screen (12.1).
    static let pollInterval: TimeInterval = 60

    /// Messages read per step when verifying that a message Gmail no longer lists is really gone
    /// (5.3, 5.7).
    static let verifyBatchMessages = 50

    /// Requests in flight at once, per account, for a batch of reads (5.1, 5.2).
    static let maxInFlight = 4

    // MARK: - The pace of local passes (4.12)

    /// The share of one core a paced pass may use: a fifth.
    static let pacedShare = 0.2

    /// A paced pass works in pieces of at most this long (50 ms) and then sleeps, so that work
    /// is `pacedShare` of the time elapsed.
    static let pacedPiece: TimeInterval = 0.050
}

#endif
