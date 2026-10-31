import AVFoundation
import MediaPlayer
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Wraps a single `AVPlayer` for streaming podcast episodes. Handles the audio
/// session (so it plays with the screen locked), Lock Screen / Control Center
/// controls, resume positions, and advancing to the next episode in a feed's
/// chosen direction.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentPodcastID: UUID?
    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var speed: Double = 1.0
    /// The cue that explicitly started this playback. A shared podcast in a cue's
    /// pool is not enough to infer that the cue itself is running.
    @Published private(set) var activeRoutineID: UUID?

    /// The playhead lives on its own object so that a 1 Hz tick doesn't invalidate every view that
    /// merely wants to know which episode is loaded. See PlaybackClock.
    let clock = PlaybackClock()

    /// Unchanged as an API — but no longer a `@Published` on *this* object, so writing it once a
    /// second no longer re-renders the entire app.
    var currentTime: Double {
        get { clock.time }
        set { clock.time = newValue }
    }
    var duration: Double {
        get { clock.duration }
        set { if clock.duration != newValue { clock.duration = newValue } }
    }

    /// The AVPlayer's EXACT current time. `currentTime`/`clock.time` deliberately tick at 1 Hz (to
    /// avoid re-rendering the whole app every second — see PlaybackClock), which is too coarse for
    /// karaoke highlighting: at ~4 words/sec it jumps ~4 words a tick. The transcript view samples
    /// this directly at ~10 Hz instead. Reads the player synchronously (accurate across seek/rate);
    /// falls back to the clock when the item has no valid time yet.
    func preciseTime() -> Double {
        if isSeeking { return seekTarget }
        let t = player.currentTime().seconds
        return t.isFinite ? t : clock.time
    }

    /// Preset playback rates offered in the UI.
    static let speedOptions: [Double] = PlaybackSpeeds.options

    private let player = AVPlayer()
    private weak var library: PodcastLibrary?
    weak var downloads: DownloadManager?
    weak var history: ListenHistoryStore?
    weak var settings: AppSettings?

    /// Fired on every now-playing change so the Watch remote can stay in sync.
    var onStateChange: (() -> Void)?

    /// Fired at end-of-listening moments (pause / stop / finish / switch) so playback
    /// position + completion can sync to the Watch.
    var onProgressCommit: ((_ episodeID: String, _ position: Double, _ duration: Double, _ completed: Bool) -> Void)?

    /// Fired when the phone starts playing, so the Watch can stop its own local playback.
    /// The two players are independent — whoever hits play last owns your ears.
    var onTakeOver: (() -> Void)?

    private func reportProgress(completed: Bool) {
        guard let ep = currentEpisode else { return }
        onProgressCommit?(ep.id, preciseTime(), duration, completed)
    }
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var timeControlObserver: NSKeyValueObservation?
    private var stallRetry: Timer?
    private var recoveryConfirm: Timer?
    private var stallAttempts = 0
    private var stallBegan: Date?
    private var isRebuilding = false
    private var lastControlStatus: AVPlayer.TimeControlStatus = .paused
    private var lastHeartbeatAt = Date()
    private var callbacksSinceHeartbeat = 0
    /// Visible UI gets a one-second clock; a locked/background phone gets only the 30-second
    /// crash-safety heartbeat. Publishing a playhead nobody can see 3,600 times per hour was a
    /// measurable screen-off main-actor and SwiftUI cost.
    private var interfaceActive = true
    /// True while an AVPlayer seek is in flight. The periodic time observer reports the OLD position
    /// until the seek lands (seconds, on a 4-hour file), so without this it snaps the scrubber back
    /// and you get the bounce seen when skipping an hour.
    private var isSeeking = false
    private var seekTarget: Double = 0
    private var artwork: MPMediaItemArtwork?
    private var artworkURL: URL?

    // MARK: - Automatic ad skipping

    /// Plans, corrections, and the job of getting a plan built. Weak: `WakeCoordinator` owns it,
    /// so a headless background launch has one too.
    weak var skipPlans: SkipPlanService?

    /// The decision half — see `SkipPlaybackEngine`. A value, held here and nowhere else.
    private var skip = SkipPlaybackEngine()

    /// What was just skipped, for the brief non-modal notice and its undo. Nil most of the time.
    @Published private(set) var skipNotice: SkipNotice?
    private var skipNoticeDismissal: Task<Void, Never>?

    /// Fires exactly when the playhead reaches the start of an automatic span.
    ///
    /// The periodic observer cannot do this job: it runs at 1 Hz only while the interface is
    /// visible and drops to every 30 seconds otherwise, and a podcast is mostly listened to with
    /// the screen off — which would mean sitting through most of an ad before anything noticed.
    /// A boundary observer fires at the time asked for whatever the app is doing.
    private var skipBoundaryObserver: Any?

    /// One skip, as the listener is told about it.
    struct SkipNotice: Identifiable, Equatable {
        let id: UUID
        /// "Ad", "Ad + Intro" — what the plan says it took.
        var label: String
        var seconds: Double
        /// The start of what was taken, so undo plays it rather than merely rewinding a bit.
        var returnTo: Double
        var spans: [SkipSpan]

        var summary: String {
            let rounded = Int(seconds.rounded())
            guard rounded >= 60 else { return "Skipped \(max(1, rounded))s of \(label.lowercased())" }
            let minutes = rounded / 60, seconds = rounded % 60
            let length = seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
            return "Skipped \(length) of \(label.lowercased())"
        }
    }

    init() {
        #if os(iOS)
        interfaceActive = UIApplication.shared.applicationState == .active
        #endif
        // The audio-session category (mediaserverd) and remote-command registration
        // (mediaremoted) are XPC round-trips that sat in the first-frame path — and neither
        // matters until something can play. Deferred to one post-paint task; every play path
        // also configures on demand (activateSession → configureAudioSessionIfNeeded), so even
        // a background wake launch that beats the task gets a correct session.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.configureAudioSessionIfNeeded()
            self.setupRemoteCommandsIfNeeded()
        }
        installTimeObserver()
        observeTimeControl()
        LaunchClock.mark("player.init")
    }

    private var sessionConfigured = false
    private func configureAudioSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        configureAudioSession()
    }

    private var remoteCommandsConfigured = false
    private func setupRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        setupRemoteCommands()
    }

    /// Pairs both directions at once. The library's back-reference is weak and exists so a remote
    /// progress merge can ask whether this device is actively playing something else before it
    /// takes over "current episode" — setting it here means it can never be half-wired.
    func attach(library: PodcastLibrary) {
        self.library = library
        library.player = self
    }

    /// Reconfigure the AVPlayer callback cadence when the app becomes visible/hidden. The exact
    /// AVPlayer playhead remains the source of truth while the published clock is intentionally
    /// frozen off-screen.
    func setInterfaceActive(_ active: Bool) {
        guard interfaceActive != active else { return }
        interfaceActive = active
        if active, hasCurrent { currentTime = preciseTime() }
        installTimeObserver()
    }

    /// The show currently playing, for anything that needs to name it (e.g. a voice note's context).
    var currentPodcastTitle: String? {
        currentPodcastID.flatMap { library?.podcast($0)?.title }
    }

    var hasCurrent: Bool { currentEpisode != nil }

    #if DEBUG
    /// One-line playback state for memory diagnostics — including how many seconds
    /// the AVPlayer has buffered (unbounded growth here = a streaming buffer leak).
    var debugSummary: String {
        guard let item = player.currentItem else { return "player:idle" }
        let source = ((item.asset as? AVURLAsset)?.url.isFileURL ?? false) ? "local" : "stream"
        let buffered = item.loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        return String(format: "player:%@/%@ buf:%.0fs t:%.0f/%.0f",
                      isPlaying ? "play" : "pause", source, buffered, currentTime, duration)
    }
    #endif

    #if PERFORMANCE_TESTING
    /// Raw AVPlayer state for the device harness. `isPlaying` is the user's requested state;
    /// this value proves the media pipeline is actually advancing rather than stalled/waiting.
    var performanceIsActuallyPlaying: Bool {
        player.timeControlStatus == .playing
    }

    var performanceSourceIsLocal: Bool {
        (player.currentItem?.asset as? AVURLAsset)?.url.isFileURL ?? false
    }

    private(set) var performancePlaybackStallCount = 0
    #endif

    // MARK: - Public playback API

    /// A resume an interruption owes, handed to whoever takes it — a voice note starting during
    /// the interruption, so the podcast comes back when the note ends rather than under it.
    func takePendingInterruptionResume() -> Bool {
        defer { resumeAfterInterruption = false }
        return resumeAfterInterruption
    }

    /// Play a feed's next unplayed episode (in its direction), resuming if partway through.
    func playNext(in podcast: Podcast, autoSleepEligible: Bool = true, routineID: UUID? = nil) {
        guard let episode = podcast.nextEpisode(voiceOf: NarratorVoiceStore.shared.lookup()) else {
            Log.wake.error("playNext: no next episode in \"\(podcast.title, privacy: .public)\" (\(podcast.episodeCount) episodes)")
            return
        }
        play(episode, in: podcast, autoSleepEligible: autoSleepEligible, routineID: routineID)
    }

    /// `autoSleepEligible` is false for wake/alarm playback so the bedtime auto-arm
    /// can never fade out the morning wake.
    func play(_ episode: Episode, in podcast: Podcast, autoSleepEligible: Bool = true,
              routineID: UUID? = nil) {
        Telemetry.shared.record(.feature(.podcastPlayed))
        // Save progress of whatever was playing before switching (and sync it). An episode
        // switch is a moment lists can show something new, so fold the live playhead into the
        // published library here (one publish) — the 30 s heartbeat itself stays quiet.
        commitProgress()
        library?.commitLiveProgress()
        reportProgress(completed: false)

        onTakeOver?()   // the phone owns playback now — silence the Watch's local player

        currentPodcastID = podcast.id
        _ = orderedEpisodes(for: podcast)
        currentEpisode = episode
        activeRoutineID = routineID
        duration = episode.duration ?? 0
        speed = podcast.speed

        // Prefer the downloaded file when available (offline + faster start).
        pausedByRouteLoss = nil
        cancelStallRecovery()
        activateSession("play")   // the session is idle until we play

        let url = downloads?.localURL(for: episode.id) ?? episode.audioURL
        loadSkipPlan(for: episode, in: podcast, streaming: !url.isFileURL)
        PlaybackDiagnostics.shared.log("PLAY \"\(episode.title)\"",
                                       "\(url.isFileURL ? "local" : "STREAM") \(PlaybackDiagnostics.sessionSummary())")
        let item = AVPlayerItem(url: url)
        // Preserve pitch when playing faster/slower (tuned for speech).
        item.audioTimePitchAlgorithm = .timeDomain
        // Leave preferredForwardBufferDuration at 0. That is AVPlayer's power-aware default.
        // This property is a requested buffer target, not a cap: setting it to 120 made streamed
        // episodes aggressively maintain two minutes of read-ahead and increased radio demand.
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        observeFailure(of: item)
        observeStall(of: item)

        // Read the resume position from the library's freshest copy (post-fold) — the `podcast`
        // parameter is the caller's value copy and can predate the position we just committed.
        let currentPodcast = library?.podcast(podcast.id) ?? podcast
        var resume = currentPodcast.startPosition(for: episode)
        // The show's fixed pre-roll setting and an automatic plan are two answers to the same
        // question, and applying both starts playback past the plan's own spans — so the plan
        // never fires and whatever sat between the guess and the truth is lost. The plan wins
        // wherever it has something to say about that stretch. Guarded on the same condition
        // `startPosition` uses, so resuming partway through is untouched either way.
        if currentPodcast.resumePosition(for: episode.id) <= 1,
           skip.supersedesFixedPreRoll(ofSeconds: currentPodcast.autoSkipSeconds) {
            resume = currentPodcast.resumePosition(for: episode.id)
        }
        if resume > 1 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        player.playImmediately(atRate: Float(speed))
        installSkipBoundaries()
        // `resume`, not the player's own clock: the seek above may not have landed yet, and an
        // AVPlayer still reporting 0 would make this "skip the pre-roll" for someone resuming an
        // hour in — a rewind, dressed up as an ad skip.
        evaluateSkip(reason: "play", at: resume)
        isPlaying = true
        lastHeartbeatAt = Date()
        callbacksSinceHeartbeat = 0
        PlaybackDiagnostics.shared.noteAlive(
            playing: true, at: resume, episode: episode.title,
            podcastID: podcast.id, episodeID: episode.id)
        armRecoveryIfNotPlaying()   // pressing play in a dead spot must still recover later
        library?.updateProgress(podcastID: podcast.id, episodeID: episode.id, position: resume)
        library?.saveLiveProgressCheckpoint(enqueueCloud: true)
        // Fold the NEW episode in immediately: leaving it un-folded kept the struct's
        // currentEpisodeID pointing at the previous episode for the whole session, so anything
        // reading nextEpisode()/nextInPool mid-playback ("Play next", starting a cue) picked the
        // OLD episode. One publish per switch — the 30 s heartbeat stays quiet.
        library?.commitLiveProgress()
        CloudProgressSync.shared.flushNow(reason: "switch")
        history?.beginSession(podcastID: podcast.id, episodeID: episode.id,
                              podcastTitle: podcast.title, episodeTitle: episode.title,
                              artworkURL: podcast.artworkURL)
        loadArtwork(podcast.artworkURL)
        updateNowPlaying()
        if autoSleepEligible { maybeArmAutoSleepTimer() }
    }

    /// At bedtime (after the configured hour, or before 5 AM), auto-arm the sleep
    /// timer so podcasts started at night don't play until morning. Cancelable, and
    /// skipped if a timer is already set.
    private func maybeArmAutoSleepTimer() {
        guard let settings, settings.autoSleepTimer, sleepTimerEnd == nil else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight = hour >= settings.autoSleepAfterHour || hour < 5
        guard isNight else { return }
        Log.wake.notice("auto-arming sleep timer (\(settings.sleepTimerMinutes)m) — night playback")
        startSleepTimer(minutes: settings.sleepTimerMinutes)
    }

    /// Fetch the show artwork for the Lock Screen / Control Center panel, reusing
    /// the shared image cache so it isn't re-downloaded if the UI already has it.
    private func loadArtwork(_ url: URL?) {
        guard let url, url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        Task { [weak self] in
            guard let image = await ImageCache.shared.image(for: url) else { return }
            await MainActor.run {
                guard let self, self.artworkURL == url else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlaying()
            }
        }
    }

    func togglePlayPause(reason: String = "user") { setPlaying(!isPlaying, reason: reason) }

    /// Rebuild the last abruptly-terminated item without activating the audio session or playing.
    /// An app update, crash, or jetsam should look like a pause when the person next opens the app.
    @discardableResult
    func restorePaused(_ recovery: PlaybackDiagnostics.InterruptedPlayback) -> Bool {
        guard !hasCurrent, let library else { return false }
        let exact: (Podcast, Episode)? = {
            guard let podcastID = recovery.podcastID,
                  let episodeID = recovery.episodeID,
                  let podcast = library.podcast(podcastID),
                  let episode = podcast.episode(episodeID)
            else { return nil }
            return (podcast, episode)
        }()
        // Upgrade path from builds whose alive breadcrumb only stored a human-readable title:
        // progress.json still knows every feed's current episode, so choose the most recently
        // played valid one. Future breadcrumbs take the exact-ID path above.
        let fallback: (Podcast, Episode)? = library.podcasts
            .compactMap { podcast -> (Podcast, Episode)? in
                guard let id = podcast.currentEpisodeID,
                      let episode = podcast.episode(id),
                      !podcast.completed.contains(id) else { return nil }
                return (podcast, episode)
            }
            .max { ($0.0.lastPlayedAt ?? .distantPast) < ($1.0.lastPlayedAt ?? .distantPast) }
        guard let (podcast, episode) = exact ?? fallback else { return false }

        currentPodcastID = podcast.id
        _ = orderedEpisodes(for: podcast)
        currentEpisode = episode
        activeRoutineID = nil
        duration = episode.duration ?? 0
        speed = podcast.speed
        let storedPosition = podcast.resumePosition(for: episode.id)
        let position = exact == nil ? storedPosition : max(recovery.position, storedPosition)
        currentTime = position

        let url = downloads?.localURL(for: episode.id) ?? episode.audioURL
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        observeFailure(of: item)
        observeStall(of: item)
        if position > 1 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        // No fixed-pre-roll question here: a restore always resumes a real position. Load the plan
        // anyway so pressing play picks up mid-episode spans without waiting for a rebuild.
        loadSkipPlan(for: episode, in: podcast, streaming: !url.isFileURL)
        installSkipBoundaries()

        isPlaying = false
        loadArtwork(podcast.artworkURL)
        updateNowPlaying()
        onStateChange?()
        PlaybackDiagnostics.shared.log(
            "RESTORED PAUSED",
            "\"\(episode.title)\" t=\(Int(position))s \(url.isFileURL ? "local" : "STREAM")")
        return true
    }

    /// Fully stop and clear playback — dismisses the now-playing card and clears the
    /// "Now" cue. (Pause only pauses; this exits the playing state entirely.)
    func stop(reason: String = "user") {
        let stoppedAt = preciseTime()
        currentTime = stoppedAt
        PlaybackDiagnostics.shared.log("STOP", "by=\(reason) t=\(Int(stoppedAt))s")
        PlaybackDiagnostics.shared.noteAlive(playing: false, at: stoppedAt, episode: "")
        commitProgress()                                // save resume position first
        library?.commitLiveProgress()
        CloudProgressSync.shared.flushNow(reason: "stop")
        reportProgress(completed: false)
        history?.endSession()
        isPlaying = false        // before pause(): its KVO fires synchronously (see setPlaying)
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentEpisode = nil
        currentPodcastID = nil
        activeRoutineID = nil
        currentTime = 0
        duration = 0
        cancelSleepTimer()
        cancelStallRecovery()
        clearSkipState()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        onStateChange?()
    }

    /// Discrete play/pause (used by Siri, the Lock Screen, and the Watch remote so
    /// "play" always plays and "pause" always pauses — not a blind toggle).
    ///
    /// `reason` is recorded in the playback journal. Every caller names itself, so when audio
    /// stops in your pocket the log says *who* stopped it rather than just *that* it stopped.
    func setPlaying(_ shouldPlay: Bool, reason: String = "user") {
        guard hasCurrent else { return }
        if shouldPlay {
            guard !isPlaying else { return }
            onTakeOver?()                                   // resuming here also silences the Watch
            if sleepTimerEnd == nil { player.volume = 1 }   // clear any leftover fade
            cancelStallRecovery()
            activateSession("resume (\(reason))")           // resume needs an active session
            player.playImmediately(atRate: Float(speed))
            isPlaying = true
            beginCurrentListenSession()
            let resumedAt = preciseTime()
            PlaybackDiagnostics.shared.noteAlive(
                playing: true, at: resumedAt, episode: currentEpisode?.title ?? "?",
                podcastID: currentPodcastID, episodeID: currentEpisode?.id)
            armRecoveryIfNotPlaying()
            PlaybackDiagnostics.shared.log("RESUME", "by=\(reason) t=\(Int(resumedAt))s")
        } else {
            guard isPlaying else { return }
            // Flag BEFORE pause(): the .paused KVO fires synchronously inside pause(), and the
            // observer treats ".paused while isPlaying" as an external stop. With the old order,
            // a stall give-up re-entered itself through that path dozens of times (07-15 23:25,
            // followed by a crash). Every pause site in this class keeps this order.
            isPlaying = false
            player.pause()
            cancelStallRecovery()
            commitProgress()
            library?.commitLiveProgress()                    // pause = a moment lists should update
            CloudProgressSync.shared.flushNow(reason: "pause")   // the radio commit point (no-op when sync is off)
            reportProgress(completed: false)
            history?.endSession()
            let pausedAt = preciseTime()
            if interfaceActive { currentTime = pausedAt }
            PlaybackDiagnostics.shared.log("PAUSE", "by=\(reason) t=\(Int(pausedAt))s")
            PlaybackDiagnostics.shared.noteAlive(playing: false, at: pausedAt, episode: "")
        }
        updateNowPlaying()
    }

    // MARK: - Sleep timer

    @Published private(set) var sleepTimerEnd: Date?
    private var sleepTimer: Timer?
    private var fadeTimer: Timer?

    var sleepTimerRemaining: TimeInterval? {
        sleepTimerEnd.map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Play, then fade out and pause after `minutes` — for falling asleep.
    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        guard minutes > 0 else { return }
        sleepTimerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOutAndPause() }
        }
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate(); sleepTimer = nil
        fadeTimer?.invalidate(); fadeTimer = nil
        sleepTimerEnd = nil
        player.volume = 1
    }

    private func fadeOutAndPause() {
        sleepTimer = nil
        sleepTimerEnd = nil
        let steps = 20
        var i = 0
        let startVolume = player.volume
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                i += 1
                self.player.volume = startVolume * Float(max(0, 1 - Double(i) / Double(steps)))
                if i >= steps {
                    timer.invalidate()
                    self.fadeTimer = nil
                    if self.isPlaying {
                        let pausedAt = self.preciseTime()
                        PlaybackDiagnostics.shared.log("PAUSE", "by=sleep timer t=\(Int(pausedAt))s")
                        PlaybackDiagnostics.shared.noteAlive(playing: false, at: pausedAt, episode: "")
                        self.isPlaying = false
                        self.player.pause()
                        self.commitProgress()
                        self.history?.endSession()
                    }
                    self.player.volume = 1   // reset for next play
                    self.updateNowPlaying()
                }
            }
        }
    }

    /// Change playback speed. Applies live if playing, and saves it as the
    /// current feed's default so future episodes use it too.
    func setSpeed(_ newSpeed: Double) {
        speed = newSpeed
        if isPlaying { player.rate = Float(newSpeed) }
        if let pid = currentPodcastID { library?.setSpeed(newSpeed, for: pid) }
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        guard hasCurrent else { return }
        let target = max(0, preciseTime() + seconds)
        seek(to: target)
    }

    /// A seek the LISTENER asked for — a scrubber, a ±15/30 button, a Lock Screen command, a tap
    /// on a transcript phrase or a note's timestamp.
    ///
    /// This is the only door into the ad-skip learning loop, and that is the point. The one signal
    /// the feature has is "the listener rewound into audio we took", so a jump that automatic
    /// skipping made itself must never arrive here: it lands the playhead exactly where a rewind
    /// would be measured from, so feeding it back would teach every detector that its own
    /// successes were mistakes, and the feature would switch itself off show by show. Rather than
    /// leaving that as a rule to remember, the two are different functions: the jump calls
    /// `performSeek` directly and there is no path from it to `noteUserSeek`.
    func seek(to time: Double) {
        let target = max(0, time)
        noteUserSeek(to: target)
        performSeek(to: target)
    }

    /// A seek nothing asked for: the ad-skip jump, and adopting the Watch's playhead on handoff.
    /// Deliberately not `seek(to:)` — see the note there.
    private func performSeek(to target: Double,
                             toleranceBefore: Double = 1,
                             toleranceAfter: Double = 1) {
        isSeeking = true
        seekTarget = target
        currentTime = target          // show the destination immediately, not the old position
        updateNowPlaying()
        // Tolerant seek: exact (.zero tolerance) seeks re-decode from the previous keyframe and are
        // markedly slower on a long file — the scrub wants responsiveness, a second's imprecision is
        // invisible. If a newer seek arrives first, AVPlayer cancels this one (finished == false) and
        // we leave isSeeking to the newer call.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: toleranceBefore, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: toleranceAfter, preferredTimescale: 600)) { [weak self] finished in
            MainActor.assumeIsolated {
                guard let self, finished, self.seekTarget == target else { return }
                self.isSeeking = false
                if self.pendingSkipRecheck {
                    self.pendingSkipRecheck = false
                    // Evaluate from where we SOUGHT TO, not from the player's clock.
                    //
                    // `isSeeking` has just been cleared, so `preciseTime()` has stopped returning
                    // `seekTarget` and reads the item instead — and while an item is still loading
                    // (the log's `buffered=0s`) that clock lags behind the seek that just landed.
                    // The recheck then re-evaluated a position still inside the span it had just
                    // left, computed the same destination, seeked to the same place, and re-armed
                    // itself: a seek storm at ~15/s that pinned background CPU near 64% and hammered
                    // an AVPlayer whose item was not ready yet. This is the exact case the `at:`
                    // parameter was added for; it simply was not being passed.
                    self.evaluateSkip(reason: "after skip", at: target)
                }
            }
        }
    }

    /// Continue from where the Watch actually was when we took playback over. Forward-only,
    /// so a late or stale report can never rewind a listener who is already further along.
    ///
    /// `performSeek`, not `seek`: nobody reached for anything here, and a handoff arriving inside
    /// the window after a skip must not read as an objection to it.
    func adoptRemotePosition(_ position: Double) {
        guard hasCurrent, position > preciseTime() + 3 else { return }
        performSeek(to: position)
        commitProgress()
        evaluateSkip(reason: "watch handoff")
    }

    /// Persist the current resume position (call when app backgrounds/quits).
    func commitProgress(checkpointOnly: Bool = false) {
        guard let pid = currentPodcastID, let ep = currentEpisode else { return }
        let position = preciseTime()
        if interfaceActive, currentTime != position { currentTime = position }
        library?.updateProgress(podcastID: pid, episodeID: ep.id, position: position)
        if checkpointOnly {
            library?.saveLiveProgressCheckpoint()
        } else {
            library?.saveProgressSnapshot()
        }
    }

