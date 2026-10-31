import Foundation

// The app's health and food stores as the Stage C adapters see them. Kept out of the unit tests,
// which bind the adapters to fakes and the stores they can compile (`HealthFoodAdapterTests`).

extension FitnessStore: WorkoutSyncPort {
    func samplesFile(_ id: UUID) -> URL? { samplesFileForCloudSync(id) }
    func adoptSpaceWorkout(_ summary: FitnessSessionSummary, samples: URL) async -> Bool {
        await adoptCloudWorkout(summary, samplesAssetURL: samples)
    }
    func editedAt(_ id: UUID) -> Date? { CloudFitnessSync.shared.editedAt(workout: id) }
}

extension HealthKitStore: HealthSnapshotPort {
    func snapshotMaker() -> @Sendable () -> Data? { spaceSnapshotMaker() }
    var snapshotDate: Date? { snapshotChangedAt }
    func adoptSnapshot(_ packed: Data) { adoptCloudSnapshot(packed) }
}

extension HealthRemovalInbox: HealthRequestPort {
    var requests: [HealthRemovalRequest] { all }
    func adoptRequests(_ requests: [HealthRemovalRequest], done: Set<UUID>) { adoptFromSpace(requests, done: done) }
    func removeRequests(_ ids: [UUID]) { removeFromSpace(ids) }
    func askedAt(_ request: HealthRemovalRequest) -> Date { request.askedAt }
}

extension WorkoutRevertInbox: HealthRequestPort {
    var requests: [WorkoutRevertRequest] { all }
    /// A revert already carried out elsewhere needs nothing: the workout no longer stands as the
    /// edit it named (`WorkoutEdits.shouldRevert`).
    func adoptRequests(_ requests: [WorkoutRevertRequest], done: Set<UUID>) { adoptFromSpace(requests) }
    func removeRequests(_ ids: [UUID]) { removeFromSpace(ids) }
    func askedAt(_ request: WorkoutRevertRequest) -> Date { request.askedAt }
}

/// `FoodSearchPicks` (static, the key-value store) as one dictionary.
@MainActor final class FoodSearchPicksPort: HealthFood.KeyedValues {
    var values: [String: [String: Int]] { FoodSearchPicks.everything }
    func adopt(_ changes: [String: [String: Int]?]) { FoodSearchPicks.adoptFromSpace(changes) }
}

@MainActor final class MealEstimatorsPort: HealthFood.KeyedValues {
    let store: MealEstimators
    init(_ store: MealEstimators) { self.store = store }
    var values: [String: MealEstimatorStatus] { store.all }
    func adopt(_ changes: [String: MealEstimatorStatus?]) { store.adoptFromSpace(changes) }
}

@MainActor final class MealPhotoScanReportsPort: HealthFood.KeyedValues {
    let store: MealPhotoScanReports
    init(_ store: MealPhotoScanReports) { self.store = store }
    var values: [String: MealPhotoScanReport] { store.all }
    func adopt(_ changes: [String: MealPhotoScanReport?]) { store.adoptFromSpace(changes) }
}

extension ControlChangeReporter {
    /// The health and food kinds' reports go to the data platform too (`MoveOver`), beside the
    /// iCloud sync they already reach. Wraps what's there, so another tier's wrapping composes.
    /// Not while iCloud's sync applies that very item: `CloudControlsSync.apply` reports each
    /// late arrival itself, once.
    static func alsoReportHealthToSpace() {
        let health: (ControlKind, String) -> String? = { kind, id in
            guard let type = LegacyInventory.controlKinds[kind.rawValue], LegacyInventory.isHealth(type),
                  !LegacyCloud.isApplyingFromCloud(type: type, id: id) else { return nil }
            return type
        }
        let changed = self.changed, deleted = self.deleted, offered = self.offered
        self.changed = { kind, id in
            changed(kind, id)
            if let type = health(kind, id) { MoveOver.changed(type: type, ids: [id]) }
        }
        self.deleted = { kind, id in
            deleted(kind, id)
            if let type = health(kind, id) { MoveOver.deleted(type: type, ids: [id]) }
        }
        self.offered = { kind, id in
            offered(kind, id)
            if let type = health(kind, id) { MoveOver.offered(type: type, ids: [id]) }
        }
    }
}
