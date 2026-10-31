import Foundation
import CoreText
import CoreGraphics

@main
struct TilePrefetchChecks {
    @MainActor
    static func main() async throws {
        let config = Configuration(), store = FixtureStore(Configuration())
        let model = PrototypeModel(store:store); model.move(to:store.anchor)
        let black = CGColor(gray:0,alpha:1)
        let style = RasterPage.Style(text:PreparedText.Style(font:CTFontCreateUIFontForLanguage(.system,12,nil)!,color:black),
            hours:PreparedText.Style(font:CTFontCreateUIFontForLanguage(.system,11,nil)!,color:black),
            background:CGColor(gray:1,alpha:1),separator:CGColor(gray:0.5,alpha:1),event:CGColor(red:0,green:0,blue:1,alpha:0.15))
        let renderer = TileRenderer()
        var checks = 0, waits: [Double] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { FileHandle.standardError.write(Data((message+"\n").utf8)); exit(1) }
        }
        func install(_ y: Double, width: Double = 800, preload: Bool = false) {
            check(renderer.install(days:model.layouts,width:width,height:1920,gutter:48,scale:2,
                viewport:CGRect(x:0,y:y,width:width,height:800),style:style,preloadScroll:preload),"Tile install failed")
        }
        func waitFor(_ predicate: () -> Bool) async {
            let start = ProcessInfo.processInfo.systemUptime
            while !predicate() && ProcessInfo.processInfo.systemUptime-start < 5 {
                try? await Task.sleep(nanoseconds:5_000_000)
            }
            waits.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            check(predicate(),"Tile preparation did not complete")
        }
        install(0,preload:true)
        let builds = renderer.builds
        await waitFor { renderer.prefetchedBuilds > 0 }
        install(256)
        check(renderer.builds == builds,"Scroll did not consume preloaded neighboring tile")
        renderer.preloadPages(store:store,date:model.date,dayCount:model.dayCount,width:800,height:1920,
            gutter:48,scale:2,viewport:CGRect(x:0,y:0,width:800,height:800),style:style)
        let nextDate = store.calendar.date(byAdding:.day,value:model.dayCount,to:model.date)!
        let dates = (0..<model.dayCount).map { store.calendar.date(byAdding:.day,value:$0,to:nextDate)! }
        let last = RasterKey(dates:dates,width:800,scale:2,top:768,height:256)
        await waitFor { renderer.cache.get(last) != nil }
        model.move(to:nextDate)
        let beforePage = renderer.builds
        install(0)
        check(renderer.builds == beforePage,"Paging did not consume prepared tiles")
        renderer.preloadPages(store:store,date:model.date,dayCount:model.dayCount,width:800,height:1920,
            gutter:48,scale:2,viewport:CGRect(x:0,y:0,width:800,height:800),style:style)
        renderer.evict()
        let received = renderer.prefetchedBuilds
        check(renderer.contentsPresent && renderer.cache.bytes == 0,"Eviction lost active pixels")
        try? await Task.sleep(nanoseconds:250_000_000)
        check(renderer.cache.bytes == 0 && renderer.prefetchedBuilds == received,"Canceled work repopulated evicted cache")
        install(0,width:400)
        renderer.preloadPages(store:store,date:model.date,dayCount:model.dayCount,width:400,height:1920,
            gutter:48,scale:2,viewport:CGRect(x:0,y:0,width:400,height:800),style:style)
        renderer.clear()
        let afterClear = renderer.prefetchedBuilds
        try? await Task.sleep(nanoseconds:250_000_000)
        check(!renderer.contentsPresent && renderer.prefetchedBuilds == afterClear,"Retired generation published tiles")
        check(renderer.cache.bytes <= 64*1024*1024 && renderer.cache.count <= 24,"Prefetch exceeded cache bounds")
        try JSONSerialization.data(withJSONObject:["checks":checks,"availabilityWaitMS":waits,
            "scope":"Offscreen prefetch lifecycle; availability polling is not input latency"],options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:config.value("--output","/tmp/tile-prefetch-checks.json")))
        print("PASS: \(checks) tile prefetch/cancellation checks")
    }
}
