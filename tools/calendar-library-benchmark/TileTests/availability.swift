import Foundation
import CoreText
import CoreGraphics

/// Offscreen preparation availability, including publication on the main actor. Never UI latency.
@main
struct TileAvailability {
    @MainActor
    static func main() async throws {
        let config = CalendarFixtureConfiguration(), store = FixtureStore(CalendarFixtureConfiguration())
        let policy = Optimizations()
        let black = CGColor(gray: 0, alpha: 1)
        let style = RasterPage.Style(text: .init(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: .init(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        var samples: [[String: Any]] = [], checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
        }
        for (width, scale) in [(393.0, 3.0), (1200.0, 2.0)] {
            for trial in 0..<7 {
                let model = PrototypeModel(store: store)
                model.move(to: store.calendar.date(byAdding: .day, value: trial * model.dayCount, to: store.anchor)!)
                let renderer = TileRenderer()
                let viewport = CGRect(x: 0, y: 0, width: width, height: 800)
                check(renderer.install(days: model.layouts, width: width, height: 1920, gutter: 48,
                    scale: scale, viewport: viewport, style: style, lookahead: true), "Initial pixels missing")
                // These fixed fixtures fit two neighboring bands on the phone-sized surface,
                // and one on the desktop-sized surface under the unchanged 64 MiB policy.
                let offsets = width == 393 ? [model.dayCount, -model.dayCount] : [model.dayCount]
                var expected: [(RasterKey, [DayGeometry])] = []
                for offset in offsets {
                    let days = (0..<model.dayCount).map { day -> DayGeometry in
                        let date = store.calendar.date(byAdding: .day, value: offset + day, to: model.date)!
                        return DayGeometry(date: date, calendar: store.calendar, events: store.day(date), buildIndex: false)
                    }
                    for top in stride(from: 0.0, to: 800.0, by: 256.0) {
                        expected.append((RasterKey(dates: days.map(\.date), width: width, scale: scale, top: top, height: 256), days))
                    }
                }
                let began = ProcessInfo.processInfo.systemUptime
                renderer.preloadPages(store: store, date: model.date, dayCount: model.dayCount,
                    width: width, height: 1920, gutter: 48, scale: scale, viewport: viewport,
                    style: style, budgeted: true)
                let dispatchMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
                var firstMS: Double?, forwardMS: Double?, polls = 0
                while true {
                    let available = expected.map { renderer.cache.get($0.0) != nil }
                    let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    if firstMS == nil && available.contains(true) { firstMS = elapsed }
                    if forwardMS == nil && available.prefix(4).allSatisfy({ $0 }) { forwardMS = elapsed }
                    if available.allSatisfy({ $0 }) { break }
                    check(elapsed < 5_000, "Preparation did not produce every requested tile")
                    polls += 1
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let allMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
                let bytes = renderer.cache.bytes
                // Pixel and coverage comparisons are deliberately outside availability timing.
                for (key, days) in expected {
                    let actual = renderer.cache.get(key)!
                    let reference = autoreleasepool {
                        RasterPage.render(days: days, width: width, height: 1920, gutter: 48, scale: scale,
                            style: style, region: CGRect(x: 0, y: key.top, width: width, height: key.height))!
                    }
                    check(actual.ids == reference.ids, "Prepared tile IDs differ")
                    check(actual.image.dataProvider!.data! as Data == reference.image.dataProvider!.data! as Data,
                          "Worker queue changed pixels")
                }
                check(renderer.cache.bytes <= 64 * 1024 * 1024 && renderer.cache.count <= 24, "Cache budget exceeded")
                samples.append(["width": width, "scale": scale, "trial": trial, "dispatchMS": dispatchMS,
                    "firstTileMS": firstMS!, "forwardBandMS": forwardMS!, "allBandsMS": allMS,
                    "polls": polls, "cacheBytes": bytes, "preparedTiles": expected.count])
            }
        }
        let result: [String: Any] = ["scope": "Offscreen speculative tile readiness; 1 ms polling; not input/display latency",
            "ablation": policy.disabled, "queueConcurrency": policy.tilePreparationConcurrency,
            "checks": checks, "samples": samples, "peakResidentBytes": peakResidentBytes()]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/tile-availability.json")))
        print("PASS: \(checks) pixel/availability/cache checks")
    }
}
