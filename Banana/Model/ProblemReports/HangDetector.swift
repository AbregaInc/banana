import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Captures a stuck foreground main thread while Share usage is enabled, then reports
/// the duration and live stack when the thread recovers.
final class HangDetector: @unchecked Sendable {
    static let shared = HangDetector()
    static let threshold: TimeInterval = 1.5

    /// Called on the detector queue when the main thread resumes.
    var onHang: (@Sendable (_ seconds: Double, _ stack: String?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    @MainActor private lazy var watch = MainRunLoopHangMonitor(threshold: Self.threshold, sample: {
        MainThreadSampler.sample()
    }) { [weak self] seconds, stack in self?.onHang?(seconds, stack) }

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
            MainActor.assumeIsolated { self?.stop() }
        })
        #if DEBUG && STRESS_DEVICE_AUDIT && os(iOS)
        let arguments = ProcessInfo.processInfo.arguments
        if enabled(), let option = arguments.firstIndex(of: "--stress-test-hang-recovery"),
           let token = arguments.dropFirst(option + 1).first.flatMap(UUID.init(uuidString:)) {
            // Keep the deliberate fixture hang local. The observer still captures its
            // live thread stack, but the normal problem-report outbox receives nothing.
            let mode = "run-loop"
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let file = folder.appendingPathComponent("stress-hang-recovery-" + mode + ".json")
            onHang = { seconds, stack in
                let value: [String: Any] = ["mode": mode, "run": token.uuidString, "seconds": seconds,
                                            "capturedStack": stack?.isEmpty == false]
                if let data = try? JSONSerialization.data(withJSONObject: value) {
                    try? data.write(to: file, options: .atomic)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Thread.sleep(forTimeInterval: 2.8)
            }
        }
        #endif
        #if os(iOS)
        let currentlyActive = UIApplication.shared.applicationState == .active
        #else
        let currentlyActive = NSApplication.shared.isActive
        #endif
        if currentlyActive && enabled() { start() }
    }

    @MainActor private func start() {
        #if DEBUG && STRESS_DEVICE_AUDIT
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--stress-measure-hang-detector") {
            let paused = args.contains("--stress-pause-hang-detector")
            PlaybackDiagnostics.shared.log("fixture", paused ? "hang heartbeat paused" : "hang heartbeat run-loop")
            if paused { return }
        }
        #endif
        watch.start()
    }

    @MainActor private func stop() {
        watch.stop()
    }
}
