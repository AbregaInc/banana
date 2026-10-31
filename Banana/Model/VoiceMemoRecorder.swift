#if os(iOS)
import Foundation
import AVFoundation

struct VoiceCaptureResult {
    let reportedDuration: TimeInterval
    let playableDuration: TimeInterval
    let fileBytes: Int
    let audioFrames: AVAudioFramePosition

    static let empty = VoiceCaptureResult(
        reportedDuration: 0,
        playableDuration: 0,
        fileBytes: 0,
        audioFrames: 0)

    var containsPlayableAudio: Bool {
        audioFrames > 0 && playableDuration > 0.05 && fileBytes > 0
    }

    var diagnosticAttributes: [String: String] {
        [
            "reported_duration_ms": String(Int(reportedDuration * 1_000)),
            "playable_duration_ms": String(Int(playableDuration * 1_000)),
            "file_bytes": String(fileBytes),
            "audio_frames": String(audioFrames),
        ]
    }

    static func inspect(url: URL, reportedDuration: TimeInterval) -> VoiceCaptureResult {
        let bytes = (try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int) ?? 0
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else {
            return VoiceCaptureResult(
                reportedDuration: reportedDuration,
                playableDuration: 0,
                fileBytes: bytes,
                audioFrames: 0)
        }
        return VoiceCaptureResult(
            reportedDuration: reportedDuration,
            playableDuration: Double(file.length) / file.processingFormat.sampleRate,
            fileBytes: bytes,
            audioFrames: file.length)
    }
}

