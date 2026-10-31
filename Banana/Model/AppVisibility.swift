import SwiftUI

/// Is anyone actually looking at the app?
///
/// `@Environment(\.scenePhase)` read inside `PlannerTab` did NOT gate: with the app demonstrably
/// backgrounded, PlannerTab's body still ran and still built TodayView — the environment value is
/// stale inside the new TabView's `Tab {}` content closure. RootView's `.onChange(of: scenePhase)`
/// fires reliably (it's what writes "app → background" to the journal every single time), so this
/// takes the signal from the place that provably works and publishes it somewhere any view can
/// trust.
///
/// This exists because an audio app keeps running with the screen off, and this one kept RENDERING
/// there too — the whole view tree, several times a second, in a pocket, until iOS killed it for
/// burning a core. Three times in one day.
@MainActor
final class AppVisibility: ObservableObject {
    static let shared = AppVisibility()

    /// Whether the app is in the foreground. Gates WORK: write-back, re-planning, timers.
    /// Flips the instant the scene backgrounds, because none of that should run in a pocket.
    @Published private(set) var isActive = true

    /// Whether the view tree should still draw. Gates RENDERING only, and lags `isActive` by a
    /// short grace period on the way down.
    ///
    /// iOS takes the app-switcher snapshot *after* the scene enters the background. Blanking the
    /// tree the moment that happened meant the snapshot captured the blank — so the app showed as
    /// a black rectangle when swiping between apps, and, worse, on the way back in: the black is
    /// what you see until the tree rebuilds. Holding the drawing for a moment lets iOS photograph
    /// the real screen, and costs a second or two of the render loop this gate exists to stop —
    /// against the minutes or hours of it that actually burned the CPU budget.
    @Published private(set) var rendersContent = true

    /// How long the tree keeps drawing after the app backgrounds.
    ///
    /// Long enough for iOS to take its snapshot, which it does promptly after backgrounding, and
    /// short enough that a phone going into a pocket stops rendering almost immediately. The
    /// failure this protects against was continuous rendering, not a couple of seconds of it.
    /// A `var` so tests can shorten it; nothing in the app changes it.
    static var snapshotGrace: TimeInterval = 2.5

    private var blankTask: Task<Void, Never>?

    func set(active: Bool) {
        if active {
            // Returning to the foreground must never leave a queued blanking behind to fire a
            // second later over a screen the user is already looking at.
            blankTask?.cancel()
            blankTask = nil
            if !rendersContent { rendersContent = true }
            if !isActive { isActive = true }
            return
        }

        guard isActive else { return }   // don't publish what hasn't changed
        isActive = false
        blankTask?.cancel()
        blankTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.snapshotGrace))
            guard !Task.isCancelled else { return }
            self?.rendersContent = false
            self?.blankTask = nil
        }
    }

    /// Test seam: apply the blanking immediately rather than waiting out the grace.
    func blankNowForTesting() {
        blankTask?.cancel()
        blankTask = nil
        rendersContent = false
    }
}
