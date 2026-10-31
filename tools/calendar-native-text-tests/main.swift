import Foundation
import CoreText

func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
let font = CTFontCreateUIFontForLanguage(.system, 11, nil)!
let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
]
func attributed(_ value: String) -> NSAttributedString {
    NSAttributedString(string: value, attributes: attributes)
}
func bitmap(_ layout: CalendarNativeText, width: CGFloat = 180) -> Data {
    let context = CGContext(data: nil, width: 360, height: 160, bitsPerComponent: 8,
        bytesPerRow: 1440, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: 160); context.scaleBy(x: 2, y: -2)
    layout.draw(in: context, rect: CGRect(x: 0, y: 0, width: width, height: 80))
    return Data(bytes: context.data!, count: 1440 * 160)
}
var cases = 0
let texts = ["Planning", "Réunion – 東京", "مرحبا بالعالم", "Meet 👩‍💻 👨‍👩‍👧‍👦", "e\u{301}cole", "a\nb", "a\r\nb", "a\u{2028}b",
             String(repeating: "A long appointment title with words ", count: 12)]
for text in texts {
    for width: CGFloat in [1, 28, 90, 180] {
        for limit in [1, 2, 3] {
            let value = attributed(text)
            let layout = CalendarNativeText(value, width: width, maximumLines: limit)
            require(layout.lines.count <= limit, "Line budget violated")
            require(layout.height.isFinite && layout.height >= 0, "Invalid height")
            require(zip(layout.lines, layout.lines.dropFirst()).allSatisfy { $0.baseline < $1.baseline }, "Overlapping baselines")
            let first = bitmap(layout, width: width)
            require(first == bitmap(CalendarNativeText(value, width: width, maximumLines: limit), width: width), "Nonrepeatable layout")
            // Each scanline is bounded by the content width, including emoji/ellipsis overhang.
            let boundary = Int(ceil(width * 2))
            require(first.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                return (0..<160).allSatisfy { y in (boundary..<360).allSatisfy { x in p[y * 1440 + x * 4 + 3] == 0 } }
            }, "Text leaked into adjacent event column")
            cases += 1
        }
    }
}
for separator in ["\n", "\r\n", "\u{2028}"] {
    let truncated = CalendarNativeText(attributed("a" + separator + "b"), width: 180, maximumLines: 1)
    require(truncated.truncated, "Hidden second line lacks truncation state")
    require(bitmap(truncated) == bitmap(CalendarNativeText(attributed("a…"), width: 180, maximumLines: 1)), "Hard-break truncation lost ellipsis")
    let complete = CalendarNativeText(attributed("a" + separator + "b"), width: 180, maximumLines: 2)
    require(complete.lines.count == 2 && !complete.truncated, "Hard breaks not preserved")
    cases += 2
}
for width in [CGFloat.zero, -.infinity, .infinity, .nan] {
    require(CalendarNativeText(attributed("Test"), width: width, maximumLines: 2).lines.isEmpty, "Invalid width accepted")
    cases += 1
}
require(CalendarNativeText(attributed(""), width: 90, maximumLines: 2).height == 0, "Empty title has height")
// Controlled ablation: identical text, width, bitmap and draw; only layout reuse differs.
let value = attributed(String(repeating: "Meet 👩‍💻 – 東京 tomorrow ", count: 4))
let cached = CalendarNativeText(value, width: 90, maximumLines: 3)
var samples: [String: [Double]] = ["rebuild": [], "reuse": []]
for iteration in 0..<200 {
    for mode in iteration.isMultiple(of: 2) ? ["rebuild", "reuse"] : ["reuse", "rebuild"] {
        let start = DispatchTime.now().uptimeNanoseconds
        let pixels = bitmap(mode == "reuse" ? cached : CalendarNativeText(value, width: 90, maximumLines: 3), width: 90)
        samples[mode]!.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        require(pixels == bitmap(cached, width: 90), "Ablation changed pixels")
    }
}
let report: [String: Any] = ["correctnessCases": cases + 1, "samplesMS": samples,
    "scope": "Worker-local text layout, clipping and reuse ablation. Not app integration, SwiftUI parity, frame or input acceptance."]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("PASS: \(cases + 1) native text cases; 400 ablation samples retained")
