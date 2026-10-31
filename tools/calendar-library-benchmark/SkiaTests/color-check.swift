// Standalone explanation/regression check for native color conversion; no timing claims.
import Foundation
import CoreGraphics

@main struct ColorCheck {
    static func main() throws {
        let target = CGColorSpaceCreateDeviceRGB()
        let colors = FixturePalette.fills + [CGColor(gray: 0.5, alpha: 1)]
        var rows: [[String: Any]] = []
        var failures = 0, unmanagedFailures = 0
        for (index, color) in colors.enumerated() {
            let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                bytesPerRow: 16, space: target, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let actual = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4)).map(Int.init)
            let converted = color.converted(to: target, intent: .defaultIntent, options: nil)!.components!
            let raw = color.components!
            let unmanaged = raw.count == 2 ? [raw[0], raw[0], raw[0], raw[1]] : raw
            func predicted(_ rgba: [CGFloat]) -> [Int] {
                (0..<3).map { Int((255 * (rgba[$0]*rgba[3] + 1-rgba[3])).rounded()) } + [255]
            }
            let correctDelta = zip(predicted(converted), actual).map { abs($0-$1) }.max()!
            let wrongDelta = zip(predicted(unmanaged), actual).map { abs($0-$1) }.max()!
            if correctDelta > 1 { failures += 1 }
            if wrongDelta > 1 { unmanagedFailures += 1 }
            rows.append(["index": index, "sourceComponents": raw, "convertedComponents": converted,
                "nativePixel": actual, "convertedMaxDifference": correctDelta, "unmanagedMaxDifference": wrongDelta])
        }
        let data = try JSONSerialization.data(withJSONObject: ["rows": rows, "failures": failures,
            "unmanagedFailures": unmanagedFailures, "scope": "Native color transform and opaque-background blend; not GPU edge/text parity"], options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        if failures != 0 || unmanagedFailures == 0 { exit(1) }
    }
}
