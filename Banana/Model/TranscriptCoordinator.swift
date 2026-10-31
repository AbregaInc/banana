import Foundation
import Combine
#if os(iOS)
// Transcription itself is cross-platform — SpeechAnalyzer is on the Mac too. Only the *scheduling*
// is a phone concern: BGTaskScheduler and the sleep-prevention assertion exist because an iPhone
// aggressively suspends apps and dims itself. A Mac left open just gets on with it.
import BackgroundTasks
import UIKit
#endif

/// Orchestrates transcript creation and the on-device credits/diarization pipeline.
///
/// Strategy per episode:
///  1. If the feed publishes a timed transcript (`<podcast:transcript>` VTT/SRT), use it —
///     free and instant.
///  2. Otherwise, if the episode is downloaded, transcribe it on device with
///     `SpeechAnalyzer` (iOS 26) — real word timings, no network, no cloud.
///  3. If a `Diarizer` is available (FluidAudio), label words with speaker turns.
///
/// Live work (a transcript for the episode you're about to play) runs on demand.
/// Bulk work (transcribing the whole download shelf) runs overnight on charger via a
/// `BGProcessingTask`, so it never spends the user's battery mid-day.
@MainActor
final class TranscriptCoordinator: ObservableObject {
    static let shared = TranscriptCoordinator()

    static let overnightTaskID = "com.boris.banana.transcribe.overnight"

    enum Status: Equatable {
        case idle
        case preparing         // downloading the on-device speech model
        case working(Double)   // 0…1
        case ready
        case unavailable       // no feed transcript and no way to make one
        case deferredForPlayback
        case failed
    }

    @Published private(set) var status: [String: Status] = [:]

    weak var library: PodcastLibrary?
    weak var downloads: DownloadManager?
    /// Follows the per-device switch (`SpeakerLabelling`), read when a transcript is finished.
    var diarizer: Diarizer { SpeakerLabelling.diarizer }

    private var inFlight: Set<String> = []
    private var startedAt: [String: Date] = [:]
    /// A broken publisher URL is retried next launch, not on every transcript-screen open.
    private var publisherAttempted: Set<String> = []
    /// Shares one in-flight credits extraction across concurrent callers (e.g. the transcript
    /// screen and the episode-info sheet open at once) instead of running the on-device model
    /// twice for the same episode.
    private var creditsInFlight: [String: Task<CreditsExtractor.Outcome, Never>] = [:]
    /// Episode IDs whose extraction deterministically threw `exceededContextWindowSize` this
    /// process — re-opening the transcript screen or info sheet for one of these must not re-run
    /// the full on-device model call, since the same (title, showNotes) input throws again.
    private var creditsUnavailableThisSession: Set<String> = []
    #if os(macOS)
    private var macBatchTask: Task<Void, Never>?
    #endif

    /// Compact state for the app-wide power rollup.
    var powerSummary: String { inFlight.isEmpty ? "idle" : "\(inFlight.count)active" }

    private init() {
        sweepOrphanedSegments()
    }

    /// Delete `tmp/seg-*.caf` decode artifacts from previous runs. A resume decodes the remaining
    /// audio to an uncompressed 16 kHz temp — up to ~500 MB for a long episode — and the `defer`
    /// cleanup can't run when the PROCESS dies (an expired background task: the very event that
    /// causes resumes). iOS only purges tmp under storage pressure, so without this sweep each
    /// interrupted night stacked another half-gigabyte.
    private func sweepOrphanedSegments() {
        Task.detached(priority: .utility) {
            let tmp = FileManager.default.temporaryDirectory
            let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
            for name in names where name.hasPrefix("seg-") && name.hasSuffix(".caf") {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Failure memo

    /// Consecutive terminal failures per episode. A corrupt or DRM'd file fails identically every
    /// night, and the overnight batch re-attempted it forever — model load + a full remaining-audio
    /// decode, on charger, nightly. Three strikes and it's parked (cleared if it ever succeeds).
    private static let failCountsKey = "transcribeFailCounts"
    private static let maxFailures = 3

    private var failCounts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Self.failCountsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.failCountsKey) }
    }

