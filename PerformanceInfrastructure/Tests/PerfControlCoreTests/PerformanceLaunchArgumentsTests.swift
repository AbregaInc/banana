import PerformanceContracts
import Testing
@testable import PerfControlCore

struct PerformanceLaunchArgumentsTests {
    @Test
    func hostLaunchArgumentsRoundTripThroughTheAppParser() throws {
        let request = PerformanceScenarioRequest(
            scenarioID: "playback.local",
            runID: "44444444-4444-4444-4444-444444444444",
            durationSeconds: 28_800,
            sampleIntervalSeconds: 60,
            settleSeconds: 45,
            variant: "baseline",
            gitCommit: "def456",
            fixtureDigest: "sha256:audio")

        let arguments = PerformanceLaunchArguments.make(for: request)
        let reparsed = try PerformanceScenarioRequest.parse(
            arguments: ["Banana"] + arguments)

        #expect(reparsed == request)
        #expect(arguments.first == "--perf-scenario")
    }

    @Test
    func peerOffVariantAddsTheSilentServingOverride() {
        let request = PerformanceScenarioRequest(
            scenarioID: "control.idle",
            runID: "77777777-7777-7777-7777-777777777777",
            durationSeconds: 60,
            sampleIntervalSeconds: 5,
            settleSeconds: 0,
            variant: "tethered-peer-off",
            gitCommit: "abc123",
            fixtureDigest: "builtin-control-v1"
        )

        #expect(
            PerformanceLaunchArguments.make(for: request)
                .contains("--perf-disable-peer-serving")
        )
    }

    @Test
    func peerOnVariantAddsTheExplicitServingOverride() {
        let request = PerformanceScenarioRequest(
            scenarioID: "control.idle",
            runID: "AAAAAAAA-7777-7777-7777-777777777777",
            durationSeconds: 60,
            sampleIntervalSeconds: 5,
            settleSeconds: 0,
            variant: "tethered-peer-on",
            gitCommit: "abc123",
            fixtureDigest: "builtin-control-v1"
        )

        #expect(
            PerformanceLaunchArguments.make(for: request)
                .contains("--perf-enable-peer-serving")
        )
    }
}
