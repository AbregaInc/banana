import SwiftUI
import AppKit

/// Independent diagnosis: no CalendarArtworkRasterCache is linked into this executable.
@main struct RepeatProbe {
    @MainActor static func main() throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: path.path) else { exit(2) }
        var environment = EnvironmentValues()
        environment.colorScheme = .light; environment.displayScale = 2
        environment.locale = Locale(identifier: "en_US")
        environment.timeZone = TimeZone(secondsFromGMT: 0)!
        environment.calendar = Calendar(identifier: .gregorian)
        var a = CalendarEventPaint(title: "Design review 👩🏽‍💻", start: Date(timeIntervalSince1970: 1791541800),
            startText: "9:10 AM", timeRange: "9:10–10:25 AM", icon: "calendar")
        var b = a; b.title = "A different meeting"
        func render(_ paint: CalendarEventPaint) -> CGImage {
            let renderer = ImageRenderer(content: CalendarEventArtwork(paint: paint, height: 64,
                layout: .mobile).frame(width: 160, height: 64).environment(\.self, environment))
            renderer.scale = 2
            if CommandLine.arguments.contains("--context") {
                var result: CGImage?
                renderer.render(rasterizationScale: 2) { size, draw in
                    let context = CGContext(data: nil, width: Int(ceil(size.width * 2)),
                        height: Int(ceil(size.height * 2)), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.scaleBy(x: 2, y: 2)
                    draw(context)
                    result = context.makeImage()
                }
                return result!
            }
            return renderer.cgImage!
        }
        func bytes(_ image: CGImage) -> Data {
            let source = image.dataProvider!.data! as Data
            let active = image.width * image.bitsPerPixel / 8
            var result = Data(); result.reserveCapacity(active * image.height)
            for row in 0..<image.height {
                result.append(source[(row * image.bytesPerRow)..<(row * image.bytesPerRow + active)])
            }
            return result
        }
        let first = render(a), expected = bytes(first)
        var rows: [[String: Any]] = []
        for trial in 0..<60 {
            a.tint = trial.isMultiple(of: 2) ? .blue : .purple
            _ = render(b)
            // Restore the exact original paint before the comparison.
            a.tint = .blue
            let actualImage = render(a), actual = bytes(actualImage)
            var differences = 0, maximum = 0
            var channels = [0, 0, 0, 0]
            for i in expected.indices where expected[i] != actual[i] {
                differences += 1; channels[i % 4] += 1
                maximum = max(maximum, abs(Int(expected[i]) - Int(actual[i])))
            }
            rows.append(["trial": trial, "differentBytes": differences, "maximumDelta": maximum,
                         "channels": channels, "sameSourceReadStable": expected == bytes(first)])
        }
        let result: [String: Any] = ["backend": CommandLine.arguments.contains("--context") ? "context" : "cgImage",
            "cacheLinked": false, "bitsPerComponent": first.bitsPerComponent,
            "bitsPerPixel": first.bitsPerPixel, "samples": rows,
            "mismatches": rows.filter { ($0["differentBytes"] as! Int) != 0 }.count]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: path)
        try NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:])!
            .write(to: path.deletingPathExtension().appendingPathExtension("png"))
        print("Independent ImageRenderer repeat mismatches: \(result["mismatches"]!)/60")
    }
}
