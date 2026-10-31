import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Speaker diarization ("who spoke when"). Runs entirely on device, with the transcript it labels.
///
/// A publisher's transcript brings its own speaker names and needs none of this. For a transcript
/// made on the device, FluidAudio's offline pipeline (the package Parakeet already comes from)
/// tells the voices apart; it needs a model of its own, downloaded the first time, so it is a
/// per-device switch that starts off (`SpeakerLabelling`).
protocol Diarizer {
    var isAvailable: Bool { get }
    /// Diarize an audio file into speaker turns. Empty result = couldn't diarize.
    func diarize(fileURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerTurn]
}

/// No labelling: the switch is off, or this build has no FluidAudio.
struct DefaultDiarizer: Diarizer {
    var isAvailable: Bool { false }
    func diarize(fileURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerTurn] { [] }
}

/// The per-device switch for labelling speakers in transcripts made on this device.
enum SpeakerLabelling {
    private static let key = "transcriptSpeakerLabels"

    static var available: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    static var enabled: Bool {
        get { available && UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The diarizer a transcript being finished now should use.
    static var diarizer: Diarizer {
        #if canImport(FluidAudio)
        if enabled { return FluidDiarizer() }
        #endif
        return DefaultDiarizer()
    }
}

#if canImport(FluidAudio)
/// FluidAudio's offline diarization (segmentation, voice embeddings, clustering), one job at a
/// time with the models kept loaded between jobs.
struct FluidDiarizer: Diarizer {
    var isAvailable: Bool { true }

    func diarize(fileURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerTurn] {
        try await FluidDiarizerHost.shared.diarize(fileURL, progress: progress)
    }
}

private actor FluidDiarizerHost {
    static let shared = FluidDiarizerHost()
    private var manager: OfflineDiarizerManager?

    func diarize(_ url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerTurn] {
        let manager = self.manager ?? OfflineDiarizerManager()
        try await manager.prepareModels()   // downloads and compiles the models the first time
        self.manager = manager
        let result = try await manager.process(url) { done, total in
            progress?(total > 0 ? Double(done) / Double(total) : 0)
        }
        return Diarization.turns(result.segments.map {
            (speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        })
    }
}
#endif
