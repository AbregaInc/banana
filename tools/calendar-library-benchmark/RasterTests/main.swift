import Foundation
import CoreGraphics
import CoreText

@main
struct RasterChecks {
    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            if !ok { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 0)
        // An asymmetric interval catches vertically flipped images; a full-day fill cannot.
        let events = [Fixture(id: "one", start: date.addingTimeInterval(3600), end: date.addingTimeInterval(7200))]
        let days = [DayGeometry(date: date, calendar: calendar, events: events)]
        let black = CGColor(gray: 0, alpha: 1)
        let style = RasterPage.Style(text: PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        for scale in [1.0, 2.0, 3.0] {
            let page = RasterPage.render(days: days, width: 200, height: 1920, gutter: 48, scale: scale, style: style)!
            check(page.ids == ["0:one"], "raster omitted an event")
            check(page.image.width == Int(200 * scale) && page.image.height == Int(1920 * scale), "raster scale incorrect")
            let bytes = page.image.dataProvider!.data! as Data
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = Int(Double(y) * scale) * page.image.bytesPerRow + Int(Double(x) * scale) * 4
                return Array(bytes[offset..<(offset + 4)])
            }
            check(pixel(3, 50) == [255, 255, 255, 255], "raster background or orientation incorrect")
            let eventPixel = pixel(120, 100)
            check(eventPixel[0] < 230 && eventPixel[1] < 230 && eventPixel[2] == 255 && eventPixel[3] == 255,
                  "event missing from expected raster position")
            check(pixel(120, 180) == [255, 255, 255, 255], "raster painted outside the event interval")
            let task = Task.detached { RasterPage.render(days: days, width: 200, height: 1920, gutter: 48, scale: scale, style: style)! }
            let worker = await task.value
            check(bytes == worker.image.dataProvider!.data! as Data, "worker raster differs from synchronous raster")
            let cache = RasterCache(byteLimit: page.bytes * 2, countLimit: 2)
            let keys = (0..<3).map { RasterKey(dates: [date.addingTimeInterval(Double($0) * 86400)], width: 200, scale: scale) }
            cache.put(page, for: keys[0]); cache.put(page, for: keys[1]); _ = cache.get(keys[0]); cache.put(page, for: keys[2])
            check(cache.count == 2 && cache.bytes == page.bytes * 2 && cache.get(keys[1]) == nil, "raster LRU/count limit failed")
            check(cache.get(RasterKey(dates: [date], width: 201, scale: scale)) == nil, "resize reused incorrect image")
            cache.clear(); check(cache.count == 0 && cache.bytes == 0, "raster eviction retained memory")
            let small = RasterCache(byteLimit: page.bytes - 1)
            small.put(page, for: keys[0]); check(small.bytes == 0 && small.count == 0, "oversized raster entered bounded cache")
        }
        // Offscreen AppKit objects only: no application activation or window is created.
        let document = TimelineDocument(frame: CGRect(x: 0, y: 0, width: 200, height: 1920))
        let surface = CalendarSurface(frame: document.bounds)
        document.addSubview(surface)
        check(surface.optimizations.renderer == "raster", "Run raster checks with --renderer raster")
        let viewport = CGRect(x: 0, y: 0, width: 200, height: 800)
        var timings: [Double] = []
        var retained = true
        for _ in 0..<200 {
            surface.install(days, viewport: viewport)
            check(surface.rasterContentsPresent, "raster layer was never populated")
            let start = DispatchTime.now().uptimeNanoseconds
            surface.evictSpareViews()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            retained = retained && surface.rasterContentsPresent
        }
        let config = CalendarFixtureConfiguration()
        let sorted = timings.sorted()
        let report: [String: Any] = ["scope": "Offscreen layer eviction component; no window/display/input evidence",
            "samplesMS": timings, "p50MS": sorted[99], "p95MS": sorted[189], "p99MS": sorted[197], "maxMS": sorted.last!,
            "retainedActiveImage": retained]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/calendar-raster-retention.json")), options: .atomic)
        check(retained, "Memory pressure removed the active raster image")
        surface.install([], viewport: viewport)
        check(!surface.rasterContentsPresent && surface.presentations.isEmpty && surface.drawnIDs.isEmpty,
              "Empty page retained stale raster content")
        print("PASS: \(checks) raster checks (pixels, worker equivalence, limits, LRU, resize, eviction, active-image retention)")
    }
}
