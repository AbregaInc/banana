import AppKit
import QuartzCore
import CryptoKit

/// Offscreen native layer-tree pixel oracle. This is not visible interaction timing.
@main
struct LayerChecks {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let config = CalendarFixtureConfiguration(), store = FixtureStore(CalendarFixtureConfiguration())
        precondition(config.value("--renderer", "") == "tiles")
        let model = PrototypeModel(store: store)
        let document = TimelineDocument(frame: CGRect(x: 0, y: 0, width: 800, height: 1920))
        document.wantsLayer = true
        let surface = CalendarSurface(frame: document.bounds)
        surface.wantsLayer = true
        document.addSubview(surface)
        let out = URL(fileURLWithPath: config.value("--output", "/tmp/calendar-layer-checks"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var checks = 0, rows: [[String: Any]] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition {
                try? JSONSerialization.data(withJSONObject: ["status": "failed", "checks": checks,
                    "failure": message, "cases": rows], options: [.prettyPrinted, .sortedKeys])
                    .write(to: out.appendingPathComponent("checks.json"))
                FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
            }
        }
        for (index, spec) in [(800.0,0.0,0),(800,800,0),(1000,800,0),(1000,800,5),(1000,800,5),(800,0,0)].enumerated() {
            document.frame.size.width = spec.0
            model.move(to: store.calendar.date(byAdding: .day, value: spec.2, to: store.anchor)!)
            let viewport = CGRect(x: 0, y: spec.1, width: spec.0, height: 800)
            if index == 4 { surface.evictSpareViews() }
            surface.install(model.layouts, viewport: viewport)
            document.layoutSubtreeIfNeeded()
            surface.layer?.displayIfNeeded()
            CATransaction.flush()
            check(surface.tiles.contentsPresent, "Tile layer is blank")
            check(surface.expectedVisibleIDs(viewport).isSubset(of: surface.drawnIDs), "Missing visible event pixels")
            check(surface.wantsUpdateLayer == surface.optimizations.nativeLayerUpdates, "Wrong native display policy")
            let context = CGContext(data: nil, width: Int(viewport.width * 2), height: 1600,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: 1600)
            context.scaleBy(x: 2, y: -2)
            context.translateBy(x: 0, y: -viewport.minY)
            surface.layer!.render(in: context)
            let image = context.makeImage()!
            let bytes = image.dataProvider!.data! as Data
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            check(bytes.contains { $0 != 0 }, "Composited layer image is empty")
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = bitmap.representation(using: .png, properties: [:])!
            try png.write(to: out.appendingPathComponent("\(index).png"))
            if config.args.contains("--reference") {
                let reference = URL(fileURLWithPath: config.value("--reference", "")).appendingPathComponent("\(index).png")
                let expected = NSBitmapImageRep(data: try Data(contentsOf: reference))!.cgImage!
                check(expected.width == image.width && expected.height == image.height &&
                      expected.dataProvider!.data! as Data == NSBitmapImageRep(data: png)!.cgImage!.dataProvider!.data! as Data,
                      "Native layer update changed composited pixels")
            }
            rows.append(["case": index, "sha256": hash, "drawPasses": surface.surfaceDrawPasses,
                "layerUpdates": surface.surfaceLayerUpdates, "visibleCount": surface.expectedVisibleIDs(viewport).count])
        }
        surface.install([], viewport: CGRect(x: 0, y: 0, width: 800, height: 800))
        check(surface.presentations.isEmpty && !surface.tiles.contentsPresent, "Empty page retained tile pixels")
        try JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks, "cases": rows,
            "scope": "Offscreen CALayer composition correctness, not visible UI timing"], options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("checks.json"))
        print("PASS: \(checks) layer composition checks")
    }
}
