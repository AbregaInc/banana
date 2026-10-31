import Foundation
import CoreGraphics
import CoreText

struct RasterKey: Hashable {
    let dates: [Date]
    let width: Double
    let scale: Double
    var top: Double = 0
    var height: Double = 1920
}

// Immutable pixels only cross the worker boundary. UI objects never enter this renderer.
struct RasterPage: @unchecked Sendable {
    struct Style: @unchecked Sendable {
        let text: PreparedText.Style
        let hours: PreparedText.Style
        let background: CGColor
        let separator: CGColor
        let event: CGColor
    }
    let image: CGImage
    let ids: Set<String>
    let preparationMS: Double
    var bytes: Int { image.bytesPerRow * image.height }

    static func render(days: [DayGeometry], width: CGFloat, height: CGFloat, gutter: CGFloat,
                       scale: CGFloat, style: Style, region: CGRect? = nil) -> RasterPage? {
        let began = DispatchTime.now().uptimeNanoseconds
        let region = region ?? CGRect(x: 0, y: 0, width: width, height: height)
        let pixelWidth = Int(ceil(width * scale)), pixelHeight = Int(ceil(region.height * scale))
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: region.height); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -region.minY)
        context.setFillColor(style.background); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(style.separator); context.setLineWidth(0.5)
        for hour in 0...24 {
            let y = CGFloat(hour) * height / 24
            context.move(to: CGPoint(x: gutter, y: y)); context.addLine(to: CGPoint(x: width, y: y))
        }
        for day in 0...days.count {
            let x = gutter + CGFloat(day) * max(1, width - gutter) / CGFloat(max(1, days.count))
            context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height))
        }
        context.strokePath()
        for hour in 0..<24 {
            context.saveGState(); context.textMatrix = .identity
            context.translateBy(x: 3, y: CGFloat(hour) * height / 24 + 13); context.scaleBy(x: 1, y: -1)
            PreparedText(String(format: "%02d:00", hour), style: style.hours).draw(in: context)
            context.restoreGState()
        }
        var ids = Set<String>()
        for (day, geometry) in days.enumerated() {
            for item in geometry.placements {
                guard !Task.isCancelled else { return nil }
                let key = "\(day):\(item.id)"
                let rect = item.rect(day: day, dayCount: days.count, width: width, height: height, gutter: gutter)
                guard rect.intersects(region.insetBy(dx: 0, dy: -1 / scale)) else { continue }
                context.setFillColor(style.event)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: min(3, rect.width / 2), cornerHeight: min(3, rect.height / 2), transform: nil))
                context.fillPath()
                context.saveGState(); context.clip(to: rect); context.textMatrix = .identity
                context.translateBy(x: rect.minX + 3, y: rect.minY + 14); context.scaleBy(x: 1, y: -1)
                PreparedText("Event \(key)", style: style.text).draw(in: context, maxWidth: rect.width - 3)
                context.restoreGState(); ids.insert(key)
            }
        }
        guard let image = context.makeImage() else { return nil }
        return RasterPage(image: image, ids: ids,
                          preparationMS: Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
    }
}

// An experiment-specific retention limit, not a product/device memory budget.
// Also bound entry count so small images cannot retain unbounded history.
final class RasterCache {
    let byteLimit: Int
    let countLimit: Int
    private var pages: [RasterKey: RasterPage] = [:]
    private var order: [RasterKey] = []
    private(set) var bytes = 0
    var count: Int { pages.count }
    init(byteLimit: Int = 128 * 1024 * 1024, countLimit: Int = 3) {
        precondition(byteLimit > 0 && countLimit > 0)
        self.byteLimit = byteLimit; self.countLimit = countLimit
    }
    func get(_ key: RasterKey) -> RasterPage? {
        guard let page = pages[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key); return page
    }
    func put(_ page: RasterPage, for key: RasterKey) {
        if let old = pages.removeValue(forKey: key) { bytes -= old.bytes }
        order.removeAll { $0 == key }
        guard page.bytes <= byteLimit else { return }
        pages[key] = page; order.append(key); bytes += page.bytes
        while bytes > byteLimit || order.count > countLimit {
            bytes -= pages.removeValue(forKey: order.removeFirst())!.bytes
        }
    }
    func clear() { pages.removeAll(); order.removeAll(); bytes = 0 }
}
