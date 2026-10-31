import Foundation

/// Ticking a reminder, from wherever it is ticked: the circle on a chip, on a block, a row on the
/// Mac, the menu. It shows at once, a toast names it and offers Undo, and Reminders is told when
/// the toast goes (or the app leaves the front), so an Undo leaves nothing to take back there.
///
/// A tick used to be written 120 ms after the tap with nothing to undo it: on the phone a tap
/// anywhere on a reminder ticked it, a ticked one left the line, and that was that.
@MainActor
enum TaskTick {
    static func toggle(_ occurrence: Occurrence) {
        guard let id = occurrence.reminderID else { return }
        let store = OccurrenceStore.shared
        // The circle tapped again while its toast is still up: that is the Undo.
        if store.hasHeldTick(id) {
            Task { await ToastCenter.shared.performUndo() }
            return
        }
        guard let completed = store.toggleTask(occurrence, holdingWrite: true) else { return }
        let message = TaskTicks.message(title: occurrence.title, completed: completed)
        Task {
            await ToastCenter.shared.deferCommit(message: message,
                                                 undo: { store.undoHeldTick(id) },
                                                 commit: { store.commitHeldTick(id) })
        }
    }
}
