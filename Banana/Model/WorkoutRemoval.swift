import Foundation

/// Deleting a workout Banana recorded, the way meals and doses are deleted: gone from the list at
/// once, with Undo, and removed for real when the Undo window closes — its Banana record, and the
/// Apple Health workout paired with it (or, when Health hasn't delivered that yet, a note to
/// remove it when it comes).
///
/// The phone's swipe used to delete both outright, with nothing to take it back; the wide list
/// asked first; the wide detail asked and left the Health half behind; and the Mac asked, with a
/// warning that its delete couldn't reach the phone's Health copy. One rule for every device:
/// where Health isn't this device's, the phone is asked to finish (`removeHealthHalf`).
@MainActor
enum WorkoutRemoval {
    /// Entries, less any deleted a moment ago.
    static func visible(_ entries: [WorkoutEntry], hiding hidden: Set<String>) -> [WorkoutEntry] {
        WorkoutEntry.visible(entries, hiding: hidden)
    }

    static func remove(_ entry: WorkoutEntry, fitness: FitnessStore, health: HealthKitStore) {
        guard let summary = entry.summary else { return }
        let start = entry.start
        Task {
            await ToastCenter.shared.deferRemoval(
                id: entry.removalID,
                message: "Deleted \(entry.activity)",
                failure: { "Couldn\u{2019}t delete: \($0)" }
            ) {
                await health.removeHealthHalf(ofWorkoutStarting: start)
                fitness.delete(summary.id)
                return nil
            }
        }
    }
}
