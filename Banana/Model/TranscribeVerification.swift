#if os(iOS)
// DEBUG harness; leans on iOS-only background tasks.

#if DEBUG
import Foundation
import AVFoundation
import Speech
import UIKit

/// `--verify-transcribe` — run the REAL on-device transcription against a real downloaded episode
/// and narrate every step to stdout, so a stall can be located instead of guessed at.
///
/// "Transcribing on device…" with no movement has several possible causes that look identical from
/// the UI: the locale isn't supported, the model isn't actually installed, the analyzer never emits
/// a result, or it's simply slow. This prints enough to tell them apart — and a real-time factor,
/// which is the number that decides whether we need a different model (Parakeet) at all.
enum TranscribeVerification {

    static func runIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("--verify-transcribe") {
            Task.detached(priority: .userInitiated) { await run() }
        }
        // `--verify-asr <path>` — transcribe an arbitrary file through the PRODUCTION path.
        // Exists to answer: does SpeechAnalyzer work in the Simulator? If it does, transcription
        // can be debugged locally instead of on someone's phone.
        // `--verify-progress` — does splitting progress out of the catalogue keep every position?
        if ProcessInfo.processInfo.arguments.contains("--verify-progress") {
            Task { @MainActor in await progressSplit() }
        }
        // `--verify-backup` — does CloudBackup's SHA dedup actually prevent redundant uploads?
        if ProcessInfo.processInfo.arguments.contains("--verify-backup") {
            Task { @MainActor in await backupDedup() }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-asr") {
            Task.detached(priority: .userInitiated) { await asr() }
        }
        if ProcessInfo.processInfo.arguments.contains("--bench-transcribe") {
            Task.detached(priority: .userInitiated) { await benchmark() }
        }
        if ProcessInfo.processInfo.arguments.contains("--bench-options") {
            Task.detached(priority: .userInitiated) { await benchOptions() }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-continued") {
            Task.detached(priority: .userInitiated) { await continued() }
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-overnight") {
            // Detached, like the others. Kicking this off as a @MainActor task from init() never
            // ran at all — it printed nothing for seven minutes.
            Task.detached(priority: .userInitiated) { await overnight() }
        }
    }

    /// `--verify-overnight` — run the overnight batch's REAL work path in the foreground.
    ///
    /// The batch itself only runs when iOS decides to background-launch us on a charger, which
    /// makes "it never produced a transcript" almost impossible to debug by waiting. This exercises
    /// the same work list and the same transcription, and says out loud what it found.
    /// `--verify-continued` — exercise the path that crashed the app: submit a real
    /// BGContinuedProcessingTask for a long episode.
    @available(iOS 26, *)
    private static func continued() async {
        started = Date()
        log("=== continued-processing task ===")
        try? await Task.sleep(for: .seconds(2))
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        log("permitted identifiers: \(permitted)")

        let pending = await MainActor.run { () -> [Episode] in
            let c = TranscriptCoordinator.shared
            c.library = WakeCoordinator.shared.library
            c.downloads = WakeCoordinator.shared.downloads
            return c.pendingEpisodes()
        }
        guard let long = pending.max(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }) else {
            log("nothing pending"); return
        }
        log("submitting for: \(long.title.prefix(50)) (\(Int((long.duration ?? 0) / 60))m)")
        let ok = await MainActor.run { ContinuedTranscription.start(long) }
        log(ok ? "SUBMITTED — the system should now run it (look for the Live Activity)"
               : "REFUSED — scheduler rejected the submission")
        // Stay alive so the system has a chance to launch the task handler.
        try? await Task.sleep(for: .seconds(90))
        log("still alive; check the log for 'continued transcription' lines")
    }

    private static func overnight() async {
        started = Date()
        log("=== overnight batch (real work path, run in foreground) ===")

        // Give the app a moment to finish launching before we reach into its object graph.
        try? await Task.sleep(for: .seconds(2))

        let pending = await MainActor.run { () -> [Episode] in
            let coordinator = TranscriptCoordinator.shared
            coordinator.library = WakeCoordinator.shared.library
            coordinator.downloads = WakeCoordinator.shared.downloads
            return coordinator.pendingEpisodes()
        }
        log("pending: \(pending.count) downloaded episode(s) without a transcript")
        for episode in pending.prefix(10) {
            let mins = Int((episode.duration ?? 0) / 60)
            log("  • \(episode.title.prefix(58)) — \(mins)m")
        }
        guard let first = pending.first else {
            log("nothing to do — either nothing is downloaded, or everything already has a transcript")
            return
        }

        // Prove the checkpointing: cancel mid-episode, then resume and confirm it picks up rather
        // than starting from zero.
        if ProcessInfo.processInfo.arguments.contains("--interrupt") {
            let long = pending.max { ($0.duration ?? 0) < ($1.duration ?? 0) } ?? first
            log("INTERRUPT TEST on \(long.title.prefix(40)) (\(Int((long.duration ?? 0) / 60))m)")

            let deadline = Date().addingTimeInterval(45)
            let t1 = Date()
            _ = await TranscriptCoordinator.shared.ensureTranscript(
                for: long, keepAwake: true, isCancelled: { Date() > deadline })
            log("cancelled after \(Int(Date().timeIntervalSince(t1)))s — checking the checkpoint…")

            let resumeStart = Date()
            _ = await TranscriptCoordinator.shared.ensureTranscript(
                for: long, keepAwake: true, isCancelled: { Date() > resumeStart.addingTimeInterval(30) })
            log("resumed run ended — if it resumed, the log above says 'resuming … at Ns'")
            return
        }

        log("transcribing the shortest: \(first.title.prefix(58))")
        let t0 = Date()
        let transcript = await TranscriptCoordinator.shared.ensureTranscript(for: first, keepAwake: true)
        let elapsed = Date().timeIntervalSince(t0)
        if let transcript {
            let saved = await MainActor.run { TranscriptStore.shared.has(first.id) }
            log("DONE in \(Int(elapsed))s — \(transcript.words.count) words, saved to disk: \(saved)")
        } else {
            let status = await MainActor.run { TranscriptCoordinator.shared.status(for: first.id) }
            log("FAILED after \(Int(elapsed))s — status \(String(describing: status))")
        }
    }

    // MARK: - Options A/B (the real benchmark)
    //
    // Every RTF number quoted before this was measured by THIS harness building its own
    // SpeechAnalyzer — not by the code the app actually runs. And the app was passing no
    // SpeechAnalyzer.Options at all, so it ran at default priority with default model retention.
    // This drives the production path (TranscriptionService.transcribeOnDevice) and sweeps the
    // knobs we'd never touched.

    @available(iOS 26, *)
    private static func benchOptions() async {
        started = Date()
        log("=== SpeechAnalyzer Options A/B — production code path ===")
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }

        guard let source = biggestDownload() else { log("no downloaded episode"); return }
        let seconds = 600.0   // 10 minutes of real audio, same slice every run

        let configs: [(String, TaskPriority?, SpeechAnalyzer.Options.ModelRetention)] = [
            ("SHIPPED (no Options)",       nil,             .processLifetime),
            ("priority .utility",          .utility,        .processLifetime),
            ("priority .userInitiated",    .userInitiated,  .processLifetime),
            ("userInitiated + whileInUse", .userInitiated,  .whileInUse),
        ]

        for (name, priority, retention) in configs {
            let t0 = Date()
            do {
                let words = try await TranscriptionService.transcribeSegment(
                    fileURL: source, startSeconds: 0, seconds: seconds,
                    priority: priority, retention: retention)
                let elapsed = Date().timeIntervalSince(t0)
                log(String(format: "%-28@ %5.1f× realtime  (%3.0fs for %.0fs audio)  %d words  mem %dMB",
                           name as NSString, seconds / elapsed, elapsed, seconds, words.count, memoryMB()))
            } catch {
                log("\(name): FAILED — \(error)")
            }
        }

        // Model retention only pays off across episodes — one analyzer per episode means a reload
        // each time unless the model lingers. Price it.
        log("")
        log("back-to-back x2 (does the model reload between episodes?)")
        for (name, retention) in [("whileInUse", SpeechAnalyzer.Options.ModelRetention.whileInUse),
                                  ("processLifetime", .processLifetime)] {
            let t0 = Date()
            for _ in 0..<2 {
                _ = try? await TranscriptionService.transcribeSegment(
                    fileURL: source, startSeconds: 0, seconds: 300,
                    priority: .userInitiated, retention: retention)
            }
            let elapsed = Date().timeIntervalSince(t0)
            log(String(format: "  %-16@ 2×300s audio in %3.0fs = %.1f× realtime",
                       name as NSString, elapsed, 600 / elapsed))
        }
        log("=== done ===")
    }

    /// Prove the progress split cannot lose a play position.
    ///
    /// 1. Seed a catalogue with known positions and NO progress.json (i.e. the pre-change state).
    /// 2. Reload from disk — the embedded values must survive (the no-migration path).
    /// 3. Move the playhead and save via the hot path — only progress.json may change.
    /// 4. Reload again — the NEW positions must survive.
    @MainActor
    private static func progressSplit() async {
        started = Date()
        log("=== progress split: does anything get lost? ===")
        try? await Task.sleep(for: .seconds(1))

        let library = WakeCoordinator.shared.library
        let catalogue = library.debugCatalogueURL()
        let progress = library.debugProgressURL()

        // A feed with enough episodes that the catalogue is genuinely big.
        let episodes = (1...500).map { i in
            Episode(id: "ep-\(i)", title: "Episode \(i) — a fairly long title to bulk out the file",
                    audioURL: URL(string: "https://example.com/ep\(i).mp3")!,
                    pubDate: Date(), duration: 3600,
                    summary: String(repeating: "show notes ", count: 60))
        }
        var seeded = Podcast(feedURL: URL(string: "https://example.com/feed.xml")!,
                             title: "Test Feed", author: "Nobody", artworkURL: nil, episodes: episodes)
        seeded.positions = ["ep-7": 1234.5, "ep-9": 42.0]
        seeded.completed = ["ep-1", "ep-2"]
        seeded.currentEpisodeID = "ep-7"
        library.debugSeed([seeded])

        // Step 1: pre-change state — catalogue only.
        try? FileManager.default.removeItem(at: progress)
        let catSize = (try? Data(contentsOf: catalogue).count) ?? 0
        log("catalogue: \(catSize / 1024) KB, progress.json: absent (pre-change state)")

        // Step 2: reload — embedded values must survive with no progress file.
        library.reloadFromDisk()
        let p1 = library.podcasts.first
        log("after reload w/o progress.json → ep-7: \(p1?.positions["ep-7"] ?? -1), "
            + "completed: \(p1?.completed.count ?? -1), current: \(p1?.currentEpisodeID ?? "nil")")
        let step2OK = p1?.positions["ep-7"] == 1234.5 && p1?.completed.count == 2 && p1?.currentEpisodeID == "ep-7"

        // Step 3: move the playhead and save through the hot path.
        let catMtimeBefore = (try? FileManager.default.attributesOfItem(atPath: catalogue.path)[.modificationDate] as? Date) ?? Date()
        try? await Task.sleep(for: .seconds(1.2))
        library.updateProgress(podcastID: seeded.id, episodeID: "ep-7", position: 9999.0)
        library.saveProgressSnapshot()

        let progSize = (try? Data(contentsOf: progress).count) ?? 0
        let catMtimeAfter = (try? FileManager.default.attributesOfItem(atPath: catalogue.path)[.modificationDate] as? Date) ?? Date()
        let catalogueUntouched = catMtimeBefore == catMtimeAfter
        log("hot-path save → progress.json: \(progSize) bytes, catalogue rewritten: \(!catalogueUntouched)")
        log("   (was \(catSize / 1024) KB rewritten every 30s of playback)")

        // Step 4: reload — the NEW position must survive.
        library.reloadFromDisk()
        let p2 = library.podcasts.first
        log("after reload → ep-7: \(p2?.positions["ep-7"] ?? -1), ep-9: \(p2?.positions["ep-9"] ?? -1), "
            + "completed: \(p2?.completed.count ?? -1), current: \(p2?.currentEpisodeID ?? "nil")")
        let step4OK = p2?.positions["ep-7"] == 9999.0 && p2?.positions["ep-9"] == 42.0
            && p2?.completed.count == 2 && p2?.currentEpisodeID == "ep-7"

        log("")
        log("no-migration path (old data, no progress.json): \(step2OK ? "PASS" : "FAIL")")
        log("progress survives a hot-path save + reload:      \(step4OK ? "PASS" : "FAIL")")
        log("catalogue untouched by the hot path:             \(catalogueUntouched ? "PASS" : "FAIL")")
    }

    /// Back up twice with NOTHING changed in between. If the SHA dedup works, the second call is a
    /// no-op. The audit claims it can never fire, because `savedAt: Date()` is inside the hashed
    /// payload — so every save uploads the whole library.
    @MainActor
    private static func backupDedup() async {
        started = Date()
        log("=== CloudBackup dedup check ===")
        try? await Task.sleep(for: .seconds(2))

        let backup = CloudBackup.shared
        log("enabled: \(backup.enabled)")

        // Compute the very hash backUpNow compares, twice, with nothing changed in between.
        // This isolates the dedup from iCloud availability (the Simulator has no iCloud account).
        // Which component is unstable — the files, or the serialized defaults?
        let f1 = backup.debugFilesHash() ?? "nil"
        let d1 = backup.debugDefaultsHash() ?? "nil"
        try? await Task.sleep(for: .milliseconds(600))
        let f2 = backup.debugFilesHash() ?? "nil"
        let d2 = backup.debugDefaultsHash() ?? "nil"
        log("files    stable: \(f1 == f2)")
        log("defaults stable: \(d1 == d2)")

        let first = backup.debugPayloadHash() ?? "nil"
        try? await Task.sleep(for: .milliseconds(1100))   // only the clock moves
        let second = backup.debugPayloadHash() ?? "nil"

        log("hash #1: \(first.prefix(24))…")
        log("hash #2: \(second.prefix(24))…  (identical data, 1.1s later)")
        if first == second {
            log("RESULT: MATCH → dedup works; redundant saves will NOT upload")
        } else {
            log("RESULT: DIFFER on identical data → dedup is DEAD. Every save uploads the whole")
            log("        library — including the one the player fires every 30s while listening.")
        }
    }

    @available(iOS 26, *)
    private static func asr() async {
        started = Date()
        log("=== ASR check (production path) ===")
        #if targetEnvironment(simulator)
        log("environment: SIMULATOR")
        #else
        log("environment: DEVICE")
        #endif

        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--verify-asr"), i + 1 < args.count else {
            log("usage: --verify-asr <path>"); return
        }
        let path = args[i + 1]
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            log("no file at \(path)"); return
        }
        let seconds = TranscriptionService.duration(of: url)
        log("file: \(url.lastPathComponent), \(String(format: "%.1f", seconds))s")

        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        log("locales — supported: \(supported.count), installed: \(installed.map(\.identifier))")

        let t0 = Date()
        do {
            let words = try await TranscriptionService.transcribeOnDevice(fileURL: url) { stage in
                if case .installingModel = stage { log("downloading speech model…") }
            }
            let elapsed = Date().timeIntervalSince(t0)
            log("RESULT: \(words.count) words in \(String(format: "%.1f", elapsed))s "
                + "(\(String(format: "%.1f", seconds / max(0.01, elapsed)))× realtime)")
            log("TEXT: \(words.map(\.text).joined(separator: " ").prefix(200))")
        } catch {
            log("FAILED: \(error)")
        }
    }

    // MARK: - Chunked-parallel benchmark
    //
    // The claim doing the rounds is that splitting the audio and running several analyzers at once
    // is "blazing fast" — an hour a minute. Our measured single-stream baseline is already ~35×
    // realtime, so the honest question is what parallelism buys ON THIS PHONE, and where the
    // concurrent-decoder ceiling actually is. Measured, not repeated.

    @available(iOS 26, *)
    private static func benchmark() async {
        started = Date()
        log("=== chunked-parallel benchmark ===")
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }

        guard let source = biggestDownload() else { log("no downloaded episode"); return }
        let chunkSeconds = 300.0        // 5 min
        let chunkCount = 6              // 30 min of audio — enough to be honest, short enough to iterate
        let audioSeconds = chunkSeconds * Double(chunkCount)

        // Write the chunks ONCE, outside the timed section — otherwise we'd be benchmarking mp3
        // decoding rather than transcription.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var chunks: [URL] = []
        let writeStart = Date()
        for i in 0..<chunkCount {
            let url = tmp.appendingPathComponent("chunk\(i).caf")
            do {
                try writeChunk(from: source, startSeconds: Double(i) * chunkSeconds,
                               seconds: chunkSeconds, to: url)
                chunks.append(url)
            } catch {
                log("chunk \(i) write FAILED: \(error)")
                return
            }
        }
        log("wrote \(chunks.count) × \(Int(chunkSeconds))s chunks in \(Int(Date().timeIntervalSince(writeStart)))s (excluded from timings)")

        for concurrency in [1, 2, 4, 6] {
            let start = Date()
            var words = 0
            var failed = 0
            await withTaskGroup(of: (Int, Bool).self) { group in
                var next = 0
                var running = 0
                while next < chunks.count || running > 0 {
                    while running < concurrency && next < chunks.count {
                        let url = chunks[next]
                        next += 1
                        running += 1
                        group.addTask { await transcribeChunk(url) }
                    }
                    if let (count, ok) = await group.next() {
                        running -= 1
                        words += count
                        if !ok { failed += 1 }
                    }
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            let rtf = audioSeconds / max(0.001, elapsed)
            log(String(format: "concurrency %d → %.0fs for %.0fs audio = %.1f× realtime, %d words, %d failed, peak mem %dMB",
                       concurrency, elapsed, audioSeconds, rtf, words, failed, memoryMB()))
        }
        try? FileManager.default.removeItem(at: tmp)
        log("=== benchmark done ===")
    }

    /// One chunk through its own analyzer. Returns (words, ok).
    @available(iOS 26, *)
    private static func transcribeChunk(_ url: URL) async -> (Int, Bool) {
        do {
            let audio = try AVAudioFile(forReading: url)
            let transcriber = SpeechTranscriber(locale: Locale.current,
                                                transcriptionOptions: [],
                                                reportingOptions: [],
                                                attributeOptions: [.audioTimeRange])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collector = Task { () -> Int in
                var n = 0
                for try await result in transcriber.results {
                    n += result.text.runs.count { $0.audioTimeRange != nil }
                }
                return n
            }
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return (try await collector.value, true)
        } catch {
            log("chunk failed: \(error)")
            return (0, false)
        }
    }

    /// Copy a time range out of the source into its own file, downmixed to 16k mono — the format
    /// speech models want anyway, and 20× smaller than the source's 44.1k stereo float.
    private static func writeChunk(from source: URL, startSeconds: Double,
                                   seconds: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let input = try AVAudioFile(forReading: source)
        let inFormat = input.processingFormat

        // 16k mono on disk (what speech models want, and 20× smaller than 44.1k stereo float).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings)

        // Convert to the file's PROCESSING format, not its on-disk format. AVAudioFile.write(from:)
        // demands buffers in processingFormat (always Float32 non-interleaved) and encodes to the
        // 16-bit file format itself. Handing it an Int16 buffer throws an ObjC exception and takes
        // the process down — which is exactly what was crashing here.
        let outFormat = output.processingFormat
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "bench", code: 1)
        }

        input.framePosition = AVAudioFramePosition(startSeconds * inFormat.sampleRate)
        let want = AVAudioFramePosition(seconds * inFormat.sampleRate)
        var remaining = min(want, input.length - input.framePosition)
        let step: AVAudioFrameCount = 16_384

        while remaining > 0 {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(step), remaining))
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { break }
            try input.read(into: inBuf, frameCount: frames)
            if inBuf.frameLength == 0 { break }
            remaining -= AVAudioFramePosition(inBuf.frameLength)

            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { break }
            var err: NSError?
            var supplied = false
            converter.convert(to: outBuf, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            if outBuf.frameLength > 0 { try output.write(from: outBuf) }
        }
    }

    private static func biggestDownload() -> URL? {
        let dir = AppSupport.directory
            .appendingPathComponent("Downloads", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension.lowercased() != "json" } ?? []
        return files.max(by: { size($0) < size($1) })
    }

    private static func log(_ message: String) {
        let stamp = String(format: "%7.1fs", Date().timeIntervalSince(started))
        let line = "[transcribe \(stamp)] \(message)"
        print(line)
        fflush(stdout)
        // Also to a file: the Simulator's stdout plumbing is unreliable, and the whole point of
        // this harness is to be readable from the host without a device.
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("verify.log")
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
    nonisolated(unsafe) private static var started = Date()

    private static func run() async {
        started = Date()
        log("=== transcription verification ===")

        // Keep the screen awake for the duration — scoped to this app, reverted on exit. The work
        // dies when the phone locks, and that is the bug, not the model.
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }

        guard #available(iOS 26, *) else { log("iOS 26 required"); return }

        // 1. Find a real downloaded episode — the biggest one, which is the case that's failing.
        let dir = AppSupport.directory
            .appendingPathComponent("Downloads", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension.lowercased() != "json" } ?? []
        guard let file = files.max(by: { size($0) < size($1) }) else {
            log("no downloaded episodes found in \(dir.path) — download one first")
            return
        }
        log("file: \(file.lastPathComponent) (\(size(file) / 1_048_576) MB)")

        // 2. Can we even read it, and how long is it?
        do {
            let audio = try AVAudioFile(forReading: file)
            let seconds = audio.processingFormat.sampleRate > 0
                ? Double(audio.length) / audio.processingFormat.sampleRate : 0
            log("audio: \(Int(seconds))s (\(String(format: "%.1f", seconds / 3600))h), format \(audio.processingFormat)")
        } catch {
            log("AVAudioFile FAILED to open: \(error)")
            return
        }

        // 3. Locale — the quiet killer. An unsupported/uninstalled locale produces an analyzer that
        //    runs happily and emits nothing at all.
        let current = Locale.current
        log("Locale.current: \(current.identifier)")
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        log("supported: \(supported.count) locales, installed: \(installed.map(\.identifier))")
        let isSupported = supported.contains { $0.identifier(.bcp47) == current.identifier(.bcp47) }
        let isInstalled = installed.contains { $0.identifier(.bcp47) == current.identifier(.bcp47) }
        log("current locale supported: \(isSupported), installed: \(isInstalled)")

        // 4. The model.
        let transcriber = SpeechTranscriber(locale: current,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log("model NOT installed — downloading…")
                try await request.downloadAndInstall()
                log("model installed")
            } else {
                log("model already installed (no install request needed)")
            }
        } catch {
            log("asset install FAILED: \(error)")
            return
        }

        // 5. Run it, narrating the first result and every 10%.
        do {
            let audio = try AVAudioFile(forReading: file)
            let seconds = Double(audio.length) / audio.processingFormat.sampleRate
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let runStart = Date()

            let collector = Task { () -> Int in
                var words = 0
                var firstAt: Date?
                var lastDecile = -1
                var results = 0
                for try await result in transcriber.results {
                    results += 1
                    if firstAt == nil {
                        firstAt = Date()
                        log("FIRST RESULT after \(String(format: "%.1f", Date().timeIntervalSince(runStart)))s")
                    }
                    // Is each result INCREMENTAL (only new words) or CUMULATIVE (everything so far)?
                    // If cumulative, walking every run of every result is quadratic — which is
                    // exactly the deceleration we're seeing.
                    if results <= 3 || results % 200 == 0 {
                        let runCount = result.text.runs.count { $0.audioTimeRange != nil }
                        let firstStart = result.text.runs.first { $0.audioTimeRange != nil }?
                            .audioTimeRange.map { $0.start.seconds } ?? -1
                        log("result #\(results): \(runCount) runs, first run starts at \(Int(firstStart))s, mem \(memoryMB())MB")
                    }
                    for run in result.text.runs where run.audioTimeRange != nil {
                        words += 1
                        guard let range = run.audioTimeRange, seconds > 0 else { continue }
                        let decile = Int(range.end.seconds / seconds * 10)
                        if decile > lastDecile {
                            lastDecile = decile
                            let elapsed = Date().timeIntervalSince(runStart)
                            let rtf = elapsed > 0 ? range.end.seconds / elapsed : 0
                            log("\(decile * 10)% — \(Int(range.end.seconds))s of audio in \(Int(elapsed))s (\(String(format: "%.1f", rtf))× realtime)")
                        }
                    }
                }
                return words
            }

            // Independent heartbeat. If results stop but this keeps ticking, the process is alive
            // and the analyzer is being starved (thermal throttle / QoS). If this stops too, we
            // were killed (jetsam) — two very different bugs that look identical from the UI.
            let heartbeat = Task.detached(priority: .utility) {
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    tick += 10
                    let thermal = ProcessInfo.processInfo.thermalState
                    let name: String
                    switch thermal {
                    case .nominal: name = "nominal"
                    case .fair: name = "fair"
                    case .serious: name = "SERIOUS"
                    case .critical: name = "CRITICAL"
                    @unknown default: name = "?"
                    }
                    log("… alive at \(tick)s — mem \(memoryMB())MB, thermal \(name), lowPower \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
                }
            }
            defer { heartbeat.cancel() }

            log("analyzeSequence starting…")
            if let last = try await analyzer.analyzeSequence(from: audio) {
                log("analyzeSequence returned; finalizing")
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                log("analyzeSequence returned NIL (no samples read!) — cancelling")
                await analyzer.cancelAndFinishNow()
            }

            let words = try await collector.value
            let elapsed = Date().timeIntervalSince(runStart)
            log("DONE: \(words) words, \(Int(seconds))s audio in \(Int(elapsed))s = \(String(format: "%.1f", seconds / max(1, elapsed)))× realtime")
        } catch {
            log("transcription FAILED: \(error)")
        }
    }

    /// Resident memory — a 4.5h file decodes to gigabytes if anything buffers the whole thing.
    private static func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : -1
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
#endif
#endif
