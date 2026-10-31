import Foundation
import CoreText

@main
struct TextMemoChecks {
    static func main() {
        let black = CGColor(gray: 0, alpha: 1)
        let title = PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black)
        let hours = PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 20, nil)!, color: black)
        func image(_ text: PreparedText) -> Data {
            let context = CGContext(data: nil, width: 512, height: 64, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 64))
            context.translateBy(x: 2, y: 24)
            text.draw(in: context)
            return context.makeImage()!.dataProvider!.data! as Data
        }
        let memo = RasterTextMemo(text: title, hours: hours, countLimit: 4, byteLimit: 16_384)
        var checks = 0
        for label in ["00:00", "顧客との打ち合わせ", "مراجعة المشروع", "Café with Renée", "Overflow after capacity"] {
            for isHour in [false, true] {
                let expected = image(PreparedText(label, style: isHour ? hours : title))
                for _ in 0..<3 {
                    precondition(image(memo.line(label, hours: isHour)) == expected, "Memo changed glyph pixels or font namespace")
                    precondition(memo.count <= 4 && memo.bytes <= 16_384, "Memo exceeded its bound")
                    checks += 1
                }
            }
        }
        precondition(memo.hits > 0 && memo.misses > memo.count, "Capacity fallback was not exercised")
        let tiny = RasterTextMemo(text: title, hours: hours, byteLimit: 1)
        for _ in 0..<3 {
            precondition(image(tiny.line("Uncached", hours: false)) == image(PreparedText("Uncached", style: title)))
            precondition(tiny.count == 0 && tiny.bytes == 0 && tiny.hits == 0)
            checks += 1
        }
        precondition(!memo.supports(text: hours, hours: title), "Changed styles must not reuse prepared labels")
        print("PASS: \(checks) bounded text-memo pixel checks, including font namespace and capacity misses")
    }
}
