import XCTest

/// A paused workout (`WorkoutPauses`): the clock that stops, what is saved, and what a trim keeps.
final class WorkoutPausesTests: XCTestCase {
    private func pause(_ start: TimeInterval, _ end: TimeInterval) -> FitnessPause { FitnessPause(start: start, end: end) }

    func testTheClockStopsWhileItIsPaused() {
        // Ten minutes in, a call: paused at 600 s.
        XCTAssertEqual(WorkoutPauses.activeElapsed(wall: 600, pauses: [], openSince: 600), 600)
        XCTAssertEqual(WorkoutPauses.activeElapsed(wall: 900, pauses: [], openSince: 600), 600, "five minutes later, still ten")
    }

    func testTheClockPicksUpWhereItStopped() {
        // Resumed at 900 s: a minute later the workout is eleven minutes long, not sixteen.
        XCTAssertEqual(WorkoutPauses.activeElapsed(wall: 960, pauses: [pause(600, 900)], openSince: nil), 660)
        // And a second pause freezes it again.
        XCTAssertEqual(WorkoutPauses.activeElapsed(wall: 2000, pauses: [pause(600, 900)], openSince: 1200), 900)
    }

    func testAWorkoutEndedWhilePausedLeavesThePauseOut() {
        let saved = WorkoutPauses.closed([pause(600, 900)], openSince: 1500, at: 1800)
        XCTAssertEqual(saved, [pause(600, 900), pause(1500, 1800)])
        XCTAssertEqual(WorkoutPauses.pausedSeconds(saved), 600)
    }

    func testSavedPausesAreInOrderInsideTheWorkoutAndJoined() {
        let saved = WorkoutPauses.closed([pause(900, 1000), pause(100, 200), pause(150, 300), pause(400, 400.2), pause(1700, 5000)],
                                         openSince: nil, at: 1800)
        XCTAssertEqual(saved, [pause(100, 300), pause(900, 1000), pause(1700, 1800)],
                       "overlapping ones are one pause, a blink isn't one, and none runs past the end")
    }

    func testATrimKeepsWhatIsLeftOfAPause() {
        let pauses = [pause(100, 200), pause(600, 900), pause(1700, 1800)]
        // Keep 150…1000: the first pause is cut to its last 50 s, the second is whole, the third is gone.
        XCTAssertEqual(WorkoutPauses.kept(pauses, startOffset: 150, endOffset: 1000), [pause(0, 50), pause(450, 750)])
        XCTAssertEqual(WorkoutPauses.kept(pauses, startOffset: 0, endOffset: 1800), pauses)
        XCTAssertEqual(WorkoutPauses.kept(pauses, startOffset: 300, endOffset: 500), [])
    }

    func testTheWatchSendsPausesAsAPlainList() {
        let pauses = [pause(600, 900), pause(1500, 1800)]
        XCTAssertEqual(WorkoutPauses.flat(pauses), [600, 900, 1500, 1800])
        XCTAssertEqual(WorkoutPauses.fromFlat([600, 900, 1500, 1800]), pauses)
        XCTAssertEqual(WorkoutPauses.fromFlat([600, 900, 1500]), [pause(600, 900)], "a start without its end is dropped")
        XCTAssertEqual(WorkoutPauses.fromFlat([]), [])
    }

    func testAWorkoutsTimeLeavesItsPausesOut() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let session = FitnessSession(id: UUID(), start: start, end: start.addingTimeInterval(3600), activity: "Strength",
                                     avgHeartRate: nil, totalEnergy: nil, totalDistance: nil,
                                     pauses: [pause(600, 900)], samples: [])
        let summary = FitnessSessionSummary(session: session)
        XCTAssertEqual(summary.duration, 3600, "by the clock, start to end")
        XCTAssertEqual(summary.activeDuration, 3300, "what's shown as its time")
        // And it survives the summary's own coding, and reading one saved before pauses existed.
        let decoded = try JSONDecoder().decode(FitnessSessionSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.pauses, [pause(600, 900)])
        let old = FitnessSessionSummary(session: FitnessSession(id: UUID(), start: start, end: start.addingTimeInterval(60),
                                                                activity: "Run", avgHeartRate: nil, totalEnergy: nil,
                                                                totalDistance: nil, samples: []))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["pauses"] = nil
        let read = try JSONDecoder().decode(FitnessSessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(read.pauses, [])
        XCTAssertEqual(read.activeDuration, read.duration)
    }
}
