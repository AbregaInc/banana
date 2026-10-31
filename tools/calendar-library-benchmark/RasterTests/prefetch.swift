import Foundation
import CoreGraphics

// Measures when prepared pixels become available, not when a display presents them.
// Offscreen views only: does not create, open or activate a window.
@main
@MainActor
struct PrefetchProbe {
    static func main() async throws {
        let config = CalendarFixtureConfiguration()
        let store = FixtureStore(config)
        let document = TimelineDocument(frame: CGRect(x: 0, y: 0, width: 1200, height: 1920))
        let surface = CalendarSurface(frame: document.bounds)
        document.addSubview(surface)
        precondition(surface.optimizations.renderer == "raster" && surface.optimizations.rasterPreload)
        let days = (0..<5).map { offset -> DayGeometry in
            let date = store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!
            return DayGeometry(date: date, calendar: store.calendar, events: store.day(date), buildIndex: false)
        }
        var samples: [[String: Any]] = []
        var valid = true
        for _ in 0..<5 {
            surface.evictSpareViews()
            surface.install(days, viewport: CGRect(x: 0, y: 0, width: 1200, height: 800))
            let before = surface.prefetchedRasterBuilds
            let start = ProcessInfo.processInfo.systemUptime
            surface.preloadText(store: store, date: store.anchor, dayCount: 5)
            var firstMS: Double?
            var firstCount = 0
            while surface.prefetchedRasterBuilds - before < 2 && ProcessInfo.processInfo.systemUptime - start < 5 {
                try await Task.sleep(nanoseconds: 1_000_000)
                let count = surface.prefetchedRasterBuilds - before
                if firstMS == nil && count > 0 {
                    firstMS = (ProcessInfo.processInfo.systemUptime - start) * 1000; firstCount = count
                }
            }
            let complete = surface.prefetchedRasterBuilds - before == 2
            valid = valid && complete && firstMS != nil && surface.rasterCache.count <= 3 && surface.rasterCache.bytes <= 128 * 1024 * 1024
            samples.append(["firstAvailableMS": firstMS as Any? ?? NSNull(), "firstObservedPageCount": firstCount,
                "bothAvailableMS": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                "complete": complete, "cacheBytes": surface.rasterCache.bytes])
        }
        let report: [String: Any] = ["scope": "Offscreen cache availability; 1 ms polling, not input/display latency",
            "ablation": surface.optimizations.disabled, "eventsPerDay": config.density, "dayCount": 5,
            "width": 1200, "scale": 1, "samples": samples, "valid": valid, "uiAcceptance": "unmeasured"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/calendar-prefetch.json")), options: .atomic)
        if !valid { exit(1) }
        print("PASS: five offscreen prefetch-availability trials, \(surface.optimizations.disabled)")
    }
}
