#if os(iOS)
// BGContinuedProcessingTask + Live Activities: iPhone-only.

import Foundation
import BackgroundTasks

/// User-initiated transcription that keeps running after you leave the app (iOS 26).
///
/// Rewritten against the actual contract — WWDC25 session 227 and Apple DTS's replies on the
/// developer forums — rather than my reading of the headers. Three things I had wrong, each of
/// which produced a task the system killed:
///
///  1. **Identifiers must be unique per submission.** DTS: "you don't really 'know' when we're
///     'done' with any particular task ID, which means you don't know when it's 'safe' to reuse
///     that ID … I'd just append a value to the string to force uniqueness." I reused one fixed ID
///     for every submission, so only the first one could ever behave.
///
///  2. **Registration is dynamic, paired with submission** — not done once at launch like a
///     BGProcessingTask. WWDC25: "Launch handlers don't need to be registered before your app
///     finishes launching. Instead, you'll now dynamically register these handlers when the intent
///     to use them is expressed."
///
///  3. **Progress must move, and often.** The scheduler marks a task stalled when
///     `completedUnitCount` stops advancing — an observed dasd log reads "Task has not reported
///     progress within expected cadence (time without update: -36.2s)". DTS's rule of thumb is
///     2-10 updates/sec. It watches `completedUnitCount`, not `fractionCompleted`, and not child
///     Progress objects (a known iOS 26 bug, FB21338185).
///
/// Also true, and not worth re-learning the hard way:
///  • The request must be submitted from the foreground, as a result of a person's action.
///  • The wildcard (`<bundleID>.<context>.*`) goes in Info.plist; you register and submit a
///    fully-composed concrete identifier under it.
///  • Background App Refresh must be on for the app.
///  • It does not work in the Simulator. Device only.
@available(iOS 26, *)
@MainActor
enum ContinuedTranscription {

    /// Must sit under the wildcard permitted in Info.plist: `com.boris.banana.transcribe.*`
    private static let prefix = "com.boris.banana.transcribe"

    /// Identifier → episode ID, on disk: the handler can run in a fresh process.
    private static let mapKey = "continuedTranscriptionJobs"
    private static var jobs: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: mapKey) }
    }

    /// Registering the same identifier twice kills the app, so never do it.
    private static var registered: Set<String> = []

    /// Begin transcribing now, and keep going once the app is backgrounded.
    /// Must be called from the foreground, in response to a person's action.
    @discardableResult
    static func start(_ episode: Episode) -> Bool {
        let id = "\(prefix).\(UUID().uuidString)"   // unique per submission, never reused
        guard !registered.contains(id) else { return false }

        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            Task { @MainActor in await run(task) }
        }
        guard ok else {
            Log.wake.error("continued transcription: registration rejected for \(id, privacy: .public)")
            return false
        }
        registered.insert(id)

        var map = jobs
        map[id] = episode.id
        jobs = map

        let request = BGContinuedProcessingTaskRequest(identifier: id,
                                                       title: "Transcribing",
                                                       subtitle: episode.title)
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.wake.notice("continued transcription: submitted \(id, privacy: .public)")
            return true
        } catch {
            map[id] = nil
            jobs = map
            Log.wake.error("continued transcription: submit failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func run(_ task: BGContinuedProcessingTask) async {
        #if DEBUG
        print("[continued] handler launched — \(task.identifier)"); fflush(stdout)
        #endif

        defer {
            var map = jobs
            map[task.identifier] = nil
            jobs = map
            registered.remove(task.identifier)
        }

        let progress = task.progress
        // 10,000 units, not 100: at 100 a four-hour episode only ticks every ~3s, and the scheduler
        // wants to see movement far more often than that.
        progress.totalUnitCount = 10_000
        progress.completedUnitCount = 0

        let library = WakeCoordinator.shared.library
        await library.whenLoaded()
        guard let episodeID = jobs[task.identifier],
              let episode = library.podcasts.lazy.compactMap({ $0.episode(episodeID) }).first else {
            Log.wake.error("continued transcription: no episode for \(task.identifier, privacy: .public)")
            task.setTaskCompleted(success: false)
            return
        }

        var expired = false
        task.expirationHandler = {
            expired = true
            #if DEBUG
            print("[continued] EXPIRED BY SYSTEM"); fflush(stdout)
            #endif
            Log.wake.error("continued transcription: expired by the system")
        }

        let coordinator = TranscriptCoordinator.shared

        // 1 Hz, driven by the coordinator's real status. It has to keep moving even while the model
        // loads and before the first word lands — a flat completedUnitCount is exactly what gets us
        // marked stalled — so creep forward slowly until real progress overtakes the floor. Five
        // updates per second added 18,000 main-actor wakeups/hour without making the system UI
        // materially more informative.
        let ticker = Task { @MainActor in
            var floor: Int64 = 0
            var shownMinutes = -1
            while !Task.isCancelled {
                var real: Int64 = 0
                if case .working(let fraction) = coordinator.status(for: episode.id) {
                    real = Int64(fraction * 10_000)
                }
                if real <= floor, floor < 100 { floor += 1 }   // warm-up creep, capped at 1%
                progress.completedUnitCount = max(real, floor)

                // updateTitle is an IPC round-trip that redraws the system UI. DTS is explicit that
                // over-updating progress "can VERY easily steal a LOT more performance than you'd
                // realize" — and this was firing 5×/sec for the whole run, competing with the very
                // transcription it was reporting on. Only redraw when the displayed minute changes.
                if let eta = coordinator.eta(for: episode.id), eta > 5 {
                    let minutes = Int((eta / 60).rounded())
                    if minutes != shownMinutes {
                        shownMinutes = minutes
                        task.updateTitle("Transcribing",
                                         subtitle: "\(minutes) min left · \(episode.title)")
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { ticker.cancel() }

        let transcript = await coordinator.ensureTranscript(for: episode, keepAwake: false,
                                                            isCancelled: { expired })
        ticker.cancel()

        #if DEBUG
        print("[continued] finished — words: \(transcript?.words.count ?? 0), expired: \(expired)")
        fflush(stdout)
        #endif

        if let transcript {
            progress.completedUnitCount = progress.totalUnitCount
            Log.wake.notice("continued transcription: done — \(transcript.words.count) words")
            task.setTaskCompleted(success: true)
        } else {
            // Expired mid-run. The partial is checkpointed so nothing is lost, but the work didn't
            // finish — and DTS is explicit that failing to report progress is a failure state, not
            // a flow-control tool.
            task.setTaskCompleted(success: false)
        }
    }
}
#endif
