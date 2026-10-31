// Offscreen raster-job comparison, not input/display latency.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

@_silgen_name("calendar_skia_picture_stat") private func pictureStat(_ probe: UnsafeMutableRawPointer, _ which: Int32) -> Double
@_silgen_name("calendar_skia_create") private func makeSkia(_ json: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("calendar_skia_render") private func renderSkia(_ probe: UnsafeMutableRawPointer, _ evict: Int32) -> Double
@_silgen_name("calendar_skia_encode") private func encodeSkia(_ probe: UnsafeMutableRawPointer) -> Double
@_silgen_name("calendar_skia_read") private func readSkia(_ probe: UnsafeMutableRawPointer, _ tile: Int32, _ bytes: UnsafeMutablePointer<UInt8>) -> Int32
@_silgen_name("calendar_skia_cache_bytes") private func cacheSkia(_ probe: UnsafeMutableRawPointer) -> Double
@_silgen_name("calendar_skia_drawn") private func drawnSkia(_ probe: UnsafeMutableRawPointer, _ tile: Int32) -> Int32
@_silgen_name("calendar_skia_destroy") private func destroySkia(_ probe: UnsafeMutableRawPointer)
private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
private enum Failure: Error { case unavailable, outputExists, coverage }
private func png(_ image: CGImage, _ path: URL) {
    let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
@main struct CalendarSkiaProbe {
    @MainActor static func main() throws {
        let config = CalendarFixtureConfiguration()
        precondition(config.fixture == "varied-v1" && config.mode == "week")
        let out = URL(fileURLWithPath: config.value("--out", "/tmp/calendar-skia"))
        guard !FileManager.default.fileExists(atPath: out.path) else { throw Failure.outputExists }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = FixtureStore(config), model = PrototypeModel(store: store)
        model.move(to: store.anchor)
        let black = CGColor(gray: 0, alpha: 1)
        let style = RasterPage.Style(text: .init(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: .init(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        var results: [[String: Any]] = []
        let reverse = config.args.contains("--reverse")
        let reusePictures = config.args.contains("--reuse-pictures")
        let pictureLimit = Int(config.value("--picture-cache-bytes", "8388608"))!
        precondition(pictureLimit >= 0)
        let cgPaths = config.args.contains("--cg-paths")
        let managedColors = !config.args.contains("--legacy-unmanaged-colors")
        func rgba(_ color: CGColor) -> [CGFloat] {
            managedColors ? color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)!.components! : color.components!
        }
        for (width, scale) in [(393, 3), (1366, 2)] {
            var events: [[String: Any]] = []
            for (day, geometry) in model.layouts.enumerated() {
                for item in geometry.placements {
                    let rect = item.rect(day: day, dayCount: model.layouts.count, width: Double(width), height: 1920, gutter: 48)
                    events.append(["id": "\(day):\(item.id)", "title": item.title!,
                        "rect": [rect.minX, rect.minY, rect.width, rect.height],
                        "color": rgba(FixturePalette.fills[item.calendarIndex])])
                }
            }
            let descriptor: [String: Any] = ["width": width, "scale": scale, "days": model.layouts.count, "events": events, "cgPaths": cgPaths, "reusePictures": reusePictures, "pictureLimit": pictureLimit,
                "separator": managedColors ? rgba(style.separator) : [0.5, 0.5, 0.5, 1.0]]
            let data = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
            try data.write(to: out.appendingPathComponent("geometry-\(width).json"))
            let startup = now()
            guard let skia = String(decoding: data, as: UTF8.self).withCString({ makeSkia($0) }) else { throw Failure.unavailable }
            defer { destroySkia(skia) }
            let startupMS = now() - startup
            var pages: [RasterPage] = []
            var samples: [[String: Any]] = []
            var firstPixels: [[UInt8]] = []
            for state in ["cold-raster", "warm-reraster", "eviction-reraster"] {
                var cgMS = 0.0, skiaMS = 0.0
                func coreGraphics() {
                    let began = now()
                    pages.removeAll()
                    pages = (0..<4).map { tile in
                        RasterPage.render(days: model.layouts, width: Double(width), height: 1920, gutter: 48,
                            scale: Double(scale), style: style, region: CGRect(x: 0, y: tile*256, width: width, height: 256))!
                    }
                    cgMS = now() - began
                }
                func metal() { skiaMS = renderSkia(skia, state == "eviction-reraster" ? 1 : 0) }
                if reverse { metal(); coreGraphics() } else { coreGraphics(); metal() }
                guard skiaMS >= 0 else { throw Failure.unavailable }
                var comparisons: [[String: Any]] = []
                for tile in 0..<4 {
                    let reference = pages[tile].image
                    var actual = [UInt8](repeating: 0, count: reference.width * reference.height * 4)
                    guard readSkia(skia, Int32(tile), &actual) != 0 else { throw Failure.unavailable }
                    if state == "cold-raster" { firstPixels.append(actual) }
                    let phaseDifference = zip(firstPixels[tile], actual).reduce(0) { max($0, abs(Int($1.0)-Int($1.1))) }
                    let expectedData = reference.dataProvider!.data!
                    let expected = CFDataGetBytePtr(expectedData)!
                    var maxDifference = 0, changedPixels = 0, sumDifference: Int64 = 0
                    for y in 0..<reference.height {
                        for x in 0..<reference.width {
                            var changed = false
                            for c in 0..<4 {
                                let delta = abs(Int(actual[(y*reference.width+x)*4+c]) - Int(expected[y*reference.bytesPerRow+x*4+c]))
                                maxDifference = max(maxDifference, delta); sumDifference += Int64(delta)
                                changed = changed || delta > 1
                            }
                            if changed { changedPixels += 1 }
                        }
                    }
                    let region = CGRect(x: 0, y: tile*256, width: width, height: 256).insetBy(dx: 0, dy: -1/Double(scale))
                    let expectedIDs = Set(events.filter {
                        let r = $0["rect"] as! [CGFloat]
                        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).intersects(region)
                    }.map { $0["id"] as! String })
                    guard expectedIDs == pages[tile].ids, Int(drawnSkia(skia, Int32(tile))) == expectedIDs.count else { throw Failure.coverage }
                    comparisons.append(["tile": tile, "events": expectedIDs.count, "skiaEvents": Int(drawnSkia(skia, Int32(tile))), "maxChannelDifference": maxDifference, "skiaPhaseMaxDifference": phaseDifference,
                        "pixelsOverOne": changedPixels, "totalPixels": reference.width*reference.height,
                        "meanAbsoluteChannelDifference": Double(sumDifference)/Double(actual.count)])
                    if state == "cold-raster" || config.args.contains("--all-phase-images") {
                        let prefix = state == "cold-raster" ? "" : state + "-"
                        png(reference, out.appendingPathComponent("\(prefix)cg-\(width)-\(tile).png"))
                        let image = CGImage(width: reference.width, height: reference.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: reference.width*4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(actual) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                        png(image, out.appendingPathComponent("\(prefix)skia-\(width)-\(tile).png"))
                    }
                }
                guard pictureStat(skia, 0) <= Double(pictureLimit), pictureStat(skia, 3) <= 4 else { throw Failure.coverage }
                samples.append(["pictureBytes": pictureStat(skia, 0), "pictureHits": pictureStat(skia, 1),
                    "pictureMisses": pictureStat(skia, 2), "pictureCount": pictureStat(skia, 3), "state": state, "first": reverse ? "skia" : "coreGraphics", "coreGraphicsRasterMS": cgMS,
                    "skiaCompletionMS": skiaMS, "skiaEncodeMS": encodeSkia(skia), "skiaCacheBytes": cacheSkia(skia),
                    "coreGraphicsTileBytes": pages.reduce(0) { $0 + $1.bytes }, "pixels": comparisons])
            }
            results.append(["widthPoints": width, "scale": scale, "startupMS": startupMS, "samples": samples])
        }
        let report: [String: Any] = ["fixture": store.fixtureSummary, "results": results, "acceptance": "unmeasured", "managedColors": managedColors, "cgPaths": cgPaths, "reusePictures": reusePictures, "pictureLimit": pictureLimit,
            "scope": "Four tile raster jobs using identical Core Text layout; no presentation or input latency"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("report.json"))
    }
}
