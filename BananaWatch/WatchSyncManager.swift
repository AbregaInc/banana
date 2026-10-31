import Foundation
import CoreMotion
import WatchConnectivity
import WidgetKit
import os

private let syncLog = Logger(subsystem: "com.boris.banana", category: "sync")

/// The single watch-side WatchConnectivity delegate: sends recorded workout
/// files to the phone (deleting them locally once transferred) and receives
/// downloaded podcast episode files from the phone.
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()

    private let diagnosticLock = NSLock()
    private var pendingDiagnosticSnapshots: [(url: URL, id: String, reason: String)] = []

    /// Last calendar snapshot actually persisted to the Keychain, so a context push that carries
    /// the same events we already hold — every unrelated push (play/pause, settings, plan)
    /// rides the same merged dict — skips the SecItemUpdate + widget-extension relaunch. Lazily
    /// seeded from the store on first use rather than at init, since WatchCalendarSnapshotStore
    /// touches the Keychain and `apply(context:)` already runs on the MainActor.
    @MainActor private var lastCalendarItems: [WatchCalendarItem]?

    func activate() {
        guard WCSession.isSupported() else { syncLog.error("watch: WCSession unsupported"); return }
        recoverDiagnosticOutbox()
        WCSession.default.delegate = self
        WCSession.default.activate()
        syncLog.notice("watch: WCSession activate() called")
    }

    func sendWorkoutPlanCompletion(_ completion: WorkoutCompletion) {
        guard let data = try? JSONEncoder().encode(completion), WCSession.isSupported() else { return }
        WCSession.default.transferUserInfo(["type": "guidedWorkoutCompletion", "completion": data])
    }

    private var toResend: [WorkoutSummary] = []
    private func compressedURL(for id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent("session-\(id).lz")
    }

    /// Re-send any recorded workouts whose sample file is still present (i.e. the
    /// phone never acked receipt). Called on launch and on activation.
    func resendPending(_ summaries: [WorkoutSummary]) {
        toResend = summaries
        flushResend()
    }
    private func flushResend() {
        guard WCSession.default.activationState == .activated else { return }
        // WC file transfers persist in the daemon's queue across our relaunches. Re-queuing
        // without checking stacked a duplicate multi-MB upload per launch until the ack arrived —
        // radio spend on both devices for bytes already in flight.
        let inFlight = Set(WCSession.default.outstandingFileTransfers.compactMap {
            $0.file.metadata?["id"] as? String
        })
        for summary in toResend {
            let idString = summary.id.uuidString
            guard !inFlight.contains(idString) else { continue }
            let url = compressedURL(for: idString)
            if FileManager.default.fileExists(atPath: url.path) {
                syncLog.notice("watch: re-sending un-acked workout \(idString)")
                sendWorkout(fileURL: url, summary: summary)
            }
        }
    }

    /// Incident-only transfer. The normal journal stays local; a snapshot crosses the radio only
    /// after an unfinished operation is recovered or a critical workflow fails validation.
    func queueDiagnosticSnapshot(reason: String) {
        guard let temporaryURL = DiagnosticJournal.shared.exportSnapshot() else { return }
        let id = UUID().uuidString.lowercased()
        let outbox = DiagnosticJournal.shared.directory
            .appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: outbox,
            withIntermediateDirectories: true)
        let url = outbox.appendingPathComponent(id).appendingPathExtension("txt")
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }
        diagnosticLock.lock()
        pendingDiagnosticSnapshots.append(
            (url: url, id: id, reason: reason))
        diagnosticLock.unlock()
        flushDiagnosticSnapshots()
    }

    private func recoverDiagnosticOutbox() {
        let outbox = DiagnosticJournal.shared.directory
            .appendingPathComponent("Outbox", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: outbox,
            includingPropertiesForKeys: nil)) ?? []
        diagnosticLock.lock()
        let known = Set(pendingDiagnosticSnapshots.map(\.id))
        for url in files where !known.contains(url.deletingPathExtension().lastPathComponent) {
            pendingDiagnosticSnapshots.append((
                url: url,
                id: url.deletingPathExtension().lastPathComponent,
                reason: "recovered_diagnostic_outbox"))
        }
        diagnosticLock.unlock()
    }

    private func flushDiagnosticSnapshots() {
        guard WCSession.default.activationState == .activated else { return }
        let inFlight = Set(WCSession.default.outstandingFileTransfers.compactMap {
            $0.file.metadata?["snapshotID"] as? String
        })
        diagnosticLock.lock()
        let ready = pendingDiagnosticSnapshots.filter { !inFlight.contains($0.id) }
        pendingDiagnosticSnapshots.removeAll { snapshot in
            ready.contains { $0.id == snapshot.id }
        }
        diagnosticLock.unlock()
        for snapshot in ready {
            WCSession.default.transferFile(snapshot.url, metadata: [
                "type": "diagnostics",
                "source": "watchOS",
                "snapshotID": snapshot.id,
                "reason": snapshot.reason,
            ])
        }
    }

    /// Queue for an offline phone as well as delivering immediately when it can be reached.
    func announceWorkoutStarted(id: UUID, start: Date) {
        guard WCSession.isSupported() else { return }
        let payload: [String: Any] = ["type": "workoutStarted", "cmd": "workoutStarted",
                                      "id": id.uuidString, "start": start.timeIntervalSince1970]
        WCSession.default.transferUserInfo(payload)
        if WCSession.default.activationState == .activated && WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    /// Tell the phone a workout just ended. A message wakes the phone app in the background;
    /// the workout's file transfer waits for it to be opened. So what's due after a workout
    /// (Creatine "after your workout") rings when the workout ends, not when Banana next runs.
    /// Only when the phone is in reach — the file still follows either way.
    func announceWorkoutEnded(_ summary: WorkoutSummary) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([
            "cmd": "workoutEnded",
            "id": summary.id.uuidString,
            "start": summary.start.timeIntervalSince1970,
            "end": summary.end.timeIntervalSince1970,
        ], replyHandler: nil, errorHandler: nil)
    }

    /// Transfer a finished workout's sample file to the phone. Summary travels in
    /// metadata; the raw samples are the file. The local file is deleted on success.
    func sendWorkout(fileURL: URL, summary: WorkoutSummary) {
        guard WCSession.isSupported() else { return }
        var meta: [String: Any] = [
            "type": "fitness",
            "id": summary.id.uuidString,
            "start": summary.start.timeIntervalSince1970,
            "end": summary.end.timeIntervalSince1970,
            "activity": summary.activity,
            "count": summary.sampleCount,
            "format": "bin-lzfse",
        ]
        if let hr = summary.avgHeartRate { meta["avgHR"] = hr }
        if let e = summary.totalEnergy { meta["energy"] = e }
        if let d = summary.totalDistance { meta["distance"] = d }
        if let lapLength = summary.poolLengthMeters { meta["poolLength"] = lapLength }
        if !summary.lapDurations.isEmpty { meta["lapDurations"] = summary.lapDurations }
        if !summary.pauses.isEmpty { meta["pauses"] = WorkoutPauses.flat(summary.pauses) }
        if let traceparent = summary.traceparent { meta["traceparent"] = traceparent }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        syncLog.notice("watch: transferring workout \(summary.id.uuidString) samples=\(summary.sampleCount) bytes=\(size) activated=\(WCSession.default.activationState == .activated)")
        WCSession.default.transferFile(fileURL, metadata: meta)
    }

    /// Tell the phone a skip it planned was wrong — the wearer rewound back into it.
    ///
    /// The Watch keeps no correction book: it has no detector to demote, and two books either
    /// side of an intermittent link would need merging for no gain over this one message. The
    /// phone owns the learning; the Watch just reports what happened on the wrist.
    static func sendSkipCorrection(episodeID: String, spanID: String) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "type": "skipCorrection", "episodeID": episodeID, "spanID": spanID,
        ])
    }

    /// Send Watch playback position / completion to the phone (queued delivery).
    static func sendListenProgress(episodeID: String, position: Double, duration: Double, completed: Bool) {
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

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        syncLog.notice("watch: activation completed state=\(activationState.rawValue) error=\(error?.localizedDescription ?? "none")")
        flushResend()
        flushDiagnosticSnapshots()
        // Apply whatever context the phone sent while this app wasn't running.
        let ctx = session.receivedApplicationContext
        if !ctx.isEmpty { apply(context: ctx) }
        // Say what we actually hold. On a freshly installed Watch app this is empty, which is
        // exactly the case the phone could never otherwise detect.
        reportInventory()
    }

    /// The phone tells us which podcast is its Workout source (title match) so we can
    /// auto-play a downloaded episode of it when a workout starts.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(context: applicationContext)
    }

    /// A show's speed chosen on the Watch, for the phone to keep: at once when it's in reach,
    /// queued otherwise.
    static func sendShowSpeed(_ speed: Double, podcast: String) {
        guard WCSession.isSupported() else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["cmd": "showSpeed", "podcast": podcast, "speed": speed],
                                          replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(["type": "showSpeed", "podcast": podcast, "speed": speed])
            }
        } else {
            WCSession.default.transferUserInfo(["type": "showSpeed", "podcast": podcast, "speed": speed])
        }
    }

    private func apply(context: [String: Any]) {
        Task { @MainActor in
            if let data = context["guidedWorkoutPlan"] as? Data {
                WatchWorkoutPlanStore.shared.apply(data)
            }
            if context["workoutPodcast"] != nil {
                let title = context["workoutPodcast"] as? String
                let normalized = (title?.isEmpty == false) ? title : nil
                if WatchEpisodeStore.shared.workoutPodcast != normalized {
                    WatchEpisodeStore.shared.workoutPodcast = normalized
                }
            }
            if let pool = context["workoutPodcasts"] as? [String], WatchEpisodeStore.shared.workoutPodcasts != pool {
                WatchEpisodeStore.shared.workoutPodcasts = pool
            }
            if let speeds = context["podcastSpeeds"] as? [String: Double] {
                WatchEpisodeStore.shared.adoptSpeeds(speeds)
                WatchAudioPlayer.shared.speedsChanged()
            }
            if let unit = context["distanceUnit"] as? String {
                let useMiles = (unit == "miles")
                if WatchEpisodeStore.shared.useMiles != useMiles {
                    WatchEpisodeStore.shared.useMiles = useMiles
                }
            }
            if let pool = context["poolLengthMeters"] as? Double, pool > 0, WatchEpisodeStore.shared.poolLengthMeters != pool {
                WatchEpisodeStore.shared.poolLengthMeters = pool
            }
            if let manifest = context["watchEpisodes"] as? [String] {
                let keep = Set(manifest)
                WatchEpisodeStore.shared.pruneNotIn(keep)
                WatchSkipPlanStore.shared.prune(keeping: keep)
            }
            if let payload = context["calendarItems"] as? [[String: Any]] {
                let items = payload.compactMap { value -> WatchCalendarItem? in
                    guard let id = value["id"] as? String,
                          let title = value["title"] as? String,
                          let start = value["start"] as? TimeInterval,
                          let end = value["end"] as? TimeInterval,
                          end > start else { return nil }
                    let location = value["location"] as? String
                    return WatchCalendarItem(
                        id: id,
                        title: title,
                        start: Date(timeIntervalSince1970: start),
                        end: Date(timeIntervalSince1970: end),
                        location: location?.isEmpty == false ? location : nil)
                }.sorted { $0.start < $1.start }   // match WatchCalendarSnapshotStore.load()'s order
                if lastCalendarItems == nil {
                    lastCalendarItems = WatchCalendarSnapshotStore.load()
                }
                if items != lastCalendarItems {
                    if WatchCalendarSnapshotStore.save(items) {
                        // Only remember this as applied once the write actually lands — a
                        // transient Keychain failure (e.g. before first unlock) must keep
                        // retrying on the next identical push, exactly as it does today.
                        lastCalendarItems = items
                        WidgetCenter.shared.reloadTimelines(ofKind: WatchCalendarSnapshotStore.widgetKind)
                    } else {
                        syncLog.error("watch: could not persist calendar complication snapshot")
                    }
                }
            }
            // The phone handing us its current episode — the mirror of the Watch report the phone
            // weighs in `PhoneConnectivity`, and it applies the same two-part rule.
            //
            // It rides applicationContext rather than transferUserInfo deliberately: context is
            // latest-state-wins and coalesces, which is what "what is current" wants. The
            // userInfo queue would let a stale claim arrive after a fresh one. Progress reports
            // stay on the queue, because there every single one matters.
            if let at = context["currentEpisodeAt"] as? TimeInterval {
                let claimed = context["currentEpisodeID"] as? String
                // Never move current out from under a Watch that is actively playing something
                // else — pressing play here has to mean more than a context push from a pocket.
                let player = WatchAudioPlayer.shared
                let busyElsewhere = player.isPlaying && player.currentID != nil
                    && player.currentID != claimed
                if busyElsewhere {
                    syncLog.notice("watch: keeping its own current episode; phone's claim arrived mid-playback")
                } else {
                    WatchEpisodeStore.shared.applyRemoteCurrent(
                        claimed, at: Date(timeIntervalSince1970: at))
                }
            }
            WatchPhoneRemote.shared.update(from: context)
        }
    }

    /// The phone pruned/deleted an episode — remove our downloaded copy.
    /// Tell the phone an episode is now on the Watch (direct download succeeded).
    func confirmEpisodeOnWatch(_ episodeID: String) {
        guard WCSession.isSupported() else { return }
        WCSession.default.transferUserInfo(["type": "episodeOnWatch", "episodeID": episodeID])
    }

    /// Tell the phone exactly which episodes this Watch actually holds.
    ///
    /// The phone tracks what it believes it delivered (`DownloadManager.transferred`) and skips
    /// those on backfill. Nothing ever contradicted that belief, so anything that empties the
    /// Watch — a reinstall, or the app being removed with its container — left the phone certain
    /// it had already sent episodes the Watch no longer has, and backfill skipped every one of
    /// them forever. Only the Watch knows the truth, so the Watch has to say it.
    ///
    /// Sent after the store has loaded, so an empty list means genuinely empty rather than
    /// not-read-yet — the phone treats it as "re-send everything".
    func reportInventory() {
        guard WCSession.isSupported() else { return }
        // The store is main-actor isolated and this is called from the WC delegate, which is not.
        Task { @MainActor in
            guard WCSession.default.activationState == .activated else { return }
            let ids = WatchEpisodeStore.shared.episodes.map(\.id)
            // Ride the version along with the inventory: same trigger (activation), and it means
            // the phone can always answer "what is the Watch actually running?" — which nothing
            // could, so a mismatched pair looked like a bug in whatever you tried next.
            let info = Bundle.main.infoDictionary
            WCSession.default.transferUserInfo([
                "type": "watchInventory",
                "episodeIDs": ids,
                "watchShortVersion": info?["CFBundleShortVersionString"] as? String ?? "?",
                "watchBuild": info?["CFBundleVersion"] as? String ?? "?",
            ])
        }
    }

    /// Ask the phone to transfer an episode file (direct download failed / no network).
    func requestFileFallback(_ episodeID: String) {
        guard WCSession.isSupported() else { return }
        WCSession.default.transferUserInfo(["type": "fileFallback", "episodeID": episodeID])
    }

    /// Immediate commands from the phone. Right now: "the phone started playing, stop yours."
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["cmd"] as? String == "stopPlayback" else { return }
        stopLocalPlayback()
    }

    /// Same, but the phone wants our playhead back so it can resume exactly where we were —
    /// we only sync progress on pause, so its stored position is stale mid-listen.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["cmd"] as? String == "stopPlayback" else { replyHandler([:]); return }
        Task { @MainActor in
            let player = WatchAudioPlayer.shared
            if player.isPlaying, let id = player.currentID {
                replyHandler(["episodeID": id, "position": player.currentPosition])
                syncLog.notice("watch: phone took over playback — stopping local audio")
                player.stop()
            } else {
                replyHandler([:])
            }
        }
    }

    /// Queued fallback for `stopPlayback` (the Watch app wasn't reachable). Ignore a stale one
    /// so it can't silence a session the user started long after the phone's handoff.
    private func stopLocalPlayback(sentAt: Date? = nil) {
        if let sentAt, Date().timeIntervalSince(sentAt) > 120 {
            syncLog.notice("watch: ignoring stale stopPlayback")
            return
        }
        Task { @MainActor in
            guard WatchAudioPlayer.shared.isPlaying else { return }
            syncLog.notice("watch: phone took over playback — stopping local audio")
            WatchAudioPlayer.shared.stop()
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        switch userInfo["type"] as? String {
        case "stopPlayback":
            let at = (userInfo["at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            stopLocalPlayback(sentAt: at)
        case "downloadEpisode":
            if let id = userInfo["episodeID"] as? String,
               let urlString = userInfo["url"] as? String, let url = URL(string: urlString) {
                let title = userInfo["title"] as? String ?? "Episode"
                let podcast = userInfo["podcast"] as? String ?? ""
                let plan = userInfo["skipPlan"] as? Data
                Task { @MainActor in
                    if let plan { WatchSkipPlanStore.shared.adopt(plan, for: id) }
                    WatchDownloadManager.shared.download(episodeID: id, title: title, podcast: podcast, url: url)
                }
            }
        case "skipPlan":
            // The phone learned something after this episode was already delivered — a transcript
            // finished overnight, or a correction retired a detector. Latest send wins.
            if let id = userInfo["episodeID"] as? String, let plan = userInfo["skipPlan"] as? Data {
                Task { @MainActor in WatchSkipPlanStore.shared.adopt(plan, for: id) }
            }
        case "deleteEpisode":
            if let episodeID = userInfo["episodeID"] as? String {
                Task { @MainActor in WatchEpisodeStore.shared.delete(episodeID: episodeID) }
            }
        case "workoutAck":
            if let id = userInfo["id"] as? String {
                try? FileManager.default.removeItem(at: compressedURL(for: id))
                syncLog.notice("watch: workout \(id) acked by phone — deleted local file")
                let parent = (userInfo["traceparent"] as? String)
                    .flatMap(DiagnosticTraceContext.init(traceparent:))
                DiagnosticJournal.shared.record(
                    operation: "workout.transfer",
                    parent: parent,
                    name: "phone_acknowledged",
                    attributes: ["session_id": id.lowercased()])
            }
        case "listenProgress":
            if let id = userInfo["episodeID"] as? String {
                let position = userInfo["position"] as? Double ?? 0
                let duration = userInfo["duration"] as? Double ?? 0
                let completed = userInfo["completed"] as? Bool ?? false
                let at = Date(timeIntervalSince1970: userInfo["at"] as? TimeInterval ?? 0)
                Task { @MainActor in
                    WatchEpisodeStore.shared.applyRemoteProgress(episodeID: id, position: position, duration: duration, completed: completed, at: at)
                }
            }
        default:
            break
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if (fileTransfer.file.metadata?["type"] as? String) == "fitness" {
            // Keep the file until the PHONE acks receipt (a completed WC transfer
            // doesn't guarantee the phone actually ingested it). Deletion happens in
            // the workoutAck handler below.
            syncLog.notice("watch: workout transfer finished error=\(error?.localizedDescription ?? "none") (awaiting phone ack)")
            let parent = (fileTransfer.file.metadata?["traceparent"] as? String)
                .flatMap(DiagnosticTraceContext.init(traceparent:))
            DiagnosticJournal.shared.record(
                operation: "workout.transfer",
                parent: parent,
                name: error == nil ? "transport_finished_awaiting_ingest" : "transport_failed",
                attributes: error.map { ["error": $0.localizedDescription] } ?? [:])
        } else if (fileTransfer.file.metadata?["type"] as? String) == "voiceNote" {
            let parent = (fileTransfer.file.metadata?["traceparent"] as? String)
                .flatMap(DiagnosticTraceContext.init(traceparent:))
            DiagnosticJournal.shared.record(
                operation: "voiceNote.transfer",
                parent: parent,
                name: error == nil ? "transport_finished" : "transport_failed",
                attributes: error.map { ["error": $0.localizedDescription] } ?? [:])
            if error == nil {
                try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            }
        } else if (fileTransfer.file.metadata?["type"] as? String) == "diagnostics" {
            if error == nil {
                try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            } else {
                diagnosticLock.lock()
                pendingDiagnosticSnapshots.append((
                    url: fileTransfer.file.fileURL,
                    id: fileTransfer.file.metadata?["snapshotID"] as? String
                        ?? UUID().uuidString.lowercased(),
                    reason: fileTransfer.file.metadata?["reason"] as? String
                        ?? "diagnostic_transfer_failed"))
                diagnosticLock.unlock()
            }
        }
    }

    /// Receive an episode audio file pushed from the phone.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        syncLog.notice("watch: didReceive file type=\(file.metadata?["type"] as? String ?? "nil")")
        guard (file.metadata?["type"] as? String) == "episode",
              let episodeID = file.metadata?["episodeID"] as? String else { return }
        syncLog.notice("watch: received episode \(episodeID)")
        let title = file.metadata?["title"] as? String ?? "Episode"
        let podcast = file.metadata?["podcast"] as? String ?? ""
        let skipPlan = file.metadata?["skipPlan"] as? Data
        let ext = file.fileURL.pathExtension.isEmpty ? "mp3" : file.fileURL.pathExtension

        // fileURL is only valid during this call — stage it now, then hand to the store.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: file.fileURL, to: staged) } catch { return }

        Task { @MainActor in
            // The plan first: an episode must never exist here with its markers still in flight,
            // or the first play of it is the one that keeps the ads.
            if let skipPlan { WatchSkipPlanStore.shared.adopt(skipPlan, for: episodeID) }
            WatchEpisodeStore.shared.add(episodeID: episodeID, title: title, podcast: podcast,
                                         from: staged, ext: ext)
        }
    }
}

// MARK: - Night motion

/// Reads the night's steps minute by minute from Core Motion and sends them to the phone, which
/// uses them to time night wake-ups (`NightMotionReport`). Health keeps the Watch's steps only as
/// chunks of several minutes; Core Motion answers for any range, and keeps a week of history —
/// so opening the app any time in the week catches up.
///
/// Half-hour blocks first, then minute by minute only inside blocks with steps: a night is
/// mostly still, so that's a few dozen queries rather than hundreds.
@MainActor final class NightMotionHarvester {
    static let shared = NightMotionHarvester()

    private let pedometer = CMPedometer()
    private let activity = CMMotionActivityManager()
    private var running = false
    private static let lastRunKey = "nightMotionLastRun"
    /// Windows ending by this were sent whole.
    private static let sentThroughKey = "nightMotionSentThrough"
    private static let log = Logger(subsystem: "com.boris.banana", category: "nightmotion")

    func harvestIfDue(now: Date = Date()) {
        guard !running, CMPedometer.isStepCountingAvailable(),
              CMPedometer.authorizationStatus() != .denied, CMPedometer.authorizationStatus() != .restricted else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date,
           now.timeIntervalSince(last) < 2 * 60 { return }
        running = true
        Task {
            await harvest(now: now)
            running = false
        }
    }

    /// 8 pm to 11 am, for each of the last seven nights.
    static func windows(now: Date, calendar: Calendar = .current) -> [(start: Date, end: Date)] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { daysAgo -> (Date, Date)? in
            guard let morning = calendar.date(byAdding: .day, value: -daysAgo, to: today),
                  let start = calendar.date(byAdding: .hour, value: -4, to: morning),
                  let end = calendar.date(byAdding: .hour, value: 11, to: morning),
                  start < now else { return nil }
            return (start, min(end, now))
        }
    }

    private func harvest(now: Date) async {
        let sentThrough = UserDefaults.standard.object(forKey: Self.sentThroughKey) as? Date ?? .distantPast
        var report = NightMotionReport(windows: [], probe: nil, generated: now)
        var completeThrough = sentThrough
        for (start, end) in Self.windows(now: now) where end > sentThrough {
            guard let window = await read(start, end) else { continue }
            report.windows.append(window)
            if end < now { completeThrough = max(completeThrough, end) }
        }
        report.probe = await read(now.addingTimeInterval(-2 * 3_600), now)
        UserDefaults.standard.set(now, forKey: Self.lastRunKey)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? JSONEncoder().encode(report) else { return }
        WCSession.default.transferUserInfo(["type": "nightMotion", "report": data])
        UserDefaults.standard.set(completeThrough, forKey: Self.sentThroughKey)
        Self.log.notice("sent \(report.windows.count) night window(s), probe \(report.probe?.minutes.count ?? 0) min with steps")
    }

    /// Nil when Core Motion won't answer (no permission, or older than its week of history).
    private func read(_ start: Date, _ end: Date) async -> NightMotionReport.Window? {
        var minutes: [NightMotionReport.Minute] = []
        var blockStart = start
        var answered = false
        while blockStart < end {
            let blockEnd = min(blockStart.addingTimeInterval(30 * 60), end)
            if let steps = await steps(blockStart, blockEnd) {
                answered = true
                if steps > 0 {
                    var minute = blockStart
                    while minute < blockEnd {
                        let next = min(minute.addingTimeInterval(60), blockEnd)
                        if let s = await self.steps(minute, next), s > 0 {
                            minutes.append(.init(start: minute, steps: s))
                        }
                        minute = next
                    }
                }
            }
            blockStart = blockEnd
        }
        guard answered else { return nil }
        return .init(start: start, end: end, minutes: minutes, walking: await walking(start, end))
    }

    private func steps(_ from: Date, _ to: Date) async -> Int? {
        await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: from, to: to) { data, _ in
                continuation.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }

    private func walking(_ from: Date, _ to: Date) async -> [NightMotionReport.Span] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        let activities: [CMMotionActivity] = await withCheckedContinuation { continuation in
            activity.queryActivityStarting(from: from, to: to, to: .main) { activities, _ in
                continuation.resume(returning: activities ?? [])
            }
        }
        return activities.indices.compactMap { i in
            let a = activities[i]
            guard a.walking || a.running else { return nil }
            let end = i + 1 < activities.count ? activities[i + 1].startDate : to
            return end > a.startDate ? .init(start: a.startDate, end: min(end, to)) : nil
        }
    }
}
