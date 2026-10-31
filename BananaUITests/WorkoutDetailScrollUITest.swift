import XCTest

/// Regression test for the "can't scroll the swim detail" report: `WorkoutChartsSection`'s
/// drag-to-scrub overlay used to be a plain, ungated `.gesture(DragGesture(minimumDistance: 0))`,
/// which — per SwiftUI's own gesture disambiguation — wins first-touch priority over the ancestor
/// `ScrollView` and claims a touch before any direction is even known. Since the Heart Rate chart
/// is the first large, full-width element under the hero header (the most natural place for a
/// first scroll attempt to land), this silently ate the page's scroll on ANY chart touch.
///
/// Measured with a real `XCUIApplication` drag that even the textbook fix — `.simultaneousGesture`
/// plus a direction gate, matching `HandPathView.orbitDrag`'s own approach — did NOT restore: a
/// drag beginning on a `.simultaneousGesture`-attached `DragGesture` still moved the page 0pt here,
/// regardless of direction gating or gesture shape. `ChartScrubOverlay` (`WorkoutChartsSection.
/// swift`) was fixed by dropping the `DragGesture` entirely in favor of `.onTapGesture` — see its
/// doc comment for the full trade-off (tap-to-inspect instead of drag-to-scrub).
///
/// `--workout-detail latest-swim` (`WorkoutDetailDebugHost`), not `--runmap`
/// (`FitnessStore.injectSampleForPreview`) — the injected fixture races `FitnessStore`'s own async
/// disk load on a truly empty store (confirmed on a fresh `simctl uninstall`/reinstall: the
/// fixture never appears, "no workout" sticks indefinitely) and is a pre-existing gap in that
/// debug route, not something this change touches. `WorkoutDetailDebugHost` correctly `await`s
/// `fitness.whenLoaded()` before resolving, so it doesn't share that race — but it does mean this
/// test needs a real local pool swim to run against. `XCTSkip`s rather than fails when this
/// Simulator/account has none, so a fresh checkout without the owner's Fitness data skips cleanly
/// instead of reporting a false regression.
final class WorkoutDetailScrollUITest: XCTestCase {
    func testDragOnHeartRateChartScrollsThePage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workout-detail", "latest-swim", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let chart = app.otherElements["workout.chart.Heart rate"]
        guard chart.waitForExistence(timeout: 20) else {
            throw XCTSkip("No local pool swim with a heart rate series on this Simulator/account — nothing to drag against.")
        }
        let frameBefore = chart.frame

        // A drag starting squarely inside the chart's own plot area.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frameBefore.midX, dy: frameBefore.minY + 0.7 * frameBefore.height))
        let end = origin.withOffset(CGVector(dx: frameBefore.midX, dy: frameBefore.minY + 0.2 * frameBefore.height))
        start.press(forDuration: 0, thenDragTo: end)

        // Either the chart scrolled off past the top edge, or its frame moved by a real amount —
        // not the near-zero jitter a swallowed touch would leave.
        let scrolled = NSPredicate { _, _ in
            !chart.exists || abs(chart.frame.minY - frameBefore.minY) > 20
        }
        let exp = expectation(for: scrolled, evaluatedWith: chart)
        wait(for: [exp], timeout: 4)
    }
}
