import XCTest

/// Coverage for the routing-guard fix in `Banana/Model/CloudProgressSync.swift`
/// (`CloudFitnessSync.apply`/`applyDeletion`): the note branch guarded on
/// `hasPrefix("note-")`, but the workout branch was a bare `else` with no
/// `hasPrefix("workout-")` guard of its own, so any record name this app didn't recognise fell
/// through and was attempted as a workout — corrupting the local fitness index with phantom
/// `Date.distantPast` summaries when the attempt happened to decode, and vanishing without a
/// trace when it didn't.
///
/// `CloudFitnessRecordRouting.classify` (`Shared/FitnessModels.swift`) is the fix: the one place
/// that routing decision is made now, pure and CloudKit-free, so it's testable here without
/// constructing a `CKSyncEngine`/`CKContainer` — `CloudFitnessSync` itself deliberately stays out
/// of this test target (see `FitnessIndexPersistenceTests`'s doc comment for the same reasoning
/// applied to `FitnessStore`).
final class CloudFitnessRecordRoutingTests: XCTestCase {
    private let healthName = "health-cache"
    private let someUUID = UUID(uuidString: "0030257A-5980-4A67-B04C-86019DE56BB2")!

    // MARK: - Each known prefix resolves to its own kind, and only its own kind

    func testNotePrefixResolvesToNote() {
        let name = "note-\(someUUID.uuidString)"
        let kind = CloudFitnessRecordRouting.classify(name, healthRecordName: healthName)
        XCTAssertEqual(kind, .note(someUUID))
    }

    /// The actual bug: a `note-` record must never resolve to `.workout`, even after decode
    /// failure. Before the fix, a malformed note fell through the un-guarded workout branch and
    /// was attempted (and typically failed) as a workout decode instead of staying a note.
    func testNotePrefixNeverResolvesToWorkout() {
        let name = "note-\(someUUID.uuidString)"
        let kind = CloudFitnessRecordRouting.classify(name, healthRecordName: healthName)
        if case .workout = kind {
            XCTFail("a note- record must never classify as a workout")
        }
    }

    func testWorkoutPrefixResolvesToWorkout() {
        let name = "workout-\(someUUID.uuidString)"
        let kind = CloudFitnessRecordRouting.classify(name, healthRecordName: healthName)
        XCTAssertEqual(kind, .workout(someUUID))
    }

    func testHealthRecordNameResolvesToHealth() {
        let kind = CloudFitnessRecordRouting.classify(healthName, healthRecordName: healthName)
        XCTAssertEqual(kind, .health)
    }

    // MARK: - Unrecognised names resolve to neither, not to a silent default

    /// The exact shape that corrupted the index: a record name with no known prefix at all — no
    /// `note-`/`workout-` prefix, not the health record. Before the fix this fell into the
    /// un-guarded workout branch; now it must classify as `.unrecognised`, which every caller
    /// (`apply`/`applyDeletion`) logs instead of silently attempting or dropping.
    func testBareUUIDWithNoPrefixIsUnrecognised() {
        // A real record name observed live in this bug's blast radius (`ckSyncEngine.fitness
        // .revisions` on-device) — a bare UUID with no "note-"/"workout-" prefix at all.
        let name = "32742e24-9fce-11f1-b7d7-635450354b27"
        let kind = CloudFitnessRecordRouting.classify(name, healthRecordName: healthName)
        XCTAssertEqual(kind, .unrecognised)
    }

    func testUnrelatedRecordNameIsUnrecognised() {
        let kind = CloudFitnessRecordRouting.classify("SettingsSnapshot-1", healthRecordName: healthName)
        XCTAssertEqual(kind, .unrecognised)
    }

    /// A `note-`-prefixed name whose suffix isn't a valid UUID is a malformed name, not a note —
    /// `classify` requires both the prefix AND a parseable UUID, matching what `apply`'s note
    /// branch has always required for its own `if let` chain.
    func testNotePrefixWithoutValidUUIDIsUnrecognised() {
        let kind = CloudFitnessRecordRouting.classify("note-not-a-uuid", healthRecordName: healthName)
        XCTAssertEqual(kind, .unrecognised)
    }

    func testWorkoutPrefixWithoutValidUUIDIsUnrecognised() {
        let kind = CloudFitnessRecordRouting.classify("workout-not-a-uuid", healthRecordName: healthName)
        XCTAssertEqual(kind, .unrecognised)
    }

    /// Empty string is the degenerate unrecognised case — must not crash or match by accident.
    func testEmptyNameIsUnrecognised() {
        let kind = CloudFitnessRecordRouting.classify("", healthRecordName: healthName)
        XCTAssertEqual(kind, .unrecognised)
    }
}
