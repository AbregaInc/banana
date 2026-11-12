import XCTest

@MainActor final class MailReaderModelTests: XCTestCase {
    private final class Source: MailSource {
        var value = MailBody.notOnDevice
        var onChange: (@MainActor (MailConversation?) -> Void)?
        var reads = 0
        var fetched: [MailMessageID] = []
        func fetchBody(_ id: MailMessageID) { fetched.append(id) }
        var suspendFirst = false
        var waiting: CheckedContinuation<MailBody, Never>?
        var began: (() -> Void)?
        func observeConversation(_ id: MailConversationID, _ change: @escaping @MainActor (MailConversation?) -> Void) -> MailObservation {
            onChange = change
            return MailObservation {}
        }
        func body(_ id: MailMessageID) async -> MailBody {
            reads += 1
            if reads == 1 && suspendFirst {
                return await withCheckedContinuation { waiting = $0; began?() }
            }
            return value
        }
    }
    private let id = MailConversationID(account: "a@example.com", thread: "thread")
    private var messageID: MailMessageID { MailMessageID(account: id.account, message: "message") }
    private var text: MailBody { .text(MailText(blocks: []), quoteStartsAt: nil, notices: []) }
    private func conversation(body: MailBodyState) -> MailConversation {
        let person = MailPerson(name: "Sender", address: "sender@example.com", isMe: false, isKnown: false, fromTheirMail: false)
        let message = MailMessage(id: messageID, from: person, to: [], cc: [], bcc: [], replyTo: [], deliveredTo: nil,
            listName: nil, date: Date(timeIntervalSince1970: 0), isUnread: true, isMine: false, firstLine: "Preview",
            body: body, attachments: [], delivery: nil, draft: nil)
        return MailConversation(id: id, subject: "Subject", labels: [], inInbox: true, isStarred: false,
            isImportant: false, isMuted: false, snoozedUntil: nil, system: nil, messages: [message],
            invite: nil, unsubscribe: nil, draft: nil, newestIsMine: false, appliedThrough: 0)
    }
    func testOutgoingAliasesAreExcludedFromSenderBlockingBeforeContactRecognition() {
        var message = conversation(body: .text).messages[0]
        message.isMine = true
        XCTAssertFalse(message.from.isMe)
        XCTAssertTrue(MailMessageDisplay(message).senderIsMe)
        message.isMine = false
        XCTAssertFalse(MailMessageDisplay(message).senderIsMe)
        message.from = MailPerson(name: "Noor", address: id.account, isMe: true, isKnown: true, fromTheirMail: false)
        XCTAssertTrue(MailMessageDisplay(message).senderIsMe)
    }

    func testDownloadedBodyReplacesCachedPlaceholderWithoutReopening() async {
        let source = Source()
        // Keep one observed source for both notifications.
        let observed = MailReaderModel(id: id, source: source)
        source.onChange?(conversation(body: .notOnDevice))
        await observed.waitForBodies()
        XCTAssertEqual(observed.bodies[messageID], .notOnDevice)
        source.value = text
        source.onChange?(conversation(body: .text))
        await observed.waitForBodies()
        XCTAssertEqual(observed.bodies[messageID], text)
    }
    func testUnchangedReadyBodyIsReusedAndRemovedBodyIsEvicted() async {
        let source = Source(); source.value = text
        let reader = MailReaderModel(id: id, source: source)
        source.onChange?(conversation(body: .text))
        await reader.waitForBodies()
        source.onChange?(conversation(body: .text))
        await reader.waitForBodies()
        XCTAssertEqual(source.reads, 1)
        var empty = conversation(body: .text); empty.messages = []
        source.onChange?(empty)
        XCTAssertTrue(reader.bodies.isEmpty)
    }

    func testLateOldReadCannotOverwriteNewBody() async {
        let source = Source(); source.suspendFirst = true
        let started = expectation(description: "First body read suspended")
        source.began = { started.fulfill() }
        let reader = MailReaderModel(id: id, source: source)
        source.onChange?(conversation(body: .notOnDevice))
        await fulfillment(of: [started], timeout: 2)
        source.value = text
        source.onChange?(conversation(body: .text))
        await reader.waitForBodies()
        source.waiting?.resume(returning: .notOnDevice); source.waiting = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(reader.bodies[messageID], text)
    }
    func testRemovedConversationClearsBodiesAndRejectsLateRead() async {
        let source = Source(); source.suspendFirst = true
        let started = expectation(description: "Body read suspended")
        source.began = { started.fulfill() }
        let reader = MailReaderModel(id: id, source: source)
        source.onChange?(conversation(body: .text))
        await fulfillment(of: [started], timeout: 2)
        source.onChange?(nil)
        source.waiting?.resume(returning: text); source.waiting = nil
        await reader.waitForBodies()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(reader.conversation)
        XCTAssertTrue(reader.bodies.isEmpty)
    }
    func testVisibleMissingBodyFetchesOnceAndExplicitRetryStillWorks() async {
        let source = Source()
        let observed = MailReaderModel(id: id, source: source)
        source.onChange?(conversation(body: .notOnDevice))
        await observed.waitForBodies()
        XCTAssertTrue(source.fetched.isEmpty, "Offscreen messages do not start downloads")
        observed.revealBody(messageID)
        observed.revealBody(messageID)
        XCTAssertEqual(source.fetched, [messageID])
        observed.fetchBody(messageID)
        XCTAssertEqual(source.fetched, [messageID, messageID])
        source.value = text
        source.onChange?(conversation(body: .text))
        await observed.waitForBodies()
        XCTAssertEqual(observed.bodies[messageID], text)
    }
    func testVisibleReadyBodyDoesNotDownloadAgain() async {
        let source = Source(); source.value = text
        let reader = MailReaderModel(id: id, source: source)
        source.onChange?(conversation(body: .text))
        await reader.waitForBodies()
        reader.revealBody(messageID)
        XCTAssertTrue(source.fetched.isEmpty)
    }

    func testVisibleBeforeCacheReadFinishesStillFetchesMissingBody() async {
        let source = Source(); source.suspendFirst = true
        let began = expectation(description: "Cache read started")
        source.began = { began.fulfill() }
        let reader = MailReaderModel(id: id, source: source)
        source.onChange?(conversation(body: .text))
        await fulfillment(of: [began], timeout: 2)
        reader.revealBody(messageID)
        XCTAssertTrue(source.fetched.isEmpty)
        source.waiting?.resume(returning: .notOnDevice); source.waiting = nil
        await reader.waitForBodies()
        XCTAssertEqual(source.fetched, [messageID])
    }


    /// Newest first, by date; two at the same moment keep the later-arrived one above.
    func testAConversationIsReadNewestFirst() {
        let person = MailPerson(name: "Sender", address: "sender@example.com", isMe: false, isKnown: false, fromTheirMail: false)
        func at(_ name: String, _ seconds: TimeInterval) -> MailMessage {
            MailMessage(id: MailMessageID(account: id.account, message: name), from: person, to: [], cc: [], bcc: [],
                replyTo: [], deliveredTo: nil, listName: nil, date: Date(timeIntervalSince1970: seconds), isUnread: false,
                isMine: false, firstLine: "", body: .text, attachments: [], delivery: nil, draft: nil)
        }
        let order = MailReadingOrder.newestFirst([at("a", 10), at("b", 30), at("c", 20), at("d", 30)])
        XCTAssertEqual(order.map(\.id.message), ["d", "b", "c", "a"])
        XCTAssertTrue(MailReadingOrder.newestFirst([]).isEmpty)
    }
}
