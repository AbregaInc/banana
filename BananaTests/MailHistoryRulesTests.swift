import XCTest

final class MailHistoryRulesTests: XCTestCase {
    private func change(_ id: String, labels: [String]? = nil) -> GmailHistoryChange {
        GmailHistoryChange(message: GmailMessage(id: id, threadId: "t-" + id), labelIds: labels)
    }
    private func state(_ history: UInt64, vis: Int = 0) -> StoredMessageState {
        StoredMessageState(msgPK: 1, fetchState: 1, vis: vis, labels: ["INBOX"], labelsKnown: true, historyID: history)
    }
    private func plan(_ records: [GmailHistoryRecord], states: [String: StoredMessageState] = [:],
                      tombstones: Set<String> = []) throws -> MailHistoryPlan {
        try MailHistoryRules.plan(records, account: "fixture@example.com", known: { states[$0] },
            knownLabel: { ["INBOX", "UNREAD", "STARRED"].contains($0) }, tombstoned: { tombstones.contains($0) })
    }

    func testBothLabelDirectionsApplyAtOneHistoryPositionAndReplayIsIgnored() throws {
        let record = GmailHistoryRecord(id: UInt64.max, labelsAdded: [change("m", labels: ["STARRED", "custom"])],
            labelsRemoved: [change("m", labels: ["INBOX"])])
        let value = try plan([record], states: ["m": state(UInt64.max - 1)])
        XCTAssertEqual(value.setLabels, [LabelChange(messageID: "m", add: ["STARRED", "custom"], remove: ["INBOX"], recordID: UInt64.max)])
        XCTAssertEqual(value.unknownLabels, ["custom"])
        XCTAssertEqual(value.echoes.count, 3)
        XCTAssertTrue(value.echoes.allSatisfy { $0.account == "fixture@example.com" })
        XCTAssertEqual(try plan([record], states: ["m": state(UInt64.max)]), MailHistoryPlan())
    }

    func testUnknownDeltasRequireFetchWithoutInventingCompleteMemberships() throws {
        let value = try plan([GmailHistoryRecord(id: 2, messagesAdded: [change("a")],
            labelsAdded: [change("b", labels: ["UNREAD"])])])
        XCTAssertEqual(value.fetch, ["a", "b"])
        XCTAssertEqual(value.createStubs.map(\.threadID), ["t-a", "t-b"])
        XCTAssertTrue(value.setLabels.isEmpty)
        XCTAssertTrue(value.echoes.isEmpty)
        let cancelled = try plan([GmailHistoryRecord(id: 2, messagesAdded: [change("a")]),
                                 GmailHistoryRecord(id: 3, messagesDeleted: [change("a")])])
        XCTAssertEqual(cancelled, MailHistoryPlan())
    }

    func testDeletedKnownRowsDoNotKeepMembershipChangesOrEchoes() throws {
        let value = try plan([GmailHistoryRecord(id: 2, labelsAdded: [change("m", labels: ["custom"])]),
                             GmailHistoryRecord(id: 3, messagesDeleted: [change("m")])], states: ["m": state(1)])
        XCTAssertEqual(value.delete, ["m"])
        XCTAssertTrue(value.setLabels.isEmpty)
        XCTAssertTrue(value.echoes.isEmpty)
        XCTAssertTrue(value.unknownLabels.isEmpty)
        XCTAssertTrue(try plan([GmailHistoryRecord(id: 2, messagesDeleted: [change("m")])], states: ["m": state(3)]).delete.isEmpty)
    }

    func testKeptAndTombstonedMessagesCannotBeMutatedOrResurrected() throws {
        let record = GmailHistoryRecord(id: 9, messagesAdded: [change("gone")],
            messagesDeleted: [change("kept")], labelsAdded: [change("gone", labels: ["INBOX"]), change("kept", labels: ["UNREAD"])])
        XCTAssertEqual(try plan([record], states: ["kept": state(1, vis: 4)], tombstones: ["gone"]), MailHistoryPlan())
    }

    func testIncompleteUnorderedAndContradictoryPagesFailBeforeApplication() throws {
        for records in [
            [GmailHistoryRecord()],
            [GmailHistoryRecord(id: 2)],
            [GmailHistoryRecord(id: 2, messagesAdded: [GmailHistoryChange(message: GmailMessage(id: "new"))])],
            [GmailHistoryRecord(id: 2, labelsAdded: [change("m")])],
            [GmailHistoryRecord(id: 3, messagesAdded: [change("a")]), GmailHistoryRecord(id: 2, messagesAdded: [change("b")])],
            [GmailHistoryRecord(id: 2, labelsAdded: [change("m", labels: ["INBOX"])], labelsRemoved: [change("m", labels: ["INBOX"])])]
        ] { XCTAssertThrowsError(try plan(records, states: ["m": state(1)])) }
    }

    func testHistoryPagePlanningCost() throws {
        let records = (1...100).map { number in
            GmailHistoryRecord(id: UInt64(number + 1), labelsAdded: (0..<20).map {
                change("\(number)-\($0)", labels: ["UNREAD", "custom"])
            })
        }
        let existing = state(1)
        var samples: [Double] = []
        for _ in 0..<6 {
            let start = ContinuousClock.now
            let value = try MailHistoryRules.plan(records, account: "fixture@example.com",
                known: { _ in existing }, knownLabel: { $0 == "UNREAD" }, tombstoned: { _ in false })
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertEqual(value.setLabels.count, 2_000)
            XCTAssertEqual(value.echoes.count, 4_000)
            XCTAssertEqual(value.unknownLabels, ["custom"])
        }
        if let path = ProcessInfo.processInfo.environment["MAIL_HISTORY_BENCHMARK_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["samplesMS": samples,
                "scope": "100 history records, 2000 message deltas; first and five warm planner calls only. No database, UI, eviction or device acceptance."], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        for sample in samples { XCTAssertLessThan(sample, 100) }
    }
}
