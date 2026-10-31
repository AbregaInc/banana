#if os(iOS)
import BackgroundTasks
import Foundation
import UIKit

// Meals keep being estimated once the app is closed. Left to itself, iOS gives a backgrounded app
// about 30 seconds and then stops it; a photo meal takes the on-device model 10–20 s, so leaving
// the app mid-backlog left all but one meal waiting until it was opened again. Two ways round it:
//  - meals someone just asked for keep going, with the system's progress bar (`ContinuedMealEstimates`);
//  - anything still waiting is estimated while the phone charges (`MealEstimateCatchUp`).

/// Meals someone just readied here (a note, Use photo only, Try again) keep being estimated after
/// they leave the app, with the system's progress bar — iOS 26's continued processing, used the
/// way ContinuedTranscription learned it has to be: a unique identifier per submission, registered
/// just before it's submitted, submitted from the foreground, and progress that never stands still.
@available(iOS 26, *)
@MainActor
enum ContinuedMealEstimates {
    /// Under the wildcard in Info.plist: `com.boris.banana.meals.estimate.*`.
    private static let prefix = "com.boris.banana.meals.estimate"
    /// The submission running now; one at a time — it follows every meal this device has to do.
    private static var running: String?

    static func startIfNeeded(meals: Int) {
        guard running == nil, meals > 0, UIApplication.shared.applicationState == .active else { return }
        let id = "\(prefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in await run(task) }
        }
        guard registered else {
            PlaybackDiagnostics.shared.log("🍽 estimate", "continued: registration refused")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: id, title: "Estimating meals",
            subtitle: MealEstimateProgress.subtitle(done: 0, total: meals))
        // Now or not at all: the estimating has already started; a run queued for later would
        // find it finished.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            running = id
            PlaybackDiagnostics.shared.log("🍽 estimate", "continued: started for \(meals) meal(s)")
        } catch {
            PlaybackDiagnostics.shared.log("🍽 estimate", "continued: not started — \(error.localizedDescription)")
        }
    }

    private static func run(_ task: BGContinuedProcessingTask) async {
        defer { running = nil }
        let processor = MealBacklogProcessor.shared
        var expired = false
        task.expirationHandler = {
            expired = true
            Task { @MainActor in
                processor.suspending()
                PlaybackDiagnostics.shared.log("🍽 estimate", "continued: stopped by the system")
            }
        }
        let progress = task.progress
        var meals = processor.pendingHere
        var done = 0
        var currentSince = Date()
        progress.totalUnitCount = Int64(max(meals.count, 1)) * MealEstimateProgress.unitsPerMeal
        progress.completedUnitCount = 0

        // Once a second: the scheduler stops a task whose progress stands still, and more often
        // only costs the estimating itself.
        while !expired {
            let pending = processor.pendingHere
            meals.formUnion(pending)
            let finished = meals.count - pending.count
            if finished != done {
                done = finished
                currentSince = Date()
                task.updateTitle("Estimating meals", subtitle: MealEstimateProgress.subtitle(done: done, total: meals.count))
            }
            progress.totalUnitCount = Int64(max(meals.count, 1)) * MealEstimateProgress.unitsPerMeal
            progress.completedUnitCount = MealEstimateProgress.completed(
                done: done, total: meals.count, secondsIntoCurrent: Date().timeIntervalSince(currentSince))
            if pending.isEmpty { break }
            try? await Task.sleep(for: .seconds(1))
        }
        if !expired { progress.completedUnitCount = progress.totalUnitCount }
        PlaybackDiagnostics.shared.log("🍽 estimate", "continued: \(expired ? "cut short" : "done") — \(done) of \(meals.count)")
        task.setTaskCompleted(success: !expired)
    }
}

/// Meals still waiting when the app closes are estimated the next time the phone charges and sits
/// idle — usually overnight — so the morning's review is ready without opening anything.
@MainActor
enum MealEstimateCatchUp {
    static let taskID = "com.boris.banana.meals.catchup"

    /// At launch, before launch finishes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in await run(task) }
        }
    }

    /// When the app goes to the background with something this device can estimate still waiting.
    static func scheduleIfNeeded() {
        guard MealBacklogProcessor.shared.hasWorkHere else { return }
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
            PlaybackDiagnostics.shared.log("🍽 estimate", "catch-up: scheduled for the next charge")
        } catch {
            // Swallowing this is how a background task silently never runs.
            PlaybackDiagnostics.shared.log("🍽 estimate", "catch-up: not scheduled — \(error.localizedDescription)")
        }
    }

    private static func run(_ task: BGProcessingTask) async {
        var expired = false
        task.expirationHandler = {
            expired = true
            Task { @MainActor in MealBacklogProcessor.shared.suspending() }
        }
        // A background launch has no window: start what the app's window would have.
        await MealBacklogWake.catchUp(reason: "charging")
        await WellnessStore.shared.whenLoaded()
        let processor = MealBacklogProcessor.shared
        processor.startIfNeeded(wellness: .shared)
        let started = Date()
        var estimated = Set<UUID>()
        // Until nothing here is waiting. A meal readied on another device becomes this one's after
        // the hand-off (`MealBacklogRouting`), so keep looking a while even when none is ours yet.
        while !expired {
            processor.kick()
            let pending = processor.pendingHere
            estimated.formUnion(pending)
            if pending.isEmpty, !processor.hasWorkHere || Date().timeIntervalSince(started) > 11 * 60 { break }
            try? await Task.sleep(for: .seconds(2))
        }
        PlaybackDiagnostics.shared.log("🍽 estimate", "catch-up: \(expired ? "cut short" : "done") — \(estimated.count) meal(s)")
        if processor.hasWorkHere { scheduleIfNeeded() }
        task.setTaskCompleted(success: !expired)
    }
}
#endif
