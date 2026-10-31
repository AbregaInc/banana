import Foundation
#if os(iOS)
import UIKit
#else
import AppKit   // UIImage is typealiased to NSImage in PlatformShim
#endif
import ImageIO
import CryptoKit

/// Two-tier artwork cache: an in-memory `NSCache` (byte-cost-limited) backed by a
/// persistent disk cache. Images are **downsampled** to display size on load —
/// podcast artwork is frequently 1400–3000px, which would decode to tens of MB
/// each and blow up memory over a long session. Downsampling + a cost limit keep
/// the working set small; each URL is still fetched from the network at most once.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// Max pixel dimension we ever keep in memory. Covers the largest on-screen
    /// artwork (~280pt @3x ≈ 840px) with headroom.
    private let maximumPixel: CGFloat = 1000

    /// Memory keeps size variants; disk deliberately does not. A 52 pt list thumbnail should not
    /// occupy the same ~4 MB decoded buffer as 280 pt Now Playing art, but storing resized copies
    /// on disk would multiply cache bytes and writes. Every variant decodes from the one original.
    private struct Variant: Hashable {
        var url: URL
        var maxPixel: Int
    }

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private let inFlightLock = NSLock()
    private struct InFlight {
        var id: UUID
        var task: Task<UIImage?, Never>
    }
    private var inFlight: [Variant: InFlight] = [:]
    private struct DataInFlight {
        var id: UUID
        var task: Task<Data?, Never>
    }
    private var dataInFlight: [URL: DataInFlight] = [:]

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 120
        memory.totalCostLimit = 40 * 1024 * 1024   // ~40 MB of decoded pixels
        sweepStale()
    }

    /// Age out disk entries untouched for 60 days. Caches/ is system-purgeable under pressure,
    /// but "the system might clean it someday" is not an eviction policy — artwork for long-gone
    /// feeds otherwise sits there indefinitely.
    private func sweepStale() {
        let dir = directory
        Task.detached(priority: .utility) {
            let cutoff = Date().addingTimeInterval(-60 * 24 * 3600)
            let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys) else { return }
            for file in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                let touched = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
                if touched < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    /// Synchronous memory-only lookup — lets a view show a cached image instantly.
    func memoryImage(for url: URL, targetPixelSize: CGFloat? = nil) -> UIImage? {
        memory.object(forKey: memoryKey(for: variant(
            for: url,
            targetPixelSize: targetPixelSize)))
    }

    /// Drop the in-memory images (disk cache is kept). Call on a memory warning.
    func clearMemory() {
        memory.removeAllObjects()
    }

    /// Full lookup: memory → disk → network. Downsamples and populates both caches.
    func image(for url: URL, targetPixelSize: CGFloat? = nil) async -> UIImage? {
        let variant = variant(for: url, targetPixelSize: targetPixelSize)
        let key = memoryKey(for: variant)
        if let hit = memory.object(forKey: key) { return hit }
        let shared = sharedTask(for: variant)
        let result = await shared.task.value
        removeSharedTask(for: variant, id: shared.id)
        return result
    }

    /// Keep lock operations in synchronous helpers. Swift 6 deliberately disallows holding an
    /// NSLock directly across an `await`; the returned task is the only value that crosses it.
    private func sharedTask(for variant: Variant) -> InFlight {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        if let existing = inFlight[variant] { return existing }
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.loadImage(for: variant)
        }
        let entry = InFlight(id: id, task: task)
        inFlight[variant] = entry
        return entry
    }

    private func removeSharedTask(for variant: Variant, id: UUID) {
        inFlightLock.lock()
        // Several views can await the same task. A late waiter from the old generation must not
        // erase a new request that started after the old task completed.
        if inFlight[variant]?.id == id { inFlight[variant] = nil }
        inFlightLock.unlock()
    }

    private func loadImage(for variant: Variant) async -> UIImage? {
        let key = memoryKey(for: variant)
        if let hit = memory.object(forKey: key) { return hit }
        guard let data = await originalData(for: variant.url),
              let image = downsample(data, maxPixel: CGFloat(variant.maxPixel))
        else { return nil }
        store(image, for: variant)
        return image
    }

    /// Size variants share this original-byte flight. Without the URL-level flight, a list row
    /// asking for 256 px at the same moment Now Playing asks for 1000 px could issue two network
    /// requests before either one populated the single original disk entry.
    private func originalData(for url: URL) async -> Data? {
        let fileURL = diskURL(for: url)
        if let data = try? Data(contentsOf: fileURL) { return data }

        let shared: DataInFlight = {
            inFlightLock.lock()
            defer { inFlightLock.unlock() }
            if let existing = dataInFlight[url] { return existing }
            let id = UUID()
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> Data? in
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)
                        .map({ (200..<300).contains($0.statusCode) }) ?? true
                else { return nil }
                if let self {
                    try? data.write(to: self.diskURL(for: url), options: .atomic)
                }
                return data
            }
            let created = DataInFlight(id: id, task: task)
            dataInFlight[url] = created
            return created
        }()
        let data = await shared.task.value
        removeSharedDataTask(for: url, id: shared.id)
        return data
    }

    private func removeSharedDataTask(for url: URL, id: UUID) {
        inFlightLock.lock()
        if dataInFlight[url]?.id == id { dataInFlight[url] = nil }
        inFlightLock.unlock()
    }

    private func store(_ image: UIImage, for variant: Variant) {
        // `scale` is a UIKit notion (points vs pixels on a Retina phone). NSImage carries its size
        // in points and does the backing-scale arithmetic itself, so the cost estimate is simply
        // the area.
        #if os(iOS)
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        #else
        let pixels = image.size.width * image.size.height
        #endif
        memory.setObject(image, forKey: memoryKey(for: variant), cost: Int(pixels * 4))
    }

    /// Efficient downsample via ImageIO — creates a thumbnail without ever
    /// decoding the full-resolution image into memory.
    private func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: .zero)   // .zero = use the image's own pixel size
        #endif
    }

    private func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private func variant(for url: URL, targetPixelSize: CGFloat?) -> Variant {
        let requestedPixels = targetPixelSize ?? maximumPixel
        // A few buckets maximize cross-view reuse without turning one URL into an unbounded set
        // of decoded sizes. The largest bucket still covers 280 pt Now Playing art at 3x.
        let bucket = [128, 256, 512, Int(maximumPixel)]
            .first(where: { CGFloat($0) >= requestedPixels })
            ?? Int(maximumPixel)
        return Variant(url: url, maxPixel: bucket)
    }

    private func memoryKey(for variant: Variant) -> NSString {
        "\(variant.url.absoluteString)|\(variant.maxPixel)" as NSString
    }

    #if DEBUG
    /// Seed the disk cache with bundled bytes, keyed to `url`, so screenshot routes render real
    /// artwork without touching the network. The URL never resolves; on a seeding failure views
    /// fall back to the placeholder instead of fetching.
    func injectPreviewOriginal(_ data: Data, for url: URL) {
        try? data.write(to: diskURL(for: url), options: .atomic)
    }
    #endif

    #if PERFORMANCE_TESTING && os(iOS)
    /// Device-only decode primitive used by the deterministic artwork benchmark. It deliberately
    /// bypasses memory/disk caches so each iteration models a newly encountered show image.
    func performanceDecode(data: Data, maxPixel: CGFloat, count: Int) -> Int {
        var decodedPixelCount = 0
        for _ in 0..<count {
            autoreleasepool {
                guard let image = downsample(data, maxPixel: maxPixel),
                      let cgImage = image.cgImage else { return }
                decodedPixelCount += cgImage.width * cgImage.height
            }
        }
        return decodedPixelCount
    }
    #endif
}
