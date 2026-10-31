import XCTest

final class ViewMembershipRulesTests: XCTestCase {
    private func message(_ id: String, _ date: Int64, _ labels: Set<String>,
                         vis: Int = 0, fetched: Int = 1, rowID: Int64 = 0) -> MessageFacts {
        MessageFacts(gmailID: id, rowID: rowID, internalDate: date, fetchState: fetched, vis: vis,
            labels: labels, labelsKnown: true, bananaLabels: [], fromName: nil,
            fromAddress: "sender@example.com", isFromMe: false, toAddresses: [], ccAddresses: [],
            subject: "Subject", snippet: "Preview", hasAttachment: false, hasInvite: false,
            listID: nil, hasUndeliveredIntent: false, hasRefusedIntent: false)
    }
    private func rows(_ messages: [MessageFacts]) -> [ViewMembership] {
        ViewMembershipRules.memberships(messages, account: "a", splits: [],
            matches: { _, _ in false }, myAddresses: [])
    }
    func testIncomingReplyDoesNotLiftSentOrdering() {
        let result = rows([message("sent", 10, ["SENT"]), message("reply", 30, ["INBOX", "UNREAD"])])
        XCTAssertEqual(result.first { $0.view == .unified(.sent) }?.sortKey, 10)
        XCTAssertEqual(result.first { $0.view == .unified(.inbox) }?.sortKey, 30)
        XCTAssertEqual(result.first { $0.view == .allMail(account: nil) }?.sortKey, 30)
        XCTAssertTrue(result.allSatisfy(\.unread))
        XCTAssertFalse(result.contains { $0.view == .done(account: nil) })
    }
    func testTrashAndUnconfirmedMailCannotEnterOrdinaryViews() {
        let result = rows([message("trash", 30, ["TRASH", "INBOX", "UNREAD"], vis: 1),
                           message("unknown", 40, ["INBOX"], vis: 3)])
        XCTAssertEqual(Set(result.map(\.view)), [.label(account: "a", labelID: "TRASH"), .unified(.trash)])
        XCTAssertTrue(result.allSatisfy { $0.sortKey == 30 && $0.unread })
        XCTAssertTrue(rows([message("unknown", 40, ["TRASH"], vis: 3)]).isEmpty)
    }
    func testKeptMailHasDoneAndAllMailMembership() {
        let result = rows([message("kept", 20, ["STARRED"], vis: 4)])
        XCTAssertTrue(result.contains { $0.view == .done(account: nil) })
        XCTAssertTrue(result.contains { $0.view == .allMail(account: "a") })
        XCTAssertFalse(result.contains { if case .split = $0.view { return true }; return false })
    }
    func testStubUsesNegativeLocalPrimaryKeyUntilFetched() {
        var values = [message("a", 0, ["INBOX"], fetched: 0, rowID: 7),
                      message("b", 0, ["INBOX"], fetched: 0, rowID: 12)]
        XCTAssertTrue(rows(values).allSatisfy { $0.sortKey == -12 })
        values[0].fetchState = 1; values[0].internalDate = 100
        XCTAssertTrue(rows(values).allSatisfy { $0.sortKey == 100 })
    }
    func testCustomSplitsHavePriorityAndOnlyOneWins() {
        var value = message("a", 20, ["INBOX", "IMPORTANT"]); value.hasInvite = true
        let splits = [MailSplit(id: "first", name: "First", query: "x"),
                      MailSplit(id: "second", name: "Second", query: "y")]
        XCTAssertEqual(MailBuiltInSplits.matching([value], splits: splits, matches: { _, _ in true }), "first")
        XCTAssertEqual(MailBuiltInSplits.matching([value], splits: splits), MailSplit.calendarID)
        value.hasInvite = false
        XCTAssertEqual(MailBuiltInSplits.matching([value], splits: []), MailSplit.importantID)
        value.labels = ["INBOX"]
        XCTAssertEqual(MailBuiltInSplits.matching([value], splits: []), MailSplit.otherID)
        value.labels = ["SENT"]
        XCTAssertNil(MailBuiltInSplits.matching([value], splits: []))
    }
    func testMembershipIsStableUnderInputPermutationAndMutedIsExplicit() {
        var muted = message("a", 10, ["INBOX"]); muted.bananaLabels = ["Banana/Muted"]
        let other = message("b", 30, ["SENT", "UNREAD"])
        XCTAssertEqual(rows([muted, other]), rows([other, muted]))
        XCTAssertEqual(rows([muted, other]).first { $0.view == .muted }?.sortKey, 30)
        XCTAssertEqual(Set(rows([muted, other]).map(\.view)).count, rows([muted, other]).count)
    }
}
