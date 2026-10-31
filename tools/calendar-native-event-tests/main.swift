import Foundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
require(!FileManager.default.fileExists(atPath: output.path), "Preserve existing evidence; choose a new output directory")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let font = CTFontCreateUIFontForLanguage(.system, 11, nil)!
let blue = CGColor(srgbRed: 0.1, green: 0.35, blue: 0.85, alpha: 1)
let red = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)
func text(_ string: String, lines: Int = 1) -> CalendarNativeEventRaster.Text {
    .init(value: NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): blue]), maximumLines: lines)
}
func request(width: CGFloat, height: CGFloat, desktop: Bool, rtl: Bool, state: Int) -> CalendarNativeEventRaster.Request {
    .init(size: CGSize(width: width, height: height), scale: 2, tint: blue,
        ribbons: [blue, red], fillOpacity: state == 1 || state == 3 ? 0.08 : 0.2,
        opacity: state == 4 ? 0.55 : 1,
        title: text(rtl ? "مرحبا بالعالم — 東京" : "Planning 👩‍💻 — 東京 with a longer title", lines: height >= 76 ? 3 : (height >= 40 ? 2 : 1)),
        subtitle: height >= 40 ? text("10:30–11:30 AM") : nil,
        location: height >= 64 ? text("Meeting room — étage 2") : nil,
        icon: nil, warning: nil, desktop: desktop, rightToLeft: rtl,
        free: state == 1, tentative: state == 2, needsAction: state == 3,
        textVisible: height >= 9, centerSingleLine: desktop && height < 34,
        strikeThrough: state == 4)
}
func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
func save(_ image: CGImage, _ name: String) {
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name).appendingPathExtension("png") as CFURL,
        UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    require(CGImageDestinationFinalize(destination), "PNG export failed")
}
var cases = 0
var samples: [Double] = []
for desktop in [false, true] {
    for rtl in [false, true] {
        for width: CGFloat in [28, 90, 180] {
            for height: CGFloat in [8, 16, 34, 40, 64, 100] {
                for state in 0...4 {
                    let input = request(width: width, height: height, desktop: desktop, rtl: rtl, state: state)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let image = try CalendarNativeEventRaster.render(input)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    require(image.width == Int(width * 2) && image.height == Int(height * 2), "Wrong pixel dimensions")
                    require(bytes(image) == bytes(try CalendarNativeEventRaster.render(input)), "Nonrepeatable event raster")
                    require(bytes(image).contains(where: { $0 != 0 }), "Event became blank")
                    if width == 180 && height == 100 {
                        save(image, "event-\(desktop ? "desktop" : "mobile")-\(rtl ? "rtl" : "ltr")-state\(state)")
                    }
                    cases += 1
                }
            }
        }
    }
}
// Semantic states must produce distinct pixels on an otherwise identical event.
let states = try (0...4).map { state in
    bytes(try CalendarNativeEventRaster.render(request(width: 180, height: 100, desktop: false, rtl: false, state: state)))
}
require(Set(states).count == 5, "An event state lost its visible treatment")
for size in [CGFloat.nan, .infinity, -1, 0, 1e12] {
    do {
        _ = try CalendarNativeEventRaster.render(request(width: size, height: 100, desktop: false, rtl: false, state: 0))
        fatalError("Invalid or excessive allocation accepted")
    } catch { cases += 1 }
}
let report: [String: Any] = ["correctnessCases": cases + 1, "coldRenderSamplesMS": samples,
    "scope": "Standalone production adapter candidate. Deterministic states/dimensions/allocation bounds; no SwiftUI parity or app/device acceptance."]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("results.json"))
print("PASS: \(cases + 1) event raster cases; \(samples.count) cold component samples")
