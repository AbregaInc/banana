import SwiftUI

/// Custom event drawing on the host surface for blocks that cannot fit the image cache.
/// This uses the same Core Text renderer as prepared images, with no ImageRenderer or
/// CalendarEventArtwork fallback. Parent cells retain accessibility and all interaction.
struct CalendarNativeEventCanvas: View {
    let request: CalendarNativeEventRaster.Request

    static func required(size: CGSize, scale: CGFloat, maximumImageBytes: Int) -> Bool {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return false }
        let pixels = ceil(size.width * scale) * ceil(size.height * scale)
        guard pixels.isFinite else { return false }
        return pixels > CGFloat(maximumImageBytes / 4)
    }

    var body: some View {
        Canvas { context, _ in
            context.withCGContext { CalendarNativeEventRaster.draw(request, in: $0) }
        }
    }
}
