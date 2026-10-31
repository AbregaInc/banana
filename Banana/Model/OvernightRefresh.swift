import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Overnight feed + download upkeep: while the phone charges on Wi-Fi, refresh every feed,
/// apply the auto-download rules, and (re)send anything the Watch is missing — so both
/// devices are stocked by morning without the app ever being opened.
///
/// The BG window itself only needs seconds: conditional feed GETs are header-cheap, and the
/// episode downloads are handed to the background URLSession daemon, which keeps working
/// after the task ends and relaunches the app per completion (where `finishDownload`
/// instructs the Watch per episode).
@MainActor
enum OvernightRefresh {
    static let taskID = "com.boris.banana.feeds.overnight"

    #if os(iOS)
    /// Call once from app launch, before launch finishes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in await run(task) }
        }
    }

    /// Ask the OS for the next charger + network window.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresExternalPower = true        // the overnight charger window
        request.requiresNetworkConnectivity = true  // feed fetches + downloads need it
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.sync.notice("overnight feeds: scheduled")
        } catch {
            // Swallowing this is how a background task silently never runs.
            Log.sync.error("overnight feeds: submit FAILED — \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func run(_ task: BGProcessingTask) async {
        // Background launches skip the root view's .task, so wireUp() never ran here —
        // dependencies must come from the singletons (same lesson as overnight transcribe).
        let library = WakeCoordinator.shared.library
        let downloads = WakeCoordinator.shared.downloads
        var expired = false
        task.expirationHandler = { expired = true }

        await library.whenLoaded()
        // A shorter staleness than the foreground path: an evening foreground refresh must
        // not make the overnight window a no-op — mornings deserve tonight's episodes.
        await downloads.refreshFeedsAndReconcile(staleAfter: 3600, allowBackgroundExecution: true)
        guard !expired else {
            task.setTaskCompleted(success: false)
            schedule()
            return
        }
        downloads.backfillWatch()       // escalates hour-old unconfirmed episodes to file transfers
        downloads.pushWatchManifest()
        Log.sync.notice("overnight feeds: refreshed \(library.podcasts.count) feeds, downloads handed to daemon")
        task.setTaskCompleted(success: true)
        schedule()                      // chain the next night
    }
    #else
    static func register() {}
    static func schedule() {}
    #endif
}
