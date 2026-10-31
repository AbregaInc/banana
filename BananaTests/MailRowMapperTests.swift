import XCTest

final class MailRowMapperTests: XCTestCase {
    private let id = MailConversationID(account: "owner@example.com", thread: "thread-1")
    private func summary() -> ThreadSummary {
        ThreadSummary(lastDate: 1_800_000_000_123, messageCount: 3, fetchedCount: 3,
            unreadCount: 1, flags: [.inInbox, .important, .starred, .hasAttachment, .hasInvite, .muted],
            subject: "A stored subject", snippet: "A stored snippet",
            people: [SummaryPerson(n: "me", a: "alias@example.com", u: false, isMe: true),
                     SummaryPerson(n: "me", a: "other@example.com", u: true)],
            peopleTotal: 2, labels: ["INBOX"], wakeAt: 1_900_000_000_000,
            returnedAt: nil, waitingUntil: nil, pending: 2,
            recipients: [SummaryPerson(n: nil, a: "recipient@example.com", u: false)],
            recipientsTotal: 1)
    }
    private func stored() -> IndexRow {
        IndexRow(summary: summary(), id: id, key: MailOrderKey(group: 0, sortKey: 42, tie: -9))
    }
    private func row(_ stored: IndexRow, _ place: MailPlace = .mailbox(.inbox)) -> MailRow {
        MailRowMapper.row(stored, labels: [], reason: nil, in: MailScope(place: place))
    }

    func testDisplayDateDoesNotComeFromTheViewSortKey() {
        var value = stored()
        value.sortKey = (1 << 42) - value.wakeAt!
        let result = row(value, .mailbox(.snoozed))
        XCTAssertEqual(result.date.timeIntervalSince1970, 1_800_000_000.123, accuracy: 0.0001)
        XCTAssertEqual(result.key.sortKey, value.sortKey)
        XCTAssertEqual(result.key.tie, -9)
        XCTAssertEqual(result.id, id)
    }

    func testOwnAliasIdentityDoesNotComeFromTheDisplayedName() {
        let result = row(stored())
        XCTAssertTrue(result.people[0].isMe)
        XCTAssertFalse(result.people[1].isMe)
        XCTAssertEqual(result.people.map(\.name), ["me", "me"])
        XCTAssertFalse(result.people.contains { $0.isKnown || $0.fromTheirMail },
                       "A summary cannot invent address-book or sent-history evidence")
    }

    func testSentDraftsAndOutboxUseRecipientsIncludingSystemLabelRoutes() {
        let value = stored()
        for place in [MailPlace.mailbox(.sent), .mailbox(.drafts), .mailbox(.outbox),
                      .label(account: id.account, id: "SENT"), .label(account: id.account, id: "DRAFT")] {
            let result = row(value, place)
            XCTAssertEqual(result.people.map(\.address), ["recipient@example.com"])
            XCTAssertEqual(result.peopleTotal, 1)
        }
        for place in [MailPlace.mailbox(.inbox), .mailbox(.all), .search("recipient"),
                      .label(account: id.account, id: "Label_9")] {
            XCTAssertEqual(row(value, place).people.map(\.address), ["alias@example.com", "other@example.com"])
        }
    }

    func testSixPersonDisplayKeepsTheTrueCountForBothKindsOfRow() {
        var value = stored()
        value.people = (0..<10).map { SummaryPerson(n: nil, a: "author\($0)", u: false) }
        value.peopleTotal = 10
        value.recipients = (0..<12).map { SummaryPerson(n: nil, a: "recipient\($0)", u: false) }
        value.recipientsTotal = 12
        XCTAssertEqual(row(value).people.count, 6)
        XCTAssertEqual(row(value).peopleTotal, 10)
        XCTAssertEqual(row(value, .mailbox(.sent)).people.count, 6)
        XCTAssertEqual(row(value, .mailbox(.sent)).peopleTotal, 12)
    }

    func testStoredFlagsFailureReasonAndLabelsReachTheRow() {
        let label = MailLabelRef(id: "Label_9", name: "Review", colorHex: nil)
        let result = MailRowMapper.row(stored(), labels: [label], reason: .changeRefused(.signedOut),
                                       in: MailScope(place: .mailbox(.inbox)))
        XCTAssertTrue(result.isUnread && result.isStarred && result.isImportant)
        XCTAssertTrue(result.hasAttachment && result.isInvitation && result.inInbox && result.isMuted)
        XCTAssertTrue(result.hasPendingChange)
        XCTAssertEqual(result.reason, .changeRefused(.signedOut))
        XCTAssertEqual(result.labels, [label])
        XCTAssertEqual(result.subject, "A stored subject")
        XCTAssertEqual(result.snippet, "A stored snippet")
        XCTAssertEqual(result.messageCount, 3)
        XCTAssertTrue(result.isOnDevice)
        XCTAssertFalse(result.fromGmailSearch)
    }

    func testLocalDatabaseIdentityNeverLeaksIntoConversationIdentity() {
        var value = stored()
        let before = row(value)
        value.threadPK = 999_999; value.labelPKs = [4, 8, 15]
        XCTAssertEqual(row(value), before)
    }
}
