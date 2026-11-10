import XCTest

/// Travel blocks every device plans from its own route estimate (`CopyRefresh`): a block whose
/// inputs changed is written at once, whoever wrote it; one whose estimate merely differs is left
/// for `travelRefreshHold`, by Google's `updated`, and after that rewritten only when an edge moves
/// five minutes or more.
final class TravelCopyRefreshTests: XCTestCase {
    private let meeting = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let now = Date(timeIntervalSinceReferenceDate: 799_990_000)
    private let inputs = GoogleBusyBlocks.inputsHash(["travel-1", "work", "Travel to Lunch with Noor Haddad", "drive", "Cafe", "40.700,-74.000", "40.750,-73.990"])

    private func content(_ start: Date, _ end: Date, title: String = "Travel to Lunch with Noor Haddad") -> String {
        GoogleBusyBlocks.content(title: title, start: start, end: end, isAllDay: false)
    }

    /// The trip this device wants: `minutes` before the meeting.
    private func wanted(minutes: Double, inputs: String? = nil, refreshable: Bool = true) -> BusyCopyPlanner.Desired {
        let start = meeting.addingTimeInterval(-minutes * 60)
        return BusyCopyPlanner.Desired(appItemID: "travel-1", ledgerKey: "travel-1|work", fingerprint: Int(minutes),
                                       content: content(start, meeting), inputs: inputs ?? self.inputs,
                                       refreshable: refreshable, start: start, end: meeting)
    }

    /// The block on Google: `minutes` before the meeting, last changed `age` seconds ago.
    private func onGoogle(minutes: Double, age: TimeInterval, inputs: String?? = .some(nil),
                          title: String = "Travel to Lunch with Noor Haddad") -> BusyCopyPlanner.Owned {
        let start = meeting.addingTimeInterval(-minutes * 60)
        let stamp: String? = inputs ?? self.inputs
        return BusyCopyPlanner.Owned(eventID: "g1", etag: "e1", end: meeting, content: content(start, meeting, title: title),
                                     start: start, inputs: stamp, updated: now.addingTimeInterval(-age))
    }

    private func plan(_ want: BusyCopyPlanner.Desired, _ have: BusyCopyPlanner.Owned, at time: Date? = nil) -> BusyCopyPlanner.CalendarPlan {
        BusyCopyPlanner.plan(desired: [want], owned: ["travel-1": [have]], recorded: [:], now: time ?? now)
    }

    func testChangedInputsAreWrittenAtOnceWhoeverWroteIt() {
        // Ten seconds old, written by another device, but the meeting's place changed.
        let p = plan(wanted(minutes: 25, inputs: GoogleBusyBlocks.inputsHash(["travel-1", "other place"])),
                     onGoogle(minutes: 20, age: 10, inputs: .some(inputs)))
        XCTAssertEqual(p.writes, [.update(index: 0, eventID: "g1", etag: "e1")])
        XCTAssertTrue(p.held.isEmpty)
    }

    func testSameInputsAndAYoungBlockAreLeftEvenForABigDifference() {
        let p = plan(wanted(minutes: 35), onGoogle(minutes: 20, age: 30 * 60, inputs: .some(inputs)))
        XCTAssertTrue(p.writes.isEmpty)
        XCTAssertEqual(p.held.map(\.eventID), ["g1"])
    }

    func testSameInputsAnOldBlockAndUnderFiveMinutesAreLeft() {
        let p = plan(wanted(minutes: 24), onGoogle(minutes: 20, age: 2 * 3600, inputs: .some(inputs)))
        XCTAssertTrue(p.writes.isEmpty)
        XCTAssertEqual(p.held.count, 1)
    }

    func testSameInputsAnOldBlockAndFiveMinutesOrMoreAreWritten() {
        XCTAssertEqual(plan(wanted(minutes: 25), onGoogle(minutes: 20, age: CopyRefresh.travelRefreshHold + 1, inputs: .some(inputs))).writes,
                       [.update(index: 0, eventID: "g1", etag: "e1")])
        // The hold is by Google's `updated`: one second younger than the hold, the same block stays.
        XCTAssertTrue(plan(wanted(minutes: 25), onGoogle(minutes: 20, age: CopyRefresh.travelRefreshHold - 1, inputs: .some(inputs))).writes.isEmpty)
    }

    func testAnUnstampedBlockIsAdoptedWhenOnlyItsTimesDifferALittle() {
        // From a build that didn't stamp: not rewritten just to add the stamp.
        let adopted = plan(wanted(minutes: 22), onGoogle(minutes: 20, age: 60))
        XCTAssertTrue(adopted.writes.isEmpty)
        // Genuinely different: written (and stamped).
        XCTAssertEqual(plan(wanted(minutes: 30), onGoogle(minutes: 20, age: 60)).writes.count, 1)
        XCTAssertEqual(plan(wanted(minutes: 20), onGoogle(minutes: 20, age: 60, title: "Travel to Somewhere else")).writes.count, 1)
        // Saying exactly what is wanted: a plain match, as before.
        XCTAssertEqual(plan(wanted(minutes: 20), onGoogle(minutes: 20, age: 60)).matches.count, 1)
    }

    func testBusyCopiesAndTaskBlocksAreNeverHeld() {
        let p = plan(wanted(minutes: 22, refreshable: false), onGoogle(minutes: 20, age: 60, inputs: .some(inputs)))
        XCTAssertEqual(p.writes.count, 1)
    }

    func testACancelledSourceRemovesTheBlockWhoeverWroteIt() {
        // The meeting is gone, so nothing wants the block: it is unwanted, young or not.
        let p = BusyCopyPlanner.plan(desired: [], owned: ["travel-1": [onGoogle(minutes: 20, age: 10, inputs: .some(inputs))]],
                                     recorded: [:], now: now)
        XCTAssertEqual(p.unwanted["travel-1"]?.map(\.eventID), ["g1"])
        XCTAssertTrue(p.writes.isEmpty)
    }

    /// Two devices whose estimates differ by three minutes, each planning every 20 seconds against
    /// what Google holds, for longer than the hold: one write (the create), then none.
    func testTwoDevicesWithDifferentEstimatesConvergeWithNoRewrites() {
        var server: BusyCopyPlanner.Owned?
        var writes = 0
        var clock = now
        let estimates: [Double] = [20, 23]   // device A, device B
        for pass in 0..<(3 * 3600 / 20) {
            let want = wanted(minutes: estimates[pass % 2])
            let p = BusyCopyPlanner.plan(desired: [want], owned: server.map { ["travel-1": [$0]] } ?? [:],
                                         recorded: [:], now: clock)
            for write in p.writes {
                writes += 1
                if case .create = write {} else { XCTFail("rewrote at pass \(pass)") }
                // Google stamps the write with its own clock.
                server = BusyCopyPlanner.Owned(eventID: "g1", etag: "e\(writes)", end: want.end!, content: want.content,
                                               start: want.start, inputs: want.inputs, updated: clock)
            }
            clock = clock.addingTimeInterval(20)
        }
        XCTAssertEqual(writes, 1)
    }
}
