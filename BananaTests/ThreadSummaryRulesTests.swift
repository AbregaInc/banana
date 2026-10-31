import XCTest

final class ThreadSummaryRulesTests: XCTestCase {
    private func message(_ id: String, _ time: Int64, sender: String = "sam@example.com",
                         labels: Set<String> = ["INBOX"], vis: Int = 0, fetched: Int = 1) -> MessageFacts {
        MessageFacts(gmailID: id, internalDate: time, fetchState: fetched, vis: vis,
                     labels: labels, labelsKnown: true, bananaLabels: [], fromName: "Sam",
                     fromAddress: sender, isFromMe: false, toAddresses: [], ccAddresses: [],
                     subject: "subject-" + id, snippet: "snippet-" + id,
                     hasAttachment: false, hasInvite: false, listID: nil,
                     hasUndeliveredIntent: false, hasRefusedIntent: false)
    }
    private func summary(_ values: [MessageFacts], own: Set<String> = []) -> ThreadSummary {
        ThreadSummaryRules.summarise(values, myAddresses: own)
    }

    func testSummaryIsInputOrderIndependentAndUsesEarliestSubjectLatestSnippet() {
        let first = message("a", 10), second = message("b", 20), tie = message("c", 20)
        let expected = summary([first, second, tie])
        XCTAssertEqual(summary([tie, first, second]), expected)
        XCTAssertEqual(expected.subject, "subject-a")
        XCTAssertEqual(expected.snippet, "snippet-c")
        XCTAssertEqual(expected.lastDate, 20)
        XCTAssertEqual(expected.messageCount, 3)
    }

    func testUnconfirmedRowsNeverBecomeVisibleEvenWhenTheyAreTheOnlyRows() {
        let row = message("a", 10, labels: ["INBOX", "UNREAD"], vis: 3)
        let value = summary([row])
        XCTAssertEqual(value.messageCount, 0)
        XCTAssertEqual(value.fetchedCount, 0)
        XCTAssertEqual(value.unreadCount, 0)
        XCTAssertTrue(value.people.isEmpty)
        XCTAssertTrue(value.labels.isEmpty)
        XCTAssertEqual(value.lastDate, 0)
    }

    func testTrashAndSpamAreExcludedWhenOrdinaryMailExists() {
        let value = summary([message("a", 10),
            message("b", 20, labels: ["TRASH", "UNREAD"], vis: 1),
            message("c", 30, labels: ["SPAM", "UNREAD"], vis: 2)])
        XCTAssertEqual(value.messageCount, 1)
        XCTAssertEqual(value.lastDate, 10)
        XCTAssertEqual(value.unreadCount, 0)
        XCTAssertEqual(value.labels, ["INBOX"])
    }

    func testEntirelyTrashedConversationStillHasAReadableSummary() {
        let value = summary([message("a", 10, labels: ["TRASH"], vis: 1),
                             message("b", 20, labels: ["TRASH", "UNREAD"], vis: 1)])
        XCTAssertEqual(value.messageCount, 2)
        XCTAssertEqual(value.subject, "subject-a")
        XCTAssertEqual(value.snippet, "snippet-b")
        XCTAssertEqual(value.unreadCount, 1)
    }

    func testKeptMessageRemainsReadableBesideLiveMailAndRetainsTheConversation() {
        let value = summary([message("a", 10), message("b", 20, vis: 4)])
        XCTAssertEqual(value.messageCount, 2)
        XCTAssertTrue(value.flags.contains(.keptAfterRemoval))
        XCTAssertTrue(value.claims.contains(.keptAfterRemoval))
    }

    func testStubCountsAndUnreadStateDoNotInventDatesOrSenders() {
        let value = summary([message("stub", 0, labels: ["INBOX", "UNREAD"], fetched: 0)])
        XCTAssertEqual(value.messageCount, 1)
        XCTAssertEqual(value.fetchedCount, 0)
        XCTAssertEqual(value.unreadCount, 1)
        XCTAssertEqual(value.lastDate, 0)
        XCTAssertEqual(value.subject, "")
        XCTAssertTrue(value.people.isEmpty)
    }

