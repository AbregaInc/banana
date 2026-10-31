import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import os

/// The rapidly changing playhead lives in its own observation object. Views that only need
/// play/pause/title changes can observe `WatchAudioPlayer` without being invalidated every second.
@MainActor
final class WatchPlaybackClock: ObservableObject {
    @Published fileprivate(set) var time: TimeInterval = 0
}

/// Plays a downloaded episode file locally on the Watch (to Bluetooth headphones).
@MainActor
final class WatchAudioPlayer: NSObject, ObservableObject {
    /// Shared so `WatchSyncManager` (a singleton delegate, with no view context) can stop
    /// local playback when the phone takes over.
    static let shared = WatchAudioPlayer()

    @Published private(set) var currentID: String?
    @Published private(set) var currentTitle: String?
    /// The show being played, by title: its speed is kept per show.
    private var currentPodcast = ""
    /// The speed this episode is playing at (0.8× to 2×, `PlaybackSpeeds.watchOptions`).
    @Published private(set) var speed: Double = 1
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    /// You asked for audio with no headphones connected, and it didn't play: the Watch's speaker
    /// is never the place for a podcast. The Watch says so until you dismiss it or connect some.
    @Published private(set) var needsHeadphones = false
    let clock = WatchPlaybackClock()

    /// Kept as an API convenience for commands and metadata. Reading this does not subscribe a
    /// view to playhead ticks; progress-only child views explicitly observe `clock`.
    var currentTime: TimeInterval {
        get { clock.time }
        set {
            guard clock.time != newValue else { return }
            clock.time = newValue
        }
    }

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var interfaceActive = true
    private var lastLocalCheckpoint = Date.distantPast
    /// A Siri/notification interruption is not a user pause. Keep that distinction so spoken
    /// audio resumes when the announcement ends, but never resurrects something the listener
    /// intentionally stopped.
    private var resumeAfterInterruption = false
    private var remoteCommandsConfigured = false

    // MARK: - Automatic ad skipping

    /// The markers the phone sent for the episode playing now, minus anything rejected during
    /// this session. The Watch never computes these and never persists a rejection: it has no
    /// detector to demote and no correction book to keep. What it does do is tell the phone,
    /// which has both.
    private var skipPlan: EpisodeSkipPlan?
    /// The one learning signal, fed exclusively from `skip(by:)` — a seek the wearer asked for.
    /// A jump this class makes itself never goes near it, or the phone would be taught that its
    /// own correct skips were mistakes.
    private var skipWatcher = SkipRewindWatcher()
    /// AVAudioPlayer has no boundary observer, and this class's ticker drops to once a minute
    /// with the screen off — which would mean sitting through most of an ad before anything
    /// noticed. One timer, armed for the next span, is both precise and cheaper than a faster tick.
    private var skipTimer: Timer?

    private static let log = Logger(subsystem: "com.boris.banana", category: "watchaudio")

