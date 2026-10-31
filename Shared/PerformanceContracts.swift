import Foundation

public enum PerformanceScenarioRequestError: Error, Equatable, Sendable {
    case missingValue(String)
    case invalidValue(flag: String, value: String)
    case unsupportedScenario(String)
}

public struct PerformanceScenarioRequest: Codable, Equatable, Sendable {
    public static let supportedScenarioIDs = [
        "artwork.decode",
        "control.idle",
        "planner.dense",
        "planner.refresh",
        "playback.local",
    ]

    public static func builtinFixtureDigest(for scenarioID: String) -> String? {
        switch scenarioID {
        case "artwork.decode": return "builtin-artwork-decode-v1"
        case "control.idle": return "builtin-control-v1"
        case "planner.dense": return "builtin-planner-dense-v1"
        case "planner.refresh": return "builtin-planner-refresh-v1"
        default: return nil
        }
    }

    public var scenarioID: String
    public var runID: String
    public var durationSeconds: Double
    public var sampleIntervalSeconds: Double
    public var settleSeconds: Double
    public var variant: String
    public var gitCommit: String
    public var fixtureDigest: String

    /// Tethered runs intentionally keep the device connected to power and networking. They are
    /// useful for unattended CPU/wakeup/memory comparisons, but not battery-drain measurements.
    public var isTetheredMeasurement: Bool {
        variant == "tethered" || variant.hasPrefix("tethered-")
    }

    public init(
        scenarioID: String,
        runID: String,
        durationSeconds: Double,
        sampleIntervalSeconds: Double,
        settleSeconds: Double,
        variant: String,
        gitCommit: String,
        fixtureDigest: String
    ) {
        self.scenarioID = scenarioID
        self.runID = runID
        self.durationSeconds = durationSeconds
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.settleSeconds = settleSeconds
        self.variant = variant
        self.gitCommit = gitCommit
        self.fixtureDigest = fixtureDigest
    }

    public static func parse(arguments: [String]) throws -> PerformanceScenarioRequest? {
        guard arguments.contains("--perf-scenario") else { return nil }

        func value(after flag: String) throws -> String {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--")
            else {
                throw PerformanceScenarioRequestError.missingValue(flag)
            }
            return arguments[index + 1]
        }

        let scenarioID = try value(after: "--perf-scenario")
        guard supportedScenarioIDs.contains(scenarioID) else {
            throw PerformanceScenarioRequestError.unsupportedScenario(scenarioID)
        }
        let runID = try value(after: "--perf-run-id")
        guard UUID(uuidString: runID) != nil else {
            throw PerformanceScenarioRequestError.invalidValue(
                flag: "--perf-run-id",
                value: runID)
        }

        func positiveDouble(after flag: String, default defaultValue: Double) throws -> Double {
            guard arguments.contains(flag) else { return defaultValue }
            let raw = try value(after: flag)
            guard let parsed = Double(raw), parsed.isFinite, parsed > 0 else {
                throw PerformanceScenarioRequestError.invalidValue(flag: flag, value: raw)
            }
            return parsed
        }

        let defaultDuration = scenarioID == "playback.local" ? 3_600.0 : 300.0
        let duration = try positiveDouble(
            after: "--perf-duration-seconds",
            default: defaultDuration)
        let sampleInterval = try positiveDouble(
            after: "--perf-sample-interval-seconds",
            default: 60)
        let settleSeconds: Double
        if arguments.contains("--perf-settle-seconds") {
            let raw = try value(after: "--perf-settle-seconds")
            guard let parsed = Double(raw), parsed.isFinite, parsed >= 0 else {
                throw PerformanceScenarioRequestError.invalidValue(
                    flag: "--perf-settle-seconds",
                    value: raw)
            }
            settleSeconds = parsed
        } else {
            settleSeconds = 0
        }
        let variant = arguments.contains("--perf-variant")
            ? try value(after: "--perf-variant")
            : "baseline"
        let gitCommit = arguments.contains("--perf-git-commit")
            ? try value(after: "--perf-git-commit")
            : "unknown"
        let fixtureDigest = arguments.contains("--perf-fixture-digest")
            ? try value(after: "--perf-fixture-digest")
            : (builtinFixtureDigest(for: scenarioID) ?? "unverified")

        return PerformanceScenarioRequest(
            scenarioID: scenarioID,
            runID: runID,
            durationSeconds: duration,
            sampleIntervalSeconds: sampleInterval,
            settleSeconds: settleSeconds,
            variant: variant,
            gitCommit: gitCommit,
            fixtureDigest: fixtureDigest)
    }
}

public struct PerformanceDevice: Codable, Equatable, Sendable {
    public var platform: String
    public var model: String
    public var osVersion: String
    public var osBuild: String