    func testOwnAliasesCoalesceWithoutTrustingSomeoneNamedMe() {
        var impostor = message("c", 3, sender: "other@example.com")
        impostor.fromName = "me"
        let value = summary([message("a", 1, sender: "me@example.com"),
                             message("b", 2, sender: "alias@example.com"), impostor],
                            own: ["me@example.com", "alias@example.com"])
        XCTAssertEqual(value.peopleTotal, 2)
        XCTAssertEqual(value.people.count, 2)
        XCTAssertTrue(value.people[0].isMe)
        XCTAssertFalse(value.people[1].isMe)
        XCTAssertFalse(value.flags.contains(.lastIsMine))
    }

    func testFirstSixAuthorsKeepOrderAndUnreadAggregationWithTheTrueTotal() {
        var rows = (0..<9).map { message(String($0), Int64($0), sender: "person\($0)@example.com") }
        rows.append(message("again", 100, sender: "person0@example.com", labels: ["UNREAD"]))
        let value = summary(rows)
        XCTAssertEqual(value.peopleTotal, 9)
        XCTAssertEqual(value.people.map(\.a), (0..<6).map { "person\($0)@example.com" })
        XCTAssertTrue(value.people[0].u)
        XCTAssertFalse(value.people[1].u)
    }

    func testRecipientsAreSeparateFromAuthorsAndDeduplicateAcrossToAndCc() {
        var row = message("a", 1)
        row.toAddresses = ["one@example.com", "me@example.com"]
        row.ccAddresses = ["one@example.com", "alias@example.com", "two@example.com"]
        let value = summary([row], own: ["me@example.com", "alias@example.com"])
        XCTAssertEqual(value.people.map(\.a), ["sam@example.com"])
        XCTAssertEqual(value.recipients.map(\.a), ["one@example.com", "me@example.com", "two@example.com"])
        XCTAssertEqual(value.recipientsTotal, 3)
        XCTAssertTrue(value.recipients[1].isMe)
    }

    func testUnreadableSenderNeverUsesTheUntrustedDisplayName() {
        var row = message("a", 1, sender: "")
        row.fromName = "Trusted CEO"
        row.isFromMe = true
        let value = summary([row], own: [""])
        XCTAssertEqual(value.people.count, 1)
        XCTAssertEqual(value.people[0].a, "")
        XCTAssertNil(value.people[0].n)
        XCTAssertFalse(value.people[0].isMe)
        XCTAssertFalse(value.flags.contains(.lastIsMine))
    }

    func testRefusedIntentWinsAndHiddenClaimsSurviveDisplayFiltering() {
        var hidden = message("a", 1, labels: ["TRASH", "STARRED", "DRAFT"], vis: 1)
        hidden.hasRefusedIntent = true
        hidden.bananaLabels = ["Banana/Muted"]
        let value = summary([hidden, message("b", 2)])
        XCTAssertEqual(value.messageCount, 1)
        XCTAssertEqual(value.claims, [.starred, .draft, .bananaLabel, .pendingChange])
        XCTAssertEqual(value.pending, 2, "A hidden refused change must remain visible at conversation level")
        var pending = message("c", 3); pending.hasUndeliveredIntent = true
        var refused = message("d", 4); refused.hasRefusedIntent = true
        XCTAssertEqual(summary([pending, refused]).pending, 2)
        XCTAssertEqual(summary([refused, pending]).pending, 2)
        XCTAssertEqual(summary([pending]).pending, 1)
    }

    func testFlagsComeFromFactsAndSchedulingFieldsRemainUnsetBeforeTheScheduler() {
        var row = message("a", 10, labels: ["INBOX", "STARRED", "IMPORTANT", "DRAFT"])
        row.isFromMe = true; row.hasAttachment = true; row.hasInvite = true
        row.listID = "list.example.com"; row.bananaLabels = ["Banana/Muted"]
        let value = summary([row])
        XCTAssertEqual(value.flags, [.inInbox, .starred, .important, .hasDraft,
                                     .lastIsMine, .hasAttachment, .hasInvite, .isList, .muted])
        XCTAssertNil(value.wakeAt); XCTAssertNil(value.returnedAt); XCTAssertNil(value.waitingUntil)
    }
}
