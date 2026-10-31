import XCTest

final class WorkoutRoutineCompletionTests: XCTestCase {
    func testStartCompletesOnlySpecifiedRoutineForItsOwnDayAndKeepsBookedTime() throws {
        let start = Date(timeIntervalSince1970: 1_792_598_400)
        let routineID = UUID(), day = "2026-10-21"
        let key = "\(routineID.uuidString)|main|\(day)"
        let booked = start.addingTimeInterval(-3600)
        let updates = WorkoutRoutineCompletion.updates(startedAt: start, day: day, routineIDs: [routineID], overrides: [key: .reschedule(booked)])
        XCTAssertEqual(updates, [key: .completed(at: start, scheduledStart: booked)])
        XCTAssertTrue(WorkoutRoutineCompletion.updates(startedAt: start, day: day, routineIDs: [routineID], overrides: updates).isEmpty, "queued duplicate must not rewrite completion")
        let tomorrow = WorkoutRoutineCompletion.updates(startedAt: start.addingTimeInterval(86400), day: "2026-10-22", routineIDs: [routineID], overrides: updates)
        XCTAssertEqual(tomorrow.count, 1); XCTAssertNil(tomorrow[key])
        let canonical = try CanonicalJSON.value(of: updates)
        XCTAssertEqual(try CanonicalJSON.decode([String: RoutineOccurrenceOverride].self, from: canonical), updates, "the actual sync codec must preserve completion dates")
        let bytes = try JSONEncoder().encode(updates)
        XCTAssertEqual(try JSONDecoder().decode([String: RoutineOccurrenceOverride].self, from: bytes), updates, "completion survives persistence and sync")
    }

    func testManualCompletionRestoresMovedTimeWhenUnmarkedAndSurvivesSync() throws {
        let now = Date(timeIntervalSince1970: 1_792_598_400)
        let moved = now.addingTimeInterval(-86400)
        let completed = RoutineOccurrenceOverride.settingCompleted(true, at: now, previous: .reschedule(moved))
        XCTAssertEqual(completed, .completed(at: now, scheduledStart: moved))
        let encoded = try CanonicalJSON.value(of: completed)
        XCTAssertEqual(try CanonicalJSON.decode(RoutineOccurrenceOverride?.self, from: encoded), completed)
        XCTAssertEqual(RoutineOccurrenceOverride.settingCompleted(false, at: now, previous: completed), .reschedule(moved))
        XCTAssertNil(RoutineOccurrenceOverride.settingCompleted(false, at: now, previous: .completed(at: now, scheduledStart: nil)))
        XCTAssertEqual(try JSONDecoder().decode(RoutineOccurrenceOverride.self, from: Data(#"{"skip":{}}"#.utf8)), .skip)
    }

    func testRestCountdownUsesWallClockAndStopsAtZero() {
        let end = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(WorkoutRestTimer.remaining(until: end, now: end.addingTimeInterval(-30)), 30)
        XCTAssertEqual(WorkoutRestTimer.remaining(until: end, now: end.addingTimeInterval(-0.2)), 1)
        XCTAssertEqual(WorkoutRestTimer.remaining(until: end, now: end.addingTimeInterval(5)), 0)
        XCTAssertEqual(WorkoutRestTimer.remaining(until: nil), 0)
    }
}
