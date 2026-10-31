import CoreGraphics
import CoreText
import Foundation

/// Event artwork only: the collection cell retains hit testing, editing and accessibility.
/// Resolve platform colors/fonts/symbol images before entering this worker-local renderer.
enum CalendarNativeEventRaster {
    struct Text {
        let value: NSAttributedString
        let maximumLines: Int
    }
    struct Request {
        let size: CGSize
        let scale: CGFloat
        let tint: CGColor
        let ribbons: [CGColor]
        let fillOpacity: CGFloat
        let opacity: CGFloat
        let title: Text
        let subtitle: Text?
        let location: Text?
        let icon: CGImage?
        let warning: CGImage?
        let desktop: Bool
        let rightToLeft: Bool
        let free: Bool
        let tentative: Bool
        let needsAction: Bool
        let textVisible: Bool
        let centerSingleLine: Bool
        let strikeThrough: Bool
        var redacted = false
        var subtitleIcon: CGImage? = nil
    }
    enum Failure: Error { case invalidDimensions, exceedsBudget, allocation }

    static func render(_ request: Request, maximumBytes: Int = 2 * 1024 * 1024) throws -> CGImage {
        let size = request.size, scale = request.scale
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { throw Failure.invalidDimensions }
        let width = ceil(size.width * scale), height = ceil(size.height * scale)
        guard width.isFinite, height.isFinite, maximumBytes > 0,
              width * height <= CGFloat(maximumBytes / 4) else { throw Failure.exceedsBudget }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height),
            bitsPerComponent: 8, bytesPerRow: Int(width) * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.allocation }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        draw(request, in: context)
        guard let image = context.makeImage() else { throw Failure.allocation }
        return image
    }

    /// Draw the same artwork into a caller-owned top-left/y-down canvas. Oversized cells
    /// use the host's drawing surface instead of allocating an over-budget cached CGImage.
    /// Framework backing-store memory is separate and requires device measurement.
    static func draw(_ request: Request, in context: CGContext) {
        let size = request.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(request.opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let bounds = CGRect(origin: .zero, size: size)
        let radius = min(5, size.width / 2, size.height / 2)
        let outline = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(outline); context.clip()
        func fill(_ color: CGColor, alpha: CGFloat, rect: CGRect) {
            context.setFillColor(color.copy(alpha: color.alpha * alpha)!)
            context.fill(rect)
        }
        fill(request.tint, alpha: request.fillOpacity, rect: bounds)
        if request.ribbons.count > 1 {
            for (index, color) in request.ribbons.enumerated() {
                let diameter: CGFloat = 5
                let x = request.rightToLeft ? size.width - 4 - diameter : 4
                let rect = CGRect(x: x, y: 4 + CGFloat(index) * 7, width: diameter, height: diameter)
                context.setFillColor(color.copy(alpha: color.alpha * (request.free ? 0.4 : 1))!)
                context.fillEllipse(in: rect)
            }
        }
        if request.redacted && request.textVisible {
            // Fixed geometry: neither the text nor its length leaks through redacted images.
            let inset: CGFloat = 8 + (request.ribbons.count > 1 ? 9 : 0)
            let available = max(0, size.width - inset - 4)
            for (index, fraction) in [CGFloat(0.8), 0.6, 0.7].enumerated() {
                let y = CGFloat(index) * 15 + 4
                guard y + 8 <= size.height else { break }
                let width = available * fraction
                let x = request.rightToLeft ? size.width - inset - width : inset
                context.setFillColor(request.tint.copy(alpha: request.tint.alpha * 0.25)!)
                context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: 8),
                    cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.fillPath()
            }
        } else if request.textVisible {
            let inset: CGFloat = 8 + (request.ribbons.count > 1 ? 9 : 0)
            var leading = request.rightToLeft ? 4 : inset
            var available = max(0, size.width - inset - 4)
            let initialY: CGFloat = request.centerSingleLine ? 0 : (request.desktop ? 4 : (size.height < 16 ? 0 : 2))
            var icons: [CGImage] = []
            if let icon = request.icon { icons.append(icon) }
            if let warning = request.warning { icons.append(warning) }
            for image in icons {
                let iconX = request.rightToLeft ? leading + available - 9 : leading
                let iconY = request.centerSingleLine ? max(0, (size.height - 9) / 2) : initialY + 1
                context.saveGState()
                context.translateBy(x: iconX, y: iconY + 9); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 9))
                context.restoreGState()
                if !request.rightToLeft { leading += 13 }
                available = max(0, available - 13)
            }
            let title = CalendarNativeText(request.title.value, width: available,
                maximumLines: request.title.maximumLines)
            var y = request.centerSingleLine ? max(0, (size.height - title.height) / 2) : initialY
            title.draw(in: context, rect: CGRect(x: leading, y: y, width: available,
                height: max(0, size.height - y)), rightAligned: request.rightToLeft)
            if request.strikeThrough {
                context.saveGState()
                context.clip(to: CGRect(x: leading, y: y, width: available, height: max(0, size.height - y)))
                context.setStrokeColor(request.tint); context.setLineWidth(0.7)
                for line in title.lines {
                    let extent = min(available, line.width)
                    let x = leading + (request.rightToLeft ? available - extent : 0)
                    let strikeY = y + line.baseline - 3.5
                    context.move(to: CGPoint(x: x, y: strikeY))
                    context.addLine(to: CGPoint(x: x + extent, y: strikeY))
                }
                context.strokePath(); context.restoreGState()
            }
            y += title.height + 1
            // Metadata uses the full content width, independently of title icon indentation.
            let metaX: CGFloat = request.rightToLeft ? 4 : inset
            let metaWidth = max(0, size.width - inset - 4)
            for (index, text) in [request.subtitle, request.location].enumerated() {
                guard let text else { continue }
                let icon = index == 0 ? request.subtitleIcon : nil
                let textX = metaX + (icon != nil && !request.rightToLeft ? 13 : 0)
                let textWidth = max(0, metaWidth - (icon == nil ? 0 : 13))
                if let icon {
                    let iconX = request.rightToLeft ? metaX + metaWidth - 9 : metaX
                    context.saveGState()
                    context.translateBy(x: iconX, y: y + 10); context.scaleBy(x: 1, y: -1)
                    context.draw(icon, in: CGRect(x: 0, y: 0, width: 9, height: 9))
                    context.restoreGState()
                }
                let layout = CalendarNativeText(text.value, width: textWidth, maximumLines: text.maximumLines)
                layout.draw(in: context, rect: CGRect(x: textX, y: y, width: textWidth,
                    height: max(0, size.height - y)), rightAligned: request.rightToLeft)
                y += layout.height + 1
            }
        }
        func border(width: CGFloat, dash: [CGFloat]) {
            context.setLineWidth(width); context.setLineDash(phase: 0, lengths: dash)
            context.setStrokeColor(request.tint.copy(alpha: request.tint.alpha * 0.85)!)
            let inset = bounds.insetBy(dx: width / 2, dy: width / 2)
            guard inset.width > 0, inset.height > 0 else { return }
            context.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, radius - width / 2),
                cornerHeight: max(0, radius - width / 2), transform: nil))
            context.strokePath()
        }
        if request.free { border(width: 1.5, dash: [4, 3]) }
        if request.tentative {
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(1.5)
            context.setStrokeColor(request.tint.copy(alpha: request.tint.alpha * 0.35)!)
            var x = -size.height
            while x < size.width {
                context.move(to: CGPoint(x: x, y: size.height))
                context.addLine(to: CGPoint(x: x + size.height, y: 0)); x += 6
            }
            context.strokePath()
        } else if request.needsAction { border(width: 1, dash: []) }
        context.endTransparencyLayer()
    }
}
