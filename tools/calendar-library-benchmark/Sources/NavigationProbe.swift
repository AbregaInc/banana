import UIKit

/// Programmatic race/cancellation correctness, not input/display timing.
@MainActor
enum NavigationProbe {
    static func run(_ native: NativeController) async -> [String: Any] {
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func date(_ offset: Int) -> Date {
            native.model.store.calendar.date(byAdding: .day, value: offset, to: native.model.store.anchor)!
        }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return condition()
        }
        check(native.model.store.config.value("--async-workers", "0") == "2", "Probe requires two foreground workers")
        for trial in 0..<10 {
            let start = trial * 10
            native.move(to: date(start)); native.memoryPressure()
            native.moveInteractive(1)
            let started = await wait { native.surface.tiles.isPreparingForeground }
            check(started, "Foreground preparation did not start in trial \(trial)")
            check(native.model.date == date(start), "Pending work changed the published model")
            // Cancel a running request, allow its continuation to run, then append input.
            // An obsolete defer must not clear the newer request's accumulated intent.
            native.moveInteractive(1)
            await Task.yield()
            native.moveInteractive(1)
            let completed = await wait { native.requestedDate == nil }
            check(completed && native.model.date == date(start + native.model.dayCount * 3),
                  "Rapid supersession lost navigation intent in trial \(trial)")
            let state = native.validation()
            check(state["visibleIDsMatch"] as? Bool == true && state["drawCoverageMatches"] as? Bool == true,
                  "Rapid supersession published stale pixels")
        }
        native.move(to: date(0)); native.memoryPressure()
        native.moveInteractive(1)
        let started = await wait { native.surface.tiles.isPreparingForeground }
        check(started, "Eviction race did not start")
        native.memoryPressure()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(native.model.date == date(0) && native.requestedDate == nil,
              "Evicted request published after cancellation")
        native.moveInteractive(1)
        let recovered = await wait { native.requestedDate == nil }
        check(recovered && native.model.date == date(native.model.dayCount), "Navigation did not recover after eviction")
        return ["status": failures.isEmpty ? "passed" : "failed", "checks": checks, "failures": failures,
                "scope": "Programmatic native controller cancellation/supersession correctness; not UI latency",
                "eventsPerDay": native.model.store.config.density]
    }
}
