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
    private(set) var builds = 0
    private(set) var preparationMS: [Double] = []
    var ids: Set<String> { active.values.reduce(into: Set<String>()) { $0.formUnion($1.page.ids) } }
    var activeCount: Int { active.count }
    var activeBytes: Int { active.values.reduce(0) { $0 + $1.page.bytes } }
    var contentsPresent: Bool { !active.isEmpty && active.values.allSatisfy { $0.layer.contents != nil } }

    func install(days: [DayGeometry], width: CGFloat, height: CGFloat, gutter: CGFloat,
                 scale: CGFloat, viewport: CGRect, style: RasterPage.Style, tileHeight: CGFloat = 256) -> Bool {
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
        return true
    }
    func evict() {
        cache.clear(); invalidated = true
        // The active visible layers retain their pixels until replacements are ready.
    }
    func clear() {
        active.values.forEach { $0.layer.removeFromSuperlayer() }
        active.removeAll(); invalidated = false
    }
}
