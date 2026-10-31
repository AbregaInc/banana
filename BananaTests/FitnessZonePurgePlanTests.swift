import XCTest

/// Coverage for the Fitness-zone purge tool's delete-list handling
/// (`Shared/FitnessModels.swift`'s `FitnessZonePurgeDeleteList`/`FitnessZonePurgePlan`) — the
/// replacement for `auditFitnessZone`'s CloudKit query, which cannot work in this container (see
/// the "Fitness-zone purge delete list" section of `Shared/FitnessModels.swift` for the exact
/// CKError). Pure and CloudKit-free by design, so it's testable here without constructing a
/// `CKSyncEngine`/`CKContainer` — `CloudFitnessSync` itself deliberately stays out of this test
/// target (see `CloudFitnessRecordRoutingTests`'s doc comment for the same reasoning).
final class FitnessZonePurgePlanTests: XCTestCase {
    private let phantomA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let phantomB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let realA = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let realB = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func recordName(_ id: UUID) -> String { FitnessZonePurgePlan.workoutRecordName(for: id) }

    // MARK: - Record-name construction

    /// The exact rule the whole tool depends on: CloudKit record names in the Fitness zone are
    /// `workout-<uuid>`, uppercase `uuidString` (Foundation's default), no other transformation.
    func testWorkoutRecordNameConstructionFromUUID() {
        let id = UUID(uuidString: "0030257A-5980-4A67-B04C-86019DE56BB2")!
        XCTAssertEqual(FitnessZonePurgePlan.workoutRecordName(for: id),
                       "workout-0030257A-5980-4A67-B04C-86019DE56BB2")
    }

    /// Round-trips through `CloudFitnessRecordRouting.classify` — the construction this test
    /// covers is the exact inverse of the parse that function already performs, so a record name
    /// this tool builds must classify right back to the same id.
    func testWorkoutRecordNameRoundTripsThroughClassify() {
        let id = UUID()
        let name = FitnessZonePurgePlan.workoutRecordName(for: id)
        let kind = CloudFitnessRecordRouting.classify(name, healthRecordName: "health-cache")
        XCTAssertEqual(kind, .workout(id))
    }

    // MARK: - validate: overlap with the live local index aborts

    /// The primary safety rule: a delete list naming a record the LIVE local index still
    /// considers real must abort the whole run, not silently skip that one name.
    func testDeleteListOverlappingLiveRealWorkoutAborts() {
        let list = FitnessZonePurgeDeleteList(phantomRecordNames: [recordName(phantomA), recordName(realA)],
                                              realRecordNames: [])
        let liveReal: Set<String> = [recordName(realA)]

        XCTAssertThrowsError(try FitnessZonePurgePlan.validate(list, liveRealRecordNames: liveReal)) { error in
            guard case let FitnessZonePurgeValidationError.deleteListOverlapsLiveRealWorkouts(overlap) = error else {
                return XCTFail("expected .deleteListOverlapsLiveRealWorkouts, got \(error)")
            }
            XCTAssertEqual(overlap, [recordName(realA)])
        }
    }

    /// A delete list can also contradict itself before the live index is even consulted: its own
    /// phantom and real arrays naming the same record name. That is caught first and separately.
    func testDeleteListSelfContradictionAborts() {
        let shared = recordName(phantomA)
        let list = FitnessZonePurgeDeleteList(phantomRecordNames: [shared], realRecordNames: [shared])

        XCTAssertThrowsError(try FitnessZonePurgePlan.validate(list, liveRealRecordNames: [])) { error in
            guard case let FitnessZonePurgeValidationError.deleteListSelfContradicts(overlap) = error else {
                return XCTFail("expected .deleteListSelfContradicts, got \(error)")
            }
            XCTAssertEqual(overlap, [shared])
        }
    }

    // MARK: - validate: no overlap proceeds

    /// The common case: phantoms the list wants deleted share no name with either the file's own
    /// "known real" list or the live local index. `validate` must not throw.
    func testDeleteListWithNoOverlapProceeds() {
        let list = FitnessZonePurgeDeleteList(phantomRecordNames: [recordName(phantomA), recordName(phantomB)],
                                              realRecordNames: [recordName(realA)])
        let liveReal: Set<String> = [recordName(realA), recordName(realB)]

        XCTAssertNoThrow(try FitnessZonePurgePlan.validate(list, liveRealRecordNames: liveReal))
    }

    // MARK: - validate: empty list is a clean no-op

    /// Nothing to delete and nothing known real — trivially disjoint from everything, including a
    /// non-empty live index. Must not throw.
    func testEmptyDeleteListIsCleanNoOp() {
        let list = FitnessZonePurgeDeleteList(phantomRecordNames: [], realRecordNames: [])
        let liveReal: Set<String> = [recordName(realA), recordName(realB)]

        XCTAssertNoThrow(try FitnessZonePurgePlan.validate(list, liveRealRecordNames: liveReal))
    }

    // MARK: - FitnessZonePurgeDeleteList: plain JSON round-trip

    /// The shape `--purge-fitness-zone-delete-list <path>` actually reads off disk — decode
    /// failures here would surface as a load error in `CloudFitnessZonePurgeTool`, not a silent
    /// empty list, so the field names matter.
    func testDeleteListDecodesFromJSON() throws {
        let json = """
        {
            "phantomRecordNames": ["workout-\(phantomA.uuidString)"],
            "realRecordNames": ["workout-\(realA.uuidString)"]
        }
        """
        let list = try JSONDecoder().decode(FitnessZonePurgeDeleteList.self, from: Data(json.utf8))
        XCTAssertEqual(list.phantomRecordNames, [recordName(phantomA)])
        XCTAssertEqual(list.realRecordNames, [recordName(realA)])
    }
}
