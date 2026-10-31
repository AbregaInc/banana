import Foundation

/// Skipping one routine moment, or bringing it back, from any menu or sheet. The calendar shows it
/// at once — struck through and faded — and a toast says what happened, with Undo; the timeline
/// catches up behind. Before, nothing on screen changed until the recompute landed a few seconds
/// later, so a skip looked as if it hadn't worked.
@MainActor
enum CueSkip {
    static func skip(_ occurrence: Occurrence) { set(occurrence, skipped: true) }
    static func restore(_ occurrence: Occurrence) { set(occurrence, skipped: false) }

    private static func set(_ occurrence: Occurrence, skipped: Bool) {
        guard let key = occurrence.occurrenceKey else { return }
        let exceptions = ExceptionStore.shared
        let timeline = OccurrenceStore.shared
        let before = exceptions.override(for: key)
        if skipped { exceptions.skip(key) } else { exceptions.clearOverride(key) }
        timeline.markSkipped(key: key, skipped)
        Task { await timeline.recompute() }
        let message = skipped
            ? CueTimeText.skipped(occurrence.title, at: occurrence.start, hasTime: occurrence.hasScheduledTime)
            : CueTimeText.restored(occurrence.title, at: occurrence.start, hasTime: occurrence.hasScheduledTime)
        Task {
            await ToastCenter.shared.offerUndo(message) { @MainActor in
                exceptions.setOverride(key, before)
                timeline.markSkipped(key: key, occurrence.skipped)
                await timeline.recompute()
                return nil
            }
        }
    }
}
