import Foundation

/// One piece of async work at a time. Asking while it runs doesn't start a second copy: the work
/// runs once more when the current pass ends, and the caller waits for that pass — so whoever asked
/// (a push that has to ask about what arrived) sees what was fetched for it, not a fetch still in
/// flight (`CloudZonePoller`).
@MainActor
final class CoalescingRun {
    private var running = false
    private var again = false
    private var waiters: [CheckedContinuation<Int, Never>] = []

    /// Runs `work` until no one asked again during it, and returns the passes' total. A call made
    /// while a pass runs waits for the pass that follows it, and returns the same total.
    func run(_ work: () async -> Int) async -> Int {
        guard !running else {
            again = true
            return await withCheckedContinuation { waiters.append($0) }
        }
        running = true
        var total = 0
        repeat {
            again = false
            total += await work()
        } while again
        running = false
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: total) }
        return total
    }
}
