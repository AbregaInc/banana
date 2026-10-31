#if !BANANA_PUBLIC
import Foundation

/// How fast mail's local, CPU-bound passes may run right now (MAIL-ENGINE 4.12, invariant 31).
///
/// Preparing messages, indexing them, rebuilding derived stores and rebuilding split views can
/// run for hours, and in the first design they ran flat out: the app's own watchdog would have
/// called them a runaway, and a phone would have been warm in a pocket for no one's benefit.
/// So they run at a pace that depends on the device and what it is doing, and this is the one
/// place that decides it. It reads nothing: the caller says what is true, which is what lets
/// every row of the table be tested directly.
///
/// The decision is **the first row that applies**, top to bottom (the tables of 4.12 and 12.1
/// say the same):
///
/// 1. **`stopped`** when the device is warm (thermal state fair or worse) or in Low Power Mode,
///    on any device, **inside the overnight task too**. Invariant 31 says "not at all" and makes
///    no exception; a phone that warms while it charges stops its overnight work until it cools.
/// 2. **`full`** inside the overnight task, and on a Mac on mains.
/// 3. **`paced(0.2)`** on a Mac on battery, and on a phone or iPad with Banana active and Mail
///    on screen.
/// 4. **`stopped`** for a phone or iPad otherwise: Mail not on screen, or the app not active.
///    (The overnight task is not "active", so row 2 has to come before this one: it is the one
///    time these devices work with the app in the background.)
enum MailWorkPace: Equatable, Sendable {
    /// No pauses.
    case full
    /// Work, then sleep so that work is `share` of the time elapsed.
    case paced(share: Double)
    /// Do none.
    case stopped

    /// The pace for a device in the situation described. See the type's comment for the order
    /// the rules are applied in.
    ///
    /// - Parameters:
    ///   - insideOvernightTask: the iOS processing task of 12.2 is running this.
    ///   - mailVisible: Mail is the thing on screen. Meaningless on a Mac and ignored there.
    ///   - appActive: the app is in the foreground. Ignored on a Mac.
    static func current(role: MailDeviceRole,
                        power: MailPower,
                        insideOvernightTask: Bool,
                        mailVisible: Bool,
                        appActive: Bool) -> MailWorkPace {
        if power.thermalFairOrWorse || power.lowPowerMode { return .stopped }
        if insideOvernightTask { return .full }

        switch role {
        case .mac:
            return power.onMains ? .full : .paced(share: MailKnobs.pacedShare)
        case .phone, .pad:
            return (appActive && mailVisible) ? .paced(share: MailKnobs.pacedShare) : .stopped
        }
    }

    /// How long a pass sleeps after working for `work` seconds, so that its work is `share` of
    /// the time elapsed: `work × (1 − share) ÷ share`, which at a fifth is four times as long as
    /// the piece took. Nil for a pace that does not work at all; zero for one that never pauses.
    ///
    /// A paced pass works in pieces of at most `MailKnobs.pacedPiece` (50 ms) and sleeps this
    /// long, on the clock (`MailClock.sleep(until:)`), after each.
    func pause(afterWorking work: TimeInterval) -> TimeInterval? {
        switch self {
        case .full:
            return 0
        case .stopped:
            return nil
        case .paced(let share):
            guard share > 0 else { return nil }
            guard share < 1 else { return 0 }
            return max(0, work) * (1 - share) / share
        }
    }
}

#endif
