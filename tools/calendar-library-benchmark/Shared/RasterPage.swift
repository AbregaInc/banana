import Foundation
import CoreGraphics
import CoreText
import CoreVideo

struct RasterKey: Hashable, Sendable {
    let dates: [Date]
    let width: Double
    let scale: Double
    var top: Double = 0
    var height: Double = 1920
}

// Immutable pixels only cross the worker boundary. UI objects never enter this renderer.
struct RasterPage: @unchecked Sendable {
    // The concurrent rectangle repro on macOS 26.6.2 (25G83) produces wrong
    // antialiased fill colors across independent CGContext instances. Serialize
    // only event fills; geometry and text preparation remain worker-local/parallel.
    // Keep the exact-pixel oracle: neither format changes nor flush solved this.
    private static let fillLock = NSLock()
    struct Style: @unchecked Sendable {
        let text: PreparedText.Style
        let hours: PreparedText.Style
        let background: CGColor
        let separator: CGColor
        let event: CGColor
        var cullTileText = false
        var nativeText = false
        var pixelBuffer = false
        // Experimental: lower medians, but a worse retained eviction tail.
        // Keep single-pass ordering as the default and exact-pixel reference.
        var batchEventFills = CalendarFixtureConfiguration().args.contains("--batch-event-fills")
        var memoText = CalendarFixtureConfiguration().args.contains("--memo-raster-text")
        func textMemo(reusing tileCount: Int) -> RasterTextMemo? {
            guard memoText else { return nil }
            precondition(!nativeText, "Text memo targets prepared glyphs, not native CTLine drawing")
            guard tileCount > 1 else { return nil }
            return RasterTextMemo(text: text, hours: hours)
        }
    }
    private let bitmap: CGImage?
    let pixelBuffer: CVPixelBuffer?
    /// CALayer accepts a surface-backed CVPixelBuffer directly. Never construct a
    /// CGImage snapshot on that presentation path; snapshots are for pixel oracles.
    var layerContents: Any { if let pixelBuffer { return pixelBuffer }; return bitmap! }
    var image: CGImage {
        if let bitmap { return bitmap }
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let sourceRow = CVPixelBufferGetBytesPerRow(buffer)
        let source = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        // Canonical RGBA snapshot; the live native surface stays immutable BGRA.
        let rowBytes = ((width * 4 + 63) / 64) * 64
        var bytes = Data(count: rowBytes * height)
        bytes.withUnsafeMutableBytes { raw in
            let target = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let from = y * sourceRow + x * 4, to = y * rowBytes + x * 4
                    target[to] = source[from + 2]; target[to + 1] = source[from + 1]
                    target[to + 2] = source[from]; target[to + 3] = source[from + 3]
                }
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)!
    }
    let ids: Set<String>
    let preparationMS: Double
    var bytes: Int { pixelBuffer.map { CVPixelBufferGetDataSize($0) } ?? (bitmap!.bytesPerRow * bitmap!.height) }

    static func render(days: [DayGeometry], width: CGFloat, height: CGFloat, gutter: CGFloat,
                       scale: CGFloat, style: Style, region: CGRect? = nil,
                       cancelled: (@Sendable () -> Bool)? = nil,
                       textMemo: RasterTextMemo? = nil) -> RasterPage? {
        precondition(textMemo?.supports(text: style.text, hours: style.hours) ?? true)
        guard cancelled?() != true else { return nil }
        let began = DispatchTime.now().uptimeNanoseconds
        let region = region ?? CGRect(x: 0, y: 0, width: width, height: height)
        let pixelWidth = Int(ceil(width * scale)), pixelHeight = Int(ceil(region.height * scale))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer: CVPixelBuffer?
        let context: CGContext
        if style.pixelBuffer {
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferBytesPerRowAlignmentKey: 64]
            guard CVPixelBufferCreate(kCFAllocatorDefault, pixelWidth, pixelHeight,
                kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
                let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
            guard let address = CVPixelBufferGetBaseAddress(buffer),
                let bitmapContext = CGContext(data: address,
                width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, []); return nil
            }
            context = bitmapContext
        } else {
            guard let bitmapContext = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context = bitmapContext
        }
        defer { if let buffer { CVPixelBufferUnlockBaseAddress(buffer, []) } }
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
        // Benchmark labels use ASCII with these exact fonts. Arbitrary user titles
        // would require conservative bounds for every fallback font before culling.
        let hourInk = style.cullTileText ? CTFontGetBoundingBox(style.hours.font) : .zero
        let titleInk = style.cullTileText ? CTFontGetBoundingBox(style.text.font) : .zero
        func drawText(_ text: String, style textStyle: PreparedText.Style, maxWidth: CGFloat? = nil, hours: Bool = false) {
            if style.nativeText {
                // Raster jobs own their context and line on one worker. No glyph arrays need
                // to cross threads, so Core Text can draw its native line directly.
                let attributes = [kCTFontAttributeName: textStyle.font,
                    kCTForegroundColorAttributeName: textStyle.color] as [CFString: Any]
                let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
                context.textPosition = .zero
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            } else {
                (textMemo?.line(text, hours: hours) ?? PreparedText(text, style: textStyle)).draw(in: context, maxWidth: maxWidth)
            }
        }
        func textIntersects(_ baseline: CGFloat, ink: CGRect, clip: CGRect) -> Bool {
            let extent = CGRect(x: clip.minX, y: baseline-ink.maxY, width: clip.width, height: ink.height)
                .insetBy(dx: 0, dy: -1/scale)
            return extent.intersection(clip).intersects(region)
        }
        for hour in 0..<24 {
            guard cancelled?() != true else { return nil }
            let baseline = CGFloat(hour) * height / 24 + 13
            if style.cullTileText && !textIntersects(baseline, ink: hourInk,
                clip: CGRect(x:0,y:0,width:gutter,height:height)) { continue }
            context.saveGState(); context.textMatrix = .identity
            context.translateBy(x: 3, y: CGFloat(hour) * height / 24 + 13); context.scaleBy(x: 1, y: -1)
            drawText(String(format: "%02d:00", hour), style: style.hours, hours: true)
            context.restoreGState()
        }
        var ids = Set<String>()
        if style.batchEventFills {
            // DayGeometry assigns non-overlapping event lanes. Batch backgrounds
            // under one lock, then prepare/draw clipped labels concurrently.
            // Pixel tests compare this ordering with the original interleaved path.
            var visible: [(key: String, item: EventPlacement, rect: CGRect)] = []
            for (day, geometry) in days.enumerated() {
                for item in geometry.placements {
                    let rect = item.rect(day: day, dayCount: days.count, width: width, height: height, gutter: gutter)
                    if rect.intersects(region.insetBy(dx: 0, dy: -1 / scale)) {
                        visible.append(("\(day):\(item.id)", item, rect))
                    }
                }
            }
            fillLock.lock()
            for (_, item, rect) in visible {
                if Task.isCancelled || cancelled?() == true { fillLock.unlock(); return nil }
                context.setFillColor(item.title == nil ? style.event : FixturePalette.fills[item.calendarIndex])
                context.addPath(CGPath(roundedRect: rect, cornerWidth: min(3, rect.width / 2), cornerHeight: min(3, rect.height / 2), transform: nil))
                context.fillPath()
            }
            fillLock.unlock()
            for (key, item, rect) in visible {
                guard !Task.isCancelled, cancelled?() != true else { return nil }
                if !style.cullTileText || item.title != nil || textIntersects(rect.minY+14, ink: titleInk, clip: rect) {
                    context.saveGState(); context.clip(to: rect); context.textMatrix = .identity
                    context.translateBy(x: rect.minX + 3, y: rect.minY + 14); context.scaleBy(x: 1, y: -1)
                    drawText(item.title ?? "Event \(key)", style: style.text, maxWidth: item.title == nil ? rect.width - 3 : nil)
                    context.restoreGState()
                }
                ids.insert(key)
            }
        } else {
            for (day, geometry) in days.enumerated() {
                for item in geometry.placements {
                    guard !Task.isCancelled, cancelled?() != true else { return nil }
                    let key = "\(day):\(item.id)"
                    let rect = item.rect(day: day, dayCount: days.count, width: width, height: height, gutter: gutter)
                    guard rect.intersects(region.insetBy(dx: 0, dy: -1 / scale)) else { continue }
                    fillLock.lock()
                    context.setFillColor(item.title == nil ? style.event : FixturePalette.fills[item.calendarIndex])
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: min(3, rect.width / 2), cornerHeight: min(3, rect.height / 2), transform: nil))
                    context.fillPath()
                    fillLock.unlock()
                    if !style.cullTileText || item.title != nil || textIntersects(rect.minY+14, ink: titleInk, clip: rect) {
                        context.saveGState(); context.clip(to: rect); context.textMatrix = .identity
                        context.translateBy(x: rect.minX + 3, y: rect.minY + 14); context.scaleBy(x: 1, y: -1)
                        drawText(item.title ?? "Event \(key)", style: style.text, maxWidth: item.title == nil ? rect.width - 3 : nil)
                        context.restoreGState()
                    }
                    ids.insert(key)
                }
            }
        }
        // All drawing completes before the buffer is unlocked and returned. Published
        // buffers are never mutated or recycled while a layer/cache can retain them.
        let image = buffer == nil ? context.makeImage() : nil
        guard buffer != nil || image != nil else { return nil }
        return RasterPage(bitmap: image, pixelBuffer: buffer, ids: ids,
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