#if os(iOS)
    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
        } catch {
            PlaybackDiagnostics.shared.log("session.setCategory FAILED", "\(error)")
        }
        // Deliberately NOT activated here. PlayerController is built eagerly at launch — including
        // on headless background launches (the overnight task, a Watch file transfer, an AlarmKit
        // intent) — and an active .playback session plus the `audio` background mode tells iOS the
        // app is producing audio, so it is never suspended. Activate when something actually plays.

        // Auto-resume after an interruption (Siri reading a text, a phone call, etc.).
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleInterruption(note) }
        }

        // Headphones pulled out / Bluetooth dropped. iOS pauses the player behind our back, so
        // without this our `isPlaying` (and the Lock Screen) would keep claiming we're playing.
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleRouteChange(note) }
        }

        // The media daemon can die and be restarted. When it does, the session and every player
        // object built on it are dead — silently. Nothing recovers without being rebuilt from
        // scratch, and nothing else in the app was listening for this at all.
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                               object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                PlaybackDiagnostics.shared.log("MEDIA SERVICES RESET", "rebuilding session + player")
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                guard self.isPlaying else { return }
                self.activateSession("media services reset")
                self.rebuildCurrentItem()
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification,
                                               object: session, queue: .main) { _ in
            PlaybackDiagnostics.shared.log("MEDIA SERVICES LOST", "audio is dead until they come back")
        }

        // Memory pressure is the visible prelude to being jetsam-killed — the thing that stops
        // playback without ever letting us log a pause.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { _ in
            PlaybackDiagnostics.shared.log("⚠️ MEMORY WARNING", "iOS may kill the app")
        }
    }

    /// Activate the session, loudly. Every `setActive` in this file used to be a `try?`: if
    /// activation failed we lost the background-audio assertion and iOS was free to suspend us
    /// mid-episode, and the failure left no trace anywhere. Now it's recorded, and playback that
    /// starts on a dead session is a fact we can see rather than infer.
    @discardableResult
    private func activateSession(_ why: String) -> Bool {
        configureAudioSessionIfNeeded()      // category + observers must exist before activation
        setupRemoteCommandsIfNeeded()        // playing without Lock Screen controls is a bug
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            PlaybackDiagnostics.shared.log("session.setActive FAILED (\(why))", "\(error)")
            return false
        }
    }

    /// When headphones drop mid-episode, remember it — so that if the *same kind* of device comes
    /// back moments later (a Bluetooth blip, not a deliberate unplug), we can pick up where we
    /// were instead of leaving you to fish the phone out and press play.
    private var pausedByRouteLoss: Date?

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        let previous = (info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
            .map { Self.describe($0) } ?? "?"
        let now = Self.describe(AVAudioSession.sharedInstance().currentRoute)

        switch reason {
        case .oldDeviceUnavailable:
            // The thing you were listening on went away. Reflect the system's pause — and say
            // exactly what vanished, because "it stopped" and "your headphones left" look
            // identical from the outside and have completely different fixes.
            PlaybackDiagnostics.shared.log("route: DEVICE VANISHED → paused", "was \(previous) → now \(now)")
            if isPlaying {
                isPlaying = false        // before pause(): its KVO fires synchronously (see setPlaying)
                player.pause()
                history?.endSession()
                pausedByRouteLoss = Date()
                commitProgress()
                reportProgress(completed: false)
                PlaybackDiagnostics.shared.noteAlive(playing: false, at: preciseTime(), episode: "")
                updateNowPlaying()
            }

        case .newDeviceAvailable:
            PlaybackDiagnostics.shared.log("route: device available", "was \(previous) → now \(now)")
            // Came back within the blip window, and it's not the phone's own speaker? Then the
            // headphones reconnected — resume. (A deliberate unplug lands you on the speaker, and
            // Apple's guidance is right there: don't blast the room. So that case stays paused.)
            guard let lost = pausedByRouteLoss, Date().timeIntervalSince(lost) < 90,
                  hasCurrent, !isPlaying, !Self.isBuiltInSpeaker(AVAudioSession.sharedInstance().currentRoute)
            else { return }
            pausedByRouteLoss = nil
            PlaybackDiagnostics.shared.log("resuming — headphones came back", "after \(Int(Date().timeIntervalSince(lost)))s")
            setPlaying(true, reason: "headphones reconnected")

        default:
            PlaybackDiagnostics.shared.log("route change (\(Self.routeReason(reason)))", "was \(previous) → now \(now)")
        }
    }

    /// Human-readable route: "AirPods Pro (BluetoothA2DPOutput)" beats a raw enum every time.
    private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
        let outs = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        return outs.isEmpty ? "[none]" : outs.joined(separator: ", ")
    }

    private static func isBuiltInSpeaker(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.allSatisfy { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
    }

    private static func routeReason(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "new device"
        case .oldDeviceUnavailable: return "old device gone"
        case .categoryChange: return "category change"
        case .override: return "override"
        case .wakeFromSleep: return "wake from sleep"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "route reconfigured"
        @unknown default: return "reason \(r.rawValue)"
        }
    }

    private var resumeAfterInterruption = false

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // *Why* we were interrupted is the whole story: a phone call, Siri, the route being yanked,
        // or iOS suspending us are four completely different bugs that produce one identical symptom.
        var why = "unspecified"
        if let rawReason = info[AVAudioSessionInterruptionReasonKey] as? UInt,
           let r = AVAudioSession.InterruptionReason(rawValue: rawReason) {
            switch r {
            case .default:         why = "another app took audio"
            case .builtInMicMuted: why = "mic muted"
            case .routeDisconnected: why = "route disconnected"
            default:               why = "reason \(rawReason)"
            }
        }

        switch type {
        case .began:
            resumeAfterInterruption = isPlaying   // remember we were playing
            PlaybackDiagnostics.shared.log("INTERRUPTION began (\(why))",
                                           "wasPlaying=\(isPlaying) t=\(Int(preciseTime()))s \(PlaybackDiagnostics.sessionSummary())")
            if isPlaying {
                isPlaying = false
                // An interruption can last long enough for iOS to suspend us. Treat its beginning
                // as a real commit point instead of relying on a later "ended" callback that may
                // never arrive before a kill.
                commitProgress()
                library?.commitLiveProgress()
                reportProgress(completed: false)
                history?.endSession()
                PlaybackDiagnostics.shared.noteAlive(
                    playing: false, at: preciseTime(), episode: "")
                updateNowPlaying()
            }   // reflect the system pause
        case .ended:
            // Resume if we were playing — for spoken audio the listener wants continuity,
            // even when the system doesn't set `.shouldResume` (e.g. after Siri).
            PlaybackDiagnostics.shared.log("INTERRUPTION ended (\(why))",
                                           "willResume=\(resumeAfterInterruption) \(PlaybackDiagnostics.sessionSummary())")
            // Owed by this player, or by a voice note the interruption cut short (it hands its
            // resume here rather than restarting the podcast mid-interruption).
            let owed = resumeAfterInterruption || VoiceNoteStore.shared.takeResumeWhenInterruptionEnds()
            resumeAfterInterruption = false
            if owed && hasCurrent {
                if VoiceNoteStore.shared.isRecording {
                    // A note is recording (Siri's "Record a note" starts one mid-interruption):
                    // resuming now would play the podcast into the mic. The note resumes it when
                    // it ends.
                    VoiceNoteStore.shared.resumePlaybackWhenDone()
                } else {
                    setPlaying(true, reason: "interruption ended")
                }
            }
        @unknown default:
            break
        }
    }

