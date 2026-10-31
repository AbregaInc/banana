import Foundation

public enum PerformanceRunRecorderError: Error {
    case runDirectoryAlreadyExists
    case alreadyFinished
}

public final class PerformanceRunRecorder: @unchecked Sendable {
    public let directory: URL
    public let manifest: PerformanceRunManifest

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private var nextSequence = 0
    private var finished = false

    public init(directory: URL, manifest: PerformanceRunManifest) throws {
        self.directory = directory
        self.manifest = manifest
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw PerformanceRunRecorderError.runDirectoryAlreadyExists
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic)
        try Data().write(to: directory.appendingPathComponent("events.ndjson"))
    }

    public func emit(
        _ kind: PerformanceEventKind,
        phase: String? = nil,
        values: [String: Double]? = nil,
        detail: String? = nil,
        wallTime: Date,
        monotonicNanoseconds: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            throw PerformanceRunRecorderError.alreadyFinished
        }
        try append(
            PerformanceEvent(
                runID: manifest.runID,
                scenarioID: manifest.scenarioID,
                sequence: nextSequence,
                kind: kind,
                phase: phase,
                wallTime: wallTime,
                monotonicNanoseconds: monotonicNanoseconds,
                values: values,
                detail: detail))
        nextSequence += 1
    }

    public func finish(
        status: PerformanceRunStatus,
        finalConditions: PerformanceConditions,
        invalidReasons: [String],
        measurements: [String: Double],
        wallTime: Date,
        monotonicNanoseconds: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            throw PerformanceRunRecorderError.alreadyFinished
        }
        let terminal: PerformanceEventKind
        switch status {
        case .passed: terminal = .scenarioFinished
        case .failed: terminal = .scenarioFailed
        case .invalid: terminal = .scenarioInvalidated
        }
        try append(
            PerformanceEvent(
                runID: manifest.runID,
                scenarioID: manifest.scenarioID,
                sequence: nextSequence,
                kind: terminal,
                wallTime: wallTime,
                monotonicNanoseconds: monotonicNanoseconds,
                detail: invalidReasons.isEmpty ? nil : invalidReasons.joined(separator: "; ")))
        nextSequence += 1
        let elapsed = monotonicNanoseconds >= manifest.monotonicStartNanoseconds
            ? monotonicNanoseconds - manifest.monotonicStartNanoseconds
            : 0
        let result = PerformanceRunResult(
            runID: manifest.runID,
            scenarioID: manifest.scenarioID,
            status: status,
            finishedAt: wallTime,
            durationMilliseconds: Double(elapsed) / 1_000_000,
            finalConditions: finalConditions,
            invalidReasons: invalidReasons,
            measurements: measurements)
        try encoder.encode(result).write(
            to: directory.appendingPathComponent("result.json"),
            options: .atomic)
        finished = true
    }

    private func append(_ event: PerformanceEvent) throws {
        var line = try encoder.encode(event)
        line.append(0x0A)
        let url = directory.appendingPathComponent("events.ndjson")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
