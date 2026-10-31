import Foundation

/// The road a `WorkoutRevertRequest` takes: asked on a device that shows a workout as edited but
/// doesn't hold its original, carried out by any of your devices that does, over iCloud's
/// key-value store. The restored workout then syncs back like any other change.
///
/// Nothing is ticked off: a request is done when the workout no longer stands as the edit it
/// named, which every device can see for itself.
@MainActor
final class WorkoutRevertInbox {
    static let shared = WorkoutRevertInbox()

    private let cloud = LegacyKVS.shared
    private static let key = "workoutRevertRequests.v1"
    private weak var fitness: FitnessStore?
    private var observer: NSObjectProtocol?

    private init() {}

    func attach(fitness: FitnessStore) {
        self.fitness = fitness
        observer = LegacyKVS.observeExternalChanges(tier: .health) { [weak self] in
            // What another device asked, carried out here: the requests' own records it reports are
            // arrivals; the workouts it changes are this device's doing (`LegacyCloud.ApplyScope`).
            Task { @MainActor in
                await LegacyCloud.applyingFromCloud(LegacyCloud.ApplyScope(["health.workoutRevert": nil])) { await self?.settle() }
            }
        }
        Task { await settle() }
    }

    private var stored: [WorkoutRevertRequest] {
        guard let data = cloud.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([WorkoutRevertRequest].self, from: data)) ?? []
    }

    /// Ask whichever device holds the original to bring it back.
    func ask(_ summary: FitnessSessionSummary, now: Date = Date()) {
        guard let edit = summary.edit else { return }
        let request = WorkoutRevertRequest(sessionID: summary.id, editedAt: edit.editedAt, askedAt: now)
        guard let data = try? JSONEncoder().encode(WorkoutEdits.adding(request, to: stored, now: now)) else { return }
        cloud.set(data, forKey: Self.key)
        cloud.synchronize()
        MoveOver.changed(type: Self.spaceType, ids: [request.id.uuidString])
    }

    /// Carry out what's been asked and this device can do.
    func settle() async {
        guard let fitness else { return }
        await fitness.whenLoaded()
        let now = Date()
        for request in all {
            let summary = fitness.summaries.first { $0.id == request.sessionID }
            guard WorkoutEdits.shouldRevert(request, summary: summary,
                                            hasOriginal: fitness.hasOriginal(request.sessionID), now: now) else { continue }
            let done = fitness.revertTrim(request.sessionID)
            Log.sync.info("workout revert asked on another device: \(done, privacy: .public)")
            if done, SpaceSyncFlag.isOn {
                carriedOut.insert(request.id)
                MoveOver.changed(type: Self.spaceType, ids: [request.id.uuidString])
            }
        }
    }

    // MARK: - The data platform (`HealthRequestsAdapter`)

    static let spaceType = "health.workoutRevert"
    private static let spaceKey = "workoutRevertRequests.space"
    private static let doneKey = "workoutRevertRequests.done"

    /// Requests that came through the data platform, kept beside the key-value list.
    private var fromSpace: [WorkoutRevertRequest] {
        get { UserDefaults.standard.data(forKey: Self.spaceKey).flatMap { try? JSONDecoder().decode([WorkoutRevertRequest].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.spaceKey) }
    }

    /// The requests this device carried out.
    private var carriedOut: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: Self.doneKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set {
            let live = Set(all.map(\.id))
            UserDefaults.standard.set(newValue.intersection(live).map(\.uuidString).sorted(), forKey: Self.doneKey)
        }
    }

    /// Every request this device knows, once each.
    var all: [WorkoutRevertRequest] {
        var seen = Set<UUID>()
        return (stored + fromSpace).filter { seen.insert($0.id).inserted }
    }

    var outcomes: [UUID: String] { Dictionary(uniqueKeysWithValues: carriedOut.map { ($0, "reverted") }) }

    func adoptFromSpace(_ requests: [WorkoutRevertRequest]) {
        let now = Date()
        var kept = fromSpace
        for request in requests where !kept.contains(where: { $0.id == request.id }) { kept.append(request) }
        fromSpace = Array(kept.filter { $0.isLive(at: now) }.suffix(20))
        Task { await settle() }
    }

    /// Another account signed in and the person said to clear this device: here only.
    func clearForAccountChange() {
        guard !LegacyCloud.mayWrite(.health) else { return }
        fromSpace = []
        UserDefaults.standard.removeObject(forKey: Self.doneKey)
        cloud.removeObject(forKey: Self.key)
    }

    func removeFromSpace(_ ids: [UUID]) {
        let gone = Set(ids)
        fromSpace = fromSpace.filter { !gone.contains($0.id) }
    }
}
