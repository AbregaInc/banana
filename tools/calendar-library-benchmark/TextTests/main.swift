import Foundation
import CoreText

func require(_ ok: Bool, _ message: String) {
    if !ok { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
let font = CTFontCreateUIFontForLanguage(.system, 12, nil)!
let color = CGColor(gray: 0, alpha: 1)
let style = PreparedText.Style(font: font, color: color)
func context() -> CGContext {
    let context = CGContext(data: nil, width: 300, height: 48, bitsPerComponent: 8, bytesPerRow: 1200,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 4, y: 20); context.textMatrix = .identity; context.textPosition = .zero
    return context
}
func line(_ text: String) -> CTLine {
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as [CFString: Any]
    return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!)
}
var reports: [[String: Any]] = []
for text in ["Event 0:15-80", "Réunion – 東京", "مرحبا", "Meet 👩‍💻"] {
    let reference = context(); CTLineDraw(line(text), reference)
    let prepared = PreparedText(text, style: style)
    let actual = context(); prepared.draw(in: actual)
    let expectedBytes = Data(bytes: reference.data!, count: 1200 * 48)
    let actualBytes = Data(bytes: actual.data!, count: 1200 * 48)
    let differences = zip(expectedBytes, actualBytes).filter { $0 != $1 }.count
    require(differences == 0, "Prepared glyph drawing differs from CTLine for \(text): \(differences) bytes")
    for width in [1.0, 4.0, 8.0, 20.0, 60.0, 300.0] {
        let ref = context(); ref.clip(to: CGRect(x: -3, y: -20, width: width + 3, height: 48)); CTLineDraw(line(text), ref)
        let fast = context(); fast.clip(to: CGRect(x: -3, y: -20, width: width + 3, height: 48)); prepared.draw(in: fast, maxWidth: width)
        require(Data(bytes: ref.data!, count: 1200 * 48) == Data(bytes: fast.data!, count: 1200 * 48), "Glyph culling changed pixels for \(text), width \(width)")
    }
    for name in ["prepare", "cached-glyph-draw", "cached-ctline-draw", "clipped-glyph-draw", "clipped-ctline-draw"] {
        let target = context(); let cachedLine = line(text)
        if name.hasPrefix("clipped") { target.clip(to: CGRect(x: -3, y: -20, width: 11, height: 48)) }
        var values: [Double] = []
        for _ in 0..<200 {
            let start = DispatchTime.now().uptimeNanoseconds
            switch name {
            case "prepare": _ = PreparedText(text, style: style)
            case "cached-glyph-draw": prepared.draw(in: target)
            case "clipped-glyph-draw": prepared.draw(in: target, maxWidth: 8)
            default: CTLineDraw(cachedLine, target)
            }
            values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let sorted = values.sorted()
        reports.append(["text": text, "operation": name, "samplesMS": values, "p50MS": sorted[99],
                        "p95MS": sorted[189], "p99MS": sorted[197], "maxMS": sorted.last!])
    }
}
try JSONSerialization.data(withJSONObject: ["scope": "CoreText bitmap equivalence and component costs; not UI acceptance", "pixelEquivalenceCases": 28, "results": reports], options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
print("PASS: 28 pixel-exact prepared-text/clipping comparisons (Latin, CJK, Arabic, emoji)")
