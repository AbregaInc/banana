import XCTest

final class OutboxRulesTests: XCTestCase {
    private func message(_ id: String, _ date: Int64, labels: Set<String> = [], known: Bool = true, vis: Int = 0) -> MessageFacts {
        MessageFacts(gmailID: id, internalDate: date, fetchState: 1, vis: vis, labels: labels,
            labelsKnown: known, bananaLabels: [], fromName: nil, fromAddress: "sender@example.com",
            isFromMe: false, toAddresses: [], ccAddresses: [], subject: "Subject", snippet: "",
            hasAttachment: false, hasInvite: false, listID: nil, hasUndeliveredIntent: false, hasRefusedIntent: false)
    }
    func testArchiveDoesNotIncludeNewRepliesDraftsOrUnconfirmedRows() throws {
        let values = [message("seen", 10, labels: ["INBOX", "UNREAD"]),
                      message("new", 11, labels: ["INBOX"]), message("draft", 9, labels: ["DRAFT", "INBOX"]),
                      message("unconfirmed", 8, labels: ["INBOX"], vis: 3), message("kept", 7, labels: ["INBOX"], vis: 4)]
        let result = try OutboxRules.assertions(for: .done, account: "a@example.com", messages: values, asOf: 10)
        XCTAssertEqual(result.map(\.messageID), ["seen", "seen"])
        XCTAssertEqual(Set(result.map(\.labelRef)), ["INBOX", "UNREAD"])
        XCTAssertTrue(result.allSatisfy { !$0.want })
    }
    func testStarAndUnreadUseDeterministicLastNonDraft() throws {
        let values = [message("b", 10), message("draft", 20, labels: ["DRAFT"]), message("a", 10)]
        for change in [MailChange.star(true), .read(false), .notDone] {
            let result = try OutboxRules.assertions(for: change, account: "a@example.com", messages: values, asOf: 30)
            XCTAssertEqual(result.map(\.messageID), ["b"])
            XCTAssertTrue(result.allSatisfy(\.want))
        }
    }
    func testUnknownAbsenceNeverDropsRemoval() throws {
        let values = [message("unknown", 1, known: false), message("known", 2)]
        let result = try OutboxRules.assertions(for: .read(true), account: "a@example.com", messages: values, asOf: 2)
        XCTAssertEqual(result.map(\.messageID), ["unknown"])
        XCTAssertFalse(OutboxRules.isMoot(want: false, gmailHas: nil))
        XCTAssertTrue(OutboxRules.isMoot(want: false, gmailHas: false))
    }
    func testLabelAccountIsolationAndConflictingLabels() throws {
        let values = [message("m", 1)]
        let foreign = try OutboxRules.assertions(for: .label(account: "other@example.com", add: ["label"], remove: []), account: "a@example.com", messages: values, asOf: 2)
        XCTAssertTrue(foreign.isEmpty)
        XCTAssertThrowsError(try OutboxRules.assertions(for: .label(account: "a@example.com", add: ["label"], remove: ["label"]), account: "a@example.com", messages: values, asOf: 2))
        XCTAssertThrowsError(try OutboxRules.assertions(for: .snooze(until: Date(), ifNoReply: false), account: "a@example.com", messages: values, asOf: 2))
    }
}
