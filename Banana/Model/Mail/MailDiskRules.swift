#if !BANANA_PUBLIC
import Foundation

/// What the free space says about whether the fill may go on.
enum MailDiskState: Equatable, Sendable {
    /// The fill and the passes may run.
    case ok
    /// Free space fell below the floor and has not come back to the floor plus 500 MiB: they
    /// stop, and eviction (P33) is what brings it back (11.3).
    /// `MailStatusValue.downloads.heldBy` says `.diskNearlyFull`.
    case belowFloor
}

/// Whether there is enough free space for mail to go on filling in, and when to look
/// (MAIL-ENGINE 11.3, invariant 26).
///
/// The fill, attachment prefetch, preparation and the indexer are what can use up a disk, and
/// the one thing that must never fail for want of space is the commit of a change he has just
/// made — a few hundred bytes. So there is a floor of free space under which all four stop,
/// well above what that commit needs; actions, drafts and sends are never stopped by it.
///
/// The decision is a pure function of the free space, the floor and its own last answer, so it is
/// tested directly. Reading the free space is not done here (`volumeAvailableCapacityForImportantUsage`,
/// off the main thread); only when to read is. `MailDiskWatch` is the one object that reads, and
/// remembers.
///
/// Sizes here are binary (a gigabyte is 2³⁰ bytes), as the page-cache sizes of 4.2 are. The
/// document says "GB" and "MB" without saying which; the binary figure is the larger floor, so
/// it errs towards stopping early.
enum MailDiskRules {

    private static let megabyte: Int64 = 1_048_576
    private static let gigabyte: Int64 = 1_073_741_824

    /// The floor: 1 GB on an iPhone or iPad, 5 GB on a Mac.
    static func floor(for role: MailDeviceRole) -> Int64 {
        switch role {
        case .phone, .pad: return 1 * gigabyte
        case .mac: return 5 * gigabyte
        }
    }

    /// The rule has two thresholds, so it is told its own previous answer (`was`):
    ///
    /// - From `ok` it becomes `belowFloor` when free space is **strictly less than** the floor.
    ///   Free space equal to the floor is `ok`.
    /// - From `belowFloor` it becomes `ok` only at the floor plus 500 MiB or more
    ///   (`evictionTarget(floor:)`). A fill let go at the floor itself would be stopped again by
    ///   its next batch; eviction brings the space back up to the target, and then it resumes.
    ///
    /// The memory of the last answer is `MailDiskWatch`'s.
    static func state(free: Int64, floor: Int64, was: MailDiskState) -> MailDiskState {
        switch was {
        case .ok:
            return free < floor ? .belowFloor : .ok
        case .belowFloor:
            return free >= evictionTarget(floor: floor) ? .ok : .belowFloor
        }
    }

    /// How far above the floor eviction runs before the fill is let go again: 500 MB.
    static let evictionHeadroom: Int64 = 500 * megabyte

    /// The amount of free space eviction aims for once it has begun: the floor and the headroom.
    static func evictionTarget(floor: Int64) -> Int64 {
        floor + evictionHeadroom
    }

    /// Free space is read at most once a minute …
    static let readInterval: TimeInterval = 60
    /// … and again after every 50 MB written.
    static let readAfterBytesWritten: Int64 = 50 * megabyte

    /// Whether it is time to read the free space again: a minute has passed since the last
    /// read, or 50 MB have been written since.
    static func shouldReadFreeSpace(secondsSinceLastRead: TimeInterval,
                                    bytesWrittenSinceLastRead: Int64) -> Bool {
        secondsSinceLastRead >= readInterval || bytesWrittenSinceLastRead >= readAfterBytesWritten
    }
}

#endif
