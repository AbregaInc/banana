import Foundation
import PerformanceContracts
import Testing

struct PerformanceScenarioRequestTests {
    @Test
    func launchArgumentsProduceACompleteDeterministicRequest() throws {
        let parsed = try PerformanceScenarioRequest.parse(arguments: [
            "/Applications/Banana.app/Banana",
            "--perf-scenario", "playback.local",
            "--perf-run-id", "33333333-3333-3333-3333-333333333333",
            "--perf-duration-seconds", "28800",
            "--perf-sample-interval-seconds", "60",
            "--perf-settle-seconds", "45",
            "--perf-variant", "baseline",
            "--perf-git-commit", "abc123",
            "--perf-fixture-digest", "sha256:fixture",
        ])
        let request = try #require(parsed)

        #expect(request.scenarioID == "playback.local")
        #expect(request.runID == "33333333-3333-3333-3333-333333333333")
        #expect(request.durationSeconds == 28_800)
        #expect(request.sampleIntervalSeconds == 60)
        #expect(request.settleSeconds == 45)
        #expect(request.variant == "baseline")
        #expect(request.gitCommit == "abc123")
        #expect(request.fixtureDigest == "sha256:fixture")
    }

    @Test
    func normalLaunchDoesNotCreateAPerformanceRequest() throws {
        #expect(try PerformanceScenarioRequest.parse(arguments: ["/Applications/Banana.app/Banana"]) == nil)
    }

    @Test
    func unsupportedScenarioIsRejectedBeforeTheAppMutatesState() {
        #expect(throws: PerformanceScenarioRequestError.self) {
            try PerformanceScenarioRequest.parse(arguments: [
                "Banana",
                "--perf-scenario", "made.up",
                "--perf-run-id", UUID().uuidString,
            ])
        }
    }

    @Test
    func plannerRefreshIsSilentAndSelfDescribingByDefault() throws {
        let parsed = try PerformanceScenarioRequest.parse(arguments: [
            "Banana",
            "--perf-scenario", "planner.refresh",
            "--perf-run-id", "55555555-5555-5555-5555-555555555555",
        ])
        let request = try #require(parsed)

        #expect(request.durationSeconds == 300)
        #expect(request.fixtureDigest == "builtin-planner-refresh-v1")
        #expect(PerformanceScenarioRequest.supportedScenarioIDs.contains("planner.refresh"))
    }

    @Test
    func tetheredVariantIsExplicitlyRecognized() throws {
        let parsed = try PerformanceScenarioRequest.parse(arguments: [
            "Banana",
            "--perf-scenario", "planner.refresh",
            "--perf-run-id", "66666666-6666-6666-6666-666666666666",
            "--perf-variant", "tethered-baseline",
        ])
        let request = try #require(parsed)

        #expect(request.isTetheredMeasurement)
    }

    @Test
    func densePlannerFixtureIsVersionedAndSupported() throws {
        let parsed = try PerformanceScenarioRequest.parse(arguments: [
            "Banana",
            "--perf-scenario", "planner.dense",
            "--perf-run-id", "88888888-8888-8888-8888-888888888888",
        ])
        let request = try #require(parsed)

        #expect(request.fixtureDigest == "builtin-planner-dense-v1")
        #expect(PerformanceScenarioRequest.supportedScenarioIDs.contains("planner.dense"))
    }

    @Test
    func artworkDecodeFixtureIsVersionedAndSupported() throws {
        let parsed = try PerformanceScenarioRequest.parse(arguments: [
            "Banana",
            "--perf-scenario", "artwork.decode",
            "--perf-run-id", "99999999-9999-9999-9999-999999999999",
        ])
        let request = try #require(parsed)

        #expect(request.fixtureDigest == "builtin-artwork-decode-v1")
        #expect(PerformanceScenarioRequest.supportedScenarioIDs.contains("artwork.decode"))
    }
}