    private func noteFailure(_ id: String) {
        var counts = failCounts
        counts[id, default: 0] += 1
        failCounts = counts
        if counts[id, default: 0] >= Self.maxFailures {
            clearPartial(id)   // a partial for an episode we've given up on is dead weight
            Log.wake.error("transcribe: \(id, privacy: .public) failed \(Self.maxFailures) times — parked (delete/re-download to retry)")
        }
    }

    private func isParked(_ id: String) -> Bool { failCounts[id, default: 0] >= Self.maxFailures }

    /// Drop any resume checkpoint for an episode — called when its download is deleted (a partial
    /// can only ever resume against the file it was cut from).
    func discardPartial(_ episodeID: String) {
        clearPartial(episodeID)
        var counts = failCounts
        if counts.removeValue(forKey: episodeID) != nil { failCounts = counts }
    }

    /// Seconds left, extrapolated from how far we've got and how long it took. A percentage alone
    /// reads as "hung"; "about 6 min left" reads as "working".
    func eta(for episodeID: String) -> TimeInterval? {
        guard case .working(let p) = status(for: episodeID), p > 0.02,
              let started = startedAt[episodeID] else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        return max(0, elapsed / p - elapsed)
    }

    func status(for episodeID: String) -> Status {
        if TranscriptStore.shared.has(episodeID) { return .ready }
        return status[episodeID] ?? .idle
    }

    // MARK: - On-demand

    /// Ensure a transcript exists for `episode`, creating one if needed. Idempotent and
    /// safe to call from a view's `.task`.
    @discardableResult
    func ensureTranscript(for episode: Episode, force: Bool = false,
                          keepAwake: Bool = true,
                          isCancelled: @escaping () -> Bool = { false }) async -> Transcript? {
        let id = episode.id
        let existing = force ? nil : await TranscriptStore.shared.transcriptAsync(for: id)
        if let existing,
           existing.source == .feed
                || episode.availableTranscriptSources.isEmpty
                || publisherAttempted.contains(id) {
            status[id] = .ready
            return existing
        }
        guard !inFlight.contains(id) else { return nil }
        inFlight.insert(id)
        let power = PowerTrace.begin("transcription")
        defer { inFlight.remove(id); PowerTrace.end(power) }
        status[id] = .working(0)

        // 1. Publisher transcript — cheapest, fastest and usually the creator's canonical text.
        // Try every Podcasting 2.0 candidate: one dead JSON link must not hide a working VTT/SRT.
        if !episode.availableTranscriptSources.isEmpty { publisherAttempted.insert(id) }
        for source in episode.availableTranscriptSources {
            if let payload = await TranscriptionService.feedTranscript(from: source),
               !payload.words.isEmpty {
                let transcript = await finalize(
                    episodeID: id, words: payload.words, source: .feed,
                    speakerNames: payload.speakerNames)
                _ = await credits(for: episode)
                status[id] = .ready
                return transcript
            }
        }
        // A local/cloud-generated transcript remains useful even if every newly-advertised
        // publisher URL is broken. Do not re-run ASR just because an upgrade attempt failed.
        if let existing {
            status[id] = .ready
            return existing
        }

        // 2. On-device ASR from the downloaded file.
        let engine = LocalTranscriptionEngine.selected
        let engineAvailable = engine == .parakeet
            ? TranscriptionService.parakeetAvailable : TranscriptionService.onDeviceAvailable
        if #available(iOS 26, *), engineAvailable,
           let fileURL = downloads?.localURL(for: id) {
            // SpeechAnalyzer is sustained CPU/Neural Engine work. Running it under active audio is
            // the worst possible power combination and risks the OS killing the background player.
            // A published feed transcript was already attempted above; generated transcripts wait
            // until playback stops or the overnight charger task.
            if WakeCoordinator.shared.player.isPlaying {
                status[id] = .deferredForPlayback
                scheduleOvernight()
                return nil
            }

            // Transcribing runs ~35× realtime, so a four-hour episode is minutes of compute, not
            // hours. But it dies the instant the phone auto-locks: iOS suspends us and the job
            // freezes — which is exactly what "stuck at 1% forever" was. Hold the screen awake for
            // the duration (scoped to this app, released the moment we're done), and take a
            // background assertion so briefly switching away doesn't kill it outright.
            //
            // The overnight batch passes keepAwake: false — it already runs under a BGProcessingTask
            // assertion, and it has no business lighting up the screen at 3am.
            #if os(iOS)
            var bgTask = UIBackgroundTaskIdentifier.invalid
            #endif
            if keepAwake {
                #if os(iOS)
                KeepAwake.acquire()   // refcounted — another holder coming and going can't undo this
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "transcribe") { }
                #endif
            }
            defer {
                if keepAwake {
                    #if os(iOS)
                    KeepAwake.release()
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                    #endif
                }
            }
            startedAt[id] = Date()
            defer { startedAt[id] = nil }

            do {
                if engine == .parakeet {
                    let stageHandler: @Sendable (TranscriptionService.Stage) -> Void = { [weak self] stage in
                        Task { @MainActor in
                            switch stage {
                            case .installingModel: self?.status[id] = .preparing
                            case .transcribing(let progress): self?.status[id] = .working(progress)
                            }
                        }
                    }
                    let words = try await TranscriptionService.transcribeParakeet(
                        fileURL: fileURL, stage: stageHandler)
                    let transcript = await finalize(
                        episodeID: id, words: words, source: .parakeet, audio: fileURL)
                    _ = await credits(for: episode)
                    clearPartial(id)
                    if failCounts[id] != nil { discardPartial(id) }
                    status[id] = .ready
                    return transcript
                }

                guard let words = try await transcribeResumable(id: id, fileURL: fileURL,
                                                                isCancelled: isCancelled) else {
                    status[id] = .idle   // interrupted — progress is on disk, we pick it up next time
                    return nil
                }
                let transcript = await finalize(episodeID: id, words: words, source: .onDevice, audio: fileURL)
                _ = await credits(for: episode)
                clearPartial(id)
                if failCounts[id] != nil { discardPartial(id) }   // success clears the strike count
                status[id] = .ready
                return transcript
            } catch {
                // Log the actual error. "Transcription failed" told us nothing tonight; the useful
                // information (e.g. SFSpeechError.assetLocaleNotAllocated) was in here all along.
                Log.wake.error("transcribe FAILED for \(id, privacy: .public) — \(String(describing: error), privacy: .public)")
                noteFailure(id)
                status[id] = .failed
                return nil
            }
        }

