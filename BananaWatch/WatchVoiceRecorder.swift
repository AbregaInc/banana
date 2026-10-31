import Foundation
import AVFoundation
import WatchConnectivity

/// Records a voice note ON THE WATCH, and coordinates the podcast.
///
/// The model (per the full device matrix): the device you press records locally. So the Watch
/// records from its own input — the AirPods mic if they're paired to the Watch, the Watch's built-in
/// mic otherwise — and it broadcasts to the phone so that whichever device is *playing* the podcast
/// pauses. If the Watch itself is playing local audio, it pauses that too. When you stop, the audio
/// (with what context the Watch has: the episode + timestamp if it was the one playing) is handed to
/// the phone, which transcribes it and files it in Reminders. No phone present? WatchConnectivity
/// queues the transfer until there is one — so a watch-only run still captures the note.
@MainActor
final class WatchVoiceRecorder: NSObject, ObservableObject {
    static let shared = WatchVoiceRecorder()

    @Published private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var resumeLocalAudio = false
    private var diagnosticSpan: DiagnosticSpan?

    /// Record on whichever device holds the audio route, wherever this is pressed.
    ///
    /// The AirPods (the good mic) are bonded to ONE device — the one playing. So:
    ///  • Watch is playing → record here (AirPods are on the Watch).
    ///  • Phone is playing → the PHONE records (AirPods are on the phone); we're just the trigger.
    ///  • Nothing playing → record here (a standalone note, e.g. a journal).
    func toggle() {
        // Already recording somewhere → stop it.
        if isRecording { stop(); return }
        if let diagnosticSpan {
            let sent = WatchPhoneRemote.shared.send(
                "phoneNoteStop",
                parent: diagnosticSpan.context)
            DiagnosticJournal.shared.finish(
                diagnosticSpan,
                status: sent ? .succeeded : .failed,
                reason: sent ? "remote_stop_sent" : "phone_unreachable_for_stop")
            self.diagnosticSpan = nil
            return
        }
        if WatchPhoneRemote.shared.isRecordingNote {
            WatchPhoneRemote.shared.send("phoneNoteStop")
            return
        }

        if WatchAudioPlayer.shared.isPlaying {
            start()                                                   // Watch has the route
        } else if WatchPhoneRemote.shared.isActive && WatchPhoneRemote.shared.isPlaying {
            let trace = DiagnosticJournal.shared.startSpan(
                "voiceNote.remoteCommand",
                attributes: ["source": "watchOS", "destination": "iPhone"])
            diagnosticSpan = trace
            let sent = WatchPhoneRemote.shared.send(
                "phoneNoteStart",
                parent: trace.context)
            if !sent {
                DiagnosticJournal.shared.finish(
                    trace,
                    status: .failed,
                    reason: "phone_unreachable_for_start")
                diagnosticSpan = nil
            }
        } else {
            start()                                                   // standalone note
        }
    }

    /// True if a note is being recorded either here or on the phone (for the button's state).
    var anyRecording: Bool {
        isRecording || diagnosticSpan != nil || WatchPhoneRemote.shared.isRecordingNote
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-note-\(UUID().uuidString).m4a")
    }

