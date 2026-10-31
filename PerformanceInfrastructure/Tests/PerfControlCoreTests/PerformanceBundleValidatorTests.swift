import Foundation
import Testing
@testable import PerfControlCore

struct PerformanceBundleValidatorTests {
    @Test
    func completedBundleIsAcceptedThroughTheArtifactBoundary() throws {
        let directory = try fixtureDirectory(
            resultStatus: "passed",
            events: [
                event(sequence: 0, kind: "scenarioStarted"),
                event(sequence: 1, kind: "phaseStarted", phase: "work"),
                event(sequence: 2, kind: "phaseFinished", phase: "work"),
                event(sequence: 3, kind: "scenarioFinished"),
            ])

        let summary = try PerformanceBundleValidator.validate(directory: directory)

        #expect(summary.runID == "11111111-1111-1111-1111-111111111111")
        #expect(summary.scenarioID == "control.idle")
        #expect(summary.status == .passed)
        #expect(summary.eventCount == 4)
    }

    @Test
    func passedResultWithoutFinishedEventIsRejected() throws {
        let directory = try fixtureDirectory(
            resultStatus: "passed",
            events: [event(sequence: 0, kind: "scenarioStarted")])

        #expect(throws: PerformanceBundleValidationError.self) {
            try PerformanceBundleValidator.validate(directory: directory)
        }
    }

    @Test
    func nonContiguousEventSequenceIsRejected() throws {
        let directory = try fixtureDirectory(
            resultStatus: "passed",
            events: [
                event(sequence: 0, kind: "scenarioStarted"),
                event(sequence: 2, kind: "scenarioFinished"),
            ])

        #expect(throws: PerformanceBundleValidationError.self) {
            try PerformanceBundleValidator.validate(directory: directory)
        }
    }

    private func fixtureDirectory(
        resultStatus: String,
        events: [String]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 1,
          "runID": "11111111-1111-1111-1111-111111111111",
          "scenarioID": "control.idle",
          "variant": "baseline",
          "fixtureDigest": "builtin-control-v1",
          "startedAt": "2026-07-19T12:00:00Z",
          "monotonicStartNanoseconds": 1000,
          "appVersion": "1.0",
          "appBuild": "4",
          "gitCommit": "abc123",
          "configuration": "Release+PERFORMANCE_TESTING",
          "device": {
            "platform": "iOS",
            "model": "iPhone16,2",
            "osVersion": "26.5.2",
            "osBuild": "23F84"
          },
          "initialConditions": {
            "thermalState": "nominal",
            "lowPowerMode": false,
            "batteryLevel": 0.75,
            "batteryState": "unplugged",
            "network": "offline",
            "audioRoute": "none"
          }
        }
        """
        let result = """
        {
          "schemaVersion": 1,
          "runID": "11111111-1111-1111-1111-111111111111",
          "scenarioID": "control.idle",
          "status": "\(resultStatus)",
          "finishedAt": "2026-07-19T12:01:00Z",
          "durationMilliseconds": 60000,
          "finalConditions": {
            "thermalState": "nominal",
            "lowPowerMode": false,
            "batteryLevel": 0.74,
            "batteryState": "unplugged",
            "network": "offline",
            "audioRoute": "none"
          },
          "invalidReasons": [],
          "measurements": {"cpuSeconds": 1.25}
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data(result.utf8).write(to: root.appendingPathComponent("result.json"))
        try Data((events.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("events.ndjson"))
        return root
    }

    private func event(sequence: Int, kind: String, phase: String? = nil) -> String {
        let phaseJSON = phase.map { ",\"phase\":\"\($0)\"" } ?? ""
        return """
        {"schemaVersion":1,"runID":"11111111-1111-1111-1111-111111111111","scenarioID":"control.idle","sequence":\(sequence),"kind":"\(kind)"\(phaseJSON),"wallTime":"2026-07-19T12:00:00Z","monotonicNanoseconds":\(1000 + sequence)}
        """
    }
}
