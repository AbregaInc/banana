import Foundation
import CoreText
import CoreGraphics
import ImageIO

@MainActor
private final class Heartbeat {
    var running = true
    var started = false
    var stamps = [ProcessInfo.processInfo.systemUptime]
    func run() async {
        started = true
        while running {
            try? await Task.sleep(nanoseconds: 1_000_000)
            stamps.append(ProcessInfo.processInfo.systemUptime)
        }
    }
    var maxGapMS: Double { zip(stamps, stamps.dropFirst()).map { ($1 - $0) * 1000 }.max() ?? 0 }
}

@main
struct AsyncTileChecks {
    @MainActor
    static func main() async throws {
        let config = CalendarFixtureConfiguration(), store = FixtureStore(CalendarFixtureConfiguration())
        let model = PrototypeModel(store: store); model.move(to: store.anchor)
        let black = CGColor(gray: 0, alpha: 1)
        var style = RasterPage.Style(text: .init(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: .init(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        let memoryProbe = config.args.contains("--memory-probe")
        precondition(!memoryProbe || ["0", "1", "2"].contains(config.value("--workers", "all")))
        var referenceStyle = style
        referenceStyle.batchEventFills = false
        style.pixelBuffer = Optimizations().tilePixelBuffer
        style.nativeText = Optimizations().tileNativeText
        var checks = 0, samples: [[String: Any]] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition {
                let failure: [String: Any] = ["status": "failed", "failure": message, "checks": checks,
                    "eventsPerDay": config.density, "fixture": store.fixtureSummary, "samples": samples]
                try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/calendar-async-tiles.json")))
                FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
            }
        }
        func stamp() -> Double { ProcessInfo.processInfo.systemUptime }
        for trial in 0..<7 {
            model.move(to: store.calendar.date(byAdding: .day, value: trial * 5, to: store.anchor)!)
            for (width, scale) in [(393.0, 3.0), (1200.0, 2.0)] {
                let viewport = CGRect(x: 0, y: 0, width: width, height: 800)
                let selection = config.value("--workers", "all")
                precondition(["all", "0", "1", "2"].contains(selection))
                let policies = selection == "all" ? (trial.isMultiple(of: 2) ? [0, 1, 2] : [2, 1, 0]) : [Int(selection)!]
                for workers in policies {
                    let renderer = TileRenderer()
                    for phase in ["cold", "warm", "eviction"] {
                        if phase == "eviction" { renderer.evict() }
                        let heartbeat = Heartbeat()
                        let ticking = Task { await heartbeat.run() }
                        while !heartbeat.started { await Task.yield() }
                        let began = stamp()
                        var prepared: [RasterKey: RasterPage]?
                        if workers > 0 {
                            prepared = await renderer.prepareInstall(days: model.layouts, width: width,
                                height: 1920, gutter: 48, scale: scale, viewport: viewport,
                                style: style, workers: workers)
                            check(prepared != nil, "Foreground preparation failed")
                        }
                        let installStart = stamp()
                        let installed = renderer.install(days: model.layouts, width: width, height: 1920,
                            gutter: 48, scale: scale, viewport: viewport, style: style,
                            lookahead: true, prepared: prepared)
                        let installMS = (stamp() - installStart) * 1000
                        let totalMS = (stamp() - began) * 1000
                        heartbeat.running = false; await ticking.value
                        check(installed && renderer.contentsPresent, "Complete band did not install")
                        check(renderer.cache.bytes <= 64*1024*1024 && renderer.cache.count <= 24,
                              "Foreground preparation exceeded spare-cache bounds")
                        if workers > 0 {
                            check(renderer.builds == 0, "Prepared install fell back to main-thread rendering")
                            for (key, page) in (memoryProbe ? [:] : prepared!) {
                                let region = CGRect(x: 0, y: key.top, width: width, height: key.height)
                                let oracle = RasterPage.render(days: model.layouts, width: width, height: 1920,
                                    gutter: 48, scale: scale, style: referenceStyle, region: region)!
                                check(page.ids == oracle.ids, "Background preparation changed event IDs")
                                let actualImage = page.image, expectedImage = oracle.image
                                let actual = actualImage.dataProvider!.data! as Data
                                let expected = expectedImage.dataProvider!.data! as Data
                                if actual != expected {
                                    let output = URL(fileURLWithPath: config.value("--output", "/tmp/calendar-async-tiles.json"))
                                    for (name, image) in [("actual", actualImage), ("expected", expectedImage)] {
                                        let url = output.deletingPathExtension().appendingPathExtension(name + ".png")
                                        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                                            CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
                                        }
                                    }
                                    var differences: [[String: Int]] = [], count = 0
                                    for index in 0..<min(actual.count, expected.count) where actual[index] != expected[index] {
                                        count += 1
                                        if differences.count < 20 {
                                            differences.append(["x": (index % actualImage.bytesPerRow) / 4,
                                                "y": index / actualImage.bytesPerRow, "channel": index % 4,
                                                "actual": Int(actual[index]), "expected": Int(expected[index])])
                                        }
                                    }
                                    samples.append(["failureContext": true, "trial": trial, "workers": workers,
                                        "phase": phase, "width": width, "scale": scale, "tileTop": key.top,
                                        "pixelWidth": actualImage.width, "rowBytes": actualImage.bytesPerRow,
                                        "differentBytes": count, "firstDifferences": differences])
                                }
                                check(actual == expected, "Background preparation changed pixels")
                            }
                        }
                        samples.append(["trial": trial, "width": width, "scale": scale, "workers": workers,
                            "phase": phase, "totalMS": totalMS, "installMS": installMS,
                            "measuredMainSectionsMS": installMS + (workers > 0 ? renderer.foregroundDispatchMS + renderer.foregroundCompletionMS : 0),
                            "heartbeatMaxGapMS": heartbeat.maxGapMS, "cacheBytes": renderer.cache.bytes,
                            "activeBytes": renderer.activeBytes, "peakResidentBytes": peakResidentBytes(),
                            "physicalFootprintBytes": physicalFootprintBytes()])
                    }
                }
            }
        }
        // Existing pixels survive until the entire new band is ready, including when
        // the spare LRU is deliberately too small to retain even one tile.
        let tiny = TileRenderer(cache: RasterCache(byteLimit: 1024, countLimit: 1))
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        check(tiny.install(days: model.layouts, width: 1200, height: 1920, gutter: 48, scale: 3,
                           viewport: viewport, style: style), "Initial presentation failed")
        let oldIDs = tiny.ids, oldBuilds = tiny.builds
        model.move(to: store.calendar.date(byAdding: .day, value: 5, to: model.date)!)
        let future = model.layouts
        let pending = Task { await tiny.prepareInstall(days: future, width: 1200, height: 1920,
            gutter: 48, scale: 3, viewport: viewport, style: style, workers: 2) }
        let deadline = stamp() + 5
        while !tiny.isPreparingForeground && stamp() < deadline { await Task.yield() }
        check(tiny.isPreparingForeground && tiny.ids == oldIDs, "Preparation changed active presentation")
        let ready = await pending.value
        check(ready != nil && tiny.ids == oldIDs, "Readiness published partial pixels")
        check(tiny.install(days: future, width: 1200, height: 1920, gutter: 48, scale: 3,
            viewport: viewport, style: style, prepared: ready), "Atomic prepared install failed")
        check(tiny.builds == oldBuilds && tiny.cache.bytes <= 1024 && tiny.ids != oldIDs,
              "Small LRU caused synchronous fallback or stale content")
        tiny.evict()
        let cancelled = Task { await tiny.prepareInstall(days: future, width: 1200, height: 1920,
            gutter: 48, scale: 3, viewport: viewport, style: style, workers: 2) }
        let cancelDeadline = stamp() + 5
        while !tiny.isPreparingForeground && stamp() < cancelDeadline { await Task.yield() }
        check(tiny.isPreparingForeground, "Cancellation probe did not start")
        tiny.clear()
        let retired = await cancelled.value
        check(retired == nil && tiny.cache.bytes == 0 && !tiny.contentsPresent,
              "Cancelled generation republished pixels")
        // Resolving a destination must not change the currently published model page.
        let beforeDate = model.date, beforeLayouts = model.layouts.map(\.date)
        let destination = store.calendar.date(byAdding: .day, value: 10, to: beforeDate)!
        let resolved = model.resolve(to: destination)
        check(model.date == beforeDate && model.layouts.map(\.date) == beforeLayouts,
              "Resolving a future page published it prematurely")
        model.move(to: destination, prepared: resolved)
        check(model.date == destination && model.layouts.map(\.date) == resolved.map(\.date),
              "Prepared geometry did not commit coherently")
        // A new request retires prior work; completing it later cannot fill the new cache.
        let superseded = Task { await tiny.prepareInstall(days: future, width: 1200, height: 1920,
            gutter: 48, scale: 3, viewport: viewport, style: style, workers: 2) }
        let supersedeDeadline = stamp() + 5
        while !tiny.isPreparingForeground && stamp() < supersedeDeadline { await Task.yield() }
        check(tiny.isPreparingForeground, "Supersession probe did not start")
        let replacement = await tiny.prepareInstall(days: resolved, width: 1200, height: 1920,
            gutter: 48, scale: 3, viewport: viewport, style: style, workers: 2)
        let oldResult = await superseded.value
        check(oldResult == nil && replacement != nil, "Obsolete foreground request survived supersession")
        check(replacement!.keys.allSatisfy { $0.dates == resolved.map(\.date) }, "Replacement contains retired dates")
        tiny.clear()
        let parentCancelled = Task { await tiny.prepareInstall(days: resolved, width: 1200, height: 1920,
            gutter: 48, scale: 3, viewport: viewport, style: style, workers: 2) }
        let parentDeadline = stamp() + 5
        while !tiny.isPreparingForeground && stamp() < parentDeadline { await Task.yield() }
        check(tiny.isPreparingForeground, "Parent cancellation probe did not start")
        parentCancelled.cancel()
        let parentResult = await parentCancelled.value
        check(parentResult == nil && tiny.cache.bytes == 0 && !tiny.isPreparingForeground,
              "Parent cancellation retained or published work")
        try JSONSerialization.data(withJSONObject: ["status": memoryProbe ? "memory-probe-complete" : "passed", "checks": checks, "pixelOracle": !memoryProbe, "eventsPerDay": config.density, "fixture": store.fixtureSummary, "batchEventFills": style.batchEventFills, "memoRasterText": style.memoText, "mode": config.mode, "visibleDays": model.dayCount,
            "scope": "Offscreen component ablation; measured main sections exclude runtime bookkeeping; heartbeat scheduling is not frame/input/display latency",
            "samples": samples], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/calendar-async-tiles.json")))
        print("\(memoryProbe ? "MEMORY PROBE" : "PASS"): \(checks) async preparation checks; pixel oracle \(!memoryProbe)")
    }
}