    func start() {
        guard !isRecording else { return }
        let diagnostic = DiagnosticJournal.shared.startSpan(
            "voiceNote.capture",
            attributes: ["source": "watchOS"])
        diagnosticSpan = diagnostic
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .duckOthers])
            try session.setActive(true)
        } catch {
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .failed,
                reason: "audio_session_setup_failed",
                attributes: ["error": error.localizedDescription])
            diagnosticSpan = nil
            return
        }
        DiagnosticJournal.shared.checkpoint(
            diagnostic,
            "audio_session_active",
            attributes: Self.audioRouteAttributes())

        // Pause whatever's playing: our own local audio, and — via the phone — a podcast on the phone.
        if WatchAudioPlayer.shared.isPlaying {
            resumeLocalAudio = true
            WatchAudioPlayer.shared.togglePlayPause()
        }
        WatchPhoneRemote.shared.send("noteStart", parent: diagnostic.context)

        let url = fileURL
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
            if resumeLocalAudio {
                WatchAudioPlayer.shared.togglePlayPause()
                resumeLocalAudio = false
            }
            WatchPhoneRemote.shared.send("noteStop", parent: diagnostic.context)
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .failed,
                reason: "recorder_initialization_failed")
            diagnosticSpan = nil
            return
        }
        r.delegate = self
        guard r.record() else {
            if resumeLocalAudio {
                WatchAudioPlayer.shared.togglePlayPause()
                resumeLocalAudio = false
            }
            WatchPhoneRemote.shared.send("noteStop", parent: diagnostic.context)
            DiagnosticJournal.shared.finish(
                diagnostic,
                status: .failed,
                reason: "record_returned_false",
                attributes: Self.audioRouteAttributes())
            diagnosticSpan = nil
            return
        }
        recorder = r
        startedAt = Date()
        isRecording = true
        // No elapsed-time ticker here, deliberately. One used to run at 5 Hz updating a
        // @Published `elapsed` that NOTHING displayed — re-rendering the active-workout screen
        // (six metric tiles + pace math) five times a second for the length of every note.
    }

    func stop() {
        guard isRecording, let recorder else { return }
        let url = recorder.url
        let reportedDuration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // Resume what we paused.
        if resumeLocalAudio { WatchAudioPlayer.shared.togglePlayPause(); resumeLocalAudio = false }
        WatchPhoneRemote.shared.send("noteStop", parent: diagnosticSpan?.context)

        let fileBytes = (try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int) ?? 0
        let audioFile = try? AVAudioFile(forReading: url)
        let audioFrames = audioFile?.length ?? 0
        let sampleRate = audioFile?.processingFormat.sampleRate ?? 0
        let playableDuration = sampleRate > 0 ? Double(audioFrames) / sampleRate : 0
        let validAudio = audioFrames > 0 && playableDuration > 0.05 && fileBytes > 0
        let tooShort = reportedDuration < 0.6 && playableDuration < 0.6
        let attributes = [
            "reported_duration_ms": String(Int(reportedDuration * 1_000)),
            "playable_duration_ms": String(Int(playableDuration * 1_000)),
            "file_bytes": String(fileBytes),
            "audio_frames": String(audioFrames),
        ]
        if let diagnosticSpan {
            DiagnosticJournal.shared.finish(
                diagnosticSpan,
                status: tooShort ? .cancelled : (validAudio ? .succeeded : .failed),
                reason: tooShort
                    ? "capture_too_short"
                    : (validAudio ? "audio_validated" : "audio_validation_failed"),
                attributes: attributes)
            if !validAudio && !tooShort {
                WatchSyncManager.shared.queueDiagnosticSnapshot(
                    reason: "voice_note_audio_validation_failed")
            }
        }
        let traceparent = diagnosticSpan?.context.traceparent
        self.diagnosticSpan = nil

        guard !tooShort else {
            try? FileManager.default.removeItem(at: url)
            startedAt = nil
            return
        }

        // Hand the note to the phone: audio + whatever context the Watch had (if it was the one
        // playing). The phone attaches its own context instead when the phone was playing.
        var meta: [String: Any] = [
            "type": "voiceNote",
            "recordedAt": (startedAt ?? Date()).timeIntervalSince1970,
            "reportedDuration": reportedDuration,
            "playableDuration": playableDuration,
            "fileBytes": fileBytes,
            "audioFrames": Int64(audioFrames),
            "audioValid": validAudio,
        ]
        if let traceparent { meta["traceparent"] = traceparent }
        if let id = WatchAudioPlayer.shared.currentID {
            meta["episodeID"] = id
            meta["episodeTitle"] = WatchAudioPlayer.shared.currentTitle ?? ""
            meta["timestamp"] = WatchAudioPlayer.shared.currentTime
        }
        if WCSession.isSupported() {
            WCSession.default.transferFile(url, metadata: meta)   // queues until the phone is reachable
        }
        startedAt = nil
    }

    private static func audioRouteAttributes() -> [String: String] {
        let route = AVAudioSession.sharedInstance().currentRoute
        return [
            "audio_inputs": route.inputs.map(\.portType.rawValue).joined(separator: ","),
            "audio_outputs": route.outputs.map(\.portType.rawValue).joined(separator: ","),
        ]
    }
}

extension WatchVoiceRecorder: AVAudioRecorderDelegate {
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
