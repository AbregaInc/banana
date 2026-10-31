import CoreText
import Foundation

// CTFont is documented safe across work queues. CTLine/CTRun stay inside the operation
// that creates them; only immutable copied glyph/position arrays cross to the UI thread.
// https://developer.apple.com/documentation/CoreText
struct PreparedText: @unchecked Sendable {
    struct Style: @unchecked Sendable {
        let font: CTFont
        let color: CGColor
    }
    private struct Run {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let inkStarts: [CGFloat]
        let orderedInk: Bool
    }
    private let runs: [Run]
    private let color: CGColor
    init(_ text: String, style: Style) {
        color = style.color
        let attributes = [kCTFontAttributeName: style.font, kCTForegroundColorAttributeName: style.color] as [CFString: Any]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(string)
        runs = (CTLineGetGlyphRuns(line) as! [CTRun]).map { run in
            let count = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(0), count: count)
            var positions = Array(repeating: CGPoint.zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            var boxes = Array(repeating: CGRect.zero, count: count)
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &boxes, count)
            let starts = zip(positions, boxes).map { $0.x + $1.minX }
            let ordered = zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 }
            return Run(font: font, glyphs: glyphs, positions: positions, inkStarts: starts, orderedInk: ordered)
        }
    }
    func draw(in context: CGContext, maxWidth: CGFloat? = nil) {
        context.setFillColor(color)
        for run in runs where !run.glyphs.isEmpty {
            var count = run.glyphs.count
            if let width = maxWidth, run.orderedInk {
                var low = 0
                var high = count
                while low < high {
                    let middle = (low + high) / 2
                    // Preserve antialiasing outside the mathematical ink bounds.
                    // The bitmap oracle caught clipped accent pixels without this fringe.
                    if run.inkStarts[middle] < width + 1 { low = middle + 1 } else { high = middle }
                }
                count = low
            }
            guard count > 0 else { continue }
            run.glyphs.withUnsafeBufferPointer { glyphs in
                run.positions.withUnsafeBufferPointer { positions in
                    CTFontDrawGlyphs(run.font, glyphs.baseAddress!, positions.baseAddress!, count, context)
                }
            }
        }
    }
}
