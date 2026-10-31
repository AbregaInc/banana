import CoreText
import Foundation

/// Worker-local Core Text layout for the production event adapter. Unlike the prototype's
/// single glyph line, this preserves contextual wrapping, fallback fonts and color emoji.
/// Create and draw on the same preparation worker; only the resulting CGImage crosses queues.
struct CalendarNativeText {
    struct Line {
        let value: CTLine
        let baseline: CGFloat
        let width: CGFloat
    }
    let lines: [Line]
    let height: CGFloat
    let truncated: Bool

    init(_ text: NSAttributedString, width: CGFloat, maximumLines: Int,
         lineSpacing: CGFloat = 1) {
        guard width.isFinite, width > 0, maximumLines > 0, text.length > 0,
              lineSpacing.isFinite, lineSpacing >= 0 else {
            lines = []; height = 0; truncated = text.length > 0; return
        }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var result: [Line] = []
        result.reserveCapacity(min(maximumLines, text.length))
        var offset = 0
        var bottom: CGFloat = 0
        var clipped = false
        while offset < text.length && result.count < maximumLines {
            let count = CTTypesetterSuggestLineBreak(typesetter, offset, Double(width))
            guard count > 0 else { clipped = true; break }
            let remaining = text.length - offset
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count))
            if result.count == maximumLines - 1 && count < remaining {
                let tail = text.attributedSubstring(from: NSRange(location: offset, length: remaining))
                let hardBreak = (tail.string as NSString).rangeOfCharacter(from: .newlines)
                let suffix = NSMutableAttributedString(attributedString: hardBreak.location == NSNotFound
                    ? tail : tail.attributedSubstring(from: NSRange(location: 0, length: hardBreak.location)))
                let ellipsis = NSAttributedString(string: "…",
                    attributes: text.attributes(at: offset, effectiveRange: nil))
                // An explicit newline means content is omitted even when the first line fits.
                if hardBreak.location != NSNotFound { suffix.append(ellipsis) }
                let token = CTLineCreateWithAttributedString(ellipsis)
                let full = CTLineCreateWithAttributedString(suffix)
                line = CTLineCreateTruncatedLine(full, Double(width), .end, token) ?? token
                clipped = true
            }
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let baseline = bottom + ascent
            result.append(Line(value: line, baseline: baseline, width: CGFloat(advance)))
            bottom = baseline + descent + max(0, leading) + lineSpacing
            offset += count
        }
        lines = result
        height = max(0, bottom - (result.isEmpty ? 0 : lineSpacing))
        truncated = clipped || offset < text.length
    }

    /// Draw in a top-left/y-down canvas. Clipping also handles widths narrower than ellipsis.
    func draw(in context: CGContext, rect: CGRect, rightAligned: Bool = false) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.textMatrix = .identity
        for line in lines {
            context.saveGState()
            let x = rect.minX + (rightAligned ? max(0, rect.width - line.width) : 0)
            context.translateBy(x: x, y: rect.minY + line.baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line.value, context)
            context.restoreGState()
        }
    }
}
