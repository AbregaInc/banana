import Foundation

/// The Google change poll: while the app is in front, it asks every `interval` whether anything
/// changed since it last got an answer, and only a yes runs the full refresh. Google has no change
/// notification an app can receive; this is what Apple Calendar's `EKEventStoreChanged` used to be.
///
/// Split from `SmartScheduleStore` so the part the background touches — stop it, start it again —
/// is tested without the store's dependencies. A backgrounded audio app keeps its process alive for
/// hours, and this loop woke it every two minutes to skip its own work.
@MainActor
final class CalendarChangePoll {
    private let interval: TimeInterval
    private let now: () -> Date
    private let isActive: @MainActor () -> Bool
    private let check: @MainActor (_ since: Date) async -> Bool?
    private let onChange: @MainActor () -> Void
    private var task: Task<Void, Never>?

    /// When the poll last got an answer. A pause does not touch it, so the first check after coming
    /// back looks back over the whole absence. An unanswered check (nil: offline, an error) does
    /// not move it either, so what it missed is asked again.
    private(set) var lastCheck: Date

    /// - Parameters:
    ///   - isActive: whether to check at all this tick; a tick that isn't active does nothing.
    ///   - check: whether anything changed since the date given; nil when there was no answer.
    ///   - onChange: what a yes does.
    init(interval: TimeInterval, now: @escaping () -> Date = Date.init,
         isActive: @escaping @MainActor () -> Bool,
         check: @escaping @MainActor (_ since: Date) async -> Bool?,
         onChange: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.now = now
        self.isActive = isActive
        self.check = check
        self.onChange = onChange
        lastCheck = now()
    }

    var isRunning: Bool { task != nil }

    /// At launch: the first check is one interval away.
    func start() { run(firstWait: interval) }

    /// The app went to the background.
    func pause() {
        task?.cancel()
        task = nil
    }

    /// The app is in front. A no-op while it is already running, so it is safe on every activation
    /// and at launch, when nothing was paused.
    func resume() {
        guard task == nil else { return }
        run(firstWait: Self.firstWait(interval: interval, since: lastCheck, now: now()))
    }

    /// How long a restart waits before its first check: what is left of the interval since the last
    /// answer, none if that is overdue. A short trip away is then noticed no later than the loop that
    /// merely skipped its ticks would have, and a long one is checked at once.
    nonisolated static func firstWait(interval: TimeInterval, since lastCheck: Date, now: Date) -> TimeInterval {
        let elapsed = now.timeIntervalSince(lastCheck)
        guard elapsed >= 0 else { return interval }   // the clock went back: wait a whole interval
        return max(0, interval - elapsed)
    }

    private func run(firstWait: TimeInterval) {
        task?.cancel()
        task = Task { [weak self] in
            var wait = firstWait
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                wait = self.interval
                guard self.isActive() else { continue }
                let checkedAt = self.now()
                // Overlap by a few seconds: `updated` is server time, and a change landing as the
                // previous check ran must not fall between the two.
                guard let changed = await self.check(self.lastCheck.addingTimeInterval(-10)) else { continue }
                self.lastCheck = checkedAt
                if changed { self.onChange() }
            }
        }
    }
}
