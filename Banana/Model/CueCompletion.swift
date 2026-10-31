import Foundation

/// Completion belongs to this occurrence, not to the recurring routine's definition.
@MainActor
enum CueCompletion {
    static func toggle(_ occurrence: Occurrence) {
        guard occurrence.behavior == .cue, !occurrence.skipped, let key = occurrence.occurrenceKey else { return }
        let exceptions = ExceptionStore.shared
        let before = exceptions.override(for: key)
        let next = RoutineOccurrenceOverride.settingCompleted(!occurrence.completed, at: Date(), previous: before)
        exceptions.setOverride(key, next)
        OccurrenceStore.shared.refreshCueOverrides()
        Task { await OccurrenceStore.shared.recompute() }
        Task {
            await ToastCenter.shared.offerUndo("\(occurrence.title) \(occurrence.completed ? "marked not completed" : "completed")") { @MainActor in
                exceptions.setOverride(key, before)
                OccurrenceStore.shared.refreshCueOverrides()
                await OccurrenceStore.shared.recompute()
                return nil
            }
        }
    }
}