/// Records a short spoken note, coexisting with podcast playback.
///
/// The podcast owns an `.playback` audio session and, on a run, the output is usually AirPods. To
/// record cleanly you have to (1) pause the podcast — you can't have it bleeding into the note —
/// and (2) switch the session to `.playAndRecord` with Bluetooth allowed, which routes the AirPods
/// mic in. On stop, hand the session back exactly as it was so playback resumes on the same route.
///
/// This is deliberately the ONLY thing in the app besides PlayerController that touches the audio
/// session, and it always restores `.playback` when done — a recorder that leaves the session in
/// `.playAndRecord` would quietly halve playback volume (the record category ducks) forever after.
@MainActor
final class VoiceMemoRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0          // 0…1, for a live meter
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var startedAt: Date?
    private var diagnosticSpan: DiagnosticSpan?

    override init() {
        super.init()
        // A phone call (or Siri) interrupts the recorder silently. Without this, `isRecording`
        // stayed true and the 20 Hz meter kept polling a stalled recorder until the user noticed.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated {
                guard self.isRecording else { return }
                PlaybackDiagnostics.shared.log("voice note: interrupted — finishing capture")
                // Finish through the flow's OWNER, not by stopping the recorder underneath it.
                // Stopping here first zeroed `recorder.currentTime`, so the store's later
                // finishCapture read a 0s duration and DELETED the interrupted note. Finishing
                // the capture now — while the recorder still reports its real duration — saves
                // the audio and files the reminder like any deliberate stop.
                if VoiceNoteStore.shared.isRecording {
                    VoiceNoteStore.shared.finishCapture(interrupted: true)
                } else {
                    _ = self.stop()
                }
            }
        }
    }

    static var audioDir: URL {
        let dir = AppSupport.directory
            .appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Begin recording to a new file. Returns the filename (relative to `audioDir`) or nil on failure.
    @discardableResult
    func start(parent: DiagnosticTraceContext? = nil) -> String? {
        guard !isRecording else { return nil }
        let diagnostic = DiagnosticJournal.shared.startSpan(
            "voiceNote.audioRecord",
            parent: parent,
            attributes: Self.audioRouteAttributes())
        diagnosticSpan = diagnostic
        let session = AVAudioSession.sharedInstance()
        do {
            // Bluetooth HFP routes the AirPods mic in; .duckOthers + pausing the
            // player belt-and-braces against anything else making noise into the take.
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
            try session.setActive(true)
        } catch {
            PlaybackDiagnostics.shared.log("voice note: session setup FAILED", "\(error)")
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .failed,
                reason: "audio_session_setup_failed",
                attributes: ["error": error.localizedDescription])
            diagnosticSpan = nil
            return nil
        }
        DiagnosticJournal.shared.checkpoint(
            diagnostic,
            "audio_session_active",
            attributes: Self.audioRouteAttributes())

        let filename = "\(UUID().uuidString).m4a"
        let url = Self.audioDir.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.record() else {
                PlaybackDiagnostics.shared.log("voice note: record() returned false")
                try? FileManager.default.removeItem(at: url)
                Self.restorePlaybackSessionAfterFailedStart()
                DiagnosticJournal.shared.finish(
                    diagnostic,
                    status: .failed,
                    reason: "record_returned_false",
                    attributes: Self.audioRouteAttributes())
                diagnosticSpan = nil
                return nil
            }
            recorder = r
            startedAt = Date()
            isRecording = true
            startMeter()
            PlaybackDiagnostics.shared.log("voice note: recording", filename)
            return filename
        } catch {
            PlaybackDiagnostics.shared.log("voice note: recorder init FAILED", "\(error)")
            try? FileManager.default.removeItem(at: url)
            Self.restorePlaybackSessionAfterFailedStart()
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .failed,
                reason: "recorder_initialization_failed",
                attributes: ["error": error.localizedDescription])
            diagnosticSpan = nil
            return nil
        }
    }

    /// Stop recording and hand the audio session back to playback. Returns the finished file's
    /// duration in seconds (0 if it failed or was too short to keep).
    @discardableResult
    func stop() -> VoiceCaptureResult {
        guard isRecording, let recorder else { return .empty }
        let reportedDuration = recorder.currentTime
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        meter?.invalidate(); meter = nil
        isRecording = false
        level = 0

        // Restore the podcast's session. PlayerController re-activates on resume, but the category
        // must go back to .playback here or the next play stays ducked.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        let result = VoiceCaptureResult.inspect(
            url: url,
            reportedDuration: reportedDuration)
        PlaybackDiagnostics.shared.log(
            "voice note: stopped",
            "reported=\(Int(reportedDuration))s playable=\(String(format: "%.2f", result.playableDuration))s frames=\(result.audioFrames)")
        if let diagnosticSpan {
            DiagnosticJournal.shared.finish(
                diagnosticSpan,
                status: result.containsPlayableAudio ? .succeeded : .failed,
                reason: result.containsPlayableAudio ? "audio_validated" : "audio_validation_failed",
                attributes: result.diagnosticAttributes.merging(
                    Self.audioRouteAttributes()) { _, route in route })
        }
        diagnosticSpan = nil
        return result
    }

    private func startMeter() {
        // The timer fires on the main run loop already — assumeIsolated instead of allocating a
        // fresh Task per tick (this runs at 20 Hz for the length of every note).
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                // dB (-160…0) → 0…1, curved so speech sits in the visible range.
                let db = r.averagePower(forChannel: 0)
                self.level = max(0, min(1, pow(10, db / 40)))
                if let s = self.startedAt { self.elapsed = Date().timeIntervalSince(s) }
            }
        }
    }

    private static func audioRouteAttributes() -> [String: String] {
        let route = AVAudioSession.sharedInstance().currentRoute
        return [
            "audio_inputs": route.inputs.map(\.portType.rawValue).joined(separator: ","),
            "audio_outputs": route.outputs.map(\.portType.rawValue).joined(separator: ","),
        ]
    }

    private static func restorePlaybackSessionAfterFailedStart() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }
}

extension VoiceMemoRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            guard let diagnosticSpan else { return }
            DiagnosticJournal.shared.checkpoint(
                diagnosticSpan,
                flag ? "recorder_delegate_finished" : "recorder_delegate_failed")
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Error?
    ) {
        Task { @MainActor in
            guard let diagnosticSpan else { return }
            DiagnosticJournal.shared.checkpoint(
                diagnosticSpan,
                "recorder_encode_error",
                attributes: ["error": error?.localizedDescription ?? "unknown"])
        }
    }
}
#endif
