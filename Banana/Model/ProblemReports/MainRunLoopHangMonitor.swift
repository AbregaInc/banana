import CoreFoundation
import Foundation
import os

/// Arm one deadline for a burst of run-loop work. A waiting loop never arms another.
final class MainRunLoopHangMonitor: @unchecked Sendable {
    private struct State {
        var timer: DispatchSourceTimer?
        var observers: [CFRunLoopObserver] = []
        var active = false
        var since: UInt64?
        var deadlinePending = false
        var caught: UInt64?
        var generation: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "watch.sample", qos: .utility)
    private let delay: UInt64
    private let sample: @Sendable () -> String?
    private let report: @Sendable (Double, String?) -> Void
    private var observers: [CFRunLoopObserver] = []
    // Only accessed on the detector queue.
    private var captured: (UInt64, String?)?

    init(threshold: Double, sample: @escaping @Sendable () -> String?, report: @escaping @Sendable (Double, String?) -> Void) {
        delay = UInt64(threshold * 1e9)
        self.sample = sample
        self.report = report
    }

    @MainActor func start() {
        guard observers.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let generation = state.withLock { s in
            s.active = true
            s.timer = timer
            return s.generation
        }
        timer.setEventHandler { [weak self] in self?.check(generation: generation) }
        timer.activate()
        // Arm before other observers can handle work. Disarm after their final
        // before-waiting callbacks, which can perform drawing and layout themselves.
        let waiting = CFRunLoopActivity.beforeWaiting.rawValue
        for (mask, order) in [(CFRunLoopActivity.allActivities.rawValue & ~waiting, Int.min), (waiting, Int.max)] {
            let observer = CFRunLoopObserverCreateWithHandler(nil, mask, true, order) { [weak self] _, activity in
                self?.advanced(waiting: activity == .beforeWaiting)
            }!
            observers.append(observer)
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        state.withLock { $0.observers = observers }
        advanced(waiting: false)
    }

    @MainActor func stop() {
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
        state.withLock { s in
            s.timer?.cancel()
            let next = s.generation &+ 1
            s = State()
            s.generation = next
        }
        queue.async { [weak self] in self?.captured = nil }
    }

    private func advanced(waiting: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        state.withLock { s in
            guard s.active else { return }
            if let caught = s.caught {
                s.caught = nil
                // Report even if `stop()` follows at once: a hang that ends because the person
                // left the app is one worth reporting. The serial queue runs this before the
                // cleanup `stop()` queues, so the captured stack is still there.
                queue.async { [weak self] in
                    guard let self else { return }
                    let stack = self.captured?.0 == caught ? self.captured?.1 : nil
                    self.captured = nil
                    self.report(Double(now - caught) / 1e9, stack)
                }
            }
            s.since = waiting ? nil : now
            if !waiting && !s.deadlinePending {
                s.deadlinePending = true
                schedule(s.timer, at: now + delay)
            }
        }
    }

    private func schedule(_ timer: DispatchSourceTimer?, at deadline: UInt64) {
        timer?.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .milliseconds(5))
    }

    private func check(generation: UInt64) {
        let suspect: (UInt64, [CFRunLoopObserver])? = state.withLock { s in
            guard s.active, s.generation == generation else { return nil }
            guard let since = s.since else { s.deadlinePending = false; return nil }
            let deadline = since + delay
            guard DispatchTime.now().uptimeNanoseconds >= deadline else {
                schedule(s.timer, at: deadline)
                return nil
            }
            s.deadlinePending = false
            return (since, s.observers)
        }
        guard let (since, observers) = suspect else { return }
        let main = CFRunLoopGetMain()
        if let mode = CFRunLoopCopyCurrentMode(main), let first = observers.first,
           !CFRunLoopContainsObserver(main, first, mode) {
            // A nested private mode can stay responsive without delivering common-mode
            // notifications. Observe it and let it acknowledge a wake before sampling.
            for observer in observers { CFRunLoopAddObserver(main, observer, mode) }
            state.withLock { s in
                guard s.active, s.generation == generation, s.since == since, !s.deadlinePending else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                s.since = now
                s.deadlinePending = true
                schedule(s.timer, at: now + delay)
            }
            CFRunLoopWakeUp(main)
            return
        }
        let capture = state.withLock { s in
            guard s.active, s.generation == generation, s.since == since, s.caught == nil else { return false }
            s.caught = since
            return true
        }
        if capture { captured = (since, sample()) }
    }
}
