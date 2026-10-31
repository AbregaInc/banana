import Foundation

/// A workout removed on an iPad or the Mac, for the phone to finish. Apple Health is the phone's
/// (`DeviceRole.isHub`): the others show its copy and can't delete from it, so a delete or a hide
/// made on them stayed on them — the phone kept the Health workout, and its next snapshot brought
/// it back as a row of its own. They ask instead, over iCloud's key-value store, as the phone's
/// other jobs are asked for (`HubRequests`).
///
/// Asked for, never inferred: the phone doesn't take a workout record vanishing from iCloud as a
/// reason to delete from Health. Only a delete someone made says so.
struct HealthRemovalRequest: Codable, Hashable, Identifiable, Sendable {
    enum Target: Codable, Hashable, Sendable {
        /// The Apple Health half of a Banana workout that started then, and was deleted.
        case pairedWith(start: Date)
        /// A workout that's only in Health, by its id there: deleted if Banana wrote it, hidden
        /// if another app did (`HealthKitStore.canDeleteFromHealth`).
        case healthWorkout(UUID)
    }

    var id = UUID()
    var target: Target
    var askedAt: Date

    /// Long enough for a phone left off for some days; short enough that an old request can't
    /// meet an unrelated workout.
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    func isLive(at now: Date) -> Bool { now.timeIntervalSince(askedAt) < Self.lifetime }
}

/// The rules for those requests. Pure, for tests.
enum HealthRemovalRequests {
    /// The most kept at once: the list travels as one small value.
    static let limit = 50

    /// What the phone does about a request now.
    enum Step: Equatable {
        /// The Banana workout still stands on the phone — its delete hasn't arrived yet, or
        /// another recording of the same workout remains. Ask again later; never guess.
        case wait
        /// Remove this Health workout (delete or hide, by whose it is).
        case remove(UUID)
        /// Health hasn't delivered the workout yet: remove it when it does.
        case expect(Date)
        /// Nothing left to do: too old, or already gone.
        case drop
    }

    static func step(for request: HealthRemovalRequest, health: [HealthWorkout],
                     summaryStarts: [Date], now: Date) -> Step {
        guard request.isLive(at: now) else { return .drop }
        switch request.target {
        case .healthWorkout(let id):
            return health.contains { $0.id == id } ? .remove(id) : .drop
        case .pairedWith(let start):
            let near: (Date) -> Bool = { abs($0.timeIntervalSince(start)) < WorkoutEntry.matchTolerance }
            if summaryStarts.contains(where: near) { return .wait }
            if let paired = health.first(where: { near($0.start) }) { return .remove(paired.id) }
            return .expect(start)
        }
    }

    /// The list with one more: old ones dropped, the same thing asked twice kept once.
    static func adding(_ request: HealthRemovalRequest, to list: [HealthRemovalRequest],
                       now: Date) -> [HealthRemovalRequest] {
        var kept = list.filter { $0.isLive(at: now) && $0.target != request.target }
        kept.append(request)
        return Array(kept.suffix(limit))
    }

    /// The workouts in a Health snapshot from the phone that this device already removed: the
    /// snapshot was made before the phone heard. They stay hidden here until one arrives
    /// without them.
    static func removedHere(in workouts: [HealthWorkout], tombstones: [PendingRemoval],
                            now: Date) -> Set<UUID> {
        guard !tombstones.isEmpty else { return [] }
        return Set(workouts.filter { workout in
            tombstones.contains { $0.matches(workout.start, workout.end, now: now) }
        }.map(\.id))
    }
}
