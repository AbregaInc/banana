#if !BANANA_PUBLIC
import Foundation

/// The one answer to "may the fill go on?", and the memory that makes the rule's two thresholds
/// work (MAIL-ENGINE 11.3, invariant 26).
///
/// `MailDiskRules.state` is pure and has to be told its last answer; this is what remembers it.
/// The engine makes one (P23a), from the role's floor, its clock and
/// `MailEnvironment.freeDiskBytes`, and hands it to each of the four things that fill the disk —
/// the fill, attachment prefetch, preparation, the indexer — which ask `state()` before a batch
/// and do not start one while it says `belowFloor`. **Eviction (P33) is what brings it back**:
/// until that exists nothing does, and a device under its floor stays stopped.
///
/// It reads the free space at most once a minute, and again after every 50 MiB its users have
/// told it they wrote (`wrote(_:)`). Reading is a call into the file system, so `state()` is not
/// for the main thread.
final class MailDiskWatch: @unchecked Sendable {

    private let floor: Int64
    private let clock: MailClock
    private let freeBytes: @Sendable () -> Int64

    private let lock = NSLock()
    private var answer = MailDiskState.ok
    private var lastRead: Date?
    private var written: Int64 = 0

    /// - Parameters:
    ///   - floor: `MailDiskRules.floor(for:)` of this device's role.
    ///   - freeBytes: the free space now, in bytes. Called off the main thread, at most once a
    ///     minute.
    init(floor: Int64, clock: MailClock, freeBytes: @escaping @Sendable () -> Int64) {
        self.floor = floor
        self.clock = clock
        self.freeBytes = freeBytes
    }

    /// The state: the last answer, brought up to date first if it is time to look again — the
    /// first call always looks.
    func state() -> MailDiskState {
        MailMainQueueGuard.requireOffMainQueue("MailDiskWatch.state", store: nil)

        lock.lock(); defer { lock.unlock() }
        let now = clock.now
        if isTimeToRead(now: now) {
            answer = MailDiskRules.state(free: freeBytes(), floor: floor, was: answer)
            lastRead = now
            written = 0
        }
        return answer
    }

    /// Says that `bytes` were written to the disk: after 50 MiB of them the next `state()` looks
    /// again whatever the time. Cheap, and safe from any thread.
    func wrote(_ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        written += max(0, bytes)
    }

    /// Call with the lock held.
    private func isTimeToRead(now: Date) -> Bool {
        guard let lastRead else { return true }
        let seconds = now.timeIntervalSince(lastRead)
        // A clock set back is not a reason to wait an hour longer.
        return seconds < 0 || MailDiskRules.shouldReadFreeSpace(secondsSinceLastRead: seconds,
                                                                 bytesWrittenSinceLastRead: written)
    }
}

#endif
