import Foundation
import PerformanceContracts

public enum PerformanceLaunchArguments {
    public static func make(for request: PerformanceScenarioRequest) -> [String] {
        var arguments = [
            "--perf-scenario", request.scenarioID,
            "--perf-run-id", request.runID,
            "--perf-duration-seconds", String(request.durationSeconds),
            "--perf-sample-interval-seconds", String(request.sampleIntervalSeconds),
            "--perf-settle-seconds", String(request.settleSeconds),
            "--perf-variant", request.variant,
            "--perf-git-commit", request.gitCommit,
            "--perf-fixture-digest", request.fixtureDigest,
        ]
        if request.variant.contains("peer-off") {
            arguments.append("--perf-disable-peer-serving")
        }
        if request.variant.contains("peer-on") {
            arguments.append("--perf-enable-peer-serving")
        }
        return arguments
    }
}
