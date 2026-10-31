import XCTest

@MainActor final class MailReaderModelTests: XCTestCase {
    private final class Source: MailSource {
        var value = MailBody.notOnDevice
        var onChange: (@MainActor (MailConversation?) -> Void)?
        var reads = 0
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
}
