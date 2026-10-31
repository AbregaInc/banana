import Combine
import Foundation

/// The road `HealthRemovalRequest`s take: written on an iPad or the Mac, carried out on the
/// phone, over iCloud's key-value store. The phone never writes the list — it keeps what it has
/// done to itself — so two devices never overwrite each other's half.
@MainActor
final class HealthRemovalInbox {
    static let shared = HealthRemovalInbox()

    private let cloud = LegacyKVS.shared
    private static let key = "healthRemovalRequests.v1"
    private static let handledKey = "healthRemovalRequestsHandled.v1"
    private weak var fitness: FitnessStore?
    private weak var health: HealthKitStore?
    private var observer: NSObjectProtocol?
    private var summaries: AnyCancellable?
    private var settling = false
    private var askedAgain = false

    private init() {}

    /// The phone: start carrying out what the other devices ask — on a sync from one of them,
    /// when a workout's delete arrives (a request waits for it), and when the app comes forward.
    func attach(fitness: FitnessStore, health: HealthKitStore) {
        guard DeviceRole.current.isHub else { return }
        self.fitness = fitness
        self.health = health
        observer = LegacyKVS.observeExternalChanges(tier: .health) { [weak self] in
            // What another device asked, carried out here: the requests' own records it reports are
            // arrivals; the workouts it changes are this device's doing (`LegacyCloud.ApplyScope`).
            Task { @MainActor in
                await LegacyCloud.applyingFromCloud(LegacyCloud.ApplyScope(["health.removalRequest": nil])) { await self?.settle() }
            }
        }
        summaries = fitness.$summaries
            .map { $0.count }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in await self?.settle() } }
        Task { await settle() }
    }

    /// From an iPad or the Mac: ask the phone. On the phone there is nobody to ask.
    func ask(_ target: HealthRemovalRequest.Target, now: Date = Date()) {
        guard !DeviceRole.current.isHub else { return }
        let request = HealthRemovalRequest(target: target, askedAt: now)
        let next = HealthRemovalRequests.adding(request, to: stored, now: now)
        guard let data = try? JSONEncoder().encode(next) else { return }
        cloud.set(data, forKey: Self.key)
        cloud.synchronize()
        // The data platform carries it as its own record (DATA-PLATFORM.md §3: `request` here,
        // the phone's `outcome`).
        MoveOver.changed(type: Self.spaceType, ids: [request.id.uuidString])
    }

    /// The phone: do what's been asked and not yet done.
    func settle() async {
        guard DeviceRole.current.isHub, let fitness, let health else { return }
        // One pass at a time: a second ask while this one is deleting runs after it.
        guard !settling else { askedAgain = true; return }
        settling = true
        defer { settling = false }
        repeat {
            askedAgain = false
            let requests = all
            // Forget what's no longer listed, so this never grows.
            var handled = handledIDs.intersection(requests.map(\.id))
            for request in requests where !handled.contains(request.id) {
                switch HealthRemovalRequests.step(for: request, health: health.workouts,
                                                  summaryStarts: fitness.summaries.map(\.start), now: Date()) {
                case .wait:
                    continue
                case .remove(let id):
                    let done = await health.remove(workoutID: id)
                    Log.sync.info("health removal asked by another device: \(String(describing: done), privacy: .public)")
                case .expect(let start):
                    health.expectRemoval(near: start)
                case .drop:
                    break
                }
                handled.insert(request.id)
            }
            let done = handled.subtracting(handledIDs)
            handledIDs = handled
            if !done.isEmpty { MoveOver.changed(type: Self.spaceType, ids: done.map(\.uuidString).sorted()) }
        } while askedAgain
    }

    private var stored: [HealthRemovalRequest] {
        cloud.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([HealthRemovalRequest].self, from: $0) } ?? []
    }

    // MARK: - The data platform (`HealthRequestsAdapter`)

    static let spaceType = "health.removalRequest"
    private static let spaceKey = "healthRemovalRequests.space"

    /// Requests that came through the data platform, kept here beside the key-value list (which
    /// old builds may still write while the move drains).
    private var fromSpace: [HealthRemovalRequest] {
        get { UserDefaults.standard.data(forKey: Self.spaceKey).flatMap { try? JSONDecoder().decode([HealthRemovalRequest].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.spaceKey) }
    }

    /// Every request this device knows, once each.
    var all: [HealthRemovalRequest] {
        var seen = Set<UUID>()
        return (stored + fromSpace).filter { seen.insert($0.id).inserted }
    }

    /// What the phone has carried out.
    var outcomes: [UUID: String] {
        Dictionary(uniqueKeysWithValues: handledIDs.map { ($0, "handled") })
    }

    /// Requests from another device through the data platform: kept, and carried out on the phone.
    func adoptFromSpace(_ requests: [HealthRemovalRequest], done: Set<UUID> = []) {
        // Carried out already (by this phone before a restore, or another): never twice.
        if DeviceRole.current.isHub, !done.isSubset(of: handledIDs) { handledIDs.formUnion(done) }
        let now = Date()
        var kept = fromSpace
        for request in requests where !kept.contains(where: { $0.id == request.id }) { kept.append(request) }
        kept = Array(kept.filter { $0.isLive(at: now) }.suffix(HealthRemovalRequests.limit))
        fromSpace = kept
        Task { await settle() }
    }

    /// Another account signed in and the person said to clear this device: the requests and what
    /// was done about them go, here only (the key-value list is this device's own copy by now:
    /// its tier no longer writes iCloud).
    func clearForAccountChange() {
        guard !LegacyCloud.mayWrite(.health) else { return }
        fromSpace = []
        handledIDs = []
        cloud.removeObject(forKey: Self.key)
    }

    func removeFromSpace(_ ids: [UUID]) {
        let gone = Set(ids)
        fromSpace = fromSpace.filter { !gone.contains($0.id) }
    }

    private var handledIDs: Set<UUID> {
        get {
            Set((UserDefaults.standard.stringArray(forKey: Self.handledKey) ?? []).compactMap(UUID.init(uuidString:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString).sorted(), forKey: Self.handledKey)
        }
    }
}