        status[id] = .unavailable
        return nil
    }

    // MARK: - Resumable transcription

    /// Legacy checkpoint format (whole-array JSON) — kept only so a transcription interrupted on
    /// a pre-NDJSON build can still resume. New checkpoints are NDJSON appends.
    private struct Partial: Codable {
        var words: [TranscriptWord]
    }

    /// On resume, rewind this far and re-transcribe. Long enough that the model has real acoustic
    /// AND language lead-in before it reaches the words we keep — a couple of seconds is enough not
    /// to clip a word, but not enough for the model to know what it's listening to.
    private nonisolated static let rewindSeconds = 10.0

    /// Transcribe in one continuous pass from the top. A resumed pass is bounded into temporary
    /// slices, checkpointing the words as they stream. Returns nil if interrupted; the partial
    /// stays on disk and the next run resumes from it.
    ///
    /// A fresh run remains unchunked (SpeechAnalyzer streams the compressed source itself). Only a
    /// resume needs PCM extraction. Extracting "the rest of a four-hour episode" created a ~500 MB
    /// CAF and repeated that allocation after every expiry, so resumed work is capped to 30-minute
    /// slices. Adjacent slices overlap by `rewindSeconds`; words in the overlap are discarded and
    /// re-created with acoustic/language context, avoiding clipped mid-word seams.
    @available(iOS 26, *)
    private func transcribeResumable(id: String, fileURL: URL,
                                     isCancelled: @escaping () -> Bool) async throws -> [TranscriptWord]? {
        let total = TranscriptionService.duration(of: fileURL)
        guard total > 0 else { return [] }

        var kept = loadPartialWords(id)
        var startAt = 0.0
        if let last = kept.last?.end {
            startAt = max(0, last - Self.rewindSeconds)
            kept.removeAll { $0.end > startAt }        // that window gets re-done properly
            Log.wake.notice("transcribe: resuming \(id, privacy: .public) at \(Int(startAt))s of \(Int(total))s")
        }
        guard startAt < total - 0.5 else { return kept }

        let base = kept
        resetPartial(id, to: base)   // trims the rewind window on disk; checkpoints append from here
        let work = Task.detached(priority: .utility) { () -> [TranscriptWord] in
            // From the top, hand the analyzer the original file. Routing through transcribeSegment
            // would first decode the WHOLE episode into a temp 16k file — a minute of silent work
            // on a 4.5h episode with NSProgress pinned at zero, which is precisely what got the
            // continued-processing task expired: "tasks that appear stalled may be forcibly
            // expired". Only a resume needs a slice cut out of the middle.
            let checkpointHandler: @Sendable ([TranscriptWord]) -> Void = { [weak self] words in
                guard self != nil else { return }
                Self.appendPartial(id, newWords: words)
            }

            if startAt <= 0.01 {
                let stageHandler: @Sendable (TranscriptionService.Stage) -> Void = { [weak self] stage in
                    Task { @MainActor in
                        switch stage {
                        case .installingModel: self?.status[id] = .preparing
                        case .transcribing(let progress):
                            self?.status[id] = .working(progress * 0.9)
                        }
                    }
                }
                return try await TranscriptionService.transcribeOnDevice(
                    fileURL: fileURL, stage: stageHandler, checkpoint: checkpointHandler)
            }

            let maxSlice = 30.0 * 60.0       // 16 kHz mono Int16 ≈ 58 MB, not ~500 MB
            var produced: [TranscriptWord] = []
            var cursor = startAt
            var firstSlice = true

            while cursor < total - 0.5 {
                try Task.checkCancellation()
                let sliceStart = firstSlice ? cursor : max(startAt, cursor - Self.rewindSeconds)
                let sliceEnd = min(total, sliceStart + maxSlice)

                if !firstSlice {
                    // Re-do the overlap rather than retain a token generated from truncated audio.
                    produced.removeAll { $0.end > sliceStart }
                    Self.replacePartial(id, with: base + produced)
                }

                let stageHandler: @Sendable (TranscriptionService.Stage) -> Void = { [weak self] stage in
                    Task { @MainActor in
                        switch stage {
                        case .installingModel:
                            self?.status[id] = .preparing
                        case .transcribing(let progress):
                            let absolute = (sliceStart + progress * (sliceEnd - sliceStart)) / total
                            self?.status[id] = .working(absolute * 0.9)
                        }
                    }
                }
                let words = try await TranscriptionService.transcribeSegment(
                    fileURL: fileURL,
                    startSeconds: sliceStart,
                    seconds: sliceEnd - sliceStart,
                    priority: .utility,
                    retention: .processLifetime,
                    stage: stageHandler,
                    checkpoint: checkpointHandler)
                produced.append(contentsOf: words)
                Self.replacePartial(id, with: base + produced)
                cursor = sliceEnd
                firstSlice = false
            }
            return produced
        }

        // Poll the caller's cancellation (a BGProcessingTask expiring) and stop the analyzer.
        let watchdog = Task {
            while !Task.isCancelled {
                if isCancelled() { work.cancel(); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { watchdog.cancel() }

        do {
            let words = try await work.value
            return base + words
        } catch is CancellationError {
            Log.wake.notice("transcribe: interrupted — partial kept, will resume")
            return nil
        }
    }

    /// Created once — the computed version ran `createDirectory` on every checkpoint and load.
    private nonisolated static let partialsDir: URL = {
        let dir = AppSupport.directory
            .appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func partialURL(_ id: String) -> URL {
        Self.partialsDir.appendingPathComponent("partial-\(id.replacingOccurrences(of: "/", with: "_")).json")
    }
    /// One serial lane for partial-file IO. Keeps checkpoint IO OFF the main actor (on-main it
    /// was a 50–100 ms hitch under the very transcription being checkpointed), and serializes
    /// appends against clears so a straggler write can never land after finalize's clear and
    /// resurrect the partial of a completed episode.
    private nonisolated static let partialIO =
        DispatchQueue(label: "com.boris.banana.partialio", qos: .utility)

    /// The checkpoint file is NDJSON — one word per line, appended.
    ///
    /// The old format re-encoded and atomically rewrote the ENTIRE word array every checkpoint:
    /// O(n²) bytes over an episode (~26 MB of flash writes for a 4.5 h episode at full speed,
    /// far more when throttled), with the biggest writes landing at the end when the array is
    /// largest. Append-only writes each word exactly once. A kill can tear the final line;
    /// the loader tolerates that by dropping any line that doesn't decode.
    private nonisolated static func partialNDJSONURL(_ id: String) -> URL {
        Self.partialsDir.appendingPathComponent("partial-\(id.replacingOccurrences(of: "/", with: "_")).ndjson")
    }

    /// Words from a previous run's checkpoints — new format first, then the legacy whole-array
    /// file (a transcription interrupted on a pre-NDJSON build). Reads happen only at resume
    /// start, in a fresh process — no in-flight writes to race.
    private func loadPartialWords(_ id: String) -> [TranscriptWord] {
        if let data = try? Data(contentsOf: Self.partialNDJSONURL(id)) {
            let decoder = JSONDecoder()
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(TranscriptWord.self, from: $0) }
        }
        if let data = try? Data(contentsOf: partialURL(id)),
           let legacy = try? JSONDecoder().decode(Partial.self, from: data) {
            return legacy.words
        }
        return []
    }

    /// Reset the checkpoint file to exactly `words` — the one bounded rewrite per resume (the
    /// rewind window gets trimmed) — and retire any legacy-format file. Empty → no file.
    private func resetPartial(_ id: String, to words: [TranscriptWord]) {
        Self.replacePartial(id, with: words)
    }

    private nonisolated static func replacePartial(_ id: String, with words: [TranscriptWord]) {
        let ndjsonURL = Self.partialNDJSONURL(id)
        let legacyURL = Self.partialsDir
            .appendingPathComponent("partial-\(id.replacingOccurrences(of: "/", with: "_")).json")
        Self.partialIO.async {
            try? FileManager.default.removeItem(at: legacyURL)
            guard !words.isEmpty else {
                try? FileManager.default.removeItem(at: ndjsonURL)
                return
            }
            var data = Data()
            let encoder = JSONEncoder()
            for word in words {
                guard let line = try? encoder.encode(word) else { continue }
                data.append(line)
                data.append(0x0A)
            }
            try? data.write(to: ndjsonURL, options: .atomic)
        }
    }

    /// Append the words this session produced beyond what's already on disk. O(delta) encode +
    /// one appending write — the hot path, every ~20 s for hours on the overnight charger.
    private nonisolated static func appendPartial(_ id: String, newWords: [TranscriptWord]) {
        guard !newWords.isEmpty else { return }
        let url = partialNDJSONURL(id)
        Self.partialIO.async {
            var data = Data()
            let encoder = JSONEncoder()
            for word in newWords {
                guard let line = try? encoder.encode(word) else { continue }
                data.append(line)
                data.append(0x0A)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)   // first append creates the file
            }
        }
    }

    private func clearPartial(_ id: String) {
        let ndjsonURL = Self.partialNDJSONURL(id)
        let legacyURL = partialURL(id)
        Self.partialIO.async {
            try? FileManager.default.removeItem(at: ndjsonURL)
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    /// Attach speaker labels (if a diarizer is available) and persist.
    private func finalize(episodeID: String, words: [TranscriptWord],
                          source: Transcript.Source, audio: URL? = nil,
                          speakerNames: [Int: String] = [:]) async -> Transcript {
        var labelled = words
        if diarizer.isAvailable, let audio, let turns = try? await diarizer.diarize(fileURL: audio, progress: nil) {
            labelled = Diarization.label(words, with: turns)
        }
        let transcript = Transcript(
            episodeID: episodeID, source: source, words: labelled,
            speakerNames: speakerNames)
        // saveAsync can defer to a higher-quality transcript that already exists (e.g. one
        // synced in from another device while this one was being produced) — return whichever
        // one actually won so callers never hold a stale, unsaved object.
        let winner = await TranscriptStore.shared.saveAsync(transcript)
        return winner
    }

    // MARK: - Credits (on-device LLM)

    /// Extracted credits for an episode, cached to disk. `nil` when the model is
    /// unavailable or the notes name no one.
    func credits(for episode: Episode) async -> EpisodeCredits? {
        let id = episode.id
        if let cached = CreditsCache.load(id) { return cached.isEmpty ? nil : cached }
        // Extraction already deterministically failed for this exact input earlier this process —
        // a retry would exceed the context window again. See `creditsUnavailableThisSession`.
        if creditsUnavailableThisSession.contains(id) { return nil }
        // A second concurrent caller (e.g. the episode-info sheet opening while the transcript
        // screen's own request is still running) rides the same in-flight extraction rather than
        // starting a second one — only the original caller below bookkeeps the dictionary/cache.
        if let inFlight = creditsInFlight[id] {
            let outcome = await inFlight.value
            guard case .credits(let credits) = outcome else { return nil }
            return (credits?.isEmpty ?? true) ? nil : credits
        }
        guard CreditsExtractor.available, let notes = episode.summary, !notes.isEmpty else { return nil }
        let title = episode.title
        let task = Task<CreditsExtractor.Outcome, Never> {
            await CreditsExtractor.extract(title: title, showNotes: notes)
        }
        creditsInFlight[id] = task
        let outcome = await task.value
        creditsInFlight[id] = nil
        switch outcome {
        case .credits(let credits):
            if let credits { CreditsCache.save(id, credits) }
            return (credits?.isEmpty ?? true) ? nil : credits
        case .permanentlyUnavailable:
            creditsUnavailableThisSession.insert(id)
            return nil
        }
    }

    // MARK: - Streamed listens

    /// Episodes played by streaming that have no transcript and no local file.
    ///
    /// Persisted rather than kept in memory: the whole point is that the *next* listen benefits,
    /// and the batch that would act on it runs on a charger hours later, in a different process.
    private static let streamedKey = "transcribeAfterStreamedListen"

    /// Remember that an episode was listened to without ever being downloaded.
    ///
    /// A first streamed listen can never have the host-read sponsor stages: they need this
    /// episode's own transcript, and transcribing ahead of a live playhead is not a cost this
    /// feature is allowed to impose — it would be CPU spent racing audio the listener is already
    /// hearing, on a device in their pocket. So the answer is the one the overnight batch was
    /// built for: fetch it and read it later, on a charger, so the second listen is clean.
    func noteStreamedListen(_ episodeID: String) {
        guard !TranscriptStore.shared.has(episodeID) else { return }
        var pending = Set(UserDefaults.standard.stringArray(forKey: Self.streamedKey) ?? [])
        guard pending.insert(episodeID).inserted else { return }
        UserDefaults.standard.set(Array(pending), forKey: Self.streamedKey)
    }

    /// Queue the audio for anything streamed since the last batch, so the next one can read it.
    ///
    /// Two nights, by design: this one fetches, the next one transcribes. Downloading and running
    /// speech recognition in the same finite background window is how a batch expires having
    /// finished neither.
    private func fetchStreamedEpisodesForNextBatch() {
        var pending = Set(UserDefaults.standard.stringArray(forKey: Self.streamedKey) ?? [])
        guard !pending.isEmpty, let library, let downloads else { return }
        for podcast in library.podcasts {
            for episode in podcast.episodes where pending.contains(episode.id) {
                if TranscriptStore.shared.has(episode.id) || downloads.isDownloaded(episode.id) {
                    pending.remove(episode.id)   // already handled; stop tracking it
                    continue
                }
                guard !isParked(episode.id) else { pending.remove(episode.id); continue }
                downloads.downloadForTranscription(episode, podcast: podcast)
            }
        }
        UserDefaults.standard.set(Array(pending), forKey: Self.streamedKey)
    }

    // MARK: - Overnight batch

    /// Register the BG task handler. Call once from app launch (before launch finishes).
#if os(iOS)
    func registerBackgroundTasks() {
        // Take the dependencies from the singletons HERE, not from wireUp(). iOS background-launches
        // the app to run a BGProcessingTask with no UI at all, so the root view's .task never fires
        // and wireUp() never runs — which left library/downloads nil, pendingEpisodes() empty, and
        // the batch cheerfully reporting success having transcribed nothing. Every night, for weeks.
        library = WakeCoordinator.shared.library
        downloads = WakeCoordinator.shared.downloads

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.overnightTaskID, using: nil) { [weak self] task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in await self?.runOvernight(task) }
        }

    }

    /// Ask the OS to run the batch next time the device is charging + idle.
    func scheduleOvernight() {
        let request = BGProcessingTaskRequest(identifier: Self.overnightTaskID)
        request.requiresExternalPower = true       // charger only — transcription is CPU-heavy
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.wake.notice("overnight transcribe: scheduled")
        } catch {
            // Swallowing this is how a background task silently never runs.
            Log.wake.error("overnight transcribe: submit FAILED — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Episodes that are downloaded but not yet transcribed — the batch's work list.
    /// Shortest first: a background window is finite, so bank the wins we can finish.
    func pendingEpisodes() -> [Episode] {
        guard let library, let downloads else {
            Log.wake.error("overnight transcribe: no library/downloads wired")
            return []
        }
        return library.podcasts.lazy.flatMap(\.episodes)
            .filter { downloads.isDownloaded($0.id) && !TranscriptStore.shared.has($0.id) && !self.isParked($0.id) }
            .sorted { ($0.duration ?? .greatestFiniteMagnitude) < ($1.duration ?? .greatestFiniteMagnitude) }
    }

    private func runOvernight(_ task: BGProcessingTask) async {
        scheduleOvernight()   // chain the next night

        var cancelled = false
        task.expirationHandler = { cancelled = true }

        guard #available(iOS 26, *), TranscriptionService.onDeviceAvailable else {
            task.setTaskCompleted(success: false); return
        }
        guard !WakeCoordinator.shared.player.isPlaying else {
            Log.wake.notice("overnight transcribe: deferred because audio is playing")
            task.setTaskCompleted(success: false)
            return
        }

        // Streamed listens first: this only enqueues Wi-Fi downloads with the system, so it costs
        // the window nothing and the files are here by the time the next batch runs.
        fetchStreamedEpisodesForNextBatch()
        for episode in pendingEpisodes() {
            if cancelled { break }
            _ = await ensureTranscript(for: episode, keepAwake: false,
                                       isCancelled: { cancelled })
            // A transcript is the input the sponsor-read and boilerplate stages were missing.
            // Rebuild now, on the charger, so the morning's listen — and the Watch's copy of the
            // markers — already has it rather than discovering it mid-episode.
            if let podcast = library?.podcasts.first(where: { p in p.episodes.contains { $0.id == episode.id } }) {
                WakeCoordinator.shared.skipPlans.requestBuild(
                    episode: episode, podcast: podcast, reason: "transcript")
            }
        }
        task.setTaskCompleted(success: !cancelled)
    }
#else
    // No BGTaskScheduler on a Mac. Once Parakeet is explicitly selected, opportunistically use the
    // more capable device for already-downloaded episodes and upload each finished transcript.
    // No audio is copied through iCloud and Low Power Mode always wins.
    func registerBackgroundTasks() {}
    func scheduleOvernight() {
        guard LocalTranscriptionEngine.selected == .parakeet,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              macBatchTask == nil else { return }
        macBatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.library?.whenLoaded()
            self.fetchStreamedEpisodesForNextBatch()
            guard !WakeCoordinator.shared.player.isPlaying else {
                self.macBatchTask = nil
                return
            }
            guard let library = self.library, let downloads = self.downloads else {
                self.macBatchTask = nil
                return
            }
            let episodes = library.podcasts.lazy.flatMap(\.episodes)
                .filter {
                    downloads.isDownloaded($0.id)
                        && !TranscriptStore.shared.has($0.id)
                        && !self.isParked($0.id)
                }
                .sorted {
                    ($0.duration ?? .greatestFiniteMagnitude)
                        < ($1.duration ?? .greatestFiniteMagnitude)
                }
            for episode in episodes where !Task.isCancelled {
                guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
                      !WakeCoordinator.shared.player.isPlaying else { break }
                _ = await self.ensureTranscript(for: episode, keepAwake: false)
            }
            self.macBatchTask = nil
        }
    }
#endif
}

/// Tiny JSON cache for extracted credits, mirroring TranscriptStore's layout.
private enum CreditsCache {
    private static let dir: URL = {
        let d = AppSupport.directory
            .appendingPathComponent("Credits", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func url(_ id: String) -> URL {
        dir.appendingPathComponent("\(id.replacingOccurrences(of: "/", with: "_")).json")
    }
    static func load(_ id: String) -> EpisodeCredits? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(EpisodeCredits.self, from: data)
    }
    static func save(_ id: String, _ credits: EpisodeCredits) {
        if let data = try? JSONEncoder().encode(credits) { try? data.write(to: url(id), options: .atomic) }
    }
}
