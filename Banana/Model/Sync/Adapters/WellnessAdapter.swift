import Foundation

/// Meals, supplements and doses (`food.meal`, `food.supplement`, `food.dose`): `WellnessStore`'s
/// lists, as the data platform sees them (docs/design/DATA-PLATFORM.md §3, §6). Ids are the
/// Wellness zone's (`WellnessCloudRecord.catalogRecord`): a meal's or supplement's UUID, a dose's
/// `<supplement UUID>-<yyyyMMdd>`, so what the legacy drain reports names the same records.
@MainActor protocol WellnessSyncPort: AnyObject {
    var meals: [MealEntry] { get }
    var supplements: [SupplementSchedule] { get }
    var supplementLogs: [SupplementLog] { get }
    /// Another device's changes in one save: the store's adopt-from-cloud path
    /// (`WellnessCloudMerge.apply`), never reported back. Caps prune here only.
    func applySpaceChanges(_ changes: WellnessCloudChanges)
    /// When the legacy sync saw the item last edited (§3 seeding rule 3); nil when it doesn't know.
    func editedAt(_ record: WellnessCloudRecord) -> Date?
}

enum WellnessSpace {
    static let meal = "food.meal", supplement = "food.supplement", dose = "food.dose"
    static let types = [meal, supplement, dose]

    /// A dose's record id.
    static func doseID(_ log: SupplementLog, calendar: Calendar = .current) -> String {
        WellnessCloudRecord.dose(log, calendar: calendar).catalogRecord.id
    }

    /// `<36-character UUID>-<yyyyMMdd>`.
    static func doseKey(_ id: String) -> WellnessCloudChanges.DoseKey? {
        guard id.count == 36 + 1 + 8, let uuid = UUID(uuidString: String(id.prefix(36))),
              id.dropFirst(36).first == "-" else { return nil }
        let day = String(id.suffix(8))
        guard day.allSatisfy(\.isNumber) else { return nil }
        return .init(supplementID: uuid, day: day)
    }

    /// The doses that go with a supplement deleted here: the deleting device sends their deletes
    /// in the same request (§3 "Cascades are sent by the deleting device").
    static func doseIDs(of supplement: UUID, in logs: [SupplementLog], calendar: Calendar = .current) -> [String] {
        Array(Set(logs.filter { $0.supplementID == supplement }.map { doseID($0, calendar: calendar) })).sorted()
    }
}

@MainActor
final class WellnessAdapter: RecordAdapter {
    let port: any WellnessSyncPort
    private let calendar: Calendar
    /// Each item's own time, from the last snapshot: the seed asks for every id right after it.
    private var ownTimes: [String: [String: Date]] = [:]

    init(port: any WellnessSyncPort, calendar: Calendar = .current) {
        self.port = port
        self.calendar = calendar
    }

    var types: [String] { WellnessSpace.types }

    func snapshot(_ type: String) -> [String: any Encodable & Sendable] {
        switch type {
        case WellnessSpace.meal:
            let meals = port.meals
            ownTimes[type] = Dictionary(meals.map { ($0.id.uuidString, $0.date) }, uniquingKeysWith: { first, _ in first })
            return Dictionary(meals.map { ($0.id.uuidString, $0 as any Encodable & Sendable) }, uniquingKeysWith: { first, _ in first })
        case WellnessSpace.supplement:
            return Dictionary(port.supplements.map { ($0.id.uuidString, $0 as any Encodable & Sendable) }, uniquingKeysWith: { first, _ in first })
        case WellnessSpace.dose:
            let doses = doses(port.supplementLogs)
            ownTimes[type] = doses.compactMapValues { ($0 as? SupplementLog)?.date }
            return doses
        default:
            return [:]
        }
    }

