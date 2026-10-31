import WatchKit

/// watchOS relaunches the app through this callback when an active workout survives a crash.
final class WorkoutRecoveryDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in WorkoutRecorder.shared.recoverActiveWorkout() }
    }
}
