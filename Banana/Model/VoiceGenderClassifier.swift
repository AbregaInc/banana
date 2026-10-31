#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import CoreML
import Accelerate
import os

/// Runs `NarratorVoiceModel.mlpackage` — JaesungHuh/voice-gender-classifier, an ECAPA-TDNN under
/// MIT, converted to CoreML. The resource is named so it cannot collide with the `VoiceGender`
/// enum Xcode would otherwise generate a class for.
///
/// Measured on 20 real narrators: 90% agreement with the narrator the feed credits, and zero
/// disagreement between this CoreML build and the PyTorch original it came from.
///
/// It is a guess, and it is wrong about roughly one narrator in ten AT FULL CONFIDENCE — both of
/// its measured mistakes came back at 1.00. Nothing here treats confidence as proof.
@MainActor
final class VoiceGenderClassifier {
    static let shared = VoiceGenderClassifier()
    private static let log = Logger(subsystem: "com.boris.banana", category: "voice")

    /// The window the model was converted for: 20 s of 16 kHz mono.
    static let sampleRate: Double = 16_000
    static let windowSamples = 16_000 * 20

    /// Where in an episode to listen.
    ///
    /// Measured on real sleep stories: at 1, 3 and 5 minutes the answer is still the intro, the ads
    /// or the show's own host, and accuracy was 3/6, 3/6 and 4/6. At 10, 15 and 30 minutes it was
    /// 6/6. Past about 45 minutes the narration stops and the rest is soundscape, so sampling late
    /// asks the model to gender rain — which it does, confidently.
    static let sampleOffsets: [TimeInterval] = [10 * 60, 15 * 60, 20 * 60]

    private var model: MLModel?

    private func loadedModel() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: "NarratorVoiceModel", withExtension: "mlmodelc") else {
            throw ClassifierError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        model = loaded
        return loaded
    }

    enum ClassifierError: Error { case modelMissing, badAudio }

    /// Classify one window of 16 kHz mono samples.
    func classify(samples: [Float]) throws -> (gender: VoiceGender, confidence: Double) {
        let model = try loadedModel()
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
        for index in 0..<Self.windowSamples {
            pointer[index] = index < samples.count ? samples[index] : 0
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: input)])
        let output = try model.prediction(from: provider)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw ClassifierError.badAudio
        }
        // Index order is the model's own: 0 male, 1 female.
        let male = logits[[0, 0] as [NSNumber]].doubleValue
        let female = logits[[0, 1] as [NSNumber]].doubleValue
        let top = max(male, female)
        let expMale = exp(male - top), expFemale = exp(female - top)
        let sum = expMale + expFemale
        return female > male
            ? (.female, expFemale / sum)
            : (.male, expMale / sum)
    }
}
#endif
