import Foundation

/// The former key-value dictionaries, one record per key (§5): where one device's write of the
/// whole dictionary used to erase another's entries, each entry now merges on its own.
/// - `plan.taskDuration`: a task's estimate by the reminder's stable id, `{minutes, updatedAt}`,
///   seeded at its own `updatedAt`.
/// - `plan.reminderAnchor`, `plan.reminderAnchorUsual`, `plan.missedRepeat`: by the store's key
///   (`id:<reminder>` or `title:<title>`), the entry as one value `v`.
/// - `plan.declinedSuggestion`, `plan.notNow`: one record per answer, `v: true`.
/// - `core.guestPick`: one record per name, a field per address with its count.
/// A key that is a title or a name, or too long, is a record id only as a stable hash; the key
/// itself travels in the field `key` (`SyncKeys`), and an empty key isn't kept.
/// Entries without a time seed at the low clock (hub 1, spokes 0, §3 seeding rule 5); an entry
/// a store drops for its age is only gone there (§3, "Pruning is not deleting").
enum KeyValueAdapters {
    @MainActor
    static func adapter(_ stores: SyncStores) -> BoundAdapter {
        let durations = stores.taskDurations, anchors = stores.reminderAnchors
        let missed = stores.missedRepeats, answers = stores.anchorSuggestions
        // A reminder's title says what it is: its key goes as a hash, the title in a field.
        let byTitle: @Sendable (String) -> Bool = { $0.hasPrefix("title:") }
        return BoundAdapter("key-value", [
            .keyed(TaskDurationStore.syncType, shape: .fields,
                   entries: { durations.syncEntries },
                   set: { durations.applySynced($0) },
                   seedClock: { durations.syncEntry($0)?.updatedAt }),
            .keyed(ReminderAnchors.syncType, hashKey: byTitle,
                   entries: { [weak anchors] in anchors?.rules ?? [:] },
                   set: { [weak anchors] in anchors?.applySynced(rules: $0) }),
            .keyed(ReminderAnchors.syncUsualType, hashKey: byTitle,
                   entries: { [weak anchors] in anchors?.usual ?? [:] },
                   set: { [weak anchors] in anchors?.applySynced(usual: $0) }),
            .keyed(MissedRepeats.syncType, hashKey: byTitle,
                   entries: { [weak missed] in missed?.syncEntries ?? [:] },
                   set: { [weak missed] in missed?.applySynced($0) }),
            .keyed(AnchorSuggestionStore.syncDeclinedType,
                   entries: { [weak answers] in Dictionary(uniqueKeysWithValues: (answers?.syncDeclined ?? []).map { ($0, true) }) },
                   set: { [weak answers] changes in answers?.applySynced(declined: changes.mapValues { $0 ?? false }) }),
            .keyed(AnchorSuggestionStore.syncNotNowType,
                   entries: { [weak answers] in Dictionary(uniqueKeysWithValues: (answers?.syncNotNow ?? []).map { ($0, true) }) },
                   set: { [weak answers] changes in answers?.applySynced(notNow: changes.mapValues { $0 ?? false }) }),
            .keyed(GuestPicks.syncType, shape: .fields, hashKey: { _ in true },   // names of people
                   entries: { GuestPicks.syncEntries },
                   set: { GuestPicks.applySynced($0) }),
        ])
    }
}
