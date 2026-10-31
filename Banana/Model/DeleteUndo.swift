import Foundation

/// A delete happens at once and the toast offers Undo (DESIGN-SYSTEM.md, "Confirming and
/// undoing"); a question is only for what can't be taken back. One place for the deletes whose
/// store can put the thing back exactly, so the phone, iPad and Mac say and do the same.
///
/// Two ways, as `ToastCenter` has them:
/// - **Put back.** The store removes it now and hands back what it took (`Removed`); Undo
///   restores the same item at the same place. A restore is a newer edit than the delete, so
///   `CloudControlsSync` brings it back on every device instead of leaving a tombstone.
/// - **Deferred.** For what can't be rebuilt (a note's recording, a show's downloads and
///   transcripts): it is hidden now (`ToastCenter.hiddenIDs`) and really removed when the Undo
///   window closes. Undo shows it again; nothing was touched.
@MainActor
enum DeleteUndo {
    static func routine(_ id: UUID, in store: RoutineStore) {
        guard let removed = store.delete(id) else { return }
        offer("Deleted \(removed.item.name)") {
            store.restore(removed)
            return nil
        }
    }

    static func workoutPlan(_ id: UUID, in store: WellnessStore) {
        guard let removed = store.deleteWorkoutPlan(id) else { return }
        offer("Deleted \(removed.item.title)") {
            store.restoreWorkoutPlan(removed)
            return nil
        }
    }

    /// Undo arms it again on the phone (`AlarmStore.restoreOneOff`).
    static func alarm(_ id: UUID, in store: AlarmStore) {
        guard let alarm = store.cancelOneOff(id) else { return }
        offer("Deleted \(alarm.title)") {
            await store.restoreOneOff(alarm)
        }
    }

    /// An extra occurrence of a routine, added for one day. `changed` redraws the timeline.
    static func extra(_ id: String, named name: String?, changed: @escaping @MainActor () async -> Void) {
        let store = ExceptionStore.shared
        guard let removed = store.removeExtra(id) else { return }
        Task { await changed() }
        offer(name.map { "Deleted extra \($0)" } ?? "Deleted extra") {
            store.restoreExtra(removed)
            await changed()
            return nil
        }
    }

    /// Deferred: the recording, its iCloud copies and its reminder stay as they are until the
    /// Undo window closes, so there is nothing to rebuild and no tombstone to outrun.
    static func note(_ note: VoiceNote, in store: VoiceNoteStore) {
        let id = note.id
        Task {
            await ToastCenter.shared.deferRemoval(
                id: hidingID(note: id),
                message: "Deleted note",
                failure: { "Couldn\u{2019}t delete: \($0)" }
            ) {
                store.delete(id)
                return nil
            }
        }
    }

    /// Deferred: `remove` (downloads, transcripts, the show itself) runs when the Undo window
    /// closes, so Undo leaves progress, downloads and every episode's state untouched.
    static func podcast(_ podcast: Podcast, remove: @escaping @MainActor () -> Void) {
        Task {
            await ToastCenter.shared.deferRemoval(
                id: hidingID(podcast: podcast.id),
                message: "Deleted \(podcast.title)",
                failure: { "Couldn\u{2019}t delete: \($0)" }
            ) {
                remove()
                return nil
            }
        }
    }

    /// Deferred, for the same reason: the routes walked are files, gone for good once cleared.
    static func listeningHistory(_ store: ListenHistoryStore) {
        Task {
            await ToastCenter.shared.deferRemoval(
                id: listeningHistoryID,
                message: "Cleared history",
                failure: { "Couldn\u{2019}t clear: \($0)" }
            ) {
                store.clear()
                return nil
            }
        }
    }

    /// "Not a meal" in the backlog. Out of it at once; its photos go when the Undo window
    /// closes, so Undo finds the meal whole.
    static func notAMeal(_ id: UUID, in inbox: MealInboxStore) {
        guard let item = inbox.takeOut(id) else { return }
        Task {
            await ToastCenter.shared.deferCommit(
                message: "Deleted meal",
                undo: { inbox.putBack(item) },
                commit: { inbox.discardPhotos(of: item) })
        }
    }

    // What `ToastCenter.hiddenIDs` holds while each deferred delete waits.
    static func hidingID(note id: UUID) -> String { "note|" + id.uuidString }
    static func hidingID(podcast id: UUID) -> String { "podcast|" + id.uuidString }
    static let listeningHistoryID = "listeningHistory"

    private static func offer(_ message: String, undo: @escaping @MainActor () async -> String?) {
        Task { await ToastCenter.shared.offerUndo(message, undo: undo) }
    }
}
