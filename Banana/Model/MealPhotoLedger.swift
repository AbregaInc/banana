import Combine
import Foundation

/// Library photos already made into meals, by cloud key (`MealPhotoIdentity`), on every device
/// (`ControlKind.mealPhotoFound`). A device scanning the same iCloud Photos library skips these,
/// so a meal found on the iPhone and logged — or dismissed — isn't found again by the Mac.
@MainActor
final class MealPhotoLedger: ObservableObject {
    static let shared = MealPhotoLedger()

    /// Cloud key → when the photo was taken.
    @Published private(set) var found: [String: Date] = [:]

    private let fileURL: URL

    init(fileURL: URL = AppSupport.directory.appendingPathComponent("meal-photo-found.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: Date].self, from: data) {
            found = stored
        }
    }

    func contains(_ key: String) -> Bool { found[key] != nil }

    /// Photos just made into meals here.
    func record(_ photos: [MealPhotoRef]) {
        var changed = false
        for photo in photos {
            guard let key = photo.cloudKey, found[key] == nil else { continue }
            found[key] = photo.takenAt ?? Date()
            // The same key from two devices says the same thing: an offer, never a conflict.
            ControlChangeReporter.offered(.mealPhotoFound, key)
            changed = true
        }
        if changed { save() }
    }

    /// Forgets, here only, photos from before any scan will look again. Another device may still
    /// be looking further back, so nothing is deleted from iCloud.
    func prune(before cutoff: Date) {
        let kept = found.filter { $0.value >= cutoff }
        guard kept.count != found.count else { return }
        found = kept
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(found) else { return }
        try? HealthFileProtection.write(data, to: fileURL)
    }
}

extension MealPhotoLedger: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        guard kind == .mealPhotoFound else { return [:] }
        var out: [String: Data] = [:]
        for (key, taken) in found { out[key] = try? JSONEncoder().encode(taken) }
        return out
    }

    func cloudItem(_ kind: ControlKind, id: String) -> Data? {
        guard kind == .mealPhotoFound else { return nil }
        return found[id].flatMap { try? JSONEncoder().encode($0) }
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        guard kind == .mealPhotoFound else { return true }
        if let item, let taken = try? JSONDecoder().decode(Date.self, from: item) {
            found[id] = taken
        } else {
            found[id] = nil
        }
        save()
        return true
    }
}

// Every photo another device found, in one save.
extension MealPhotoLedger: HealthFood.BatchSource {
    func applyCloudBatch(_ kind: ControlKind, _ items: [(id: String, item: Data?)]) -> [String: Bool] {
        guard kind == .mealPhotoFound, !items.isEmpty else { return Dictionary(items.map { ($0.id, true) }, uniquingKeysWith: { a, _ in a }) }
        var next = found
        for (id, item) in items {
            if let item, let taken = try? JSONDecoder().decode(Date.self, from: item) {
                next[id] = taken
            } else {
                next[id] = nil
            }
        }
        if next != found {
            found = next
            save()
        }
        return Dictionary(items.map { ($0.id, true) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Each device's scanning, for every device's setting to show (`MealPhotoScanReport`), in iCloud
/// key-value storage: install id → report. Small, and last-writer-wins per device is exactly right.
@MainActor
final class MealPhotoScanReports: ObservableObject {
    static let shared = MealPhotoScanReports()
    private static let key = "mealPhotoScan.reports"

    @Published private(set) var all: [String: MealPhotoScanReport] = [:]
    private let cloud = LegacyKVS.shared
    private var observer: NSObjectProtocol?

    private init() {
        read()
        observer = LegacyKVS.observeExternalChanges(tier: .health) { MealPhotoScanReports.shared.read() }
    }

    var mine: MealPhotoScanReport? { all[MealInboxStore.installID] }

    /// This device's report, or none (the setting is off).
    func publish(_ report: MealPhotoScanReport?) {
        var next = all
        next[MealInboxStore.installID] = report
        guard next != all else { return }
        let before = all[MealInboxStore.installID]
        all = next
        if let data = try? JSONEncoder().encode(next) { cloud.set(data, forKey: Self.key) }
        // A new version for the data platform on a real change; a pass that only moved its times
        // at most every ten minutes.
        let now = Date()
        if Self.differs(before, report) || reportedAt.map({ now.timeIntervalSince($0) >= 10 * 60 }) ?? true {
            reportedAt = now
            MoveOver.changed(type: Self.spaceType, ids: [MealInboxStore.installID])
        }
    }

    private var reportedAt: Date?

    /// Whether two reports differ in more than when they were made.
    private static func differs(_ a: MealPhotoScanReport?, _ b: MealPhotoScanReport?) -> Bool {
        guard var a, var b else { return (a == nil) != (b == nil) }
        a.checkedAt = nil; a.completedAt = nil
        b.checkedAt = nil; b.completedAt = nil
        return a != b
    }

    /// The data platform's record type: one per install, the report whole.
    static let spaceType = "food.photoScanReport"

    /// Other devices' reports from the data platform (nil: gone). Ours stays as this device wrote it.
    func adoptFromSpace(_ changes: [String: MealPhotoScanReport?]) {
        var next = all
        for (id, report) in changes where id != MealInboxStore.installID { next[id] = report }
        guard next != all else { return }
        all = next
        if let data = try? JSONEncoder().encode(next) { cloud.set(data, forKey: Self.key) }
    }

    private func read() {
        guard let data = cloud.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: MealPhotoScanReport].self, from: data) else { return }
        // Ours as this device last wrote it — the copy in iCloud may be older.
        var merged = decoded
        merged[MealInboxStore.installID] = all[MealInboxStore.installID] ?? decoded[MealInboxStore.installID]
        let arrived = merged.filter { $0.key != MealInboxStore.installID && all[$0.key] != $0.value }.map(\.key).sorted()
        if !arrived.isEmpty, LegacyCloud.isApplyingFromCloud { MoveOver.changed(type: Self.spaceType, ids: arrived) }
        if merged != all { all = merged }
    }
}
