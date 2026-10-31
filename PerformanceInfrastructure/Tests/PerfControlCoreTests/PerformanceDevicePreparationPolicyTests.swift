import PerfControlCore
import Testing

struct PerformanceDevicePreparationPolicyTests {
    @Test
    func silentPlannerMayUseAnExplicitlyAcknowledgedPersonalDevice() throws {
        let mode = try PerformanceDevicePreparationPolicy.validate(
            scenarioID: "planner.refresh",
            hasAudioFixture: false,
            dedicatedDevice: false,
            personalDevice: true)
        #expect(mode == .personal)
    }

    @Test
    func personalDeviceRejectsEveryAudioPath() {
        #expect(throws: PerformanceDevicePreparationPolicyError.audibleScenarioRequiresDedicatedDevice) {
            try PerformanceDevicePreparationPolicy.validate(
                scenarioID: "playback.local",
                hasAudioFixture: true,
                dedicatedDevice: false,
                personalDevice: true)
        }
        #expect(throws: PerformanceDevicePreparationPolicyError.personalDeviceCannotSeedAudio) {
            try PerformanceDevicePreparationPolicy.validate(
                scenarioID: "planner.refresh",
                hasAudioFixture: true,
                dedicatedDevice: false,
                personalDevice: true)
        }
    }

    @Test
    func deviceUseMustBeExactlyOneExplicitMode() {
        #expect(throws: PerformanceDevicePreparationPolicyError.missingDeviceUseAcknowledgement) {
            try PerformanceDevicePreparationPolicy.validate(
                scenarioID: "planner.refresh",
                hasAudioFixture: false,
                dedicatedDevice: false,
                personalDevice: false)
        }
        #expect(throws: PerformanceDevicePreparationPolicyError.conflictingDeviceUseAcknowledgements) {
            try PerformanceDevicePreparationPolicy.validate(
                scenarioID: "planner.refresh",
                hasAudioFixture: false,
                dedicatedDevice: true,
                personalDevice: true)
        }
    }
}
