import Foundation
import QuartzCore

// Experimental explicit tiles use native CALayer contents. Unlike CATiledLayer,
// a completed install means every requested tile already has pixels.
@MainActor
final class TileRenderer {
    let layer = CALayer()
    let cache: RasterCache
    private let preparationQueue: OperationQueue?
    private let cooperativeCancellation = Optimizations().tileCooperativeCancellation
    private var scrollCancellation = Operation()
    private var pageCancellation = Operation()
    init(cache: RasterCache = RasterCache(byteLimit: 64 * 1024 * 1024, countLimit: 24),
         preparationConcurrency: Int = Optimizations().tilePreparationConcurrency) {
        self.cache = cache
        if preparationConcurrency > 0 {
            let queue = OperationQueue()
            queue.name = "Calendar tile preparation"
            queue.qualityOfService = .utility
            queue.maxConcurrentOperationCount = preparationConcurrency
            preparationQueue = queue
        } else { preparationQueue = nil }
    }
    private struct Active {
        let key: RasterKey
        let page: RasterPage
        let layer: CALayer
    }
    private var active: [Int: Active] = [:]
    private var invalidated = false
    private var identity: RasterKey?
    private var previousDates: [Date]?
    private var generation = 0
    private var scrollWork: Task<Void, Never>?
    private var pageWork: Task<Void, Never>?
    private var foreground: AsyncTilePreparation?
    private(set) var foregroundDispatchMS = 0.0
    private(set) var foregroundCompletionMS = 0.0
    private(set) var foregroundBuilds = 0
    var isPreparingForeground: Bool { foreground?.isPreparing ?? false }
    private(set) var builds = 0
    private(set) var prefetchedBuilds = 0
    private(set) var preparationMS: [Double] = []
    var ids: Set<String> { active.values.reduce(into: Set<String>()) { $0.formUnion($1.page.ids) } }
    var activeCount: Int { active.count }
    var activeBytes: Int { active.values.reduce(0) { $0 + $1.page.bytes } }
    var contentsPresent: Bool { !active.isEmpty && active.values.allSatisfy { $0.layer.contents != nil } }

