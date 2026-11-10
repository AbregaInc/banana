import Foundation

/// `plan.whereabouts` (docs/design/BOOKING.md §13): where the owner will be, one record
/// (`whereabouts`) merged whole, the value in `v`, written by the phone only (`writers: hub`).
/// The latest `updatedAt` stands. No legacy channel ever carried it
/// (`LegacyInventory.withoutLegacy`): `SpaceSyncLaunch` seeds it when the adapter joins.
enum WhereaboutsAdapter {
    static let type = "plan.whereabouts"
    static let id = "whereabouts"

    @MainActor
    static func adapter(_ source: WhereaboutsSyncSource) -> BoundAdapter {
        BoundAdapter("whereabouts", [binding(source)])
    }

    @MainActor
    static func binding(_ source: WhereaboutsSyncSource) -> SyncBinding {
        weak var weakSource = source
        return .single(type, id: id, shape: .wrapped,
                       value: { weakSource?.syncWhereabouts },
                       apply: { (value: Whereabouts, _) in
                           weakSource?.adoptSyncedWhereabouts(value)
                           return .taken
                       },
                       seedClock: { weakSource?.syncWhereabouts?.updatedAt })
    }
}

/// What the adapter reads and hands back (`WhereaboutsStore`; a fake in the tests).
@MainActor
protocol WhereaboutsSyncSource: AnyObject {
    var syncWhereabouts: Whereabouts? { get }
    func adoptSyncedWhereabouts(_ value: Whereabouts)
}
