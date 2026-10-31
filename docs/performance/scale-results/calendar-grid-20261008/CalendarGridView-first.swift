#if os(iOS)
import UIKit
#else
import AppKit
#endif

// A single native backing store retains grid pixels independently of event redraws.
// Native view caching is used instead of allocating and managing another image cache.
@MainActor
final class CalendarGridView: PlatformView {
    var paint: ((CGRect) -> Void)?
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
        needsDisplay = true
        #endif
    }
    override func draw(_ dirtyRect: CGRect) { paint?(dirtyRect) }
}
