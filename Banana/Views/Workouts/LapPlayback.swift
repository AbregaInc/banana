import Foundation

/// Drives the "play" control both `HandPathView` and `WorkoutMotionSection.MotionSignatureCard`
/// offer to auto-advance through every lap — the owner's own reasoning: watching the signature (or
/// the hand path) change lap by lap makes wobble over time visible in a way stepping through by
/// hand does not.
///
/// A plain `Task.sleep` loop, not a `Timer`: the caller attaches `run(advance:)` to a
/// `.task(id: isPlaying)` modifier, which SwiftUI cancels automatically both when `isPlaying`
/// flips back to `false` (the pause/stop path) and when the hosting view disappears entirely —
/// "stop when the view goes away" falls out of the platform's own task lifecycle instead of needing
/// manual `onDisappear` bookkeeping. Nothing here recomputes anything: `advance` is the caller's
/// own page-increment closure over data it already has cached (the per-lap cycles/points arrays
/// `WorkoutMotionCache` already resolved), so one tick of this driver is just an `Int` increment
/// and a read of already-resolved `@State`.
@MainActor
enum LapPlayback {
    /// Once per second — fast enough that even a real 70+ lap swim finishes a full pass in about a
    /// minute, slow enough that a lap-to-lap change registers as an actual change (the owner's own
    /// "more than a shimmer" bar) rather than a flicker, especially with the lap number and its key
    /// figure changing in view at the same pace.
    static let stepInterval: Duration = .seconds(1)

    /// Runs until `advance` returns `false` (reached the last page — the caller's own "stop, don't
    /// wrap" decision) or the surrounding `.task` is cancelled. Sleeps first so the page the user
    /// was already looking at gets its full interval before the first auto-advance.
    static func run(advance: @escaping () -> Bool) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: stepInterval)
            if Task.isCancelled { return }
            if !advance() { return }
        }
    }
}
