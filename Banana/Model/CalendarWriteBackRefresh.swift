import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Background calendar write-back: while the app is suspended, refresh the calendar sources and
/// re-run the same materialization + write-back pass the foreground does, so a Calendly booking
/// that lands a meeting (or a return-home travel hold) inside the 90-day write-back horizon still
/// shows up as a busy block WITHOUT the person having to open Banana first. The same pass moves
/// the wake alarm earlier when a meeting has landed for the morning (`WakeFollow`).
///
/// This is a `BGAppRefreshTask`, not the `BGProcessingTask` `OvernightRefresh` uses: it needs a
/// short, frequent window (no charger/Wi-Fi requirement), not an overnight batch window. Modeled
/// directly on `OvernightRefresh.swift` — same register/schedule/run shape.
///
/// A look (`look`) asks Google whether anything changed, which is one small request per calendar,
/// and runs the pass only when something did or the last pass is two hours old
/// (`CalendarRefreshPace`). iOS is asked for a look every five minutes (twenty-five in Low Power
/// Mode) and grants what it grants; the same look runs on that clock while the phone plays audio
/// with Banana not in front, which is the one time away from the front that is ours to schedule.
@MainActor
enum CalendarWriteBackRefresh {
    static let taskID = "com.boris.banana.calendar.refresh"

    /// How long between the end of one run and the earliest the OS may start the next. iOS
    /// treats this as a floor, not a promise — the real interval is opportunistic and usually far
    /// longer (it was two hours here, and the iPad's journal shows six runs in five days).
    private static var minimumInterval: TimeInterval {
        CalendarRefreshPace.interval(inFront: false, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    #if os(iOS)
    /// Call once from app launch, before launch finishes — same requirement as `OvernightRefresh`.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            // The data platform's pass and the move's next step, under their own background time.
            Task { @MainActor in SpaceSyncLaunch.sync(reason: "background refresh") }
            Task { @MainActor in await run(task) }
        }
    }

    /// Ask the OS for the next short refresh window. Called whenever the app backgrounds AND
    /// after every run (success or not) so the chain keeps going — same pattern as
    /// `OvernightRefresh.schedule()`, minus the charger/network requirements a quick refresh
    /// doesn't need.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date().addingTimeInterval(minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.sync.notice("calendar write-back: scheduled")
        } catch {
            // Swallowing this is how a background task silently never runs.
            Log.sync.error("calendar write-back: submit FAILED — \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func run(_ task: BGAppRefreshTask) async {
        var expired = false
        task.expirationHandler = { expired = true }

        // Chain the next window immediately, before doing any work: if this run gets killed by
        // expiration (or the process is jetsam'd) before reaching the bottom, the next attempt is
        // still on the books instead of the chain silently going quiet.
        schedule()

        let finished = await look(reason: "background task") { expired }
        task.setTaskCompleted(success: finished)
    }

    private static var looking = false

    /// One look made away from the front: by the background task above, or on the same clock
    /// while the phone plays audio (`SmartScheduleStore.observeCalendarChanges`).
    ///
    /// The ask brings the shared Google read up to date, incrementally, using whatever access
    /// token `GIDSignIn` has cached (nothing here prompts; with no Google account it's a no-op).
    /// The pass after it is the one this task has always run: the wake plan from the calendar as
    /// it is now, then the timeline's write-back, which moves the wake alarm earlier, or adds
    /// one, where a meeting has landed since the app was last open.
    /// - Returns: false when it was cut short.
    @discardableResult
    static func look(reason: String, expired: () -> Bool = { false }) async -> Bool {
        // One at a time: the task and the playing clock can come due together.
        guard !looking else { return true }
        looking = true
        defer { looking = false }

        let changed = await SmartScheduleStore.shared.askWhetherCalendarsChanged()
        guard !expired() else { return false }
        let lastFullPass = UserDefaults.standard.object(forKey: CalendarRefreshPace.lastFullPassKey) as? Date
        guard CalendarRefreshPace.afterLook(changed: changed, lastFullPass: lastFullPass, now: Date()) == .fullPass else {
            PlaybackDiagnostics.shared.log(
                "writeback: look", "\(reason): \(changed == nil ? "calendars not read" : "nothing changed")")
            return changed != nil
        }

        await SmartScheduleStore.shared.refreshWakePlanInBackground()
        guard !expired() else { return false }
        let writtenCount = await OccurrenceStore.shared.performBackgroundWriteBack()
        guard !expired() else { return false }
        PlaybackDiagnostics.shared.log(
            "writeback: background refresh",
            "\(reason): \(changed == true ? "calendar changed" : "two-hourly pass"), wrote \(writtenCount) blocks")
        return true
    }
    #else
    static func register() {}
    static func schedule() {}
    #endif
}
