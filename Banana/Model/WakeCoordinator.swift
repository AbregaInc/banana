import Foundation

/// Owns the audio/wake object graph as a shared singleton so BOTH the SwiftUI app
/// and the background AlarmKit stop intent drive the *same* `PlayerController`.
///
/// This is what lets the wake source start when you tap **Stop** on the Lock Screen
/// without ever foregrounding the app: the stop intent is background-launched into
/// the app's process and calls `startWake()` here, which loads the saved wake source
/// and library (both persisted to disk) and plays — no UI required.
@MainActor
final class WakeCoordinator {
    static let shared = WakeCoordinator()

    let library = PodcastLibrary()
    let wake = WakeStore()
    let downloads = DownloadManager()
    let music = MusicController()
    let player = PlayerController()
    /// Ad-skip plans live in the same graph as playback, for the same reason everything else
    /// here does: a background AlarmKit wake plays through this `PlayerController` with no UI
    /// anywhere, and an episode that skips its ads only in the foreground would be a stranger
    /// bug than not skipping them at all.
    let skipPlans = SkipPlanService()

    /// Alarm state, the Stop intent, and foreground activation can all report the same wake.
    /// Keep one start in flight so they cannot race the singleton system music player's queue.
    private var wakeStartTask: Task<Void, Never>?

    private init() {
        player.attach(library: library)
        player.downloads = downloads
        player.skipPlans = skipPlans
        downloads.library = library
        downloads.skipPlans = skipPlans
        skipPlans.library = library
        skipPlans.downloads = downloads
        // A plan can land mid-episode — a streamed first listen gets its ad-server headers a few
        // hundred milliseconds in, while the pre-roll is still playing — so the player is told,
        // rather than asked once at play time and never again.
        // Captured strongly on purpose: this graph is a singleton that outlives the process's
        // interest in it, and skipPlans holds no strong reference back (`player.skipPlans` and
        // `downloads.skipPlans` are both weak), so there is no cycle to break.
        let playerRef = player
        let downloadsRef = downloads
        skipPlans.onPlanReady = { episodeID in playerRef.adoptSkipPlan(for: episodeID) }
        skipPlans.onPlanShareable = { episodeID in downloadsRef.pushSkipPlanToWatch(episodeID) }
        LaunchClock.mark("wakegraph.init")   // library+downloads+player+music built by here
    }

    /// Start the wake-slot source. Idempotent — safe to call from both the stop
    /// intent and the on-open path without double-starting.
    ///
    /// Awaits the library's async load first: the stop intent background-launches the process,
    /// and the catalogue now decodes off-main — playing before it lands would find an empty
    /// library and silently wake to nothing.
    ///
    /// `async`, deliberately: the AlarmKit stop intent AWAITS this, and its process is only kept
    /// alive until `perform()` returns. A fire-and-forget Task here would let the intent complete
    /// before playback activates the audio session, and iOS could suspend the freshly-launched
    /// process before the wake audio ever started.
    func startWake(reason: String) async {
        if let wakeStartTask {
            PlaybackDiagnostics.shared.log("WAKE", "join in-flight start reason=\(reason)")
            await wakeStartTask.value
            return
        }

        let task = Task { @MainActor [self] in
            await performStartWake(reason: reason)
        }
        wakeStartTask = task
        await task.value
        wakeStartTask = nil
    }

    private func performStartWake(reason: String) async {
        let diagnostic = DiagnosticJournal.shared.startSpan(
            "alarm.wakePlayback",
            attributes: ["trigger": reason])
        // Journal breadcrumb: Log.wake lines don't reach playback.log, so an intent-path wake
        // used to leave no trace there at all (07-16: diagnosable only by session side effects).
        PlaybackDiagnostics.shared.log("WAKE", "start reason=\(reason)")
        await library.whenLoaded()
        DiagnosticJournal.shared.checkpoint(
            diagnostic,
            "podcast_library_loaded")
        await startWakeLoaded(reason: reason)
        let started = player.isPlaying || music.wakePlaying != nil
        DiagnosticJournal.shared.finish(
            diagnostic,
            status: started ? .succeeded : .failed,
            reason: started ? "playback_started" : "no_playback_started",
            attributes: [
                "podcast_playing": player.isPlaying ? "true" : "false",
                "music_playing": music.wakePlaying == nil ? "false" : "true",
            ])
    }

    private func startWakeLoaded(reason: String) async {
        if player.hasCurrent && player.isPlaying {
            Log.wake.notice("startWake(\(reason, privacy: .public)): already playing — skipping")
            return
        }
        // Routines is the source of truth: play the Wake cue's pool. Fall back to the
        // configured wake slot (which also carries the Apple Music path).
        if let cue = RoutineStore.shared.wakeCue {
            if let next = library.nextInPool(cue.podcastIDs) {
                Log.wake.notice("startWake(\(reason, privacy: .public)): from Wake cue pool")
                player.play(next.episode, in: next.podcast, routineID: cue.id)
                return
            }
            if let item = cue.musicItem {
                Log.wake.notice("startWake(\(reason, privacy: .public)): from Wake cue Apple Music")
                await music.playWake(item)   // awaited: see the async note above
                return
            }
        }
        await playLoaded(slot: .wake, reason: reason, sleepTimerMinutes: nil)
    }

    /// Play a given slot's configured source (podcast next-episode or Apple Music),
    /// optionally with a sleep timer (for the Sleep slot). Waits for the library load
    /// (see startWake) — cheap no-op once loaded.
    func play(slot: SourceSlot, reason: String, sleepTimerMinutes: Int? = nil,
              routineID: UUID? = nil) async {
        await library.whenLoaded()
        await playLoaded(slot: slot, reason: reason, sleepTimerMinutes: sleepTimerMinutes,
                         routineID: routineID)
    }

    private func playLoaded(slot: SourceSlot, reason: String, sleepTimerMinutes: Int?,
                            routineID: UUID? = nil) async {
        let sourceRoutineID = routineID
            ?? RoutineStore.shared.routines.first(where: { $0.enabled && $0.slot == slot })?.id
        switch wake.source(for: slot) {
        case .podcast(let id):
            guard let podcast = library.podcast(id) else {
                Log.wake.error("play(\(slot.rawValue, privacy: .public)/\(reason, privacy: .public)): podcast not in library")
                return
            }
            Log.wake.notice("play(\(slot.rawValue, privacy: .public)/\(reason, privacy: .public)): \"\(podcast.title, privacy: .public)\"")
            player.playNext(in: podcast, autoSleepEligible: false,
                            routineID: sourceRoutineID)   // wake/sleep manage their own timer
        case .appleMusic(let item):
            Log.wake.notice("play(\(slot.rawValue, privacy: .public)/\(reason, privacy: .public)): Apple Music")
            await music.playWake(item)
        case nil:
            Log.wake.notice("play(\(slot.rawValue, privacy: .public)/\(reason, privacy: .public)): no source configured")
            return
        }
        if let minutes = sleepTimerMinutes { player.startSleepTimer(minutes: minutes) }
    }
}
