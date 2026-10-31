import Foundation

/// How meals, supplements and doses are named in the Wellness CloudKit zone, and how a batch of
/// changes from another device is folded into the local lists. Pure, so the rules that decide
/// what a phone↔Mac sync keeps or drops are tested without CloudKit (`CloudWellnessSync` is the
/// transport).
///
/// A dose is one record per supplement per day — `logSupplement` replaces that day's entry
/// rather than adding one, so naming the record by the day makes a change of mind ("taken" →
/// "skipped") overwrite the same record on every device instead of piling up stale logs whose
/// ids differ from device to device. The day is the one stored on the log when it was taken
/// (`SupplementLog.day`), never recomputed from wherever the device is now.
enum WellnessCloudRecord: Equatable {
    case meal(UUID)
    case supplement(UUID)
    case dose(supplementID: UUID, day: String)

    static let mealPrefix = "meal-"
    static let supplementPrefix = "supplement-"
    static let dosePrefix = "dose-"

    var name: String {
        switch self {
        case .meal(let id): Self.mealPrefix + id.uuidString
        case .supplement(let id): Self.supplementPrefix + id.uuidString
        case .dose(let id, let day): "\(Self.dosePrefix)\(id.uuidString)-\(day)"
        }
    }

    static func dose(_ log: SupplementLog, calendar: Calendar = .current) -> WellnessCloudRecord {
        let key = doseKey(log, calendar: calendar)
        return .dose(supplementID: key.supplementID, day: key.day)
    }

    /// The log's stored day; for a log from before days were stored, the day in this calendar.
    static func doseKey(_ log: SupplementLog, calendar: Calendar = .current) -> WellnessCloudChanges.DoseKey {
        .init(supplementID: log.supplementID, day: log.day ?? dayKey(log.date, calendar: calendar))
    }

    /// nil for a name this app doesn't write — never guessed into one of the kinds above.
    init?(name: String) {
        if name.hasPrefix(Self.mealPrefix), let id = UUID(uuidString: String(name.dropFirst(Self.mealPrefix.count))) {
            self = .meal(id)
        } else if name.hasPrefix(Self.supplementPrefix),
                  let id = UUID(uuidString: String(name.dropFirst(Self.supplementPrefix.count))) {
            self = .supplement(id)
        } else if name.hasPrefix(Self.dosePrefix) {
            // "dose-<36-char uuid>-<yyyyMMdd>"
            let rest = name.dropFirst(Self.dosePrefix.count)
            guard rest.count == 36 + 1 + 8, let id = UUID(uuidString: String(rest.prefix(36))),
                  rest.dropFirst(36).first == "-" else { return nil }
            let day = String(rest.suffix(8))
            guard day.allSatisfy(\.isNumber) else { return nil }
            self = .dose(supplementID: id, day: day)
        } else {
            return nil
        }
    }

    /// The data platform's record for it (`Shared/DataCatalog.json`): a meal's or supplement's
    /// UUID, a dose's `<supplement UUID>-<yyyyMMdd>` (`LegacyInventory`).
    var catalogRecord: (type: String, id: String) {
        switch self {
        case .meal(let id): ("food.meal", id.uuidString)
        case .supplement(let id): ("food.supplement", id.uuidString)
        case .dose(let id, let day): ("food.dose", "\(id.uuidString)-\(day)")
        }
    }

    /// What the move's drain leaves (`DrainResult`, docs/design/DATA-PLATFORM.md §3 seeding rule 1),
    /// from the sync's own bookkeeping by record name: edits and deletes iCloud hasn't confirmed,
    /// and items here that iCloud confirmed once (`confirmed`: a save went through or a fetch
    /// brought it), aren't waiting to go up, and are no longer in the zone. An item made here and
    /// never confirmed, read-only for instance, is never absent. `present` nil (the zone couldn't
    /// be listed) or empty (nothing is left at all, which a drop must never be guessed from)
    /// leaves nothing absent.
    static func drainResult(local: Set<String>, confirmed: Set<String>, dirty: Set<String>, deletes: Set<String>,
                            present: Set<String>?) -> DrainResult {
        var result = DrainResult()
        for name in dirty.subtracting(deletes) {
            guard let record = WellnessCloudRecord(name: name)?.catalogRecord else { continue }
            result.note(\.dirty, type: record.type, id: record.id)
        }
        for name in deletes {
            guard let record = WellnessCloudRecord(name: name)?.catalogRecord else { continue }
            result.note(\.pendingDeletes, type: record.type, id: record.id)
        }
        if let present, !present.isEmpty {
            for name in local.intersection(confirmed).subtracting(present).subtracting(dirty).subtracting(deletes) {
                guard let record = WellnessCloudRecord(name: name)?.catalogRecord else { continue }
                result.note(\.absent, type: record.type, id: record.id)
            }
        }
        return result
    }

