import Foundation
import PerformanceContracts

public enum PerformanceBundleValidationError: Error, CustomStringConvertible {
    case missingFile(String)
    case unreadableFile(String, String)
    case unsupportedSchema(Int)
    case identityMismatch(String)
    case emptyEvents
    case sequence(expected: Int, actual: Int)
    case invalidLifecycle(String)

    public var description: String {
        switch self {
        case .missingFile(let name):
            return "missing required artifact \(name)"
        case .unreadableFile(let name, let reason):
            return "could not decode \(name): \(reason)"
        case .unsupportedSchema(let version):
            return "unsupported performance schema \(version)"
        case .identityMismatch(let detail):
            return "artifact identity mismatch: \(detail)"
        case .emptyEvents:
            return "events.ndjson contains no events"
        case .sequence(let expected, let actual):
            return "event sequence is not contiguous: expected \(expected), found \(actual)"
        case .invalidLifecycle(let detail):
            return "invalid scenario lifecycle: \(detail)"
        }
    }
}

public enum PerformanceBundleValidator {
    public static func validate(directory: URL) throws -> PerformanceRunSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest: PerformanceRunManifest = try decode(
            PerformanceRunManifest.self,
            name: "manifest.json",
            directory: directory,
            decoder: decoder)
        let result: PerformanceRunResult = try decode(
            PerformanceRunResult.self,
            name: "result.json",
            directory: directory,
            decoder: decoder)
        let events = try decodeEvents(directory: directory, decoder: decoder)

        guard manifest.schemaVersion == PerformanceRunManifest.currentSchemaVersion else {
            throw PerformanceBundleValidationError.unsupportedSchema(manifest.schemaVersion)
        }
        guard result.schemaVersion == manifest.schemaVersion else {
            throw PerformanceBundleValidationError.identityMismatch("result schema")
        }
        guard result.runID == manifest.runID, result.scenarioID == manifest.scenarioID else {
            throw PerformanceBundleValidationError.identityMismatch("result run or scenario")
        }
        for (expected, event) in events.enumerated() {
            guard event.sequence == expected else {
                throw PerformanceBundleValidationError.sequence(
                    expected: expected,
                    actual: event.sequence)
            }
            guard event.schemaVersion == manifest.schemaVersion,
                  event.runID == manifest.runID,
                  event.scenarioID == manifest.scenarioID else {
                throw PerformanceBundleValidationError.identityMismatch(
                    "event \(event.sequence)")
            }
        }
        guard events.first?.kind == .scenarioStarted else {
            throw PerformanceBundleValidationError.invalidLifecycle(
                "first event must be scenarioStarted")
        }
        let expectedTerminal: PerformanceEventKind
        switch result.status {
        case .passed: expectedTerminal = .scenarioFinished
        case .failed: expectedTerminal = .scenarioFailed
        case .invalid: expectedTerminal = .scenarioInvalidated
        }
        guard events.last?.kind == expectedTerminal else {
            throw PerformanceBundleValidationError.invalidLifecycle(
                "\(result.status.rawValue) result requires \(expectedTerminal.rawValue)")
        }

        return PerformanceRunSummary(
            runID: manifest.runID,
            scenarioID: manifest.scenarioID,
            variant: manifest.variant,
            status: result.status,
            eventCount: events.count,
            durationMilliseconds: result.durationMilliseconds,
            measurements: result.measurements)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        name: String,
        directory: URL,
        decoder: JSONDecoder
    ) throws -> Value {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PerformanceBundleValidationError.missingFile(name)
        }
        do {
            return try decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw PerformanceBundleValidationError.unreadableFile(
                name,
                error.localizedDescription)
        }
    }

    private static func decodeEvents(
        directory: URL,
        decoder: JSONDecoder
    ) throws -> [PerformanceEvent] {
        let name = "events.ndjson"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PerformanceBundleValidationError.missingFile(name)
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PerformanceBundleValidationError.unreadableFile(
                name,
                error.localizedDescription)
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            throw PerformanceBundleValidationError.emptyEvents
        }
        return try lines.enumerated().map { index, line in
            do {
                return try decoder.decode(PerformanceEvent.self, from: Data(line.utf8))
            } catch {
                throw PerformanceBundleValidationError.unreadableFile(
                    "\(name) line \(index + 1)",
                    error.localizedDescription)
            }
        }
    }
}
