import Foundation

/// What each device can estimate (`MealEstimatorStatus`), in iCloud key-value storage: install id
/// → status. The iPhone and iPad read it to leave meals to a Mac on power
/// (`MealBacklogRouting.macTakes`); each device writes only its own, last writer wins.
@MainActor
final class MealEstimators: ObservableObject {
    static let shared = MealEstimators()
    private static let key = "mealEstimators.v1"
    /// A device says what it can do again after this, so a Mac that's on is never taken for
    /// asleep (`MealBacklogRouting.macHeartbeat` is three times this).
    static let refresh: TimeInterval = 15 * 60

    @Published private(set) var all: [String: MealEstimatorStatus] = [:]
    private let cloud = LegacyKVS.shared
    private var observer: NSObjectProtocol?

    private init() {
        read()
        observer = LegacyKVS.observeExternalChanges(tier: .health) { MealEstimators.shared.read() }
    }

    /// This device's status, written when it changes or has grown old.
    func publish(_ status: MealEstimatorStatus) {
        let id = MealInboxStore.installID
        if let current = all[id], Self.same(current, status),
           status.at.timeIntervalSince(current.at) < Self.refresh {
            return
        }
        var next = all
        next[id] = status
        if all[id].map({ !Self.same($0, status) }) ?? true {
            PlaybackDiagnostics.shared.log("🍽 estimators", "this \(status.device): \(Self.describe(status))")
        }
        let changed = all[id].map { !Self.same($0, status) } ?? true
        all = next
        if let data = try? JSONEncoder().encode(next) { cloud.set(data, forKey: Self.key) }
        // The data platform keeps every version: a new one on a real change, or as the heartbeat
        // a Mac on power is known by, not more often than every ten minutes.
        if changed || reportedAt.map({ status.at.timeIntervalSince($0) >= Self.spaceHeartbeat }) ?? true {
            reportedAt = status.at
            MoveOver.changed(type: Self.spaceType, ids: [id])
        }
    }

    private var reportedAt: Date?
    static let spaceHeartbeat: TimeInterval = 10 * 60

    /// The data platform's record type: one per install, the status whole.
    static let spaceType = "food.estimatorStatus"

    /// Other devices' statuses from the data platform (nil: gone), kept as the key-value copy is
    /// (`LegacyKVS` keeps this device's own once it no longer writes iCloud). Ours stays as this
    /// device last wrote it.
    func adoptFromSpace(_ changes: [String: MealEstimatorStatus?]) {
        var next = all
        for (id, status) in changes where id != MealInboxStore.installID { next[id] = status }
        guard next != all else { return }
        all = next
        if let data = try? JSONEncoder().encode(next) { cloud.set(data, forKey: Self.key) }
    }

    /// "text yes, photos no, on power".
    static func describe(_ status: MealEstimatorStatus) -> String {
        "text \(status.canReadText ? "yes" : "no"), photos \(status.canReadPhotos ? "yes" : "no"), \(status.onPower ? "on power" : "not on power")"
    }

    private static func same(_ a: MealEstimatorStatus, _ b: MealEstimatorStatus) -> Bool {
        a.device == b.device && a.canReadPhotos == b.canReadPhotos && a.canReadText == b.canReadText
            && a.onPower == b.onPower
    }

    private func read() {
        guard let data = cloud.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: MealEstimatorStatus].self, from: data) else { return }
        // Ours as this device last wrote it — the copy in iCloud may be older.
        var merged = decoded
        merged[MealInboxStore.installID] = all[MealInboxStore.installID] ?? decoded[MealInboxStore.installID]
        for (id, status) in merged where id != MealInboxStore.installID {
            if all[id].map({ !Self.same($0, status) }) ?? true {
                PlaybackDiagnostics.shared.log("🍽 estimators", "\(status.device): \(Self.describe(status))")
            }
        }
        // Another device's change through iCloud: after the move, a late arrival (`MoveOver`).
        let arrived = merged.filter { $0.key != MealInboxStore.installID && all[$0.key] != $0.value }.map(\.key).sorted()
        if !arrived.isEmpty, LegacyCloud.isApplyingFromCloud { MoveOver.changed(type: Self.spaceType, ids: arrived) }
        if merged != all { all = merged }
    }
}
