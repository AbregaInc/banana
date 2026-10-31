import Foundation

/// The types `SyncAdapters.everythingElse` registers (Stage D), as a list the tests can read:
/// every T1 type of `Shared/DataCatalog.json` must be here (`StageDAdapterTests`), and in a debug
/// build the adapters must register exactly these.
enum EverythingElseTypes {
    static let all: [String] = [
        "plan.routine", "plan.alarm", "plan.wake", "plan.override", "plan.extra",
        "podcast.show", "podcast.settings", "podcast.progress", "podcast.listen",
        "podcast.skipPlan", "podcast.adSlots", "podcast.skipCorrection",
        "podcast.narratorReading", "podcast.narratorGender", "podcast.narratorOverride",
        "podcast.transcript", "notes.voiceNote",
        "core.appSettings", "core.modules", "core.smartSettings", "core.wakePlan", "core.hubStatus", "core.hubRequest",
        "plan.taskDuration", "plan.reminderAnchor", "plan.reminderAnchorUsual", "plan.missedRepeat",
        "plan.declinedSuggestion", "plan.notNow", "core.guestPick",
        "plan.bookingType",
    ]

    /// Personal types in the catalog with no app adapter yet. Any such type must be one no legacy
    /// channel carries (`LegacyInventory.withoutLegacy`), so the move doesn't wait for it.
    static let withoutAdapter: [String] = []
}
