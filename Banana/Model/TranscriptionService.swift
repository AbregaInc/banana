import Foundation
import AVFoundation
import Speech
#if canImport(FluidAudio)
import FluidAudio
#endif

/// A device-local choice. It deliberately does not ride AppSettings' iCloud KVS: selecting a
/// ~565 MB model on a Mac must not silently make an iPhone download the same model.
enum LocalTranscriptionEngine: String, CaseIterable, Identifiable {
    case apple
    case parakeet

    static let defaultsKey = "localTranscriptionEngine"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple (built in)"
        case .parakeet: return "Parakeet (local)"
        }
    }

    static var selected: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Produces word-timed transcripts, on-device. Sources:
///  • a transcript already published in the feed (Podcasting 2.0 JSON/WebVTT/SRT) — free; word times
///    are interpolated within each cue.
///  • Apple's on-device `SpeechAnalyzer` (iOS 26) — real word-level `audioTimeRange`s.
///  • opt-in Parakeet v3 through FluidAudio — local multilingual ASR with word timings.
enum TranscriptionService {

    struct FeedTranscript: Sendable {
        var words: [TranscriptWord]
        var speakerNames: [Int: String]
    }

    // MARK: - Feed transcripts (Podcasting 2.0 JSON / WebVTT / SRT)

    /// Fetch + parse one publisher candidate. The coordinator tries every advertised candidate, so
    /// one stale JSON URL does not hide a working VTT fallback from the same feed.
    static func feedTranscript(from source: EpisodeTranscriptSource) async -> FeedTranscript? {
        guard let data = await FeedTranscriptParser.fetch(source.url) else { return nil }
        let type = (source.type ?? source.url.pathExtension).lowercased()
        if type.contains("json") || data.first(where: { !$0.isASCIIWhitespace }) == UInt8(ascii: "{") {
            return parsePodcastingJSON(data)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let cues = FeedTranscriptParser.parseTimedText(text)
        guard !cues.isEmpty else { return nil }

        var names: [String: Int] = [:]
        var displayNames: [Int: String] = [:]
        let words = cues.flatMap { cue -> [TranscriptWord] in
            let speaker = cue.speaker.map { name -> Int in
                if let existing = names[name] { return existing }
                let index = names.count
                names[name] = index
                displayNames[index] = name
                return index
            }
            return FeedTranscriptParser.interpolateWords(in: (cue.start, cue.end, cue.text), speaker: speaker)
        }
        return FeedTranscript(words: words, speakerNames: displayNames)
    }

    /// Parse WebVTT or SRT into (start, end, text) cues.
    static func parseTimedText(_ raw: String) -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        FeedTranscriptParser.parseTimedText(raw).map { ($0.start, $0.end, $0.text) }
    }

    private struct PodcastingJSONTranscript: Decodable {
        struct Segment: Decodable {
            var speaker: String?
            var startTime: TimeInterval
            var endTime: TimeInterval?
            var body: String
        }
        var segments: [Segment]
    }

    private static func parsePodcastingJSON(_ data: Data) -> FeedTranscript? {
        guard let document = try? JSONDecoder().decode(PodcastingJSONTranscript.self, from: data),
              !document.segments.isEmpty else { return nil }
        var names: [String: Int] = [:]
        var displayNames: [Int: String] = [:]
        var words: [TranscriptWord] = []

        for (index, segment) in document.segments.enumerated() {
            let body = segment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, segment.startTime >= 0 else { continue }
            let nextStart = document.segments.indices.contains(index + 1)
                ? document.segments[index + 1].startTime : nil
            let estimated = segment.startTime + max(1, Double(body.count) / 14)
            let end = max(segment.startTime, segment.endTime ?? nextStart ?? estimated)
            let speaker = segment.speaker.flatMap { raw -> Int? in
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                if let existing = names[name] { return existing }
                let value = names.count
                names[name] = value
                displayNames[value] = name
                return value
            }
            words.append(contentsOf: FeedTranscriptParser.interpolateWords(
                in: (segment.startTime, end, body), speaker: speaker))
        }
        guard !words.isEmpty else { return nil }
        return FeedTranscript(words: words, speakerNames: displayNames)
    }

    // MARK: - On-device ASR (SpeechAnalyzer, iOS 26)

