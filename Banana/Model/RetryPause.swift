import Foundation

/// How long a device waits before asking the service again after it said it is full (429).
///
/// The wait is for the whole device, not one item: every item queued behind the one refused would be
/// refused the same way, so trying each in turn only adds load to a service that asked for less. The
/// first pause is short, each refusal in a row doubles it up to `cap`, and any accepted operation
/// starts over. `hint` is the service's own wait, when it gives one.
enum RetryPause {
    static let first: TimeInterval = 5
    static let cap: TimeInterval = 300

    /// `streak` counts refusals in a row, starting at 1. `jitter` (1 or more) spreads devices apart;
    /// tests pass the default.
    static func delay(streak: Int, hint: TimeInterval? = nil, jitter: Double = 1) -> TimeInterval {
        let steps = max(0, min(streak, 32) - 1)
        let base = min(cap, first * pow(2, Double(steps)))
        let wait = min(cap, max(base, hint.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0))
        return min(wait * max(1, jitter), cap * 1.25)
    }

    /// A little extra, so two devices that were refused together do not come back together.
    static func jitter() -> Double { Double.random(in: 1...1.25) }
}

/// The pause every provider change on this device keeps after the service says it is full. Mail,
/// Calendar and drafts share the service's limit, so one refusal pauses them all.
struct OperationBackoff: Sendable, Equatable {
    private(set) var streak = 0
    private(set) var until: Date = .distantPast

    /// Seconds left of the pause, nil when none.
    func remaining(at now: Date) -> TimeInterval? {
        until > now ? until.timeIntervalSince(now) : nil
    }

    /// The service answered 429.
    mutating func refused(at now: Date, jitter: Double = 1) {
        streak += 1
        until = now.addingTimeInterval(RetryPause.delay(streak: streak, jitter: jitter))
    }

    /// The service accepted an operation: the way is clear.
    mutating func accepted() { streak = 0; until = .distantPast }
}
