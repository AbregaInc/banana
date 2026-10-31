#if !BANANA_PUBLIC
import Foundation

/// The clock the app runs on: the device's time, and a real sleep.
///
/// This is the one place in mail that reads `Date()` and the one that sleeps for real; every
/// other piece asks a `MailClock` (13.6, 18.1). The protocol is P01a's, in `MailClock.swift`.
///
/// A sleep ends at a *moment*, so `sleep(until:)` works out how long is left, sleeps that long
/// on a clock that keeps counting while the device is asleep (`ContinuousClock`), and then looks
/// at the time again before it believes it has arrived. A phone put in a pocket for an hour
/// therefore wakes a sleeper whose time came during that hour as soon as the phone wakes, not an
/// hour after. A wall clock set *back* while a sleeper waits is noticed — it sleeps the longer
/// time that is then left. One set *forward* is not: the sleeper is waiting on a length of time,
/// and wakes late by the size of the jump, at the moment it was going to wake. (Nothing in mail
/// depends on an exact moment to that degree; a snooze that is an hour late because the clock was
/// changed is a snooze the person changed the clock under.)
struct SystemMailClock: MailClock {

    init() {}

    var now: Date { Date() }

    func sleep(until deadline: Date) async throws {
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSince(now)
            if remaining <= 0 { return }
            try await Task.sleep(for: .seconds(remaining), clock: ContinuousClock())
        }
    }
}

/// A clock that stands still until a test moves it, for every test of anything that waits.
///
/// The time starts where the test puts it and changes only through `advance(by:)`. A sleeper
/// is a task suspended in `sleep(until:)`; `advance` moves the time and wakes every sleeper
/// whose moment has been reached, **earliest first** (two with the same moment in the order they
/// began to sleep). A sleep whose moment has already come returns at once. Cancelling the sleeping
/// task ends its sleep with `CancellationError` and takes it off the list, as with the system
/// clock.
///
/// Nothing here depends on how long anything really takes, which is the point: a test says "an
/// hour passes" and an hour passes, in no time, with every sleeper woken in the order the real
/// time would have woken it.
final class ManualMailClock: MailClock, @unchecked Sendable {

    /// One task asleep. `resumed` is what keeps a wake and a cancel from both resuming it.
    private final class Sleeper {
        let deadline: Date
        let order: Int
        var continuation: CheckedContinuation<Void, Error>?
        var cancelled = false
        var resumed = false
        init(deadline: Date, order: Int) { self.deadline = deadline; self.order = order }
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []
    private var began = 0
    private var watchers: [(count: Int, resume: CheckedContinuation<Void, Never>)] = []

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// The moments of the sleepers that have not been woken, earliest first.
    var pendingSleeps: [Date] {
        lock.lock(); defer { lock.unlock() }
        return sleepers.sorted(by: Self.earlierFirst).map(\.deadline)
    }

    func sleep(until deadline: Date) async throws {
        let sleeper = Sleeper(deadline: deadline, order: nextOrder())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if sleeper.cancelled {
                    sleeper.resumed = true
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    sleeper.resumed = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleeper.continuation = continuation
                    sleepers.append(sleeper)
                    let ready = takeReadyWatchers()
                    lock.unlock()
                    ready.forEach { $0.resume() }
                }
            }
        } onCancel: {
            lock.lock()
            sleeper.cancelled = true
            var wake: CheckedContinuation<Void, Error>?
            if !sleeper.resumed, let continuation = sleeper.continuation {
                sleeper.resumed = true
                sleepers.removeAll { $0 === sleeper }
                wake = continuation
            }
            lock.unlock()
            wake?.resume(throwing: CancellationError())
        }
    }

    /// Moves the time on by `interval` and wakes every sleeper whose moment has now come,
    /// earliest first. Returns the moments of the ones it woke, in the order it woke them.
    @discardableResult
    func advance(by interval: TimeInterval) -> [Date] {
        lock.lock()
        current = current.addingTimeInterval(interval)
        let due = sleepers.filter { $0.deadline <= current }.sorted(by: Self.earlierFirst)
        sleepers.removeAll { sleeper in due.contains { $0 === sleeper } }
        for sleeper in due { sleeper.resumed = true }
        lock.unlock()
        for sleeper in due { sleeper.continuation?.resume() }
        return due.map(\.deadline)
    }

    /// Returns once at least `count` tasks are asleep on this clock.
    ///
    /// A task that has been started has not necessarily reached `sleep(until:)`, and a test that
    /// moves the time before it has would move it past a sleeper that was about to begin. This
    /// is the test's way of knowing, without a pause or a guess: it waits for the clock to say
    /// so. **It never returns if that many sleepers never come**: a test that is wrong about the
    /// count hangs here, which a test runner's own time limit ends.
    func untilSleeping(atLeast count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if sleepers.count >= count {
                lock.unlock()
                continuation.resume()
            } else {
                watchers.append((count, continuation))
                lock.unlock()
            }
        }
    }

    // MARK: - Private

    private func nextOrder() -> Int {
        lock.lock(); defer { lock.unlock() }
        began += 1
        return began
    }

    /// The watchers whose count has been reached. Call with the lock held.
    private func takeReadyWatchers() -> [CheckedContinuation<Void, Never>] {
        let ready = watchers.filter { sleepers.count >= $0.count }
        watchers.removeAll { watcher in sleepers.count >= watcher.count }
        return ready.map(\.resume)
    }

    private static func earlierFirst(_ a: Sleeper, _ b: Sleeper) -> Bool {
        a.deadline != b.deadline ? a.deadline < b.deadline : a.order < b.order
    }
}

#endif