#else
    // MARK: - Audio session

    // There isn't one on a Mac.
    //
    // AVAudioSession is an iOS framework: it exists because a phone has one pair of ears, a ringer,
    // a lock screen and a Watch all competing for them. A Mac just plays — routing, ducking and
    // interruptions are the system's business, not the app's. So the session lifecycle, the route
    // and interruption handling, and the media-services-reset recovery are all iPhone concerns, and
    // the Mac gets no-ops rather than a pantomime of a session it doesn't have.
    private func configureAudioSession() {}

    @discardableResult
    private func activateSession(_ why: String) -> Bool { true }

    private var resumeAfterInterruption = false

    /// Unused on the Mac — nothing yanks the route out from under you — but `play()` clears it, and
    /// a stub property is cheaper than guarding every touch point in shared code.
    private var pausedByRouteLoss: Date?

#endif

    // MARK: - Time observation

    private func installTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        let seconds = interfaceActive ? 1.0 : 30.0
        let interval = CMTime(seconds: seconds, preferredTimescale: 600)
        // The observer is delivered on the main queue, so we're already on the
        // main actor — assert it so the @Sendable closure can touch main-actor state.
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                // Don't let a stale mid-seek time yank the playhead backwards.
                guard !self.isSeeking else { return }
                if self.interfaceActive {
                    self.currentTime = time.seconds
                }
                // Last resort only. The real mechanisms are the paired boundaries around each
                // span and the re-check after a skip's own seek, both of which behave identically
                // with the screen off. This tick drops to 30 s when the interface is inactive, so
                // it could never have carried screen-off listening on its own — which is most
                // listening. It stays because it is one comparison and catches the case where the
                // plan arrives while playback is already inside a span.
                self.evaluateSkip(reason: "tick")
                // `library.updateProgress` writes into `@Published var podcasts`, so calling it on
                // every tick republished the whole catalogue once a second — and with it every view
                // observing the library. The playhead is already live on `clock`; the library only
                // needs to know where we got to when we persist. Now-playing info is NOT updated
                // here either: it's set on state changes and the system extrapolates elapsed time.
                self.callbacksSinceHeartbeat += 1
                let now = Date()
                let wallSeconds = now.timeIntervalSince(self.lastHeartbeatAt)
                if wallSeconds >= 30 {
                    let callbacks = self.callbacksSinceHeartbeat
                    self.lastHeartbeatAt = now
                    self.callbacksSinceHeartbeat = 0
                    self.commitProgress(checkpointOnly: true)
                    // A heartbeat, so being killed leaves a shape. A crash or a jetsam writes
                    // nothing at all — the journal simply stops — which is indistinguishable from
                    // a pause you've forgotten about. A beat every 30s while playing means the
                    // last line before the silence is a timestamped "still playing", and the next
                    // launch can say so out loud.
                    PlaybackDiagnostics.shared.log(
                        "… playing",
                        self.playbackTelemetry(wallSeconds: wallSeconds, callbacks: callbacks))
                    PlaybackDiagnostics.shared.noteAlive(playing: true, at: self.preciseTime(),
                                                         episode: self.currentEpisode?.title ?? "?",
                                                         podcastID: self.currentPodcastID,
                                                         episodeID: self.currentEpisode?.id)
                }
            }
        }
    }

    /// Power-relevant state, sampled on the existing 30-second persistence heartbeat. This adds
    /// no timer or wakeup of its own. In particular it records low-but-sustained CPU, which the
    /// watchdog's >=25% alarm deliberately does not log.
    private func playbackTelemetry(wallSeconds: TimeInterval, callbacks: Int) -> String {
        let item = player.currentItem
        let source = ((item?.asset as? AVURLAsset)?.url.isFileURL ?? false) ? "local" : "stream"
        let sample = PerfWatchdog.latestSample()
        let callbackRate = Double(callbacks) / max(wallSeconds, 0.001)
        let status: String
        switch player.timeControlStatus {
        case .playing: status = "playing"
        case .paused: status = "paused"
        case .waitingToPlayAtSpecifiedRate: status = "waiting"
        @unknown default: status = "unknown"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return String(
            format: "t=%ds src=%@ speed=%.2fx state=%@ cpu=%.1f%% mem=%.0fMB thermal=%@ lowPower=%@ callbacks=%.2f/s activity=%@ %@",
            Int(preciseTime()), source, speed, status, sample.cpuPercent, MemoryLog.footprintMB(),
            thermal, ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no",
            callbackRate, sample.activity, PlaybackDiagnostics.sessionSummary())
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // "Played to end" three minutes into a 45-minute episode is not an ending, it's a
                // truncated or corrupt file — and from the outside the two are indistinguishable.
                let expected = self.duration
                let position = self.preciseTime()
                let short = expected > 60 && position < expected - 30
                PlaybackDiagnostics.shared.log(short ? "ENDED EARLY (short/corrupt file?)" : "ended",
                                               "t=\(Int(position))s of \(Int(expected))s")
                PlaybackDiagnostics.shared.noteAlive(playing: false, at: position, episode: "")
                self.episodeFinished()
            }
        }
    }

    /// Log playback failures (e.g. a dead/expired stream URL) so a silent wake
    /// failure is diagnosable.
    private func observeFailure(of item: AVPlayerItem) {
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { note in
            let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error) ?? item.error
            PlaybackDiagnostics.shared.log("item FAILED to play to end", "\(String(describing: error))")
        }
    }

    // MARK: - Stalls

    /// A streamed episode on a walk drains its buffer the moment the cellular link gets thin, and
    /// nothing in this class used to notice: AVPlayer would sit in `.waitingToPlayAtSpecifiedRate`
    /// forever, the app would stop producing audio, and iOS would suspend us — so playback never
    /// came back even once signal did. Watch for the stall and drive the player back to playing.
    private func observeStall(of item: AVPlayerItem) {
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                #if PERFORMANCE_TESTING
                self.performancePlaybackStallCount += 1
                #endif
                PlaybackDiagnostics.shared.log("STALLED", "t=\(Int(self.preciseTime()))s buffered=\(self.bufferedSeconds())s")
                self.scheduleStallRecovery()
            }
        }
    }

    /// Watch the player's own idea of what it's doing. `timeControlStatus` going to `.paused`
    /// while we still believe we're playing means something outside this class stopped us —
    /// the single most valuable line in the log when audio dies in a pocket.
    ///
    /// Transitions only. A player scraping the end of its buffer flickers between `.playing` and
    /// `.waitingToPlayAtSpecifiedRate` several times a second, and logging each one buries the
    /// event we're actually here to find.
    private func observeTimeControl() {
        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let status = player.timeControlStatus
                defer { self.lastControlStatus = status }
                let changed = status != self.lastControlStatus

                switch status {
                case .playing:
                    self.confirmRecoveryIfSustained()
                case .waitingToPlayAtSpecifiedRate:
                    if changed {
                        let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
                        PlaybackDiagnostics.shared.log("waiting", "reason=\(reason) buffered=\(self.bufferedSeconds())s")
                    }
                    if self.isPlaying { self.scheduleStallRecovery() }
                case .paused:
                    // We only get here unexpectedly — our own pauses set isPlaying = false first.
                    // (Swapping in a new item briefly reports .paused too; that's us, not a mystery.)
                    if self.isPlaying, changed, !self.isRebuilding {
                        PlaybackDiagnostics.shared.log("PAUSED BY SOMETHING ELSE",
                                                       "t=\(Int(self.preciseTime()))s \(PlaybackDiagnostics.sessionSummary())")
                        self.scheduleStallRecovery()
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    /// Only a playhead that has actually *moved on* counts as recovery. Reaching `.playing` for a
    /// few hundred milliseconds while the last of the buffer drains is not recovery — treating it
    /// as such reset the backoff, so a long outage retried once a second forever instead of
    /// backing off.
    private func confirmRecoveryIfSustained() {
        guard stallAttempts > 0, recoveryConfirm == nil else { return }
        let baseline = preciseTime()
        recoveryConfirm = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recoveryConfirm = nil
                let position = self.preciseTime()
                guard self.player.timeControlStatus == .playing, position > baseline + 2 else { return }
                PlaybackDiagnostics.shared.log("recovered", "after \(self.stallAttempts) attempt(s), t=\(Int(position))s")
                self.cancelStallRecovery()
            }
        }
        // Coalesce with other background wakeups (PerfWatchdog's periodic sample, etc.); a
        // confirmation firing up to half a second late only makes the sustained-recovery check
        // below more likely to pass, never less.
        recoveryConfirm?.tolerance = 0.5
    }

    private func bufferedSeconds() -> Int {
        guard let item = player.currentItem else { return 0 }
        return Int(item.loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds })
    }

    /// Arm recovery if the player isn't actually playing once we've told it to.
    ///
    /// The `timeControlStatus` KVO fires *synchronously* inside `playImmediately`, before
    /// `isPlaying = true` is set — so the observer's `guard isPlaying` declined to arm, and since
    /// the player then sat in `.waitingToPlayAtSpecifiedRate` forever, no further transition ever
    /// came to arm it later. Pressing play with no signal hung silently and stayed hung even after
    /// signal came back. Nothing recovers a state machine that's waiting for an edge that never
    /// arrives; check the level instead.
    private func armRecoveryIfNotPlaying() {
        guard isPlaying, player.timeControlStatus != .playing else { return }
        scheduleStallRecovery()
    }

    /// Retry with backoff for as long as we still think we should be playing. The session is
    /// re-activated on each attempt: a suspended app can lose it, and asking AVPlayer to play on
    /// a dead session is how you get silent "playing" state.
    private func scheduleStallRecovery() {
        guard stallRetry == nil, isPlaying else { return }
        if stallBegan == nil { stallBegan = Date() }

        // A tunnel is minutes; a dead episode URL is forever. Keep trying long enough to outlast
        // any plausible dead spot, then stop rather than retrying in your pocket until the battery
        // is flat.
        if let began = stallBegan, Date().timeIntervalSince(began) > 30 * 60 {
            PlaybackDiagnostics.shared.log("giving up after 30m of stall", "t=\(Int(preciseTime()))s")
            setPlaying(false, reason: "unrecoverable stall")
            return
        }

        let delay = min(pow(2.0, Double(stallAttempts)), 30)   // 1, 2, 4, 8, 16, 30, 30…
        stallRetry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stallRetry = nil
                guard self.isPlaying, self.player.timeControlStatus != .playing else { return }
                self.stallAttempts += 1
                PlaybackDiagnostics.shared.log("recovery attempt \(self.stallAttempts)",
                                               "after \(Int(delay))s \(PlaybackDiagnostics.sessionSummary())")
                self.activateSession("stall recovery")

                // A connection that dies rather than merely slows leaves the item `.failed`, and a
                // failed item is terminal — `playImmediately` on it does nothing, forever. That is
                // the difference between audio that comes back when signal does and audio that
                // stays dead until you notice. Rebuild the item and seek back to where we were.
                if self.player.currentItem?.status == .failed || self.player.currentItem == nil {
                    self.rebuildCurrentItem()
                } else {
                    self.player.playImmediately(atRate: Float(self.speed))
                }
                self.scheduleStallRecovery()   // keep trying until timeControlStatus says .playing
            }
        }
        // Coalesce with other background wakeups (PerfWatchdog's periodic sample, etc.), same
        // convention as PerfWatchdog.swift's own timer. Backoff and the 30-minute give-up cap
        // (checked above via wall-clock Date(), not timer precision) are unaffected by jitter.
        stallRetry?.tolerance = min(3, delay * 0.2)
    }

    /// Recreate the player item for the current episode at the current playhead — the only way
    /// back from `.failed`.
    private func rebuildCurrentItem() {
        guard let episode = currentEpisode else { return }
        let url = downloads?.localURL(for: episode.id) ?? episode.audioURL
        let resumeAt = preciseTime()
        PlaybackDiagnostics.shared.log("rebuilding failed item", "t=\(Int(resumeAt))s \(url.isFileURL ? "local" : "STREAM")")
        isRebuilding = true
        defer { isRebuilding = false }

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        observeFailure(of: item)
        observeStall(of: item)
        if resumeAt > 1 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        }
        player.playImmediately(atRate: Float(speed))
        installSkipBoundaries()   // boundaries are timeline-relative; a new item needs them again
    }

    private func cancelStallRecovery() {
        stallRetry?.invalidate()
        stallRetry = nil
        recoveryConfirm?.invalidate()
        recoveryConfirm = nil
        stallAttempts = 0
        stallBegan = nil
    }

    /// Skip to the next / previous episode in the feed's play order (symmetric).
    func goToNextEpisode() { moveEpisode(by: +1) }
    func goToPreviousEpisode() { moveEpisode(by: -1) }

    /// Play order for the current feed, memoized. `Podcast.ordered()` is a full sort, and
    /// `hasNext/hasPreviousEpisode` are read from view bodies — NowPlayingView's body re-runs
    /// once a second while the sheet is open (it draws the playhead), which used to mean two
    /// full feed sorts per second. The memo invalidates structurally (feed identity, direction,
    /// episode set), so no notification wiring is needed.
    private var orderedMemo: (key: String, episodes: [String])?

    private func orderedEpisodes(for podcast: Podcast) -> [String] {
        let key = "\(podcast.id)|\(podcast.direction.rawValue)|\(podcast.episodeRevision)"
        if let memo = orderedMemo, memo.key == key { return memo.episodes }
        let list = podcast.orderedEpisodeIDs()
        orderedMemo = (key, list)
        return list
    }

    /// Next / previous episode, stepping over any the voice filter skips.
    private func moveEpisode(by offset: Int) {
        guard let pid = currentPodcastID, let ep = currentEpisode, let podcast = library?.podcast(pid) else { return }
        let ordered = orderedEpisodes(for: podcast)
        guard let idx = ordered.firstIndex(of: ep.id) else { return }
        let roster = podcast.hasVoiceFilter ? podcast.narratorRoster : []
        let voice = NarratorVoiceStore.shared.lookup()
        var target = idx + offset
        while ordered.indices.contains(target) {
            if let episode = podcast.episode(ordered[target]), !podcast.isSkipped(episode, roster: roster, voiceOf: voice) {
                play(episode, in: podcast, routineID: activeRoutineID)
                return
            }
            target += offset
        }
    }

    private func episodeIndex() -> (idx: Int, count: Int)? {
        guard let pid = currentPodcastID, let ep = currentEpisode, let podcast = library?.podcast(pid) else { return nil }
        let ordered = orderedEpisodes(for: podcast)
        guard let idx = ordered.firstIndex(of: ep.id) else { return nil }
        return (idx, ordered.count)
    }
    var hasNextEpisode: Bool { episodeIndex().map { $0.idx + 1 < $0.count } ?? false }

    #if DEBUG
    /// Screenshot fixture: show `episode` as the current one without loading any audio.
    func loadForPreview(_ episode: Episode, in podcast: Podcast) {
        currentPodcastID = podcast.id
        _ = orderedEpisodes(for: podcast)
        currentEpisode = episode
    }
    #endif

    /// What plays after the current episode, in the show's play order, skipping ones already
    /// finished — the player's Up next list.
    func upNext(limit: Int = 25) -> [Episode] {
        guard let pid = currentPodcastID, let ep = currentEpisode, let podcast = library?.podcast(pid) else { return [] }
        let ordered = orderedEpisodes(for: podcast)
        guard let idx = ordered.firstIndex(of: ep.id) else { return [] }
        let roster = podcast.hasVoiceFilter ? podcast.narratorRoster : []
        let voice = NarratorVoiceStore.shared.lookup()
        return Array(ordered.dropFirst(idx + 1)
            .lazy
            .filter { !podcast.completed.contains($0) }
            .compactMap { podcast.episode($0) }
            .filter { !podcast.completed.contains($0.id) && !podcast.isSkipped($0, roster: roster, voiceOf: voice) }
            .prefix(limit))
    }
    var hasPreviousEpisode: Bool { episodeIndex().map { $0.idx > 0 } ?? false }

    private func episodeFinished() {
        guard let pid = currentPodcastID, let ep = currentEpisode else { return }
        let routineID = activeRoutineID
        reportProgress(completed: true)
        library?.markCompleted(podcastID: pid, episodeID: ep.id)
        // Auto-advance to the next episode in the same feed for continuous listening.
        if let podcast = library?.podcast(pid),
           let next = podcast.nextEpisode(voiceOf: NarratorVoiceStore.shared.lookup()), next.id != ep.id {
            play(next, in: podcast, routineID: routineID)
        } else {
            history?.endSession()
            isPlaying = false
            activeRoutineID = nil
            currentTime = 0
            clearSkipState()
            updateNowPlaying()
            CloudProgressSync.shared.flushNow(reason: "finished")   // session over — push the completion
        }
    }

    private func beginCurrentListenSession() {
        guard let pid = currentPodcastID, let episode = currentEpisode,
              let podcast = library?.podcast(pid) else { return }
        history?.beginSession(podcastID: pid, episodeID: episode.id,
                              podcastTitle: podcast.title, episodeTitle: episode.title,
                              artworkURL: podcast.artworkURL)
    }

    // MARK: - Automatic ad skipping

    /// Adopt whatever is known about this episode, and ask for a plan if it can be improved.
    ///
    /// A missing plan is not a failure state. Streaming an episode for the first time, Banana
    /// knows nothing until the ad-server headers come back a few hundred milliseconds later —
    /// so this deliberately does not treat "no plan at play time" as "no plan this session".
    private func loadSkipPlan(for episode: Episode, in podcast: Podcast, streaming: Bool) {
        clearSkipState()
        skip.isEnabled = podcast.skipsAds(defaultingTo: settings?.automaticAdSkip ?? true)
        guard let skipPlans else { return }
        let bytes = skipPlans.audioByteCount(for: episode.id)
        skip.load(skipPlans.plan(for: episode.id),
                  corrections: skipPlans.corrections,
                  audioByteCount: bytes)
        // Never on the play button's critical path: the probe is a separate request that resolves
        // while the pre-roll is playing, and the build runs off whatever it finds.
        if streaming {
            // `freshOnly`: a prefetch from a while ago may describe a different stitch than the
            // one about to stream, so it is re-fetched rather than trusted.
            skipPlans.probeStream(episode: episode, podcast: podcast, freshOnly: true)
            // The stages that need this episode's own words cannot run on a first streamed
            // listen, and racing the playhead with live transcription is not the answer. Hand it
            // to the overnight batch instead, so the next listen is the clean one.
            TranscriptCoordinator.shared.noteStreamedListen(episode.id)
        }
        skipPlans.requestBuild(episode: episode, podcast: podcast, reason: streaming ? "stream" : "play")
    }

    /// A plan arrived (or was rebuilt) for an episode — quite possibly one already playing, and
    /// quite possibly with the playhead already inside a pre-roll. The right behaviour then is to
    /// skip from wherever the listener actually is, not to wait for the next span.
    func adoptSkipPlan(for episodeID: String) {
        guard let episode = currentEpisode, episode.id == episodeID, let skipPlans else { return }
        skip.load(skipPlans.plan(for: episodeID),
                  corrections: skipPlans.corrections,
                  audioByteCount: skipPlans.audioByteCount(for: episodeID))
        installSkipBoundaries()
        evaluateSkip(reason: "plan arrived")
    }

    /// Reflect the master switch without disturbing playback.
    ///
    /// A show that has opted out individually is left alone: flipping the global switch on must
    /// not override a per-show "no".
    func setAutomaticSkipEnabled(_ enabled: Bool) {
        let resolved = currentPodcastID
            .flatMap { library?.podcast($0) }
            .map { $0.skipsAds(defaultingTo: enabled) } ?? enabled
        guard skip.isEnabled != resolved else { return }
        setSkipEnabledResolved(resolved)
    }

    private func setSkipEnabledResolved(_ enabled: Bool) {
        guard skip.isEnabled != enabled else { return }
        skip.isEnabled = enabled
        installSkipBoundaries()
        if enabled { evaluateSkip(reason: "enabled") } else { skipNotice = nil }
    }

    private func clearSkipState() {
        skip.clear()
        skipNotice = nil
        skipNoticeDismissal?.cancel()
        skipNoticeDismissal = nil
        removeSkipBoundaries()
    }

    private func removeSkipBoundaries() {
        if let skipBoundaryObserver {
            player.removeTimeObserver(skipBoundaryObserver)
            self.skipBoundaryObserver = nil
        }
    }

    /// How far ahead of a skipped span to act, so the seek happens before it is audible.
    private var pendingSkipRecheck = false
    private static let skipLeadIn: Double = 0.4
    /// How far inside a span the backup boundary sits, for when the leading one was consumed by
    /// the seek that landed there.
    private static let skipBackupDelay: Double = 0.6

    private func installSkipBoundaries() {
        removeSkipBoundaries()
        let starts = skip.automaticSpanStarts
        guard !starts.isEmpty else { return }
        // Fire a beat BEFORE the span, not on it. A boundary observer reports a time already
        // crossed, so arming it on the span's own start meant the first fraction of the ad was
        // audible before the seek — which is what "laggy" skipping actually is.
        // Two boundaries per span. The first fires a beat BEFORE it, so the seek happens before the
        // ad is audible — an observer reports a time already crossed, which is what made skipping
        // feel late. The second sits just inside the span as a backup: a seek can consume the
        // boundary for the span it lands on, which is how a run of back-to-back ads had its first
        // one skipped and the rest played. Boundaries cost nothing unless they fire, so unlike a
        // periodic check this works exactly the same with the screen off — which is when podcasts
        // are actually listened to.
        let times = starts.flatMap { start -> [NSValue] in
            [max(0, start - Self.skipLeadIn), start + Self.skipBackupDelay].map {
                NSValue(time: CMTime(seconds: $0, preferredTimescale: 600))
            }
        }
        skipBoundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.evaluateSkip(reason: "boundary") }
        }
    }

    /// Jump if the playhead is at (or about to reach) something the plan says to skip.
    ///
    /// `at` overrides the player's own clock for the one case where it lies: immediately after
    /// `replaceCurrentItem` plus a seek, when the item has not caught up yet.
    private func evaluateSkip(reason: String, at position: Double? = nil) {
        guard hasCurrent, !isSeeking else { return }
        let from = position ?? preciseTime()
        guard let performed = skip.jump(from: from) else { return }
        // Structural loop-breaker, independent of where `from` came from. A jump that barely moves
        // cannot be worth a seek, and re-arming the recheck after one is how a stall becomes a
        // spin. `jump` refuses these too; this is the second lock on the same door, because the
        // cost of being wrong here is an unresponsive phone rather than a missed ad.
        guard performed.to - performed.from >= SkipPlaybackEngine.minimumAdvance else { return }
        // Where this jump lands may itself be the start of another span the collapse did not
        // reach. Re-check once the seek settles rather than waiting for a boundary that the seek
        // may have just consumed.
        pendingSkipRecheck = true
        // Never seek BACKWARDS of the destination: an ordinary tolerant seek is allowed to land a
        // second early, which here means landing back inside the ad it was leaving.
        performSeek(to: performed.to, toleranceBefore: 0, toleranceAfter: 0.75)
        PlaybackDiagnostics.shared.log(
            "AD SKIP (\(reason))",
            "\(Int(performed.from))s → \(Int(performed.to))s \(performed.label) "
                + performed.spans.map(\.source.rawValue).joined(separator: "+"))
        presentSkipNotice(performed)
    }

    /// Say what happened, briefly and without interrupting anything. Spoken audio with the screen
    /// off is the normal case, so this is never anything a listener has to dismiss.
    private func presentSkipNotice(_ performed: PerformedSkip) {
        guard let first = performed.spans.first else { return }
        skipNotice = SkipNotice(
            id: UUID(),
            label: performed.label,
            seconds: performed.duration,
            // Just inside the first span, so undo plays back what was taken — and so the rewind
            // watcher recognises it as landing in that span, which is what makes an undo count.
            returnTo: min(first.start + 0.01, max(0, performed.to - 0.5)),
            spans: performed.spans)
        skipNoticeDismissal?.cancel()
        skipNoticeDismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.skipNotice = nil
        }
    }

    func dismissSkipNotice() {
        skipNotice = nil
        skipNoticeDismissal?.cancel()
        skipNoticeDismissal = nil
    }

    /// Put back what was just taken.
    ///
    /// Goes through `seek(to:)` on purpose — the listener asking for skipped audio back is the
    /// clearest possible statement that the skip was wrong, and routing it through the user path
    /// means it is counted exactly once, by exactly the same rule as a manual rewind.
    func undoLastSkip() {
        guard let notice = skipNotice else { return }
        dismissSkipNotice()
        seek(to: notice.returnTo)
    }

    /// The learning loop's one input. Called from `seek(to:)` and nowhere else.
    private func noteUserSeek(to target: Double) {
        // Steering always wins over skipping. Whatever else this seek means, if it aims at audio
        // the plan wanted to skip, that audio is now reachable: someone scrubbing back to hear a
        // sponsor read, or to catch the sentence before an ad, must not be handed straight back
        // out of it. This runs on every user seek, including ones that carry no correction.
        let visited = skip.noteDeliberateVisit(to: target)
        if !visited.isEmpty {
            installSkipBoundaries()
            if let notice = skipNotice,
               notice.spans.contains(where: { s in visited.contains(where: { $0.id == s.id }) }) {
                dismissSkipNotice()
            }
        }

        guard let span = skip.userSeeked(to: target) else { return }
        // The whole move is stopped for this episode, not just the third of it they landed in:
        // being sent forward again a second after rewinding is worse than the original skip. Only
        // the span actually rewound into counts as evidence, though — one rewind is one fact
        // about one detector, and demoting three on one gesture would retire good ones.
        let run = skip.collapsedRun(containing: span)
        skip.demoteForSession(run)
        installSkipBoundaries()
        if skipNotice?.spans.contains(where: { $0.id == span.id }) == true { dismissSkipNotice() }
        guard let podcastID = skip.plan?.podcastID else { return }
        skipPlans?.recordCorrection(for: span, podcastID: podcastID)
        PlaybackDiagnostics.shared.log(
            "AD SKIP CORRECTED",
            "rewound into \(span.source.rawValue) at \(Int(target))s — \(span.kind.label)")
    }

    // MARK: - Now Playing + remote commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.setPlaying(true, reason: "remote command"); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.setPlaying(false, reason: "remote command"); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(reason: "remote command"); return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 30); return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -15); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasNextEpisode else { return .noSuchContent }
            self.goToNextEpisode(); return .success
        }
    }

    private func updateNowPlaying(minimal: Bool = false) {
        guard let ep = currentEpisode else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = preciseTime()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if !minimal {
            info[MPMediaItemPropertyTitle] = ep.title
            if let pid = currentPodcastID, let name = library?.podcast(pid)?.title {
                info[MPMediaItemPropertyArtist] = name
            }
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        onStateChange?()
    }
}
