import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Catches the main thread stuck for `threshold` or longer while the app is in front, reads its
/// stack while it is still stuck, and reports the hang once it ends (`ProblemReporter`).
///
/// It runs only while the app is active and Share usage is on: a utility-queue timer every half
/// second sends one empty block to the main queue and sees whether the last one ran. With the
/// screen on that is nothing next to drawing a frame; in the background it isn't running at all.
final class HangDetector: @unchecked Sendable {
    static let shared = HangDetector()
    static let threshold: TimeInterval = 1.5
    private static let interval: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "app.banana.hang-detector", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Queue-confined.
    private var pingSentAt: UInt64?
    private var hangStartedAt: UInt64?
    private var stack: String?
    /// Told the duration and stack when a hang ends. Called on the detector's queue.
    var onHang: (@Sendable (_ seconds: Double, _ stack: String?) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// Follows the app coming forward and going back. `enabled` is asked each time it comes forward.
    @MainActor
    func install(enabled: @escaping @MainActor () -> Bool) {
        guard observers.isEmpty else { return }
        MainThreadSampler.remember()
        let center = NotificationCenter.default
        #if os(iOS)
        let active = UIApplication.didBecomeActiveNotification, inactive = UIApplication.willResignActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification, inactive = NSApplication.didResignActiveNotification
        #endif
        observers.append(center.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if enabled() { self?.start() } else { self?.stop() } }
        })
        observers.append(center.addObserver(forName: inactive, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        })
        if enabled() { start() }
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            pingSentAt = nil
            hangStartedAt = nil
            stack = nil
        }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let sent = pingSentAt else {
            pingSentAt = now
            DispatchQueue.main.async { [weak self] in
                let answered = DispatchTime.now().uptimeNanoseconds
                self?.queue.async { self?.pong(at: answered) }
            }
            return
        }
        let waited = Double(now - sent) / 1_000_000_000
        if waited >= Self.threshold, hangStartedAt == nil {
            hangStartedAt = sent
            // Read while it is still stuck: that is the frame that matters.
            stack = MainThreadSampler.sample()
        }
    }

    private func pong(at answered: UInt64) {
        defer { pingSentAt = nil }
        guard let started = hangStartedAt else { return }
        let seconds = Double(answered - started) / 1_000_000_000
        let caught = stack
        hangStartedAt = nil
        stack = nil
        onHang?(seconds, caught)
    }
}