    public init(platform: String, model: String, osVersion: String, osBuild: String) {
        self.platform = platform
        self.model = model
        self.osVersion = osVersion
        self.osBuild = osBuild
    }
}

public struct PerformanceConditions: Codable, Equatable, Sendable {
    public var thermalState: String
    public var lowPowerMode: Bool
    public var batteryLevel: Double?
    public var batteryState: String
    public var network: String
    public var audioRoute: String

    public init(
        thermalState: String,
        lowPowerMode: Bool,
        batteryLevel: Double?,
        batteryState: String,
        network: String,
        audioRoute: String
    ) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.network = network
        self.audioRoute = audioRoute
    }
}

public struct PerformanceRunManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var scenarioID: String
    public var variant: String
    public var fixtureDigest: String
    public var startedAt: Date
    public var monotonicStartNanoseconds: UInt64
    public var appVersion: String
    public var appBuild: String
    public var gitCommit: String
    public var configuration: String
    public var device: PerformanceDevice
    public var initialConditions: PerformanceConditions

    public init(
        schemaVersion: Int = currentSchemaVersion,
        runID: String,
        scenarioID: String,
        variant: String,
        fixtureDigest: String,
        startedAt: Date,
        monotonicStartNanoseconds: UInt64,
        appVersion: String,
        appBuild: String,
        gitCommit: String,
        configuration: String,
        device: PerformanceDevice,
        initialConditions: PerformanceConditions
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.scenarioID = scenarioID
        self.variant = variant
        self.fixtureDigest = fixtureDigest
        self.startedAt = startedAt
        self.monotonicStartNanoseconds = monotonicStartNanoseconds
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.gitCommit = gitCommit
        self.configuration = configuration
        self.device = device
        self.initialConditions = initialConditions
    }
}

public enum PerformanceEventKind: String, Codable, Sendable {
    case scenarioStarted
    case phaseStarted
    case phaseFinished
    case sample
    case scenarioFinished
    case scenarioInvalidated
    case scenarioFailed
}

public struct PerformanceEvent: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var scenarioID: String
    public var sequence: Int
    public var kind: PerformanceEventKind
    public var phase: String?
    public var wallTime: Date
    public var monotonicNanoseconds: UInt64
    public var values: [String: Double]?
    public var detail: String?

    public init(
        schemaVersion: Int = PerformanceRunManifest.currentSchemaVersion,
        runID: String,
        scenarioID: String,
        sequence: Int,
        kind: PerformanceEventKind,
        phase: String? = nil,
        wallTime: Date,
        monotonicNanoseconds: UInt64,
        values: [String: Double]? = nil,
        detail: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.scenarioID = scenarioID
        self.sequence = sequence
        self.kind = kind
        self.phase = phase
        self.wallTime = wallTime
        self.monotonicNanoseconds = monotonicNanoseconds
        self.values = values
        self.detail = detail
    }
}

public enum PerformanceRunStatus: String, Codable, Sendable {
    case passed
    case failed
    case invalid
}

public struct PerformanceRunResult: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var scenarioID: String
    public var status: PerformanceRunStatus
    public var finishedAt: Date
    public var durationMilliseconds: Double
    public var finalConditions: PerformanceConditions
    public var invalidReasons: [String]
    public var measurements: [String: Double]

    public init(
        schemaVersion: Int = PerformanceRunManifest.currentSchemaVersion,
        runID: String,
        scenarioID: String,
        status: PerformanceRunStatus,
        finishedAt: Date,
        durationMilliseconds: Double,
        finalConditions: PerformanceConditions,
        invalidReasons: [String],
        measurements: [String: Double]
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.scenarioID = scenarioID
        self.status = status
        self.finishedAt = finishedAt
        self.durationMilliseconds = durationMilliseconds
        self.finalConditions = finalConditions
        self.invalidReasons = invalidReasons
        self.measurements = measurements
    }
}

public struct PerformanceRunSummary: Codable, Equatable, Sendable {
    public var runID: String
    public var scenarioID: String
    public var variant: String
    public var status: PerformanceRunStatus
    public var eventCount: Int
    public var durationMilliseconds: Double
    public var measurements: [String: Double]

    public init(
        runID: String,
        scenarioID: String,
        variant: String,
        status: PerformanceRunStatus,
        eventCount: Int,
        durationMilliseconds: Double,
        measurements: [String: Double]
    ) {
        self.runID = runID
        self.scenarioID = scenarioID
        self.variant = variant
        self.status = status
        self.eventCount = eventCount
        self.durationMilliseconds = durationMilliseconds
        self.measurements = measurements
    }
}
