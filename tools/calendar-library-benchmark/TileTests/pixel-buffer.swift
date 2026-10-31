import Foundation
import CoreGraphics
import CoreText
import CoreVideo

@main
struct PixelBufferChecks {
    @MainActor
    static func main() async throws {
        let config = CalendarFixtureConfiguration(), store = FixtureStore(CalendarFixtureConfiguration())
        let model = PrototypeModel(store: store); model.move(to: store.anchor)
        let black = CGColor(gray: 0, alpha: 1)
        let style = RasterPage.Style(text: .init(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: .init(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        var nativeStyle = style; nativeStyle.pixelBuffer = true
        var checks = 0, samples: [[String: Any]] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition {
                try? JSONSerialization.data(withJSONObject: ["status": "failed", "checks": checks,
                    "failure": message, "samples": samples], options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/calendar-pixel-buffer.json")))
                FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
            }
        }
        for (width, scale) in [(393.0,1.0),(393,2),(393,3),(1200,2),(1200,3)] {
            for top in [0.0,256,768,1792] {
                let region = CGRect(x: 0, y: top, width: width, height: min(256,1920-top))
                let reference = RasterPage.render(days: model.layouts, width: width, height: 1920,
                    gutter: 48, scale: scale, style: style, region: region)!
                let began = ProcessInfo.processInfo.systemUptime
                let candidate = RasterPage.render(days: model.layouts, width: width, height: 1920,
                    gutter: 48, scale: scale, style: nativeStyle, region: region)
                let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
                check(candidate != nil, "Native pixel buffer allocation/render failed")
                let actual = candidate!
                check(actual.pixelBuffer != nil, "Candidate fell back to a CGImage")
                check(CVPixelBufferGetIOSurface(actual.pixelBuffer!) != nil, "Native buffer is not IOSurface backed")
                check(actual.ids == reference.ids, "Pixel buffer changed event IDs")
                let snapshot = actual.image
                check(snapshot.width == reference.image.width && snapshot.height == reference.image.height,
                      "Pixel buffer changed image dimensions")
                let left = reference.image.dataProvider!.data! as Data, right = snapshot.dataProvider!.data! as Data
                var equal = true
                for y in 0..<snapshot.height {
                    let a = y * reference.image.bytesPerRow, b = y * snapshot.bytesPerRow
                    if left[a..<(a+snapshot.width*4)] != right[b..<(b+snapshot.width*4)] { equal = false; break }
                }
                check(equal, "Surface-backed BGRA pixels differ from original RGBA drawing")
                check(actual.bytes == CVPixelBufferGetDataSize(actual.pixelBuffer!) && actual.bytes > 0,
                      "Surface pixel storage was not accounted")
                samples.append(["width": width, "scale": scale, "top": top,
                    "referencePreparationMS": reference.preparationMS, "surfaceRenderMS": elapsed,
                    "referenceBytes": reference.bytes, "surfaceBytes": actual.bytes])
            }
        }
        let renderer = TileRenderer()
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        check(renderer.install(days: model.layouts, width: 1200, height: 1920, gutter: 48,
            scale: 2, viewport: viewport, style: nativeStyle), "Surface tile install failed")
        check(renderer.layer.sublayers!.allSatisfy { CFGetTypeID($0.contents! as CFTypeRef) == CVPixelBufferGetTypeID() },
              "Layer contents did not retain native pixel buffers")
        check(renderer.cache.bytes <= 64*1024*1024 && renderer.cache.count <= 24, "Surface cache exceeded limits")
        renderer.evict()
        let ready = await renderer.prepareInstall(days: model.layouts, width: 1200, height: 1920,
            gutter: 48, scale: 2, viewport: viewport, style: nativeStyle, workers: 2)
        check(ready != nil && ready!.values.allSatisfy { $0.pixelBuffer != nil }, "Async path lost surface backing")
        let oldBuilds = renderer.builds
        check(renderer.install(days: model.layouts, width: 1200, height: 1920, gutter: 48,
            scale: 2, viewport: viewport, style: nativeStyle, prepared: ready), "Prepared surfaces did not publish")
        check(renderer.builds == oldBuilds, "Prepared surfaces fell back to synchronous drawing")
        renderer.clear()
        check(!renderer.contentsPresent && renderer.activeCount == 0, "Cleared surfaces retained active pixels")
        renderer.evict()
        check(renderer.cache.bytes == 0, "Eviction retained cached pixel buffers")
        try JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks,
            "eventsPerDay": config.density, "samples": samples,
            "scope": "Exact RGBA/BGRA pixel and retention correctness; timing is diagnostic, not a controlled performance comparison"],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/calendar-pixel-buffer.json")))
        print("PASS: \(checks) native pixel-buffer checks")
    }
}
