import XCTest

final class WorkoutRecoveryTests: XCTestCase {
    func testRecoveryKeepsIdentityAndDoesNotMatchAnotherSession() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let value = WorkoutRecoveryCheckpoint(sessionID: UUID(), start: start, activityType: 20,
            name: "Weights", indoor: true, paceWindowMeters: 400, splitDistanceMeters: nil)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutRecoveryCheckpoint.self,
            from: JSONEncoder().encode(value)), value)
        XCTAssertTrue(value.matches(start: start, activityType: 20))
        XCTAssertFalse(value.matches(start: start.addingTimeInterval(10), activityType: 20))
        XCTAssertFalse(value.matches(start: start, activityType: 1))
    }

    func testCheckpointSurvivesRelaunchAndOnlyItsOwnFinishRemovesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkoutRecoveryStore(directory: dir)
        let value = WorkoutRecoveryCheckpoint(sessionID: UUID(), start: Date(), activityType: 20,
            name: "Weights", indoor: true, paceWindowMeters: 400, splitDistanceMeters: nil)
        try store.save(value)
        let reopened = WorkoutRecoveryStore(directory: dir)
        XCTAssertEqual(try reopened.load(), value)
        XCTAssertTrue(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try reopened.remove(sessionID: UUID())
        XCTAssertEqual(try reopened.load(), value)
        var next = value
        next.sessionID = UUID()
        try reopened.save(next)
        XCTAssertEqual(try reopened.load(), next)
        let archived = dir.appendingPathComponent(value.sessionID.uuidString + ".interrupted.json")
        XCTAssertEqual(try JSONDecoder().decode(WorkoutRecoveryCheckpoint.self, from: Data(contentsOf: archived)), value)
        try reopened.remove(sessionID: next.sessionID)
        XCTAssertNil(try reopened.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
    }

    func testResumingSamplesAppendsWithoutTruncatingEarlierWorkout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID(), start = Date().addingTimeInterval(-60)
        let first = try XCTUnwrap(SampleWriter(sessionID: id, start: start, directory: dir))
        first.append(.heartRate, v1: 101)
        first.close()
        let before = try Data(contentsOf: first.url)
        // A crash can leave an incomplete final record. It must not erase earlier complete ones.
        let file = try FileHandle(forWritingTo: first.url)
        try file.seekToEnd()
        try file.write(contentsOf: Data([1, 2]))
        try file.close()
        let recovered = try XCTUnwrap(SampleWriter(sessionID: id, start: start, resuming: true, directory: dir))
        XCTAssertEqual(recovered.count, 1)
        recovered.append(.heartRate, v1: 122)
        recovered.close()
        let after = try Data(contentsOf: recovered.url)
        XCTAssertEqual(after.prefix(before.count), before)
        XCTAssertEqual(after.count, 2 * FitnessSample.recordSize)
        XCTAssertEqual(recovered.count, 2)
        XCTAssertNil(SampleWriter(sessionID: UUID(), start: start, resuming: true, directory: dir))
    }
}
