#if !BANANA_PUBLIC
import Foundation

/// The only clock mail's engine reads, and the only thing it sleeps on (MAIL-ENGINE 13.6).
///
/// Every rule in mail that depends on the time — a token near expiry, a send held for undo, a
/// snooze that comes due, a pause for quota — asks this, not `Date()` and not `Task.sleep`. That
/// is what lets a test stand the time wherever it likes and move it by exactly as much as it
/// means to, instead of waiting for it or guessing how long something takes. The engine is
/// handed its clock when it is built (`MailEnvironment.clock`), so a test hands it a still one.
///
/// A sleep ends at a moment, not after a length of time, so a sleeper woken early by a change
/// of plan can go back to sleep until the same moment. Cancelling the task that sleeps ends the
/// sleep with `CancellationError`.
///
/// Only the protocol is here. The system clock (`SystemMailClock`) and the test clock that moves
/// on command (`ManualMailClock`) are in `MailClocks.swift`.
protocol MailClock: Sendable {
    var now: Date { get }
    func sleep(until deadline: Date) async throws          // throws CancellationError
}

#endif
