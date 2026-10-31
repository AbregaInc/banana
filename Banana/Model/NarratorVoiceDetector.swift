#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import Accelerate
import os

/// Works out what an episode's narrator sounds like, for shows that never credit one.
///
/// Three things have to be right and each was measured rather than assumed:
///
/// WHERE to listen. At 1, 3 and 5 minutes into a sleep story you get the intro, the ads, or the
/// show's own host — accuracy 3/6, 3/6, 4/6. At 10, 15 and 20 minutes you get the narrator.
///
/// WHETHER it is speech at all. Past roughly 45 minutes the narration stops and the rest of a
/// multi-hour episode is soundscape. The classifier has no way to say "that is not a voice": fed
/// rain it answers confidently anyway. So every window is checked for speech first.
///
/// WHETHER the windows agree. One sample near the boundary can flip — the same narrator came back
/// female at 0.62 on one clip and male at 0.90 on another. Unanimity is required, and a split
/// means no answer rather than a coin toss.
@MainActor
enum NarratorVoiceDetector {
    private static let log = Logger(subsystem: "com.boris.banana", category: "voice")

    struct Reading: Codable, Sendable {
        var gender: VoiceGender
        /// Lowest confidence among the agreeing windows — the honest figure, not the best one.
        var confidence: Double
        var windowsUsed: Int
    }

    /// Listen to an episode and decide, or return nil when it cannot be decided honestly.
    static func read(fileURL: URL) async -> Reading? {
        var verdicts: [(VoiceGender, Double)] = []
        for offset in VoiceGenderClassifier.sampleOffsets {
            guard let samples = await pcm(from: fileURL, at: offset) else { continue }
            guard containsSpeech(samples) else {
                log.debug("[voice] \(offset, privacy: .public)s: no speech, skipped")
                continue
            }
            guard let verdict = try? VoiceGenderClassifier.shared.classify(samples: samples) else { continue }
            verdicts.append((verdict.gender, verdict.confidence))
        }
        guard let first = verdicts.first else { return nil }
        guard verdicts.allSatisfy({ $0.0 == first.0 }) else {
            log.notice("[voice] windows disagreed; leaving this episode alone")
            return nil
        }
        return Reading(gender: first.0,
                       confidence: verdicts.map(\.1).min() ?? first.1,
                       windowsUsed: verdicts.count)
    }

    // MARK: - Is this actually someone talking?

    /// Speech starts and stops; a soundscape does not.
    ///
    /// Frame-energy variation alone, measured on real episodes: narration sits at 0.80–1.22 and
    /// the ambience after the story ends at 0.28–0.57. 0.70 sits in that gap. It also rejects the
    /// one-minute mark (0.49–0.63), which is music and titles rather than anyone reading.
    ///
    /// Spectral flatness was tried alongside it and dropped: across the same clips narration
    /// ranged 0.08–0.66 against ambience at 0.01–0.08, so the two overlap and adding it only threw
    /// away good windows. A second test that does not discriminate is not caution, it is noise.
    static let minimumEnergyVariation: Float = 0.70

    static func containsSpeech(_ samples: [Float]) -> Bool {
        guard samples.count > 16_000 else { return false }
        return energyVariation(samples) >= minimumEnergyVariation
    }

    /// Standard deviation of frame energy over its mean.
    static func energyVariation(_ samples: [Float], frame: Int = 800) -> Float {
        let frames = samples.count / frame
        guard frames > 4 else { return 0 }
        var energies = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            var sum: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                vDSP_measqv(buffer.baseAddress! + index * frame, 1, &sum, vDSP_Length(frame))
            }
            energies[index] = sqrt(sum) + 1e-9
        }
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(energies, 1, nil, 1, &mean, &deviation, vDSP_Length(frames))
        return mean > 0 ? deviation / mean : 0
    }

    /// Geometric mean of the spectrum over its arithmetic mean.
    static func spectralFlatness(_ samples: [Float]) -> Float {
        let count = 4096
        guard samples.count >= count else { return 0 }
        let start = (samples.count - count) / 2
        var windowed = [Float](repeating: 0, count: count)
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(Array(samples[start..<(start + count)]), 1, window, 1, &windowed, 1, vDSP_Length(count))
        let log2n = vDSP_Length(log2(Float(count)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = windowed, imaginary = [Float](repeating: 0, count: count)
        var magnitudes = [Float](repeating: 0, count: count / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(count / 2))
            }
        }
        // `vDSP_zvmags` gives magnitude SQUARED; flatness is defined over magnitudes, and the
        // squaring pushes the geometric mean far enough down that everything reads as tonal.
        var count32 = Int32(magnitudes.count)
        var rooted = [Float](repeating: 0, count: magnitudes.count)
        vvsqrtf(&rooted, &magnitudes, &count32)
        var floored = rooted.map { $0 + 1e-12 }
        var arithmetic: Float = 0
        vDSP_meanv(floored, 1, &arithmetic, vDSP_Length(floored.count))
        guard arithmetic > 0 else { return 0 }
        var logs = [Float](repeating: 0, count: floored.count)
        var n = Int32(floored.count)
        vvlogf(&logs, &floored, &n)
        var meanLog: Float = 0
        vDSP_meanv(logs, 1, &meanLog, vDSP_Length(logs.count))
        return exp(meanLog) / arithmetic
    }

    // MARK: - Audio

    /// 20 s of 16 kHz mono from `offset` into the file, or nil if the file is shorter than that.
    static func pcm(from url: URL, at offset: TimeInterval) async -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let source = file.processingFormat
        let startFrame = AVAudioFramePosition(offset * source.sampleRate)
        let wanted = AVAudioFrameCount(20 * source.sampleRate)
        guard file.length > startFrame + AVAudioFramePosition(wanted) else { return nil }
        file.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: wanted),
              (try? file.read(into: buffer, frameCount: wanted)) != nil else { return nil }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: VoiceGenderClassifier.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target,
                                         frameCapacity: AVAudioFrameCount(VoiceGenderClassifier.windowSamples))
        else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
#endif
