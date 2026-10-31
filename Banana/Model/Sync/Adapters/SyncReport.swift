import Foundation

/// Where a store reports its items to the move off iCloud (`MoveOver`), from any thread
/// (`SyncAdapters` contract, "Reports"). On the main thread it's `MoveOver`'s own call, so a
/// report made while a legacy channel applies what it fetched counts as a late arrival. Off it,
/// the report hops to the main actor; a store that applies iCloud's data off the main thread says
/// `arrived` itself.
enum SyncReport {
    static func changed(_ type: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        onMain { MoveOver.changed(type: type, ids: ids) }
    }

    static func deleted(_ type: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        onMain { MoveOver.deleted(type: type, ids: ids) }
    }

    /// What a legacy channel brought in (§3 seeding rule 6), whatever thread it's on.
    static func arrived(_ type: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        onMain { MoveOver.arrived(type: type, ids: ids) }
    }

    /// The keys of `before` and `after` whose values differ: changed (present in `after`) and gone.
    static func diff<Value: Equatable>(_ before: [String: Value], _ after: [String: Value]) -> (changed: [String], gone: [String]) {
        let changed = after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
        let gone = before.keys.filter { after[$0] == nil }.sorted()
        return (changed, gone)
    }

    private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }
}