    static var onDeviceAvailable: Bool { if #available(iOS 26, *) { return true } else { return false } }

    /// What the transcriber is doing. Downloading the speech model can take minutes on its own,
    /// and reporting that as "0%" makes a working app look hung.
    enum Stage: Sendable {
        case installingModel
        case transcribing(Double)   // 0…1
    }

    static var parakeetAvailable: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    /// Parakeet's model is fetched only after this explicit engine is selected and transcription is
    /// actually requested. FluidAudio caches the model; the actor keeps one loaded manager and
    /// serializes long jobs instead of loading ~0.6B parameters once per episode.
    static func transcribeParakeet(
        fileURL: URL, stage: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> [TranscriptWord] {
        #if canImport(FluidAudio)
        stage?(.installingModel)
        let words = try await ParakeetTranscriber.shared.transcribe(fileURL) { progress in
            stage?(.transcribing(progress))
        }
        stage?(.transcribing(1))
        return words
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    /// The supported locale closest to the user's. Falls back to any same-language locale, then to
    /// whatever the device has.
    @available(iOS 26, *)
    static func supportedLocale() async -> Locale {
        let current = Locale.current
        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return exact
        }
        if let language = current.language.languageCode?.identifier,
           let sameLanguage = supported.first(where: { $0.language.languageCode?.identifier == language }) {
            return sameLanguage
        }
        return supported.first ?? current
    }

    /// Allocate the locale to this app. Idempotent, and deliberately best-effort: transcription
    /// demonstrably worked on device without this call, so a reservation failure must never be
    /// allowed to break a path that was already working. If the missing allocation IS the bug
    /// (SFSpeechError.assetLocaleNotAllocated — "not subscribed to transcription.en"), this fixes it.
    @available(iOS 26, *)
    static func reserveLocale(_ locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }

        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            _ = await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - Segments (for resumable transcription)

    static func duration(of fileURL: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: fileURL),
              file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Transcribe one slice of a file, with word times re-based to absolute position in the episode.
    ///
    /// This is what makes transcription survivable. A `BGProcessingTask` can be revoked at any
    /// instant — there is no budget to fit inside — so the job has to be killable at any moment and
    /// lose only the current slice, not the whole episode.
    @available(iOS 26, *)
    static func transcribeSegment(fileURL: URL, startSeconds: Double, seconds: Double,
                                  priority: TaskPriority? = .userInitiated,
                                  retention: SpeechAnalyzer.Options.ModelRetention = .processLifetime,
                                  stage: (@Sendable (Stage) -> Void)? = nil,
                                  checkpoint: (@Sendable ([TranscriptWord]) -> Void)? = nil) async throws -> [TranscriptWord] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeSegment(from: fileURL, startSeconds: startSeconds, seconds: seconds, to: tmp)
        @Sendable func rebase(_ words: [TranscriptWord]) -> [TranscriptWord] {
            words.map {
                TranscriptWord(text: $0.text, start: $0.start + startSeconds,
                               end: $0.end + startSeconds, speaker: $0.speaker)
            }
        }
        let words = try await transcribeOnDevice(fileURL: tmp, priority: priority, retention: retention,
                                                 stage: stage) { partial in
            checkpoint?(rebase(partial))
        }
        return rebase(words)
    }

    /// Copy a time range into its own file, downmixed to 16k mono — what speech models want, and
    /// far smaller than 44.1k stereo float.
    static func writeSegment(from source: URL, startSeconds: Double, seconds: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let input = try AVAudioFile(forReading: source)
        let inFormat = input.processingFormat

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings)

        // Convert to the file's PROCESSING format, not its on-disk format. `write(from:)` demands
        // Float32 non-interleaved buffers and encodes to 16-bit itself; handing it an Int16 buffer
        // throws an ObjC exception and kills the process.
        let outFormat = output.processingFormat
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "TranscriptionService", code: 1)
        }

        input.framePosition = AVAudioFramePosition(startSeconds * inFormat.sampleRate)
        var remaining = min(AVAudioFramePosition(seconds * inFormat.sampleRate),
                            input.length - input.framePosition)
        let step: AVAudioFrameCount = 16_384

        while remaining > 0 {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(step), remaining))
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { break }
            try input.read(into: inBuf, frameCount: frames)
            if inBuf.frameLength == 0 { break }
            remaining -= AVAudioFramePosition(inBuf.frameLength)

            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { break }
            var error: NSError?
            var supplied = false
            converter.convert(to: outBuf, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return inBuf
            }
            if let error { throw error }
            if outBuf.frameLength > 0 { try output.write(from: outBuf) }
        }
    }

    /// Transcribe an audio file to word tokens fully on device.
    ///
    /// Uses `SpeechAnalyzer.analyzeSequence(from:)` so the framework owns reading the file and
    /// converting it to the analyzer's required audio format. (Hand-feeding raw buffers in the
    /// file's native format is what SpeechAnalyzer rejects — the earlier cause of failures.)
    @available(iOS 26, *)
    static func transcribeOnDevice(fileURL: URL,
                                   priority: TaskPriority? = .userInitiated,
                                   retention: SpeechAnalyzer.Options.ModelRetention = .processLifetime,
                                   stage: (@Sendable (Stage) -> Void)? = nil,
                                   checkpoint: (@Sendable ([TranscriptWord]) -> Void)? = nil) async throws -> [TranscriptWord] {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalSeconds = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0

        // Pick a locale the transcriber actually supports. Locale.current may be a variant with no
        // model (e.g. an English locale that isn't one of the nine installed), which yields an
        // analyzer that runs and emits nothing.
        let locale = await supportedLocale()

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // The locale must be ALLOCATED to this app before its model can be used. Without it the
        // framework refuses with SFSpeechError.assetLocaleNotAllocated — surfaced as "…is not
        // subscribed to transcription.en" — which is what broke transcription after a reinstall
        // dropped the previous allocation. Reservations are a limited resource
        // (AssetInventory.maximumReservedLocales), so release the oldest if we're at the cap.
        stage?(.installingModel)
        await reserveLocale(locale)

        // Ensure the on-device model is installed (no-op once present). On a cold device this is a
        // multi-hundred-MB download, and is where a "stuck at 1%" usually lives.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // We were constructing the analyzer with no Options at all, i.e. default priority and
        // default model retention. Two things we were leaving on the floor:
        //  • priority — the analysis runs at whatever the default is unless we ask for better.
        //  • modelRetention — a fresh analyzer per episode reloads the speech model each time, so
        //    the overnight batch was paying that cost once per episode.
        // `priority: nil` reproduces what we shipped for weeks: no Options at all, i.e. default
        // priority and default model retention. That's the baseline every RTF number so far was
        // measured against, so it's the thing worth A/B-ing.
        let options: SpeechAnalyzer.Options? = priority.map {
            .init(priority: $0, modelRetention: retention)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        let started = Date()
        stage?(.transcribing(0))

        // Collect results concurrently, driving progress off the latest word's end time.
        //
        // Progress is throttled to whole percents. It used to fire per word, and each call hopped
        // to the main actor to mutate @Published state — ~40k hops and ~40k view invalidations for
        // a four-hour episode. The main thread became the bottleneck and starved this very loop,
        // so the transcriber crawled. We were measuring SwiftUI, not the model.
        let collector = Task { () -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            var lastPercent = -1
            var lastCheckpoint = Date()
            var checkpointedCount = 0
            for try await result in transcriber.results {
                try Task.checkCancellation()   // an expiring BGProcessingTask cancels us here
                let attributed = result.text
                for run in attributed.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let token = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { continue }
                    words.append(TranscriptWord(text: token, start: range.start.seconds, end: range.end.seconds, speaker: nil))

                    if let stage, totalSeconds > 0 {
                        let fraction = min(1, range.end.seconds / totalSeconds)
                        // Per-mille, not per-cent: the continued-processing scheduler stalls a task
                        // whose progress stops moving, and at 1% granularity a four-hour episode
                        // only advances every ~3 seconds.
                        let permille = Int(fraction * 1000)
                        if permille > lastPercent {
                            lastPercent = permille
                            stage(.transcribing(fraction))
                        }
                    }
                }
                // Hand the caller the words so far every ~20s, so being killed costs seconds.
                if let checkpoint, Date().timeIntervalSince(lastCheckpoint) > 20 {
                    lastCheckpoint = Date()
                    if checkpointedCount < words.count {
                        checkpoint(Array(words[checkpointedCount...]))
                        checkpointedCount = words.count
                    }
                }
            }
            return words
        }

        // Let the framework read + format-convert the whole file, then flush.
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let words = try await collector.value

        // Real-time factor: >1 means faster than playback. This is the number that decides whether
        // Apple's model is good enough or we need a different one — measured, not guessed.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0, totalSeconds > 0 {
            Log.wake.notice("""
                transcribe: \(Int(totalSeconds))s audio in \(Int(elapsed))s \
                (\(String(format: "%.1f", totalSeconds / elapsed))× realtime, \(words.count) words)
                """)
        }
        return words
    }
}

