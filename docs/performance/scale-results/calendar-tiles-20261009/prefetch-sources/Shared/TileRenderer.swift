import Foundation
import QuartzCore

// Experimental explicit tiles use native CALayer contents. Unlike CATiledLayer,
// a completed install means every requested tile already has pixels.
@MainActor
final class TileRenderer {
    let layer = CALayer()
    let cache = RasterCache(byteLimit: 64 * 1024 * 1024, countLimit: 24)
    private struct Active {
        let key: RasterKey
        let page: RasterPage
        let layer: CALayer
    }
    private var active: [Int: Active] = [:]
    private var invalidated = false
    private var identity: RasterKey?
    private var generation = 0
    private var scrollWork: Task<Void, Never>?
    private var pageWork: Task<Void, Never>?
    private(set) var builds = 0
    private(set) var prefetchedBuilds = 0
    private(set) var preparationMS: [Double] = []
    var ids: Set<String> { active.values.reduce(into: Set<String>()) { $0.formUnion($1.page.ids) } }
    var activeCount: Int { active.count }
    var activeBytes: Int { active.values.reduce(0) { $0 + $1.page.bytes } }
    var contentsPresent: Bool { !active.isEmpty && active.values.allSatisfy { $0.layer.contents != nil } }

    func install(days: [DayGeometry], width: CGFloat, height: CGFloat, gutter: CGFloat,
                 scale: CGFloat, viewport: CGRect, style: RasterPage.Style, tileHeight: CGFloat = 256,
                 preloadScroll: Bool = false) -> Bool {
        let pageIdentity = RasterKey(dates: days.map(\.date), width: width, scale: scale)
        if identity != pageIdentity {
            cancelWork(); identity = pageIdentity
        }
        let visible = viewport.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !visible.isNull, !days.isEmpty else { clear(); return true }
        let first = max(0, Int(floor(visible.minY / tileHeight)))
        let last = min(Int(ceil(height / tileHeight))-1, Int(ceil(visible.maxY / tileHeight))-1)
        guard first <= last else { clear(); return true }
        var next: [Int: Active] = [:]
        // Prepare all missing tiles before touching the active presentation.
        // Allocation failure leaves the old layer intact but fails new-page coverage.
        for index in first...last {
            let top = CGFloat(index) * tileHeight
            let region = CGRect(x: 0, y: top, width: width, height: min(tileHeight, height-top))
            let key = RasterKey(dates: days.map(\.date), width: width, scale: scale, top: top, height: region.height)
            if !invalidated, let old = active[index], old.key == key { next[index] = old; continue }
            let cached = cache.get(key)
            guard let page = cached ?? RasterPage.render(days: days, width: width, height: height,
                gutter: gutter, scale: scale, style: style, region: region) else { return false }
            if cached == nil { builds += 1; preparationMS.append(page.preparationMS); cache.put(page, for: key) }
            next[index] = Active(key: key, page: page, layer: active[index]?.layer ?? CALayer())
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        for (index, old) in active where next[index] == nil { old.layer.removeFromSuperlayer() }
        for tile in next.values {
            tile.layer.frame = CGRect(x: 0, y: tile.key.top, width: width, height: tile.key.height)
            tile.layer.contentsScale = scale; tile.layer.isOpaque = true
            if tile.layer.superlayer == nil { layer.addSublayer(tile.layer) }
            if invalidated || active[Int(tile.key.top / tileHeight)]?.key != tile.key { tile.layer.contents = tile.page.image }
        }
        CATransaction.commit()
        active = next; invalidated = false
        if preloadScroll {
            let neighbors = [last+1, first-1].filter { $0 >= 0 && $0 < Int(ceil(height/tileHeight)) }
            let requests = neighbors.compactMap { index -> (RasterKey, CGRect)? in
                let top = CGFloat(index)*tileHeight
                let rect = CGRect(x:0,y:top,width:width,height:min(tileHeight,height-top))
                let key = RasterKey(dates:pageIdentity.dates,width:width,scale:scale,top:top,height:rect.height)
                return cache.get(key) == nil ? (key,rect) : nil
            }
            scrollWork?.cancel()
            let token = generation
            scrollWork = Task.detached(priority: .utility) { [weak self] in
                for (key,rect) in requests {
                    guard !Task.isCancelled else { return }
                    let page = autoreleasepool { RasterPage.render(days:days,width:width,height:height,
                        gutter:gutter,scale:scale,style:style,region:rect) }
                    guard !Task.isCancelled, let page else { return }
                    await self?.receive(page,key:key,generation:token)
                }
            }
        }
        return true
    }
    func preloadPages(store: FixtureStore, date: Date, dayCount: Int, width: CGFloat, height: CGFloat,
                      gutter: CGFloat, scale: CGFloat, viewport: CGRect, style: RasterPage.Style,
                      tileHeight: CGFloat = 256) {
        pageWork?.cancel()
        let calendar = store.calendar, token = generation
        let first = max(0,Int(floor(viewport.minY/tileHeight)))
        let last = min(Int(ceil(height/tileHeight))-1,Int(ceil(viewport.maxY/tileHeight))-1)
        guard first <= last else { return }
        let inputs = [dayCount,-dayCount].map { offset -> ([(Date,[Fixture])],[(RasterKey,CGRect)]) in
            let rows = (0..<dayCount).map { day -> (Date,[Fixture]) in
                let date = calendar.date(byAdding:.day,value:offset+day,to:date)!
                return (date,store.day(date))
            }
            let requests = (first...last).compactMap { index -> (RasterKey,CGRect)? in
                let top = CGFloat(index)*tileHeight
                let rect = CGRect(x:0,y:top,width:width,height:min(tileHeight,height-top))
                let key = RasterKey(dates:rows.map(\.0),width:width,scale:scale,top:top,height:rect.height)
                return cache.get(key) == nil ? (key,rect) : nil
            }
            return (rows,requests)
        }
        pageWork = Task.detached(priority: .utility) { [weak self] in
            for (rows,requests) in inputs where !requests.isEmpty {
                guard !Task.isCancelled else { return }
                let days = rows.map { DayGeometry(date:$0.0,calendar:calendar,events:$0.1,buildIndex:false) }
                for (key,rect) in requests {
                    guard !Task.isCancelled else { return }
                    let page = autoreleasepool { RasterPage.render(days:days,width:width,height:height,
                        gutter:gutter,scale:scale,style:style,region:rect) }
                    guard !Task.isCancelled, let page else { return }
                    await self?.receive(page,key:key,generation:token)
                }
            }
        }
    }
    private func receive(_ page: RasterPage, key: RasterKey, generation token: Int) {
        guard token == generation else { return }
        cache.put(page,for:key); prefetchedBuilds += 1
        for tile in active.values { _ = cache.get(tile.key) }
    }
    private func cancelWork() {
        generation += 1; scrollWork?.cancel(); pageWork?.cancel()
        scrollWork = nil; pageWork = nil
    }
    func evict() {
        cancelWork()
        cache.clear(); invalidated = true
        // The active visible layers retain their pixels until replacements are ready.
    }
    func clear() {
        cancelWork(); identity = nil
        active.values.forEach { $0.layer.removeFromSuperlayer() }
        active.removeAll(); invalidated = false
    }
    deinit { scrollWork?.cancel(); pageWork?.cancel() }
}
