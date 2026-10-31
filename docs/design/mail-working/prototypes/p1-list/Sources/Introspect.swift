import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformScrollView = UIScrollView
#else
import AppKit
typealias PlatformScrollView = NSScrollView
#endif

/// Finds the platform scroll view a SwiftUI `List` / `ScrollView` is drawn in. Used only to read
/// ground truth (offset, realised cells) for cross-checking the SwiftUI-side numbers; no host
/// *depends* on it for behaviour.
@MainActor
enum Introspect {
    #if os(iOS)
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first
    }

    static func scrollView() -> UIScrollView? {
        guard let w = keyWindow else { return nil }
        var best: UIScrollView?
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, s.bounds.height > 200 {
                if best == nil || s.bounds.height * s.bounds.width > best!.bounds.height * best!.bounds.width { best = s }
            }
            v.subviews.forEach(walk)
        }
        walk(w)
        return best
    }

    static func className() -> String { scrollView().map { String(describing: type(of: $0)) } ?? "none" }

    /// What a drag does: leaves the scroll view at an offset nobody asked for. Used to put every host at a
    /// fractional position without using the host's own scrolling API (which is what is being tested).
    static func nudge(by dy: CGFloat) {
        guard let s = scrollView() else { return }
        s.setContentOffset(CGPoint(x: s.contentOffset.x, y: s.contentOffset.y + dy), animated: false)
    }

    static func offset(_ s: UIScrollView) -> CGFloat { s.contentOffset.y + s.adjustedContentInset.top }

    /// Where the view's top edge is on screen, in window coordinates. The layers' model values, plus, for
    /// any layer in the chain that has an animation in flight (UIKit animates cells into place after a
    /// batch update), how far the presentation layer is from its model position: so a cell that is
    /// sliding reads where it is drawn, and nothing animating reads exactly its model value. (Mixing
    /// presentation values for some layers and model values for others would skew a sample taken
    /// between a change and the commit that shows it, so presentation values are used only for the deviation.)
    static func presentedY(of view: UIView) -> CGFloat {
        var y = view.convert(CGPoint.zero, to: nil).y
        var cur: UIView? = view
        while let v = cur {
            if let keys = v.layer.animationKeys(), !keys.isEmpty, let p = v.layer.presentation() {
                y += p.position.y - v.layer.position.y
                if v !== view { y -= p.bounds.origin.y - v.layer.bounds.origin.y }
            }
            cur = v.superview
        }
        return y
    }

    /// The cell at a window index of a collection-view-backed list (SwiftUI `List` on iOS, or the native host).
    static func cellY(windowIndex: Int) -> CGFloat? {
        guard let cv = scrollView() as? UICollectionView,
              cv.numberOfSections > 0, windowIndex < cv.numberOfItems(inSection: 0),
              let cell = cv.cellForItem(at: IndexPath(item: windowIndex, section: 0)) else { return nil }
        let y = presentedY(of: cell)
        // Only a row that is on screen has an answer: a cell UIKit has reused away keeps a stale frame.
        let top = cv.convert(CGPoint(x: 0, y: cv.bounds.minY), to: nil).y
        return (y > top - cell.bounds.height && y < top + cv.bounds.height) ? y : nil
    }
    #else
    static var window: NSWindow? { NSApp.windows.first { $0.isVisible } }

    static func scrollView() -> NSScrollView? {
        guard let root = window?.contentView else { return nil }
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.bounds.height > 200 {
                if best == nil || s.bounds.height * s.bounds.width > best!.bounds.height * best!.bounds.width { best = s }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    static func className() -> String {
        guard let s = scrollView() else { return "none" }
        let doc = s.documentView.map { String(describing: type(of: $0)) } ?? "nil"
        return "\(type(of: s))/\(doc)"
    }

    static func offset(_ s: NSScrollView) -> CGFloat { s.contentView.bounds.origin.y + s.contentInsets.top }

    static func nudge(by dy: CGFloat) {
        guard let s = scrollView() else { return }
        s.contentView.scroll(to: NSPoint(x: s.contentView.bounds.origin.x, y: s.contentView.bounds.origin.y + dy))
        s.reflectScrolledClipView(s.contentView)
    }

    /// Top of a row in window coordinates, y down from the top of the window's content view.
    static func rowY(windowIndex: Int) -> CGFloat? {
        guard let s = scrollView(), let table = s.documentView as? NSTableView,
              windowIndex >= 0, windowIndex < table.numberOfRows,
              let win = s.window else { return nil }
        let r = table.rect(ofRow: windowIndex)
        guard r.height > 0 else { return nil }
        let inWindow = table.convert(r, to: nil)
        return win.frame.height - inWindow.maxY
    }
    #endif
}
