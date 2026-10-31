import SwiftUI
import AppKit

@main struct RasterChecks {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            FileHandle.standardError.write(Data("Refusing to overwrite raster evidence\n".utf8)); exit(2)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0
        func check(_ passed: Bool, _ message: String) {
            checks += 1
            if !passed {
                let failure: [String: Any] = ["status": "fail", "checks": checks, "failure": message]
                if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted]) {
                    try? data.write(to: output.appendingPathComponent("report.json"))
                }
                FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
                exit(1)
            }
        }
        func bytes(_ image: CGImage) -> Data {
            var result = Data(count: image.width * image.height * 4)
            result.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return result
        }
        var environment = EnvironmentValues()
        environment.colorScheme = .light; environment.displayScale = 2
        environment.locale = Locale(identifier: "en_US")
        environment.timeZone = TimeZone(secondsFromGMT: 0)!
        environment.calendar = Calendar(identifier: .gregorian)
        let size = CGSize(width: 160, height: 64)
        let basic = CalendarEventPaint(title: "Design review 👩🏽‍💻", start: Date(timeIntervalSince1970: 1791541800),
            startText: "9:10 AM", timeRange: "9:10–10:25 AM", icon: "calendar")
        let rendering: CalendarArtworkRasterCache.Rendering = CommandLine.arguments.contains("--cgimage") ? .cgImage : .coreGraphics
        let cache = CalendarArtworkRasterCache(byteLimit: 512 * 1024, entryLimit: 2, rendering: rendering)
        func render(_ paint: CalendarEventPaint = basic, _ env: EnvironmentValues = environment,
                    _ dimensions: CGSize = size, using selected: CalendarArtworkRasterCache? = nil) throws -> CGImage {
            try (selected ?? cache).image(paint: paint, size: dimensions, desktop: false,
                showsIcon: true, environment: env)
        }
        let began = ProcessInfo.processInfo.systemUptime
        let first = try render()
        let firstMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        func verifyPixels(_ original: CGImage, _ rebuilt: CGImage, _ label: String) {
            let originalBytes = bytes(original), rebuiltBytes = bytes(rebuilt)
            guard original.width != rebuilt.width || original.height != rebuilt.height || originalBytes != rebuiltBytes else {
                checks += 1; return
            }
            for (name, image) in [("first", original), ("rebuilt", rebuilt)] {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent(name + ".png"))
            }
            var differences = 0, maximum = 0
            var examples: [[Int]] = []
            for index in 0..<min(originalBytes.count, rebuiltBytes.count) where originalBytes[index] != rebuiltBytes[index] {
                differences += 1
                maximum = max(maximum, abs(Int(originalBytes[index]) - Int(rebuiltBytes[index])))
                if examples.count < 20 { examples.append([index, Int(originalBytes[index]), Int(rebuiltBytes[index])]) }
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["differentBytes": differences,
                "maximumDelta": maximum, "examples": examples, "firstRenderMS": firstMS, "comparison": label,
                "sameImageNormalizationStable": originalBytes == bytes(original),
                "sourceBitsPerPixel": original.bitsPerPixel,
                "sourceBitsPerComponent": original.bitsPerComponent,
                "sourceBitmapInfo": original.bitmapInfo.rawValue,
                "sourceColorSpace": original.colorSpace?.name as String? ?? "unknown",
                "rawProviderEqual": original.dataProvider?.data == rebuilt.dataProvider?.data], options: [.prettyPrinted]) {
                try? data.write(to: output.appendingPathComponent("diagnostic.json"))
            }
            check(false, label + " changed pixels")
        }
        let warm = try render()
        check(first === warm && cache.statistics.renders == 1 && cache.statistics.hits == 1,
              "Warm lookup rendered again or changed image ownership")
        check(cache.count == 1 && cache.retainedBytes == first.bytesPerRow * first.height, "Byte accounting")
        var changed = basic; changed.title = "A different meeting"
        let second = try render(changed)
        check(bytes(first) != bytes(second), "Title update kept stale pixels")
        _ = try render() // touch A, so adding C must evict B.
        var third = basic; third.tint = .red; third.ribbons = [.red, .green, .purple]
        _ = try render(third)
        check(cache.count == 2 && cache.statistics.evictions == 1, "Entry bound/LRU")
        let before = cache.statistics.renders
        let secondAgain = try render(changed)
        check(cache.statistics.renders == before + 1, "Eviction did not rebuild")
        verifyPixels(second, secondAgain, "Eviction recovery")
        cache.clear()
        check(cache.count == 0 && cache.retainedBytes == 0, "Clear retained cached images")
        verifyPixels(first, try render(), "Clear/rebuild")

        func calendarPaint() -> CalendarEventPaint {
            var paint = basic
            let color = CalendarColor.color(hex: "4477CC")!
            paint.tint = color; paint.ribbons = [color]
            return paint
        }
        let dynamic = CalendarArtworkRasterCache(rendering: rendering)
        let dynamicFirst = try render(calendarPaint(), using: dynamic)
        let dynamicSecond = try render(calendarPaint(), using: dynamic)
        check(dynamicFirst === dynamicSecond && dynamic.statistics.hits == 1,
              "Recreated equivalent calendar colors missed the cache")
        let identityControl = CalendarArtworkRasterCache(rendering: rendering, usesResolvedColorIdentity: false)
        _ = try render(calendarPaint(), using: identityControl)
        _ = try render(calendarPaint(), using: identityControl)
        check(identityControl.statistics.renders == 2, "Color-identity control did not reproduce the original misses")
        var requests: [(String, CalendarEventPaint, EnvironmentValues, CGSize)] = []
        for scale in [1.0, 2.0, 3.0] {
            var env = environment; env.displayScale = scale
            requests.append(("scale-\(scale)", basic, env, size))
        }
        var dark = environment; dark.colorScheme = .dark
        requests.append(("appearance", basic, dark, size))
        var rtl = environment; rtl.layoutDirection = .rightToLeft
        requests.append(("direction", third, rtl, size))
        var moment = basic; moment.isEvent = false; moment.isMoment = true; moment.icon = "alarm"
        var french = environment; french.locale = Locale(identifier: "fr_FR")
        requests.append(("locale", moment, french, CGSize(width: 160, height: 24)))
        var zone = environment; zone.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        requests.append(("timezone", moment, zone, CGSize(width: 160, height: 24)))
        var completed = basic; completed.completed = true; completed.isTask = true; completed.isEvent = false
        requests.append(("completion", completed, environment, size))
        var free = third; free.showsAsFree = true; free.fillOpacity = DS.Event.quietFill; free.tentative = true
        requests.append(("state-and-ribbons", free, environment, size))
        requests.append(("resize", basic, environment, CGSize(width: 90, height: 40)))
        requests.append(("dynamic-calendar-color", calendarPaint(), environment, size))
        requests.append(("dynamic-calendar-dark", calendarPaint(), dark, size))
        var typography = environment
        typography.lineSpacing = 3; typography.multilineTextAlignment = .trailing
        typography.textCase = .uppercase; typography.minimumScaleFactor = 0.8
        requests.append(("text-environment", basic, typography, CGSize(width: 90, height: 64)))
        var symbols = environment; symbols.symbolVariants = .fill; symbols.imageScale = .large
        requests.append(("symbol-environment", moment, symbols, size))
        var exportAPIDifferences: [String] = []
        for (name, paint, env, dimensions) in requests {
            let actual = try render(paint, env, dimensions)
            let reference = ImageRenderer(content: LegacyCalendarEventArtwork(paint: paint,
                height: dimensions.height, layout: .mobile, showsIcon: true)
                .frame(width: dimensions.width, height: dimensions.height).environment(\.self, env))
            reference.scale = env.displayScale
            let exported = reference.cgImage!
            if actual.width != exported.width || actual.height != exported.height || bytes(actual) != bytes(exported) {
                exportAPIDifferences.append(name)
            }
            let expected: CGImage
            if rendering == .coreGraphics {
                var referenceImage: CGImage?
                reference.render(rasterizationScale: env.displayScale) { size, draw in
                    let context = CGContext(data: nil, width: Int(ceil(size.width * env.displayScale)),
                        height: Int(ceil(size.height * env.displayScale)), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.scaleBy(x: env.displayScale, y: env.displayScale)
                    draw(context); referenceImage = context.makeImage()
                }
                expected = referenceImage!
            } else { expected = exported }
            check(actual.width == expected.width && actual.height == expected.height && bytes(actual) == bytes(expected),
                  "Environment/content pixel mismatch: \(name)")
            check(cache.retainedBytes <= cache.byteLimit && cache.count <= cache.entryLimit, "Cache exceeded bound")
        }

        // Agenda uses a compact 24-point text policy inside duration-sized canvases.
        // Keep the frozen reference's independent height and frame; never retune it to match.
        let agendaCache = CalendarArtworkRasterCache(rendering: rendering)
        for desktop in [false, true] {
            for canvasHeight: CGFloat in [21, 40, 90] {
                let dimensions = CGSize(width: 160, height: canvasHeight)
                let actual = try agendaCache.image(paint: basic, size: dimensions, desktop: desktop,
                    showsIcon: true, environment: environment, paintHeight: 24)
                let reference = ImageRenderer(content: LegacyCalendarEventArtwork(paint: basic,
                    height: 24, layout: desktop ? .desktop : .mobile, showsIcon: true)
                    .frame(width: dimensions.width, height: dimensions.height).environment(\.self, environment))
                reference.scale = environment.displayScale
                var expected: CGImage?
                if rendering == .coreGraphics {
                    reference.render(rasterizationScale: environment.displayScale) { size, draw in
                        let context = CGContext(data: nil, width: Int(ceil(size.width * environment.displayScale)),
                            height: Int(ceil(size.height * environment.displayScale)), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.scaleBy(x: environment.displayScale, y: environment.displayScale)
                        draw(context); expected = context.makeImage()
                    }
                } else { expected = reference.cgImage }
                verifyPixels(expected!, actual, "Independent paint/canvas height \(desktop) \(canvasHeight)")
                check(agendaCache.cachedImage(paint: basic, size: dimensions, desktop: desktop,
                    showsIcon: true, environment: environment, paintHeight: 24) === actual,
                    "Independent-height warm lookup missed")
                check(agendaCache.cachedImage(paint: basic, size: dimensions, desktop: desktop,
                    showsIcon: true, environment: environment, paintHeight: 64) == nil,
                    "Different text threshold reused stale pixels")
            }
        }
        for invalidHeight in [CGFloat.nan, .infinity, -1, 0] {
            do {
                _ = try agendaCache.image(paint: basic, size: size, desktop: false,
                    showsIcon: true, environment: environment, paintHeight: invalidHeight)
                check(false, "Invalid paint height accepted")
            } catch CalendarArtworkRasterCache.Failure.invalidDimensions { checks += 1 }
        }

        let uncached = CalendarArtworkRasterCache(byteLimit: 0, rendering: rendering)
        _ = try render(using: uncached); _ = try render(using: uncached)
        check(uncached.count == 0 && uncached.retainedBytes == 0 && uncached.statistics.renders == 2,
              "Zero-byte policy retained content")
        let tiny = CalendarArtworkRasterCache(byteLimit: 32, maximumEntryBytes: 32, rendering: rendering)
        do { _ = try render(using: tiny); preconditionFailure("Oversized artwork accepted") }
        catch CalendarArtworkRasterCache.Failure.exceedsEntryBudget { checks += 1 }
        check(tiny.count == 0 && tiny.statistics.renders == 0, "Rejected artwork was allocated/stored")
        var explicitSymbols = environment; explicitSymbols.symbolRenderingMode = .multicolor
        do { _ = try render(basic, explicitSymbols); check(false, "Opaque symbol style accepted without a style key") }
        catch CalendarArtworkRasterCache.Failure.unsupportedEnvironment { checks += 1 }
        for width in [Double.nan, Double.infinity, -1, 0] {
            do { _ = try render(basic, environment, CGSize(width: width, height: 64)); preconditionFailure("Invalid geometry accepted") }
            catch CalendarArtworkRasterCache.Failure.invalidDimensions { checks += 1 }
        }

        let boundedProfile = CalendarArtworkRasterCache(byteLimit: 0, rendering: rendering,
            recordRenderTimings: true, timingSampleLimit: 2)
        for _ in 0..<3 { _ = try render(using: boundedProfile) }
        check(boundedProfile.statistics.renderAttempts == 3 && boundedProfile.statistics.renderSamplesMS.count == 2
            && boundedProfile.statistics.droppedRenderSamples == 1, "Timing overflow was hidden or unbounded")
        check(boundedProfile.statistics.maximumRenderMS >= boundedProfile.statistics.renderSamplesMS.max()!,
              "Maximum dropped a retained preparation sample")
        check(uncached.statistics.renderSamplesMS.isEmpty, "Disabled instrumentation captured timings")

        // Interleaved cold/warm/eviction component ablation. Same real artwork inputs; this
        // deliberately measures cache behavior, not the app's fixture distribution or UI speed.
        let hot = CalendarArtworkRasterCache(rendering: rendering)
        let evicted = CalendarArtworkRasterCache(rendering: rendering)
        _ = try render(using: hot)
        let colorHot = CalendarArtworkRasterCache(rendering: rendering)
        let colorIdentity = CalendarArtworkRasterCache(rendering: rendering, usesResolvedColorIdentity: false)
        _ = try render(calendarPaint(), using: colorHot)
        let profiled = CalendarArtworkRasterCache(byteLimit: 0, rendering: rendering, recordRenderTimings: true)
        let agendaUncached = CalendarArtworkRasterCache(byteLimit: 0, rendering: rendering)
        var samples = Array(repeating: [Double](), count: 8)
        var checksum = 0
        for trial in 0..<201 {
            for offset in 0..<8 {
                let variant = (trial + offset) % 8
                let start = ProcessInfo.processInfo.systemUptime
                let image: CGImage
                switch variant {
                case 0: image = try render(using: uncached)
                case 1: image = try render(using: hot)
                case 2: evicted.clear(); image = try render(using: evicted)
                case 3: image = try render(calendarPaint(), using: colorHot)
                case 4: image = try render(calendarPaint(), using: colorIdentity)
                case 5: image = try render(using: profiled)
                default:
                    image = try (variant == 6 ? agendaUncached : agendaCache).image(paint: basic,
                        size: CGSize(width: 160, height: 90), desktop: false, showsIcon: true,
                        environment: environment, paintHeight: 24)
                }
                checksum &+= image.width &+ image.height
                samples[variant].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        var metrics: [[String: Any]] = []
        for (index, name) in ["uncached", "warm", "evicted", "recreated-colors-resolved", "recreated-colors-identity", "profiled-uncached", "agenda-uncached", "agenda-warm"].enumerated() {
            let sorted = samples[index].sorted()
            metrics.append(["name": name, "samplesMS": samples[index], "p50MS": sorted[100],
                "p95MS": sorted[190], "maxMS": sorted.last!, "over8_3MS": sorted.filter { $0 > 8.3 }.count])
        }
        let report: [String: Any] = ["rendering": rendering == .coreGraphics ? "coreGraphics" : "cgImage",
            "cgImageExportDifferences": exportAPIDifferences,
            "parityScope": "Exact frozen-reference pixels using the same selected drawing API. Export-API differences are retained, not claimed as matching.",
            "checks": checks, "firstRenderMS": firstMS, "metrics": metrics,
            "retainedWarmBytes": hot.retainedBytes, "checksum": checksum,
            "resolvedColorCacheBytes": colorHot.retainedBytes,
            "identityColorCacheBytes": colorIdentity.retainedBytes,
            "profiling": profiled.preparationReport(),
            "agendaRetainedBytes": agendaCache.retainedBytes,
            "scope": "Main-actor offscreen artwork component; not frames or input-to-visible latency. Cache-only bytes exclude consumer/compositor ownership."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
        print("PASS: \(checks) prepared artwork/cache checks")
    }
}
