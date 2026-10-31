import Foundation

/// Cross-device playback sync resolves conflicts by last-write-wins on an event timestamp, and
/// those timestamps come from different clocks: the Watch stamps with its own `Date()`, the phone
/// and Mac with theirs. An Apple Watch tracks its paired phone closely, so in practice the skew is
/// milliseconds — but nothing bounded it, and the failure it allows is permanent rather than
/// transient.
///
/// A device whose clock runs fast wins *every* conflict it ever enters. Its stamps sit
/// permanently in the receiver's future, so the `prev >= at` guard never rejects one, and it
/// silently overrides progress that genuinely happened later. The symptom — the wrong episode,
/// a position that snaps backwards — is indistinguishable from a merge bug, which is what makes
/// it expensive to find.
///
/// The bound: an event cannot have happened after the moment it arrived. Anything claiming
/// otherwise is clamped back to now. A genuinely recent report still outranks older local
/// activity (which is the whole point of the merge), but it can no longer outrank activity that
/// hasn't happened yet.
///
/// Deliberately NOT a latency correction. `transferUserInfo` is a queue that can sit for hours,
/// so `now - sentAt` measures skew *plus* queue delay and correcting by it would be far worse
/// than doing nothing. Late delivery is already handled correctly, because the merge compares
/// when an event *happened*, not when it landed.
enum PlaybackSyncClock {
    /// Slack for ordinary clock jitter and in-flight delivery. Only affects whether skew is worth
    /// reporting — a stamp a few milliseconds ahead is clamped either way, and harmlessly so.
    static let tolerance: TimeInterval = 5

    /// The usable event time for a stamp that arrived from another device.
    static func received(_ at: Date, now: Date = Date()) -> Date { min(at, now) }

    /// Whether this stamp is far enough ahead to indicate a genuinely misaligned clock rather
    /// than jitter — worth logging, because it means someone's device time is wrong.
    static func isSkewed(_ at: Date, now: Date = Date()) -> Bool {
        at > now.addingTimeInterval(tolerance)
    }
}
