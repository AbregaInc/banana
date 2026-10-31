import Foundation
import CoreGraphics
import CoreText

@main
struct TileChecks {
    @MainActor
    static func main() throws {
        let config = CalendarFixtureConfiguration(), store = FixtureStore(CalendarFixtureConfiguration())
        let model = PrototypeModel(store: store)
        model.move(to: store.anchor)
        let black = CGColor(gray: 0, alpha: 1)
        let style = RasterPage.Style(text: PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
        }
        var samples: [[String: Any]] = []
        for scale in [1.0, 2.0, 3.0] {
            for width in [400.0, 1200.0] {
                autoreleasepool {
                    let full = RasterPage.render(days: model.layouts, width: width, height: 1920, gutter: 48, scale: scale, style: style)!
                    let fullBytes = full.image.dataProvider!.data! as Data
                    for tileHeight in [128.0, 256.0, 512.0] {
                        var ids = Set<String>(), tileTimes: [Double] = [], tileBytes = 0
                        var maxChannelDifference = 0, changedChannels = 0
                        for top in stride(from: 0.0, to: 1920.0, by: tileHeight) {
                            let region = CGRect(x: 0, y: top, width: width, height: min(tileHeight, 1920-top))
                            let tile = RasterPage.render(days: model.layouts, width: width, height: 1920, gutter: 48, scale: scale, style: style, region: region)!
                            var nativeStyle = style; nativeStyle.nativeText = true
                            let native = RasterPage.render(days: model.layouts, width: width, height: 1920,
                                gutter: 48, scale: scale, style: nativeStyle, region: region)!
                            check(native.image.dataProvider!.data! as Data == tile.image.dataProvider!.data! as Data,
                                  "Native Core Text changed tile pixels")
                            check(native.ids == tile.ids, "Native Core Text changed coverage")
                            var culledStyle = style; culledStyle.cullTileText = true
                            let culled = RasterPage.render(days: model.layouts, width: width, height: 1920,
                                gutter: 48, scale: scale, style: culledStyle, region: region)!
                            check(culled.image.dataProvider!.data! as Data == tile.image.dataProvider!.data! as Data,
                                  "Text culling changed tile pixels")
                            check(culled.ids == tile.ids, "Text culling changed coverage")
                            let bytes = tile.image.dataProvider!.data! as Data
                            check(tile.image.height == Int(region.height * scale), "Incorrect tile extent")
                            for row in 0..<tile.image.height {
                                let start = (Int(top * scale) + row) * full.image.bytesPerRow
                                let tileStart = row * tile.image.bytesPerRow
                                for column in 0..<Int(width*scale)*4 {
                                    let delta = abs(Int(fullBytes[start+column]) - Int(bytes[tileStart+column]))
                                    maxChannelDifference = max(maxChannelDifference, delta)
                                    if delta > 0 { changedChannels += 1 }
                                }

                            }
                            ids.formUnion(tile.ids); tileTimes.append(tile.preparationMS); tileBytes += tile.bytes
                        }
                        // Integer translations of antialiased Core Graphics paths can round
                        // an 8-bit channel by one level. Keep this bound explicit; geometry,
                        // alpha/coverage loss and larger color differences must still fail.
                        check(maxChannelDifference <= 1, "Tile pixels differ by more than one 8-bit channel level")
                        check(ids == full.ids, "Tiles lost event coverage")
                        samples.append(["scale":scale,"width":width,"tileHeight":tileHeight,"fullMS":full.preparationMS,
                            "tileMS":tileTimes,"fullBytes":full.bytes,"tileBytes":tileBytes,
                            "maxChannelDifference":maxChannelDifference,"changedChannels":changedChannels,"pixelExact":changedChannels == 0])
                    }
                }
            }
        }
        check(config.value("--renderer", "") == "tiles", "Run lifecycle checks with --renderer tiles")
        let document = TimelineDocument(frame: CGRect(x: 0, y: 0, width: 800, height: 1920))
        let surface = CalendarSurface(frame: document.bounds)
        document.addSubview(surface)
        var lifecycle: [[String: Any]] = []
        func probe(_ phase: String, viewport: CGRect, install: Bool) {
            let began = DispatchTime.now().uptimeNanoseconds
            if install { surface.install(model.layouts, viewport: viewport) }
            else { surface.update(viewport: viewport) }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds-began)/1_000_000
            check(surface.expectedVisibleIDs(viewport).isSubset(of: surface.drawnIDs), "Visible tile coverage missing")
            check(surface.tiles.contentsPresent, "Active tiles blank")
            check(surface.tiles.cache.bytes <= 64*1024*1024 && surface.tiles.cache.count <= 24, "Tile cache limit exceeded")
            check(surface.tiles.activeCount <= 8, "Active tile count unbounded")
            check(surface.tiles.layer.sublayers?.allSatisfy { $0.frame.width == document.bounds.width && $0.frame.height <= 256 && $0.contents != nil } == true, "Tile layer dimensions/contents stale")
            lifecycle.append(["phase":phase,"milliseconds":milliseconds,"builds":surface.tiles.builds,
                "cacheBytes":surface.tiles.cache.bytes,"activeBytes":surface.tiles.activeBytes,"peakResidentBytes":peakResidentBytes()])
        }
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 800)
        probe("cold", viewport: viewport, install: true)
        let initialBuilds = surface.tiles.builds
        probe("samePage", viewport: viewport, install: true)
        check(surface.tiles.builds == initialBuilds, "Same-page installation rebuilt tiles")
        for step in 0..<120 {
            let y = Double(step < 60 ? step : 119-step) / 59 * 1120
            probe("scroll", viewport: CGRect(x:0,y:y,width:800,height:800), install:false)
        }
        for offset in 1...30 {
            model.move(to: store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!)
            probe("page", viewport: viewport, install:true)
        }
        for width in [400.0,1200.0,800.0] {
            document.frame.size.width = width
            probe("resize", viewport:CGRect(x:0,y:0,width:width,height:800), install:false)
        }
        surface.evictSpareViews()
        check(surface.tiles.contentsPresent && surface.tiles.cache.bytes == 0, "Eviction removed active pixels or retained cache")
        probe("recovery", viewport:viewport, install:true)
        surface.install([], viewport:viewport)
        check(!surface.tiles.contentsPresent && surface.presentations.isEmpty && surface.drawnIDs.isEmpty, "Empty page retained tiles")
        try JSONSerialization.data(withJSONObject: ["checks":checks,"scope":"Offscreen raster preparation, bounded pixel differences and lifecycle; not display/input", "samples":samples,"lifecycle":lifecycle], options:[.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/calendar-tiles.json")))
        print("PASS: \(checks) tile extent/coverage/pixel checks (one-level rounding bound)")
    }
}
