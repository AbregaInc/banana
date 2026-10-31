import Foundation

/// The app-owned identity/configuration HealthKit cannot restore for us. HealthKit owns the
/// live session, statistics and pause events; the raw sample file keeps its original time origin.
struct WorkoutRecoveryCheckpoint: Codable, Equatable, Sendable {
    var sessionID: UUID
    var start: Date
    var activityType: UInt
    var name: String
    var indoor: Bool
    var paceWindowMeters: Double
    var splitDistanceMeters: Double?
    var splits: [Split] = []
    var splitSampleElapsed: TimeInterval = 0
    var splitSampleDistance: Double = 0

    struct Split: Codable, Equatable, Sendable {
        var number: Int
        var duration: TimeInterval
        var elapsed: TimeInterval
    }

    func matches(start: Date, activityType: UInt) -> Bool {
        self.activityType == activityType && abs(self.start.timeIntervalSince(start)) < 1
    }
}

/// One small atomic file, excluded from device backup before bytes are written. A failed or
/// mismatched recovery preserves the checkpoint and samples for diagnosis, never truncates them.
struct WorkoutRecoveryStore {
    let directory: URL
    var url: URL { directory.appendingPathComponent("active-workout.json") }

    func load() throws -> WorkoutRecoveryCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(WorkoutRecoveryCheckpoint.self, from: Data(contentsOf: url))
    }

    func save(_ value: WorkoutRecoveryCheckpoint) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try HealthFileProtection.exclude(directory)
        // Preserve a previous interrupted workout's identity before another workout starts.
        if let previous = try load(), previous.sessionID != value.sessionID {
            let archived = directory.appendingPathComponent(previous.sessionID.uuidString + ".interrupted.json")
            try HealthFileProtection.write(try JSONEncoder().encode(previous), to: archived)
        }
        try HealthFileProtection.write(try JSONEncoder().encode(value), to: url)
    }

    func remove(sessionID: UUID) throws {
        guard try load()?.sessionID == sessionID else { return }
        try FileManager.default.removeItem(at: url)
    }
}
