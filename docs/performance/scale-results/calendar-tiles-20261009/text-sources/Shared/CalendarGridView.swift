#if os(iOS)
import UIKit
#else
import AppKit
#endif

// A single native backing store retains grid pixels independently of event redraws.
// AppKit needs an explicitly retained image: a transparent sibling otherwise causes
// underlying views to redraw. Keep only the current size/scale/style, never page history.
@MainActor
final class CalendarGridView: PlatformView {
    var paint: ((CGRect) -> Void)?
    #if !os(iOS)
    private var cachedImage: CGImage?
    private var cachedSize = CGSize.zero
    private var cachedScale: CGFloat = 0
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        if cachedImage == nil || cachedSize != bounds.size || cachedScale != scale {
            let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: NSColorSpace.genericRGB.cgColorSpace!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            paint?(bounds)
            NSGraphicsContext.restoreGraphicsState()
            cachedImage = context.makeImage(); cachedSize = bounds.size; cachedScale = scale
        }
        layer?.contentsScale = scale
        layer?.contents = cachedImage
    }
    #endif
    #if os(iOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isOpaque = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("Programmatic prototype") }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { invalidate() }
    }
    #else
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidate()
    }
    #endif
    func invalidate() {
        #if os(iOS)
        setNeedsDisplay()
        #else
        cachedImage = nil
        needsDisplay = true
        #endif
    }
    override func draw(_ dirtyRect: CGRect) { paint?(dirtyRect) }
}
