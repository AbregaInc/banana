import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Isolated design/cost experiment. Does not change the app's artwork or inference rules.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: output.path), "Preserve previous results")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let scale: CGFloat = 2
let symbols = ["dumbbell.fill", "phone.fill", "video.fill"]
let names = ["Strength workout", "Call with Sam", "Zoom planning"]
let colors = [NSColor.systemPurple, .systemGreen, .systemBlue]
func context(_ size: CGSize) -> CGContext {
    let c = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: scale, y: scale)
    c.translateBy(x: 0, y: size.height); c.scaleBy(x: 1, y: -1)
    return c
}
func tile(_ name: String) -> CGImage {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!
    let glyph = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let c = context(CGSize(width: 22, height: 26))
    // One fixed-size tile; never shrink the symbol to fit a dense event.
    let ratio = CGFloat(glyph.height) / CGFloat(glyph.width)
    let width = min(13, 12 / ratio), height = width * ratio
    c.translateBy(x: (22 - width) / 2, y: (26 + height) / 2); c.scaleBy(x: 1, y: -1)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    c.clip(to: rect, mask: glyph)
    c.setFillColor(colors[symbols.firstIndex(of: name)!].cgColor); c.fill(rect)
    return c.makeImage()!
}
func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = try body()
    return (result, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
}
func save(_ image: CGImage, _ name: String) {
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + ".png") as CFURL,
        UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
func request(width: CGFloat, kind: Int, dark: Bool) -> CalendarNativeEventRaster.Request {
    let tint = colors[kind].cgColor
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.system, 11, nil)!,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): (dark ? NSColor.white : .black).cgColor]
    return .init(size: CGSize(width: width, height: 130), scale: scale, tint: tint, ribbons: [tint],
        fillOpacity: 0.2, opacity: 1,
        title: .init(value: NSAttributedString(string: names[kind], attributes: attrs), maximumLines: 3),
        subtitle: nil, location: nil, icon: nil, warning: nil, desktop: false, rightToLeft: false,
        free: false, tentative: false, needsAction: false, textVisible: true, centerSingleLine: false,
        strikeThrough: false)
}
func render(_ original: CalendarNativeEventRaster.Request, mode: Int, tile: CGImage) -> CGImage {
    // 0: current text, 1: plain no-text control, 2: pattern only, 3: pattern with text.
    var r = original
    r = .init(size: r.size, scale: r.scale, tint: r.tint, ribbons: r.ribbons,
        fillOpacity: r.fillOpacity, opacity: r.opacity, title: r.title, subtitle: r.subtitle,
        location: r.location, icon: r.icon, warning: r.warning, desktop: r.desktop,
        rightToLeft: r.rightToLeft, free: r.free, tentative: r.tentative, needsAction: r.needsAction,
        textVisible: mode == 0 || mode == 3, centerSingleLine: r.centerSingleLine, strikeThrough: r.strikeThrough)
    let c = context(r.size)
    CalendarNativeEventRaster.draw(r, in: c)
    if mode >= 2 {
        c.saveGState()
        // Preserve calendar spine. Leave a quiet title zone when text is present.
        let top: CGFloat = mode == 3 ? 48 : 0
        c.clip(to: CGRect(x: 5, y: top, width: max(0, r.size.width - 5), height: r.size.height - top))
        c.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: 5,
                         cornerHeight: 5, transform: nil)); c.clip()
        // Reuse the pre-tinted tile; measure the extra fill separately from removing text.
        c.setAlpha(0.48)
        c.translateBy(x: 5 + (r.size.width < 27 ? (r.size.width - 27) / 2 : 0), y: top)
        c.translateBy(x: 0, y: 26); c.scaleBy(x: 1, y: -1)
        c.draw(tile, in: CGRect(x: 0, y: 0, width: 22, height: 26), byTiling: true)
        c.restoreGState()
    }
    return c.makeImage()!
}
var cold: [Double] = []
let tiles = symbols.map { name -> CGImage in
    let (image, ms) = time { tile(name) }; cold.append(ms); return image
}
var rows: [[String: Any]] = []
let widths: [CGFloat] = [16, 24, 40, 80, 180]
for dark in [false, true] {
    let preview = context(CGSize(width: 1200, height: 660))
    preview.setFillColor((dark ? NSColor.black : .white).cgColor)
    preview.fill(CGRect(x: 0, y: 0, width: 1200, height: 660))
    for (column, label) in ["Current text", "Pattern only", "Pattern + quiet title area"].enumerated() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.system, 16, nil)!,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): (dark ? NSColor.white : .black).cgColor]))
        preview.saveGState(); preview.translateBy(x: CGFloat(column) * 400 + 12, y: 26)
        preview.scaleBy(x: 1, y: -1); preview.textPosition = .zero
        CTLineDraw(line, preview); preview.restoreGState()
    }
    for kind in 0..<3 {
        for (index, width) in widths.enumerated() {
            let r = request(width: width, kind: kind, dark: dark)
            var samplesByMode = Array(repeating: [Double](), count: 4)
            for round in 0..<24 {
                for step in 0..<4 {
                    let selected = (round + step) % 4
                    let (_, ms) = time { render(r, mode: selected, tile: tiles[kind]) }
                    samplesByMode[selected].append(ms)
                }
            }
            for mode in 0..<4 {
                let samples = samplesByMode[mode]
                let image = render(r, mode: mode, tile: tiles[kind])
                let (again, evictionMS) = time { render(r, mode: mode, tile: tile(symbols[kind])) }
                precondition((image.dataProvider!.data! as Data) == (again.dataProvider!.data! as Data),
                             "Eviction must preserve pixels")
                rows.append(["dark": dark, "kind": symbols[kind], "width": width, "mode": mode,
                             "samplesMS": samples, "evictionMS": evictionMS, "imageBytes": image.bytesPerRow * image.height])
                // Preview columns: current, pattern only, pattern + title. Plain control is timing-only.
                if mode != 1 {
                    let column = mode == 0 ? 0 : mode - 1
                    let x = CGFloat(column) * 400 + 12 + widths.prefix(index).reduce(0,+) + CGFloat(index) * 9
                    let y = CGFloat(kind) * 210 + 48
                    preview.saveGState(); preview.translateBy(x: x, y: y + 130); preview.scaleBy(x: 1, y: -1)
                    preview.draw(image, in: CGRect(x: 0, y: 0, width: width, height: 130)); preview.restoreGState()
                }
            }
        }
    }
    save(preview.makeImage()!, dark ? "dark" : "light")
}
let result: [String: Any] = ["scope": "Isolated native-raster design/cost ablation; no app, frame or input acceptance",
    "modes": ["current-text", "plain-no-text", "pattern-only", "pattern-and-text"],
    "tileColdMS": cold, "tileBytes": tiles.reduce(0) { $0 + $1.bytesPerRow * $1.height }, "cases": rows]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("results.json"))
print("Pattern prototype: \(rows.count) cases, eviction pixel parity passed")
