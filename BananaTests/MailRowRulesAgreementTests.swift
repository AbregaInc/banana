import XCTest

final class MailRowRulesAgreementTests: XCTestCase {
    func testOptimisticMembershipAgreesWithPreparedMembership() {
        let routes: [(MailPlace, MailViewKey)] = [
            (.mailbox(.inbox), .unified(.inbox)), (.mailbox(.starred), .unified(.starred)),
            (.mailbox(.important), .unified(.important)), (.mailbox(.sent), .unified(.sent)),
            (.mailbox(.all), .allMail(account: nil)), (.mailbox(.done), .done(account: nil)),
            (.label(account: "a", id: "INBOX"), .label(account: "a", labelID: "INBOX")),
            (.label(account: "a", id: "UNREAD"), .label(account: "a", labelID: "UNREAD")),
            (.label(account: "a", id: "STARRED"), .label(account: "a", labelID: "STARRED")),
            (.label(account: "a", id: "IMPORTANT"), .label(account: "a", labelID: "IMPORTANT")),
            (.split(MailSplit.calendarID), .split(id: MailSplit.calendarID)),
            (.split(MailSplit.importantID), .split(id: MailSplit.importantID)),
            (.split(MailSplit.otherID), .split(id: MailSplit.otherID))]
        let edits: [(MailChange, Set<String>, Set<String>)] = [
            (.done, [], ["INBOX", "UNREAD"]), (.notDone, ["INBOX"], []),
            (.read(true), [], ["UNREAD"]), (.read(false), ["UNREAD"], []),
            (.star(false), [], ["STARRED"]), (.star(true), ["STARRED"], []),
            (.important(false), [], ["IMPORTANT"]), (.important(true), ["IMPORTANT"], []),
            (.trash, ["TRASH"], ["INBOX"]), (.spam, ["SPAM"], ["INBOX"])]
        for bits in 0..<32 {
            let tags = ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "SENT"]
            let labels = Set(tags.enumerated().compactMap { bits & (1 << $0.offset) != 0 ? $0.element : nil })
            for invite in [false, true] {
                let before = MessageFacts(gmailID: "m", internalDate: 100, fetchState: 1, vis: 0,
                    labels: labels, labelsKnown: true, bananaLabels: [], fromName: nil,
                    fromAddress: "sender@example.com", isFromMe: false, toAddresses: [], ccAddresses: [],
                    subject: "Subject", snippet: "Preview", hasAttachment: false, hasInvite: invite,
                    listID: nil, hasUndeliveredIntent: false, hasRefusedIntent: false)
                func memberships(_ value: MessageFacts) -> [ViewMembership] {
                    ViewMembershipRules.memberships([value], account: "a", splits: [],
                        matches: { _, _ in false }, myAddresses: [])
                }
                let oldViews = Set(memberships(before).map(\.view))
                for (place, view) in routes where oldViews.contains(view) {
                    let scope = MailScope(place: place)
                    let summary = ThreadSummaryRules.summarise([before], myAddresses: [])
                    let stored = IndexRow(summary: summary, id: MailConversationID(account: "a", thread: "t"),
                                          key: MailOrderKey(group: 0, sortKey: 100, tie: 1))
                    let row = MailRowMapper.row(stored, labels: [], reason: nil, in: scope)
                    for (change, add, remove) in edits {
                        var after = before; after.labels.subtract(remove); after.labels.formUnion(add)
                        let contains = memberships(after).contains { $0.view == view }
                        switch MailRowRules.apply(change, to: row, in: scope) {
                        case .stays: XCTAssertTrue(contains, "\(labels) \(place) \(change)")
                        case .leaves: XCTAssertFalse(contains, "\(labels) \(place) \(change)")
                        case .unknown: break
                        }
                    }
                }
            }
        }
    }
}
