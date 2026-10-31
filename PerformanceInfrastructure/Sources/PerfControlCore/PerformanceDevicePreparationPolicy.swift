import Foundation

public enum PerformanceDeviceUseMode: Equatable, Sendable {
    case dedicated
    case personal
}

public enum PerformanceDevicePreparationPolicyError: Error, Equatable, Sendable {
    case missingDeviceUseAcknowledgement
    case conflictingDeviceUseAcknowledgements
    case audibleScenarioRequiresDedicatedDevice
    case personalDeviceCannotSeedAudio
}

public enum PerformanceDevicePreparationPolicy {
    /// Make the physical-device tradeoff explicit. A personal device is supported only for the
    /// silent scenarios: the instrumented build is installed in place, but no audio fixture is
    /// copied and the playback graph is never started.
    public static func validate(
        scenarioID: String,
        hasAudioFixture: Bool,
        dedicatedDevice: Bool,
        personalDevice: Bool
    ) throws -> PerformanceDeviceUseMode {
        guard dedicatedDevice || personalDevice else {
            throw PerformanceDevicePreparationPolicyError.missingDeviceUseAcknowledgement
        }
        guard dedicatedDevice != personalDevice else {
            throw PerformanceDevicePreparationPolicyError.conflictingDeviceUseAcknowledgements
        }
        if personalDevice {
            guard scenarioID != "playback.local" else {
                throw PerformanceDevicePreparationPolicyError.audibleScenarioRequiresDedicatedDevice
            }
            guard !hasAudioFixture else {
                throw PerformanceDevicePreparationPolicyError.personalDeviceCannotSeedAudio
            }
            return .personal
        }
        return .dedicated
    }
}
