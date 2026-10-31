import Foundation
import WatchConnectivity

@MainActor
final class WatchWorkoutPlanStore: ObservableObject {
    static let shared = WatchWorkoutPlanStore()

    @Published private(set) var latestPlan: WorkoutPlan?
    @Published var activePlan: WorkoutPlan?

    private let defaultsKey = "cachedWorkoutPlan"

    /// The raw bytes last applied (from `init`'s defaults read, or a prior `apply`), so a
    /// context push carrying the same plan we already hold can skip the decode + UserDefaults
    /// write entirely — it rides along on every unrelated applicationContext push (play/pause,
    /// settings, calendar) since WatchConnectivity always resends the whole merged dict.
    private var lastAppliedData: Data?

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            latestPlan = try? JSONDecoder().decode(WorkoutPlan.self, from: data)
            lastAppliedData = data
        }
    }

    func apply(_ data: Data) {
        guard data != lastAppliedData else { return }
        lastAppliedData = data
        guard !data.isEmpty, let plan = try? JSONDecoder().decode(WorkoutPlan.self, from: data) else {
            latestPlan = nil
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        latestPlan = plan
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func begin(_ plan: WorkoutPlan) { activePlan = plan }
    func cancelActive() { activePlan = nil }

    func finish(startedAt: Date, exerciseIDs: [String]) {
        guard let plan = activePlan else { return }
        let completion = WorkoutCompletion(planID: plan.id, startedAt: startedAt, endedAt: Date(), completedExerciseIDs: exerciseIDs)
        WatchSyncManager.shared.sendWorkoutPlanCompletion(completion)
        activePlan = nil
    }
}
