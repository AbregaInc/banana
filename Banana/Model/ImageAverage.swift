import CoreGraphics
import Foundation

/// The average colour of an image, as "#RRGGBB" — what the player washes its background with,
/// so the screen takes on the show's colour. Drawn into a single pixel, which is the average.
enum ImageAverage {
    static func hex(of image: CGImage) -> String? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard pixel[3] > 0 else { return nil }   // fully transparent: no colour to take
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }
}
