#if DEBUG && os(iOS)
import UIKit
import QuartzCore

/// Main-run-loop display-link cadence, useful for detecting scheduling stalls. This does not
/// measure compositor delivery, GPU completion, or input-to-visible-response latency. In
/// particular, callback gaps cannot certify the 8.3 ms rendering contract on 120 Hz hardware.
/// `RenderStats` counts view-body evaluations; this probe complements it with callback timing.
///
/// Built for one investigation: whether `WorkoutMotionSection`'s 3D acceleration signature
/// (`Chart3D`, thousands of `PointMark`s) or the hand path (`Canvas`, `HandPathScene`'s
/// depth-sorted line segments) actually drops frames under continuous pose changes — see both
/// views' doc comments. Gated behind `--frame-probe` so it costs nothing unless explicitly asked
/// for; never compiled into Release at all.
@MainActor
enum FrameProbe {
    private static var link: CADisplayLink?
    private static var lastTimestamp: CFTimeInterval = 0
    private static var frameCount = 0
    /// A frame whose delta from the previous one exceeds 2× the display's own frame interval —
    /// i.e. at least one frame was dropped, not just ordinary jitter.
    private static var hitchCount = 0
    private static var windowStart: CFTimeInterval = 0
    private static var label = "frame-probe"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--frame-probe")
    }

    /// Starts (or restarts, if already running) a 1-second rolling report under `label` — each
    /// window's fps/hitch count is written to `PlaybackDiagnostics`'s journal as it completes, so
    /// a caller driving a timed interaction (a UI test's scripted drag, say) can read the journal
    /// back afterward and see exactly which second was slow.
    static func start(label: String) {
        stop()
        self.label = label
        frameCount = 0
        hitchCount = 0
        lastTimestamp = 0
        windowStart = CACurrentMediaTime()
        let target = FrameProbeTarget()
        let l = CADisplayLink(target: target, selector: #selector(FrameProbeTarget.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    static func stop() {
        link?.invalidate()
        link = nil
        if frameCount > 0 { report() }
    }

    fileprivate static func tick(_ displayLink: CADisplayLink) {
        let now = displayLink.timestamp
        if lastTimestamp > 0 {
            let delta = now - lastTimestamp
            frameCount += 1
            if delta > displayLink.duration * 2 { hitchCount += 1 }
        }
        lastTimestamp = now
        if now - windowStart >= 1.0 {
            report()
            frameCount = 0
            hitchCount = 0
            windowStart = now
        }
    }

    private static func report() {
        let elapsed = max(CACurrentMediaTime() - windowStart, 0.001)
        let fps = Double(frameCount) / elapsed
        PlaybackDiagnostics.shared.log("📈 FRAME PROBE \(label)",
                                       "fps=\(String(format: "%.1f", fps)) hitches=\(hitchCount) frames=\(frameCount) window=\(String(format: "%.2f", elapsed))s")
    }
}

/// `CADisplayLink`'s target must be an `NSObject` with an `@objc` selector — `FrameProbe` itself
/// is an `enum` and can't be one, so this exists only to receive the callback and forward it.
/// `MainActor.assumeIsolated`, not `Task { @MainActor in }` — a `CADisplayLink` callback always
/// fires synchronously on the main run loop already; hopping through a `Task` would add its own
/// scheduling latency and corrupt the very frame timing this exists to measure precisely.
private final class FrameProbeTarget: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { FrameProbe.tick(link) }
    }
}
#endif
