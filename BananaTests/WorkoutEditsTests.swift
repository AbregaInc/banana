import XCTest

/// A trimmed workout across devices (`WorkoutEdits`): which device keeps the original, when the
/// phone rewrites Apple Health, and a Revert asked for where the original isn't.
final class WorkoutEditsTests: XCTestCase {
    private let id = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func summary(start: TimeInterval = 0, end: TimeInterval = 3600, samples: Int = 1000,
                         pool: Double? = nil, edit: SessionEdit? = nil) -> FitnessSessionSummary {
        var summary = FitnessSessionSummary(session: FitnessSession(
            id: id, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end), activity: "Run",
            avgHeartRate: nil, totalEnergy: nil, totalDistance: nil, samples: []))
        summary.sampleCount = samples
        summary.poolLengthMeters = pool
        summary.edit = edit
        return summary
    }

    private var original: FitnessSessionSummary { summary() }
    private var editedAt: Date { t0.addingTimeInterval(9000) }
    private var trimmed: FitnessSessionSummary {
        summary(start: 300, end: 3000, samples: 700, edit: SessionEdit(original: original, at: editedAt))
    }

    // MARK: The mark

    func testTheMarkSurvivesTheSummarysOwnCoding() throws {
        let data = try JSONEncoder().encode(trimmed)
        let decoded = try JSONDecoder().decode(FitnessSessionSummary.self, from: data)
        XCTAssertEqual(decoded.edit, trimmed.edit)
        XCTAssertEqual(decoded.edit?.editedAt, editedAt, "a Revert names the edit by this, exactly")
        XCTAssertNil(try JSONDecoder().decode(FitnessSessionSummary.self, from: JSONEncoder().encode(original)).edit)
    }

    func testTheMarkKnowsItsOriginal() {
        let edit = SessionEdit(original: original, at: editedAt)
        XCTAssertTrue(edit.describes(original))
        XCTAssertFalse(edit.describes(trimmed))
        XCTAssertFalse(edit.describes(summary(samples: 999)), "the same span with other samples isn't it")
    }

    // MARK: Keeping the original

    func testADeviceHoldingTheOriginalKeepsItWhenATrimArrives() {
        XCTAssertEqual(WorkoutEdits.keeping(local: original, incoming: trimmed, original: nil, replacesRecording: true),
                       .keepOriginal)
    }

    func testADeviceThatOnlyEverHadTheTrimmedCopyKeepsNothing() {
        // The mark arriving for a workout this device already has trimmed (a trim from before
        // the mark existed): its recording is not the original, and must not be kept as one.
        var unmarked = trimmed
        unmarked.edit = nil
        XCTAssertEqual(WorkoutEdits.keeping(local: unmarked, incoming: trimmed, original: nil, replacesRecording: true),
                       .nothing)
    }

    func testNothingIsKeptWhenTheRecordingIsNotReplacedOrTheWorkoutIsNew() {
        XCTAssertEqual(WorkoutEdits.keeping(local: original, incoming: trimmed, original: nil, replacesRecording: false),
                       .nothing)
        XCTAssertEqual(WorkoutEdits.keeping(local: nil, incoming: trimmed, original: nil, replacesRecording: true),
                       .nothing)
    }

    func testTheKeptOriginalGoesWhenTheWorkoutIsRevertedElsewhere() {
        XCTAssertEqual(WorkoutEdits.keeping(local: trimmed, incoming: original, original: original, replacesRecording: true),
                       .dropOriginal)
    }

    func testAnotherTrimArrivingLeavesTheKeptOriginalAlone() {
        let again = summary(start: 600, end: 2400, samples: 400, edit: SessionEdit(original: original, at: editedAt.addingTimeInterval(60)))
        XCTAssertEqual(WorkoutEdits.keeping(local: trimmed, incoming: again, original: original, replacesRecording: true),
                       .nothing)
    }

    func testACopyThatLostItsMarkIsMarkedAgainWhereTheOriginalIsHeld() {
        // From a build that doesn't know the mark: still the trimmed recording, mark gone.
        var stripped = trimmed
        stripped.edit = nil
        XCTAssertEqual(WorkoutEdits.keeping(local: trimmed, incoming: stripped, original: original, replacesRecording: true),
                       .markEdited)
    }

    func testAPoolCorrectionIsAnEditLikeATrim() {
        let fifty = summary(pool: 50)
        let corrected = summary(pool: 22.86, edit: SessionEdit(original: fifty, at: editedAt))
        XCTAssertEqual(WorkoutEdits.keeping(local: fifty, incoming: corrected, original: nil, replacesRecording: true),
                       .keepOriginal)
        XCTAssertFalse(WorkoutEdits.sameRecording(fifty, corrected))
    }

    // MARK: Apple Health follows

    func testHealthFollowsATrimOrARevertThatArrives() {
        XCTAssertTrue(WorkoutEdits.healthMustFollow(local: original, incoming: trimmed, recordingArrived: true))
        XCTAssertTrue(WorkoutEdits.healthMustFollow(local: trimmed, incoming: original, recordingArrived: true))
    }

    func testHealthIsLeftAloneOtherwise() {
        XCTAssertFalse(WorkoutEdits.healthMustFollow(local: nil, incoming: original, recordingArrived: true),
                       "a workout new to the phone isn't an edit")
        XCTAssertFalse(WorkoutEdits.healthMustFollow(local: original, incoming: trimmed, recordingArrived: false),
                       "a summary without its recording can't be written")
        var sameWithNewSeries = original
        sameWithNewSeries.heartRateSeries = [HRPoint(t: 1, bpm: 120)]
        XCTAssertFalse(WorkoutEdits.healthMustFollow(local: original, incoming: sameWithNewSeries, recordingArrived: true),
                       "derived series filled in elsewhere don't change the recording")
    }

    func testTheSpanHealthHoldsIsRememberedUntilTheRewriteGoesThrough() {
        let first = WorkoutEdits.Span(start: t0, end: t0.addingTimeInterval(3600))
        let second = WorkoutEdits.Span(start: t0.addingTimeInterval(300), end: t0.addingTimeInterval(3000))
        var pending = WorkoutEdits.noting(first, for: id, in: [:])
        pending = WorkoutEdits.noting(second, for: id, in: pending)   // trimmed, then reverted, before Health was written
        XCTAssertEqual(pending, [id.uuidString: first])
        let other = UUID()
        XCTAssertEqual(WorkoutEdits.noting(second, for: other, in: pending).count, 2)
    }

    // MARK: Revert asked for elsewhere

    func testARevertIsCarriedOutWhereTheOriginalIsHeld() {
        let request = WorkoutRevertRequest(sessionID: id, editedAt: editedAt, askedAt: editedAt.addingTimeInterval(10))
        let now = editedAt.addingTimeInterval(60)
        XCTAssertTrue(WorkoutEdits.shouldRevert(request, summary: trimmed, hasOriginal: true, now: now))
        XCTAssertFalse(WorkoutEdits.shouldRevert(request, summary: trimmed, hasOriginal: false, now: now))
        XCTAssertFalse(WorkoutEdits.shouldRevert(request, summary: original, hasOriginal: true, now: now),
                       "already the original")
        XCTAssertFalse(WorkoutEdits.shouldRevert(request, summary: nil, hasOriginal: true, now: now))
    }

    func testAWorkoutTrimmedAgainAfterwardsIsNotRevertedByTheOldRequest() {
        let request = WorkoutRevertRequest(sessionID: id, editedAt: editedAt, askedAt: editedAt.addingTimeInterval(10))
        let again = summary(start: 600, end: 2400, samples: 400,
                            edit: SessionEdit(original: original, at: editedAt.addingTimeInterval(500)))
        XCTAssertFalse(WorkoutEdits.shouldRevert(request, summary: again, hasOriginal: true, now: editedAt.addingTimeInterval(600)))
    }

    func testAnOldRequestIsDropped() {
        let request = WorkoutRevertRequest(sessionID: id, editedAt: editedAt, askedAt: editedAt)
        let later = editedAt.addingTimeInterval(8 * 24 * 60 * 60)
        XCTAssertFalse(WorkoutEdits.shouldRevert(request, summary: trimmed, hasOriginal: true, now: later))
        let fresh = WorkoutRevertRequest(sessionID: UUID(), editedAt: later, askedAt: later)
        XCTAssertEqual(WorkoutEdits.adding(fresh, to: [request], now: later), [fresh])
    }

    func testOneRequestPerWorkout() {
        let first = WorkoutRevertRequest(sessionID: id, editedAt: editedAt, askedAt: editedAt)
        let second = WorkoutRevertRequest(sessionID: id, editedAt: editedAt.addingTimeInterval(5), askedAt: editedAt.addingTimeInterval(9))
        XCTAssertEqual(WorkoutEdits.adding(second, to: [first], now: editedAt.addingTimeInterval(10)), [second])
    }
}