#if canImport(FluidAudio)
/// One model graph per process. The actor is also the concurrency limit: running two 0.6B ASR jobs
/// together is slower, raises memory pressure, and wastes energy without improving user-perceived
/// latency because completed transcripts sync to every device.
private actor ParakeetTranscriber {
    static let shared = ParakeetTranscriber()
    private var manager: AsrManager?

    func transcribe(
        _ fileURL: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptWord] {
        let manager = try await loadedManager()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        progress(0)
        let progressTask = Task {
            let stream = await manager.transcriptionProgressStream
            do {
                for try await fraction in stream where !Task.isCancelled {
                    progress(fraction)
                }
            } catch { }
        }
        defer { progressTask.cancel() }
        let result = try await manager.transcribe(fileURL, decoderState: &state)
        let timings = buildWordTimings(from: result.tokenTimings ?? [])
        if !timings.isEmpty {
            return timings.map {
                TranscriptWord(text: $0.word, start: $0.startTime, end: $0.endTime, speaker: nil)
            }
        }

        // Defensive fallback for a future model that returns text but no token timings. Distribute
        // over its reported audio duration so search/notes remain useful and seeking stays bounded.
        let tokens = result.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let step = result.duration / Double(max(1, tokens.count))
        return tokens.enumerated().map {
            TranscriptWord(text: $0.element, start: Double($0.offset) * step,
                           end: Double($0.offset + 1) * step, speaker: nil)
        }
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let loaded = AsrManager(config: .default)
        try await loaded.loadModels(models)
        manager = loaded
        return loaded
    }
}
#endif

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}
