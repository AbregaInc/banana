import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit   // UIImage is NSImage here (PlatformShim)
#endif

/// A show's colour, taken from its artwork, for the player's background and the show name.
/// Evened out through `CalendarColor` so a neon cover and a pastel one both stay legible and
/// calm — the same band calendar colours are pulled into.
@MainActor
enum ArtworkTint {
    private static var cache: [URL: String] = [:]

    static func color(for url: URL?) async -> Color? {
        guard let url else { return nil }
        if let hex = cache[url] { return CalendarColor.color(hex: hex) }
        guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 64),
              let cg = cgImage(image), let hex = ImageAverage.hex(of: cg) else { return nil }
        cache[url] = hex
        return CalendarColor.color(hex: hex)
    }

    private static func cgImage(_ image: UIImage) -> CGImage? {
        #if os(iOS)
        image.cgImage
        #else
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}
