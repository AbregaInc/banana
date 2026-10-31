#if os(iOS)
// WatchConnectivity is the phone↔Watch link. A Mac has no Watch to talk to.

import Foundation
import SwiftUI
import WatchConnectivity
import Combine

/// The single iOS-side WatchConnectivity delegate. (A `WCSession` allows only one
/// delegate, so this one coordinator handles both directions: it receives recorded
/// workout files from the Watch and sends downloaded podcast episodes to it.)
@MainActor
final class PhoneConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneConnectivity()

    /// Number of episode files still transferring to the Watch (for a progress UI).
    @Published private(set) var episodesInFlight = 0
    /// What the Watch app reports it is running, once it has talked to us. Nil until then.
    ///
    /// There are three ways a Watch app gets installed — Xcode directly, TestFlight via the
    /// Watch app on iPhone, or as a companion of a phone install — and they do not stay in step.
    /// Nothing could answer "what is on the Watch?", so a stale pair presented as whatever
    /// feature you happened to try next.
    @Published private(set) var watchVersion: String?

    /// This app's own version, for the same row.
    static var phoneVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    func refreshTransferCount() {
        guard WCSession.isSupported() else { return }
        episodesInFlight = WCSession.default.outstandingFileTransfers.filter {
            ($0.file.metadata?["type"] as? String) == "episode"
        }.count
    }

    weak var fitnessStore: FitnessStore?
    weak var downloads: DownloadManager?
    weak var skipPlans: SkipPlanService?
    weak var wake: WakeStore?
    weak var library: PodcastLibrary?

    /// Tell the Watch to download an episode DIRECTLY from its URL (fast path).
    func sendDownloadInstruction(episodeID: String, title: String, podcast: String, url: URL,
                                 skipPlan: Data? = nil) {
        guard WCSession.isSupported() else { return }
        var info: [String: Any] = [
            "type": "downloadEpisode", "episodeID": episodeID, "title": title,
            "podcast": podcast, "url": url.absoluteString,
        ]
        if let skipPlan { info["skipPlan"] = skipPlan }
        WCSession.default.transferUserInfo(info)
        Log.sync.notice("phone: sent download instruction for \(episodeID, privacy: .public)")
    }

    /// Hand the Watch the ad-skip markers for one episode.
    ///
    /// The Watch has no speech framework and no model, so it can never work these out; it plays
    /// only files that were transferred to it, so it always has the bytes and only ever needs the
    /// markers. A few hundred bytes on the queued channel, which survives the Watch being off.
    func sendSkipPlan(episodeID: String, payload: Data) {
        guard WCSession.isSupported() else { return }
        WCSession.default.transferUserInfo([
            "type": "skipPlan", "episodeID": episodeID, "skipPlan": payload,
        ])
    }

    /// Tell the Watch to delete a downloaded episode (pruned/deleted/unsubscribed on
    /// the phone). transferUserInfo is queued, so it survives the Watch being offline.
    func deleteEpisode(_ episodeID: String) {
        guard WCSession.isSupported() else { return }
        WCSession.default.transferUserInfo(["type": "deleteEpisode", "episodeID": episodeID])
    }

    /// Tell the Watch which podcast is the Workout source, so it can auto-play a
    /// downloaded episode of it when a workout starts. Uses applicationContext so it
    /// survives the Watch being unreachable (delivered on next connect).
    private var lastWorkoutTitles: [String] = []

    func syncWorkoutSource() {
        // Send the WHOLE Workout-cue pool in PRIORITY order so the Watch plays #1 if it
        // has it, else #2, and so on — not whatever synced most recently.
        let titles = (RoutineStore.shared.workoutCue?.podcastIDs ?? []).compactMap { library?.podcast($0)?.title }
        guard titles != lastWorkoutTitles else { return }   // don't re-send an unchanged value
        lastWorkoutTitles = titles
        mergeContext(["workoutPodcasts": titles, "workoutPodcast": titles.first ?? ""])
    }

    // MARK: - Settings → Watch

    weak var settings: AppSettings?

    /// Push the phone's fitness settings to the Watch so live workout metrics match and a swim
    /// needs no configuration on the wrist.
    func syncSettings() {
        mergeContext([
            "distanceUnit": (settings?.distanceUnit ?? .miles).rawValue,
            "poolLengthMeters": (settings?.poolLength ?? .yards25).meters,
        ])
    }

    /// Cache the newest validated guided plan on the Watch. Application context is latest-wins,
    /// which is exactly what a single offline-ready plan needs.
    func syncWorkoutPlan() {
        // Nothing while guided plans are off, which also clears a plan a Watch already holds.
        let plan = Features.guidedPlans ? WellnessStore.shared.latestWorkoutPlan : nil
        let data = plan.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        mergeContext(["guidedWorkoutPlan": data])
    }

    /// The authoritative set of episodes the Watch should have — it prunes anything else,
    /// self-healing stale/played episodes whose delete message was missed.
    func syncWatchManifest(_ episodeIDs: [String]) {
        mergeContext(["watchEpisodes": episodeIDs])
    }

    // MARK: - Now-playing remote (Watch controls the phone)

    weak var player: PlayerController?
    /// True while we've paused our own playback for a note being recorded on the Watch.
    private var pausedForRemoteNote = false
    private var appContext: [String: Any] = [:]
    private var lastNowPlaying: (title: String, playing: Bool, speed: Double)?
    private var calendarCancellable: AnyCancellable?

    /// Merge keys into the single shared application context (latest-wins) and push it,
    /// so workout-source + now-playing don't clobber each other.
    ///
    /// Every merge call resends the WHOLE context (it's the only WCSession primitive for this),
    /// so an unrelated key changing (a play/pause) used to re-deliver every other key verbatim —
    /// the Watch then re-applied byte-identical calendar/plan/settings data on every push. Only
    /// push when a key's value actually differs from what's already merged in; a fresh session
    /// still gets everything via the activation-time flush below, which bypasses this dedupe.
    private func mergeContext(_ updates: [String: Any]) {
        var changed = false
        for (key, value) in updates {   // retain even if not yet activated
            if let old = appContext[key], (old as AnyObject).isEqual(value) { continue }
            appContext[key] = value
            changed = true
        }
        guard changed, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(appContext)
    }

    /// Keep a few upcoming events on the Watch so its rectangular complication can continue to
    /// advance while the phone app is asleep. The complication itself never opens EventKit.
    func bindCalendarComplication(to store: OccurrenceStore) {
        calendarCancellable = store.$occurrences
            .map { Self.watchCalendarItems(from: $0) }
            .removeDuplicates()
            .sink { [weak self] items in self?.syncCalendarComplication(items) }
    }

    private static func watchCalendarItems(
        from occurrences: [Occurrence],
        now: Date = Date()
    ) -> [WatchCalendarItem] {
        occurrences
            .filter {
                $0.behavior == .event
                    && $0.hasScheduledTime
                    && !$0.skipped
                    && $0.resolvedEnd > now
            }
            .sorted { $0.start < $1.start }
            .prefix(8)
            .map {
                WatchCalendarItem(
                    id: $0.id,
                    title: $0.title,
                    start: $0.start,
                    end: $0.resolvedEnd,
                    location: $0.meeting?.address)
            }
    }

    private func syncCalendarComplication(_ items: [WatchCalendarItem]) {
        let payload: [[String: Any]] = items.map {
            [
                "id": $0.id,
                "title": $0.title,
                "start": $0.start.timeIntervalSince1970,
                "end": $0.end.timeIntervalSince1970,
                "location": $0.location ?? "",
            ]
        }
        mergeContext(["calendarItems": payload])
    }

    /// Publish the phone's now-playing state to the Watch (de-duped so position ticks
    /// don't spam the context).
    /// Tell the Watch a note is being recorded on the PHONE, so it pauses any podcast IT is
    /// playing (and its button can reflect that a capture is live).
    func sendNoteStart(parent: DiagnosticTraceContext? = nil) {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        var message: [String: Any] = ["cmd": "noteStart"]
        if let parent { message["traceparent"] = parent.traceparent }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { _ in })
    }
    func sendNoteStop(parent: DiagnosticTraceContext? = nil) {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        var message: [String: Any] = ["cmd": "noteStop"]
        if let parent { message["traceparent"] = parent.traceparent }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { _ in })
    }

    /// So the Watch's note button shows the phone's live recording state (for phone-recorded notes
    /// the Watch triggered).
    func publishNoteRecording() {
        mergeContext(["noteRecording": VoiceNoteStore.shared.isRecording])
    }

    private var lastCurrentPush: (id: String, at: Date)?

    /// Hand the phone's current episode to the Watch, so pressing play there resumes what you
    /// were listening to here rather than whatever the Watch last touched on its own.
    ///
    /// This rides applicationContext, NOT the transferUserInfo queue. "What is current" is a
    /// latest-state-wins value and context coalesces to exactly that; a queued claim could be
    /// delivered after a newer one and still take effect. Progress reports stay on the queue,
    /// because there every individual report carries listening that must not be dropped.
    ///
    /// The claim is stamped with when the episode was last genuinely *listened to*
    /// (`progressStamp`), never with "now". Launching the app restores an episode into the
    /// player without anyone pressing anything, and stamping that as fresh would let a mere
    /// launch steal current from a Watch that had been listening. A stale stamp correctly loses.
    ///
    /// Only ever asserts a non-nil episode: the phone having nothing loaded is not a claim that
    /// the Watch should forget what it has. Silence is not an instruction.
    func syncCurrentEpisode() {
        // What this device would RESUME, not what its player happens to hold. Those are the same
        // thing during playback and differ exactly when current moved without it — a CloudKit
        // merge from the Mac changes the library while the phone sits idle. Reading the player
        // meant that handoff reached the phone and stopped: the Watch has no route to the Mac
        // except through here.
        guard let target = library?.resumeTarget() else { return }
        if let last = lastCurrentPush, last.id == target.episodeID, last.at == target.at { return }
        lastCurrentPush = (target.episodeID, target.at)
        mergeContext([
            "currentEpisodeID": target.episodeID,
            "currentEpisodeAt": target.at.timeIntervalSince1970,
        ])
    }

    func sendNowPlaying() {
        guard WCSession.isSupported() else { return }
        // Before the de-dupe below: that one keys on (title, playing) and returns early when the
        // transport state is unchanged, but current can move without either changing.
        syncCurrentEpisode()
        syncPodcastSpeeds()
        let title = player?.currentEpisode?.title
        let playing = player?.isPlaying ?? false
        let speed = player?.speed ?? 1
        if let last = lastNowPlaying, last.title == (title ?? ""), last.playing == playing, last.speed == speed { return }
        lastNowPlaying = (title ?? "", playing, speed)
        var podcast = ""
        if let pid = player?.currentPodcastID { podcast = library?.podcast(pid)?.title ?? "" }
        mergeContext([
            "npActive": title != nil,
            "npTitle": title ?? "",
            "npPodcast": podcast,
            "npPlaying": playing,
            "npSpeed": speed,
        ])
    }

    /// Each show's speed, for the episodes the Watch plays by itself: a show set to 1.5× on the
    /// phone played at 1× there. By title, as the Watch knows its shows; only the ones off 1×.
    private var lastPodcastSpeeds: [String: Double]?

    func syncPodcastSpeeds() {
        guard let library else { return }
        let speeds = PlaybackSpeeds.nonDefault(library.podcasts.map { ($0.title, $0.speed) })
        guard speeds != lastPodcastSpeeds else { return }
        lastPodcastSpeeds = speeds
        mergeContext(["podcastSpeeds": speeds])
    }

    /// A speed chosen on the Watch for one of its shows: it is that show's speed everywhere.
    private func adoptSpeedFromWatch(_ speed: Double, podcastTitle: String) {
        guard PlaybackSpeeds.options.contains(where: { abs($0 - speed) < 0.001 }),
              let podcast = library?.podcasts.first(where: { $0.title == podcastTitle }) else { return }
        if player?.currentPodcastID == podcast.id {
            player?.setSpeed(speed)   // saves it for the show too
        } else {
            library?.setSpeed(speed, for: podcast.id)
        }
        syncPodcastSpeeds()
    }

    /// The phone is taking over playback — tell the Watch to stop its own local audio.
    /// The two players are independent, so without this both play at once (the Watch keeps
    /// going in your ears while the phone starts a second stream).
    ///
    /// `sendMessage` is immediate but needs the Watch app to be reachable; the queued
    /// `transferUserInfo` fallback carries a timestamp so a stop delivered long after the
    /// fact can be ignored rather than silencing a later, unrelated session.
    ///
    /// The Watch replies with its live playhead. It only syncs progress when it pauses, so
    /// without that reply we'd resume from a stale position and the handoff would jump
    /// backwards to wherever the Watch last checked in.
    func stopWatchPlayback() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let queued: () -> Void = {
            WCSession.default.transferUserInfo(["type": "stopPlayback", "at": Date().timeIntervalSince1970])
        }
        guard WCSession.default.isReachable else { queued(); return }
        WCSession.default.sendMessage(["cmd": "stopPlayback"], replyHandler: { [weak self] reply in
            guard let episodeID = reply["episodeID"] as? String,
                  let position = reply["position"] as? Double else { return }
            Task { @MainActor in self?.adoptWatchPosition(episodeID: episodeID, position: position) }
        }, errorHandler: { _ in queued() })
    }

    /// Pick up exactly where the Watch was. Only applies to the episode we just started, and
    /// `adoptRemotePosition` only ever moves forward — it can't rewind you.
    private func adoptWatchPosition(episodeID: String, position: Double) {
        guard let player, player.currentEpisode?.id == episodeID else { return }
        Log.sync.notice("phone: adopting Watch playhead \(Int(position))s for \(episodeID, privacy: .public)")
        player.adoptRemotePosition(position)
    }

    func activate() {
        // The Watch pairs with the phone. (An iPad reports unsupported anyway; this says why.)
        guard DeviceRole.current.isHub, WCSession.isSupported() else { Log.sync.error("phone: WCSession unsupported"); return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        Log.sync.notice("phone: WCSession activate() called")
    }

    var isActivated: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
    }

    /// Send a downloaded episode file to the Watch for offline playback.
    func sendEpisode(fileURL: URL, episodeID: String, title: String, podcast: String,
                     cleanup: Bool = false, skipPlan: Data? = nil) {
        guard isActivated else {
            Log.sync.error("phone: sendEpisode dropped — session not activated (\(episodeID, privacy: .public))")
            return
        }
        // The WC daemon queue survives our relaunches. Re-queuing an episode already in
        // flight would upload the same multi-MB file twice.
        if WCSession.default.outstandingFileTransfers.contains(where: {
            ($0.file.metadata?["episodeID"] as? String) == episodeID
        }) {
            Log.sync.notice("phone: episode \(episodeID, privacy: .public) already in the transfer queue — skipping")
            if cleanup { try? FileManager.default.removeItem(at: fileURL) }
            return
        }
        Log.sync.notice("phone: transferring episode \(episodeID, privacy: .public) reachable=\(WCSession.default.isReachable)")
        var meta: [String: Any] = [
            "type": "episode",
            "episodeID": episodeID,
            "title": title,
            "podcast": podcast,
        ]
        if cleanup { meta["cleanup"] = true }   // transcoded temp — delete after transfer
        // Rides with the audio it describes, so the Watch can never hold an episode whose
        // markers are still queued behind a multi-megabyte transfer.
        if let skipPlan { meta["skipPlan"] = skipPlan }
        WCSession.default.transferFile(fileURL, metadata: meta)
        refreshTransferCount()
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Log.sync.notice("phone: activation completed state=\(activationState.rawValue) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        Task { @MainActor in
            self.refreshTransferCount()
            if activationState == .activated, !self.appContext.isEmpty {   // flush anything queued before activation
                try? session.updateApplicationContext(self.appContext)
            }
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    /// Immediate transport commands from the Watch remote.
    private nonisolated func completeWorkoutRoutine(_ payload: [String: Any]) {
        guard let stamp = payload["start"] as? Double, stamp.isFinite, stamp > 0,
              stamp <= Date().timeIntervalSince1970 + 60 else { return }
        let start = Date(timeIntervalSince1970: stamp)
        Task { @MainActor in
            ExceptionStore.shared.completeWorkoutRoutines(startedAt: start, routines: RoutineStore.shared.routines)
            await OccurrenceStore.shared.recompute()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmd = message["cmd"] as? String else { return }
        if cmd == "workoutStarted" { completeWorkoutRoutine(message); return }
        // A workout just ended on the Watch. A message wakes this app in the background, which
        // the workout's own file transfer doesn't: what's due after a workout rings on time.
        if cmd == "workoutEnded", let start = message["start"] as? Double, let end = message["end"] as? Double {
            Task { @MainActor in
                PlaybackDiagnostics.shared.log("🏋️ workout", "the Watch says one ended at \(Date(timeIntervalSince1970: end).formatted(date: .omitted, time: .shortened))")
                AnchoredTimingHub.shared.workoutEnded(start: Date(timeIntervalSince1970: start),
                                                      end: Date(timeIntervalSince1970: end))
            }
            return
        }
        let parent = (message["traceparent"] as? String)
            .flatMap(DiagnosticTraceContext.init(traceparent:))
        Task { @MainActor in
            switch cmd {
            case "play":     self.player?.setPlaying(true, reason: "Watch message")
            case "pause":    self.player?.setPlaying(false, reason: "Watch message")
            case "toggle":   self.player?.togglePlayPause(reason: "Watch message")
            case "skipBack": self.player?.skip(by: -15)
            case "skipFwd":  self.player?.skip(by: 30)
            case "speed":
                // The Watch's remote, for what's playing here.
                if let speed = message["speed"] as? Double,
                   PlaybackSpeeds.options.contains(where: { abs($0 - speed) < 0.001 }) {
                    self.player?.setSpeed(speed)
                    self.sendNowPlaying()
                }
            case "showSpeed":
                if let speed = message["speed"] as? Double, let title = message["podcast"] as? String {
                    self.adoptSpeedFromWatch(speed, podcastTitle: title)
                }
            case "noteStart":
                DiagnosticJournal.shared.record(
                    operation: "voiceNote.remoteControl",
                    parent: parent,
                    name: "watch_capture_started")
                // A note is being recorded on the Watch. If the podcast is playing HERE, pause it so
                // it doesn't play under the take — and snapshot our context so the Watch note gets
                // the episode/timestamp/excerpt from what WE were playing.
                if self.player?.isPlaying == true {
                    self.pausedForRemoteNote = true
                    VoiceNoteStore.shared.snapshotContextForRemoteNote()
                    self.player?.setPlaying(false, reason: "Watch voice note")
                }
            case "noteStop":
                DiagnosticJournal.shared.record(
                    operation: "voiceNote.remoteControl",
                    parent: parent,
                    name: "watch_capture_stopped")
                if self.pausedForRemoteNote {
                    self.pausedForRemoteNote = false
                    self.player?.setPlaying(true, reason: "Watch voice note done")
                }
            case "phoneNoteStart":
                // The Watch triggered a note but the PHONE holds the audio route (AirPods) — so the
                // phone records, to use the AirPods mic. beginCapture pauses/resumes the phone's own
                // podcast; publish state so the Watch button reflects the live recording.
                VoiceNoteStore.shared.beginCapture(
                    kind: .podcastCapture,
                    parent: parent)
                self.publishNoteRecording()
            case "phoneNoteStop":
                if VoiceNoteStore.shared.isRecording { VoiceNoteStore.shared.finishCapture() }
                self.publishNoteRecording()
            default: break
            }
            self.sendNowPlaying()   // reflect the new state straight back
        }
    }

    /// The Watch's night steps in the journal: a line per night, and the probe minute by minute —
    /// how a walk you timed shows up is how we learn what Core Motion can see.
    nonisolated private static func journal(_ report: NightMotionReport) {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        for window in report.windows {
            let steps = window.minutes.reduce(0) { $0 + $1.steps }
            PlaybackDiagnostics.shared.log("🌙 night motion",
                "\(window.start.formatted(.dateTime.month().day().hour().minute()))–\(window.end.formatted(time)): \(window.minutes.count) min with steps, \(steps) steps, \(window.walking.count) walking spans")
        }
        if let probe = report.probe {
            let minutes = probe.minutes.map { "\($0.start.formatted(time))=\($0.steps)" }.joined(separator: " ")
            let walking = probe.walking.map { "\($0.start.formatted(time))–\($0.end.formatted(time))" }.joined(separator: " ")
            PlaybackDiagnostics.shared.log("🚶 motion probe",
                "\(probe.start.formatted(time))–\(probe.end.formatted(time)) minutes: \(minutes.isEmpty ? "none" : minutes) · walking: \(walking.isEmpty ? "none" : walking)")
        }
    }

    /// Messages from the Watch about direct downloads.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo["type"] as? String == "workoutStarted" { completeWorkoutRoutine(userInfo); return }
        if userInfo["type"] as? String == "guidedWorkoutCompletion",
           let data = userInfo["completion"] as? Data,
           let completion = try? JSONDecoder().decode(WorkoutCompletion.self, from: data) {
            Task { @MainActor in WellnessStore.shared.recordWorkoutCompletion(completion) }
            return
        }
        // Sent this way when the phone couldn't be reached at the moment of the tap.
        if userInfo["type"] as? String == "showSpeed",
           let speed = userInfo["speed"] as? Double, let title = userInfo["podcast"] as? String {
            Task { @MainActor in self.adoptSpeedFromWatch(speed, podcastTitle: title) }
            return
        }
        if userInfo["type"] as? String == "nightMotion",
           let data = userInfo["report"] as? Data,
           let report = try? JSONDecoder().decode(NightMotionReport.self, from: data) {
            Self.journal(report)
            Task { @MainActor in NightMotionStore.shared.merge(report) }
            return
        }
        // Checked before the episodeID guard below: an inventory report is about the whole
        // Watch, not one episode, and the guard would have dropped it.
        if userInfo["type"] as? String == "watchInventory" {
            let ids = Set(userInfo["episodeIDs"] as? [String] ?? [])
            let short = userInfo["watchShortVersion"] as? String
            let build = userInfo["watchBuild"] as? String
            Log.sync.notice("phone: Watch reports \(ids.count, privacy: .public) episode(s), version \(short ?? "?", privacy: .public) (\(build ?? "?", privacy: .public))")
            Task { @MainActor in
                self.downloads?.reconcileWatchInventory(ids)
                if let short, let build {
                    self.watchVersion = "\(short) (\(build))"
                    HubStatusStore.shared.update { $0.watchVersion = "\(short) (\(build))" }
                }
            }
            return
        }
        guard let id = userInfo["episodeID"] as? String else { return }
        switch userInfo["type"] as? String {
        case "episodeOnWatch":   // direct download succeeded — stop trying to send it
            Log.sync.notice("phone: episode \(id, privacy: .public) confirmed on Watch")
            Task { @MainActor in self.downloads?.markTransferred(id) }
        case "fileFallback":     // direct download failed — transfer the file instead
            Log.sync.notice("phone: Watch requested file fallback for \(id, privacy: .public)")
            Task { @MainActor in
                await self.library?.whenLoaded()   // needs the episode catalogue to find the file
                self.downloads?.sendFileFallback(id)
            }
        case "skipCorrection":
            // A wrong skip on the wrist is still a wrong skip. The Watch keeps no correction book
            // of its own — two books either side of an intermittent link would need merging, and
            // there is nothing to merge that this one message doesn't already carry — so it names
            // the span it rewound into and the book on this device does the learning.
            guard let spanID = userInfo["spanID"] as? String else { return }
            Log.sync.notice("phone: Watch reports a wrong skip in \(id, privacy: .public)")
            Task { @MainActor in self.skipPlans?.recordWatchCorrection(episodeID: id, spanID: spanID) }
        case "listenProgress":   // resume position / completion listened on the Watch
            let position = userInfo["position"] as? Double ?? 0
            let completed = userInfo["completed"] as? Bool ?? false
            let rawAt = Date(timeIntervalSince1970: userInfo["at"] as? TimeInterval ?? 0)
            Task { @MainActor in
                // The ownership test below compares this against our own stamps, so it has to be
                // bounded here too — `applyRemoteProgress` clamps as well, but only after this
                // decision has already been made. Clamping twice is harmless; the second sees a
                // value already in the past.
                let at = PlaybackSyncClock.received(rawAt)
                // The library decodes off-main at launch; this userInfo can arrive in a process
                // launched purely to receive it. Applying against a not-yet-loaded library would
                // find no matching podcast and silently DROP the Watch's progress — WC delivers
                // userInfo exactly once.
                await self.library?.whenLoaded()
                // Who owns "current episode"? The rule lives in PodcastLibrary now, so the Watch
                // relay and the CloudKit path decide this identically — it was inline here, which
                // is precisely why the cloud path couldn't reach it and gave up instead.
                let makeCurrent = self.library?
                    .remoteReportShouldTakeCurrent(episodeID: id, at: at) ?? false
                if !makeCurrent, self.player?.currentEpisode?.id != id {
                    Log.sync.notice("phone: keeping its own current episode; Watch report for \(id, privacy: .public) is older")
                }
                self.library?.applyRemoteProgress(episodeID: id, position: position, completed: completed,
                                                  at: at, makeCurrent: makeCurrent)
            }
        default:
            break
        }
    }

    /// Send the phone's playback position / completion to the Watch (queued delivery).
    func sendListenProgress(episodeID: String, position: Double, duration: Double, completed: Bool) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "type": "listenProgress",
            "episodeID": episodeID,
            "position": position,
            "duration": duration,
            "completed": completed,
            "at": Date().timeIntervalSince1970,
        ])
    }

    /// A file we sent finished transferring — mark synced episodes so backfill skips them.
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard (fileTransfer.file.metadata?["type"] as? String) == "episode",
              let episodeID = fileTransfer.file.metadata?["episodeID"] as? String else { return }
        if error == nil {
            Task { @MainActor in self.downloads?.markTransferred(episodeID) }
        }
        Task { @MainActor in self.refreshTransferCount() }
        // Delete the transcoded temp once the transfer finishes (either way).
        if (fileTransfer.file.metadata?["cleanup"] as? Bool) == true {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
    }

    /// Receive a recorded workout file from the Watch: summary is in metadata,
    /// raw samples are newline-delimited JSON in the file body.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Log.sync.notice("phone: didReceive file type=\(file.metadata?["type"] as? String ?? "nil", privacy: .public)")

        if (file.metadata?["type"] as? String) == "diagnostics" {
            do {
                try DiagnosticJournal.shared.ingestPeerSnapshot(
                    fileURL: file.fileURL,
                    source: file.metadata?["source"] as? String ?? "watchOS")
                DiagnosticJournal.shared.record(
                    operation: "diagnostics.transfer",
                    name: "peer_snapshot_ingested",
                    attributes: [
                        "source": file.metadata?["source"] as? String ?? "watchOS",
                        "reason": file.metadata?["reason"] as? String ?? "unknown",
                    ])
            } catch {
                DiagnosticJournal.shared.record(
                    operation: "diagnostics.transfer",
                    name: "peer_snapshot_ingest_failed",
                    attributes: ["error": error.localizedDescription])
            }
            return
        }

        // A voice note recorded on the Watch. Copy it out of the inbox (which is emptied when this
        // returns) and hand it to the store, which fills in context, transcribes, and files it.
        if (file.metadata?["type"] as? String) == "voiceNote" {
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            try? FileManager.default.moveItem(at: file.fileURL, to: staged)
            let meta = file.metadata ?? [:]
            Task { @MainActor in VoiceNoteStore.shared.ingestWatchNote(audio: staged, meta: meta) }
            return
        }

        guard (file.metadata?["type"] as? String) == "fitness",
              let meta = file.metadata,
              let idString = meta["id"] as? String, let id = UUID(uuidString: idString),
              let start = meta["start"] as? Double, let end = meta["end"] as? Double,
              let activity = meta["activity"] as? String else {
            Log.sync.error("phone: didReceive fitness guard failed / unreadable")
            return
        }
        let parentTrace = (meta["traceparent"] as? String)
            .flatMap(DiagnosticTraceContext.init(traceparent:))
        let ingestTrace = DiagnosticJournal.shared.startSpan(
            "workout.ingest",
            parent: parentTrace,
            attributes: [
                "session_id": idString.lowercased(),
                "declared_sample_count": String(meta["count"] as? Int ?? 0),
                "format": meta["format"] as? String ?? "legacy",
            ])

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id.uuidString)-watch.samples")
        try? FileManager.default.removeItem(at: staged)
        let samples: [FitnessSample]
        switch meta["format"] as? String {
        case "bin-lzfse":
            guard let data = try? Data(contentsOf: file.fileURL) else {
                Log.sync.error("phone: compressed workout unreadable")
                DiagnosticJournal.shared.finish(
                    ingestTrace,
                    status: .failed,
                    reason: "compressed_file_unreadable")
                return
            }
            guard let bin = try? (data as NSData).decompressed(using: .lzfse) as Data else {
                Log.sync.error("phone: workout decompression failed")
                DiagnosticJournal.shared.finish(
                    ingestTrace,
                    status: .failed,
                    reason: "decompression_failed",
                    attributes: ["compressed_bytes": String(data.count)])
                return
            }
            samples = FitnessSample.decodeBinary(bin)
            try? bin.write(to: staged, options: .atomic)
        case "bin":
            guard let data = try? Data(contentsOf: file.fileURL) else {
                Log.sync.error("phone: binary workout unreadable")
                DiagnosticJournal.shared.finish(
                    ingestTrace,
                    status: .failed,
                    reason: "binary_file_unreadable")
                return
            }
            samples = FitnessSample.decodeBinary(data)
            // Preserve the exact binary payload instead of decoding it and then allocating a
            // second full-size encode on the main actor.
            try? data.write(to: staged, options: .atomic)
        default:   // legacy newline-delimited JSON
            guard let data = try? Data(contentsOf: file.fileURL) else {
                Log.sync.error("phone: legacy workout unreadable")
                DiagnosticJournal.shared.finish(
                    ingestTrace,
                    status: .failed,
                    reason: "legacy_file_unreadable")
                return
            }
            let decoder = JSONDecoder()
            samples = data.split(separator: 0x0a).compactMap { try? decoder.decode(FitnessSample.self, from: $0) }
            try? FitnessSample.encodeBinary(samples).write(to: staged, options: .atomic)
        }
        let declaredCount = meta["count"] as? Int ?? 0
        guard declaredCount == 0 || !samples.isEmpty else {
            DiagnosticJournal.shared.finish(
                ingestTrace,
                status: .failed,
                reason: "decoded_sample_set_empty",
                attributes: ["declared_sample_count": String(declaredCount)])
            return
        }

        Log.sync.notice("phone: received workout \(idString, privacy: .public) format=\(meta["format"] as? String ?? "jsonl", privacy: .public) samples=\(samples.count)")
        Task { @MainActor in
            let startedAt = Date(timeIntervalSince1970: start)
            let firstOutdoorLocation = samples.first { $0.kind == .location && $0.v2 != nil }
            let outdoorConditions = firstOutdoorLocation.flatMap {
                WeatherStore.shared.outdoorConditions(lat: $0.v1, lon: $0.v2!, at: startedAt)
            }
            let fitnessSession = FitnessSession(
                id: id, start: startedAt, end: Date(timeIntervalSince1970: end), activity: activity,
                avgHeartRate: meta["avgHR"] as? Double, totalEnergy: meta["energy"] as? Double,
                totalDistance: meta["distance"] as? Double, poolLengthMeters: meta["poolLength"] as? Double,
                laps: ((meta["lapDurations"] as? [Double]) ?? []).enumerated().map {
                    FitnessLap(number: $0.offset + 1, duration: $0.element)
                }, outdoorConditions: outdoorConditions,
                pauses: WorkoutPauses.fromFlat((meta["pauses"] as? [Double]) ?? []), samples: samples)
            let stagedURL = FileManager.default.fileExists(atPath: staged.path) ? staged : nil
            let accepted = await self.fitnessStore?.ingestFromWatch(
                fitnessSession, stagedSamplesURL: stagedURL) ?? false
            Log.sync.notice("phone: ingested workout (store=\(self.fitnessStore == nil ? "nil!" : "ok", privacy: .public) accepted=\(accepted))")
            // Ack only after the durable raw file + summary are accepted. WCSession returning
            // from didReceive merely means transport succeeded; acknowledging earlier let the
            // Watch delete its sole copy while the phone ingest was still queued.
            if accepted {
                // What's due after a workout rings from its end — here, not only from the app's
                // startup wiring, which hasn't run when the phone was woken in the background.
                AnchoredTimingHub.shared.workoutEnded(start: fitnessSession.start, end: fitnessSession.end)
                WCSession.default.transferUserInfo([
                    "type": "workoutAck",
                    "id": idString,
                    "traceparent": ingestTrace.context.traceparent,
                ])
                DiagnosticJournal.shared.finish(
                    ingestTrace,
                    status: .succeeded,
                    reason: "durably_ingested_and_acknowledged",
                    attributes: ["decoded_sample_count": String(samples.count)])
            } else if let stagedURL {
                // A missing store or failed install must not leave multi-megabyte inbox copies in
                // tmp forever. The Watch retained its original because no ACK was sent.
                try? FileManager.default.removeItem(at: stagedURL)
                DiagnosticJournal.shared.finish(
                    ingestTrace,
                    status: .failed,
                    reason: self.fitnessStore == nil
                        ? "fitness_store_unavailable"
                        : "fitness_store_rejected",
                    attributes: ["decoded_sample_count": String(samples.count)])
            } else {
                DiagnosticJournal.shared.finish(
                    ingestTrace,
                    status: .failed,
                    reason: "staged_samples_unavailable",
                    attributes: ["decoded_sample_count": String(samples.count)])
            }
        }
    }
}
#endif