    func items(_ type: String, ids: Set<String>) -> [String: any Encodable & Sendable] {
        switch type {
        case WellnessSpace.meal:
            var out: [String: any Encodable & Sendable] = [:]
            for meal in port.meals where ids.contains(meal.id.uuidString) {
                out[meal.id.uuidString] = meal
                ownTimes[type, default: [:]][meal.id.uuidString] = meal.date
            }
            return out
        case WellnessSpace.supplement:
            var out: [String: any Encodable & Sendable] = [:]
            for supplement in port.supplements where ids.contains(supplement.id.uuidString) {
                out[supplement.id.uuidString] = supplement
            }
            return out
        case WellnessSpace.dose:
            let wanted = Set(ids.compactMap(WellnessSpace.doseKey).map(\.supplementID))
            let found = doses(port.supplementLogs.filter { wanted.contains($0.supplementID) }).filter { ids.contains($0.key) }
            for (id, log) in found { if let date = (log as? SupplementLog)?.date { ownTimes[type, default: [:]][id] = date } }
            return found
        default:
            return [:]
        }
    }

    /// One per supplement and day, the latest if two; each with its day filled in, as sync files it.
    /// Only those of a supplement the store has: a dose left behind by a supplement deleted
    /// elsewhere isn't sent anywhere.
    private func doses(_ logs: [SupplementLog]) -> [String: any Encodable & Sendable] {
        let supplements = Set(port.supplements.map(\.id))
        var latest: [String: SupplementLog] = [:]
        for log in logs where supplements.contains(log.supplementID) {
            var log = log
            let key = WellnessCloudRecord.doseKey(log, calendar: calendar)
            log.day = key.day
            let id = "\(key.supplementID.uuidString)-\(key.day)"
            if let kept = latest[id], kept.date >= log.date { continue }
            latest[id] = log
        }
        return latest.mapValues { $0 }
    }

    func seedClock(_ type: String, id: String) -> Date? {
        switch type {
        case WellnessSpace.meal:
            guard let uuid = UUID(uuidString: id) else { return nil }
            return HealthFood.ownTime(port.editedAt(.meal(uuid))) ?? ownTimes[type]?[id]
        case WellnessSpace.supplement:
            guard let uuid = UUID(uuidString: id) else { return nil }
            return HealthFood.ownTime(port.editedAt(.supplement(uuid)))
        case WellnessSpace.dose:
            guard let key = WellnessSpace.doseKey(id) else { return nil }
            return HealthFood.ownTime(port.editedAt(.dose(supplementID: key.supplementID, day: key.day))) ?? ownTimes[type]?[id]
        default:
            return nil
        }
    }

    func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool] {
        var changes = WellnessCloudChanges()
        changes.cascadesDoses = false
        for record in records {
            switch type {
            case WellnessSpace.meal:
                if let meal = HealthFood.decode(MealEntry.self, record.fields), meal.id.uuidString == record.id {
                    changes.meals.append(meal)
                }
            case WellnessSpace.supplement:
                if let supplement = HealthFood.decode(SupplementSchedule.self, record.fields),
                   supplement.id.uuidString == record.id {
                    changes.supplements.append(supplement)
                }
            case WellnessSpace.dose:
                if var log = HealthFood.decode(SupplementLog.self, record.fields), let key = WellnessSpace.doseKey(record.id),
                   log.supplementID == key.supplementID {
                    log.day = key.day
                    changes.doses.append(log)
                }
            default:
                break
            }
        }
        if !changes.isEmpty { port.applySpaceChanges(changes) }
        // A malformed record is dropped, as the Wellness zone drops one; nothing here waits.
        return Dictionary(records.map { ($0.id, true) }, uniquingKeysWith: { first, _ in first })
    }

    /// Through the store's adopt path, without a cascade: a supplement's doses go only by their
    /// own deletes, which the deleting device sends.
    func remove(_ type: String, ids: [String]) {
        var changes = WellnessCloudChanges()
        changes.cascadesDoses = false
        switch type {
        case WellnessSpace.meal: changes.deletedMeals = Set(ids.compactMap(UUID.init(uuidString:)))
        case WellnessSpace.supplement: changes.deletedSupplements = Set(ids.compactMap(UUID.init(uuidString:)))
        case WellnessSpace.dose: changes.deletedDoses = ids.compactMap(WellnessSpace.doseKey)
        default: return
        }
        if !changes.isEmpty { port.applySpaceChanges(changes) }
    }

    func blobFile(_ type: String, id: String, field: String) -> URL? { nil }
    func storeBlob(_ type: String, id: String, field: String, file: URL) {}
}