    func install(days: [DayGeometry], width: CGFloat, height: CGFloat, gutter: CGFloat,
                 scale: CGFloat, viewport: CGRect, style: RasterPage.Style, tileHeight: CGFloat = 256,
                 preloadScroll: Bool = false, lookahead: Bool = false,
                 prepared: [RasterKey: RasterPage]? = nil) -> Bool {
        let pageIdentity = RasterKey(dates: days.map(\.date), width: width, scale: scale)
        if identity != pageIdentity {
            if identity?.dates != pageIdentity.dates { previousDates = identity?.dates }
            cancelWork(); identity = pageIdentity
        }
        let visible = viewport.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !visible.isNull, !days.isEmpty else { clear(); return true }
        let first = max(0, Int(floor(visible.minY / tileHeight)))
        let last = min(Int(ceil(height / tileHeight))-1, Int(ceil(visible.maxY / tileHeight))-1)
        guard first <= last else { clear(); return true }
        var next: [Int: Active] = [:]
        // Retain this request's hits before inserting any misses: an early allocation
        // must not evict a later tile that was already available when paging began.
        var retained: [Int: RasterPage] = [:]
        if lookahead {
            for index in first...last {
                let top = CGFloat(index) * tileHeight
                let key = RasterKey(dates: pageIdentity.dates, width: width, scale: scale,
                                    top: top, height: min(tileHeight, height-top))
                if let page = cache.get(key) { retained[index] = page }
            }
        }
        var textMemo: RasterTextMemo?
        // Prepare all missing tiles before touching the active presentation.
        // Allocation failure leaves the old layer intact but fails new-page coverage.
        for index in first...last {
            let top = CGFloat(index) * tileHeight
            let region = CGRect(x: 0, y: top, width: width, height: min(tileHeight, height-top))
            let key = RasterKey(dates: days.map(\.date), width: width, scale: scale, top: top, height: region.height)
            if !invalidated, let old = active[index], old.key == key { next[index] = old; continue }
            let cached = prepared?[key] ?? retained[index] ?? cache.get(key)
            let page: RasterPage
            if let cached { page = cached }
            else {
                if textMemo == nil { textMemo = style.textMemo(reusing: last - first + 1) }
                guard let rendered = RasterPage.render(days: days, width: width, height: height,
                    gutter: gutter, scale: scale, style: style, region: region, textMemo: textMemo) else { return false }
                page = rendered
                builds += 1; preparationMS.append(page.preparationMS); cache.put(page, for: key)
            }
            next[index] = Active(key: key, page: page, layer: active[index]?.layer ?? CALayer())
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        for (index, old) in active where next[index] == nil { old.layer.removeFromSuperlayer() }
        for tile in next.values {
            tile.layer.frame = CGRect(x: 0, y: tile.key.top, width: width, height: tile.key.height)
            tile.layer.contentsScale = scale; tile.layer.isOpaque = true
            if tile.layer.superlayer == nil { layer.addSublayer(tile.layer) }
            if invalidated || active[Int(tile.key.top / tileHeight)]?.key != tile.key { tile.layer.contents = tile.page.layerContents }
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
            scrollCancellation.cancel(); scrollCancellation = Operation()
            let cancellation = scrollCancellation, queue = preparationQueue, cooperative = cooperativeCancellation
            let token = generation
            scrollWork = Task.detached(priority: .utility) { [weak self] in
                let memo = queue == nil ? style.textMemo(reusing: requests.count) : nil
                for (key,rect) in requests {
                    guard !Task.isCancelled else { return }
                    if let queue {
                        Self.prepare(on: queue, cancellation: cancellation, days: days, width: width,
                            height: height, gutter: gutter, scale: scale, style: style, region: rect,
                            cooperative: cooperative) { [weak self] page in
                            self?.receive(page, key: key, generation: token)
                        }
                        continue
                    }
                    let page = autoreleasepool { RasterPage.render(days:days,width:width,height:height,
                        gutter:gutter,scale:scale,style:style,region:rect, textMemo: memo) }
                    guard !Task.isCancelled, let page else { return }
                    await self?.receive(page,key:key,generation:token)
                }
            }
        }
        return true
    }
    /// Prepare a complete band without changing the visible layer. The caller commits
    /// pixels, accessibility and heading together after validating its navigation request.
    /// Returned pages retain cache hits even if their combined size exceeds the spare LRU.
    func prepareInstall(days: [DayGeometry], width: CGFloat, height: CGFloat, gutter: CGFloat,
                        scale: CGFloat, viewport: CGRect, style: RasterPage.Style,
                        workers: Int, tileHeight: CGFloat = 256) async -> [RasterKey: RasterPage]? {
        guard !Task.isCancelled else { return nil }
        let began = DispatchTime.now().uptimeNanoseconds
        foregroundDispatchMS = 0; foregroundCompletionMS = 0
        cancelWork()
        let token = generation
        if foreground?.workers != workers { foreground = AsyncTilePreparation(workers: workers) }
        let visible = viewport.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !visible.isNull, !visible.isEmpty, !days.isEmpty else { return [:] }
        let dates = days.map(\.date)
        let first = max(0, Int(floor(visible.minY / tileHeight)))
        let last = min(Int(ceil(height / tileHeight)) - 1, Int(ceil(visible.maxY / tileHeight)) - 1)
        guard first <= last else { return [:] }
        var pages: [RasterKey: RasterPage] = [:]
        var requests: [AsyncTilePreparation.Request] = []
        for index in first...last {
            let top = CGFloat(index) * tileHeight
            let region = CGRect(x: 0, y: top, width: width, height: min(tileHeight, height - top))
            let key = RasterKey(dates: dates, width: width, scale: scale, top: top, height: region.height)
            if !invalidated, let old = active[index], old.key == key { pages[key] = old.page }
            else if let cached = cache.get(key) { pages[key] = cached }
            else { requests.append(.init(key: key, region: region)) }
        }
        foregroundDispatchMS = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        guard let prepared = await foreground!.prepare(requests, days: days, width: width,
            height: height, gutter: gutter, scale: scale, style: style) else { return nil }
        let finished = DispatchTime.now().uptimeNanoseconds
        guard generation == token, !Task.isCancelled else { return nil }
        foregroundDispatchMS += foreground?.dispatchMS ?? 0
        for result in prepared {
            pages[result.key] = result.page
            cache.put(result.page, for: result.key)
        }
        foregroundBuilds += prepared.count
        foregroundCompletionMS = Double(DispatchTime.now().uptimeNanoseconds - finished) / 1_000_000
        return pages
    }

    func preloadPages(store: FixtureStore, date: Date, dayCount: Int, width: CGFloat, height: CGFloat,
                      gutter: CGFloat, scale: CGFloat, viewport: CGRect, style: RasterPage.Style,
                      tileHeight: CGFloat = 256, budgeted: Bool = false) {
        pageWork?.cancel()
        pageCancellation.cancel(); pageCancellation = Operation()
        let cancellation = pageCancellation, queue = preparationQueue, cooperative = cooperativeCancellation
        let calendar = store.calendar, token = generation
        let first = max(0,Int(floor(viewport.minY/tileHeight)))
        let last = min(Int(ceil(height/tileHeight))-1,Int(ceil(viewport.maxY/tileHeight))-1)
        guard first <= last else { return }
        var directions = [dayCount, -dayCount]
        if budgeted {
            let rowBytes = ((Int(ceil(width * scale)) * 4 + 63) / 64) * 64
            let tileBytes = rowBytes * Int(ceil(tileHeight * scale))
            let pageTiles = last-first+1
            // Reserve the visible band plus two scroll neighbors before preparing pages.
            // Prefer returning to the last visited page when three bands cannot fit.
            if (pageTiles * 3 + 2) * tileBytes > cache.byteLimit || pageTiles * 3 + 2 > cache.countLimit {
                let prior = previousDates?.first
                let backward = calendar.date(byAdding: .day, value: -dayCount, to: date)
                directions = [prior == backward ? -dayCount : dayCount]
            }
        }
        let inputs = directions.map { offset -> ([(Date,[Fixture])],[(RasterKey,CGRect)]) in
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
                let memo = queue == nil ? style.textMemo(reusing: requests.count) : nil
                let days = rows.map { DayGeometry(date:$0.0,calendar:calendar,events:$0.1,buildIndex:false) }
                for (key,rect) in requests {
                    guard !Task.isCancelled else { return }
                    if let queue {
                        Self.prepare(on: queue, cancellation: cancellation, days: days, width: width,
                            height: height, gutter: gutter, scale: scale, style: style, region: rect,
                            cooperative: cooperative) { [weak self] page in
                            self?.receive(page, key: key, generation: token)
                        }
                        continue
                    }
                    let page = autoreleasepool { RasterPage.render(days:days,width:width,height:height,
                        gutter:gutter,scale:scale,style:style,region:rect, textMemo: memo) }
                    guard !Task.isCancelled, let page else { return }
                    await self?.receive(page,key:key,generation:token)
                }
            }
        }
    }
    // Native queue caps simultaneous bitmap allocations across page and scroll speculation.
    // Each job owns its CGContext and Core Text layout objects. Only immutable pixels return.
    // The explicit cooperative variant also polls cancellation during text/event drawing.
    nonisolated private static func prepare(on queue: OperationQueue, cancellation: Operation,
        days: [DayGeometry], width: CGFloat, height: CGFloat, gutter: CGFloat, scale: CGFloat,
        style: RasterPage.Style, region: CGRect, cooperative: Bool,
        receive: @escaping @MainActor @Sendable (RasterPage) -> Void) {
        queue.addOperation {
            guard !cancellation.isCancelled else { return }
            let cancelled: (@Sendable () -> Bool)?
                    if cooperative { cancelled = { cancellation.isCancelled } }
                    else { cancelled = nil }
            let page = autoreleasepool {
                RasterPage.render(days: days, width: width, height: height, gutter: gutter,
                                  scale: scale, style: style, region: region, cancelled: cancelled)
            }
            guard !cancellation.isCancelled, let page else { return }
            Task { @MainActor in
                guard !cancellation.isCancelled else { return }
                receive(page)
            }
        }
    }
    private func receive(_ page: RasterPage, key: RasterKey, generation token: Int) {
        guard token == generation else { return }
        cache.put(page,for:key); prefetchedBuilds += 1
        for tile in active.values { _ = cache.get(tile.key) }
    }
    private func cancelWork() {
        foreground?.cancel()
        generation += 1; scrollWork?.cancel(); pageWork?.cancel()
        scrollCancellation.cancel(); pageCancellation.cancel(); preparationQueue?.cancelAllOperations()
        scrollWork = nil; pageWork = nil
    }
    func evict() {
        cancelWork()
        cache.clear(); invalidated = true
        // The active visible layers retain their pixels until replacements are ready.
    }
    func clear() {
        cancelWork(); identity = nil; previousDates = nil
        active.values.forEach { $0.layer.removeFromSuperlayer() }
        active.removeAll(); invalidated = false
    }
    deinit {
        scrollWork?.cancel(); pageWork?.cancel()
        scrollCancellation.cancel(); pageCancellation.cancel(); preparationQueue?.cancelAllOperations()
    }
}
