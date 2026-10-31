import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading a meal photo: when it was taken, and a smaller copy to keep, sync and show the model.
/// ImageIO only, so it runs on every platform and in tests.
enum MealPhotoImage {
    /// The longest side kept. Plenty for the model to read a plate, small enough (~150–300 KB)
    /// to sync as one record.
    static let keptPixels = 1_280
    static let quality = 0.72

    struct Prepared: Sendable {
        var jpeg: Data
        var takenAt: Date?
        /// What the photo's depth measured (`MealPhotoDepth`). Read from the photo as it came: the
        /// copy kept is too small, and has no depth in it.
        var depth: PhotoDepth?
        /// It carried a depth map, measurable or not. A library photo's edited version without one
        /// is worth asking for its original (`MealPhotoLibraryReader`).
        var carriesDepth = false
    }

    /// When the photo was taken, from its own metadata: EXIF DateTimeOriginal with its offset when
    /// the camera recorded one, else in `timeZone` (the camera's clock is local time). Nil when
    /// the image doesn't say — a screenshot, an edited export.
    static func captureDate(from data: Data, timeZone: TimeZone = .current) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let stamp = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let stamp else { return nil }
        let offset = (exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifOffsetTime] as? String)
        return parse(stamp, offset: offset, timeZone: timeZone)
    }

    /// "2026:09:28 12:41:07" with an optional "+02:00".
    static func parse(_ stamp: String, offset: String?, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset, let zone = zone(offset) { formatter.timeZone = zone } else { formatter.timeZone = timeZone }
        return formatter.date(from: String(stamp.prefix(19)))
    }

    private static func zone(_ offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 6, let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let parts = trimmed.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let seconds = (h * 3_600 + m * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// The copy Banana keeps: upright, at most `keptPixels` on its longest side, JPEG — and what the
    /// original's depth measured, when it has some. `depthSource`: the camera that took it, which
    /// the file can't say (`PhotoDepth.Source`).
    static func prepare(_ data: Data, maxPixels: Int = keptPixels, depthSource: PhotoDepth.Source = .portrait) -> Prepared? {
        guard let image = downscaled(data, maxPixels: maxPixels), let jpeg = jpeg(image) else { return nil }
        let map = MealPhotoDepth.read(from: data, source: depthSource)
        return Prepared(jpeg: jpeg, takenAt: captureDate(from: data), depth: map.flatMap(MealPhotoDepth.measure),
                        carriesDepth: map != nil)
    }

    /// The image upright and no larger than `maxPixels` on its longest side.
    static func downscaled(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpeg(_ image: CGImage, quality: Double = quality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
