import Foundation
import Testing
import PerformanceContracts
@testable import PerfControlCore

struct PerformanceRunRecorderTests {
    @Test
    func recorderProducesAValidBundleAtThePublicArtifactBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-recorder-\(UUID().uuidString)", isDirectory: true)
        let conditions = PerformanceConditions(
            thermalState: "nominal",
            lowPowerMode: false,
            batteryLevel: 0.8,
            batteryState: "unplugged",
            network: "offline",
            audioRoute: "none")
        let manifest = PerformanceRunManifest(
            runID: "22222222-2222-2222-2222-222222222222",
            scenarioID: "control.idle",
            variant: "baseline",
            fixtureDigest: "builtin-control-v1",
            startedAt: Date(timeIntervalSince1970: 1_753_000_000),
            monotonicStartNanoseconds: 10_000,
            appVersion: "1.0",
            appBuild: "4",
            gitCommit: "def456",
            configuration: "Release+PERFORMANCE_TESTING",
            device: PerformanceDevice(
                platform: "iOS",
                model: "iPhone16,2",
                osVersion: "26.5.2",
                osBuild: "23F84"),
            initialConditions: conditions)
        let recorder = try PerformanceRunRecorder(directory: directory, manifest: manifest)

        try recorder.emit(
            .scenarioStarted,
            wallTime: Date(timeIntervalSince1970: 1_753_000_000),
            monotonicNanoseconds: 10_000)
        try recorder.emit(
            .phaseStarted,
            phase: "idle",
            wallTime: Date(timeIntervalSince1970: 1_753_000_001),
            monotonicNanoseconds: 20_000)
        try recorder.emit(
            .phaseFinished,
            phase: "idle",
            wallTime: Date(timeIntervalSince1970: 1_753_000_002),
            monotonicNanoseconds: 30_000)
        try recorder.finish(
            status: .passed,
            finalConditions: conditions,
            invalidReasons: [],
            measurements: ["cpuSeconds": 0.25],
            wallTime: Date(timeIntervalSince1970: 1_753_000_002),
            monotonicNanoseconds: 40_000)

        let summary = try PerformanceBundleValidator.validate(directory: directory)
        #expect(summary.status == .passed)
        #expect(summary.eventCount == 4)
        #expect(summary.durationMilliseconds == 0.03)
        #expect(summary.measurements["cpuSeconds"] == 0.25)
    }
}