    /// The calendar day a dose belongs to, as "yyyyMMdd" in the device's calendar.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// A synced item and when it was last edited, on whichever device edited it. Conflicts are
/// decided on that time, not on when the copy reached the server: an edit made offline at 09:30
/// still beats one made at 09:00 that happened to upload first.
struct WellnessCloudEnvelope<Item: Codable>: Codable {
    var editedAt: Date
    var item: Item
}

enum WellnessCloudPayload {
    /// The edit time of an item that hasn't been edited since sync began (the first upload of
    /// the phone's history): any real edit beats it.
    static let unedited = Date(timeIntervalSince1970: 0)

    static func encode<Item: Codable>(_ item: Item, editedAt: Date) -> Data? {
        try? JSONEncoder().encode(WellnessCloudEnvelope(editedAt: editedAt, item: item))
    }

    static func decode<Item: Codable>(_ type: Item.Type, from data: Data) -> WellnessCloudEnvelope<Item>? {
        try? JSONDecoder().decode(WellnessCloudEnvelope<Item>.self, from: data)
    }

    /// Just the edit time, to check what a finished upload carried.
    static func editedAt(_ data: Data) -> Date? {
        struct Stamp: Decodable { var editedAt: Date }
        return (try? JSONDecoder().decode(Stamp.self, from: data))?.editedAt
    }
}

/// What to do with a copy of an item that arrives from iCloud.
enum WellnessCloudConflict: Equatable {
    /// Take it.
    case adopt
    /// Ours is the newer edit: keep it, and send it over the cloud's.
    case keepLocal
    /// Deleted here and the delete hasn't gone out yet: it's on its way, don't bring it back.
    case ignore

    static func resolve(localEditedAt: Date?, remoteEditedAt: Date, deletedHere: Bool) -> Self {
        if deletedHere { return .ignore }
        if let localEditedAt, localEditedAt > remoteEditedAt { return .keepLocal }
        return .adopt
    }
}

/// One fetch's worth of remote changes, applied to the store in a single save.
struct WellnessCloudChanges: Equatable {
    var meals: [MealEntry] = []
    var supplements: [SupplementSchedule] = []
    var doses: [SupplementLog] = []
    var deletedMeals: Set<UUID> = []
    var deletedSupplements: Set<UUID> = []
    /// (supplement, day key) pairs.
    var deletedDoses: [DoseKey] = []
    /// Whether a deleted supplement takes its doses with it here. True for iCloud, where only the
    /// supplement's delete travels; false for the data platform, where the deleting device sends
    /// each dose's delete itself and receivers never infer one (DATA-PLATFORM.md §3).
    var cascadesDoses = true

    struct DoseKey: Hashable { var supplementID: UUID; var day: String }

    var isEmpty: Bool {
        meals.isEmpty && supplements.isEmpty && doses.isEmpty
            && deletedMeals.isEmpty && deletedSupplements.isEmpty && deletedDoses.isEmpty
    }
}

enum WellnessCloudMerge {
    static let logCap = 2_000

    /// Folds remote changes into the local lists. Only what the changes name is touched: a meal
    /// missing from a batch is never removed for being missing — only an explicit deletion
    /// removes anything.
    static func apply(_ changes: WellnessCloudChanges,
                      meals: inout [MealEntry],
                      supplements: inout [SupplementSchedule],
                      logs: inout [SupplementLog],
                      calendar: Calendar = .current) {
        if !changes.meals.isEmpty || !changes.deletedMeals.isEmpty {
            var byID = Dictionary(meals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for meal in changes.meals { byID[meal.id] = meal }
            for id in changes.deletedMeals { byID.removeValue(forKey: id) }
            meals = byID.values.sorted { $0.date > $1.date }
        }

        if !changes.supplements.isEmpty || !changes.deletedSupplements.isEmpty {
            for supplement in changes.supplements {
                if let index = supplements.firstIndex(where: { $0.id == supplement.id }) {
                    supplements[index] = supplement
                } else {
                    supplements.append(supplement)
                }
            }
            supplements.removeAll { changes.deletedSupplements.contains($0.id) }
            supplements.sort { ($0.safeHour, $0.safeMinute, $0.name) < ($1.safeHour, $1.safeMinute, $1.name) }
        }

        let cascaded = changes.cascadesDoses ? changes.deletedSupplements : []
        if !changes.doses.isEmpty || !changes.deletedDoses.isEmpty || !cascaded.isEmpty {
            let replaced = Set(changes.doses.map { WellnessCloudRecord.doseKey($0, calendar: calendar) })
                .union(changes.deletedDoses)
            logs.removeAll { log in
                // Deleting a supplement takes its history with it, as it does on the device
                // that deleted it (`WellnessStore.deleteSupplement`).
                cascaded.contains(log.supplementID)
                    || replaced.contains(WellnessCloudRecord.doseKey(log, calendar: calendar))
            }
            // Latest per (supplement, day) if a batch somehow carries two.
            var latest: [WellnessCloudChanges.DoseKey: SupplementLog] = [:]
            for dose in changes.doses where !cascaded.contains(dose.supplementID) {
                let key = WellnessCloudRecord.doseKey(dose, calendar: calendar)
                if let existing = latest[key], existing.date >= dose.date { continue }
                latest[key] = dose
            }
            logs.append(contentsOf: latest.values)
            logs = Array(logs.sorted { $0.date > $1.date }.prefix(logCap))
        }
    }
}