    private override init() {
        super.init()
        setupRemoteCommandsIfNeeded()
        // System-initiated pauses (a call, Siri, an AirPod removed) never went through
        // togglePlayPause — so the 1 Hz ticker kept firing and republishing @Published state
        // for the rest of the app's life, and the session stayed active holding the route.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99
                Self.log.notice("interruption type=\(raw, privacy: .public)")
                guard let type = AVAudioSession.InterruptionType(rawValue: raw), let self else { return }
                switch type {
                case .began:
                    self.resumeAfterInterruption = self.isPlaying
                    self.systemPaused(reason: "interruption")
                case .ended:
                    self.resumeIfNeededAfterInterruption()
                @unknown default:
                    break
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 99
                let prev = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
                    .map(Self.describe) ?? "?"
                let now = Self.describe(AVAudioSession.sharedInstance().currentRoute)
                // Instrument EVERY route change (reason + before/after outputs). Removing ONE AirPod is
                // ear-detection, not `.oldDeviceUnavailable` — watchOS may report it with a different
                // reason or a changed output set, and this log is how we learn exactly what it emits on
                // the device rather than guessing.
                Self.log.notice("routeChange reason=\(raw, privacy: .public) prev=[\(prev, privacy: .public)] now=[\(now, privacy: .public)]")
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
                // Best-effort until the log confirms the single-AirPod reason: pause on a full disconnect,
                // or whenever we're playing and the current route no longer has any headphone/BT output
                // (fell back to the watch speaker / nothing).
                let lostOutput = self?.isPlaying == true
                    && !Self.hasHeadphoneOutput(AVAudioSession.sharedInstance().currentRoute)
                if reason == .oldDeviceUnavailable || lostOutput {
                    self?.systemPaused(reason: "route lost (reason \(raw))")
                }
                if Self.hasHeadphoneOutput(AVAudioSession.sharedInstance().currentRoute) {
                    self?.needsHeadphones = false
                }
            }
        }
    }

    private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
        route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
    }
    private static let builtInOutputs: Set<String> = [
        AVAudioSession.Port.builtInSpeaker.rawValue, AVAudioSession.Port.builtInReceiver.rawValue,
    ]

    private static func hasHeadphoneOutput(_ route: AVAudioSessionRouteDescription) -> Bool {
        WorkoutMediaRouting.reachesHeadphones(outputs: route.outputs.map(\.portType.rawValue),
                                              builtIn: builtInOutputs)
    }

    /// Opens the audio session and says whether it reaches headphones. Without them nothing
    /// plays — the session is let go again, and `announce` says whether to tell you why (not when
    /// a workout was only going to start something on its own).
    func sessionReachesHeadphones(announce: Bool = true) -> Bool {
        configureSession()
        let route = AVAudioSession.sharedInstance().currentRoute
        if Self.hasHeadphoneOutput(route) {
            needsHeadphones = false
            return true
        }
        Self.log.notice("no headphones (route=[\(Self.describe(route), privacy: .public)]); not playing from the Watch speaker")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if announce { needsHeadphones = true }
        return false
    }

    func dismissHeadphonesPrompt() { needsHeadphones = false }

    /// Reflect a pause the system made behind our back: stop the ticker and persist progress.
    private func systemPaused(reason: String) {
        guard isPlaying else { return }
        Self.log.notice("system paused: \(reason, privacy: .public); willResume=\(self.resumeAfterInterruption)")
        player?.pause()
        isPlaying = false
        ticker?.invalidate(); ticker = nil
        skipTimer?.invalidate(); skipTimer = nil
        reportProgress(completed: false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resumeIfNeededAfterInterruption() {
        defer { resumeAfterInterruption = false }
        guard resumeAfterInterruption, let player, currentID != nil else {
            Self.log.notice("interruption ended; no playback to resume")
            return
        }
        guard sessionReachesHeadphones(announce: false) else { return }
        guard player.play() else {
            Self.log.error("interruption ended; AVAudioPlayer refused resume")
            return
        }
        isPlaying = true
        startTicker()
        scheduleNextSkip()
        updateNowPlaying()
        Self.log.notice("interruption ended; resumed at \(Int(player.currentTime))s")
    }

    // MARK: - Watch Now Playing ownership

    /// The Watch must publish its own Now Playing item and own its command center. Without this,
    /// an AirPods press can be routed to the phone's last media app (often resuming Music) even
    /// while Banana is audibly playing from the Watch. These handlers are entirely local: they do
    /// not forward anything to the phone's media controls.
    private func setupRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.setPlayingFromRemote(true) == true ? .success : .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.setPlayingFromRemote(false) == true ? .success : .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.setPlayingFromRemote(!self.isPlaying) ? .success : .commandFailed
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.skip(by: 30)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.skip(by: -15)
            return .success
        }
    }

    @discardableResult
    private func setPlayingFromRemote(_ shouldPlay: Bool) -> Bool {
        guard let player else { return false }
        if shouldPlay {
            if !player.isPlaying {
                resumeAfterInterruption = false
                guard sessionReachesHeadphones() else { return false }
                guard player.play() else { return false }
                isPlaying = true
                startTicker()
                scheduleNextSkip()
            }
        } else if player.isPlaying {
            pause()
        }
        updateNowPlaying()
        return true
    }

    private func updateNowPlaying() {
        guard let title = currentTitle else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime ?? currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyMediaType] = MPMediaType.podcast.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func play(_ episode: WatchEpisode, url: URL, announce: Bool = true) {
        resumeAfterInterruption = false
        guard sessionReachesHeadphones(announce: announce) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            // The show's own speed, as on the phone: everything played at 1× here.
            p.enableRate = true
            currentPodcast = episode.podcast
            speed = WatchEpisodeStore.shared.speed(forPodcast: episode.podcast)
            p.rate = Float(speed)
            player = p
            currentID = episode.id
            currentTitle = episode.title
            duration = p.duration
            // Starting here claims "current" for this Watch, durably. `currentID` above is
            // runtime-only and dies with the process; this is what survives to the next launch
            // and what the phone's claim is merged against.
            WatchEpisodeStore.shared.setLocalCurrent(episode.id)
            let resume = WatchEpisodeStore.shared.position(for: episode.id)   // resume where you (or the phone) left off
            if resume > 5, resume < p.duration - 5 { p.currentTime = resume }
            skipPlan = WatchSkipPlanStore.shared.plan(for: episode.id)
            skipWatcher = SkipRewindWatcher()
            // Before the first sample: starting inside a pre-roll and jumping out a moment later
            // is audibly worse than never playing it at all.
            applySkipIfNeeded(reason: "play")
            currentTime = p.currentTime
            p.play()
            isPlaying = true
            lastLocalCheckpoint = Date()
            startTicker()
            scheduleNextSkip()
            updateNowPlaying()
            // Only *after* we're actually playing. Sending this first meant that when the episode
            // wasn't really downloaded here, AVAudioPlayer threw, the Watch played nothing — and
            // the phone had already been silenced. One device at a time, but only if this one has
            // something to say.
            WatchPhoneRemote.shared.send("pause")
        } catch {
            isPlaying = false
        }
    }

    /// Start a downloaded episode for a workout — resuming the one you're MID-WAY through, not a
    /// fresh "first" episode.
    ///
    /// The phone syncs resume positions, so an episode with a position (started, not finished) is
    /// the one you're actually listening to. Within the priority-ordered pool we prefer that — the
    /// half-played episode already going on the phone — and only fall back to a fresh episode when
    /// nothing is in progress. `play()` seeks to the saved position, so it picks up where you left
    /// off across devices.
    func playWorkout(preferredPodcasts: [String], episodes: [WatchEpisode], store: WatchEpisodeStore) {
        // The explicit current counts as in-progress even at position zero. An episode the phone
        // just handed over is the one you're listening to, but the ">30s played" proxy cannot see
        // it yet — so without this a workout would start something else entirely.
        func inProgress(_ e: WatchEpisode) -> Bool {
            store.currentEpisodeID == e.id || store.position(for: e.id) > 30
        }

        // 1) A half-played episode, in podcast-priority order (most progress wins within a podcast).
        for title in preferredPodcasts {
            let started = episodes.filter { $0.podcast == title && inProgress($0) }
                .sorted { a, b in
                    // An explicit current outranks a merely half-played episode.
                    if (store.currentEpisodeID == a.id) != (store.currentEpisodeID == b.id) {
                        return store.currentEpisodeID == a.id
                    }
                    return store.position(for: a.id) > store.position(for: b.id)
                }
            if let ep = started.first { play(ep, url: store.localURL(for: ep), announce: false); return }
        }
        // 2) Otherwise the first downloaded episode of the highest-priority podcast we have.
        let match = preferredPodcasts.lazy.compactMap { title in episodes.first { $0.podcast == title } }.first
            ?? episodes.first
        guard let episode = match else { return }
        play(episode, url: store.localURL(for: episode), announce: false)
    }

    #if DEBUG
    /// Simulator-only: seed a fake now-playing state so the inline media controls render
    /// in the active-workout preview (no real audio file needed).
    func debugSeedNowPlaying() {
        currentID = "debug-preview-episode"
        currentTitle = "Acquired — Microsoft Volume II"
        duration = 12_600
        currentTime = 4_890
        isPlaying = true
    }
    #endif

    func pause() {
        #if DEBUG
        if player == nil, currentID != nil { isPlaying = false; return }
        #endif
        resumeAfterInterruption = false
        guard let player, player.isPlaying else { return }
        player.pause(); isPlaying = false
        ticker?.invalidate(); ticker = nil
        skipTimer?.invalidate(); skipTimer = nil
        reportProgress(completed: false)
        updateNowPlaying()
    }

    func togglePlayPause() {
        #if DEBUG
        if player == nil, currentID != nil { isPlaying.toggle(); return }   // fake preview toggle
        #endif
        guard let player else { return }
        if player.isPlaying {
            // Only stop() and the finish delegate invalidated this — so pausing left a 1Hz timer
            // waking the watch CPU and republishing @Published state forever.
            pause()
        } else {
            guard sessionReachesHeadphones() else { return }
            player.play(); isPlaying = true; startTicker(); scheduleNextSkip(); updateNowPlaying()
        }
    }

    /// Stop spending one main-thread publish per second when the watch UI is not visible. Audio
    /// remains entirely in AVAudioPlayer. A minute-level local checkpoint still protects progress
    /// if watchOS kills the process; it does not wake the phone radio.
    func setInterfaceActive(_ active: Bool) {
        guard interfaceActive != active else { return }
        interfaceActive = active
        if let player {
            currentTime = player.currentTime
        }
        if isPlaying { startTicker() }
    }

    var currentPosition: TimeInterval { player?.currentTime ?? currentTime }

    // MARK: - Speed

    /// The next speed up, round to the slowest: the speed button. Kept as the show's speed, here
    /// and on the phone.
    func cycleSpeed() {
        setSpeed(PlaybackSpeeds.next(after: speed, in: PlaybackSpeeds.watchOptions))
        if !currentPodcast.isEmpty { WatchEpisodeStore.shared.setSpeed(speed, forPodcast: currentPodcast) }
    }

    /// The phone sent its shows' speeds: follow, if the one playing changed.
    func speedsChanged() {
        guard currentID != nil, !currentPodcast.isEmpty else { return }
        let wanted = WatchEpisodeStore.shared.speed(forPodcast: currentPodcast)
        if abs(wanted - speed) > 0.001 { setSpeed(wanted) }
    }

    private func setSpeed(_ newSpeed: Double) {
        speed = PlaybackSpeeds.onWatch(newSpeed)
        player?.rate = Float(speed)
        scheduleNextSkip()   // the next ad's start is now sooner or later by the clock
        updateNowPlaying()
    }

    /// Persist position locally and sync it to the phone.
    private func reportProgress(completed: Bool) {
        guard let id = currentID else { return }
        let pos = player?.currentTime ?? currentTime
        WatchEpisodeStore.shared.setLocalProgress(id, position: pos, duration: duration, completed: completed)
        WatchSyncManager.sendListenProgress(episodeID: id, position: pos, duration: duration, completed: completed)
    }

    /// A seek the wearer asked for — the crown buttons, or an AirPods/Lock Screen command.
    ///
    /// The only route into the learning loop, and deliberately the only one: the automatic jump
    /// below moves the playhead through `player.currentTime` directly and never comes through
    /// here, so a skip cannot be mistaken for an objection to itself.
    func skip(by seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, player.currentTime + seconds), player.duration)
        currentTime = player.currentTime
        noteUserSeek(to: player.currentTime)
        scheduleNextSkip()
        updateNowPlaying()
    }

    // MARK: - Ad skipping

    /// Jump out of anything the plan marks automatic, from wherever the playhead is now.
    private func applySkipIfNeeded(reason: String) {
        guard let player, let plan = skipPlan else { return }
        let from = player.currentTime
        guard let destination = plan.destination(from: from), destination > from,
              destination < player.duration - 0.5 else { return }
        for span in plan.automaticSpans where span.end > from && span.end <= destination + 0.001 {
            skipWatcher.recordSkip(span, now: Date())
        }
        player.currentTime = destination
        currentTime = destination
        Self.log.notice("watch: ad skip (\(reason, privacy: .public)) \(Int(from), privacy: .public)s -> \(Int(destination), privacy: .public)s")
        updateNowPlaying()
    }

    /// Wake up exactly when the next automatic span begins, and not before.
    private func scheduleNextSkip() {
        skipTimer?.invalidate(); skipTimer = nil
        guard let player, let plan = skipPlan else { return }
        let now = player.currentTime
        guard let next = plan.automaticSpans.map(\.start).filter({ $0 > now + 0.05 }).min(),
              // By the clock, not the audio: at 1.5× the ad comes a third sooner.
              let wait = PlaybackSpeeds.wallClock(from: now, to: next, rate: speed) else { return }
        skipTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.applySkipIfNeeded(reason: "boundary")
                self.scheduleNextSkip()
            }
        }
        skipTimer?.tolerance = 0.1
    }

    /// A rewind back into audio that was just skipped means the skip was wrong.
    private func noteUserSeek(to time: TimeInterval) {
        // Steering wins over skipping here exactly as it does on the phone: audio the listener
        // deliberately scrubbed to is audio they are allowed to hear, whether or not this seek
        // also says a recent skip was wrong. Without it, a rewind onto an ad is answered by a
        // jump back out and the audio is unreachable from the wrist.
        suppressDeliberateVisit(to: time)

        guard let span = skipWatcher.userSeeked(to: time, now: Date()), let plan = skipPlan else { return }
        // Stop the whole move for this episode, not just the part they landed in: being sent
        // forward again a second after rewinding is worse than the original skip.
        let run = Self.collapsedRun(containing: span, in: plan)
        let ids = Set(run.map(\.id))
        var demoted = plan
        demoted.spans = plan.spans.map { candidate in
            guard ids.contains(candidate.id) else { return candidate }
            var offered = candidate
            offered.confidence = .offered
            return offered
        }
        skipPlan = demoted
        if let episodeID = currentID {
            WatchSyncManager.sendSkipCorrection(episodeID: episodeID, spanID: span.id)
        }
        Self.log.notice("watch: rewound into a skipped \(span.source.rawValue, privacy: .public); telling the phone")
    }

    /// Stop auto-skipping a stretch the listener steered into on purpose.
    ///
    /// Mirrors `SkipPlaybackEngine.noteDeliberateVisit`. Not reported to the phone as a
    /// correction: wanting to hear an ad once is not evidence that calling it an ad was wrong.
    private func suppressDeliberateVisit(to time: TimeInterval) {
        guard let plan = skipPlan else { return }
        let aimedAt = plan.automaticSpans.filter { span in
            span.contains(time) || (span.start > time && span.start - time <= 3.0)
        }
        guard let first = aimedAt.min(by: { $0.start < $1.start }) else { return }
        let ids = Set(Self.collapsedRun(containing: first, in: plan).map(\.id))
        var demoted = plan
        demoted.spans = plan.spans.map { candidate in
            guard ids.contains(candidate.id) else { return candidate }
            var offered = candidate
            offered.confidence = .offered
            return offered
        }
        skipPlan = demoted
    }

    /// The run of adjacent automatic spans one jump would have collapsed into a single move. The
    /// tolerance matches `EpisodeSkipPlan.destination(from:)`'s own, so "adjacent" means the same
    /// thing here as it does where the jump is made.
    private static func collapsedRun(containing span: SkipSpan, in plan: EpisodeSkipPlan) -> [SkipSpan] {
        let ordered = plan.automaticSpans.sorted { $0.start < $1.start }
        var run: [SkipSpan] = []
        for candidate in ordered {
            if let previous = run.last, candidate.start - previous.end > 0.75 {
                if run.contains(where: { $0.id == span.id }) { return run }
                run = []
            }
            run.append(candidate)
        }
        return run.contains(where: { $0.id == span.id }) ? run : [span]
    }

    func stop() {
        resumeAfterInterruption = false
        reportProgress(completed: false)
        ticker?.invalidate(); ticker = nil
        skipTimer?.invalidate(); skipTimer = nil
        skipPlan = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentID = nil
        currentTitle = nil
        currentTime = 0
        updateNowPlaying()
        // setActive(true) was the only setActive call in the whole watch target — the session (and
        // the Bluetooth route) stayed up for the rest of the app's life after any playback.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        ticker?.invalidate()
        let interval: TimeInterval = interfaceActive ? 1 : 60
        // Fires on the main run loop — assumeIsolated instead of a fresh Task allocation per tick.
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                if self.interfaceActive {
                    self.currentTime = player.currentTime
                    if self.isPlaying != player.isPlaying { self.isPlaying = player.isPlaying }
                }
                if player.isPlaying,
                   Date().timeIntervalSince(self.lastLocalCheckpoint) >= 60,
                   let id = self.currentID {
                    self.lastLocalCheckpoint = Date()
                    // Crash safety without publishing the entire positions dictionary or
                    // serializing it once a minute while the watch face is asleep.
                    WatchEpisodeStore.shared.saveLocalCheckpoint(
                        id, position: player.currentTime, duration: player.duration, completed: false)
                }
            }
        }
        ticker?.tolerance = interfaceActive ? 0.15 : 10
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }
}

extension WatchAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.reportProgress(completed: true)
            self.ticker?.invalidate(); self.ticker = nil
            self.skipTimer?.invalidate(); self.skipTimer = nil
            self.skipPlan = nil
            self.player = nil
            self.isPlaying = false
            self.currentID = nil
            self.currentTitle = nil
            self.currentTime = 0
            self.updateNowPlaying()
            // The finish path never released the session — after an episode ended naturally the
            // watch held the Bluetooth route (and the audio stack awake) indefinitely.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
