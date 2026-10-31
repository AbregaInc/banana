import Foundation

/// The food and workout-plan kinds that sync item by item through `CloudControlsSync` today, as
/// `HealthFood.ControlSourceAdapter` carries them (docs/design/DATA-PLATFORM.md §5): ids are the
/// stores' own (`ControlKind` ids, unhashed), and each item travels as its Codable type.
enum FoodKinds {
    typealias Kind = HealthFood.ControlSourceAdapter.Kind

    /// Guided workout plans (`WellnessStore.workoutPlans`).
    static let workoutPlan = Kind.codable(WorkoutPlan.self, type: "health.workoutPlan", kind: .workoutPlan) { $0.createdAt }
    /// Guided workouts done (`WellnessStore.workoutCompletions`, 100 kept here; the space keeps all).
    static let workoutCompletion = Kind.codable(WorkoutCompletion.self, type: "health.workoutCompletion",
                                                kind: .workoutCompletion) { $0.endedAt }
    /// A food's numbers as you corrected them, by its normalised name (`WellnessStore.foodCorrections`).
    static let correction = Kind.codable(FoodCorrection.self, type: "food.correction", kind: .foodCorrection)
    /// What you scanned (`MyFoodsStore`).
    static let myFood = Kind.codable(MyFood.self, type: "food.myFood", kind: .myFood) { food in
        ([food.addedAt] + food.bought).max()
    }
    /// The meal backlog (`MealInboxStore`). Found in the library it's offered (clock 0).
    static let mealInbox = Kind.codable(MealInboxItem.self, type: "food.mealInbox", kind: .mealInbox) { item in
        [item.createdAt, item.readiedAt].compactMap { $0 }.max()
    }
    /// Library photos already made into meals, by cloud key: `{takenAt}` (`MealPhotoLedger`).
    /// `default`-seeded, one record per key; offered, never deleted.
    static let mealPhotoFound = Kind(
        type: "food.mealPhotoFound", kind: .mealPhotoFound,
        item: { data in (try? JSONDecoder().decode(Date.self, from: data)).map { (Found(takenAt: $0), nil) } },
        data: { fields in HealthFood.decode(Found.self, fields).flatMap { try? JSONEncoder().encode($0.takenAt) } })

    struct Found: Codable, Sendable { var takenAt: Date }

    static let wellnessControls = [workoutPlan, workoutCompletion, correction]
}

/// Meal photos (`food.mealPhoto`): `whole`, the small JPEG as the blob `v` (§5), fetched eagerly.
/// The record names the photo's bytes; the file arrives as its blob, so taking the record waits
/// for nothing and the store gets the file when it comes (`storeBlob`).
@MainActor
final class MealPhotoAdapter: RecordAdapter {
    static let type = "food.mealPhoto"

    let photos: MealPhotoStore
    private let editedAt: (ControlKind, String) -> Date?
    private let hashes: HealthFood.BlobHashes

    init(photos: MealPhotoStore, editedAt: @escaping (ControlKind, String) -> Date? = { _, _ in nil },
         hashes: HealthFood.BlobHashes = .shared) {
        self.photos = photos
        self.editedAt = editedAt
        self.hashes = hashes
    }

    var types: [String] { [Self.type] }

    private func item(_ id: String) -> (any Encodable & Sendable)? {
        guard let uuid = UUID(uuidString: id), photos.has(uuid) else { return nil }
        return HealthFood.Whole(v: HealthFood.FileBlob(url: photos.url(uuid), ext: "jpg", hashes: hashes))
    }

    func snapshot(_ type: String) -> [String: any Encodable & Sendable] {
        guard type == Self.type else { return [:] }
        var items: [String: any Encodable & Sendable] = [:]
        for id in photos.cloudItemIDs(.mealPhoto) { if let item = item(id) { items[id] = item } }
        return items
    }

    func items(_ type: String, ids: Set<String>) -> [String: any Encodable & Sendable] {
        guard type == Self.type else { return [:] }
        var items: [String: any Encodable & Sendable] = [:]
        for id in ids { if let item = item(id) { items[id] = item } }
        return items
    }

    func seedClock(_ type: String, id: String) -> Date? {
        if let edited = HealthFood.ownTime(editedAt(.mealPhoto, id)) { return edited }
        guard let uuid = UUID(uuidString: id) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: photos.url(uuid).path))?[.modificationDate] as? Date
    }

    /// The bytes come as the blob: nothing to wait for.
    func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
        Dictionary(records.map { ($0.id, true) }, uniquingKeysWith: { first, _ in first })
    }

    /// The store's own path for another device's delete: the file goes, nothing is reported.
    func remove(_ type: String, ids: [String]) {
        for id in ids { photos.applyCloud(.mealPhoto, id: id, item: nil) }
    }

    func blobFile(_ type: String, id: String, field: String) -> URL? {
        guard field == "v", let uuid = UUID(uuidString: id), photos.has(uuid) else { return nil }
        return photos.url(uuid)
    }

    func storeBlob(_ type: String, id: String, field: String, file: URL) {
        guard field == "v", let data = try? Data(contentsOf: file) else { return }
        photos.applyCloud(.mealPhoto, id: id, item: data)
    }
}
