#if !BANANA_PUBLIC
import Foundation
import ImageIO

/// What a picture block may load from: a part of its own message. Remote pictures go through
/// `MailImageSource` only.
struct MailPictureContext: Sendable {
    var account: String = ""
    var part: @Sendable (String) async -> Data? = { _ in nil }
}

/// Decodes pictures off the main thread, at the size they are shown, and keeps a bounded number of them.
/// Two decodes at a time; about 24 MB of pixels in the cache.
actor MailPictureLoader {
    static let shared = MailPictureLoader()
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func image(key: String, maxPixel: Int, data: @Sendable () async -> Data?) async -> CGImage? {
        let cacheKey = "\(key)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        await acquire()
        defer { release() }
        guard let bytes = await data() else { return nil }
        let image = await Task.detached(priority: .utility) { Self.decode(bytes, maxPixel: maxPixel) }.value
        if let image { cache.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height) }
        return image
    }

    private func acquire() async {
        if running < 2 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    /// A thumbnail no larger than `maxPixel` on its long side: never the full-size bitmap.
    nonisolated static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

#endif
