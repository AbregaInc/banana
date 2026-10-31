import Combine
import Foundation
import ImageIO

/// Meal photos, as the small JPEGs `MealPhotoImage.prepare` makes: one file each under
/// Application Support/MealPhotos, synced to every device as one record each (`ControlKind.mealPhoto`)
/// so a photo found on the iPhone can be answered, reviewed and seen on the iPad and Mac.
@MainActor
final class MealPhotoStore: ObservableObject {
    static let shared = MealPhotoStore()

    /// Bumped when a photo arrives or goes, so thumbnails waiting on one redraw.
    @Published private(set) var version = 0

    let directory: URL
    private let thumbnails = NSCache<NSString, CGImage>()

    init(directory: URL = AppSupport.directory.appendingPathComponent("MealPhotos", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        HealthFileProtection.protectExisting(directory)
    }

    func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".jpg") }

    func has(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    func data(_ id: UUID) -> Data? { try? Data(contentsOf: url(id)) }

    /// The photo at full kept size, for the model.
    func image(_ id: UUID) -> CGImage? {
        guard let data = data(id) else { return nil }
        return MealPhotoImage.downscaled(data, maxPixels: MealPhotoImage.keptPixels)
    }

    /// A small copy for a row. Cached.
    func thumbnail(_ id: UUID, maxPixels: Int = 240) -> CGImage? {
        let key = "\(id.uuidString)-\(maxPixels)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let data = data(id), let image = MealPhotoImage.downscaled(data, maxPixels: maxPixels) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    /// Keeps a prepared photo and sends it to the other devices. `offer`: found here in the library,
    /// perhaps already sent by another device under the same id (`ControlChangeReporter.offered`).
    func save(_ jpeg: Data, id: UUID, offer: Bool = false) {
        write(jpeg, id: id)
        if offer {
            ControlChangeReporter.offered(.mealPhoto, id.uuidString)
        } else {
            ControlChangeReporter.changed(.mealPhoto, id.uuidString)
        }
    }

    func delete(_ id: UUID) {
        remove(id)
        ControlChangeReporter.deleted(.mealPhoto, id.uuidString)
    }

    /// Removes this device's copies of photos no backlog meal or logged meal refers to any more,
    /// older than a day (a photo can arrive from another device before the meal that holds it
    /// does). Here only, never from iCloud: another device may know a meal this one hasn't
    /// received yet, and a deletion from here would take its photo from everywhere.
    func pruneOrphans(keeping referenced: Set<UUID>, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jpg" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > 86_400 { remove(id) }
        }
    }

    private var storedIDs: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }
    }

    private func write(_ jpeg: Data, id: UUID) {
        try? HealthFileProtection.write(jpeg, to: url(id))
        version += 1
    }

    private func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        for size in [120, 240, 480] { thumbnails.removeObject(forKey: "\(id.uuidString)-\(size)" as NSString) }
        version += 1
    }
}

extension MealPhotoStore: CloudControlSource {
    func cloudItemIDs(_ kind: ControlKind) -> [String] {
        kind == .mealPhoto ? storedIDs : []
    }

    func cloudItem(_ kind: ControlKind, id: String) -> Data? {
        guard kind == .mealPhoto, let uuid = UUID(uuidString: id) else { return nil }
        return data(uuid)
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        guard kind == .mealPhoto, let uuid = UUID(uuidString: id) else { return true }
        if let item { write(item, id: uuid) } else { remove(uuid) }
        return true
    }
}
