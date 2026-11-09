import SwiftUI

/// A left-to-right flow of subviews that WRAPS to a new line instead of clipping or forcing the
/// window wider — the fix for the detail hero's unbounded `HStack(spacing: 28)`, which already
/// clips at 5 of its up-to-12 possible metric pairs. Standard `Layout` wrap-by-width
/// implementation: lay subviews left to right, starting a new line whenever the next one would
/// overflow the proposed width.
struct WrappingLayout: Layout {
    var spacing: CGFloat = 20
    var lineSpacing: CGFloat = 12
    /// Offer each subview the line's width at most, so one too long for a line truncates on a
    /// line of its own instead of running off the edge. Off: each takes the size it asks for.
    var fitsWidth = false

    /// Its own size, or the line's width when it's wider than that: offered the whole line, a
    /// button takes all of it and every one sits on a line of its own.
    private func size(of subview: LayoutSubview, in width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard fitsWidth, width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0
        for subview in subviews {
            let size = size(of: subview, in: maxWidth)
            if x > 0, x + size.width > maxWidth {
                widestLine = max(widestLine, x - spacing)
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widestLine = max(widestLine, x - spacing)
        y += lineHeight
        return CGSize(width: proposal.width ?? max(widestLine, 0), height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = size(of: subview, in: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
