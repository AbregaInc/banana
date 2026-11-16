import XCTest

@MainActor final class MailReaderModelTests: XCTestCase {
    func testQuoteFoldingKeepsFollowingContentAndOriginalIndices() {
        let blocks = [MailTextBlock(kind: .paragraph, runs: []),
                      MailTextBlock(kind: .quote(depth: 1), runs: []),
                      MailTextBlock(kind: .quote(depth: 2), runs: []),
                      MailTextBlock(kind: .paragraph, runs: [])]
        XCTAssertEqual(MailQuoteFolding.hiddenRange(in: blocks, from: 1, expanded: false), 1..<3)
        XCTAssertNil(MailQuoteFolding.hiddenRange(in: blocks, from: 1, expanded: true))
        for start in [nil, -1, 0, 3, 4] as [Int?] {
            XCTAssertNil(MailQuoteFolding.hiddenRange(in: blocks, from: start, expanded: false))
        }
    }

    private final class Source: MailSource {
        var value = MailBody.notOnDevice
        var onChange: (@MainActor (MailConversation?) -> Void)?
        var reads = 0
        var fetched: [MailMessageID] = []
        func fetchBody(_ id: MailMessageID) { fetched.append(id) }
        var values: [MailMessageID: MailBody] = [:]
        var suspendMessage: MailMessageID?
        var suspendFirst = false
        var waiting: CheckedContinuation<MailBody, Never>?
        var began: (() -> Void)?
        func observeConversation(_ id: MailConversationID, _ change: @escaping @MainActor (MailConversation?) -> Void) -> MailObservation {
            onChange = change
            return MailObservation {}
        }
        func body(_ id: MailMessageID) async -> MailBody {
            reads += 1
            if (reads == 1 && suspendFirst) || suspendMessage == id {
                return await withCheckedContinuation { waiting = $0; began?() }
            }
            return values[id] ?? value
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

    func testBlankSenderNameFallsBackToAddress() {
        var message = conversation(body: .text).messages[0]
        for name in ["", "  \n "] {
            message.from.name = name
            XCTAssertEqual(MailMessageDisplay(message).sender, message.from.address)
            let row = MailRow(id: id, key: MailOrderKey(group: 0, sortKey: 0, tie: 0), date: message.date,
                people: [message.from], peopleTotal: 1, messageCount: 1, subject: "Subject", snippet: "",
                isUnread: false, isStarred: false, isImportant: false, hasAttachment: false, isInvitation: false,
                inInbox: true, isMuted: false, hasPendingChange: false, fromGmailSearch: false, labels: [], reason: nil)
            XCTAssertEqual(MailRowDisplay.who(for: row), message.from.address)
        }
        message.from.name = " Noor "
        XCTAssertEqual(MailMessageDisplay(message).sender, "Noor")
    }

    func testInlineImagesDoNotCrowdTheAttachmentHeaderButRemainAvailable() {
        var message = conversation(body: .text).messages[0]
        func file(_ part: String, inline: Bool, mime: String = "image/jpeg",
                  mismatch: Bool = false, executable: Bool = false) -> MailAttachment {
            MailAttachment(id: MailAttachmentID(message: message.id, part: part), name: part + ".jpg",
                mimeType: mime, typeMismatch: mismatch, bytes: 100, localFile: nil,
                isInline: inline, isExecutable: executable)
        }
        message.attachments = [file("inline", inline: true), file("photo", inline: false),
                               file("document", inline: true, mime: "application/pdf"),
                               file("mismatch", inline: true, mismatch: true),
                               file("program", inline: true, executable: true)]
        let display = MailMessageDisplay(message)
        XCTAssertEqual(display.inlineImages.map(\.id.part), ["inline"])
        XCTAssertEqual(display.files.map(\.id.part), ["photo", "document", "mismatch", "program"])
        XCTAssertEqual(display.attachments.count, 4)
        XCTAssertEqual(display.files.last?.isProgram, true)
    }

    func testReportHTMLDispatchCanKeepRawMarkupSeparateFromTheSafeOriginal() async throws {
        final class ReportingSource: MailSource {
            func originalHTML(_ id: MailMessageID) async throws -> String? { "<p>safe</p>" }
            func reportHTML(_ id: MailMessageID) async throws -> String? { "<img src=\"cid:picture\">" }
        }
        let source: MailSource = ReportingSource()
        let raw = try await source.reportHTML(messageID)
        let original = try await source.originalHTML(messageID)
        XCTAssertEqual(raw, "<img src=\"cid:picture\">")
        XCTAssertEqual(original, "<p>safe</p>")
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
    func testAutosavedDraftStaysInTheComposerInsteadOfDuplicatingAMessageCard() async {
        let source = Source(); source.value = text
        let reader = MailReaderModel(id: id, source: source)
        var value = conversation(body: .text)
        let draftID = MailDraftID(raw: "reply-draft")
        let draftMessage = MailMessageID(account: id.account, message: "local-draft")
        var draft = MailMessage(id: draftMessage, from: value.messages[0].from, to: [], cc: [], bcc: [],
            replyTo: [], deliveredTo: nil, listName: nil, date: Date(timeIntervalSince1970: 1),
            isUnread: false, isMine: true, firstLine: "Work in progress", body: .text,
            attachments: [], delivery: nil, draft: draftID)
        value.messages.append(draft); value.draft = draftID
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.map(\.id), [messageID])
        XCTAssertEqual(reader.conversation?.draft, draftID, "Closing the composer still offers Continue")
        XCTAssertNil(reader.bodies[draftMessage]); XCTAssertEqual(source.reads, 1)
        // Gmail may sync the remote copy before its local editable id is attached.
        draft.draft = nil; draft.isUnsentDraft = true; value.messages[1] = draft
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.map(\.id), [messageID])
        XCTAssertNil(reader.bodies[draftMessage]); XCTAssertEqual(source.reads, 1)
        draft.firstLine = "More typing"; value.messages[1] = draft
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.map(\.id), [messageID])
        XCTAssertEqual(source.reads, 1, "Autosave must not fetch or render another copy of the draft")
        draft.delivery = .held(until: Date(timeIntervalSince1970: 10)); value.messages[1] = draft
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.map(\.id), [draftMessage, messageID])
        XCTAssertEqual(reader.messages.first?.deliveryText, "Queued")
        draft.delivery = .waitingForNetwork; value.messages[1] = draft
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.first?.deliveryText, "Waiting for connection")
        draft.delivery = .failed(.other); value.messages[1] = draft
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.first?.deliveryText, "Not sent", "Failures remain visible for retry")
        draft.delivery = nil; value.messages[1] = draft
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.map(\.id), [messageID], "Undo returns it to the composer/marker")
        XCTAssertNil(reader.bodies[draftMessage])
        draft.draft = nil; draft.isUnsentDraft = false; value.messages[1] = draft; value.draft = nil
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.map(\.id), [draftMessage, messageID], "A sent message stays visible")
    }

    func testHiddenDraftDoesNotPromoteAnOlderVerificationCode() async {
        let source = Source()
        source.value = .text(MailText(blocks: [.init(kind: .paragraph, runs: [.init(text: "Verification code: 042819")])]), quoteStartsAt: nil, notices: [])
        let reader = MailReaderModel(id: id, source: source)
        var value = conversation(body: .text)
        var draft = value.messages[0]
        draft = MailMessage(id: .init(account: id.account, message: "draft"), from: draft.from,
            to: [], cc: [], bcc: [], replyTo: [], deliveredTo: nil, listName: nil,
            date: Date(timeIntervalSince1970: 1), isUnread: false, isMine: true,
            firstLine: "Reply", body: .text, attachments: [], delivery: nil,
            draft: .init(raw: "draft"))
        // Provider draft status must win even before alias recognition or local linking.
        draft.draft = nil; draft.isUnsentDraft = true; draft.isMine = false
        value.messages.append(draft)
        source.onChange?(value); await reader.waitForBodies()
        XCTAssertEqual(reader.messages.map(\.id), [messageID])
        XCTAssertNil(reader.verificationCode)
    }

    func testCodeUsesNewestIncomingMessageAndClearsForAnOutgoingReply() async {
        let source = Source()
        source.value = .text(MailText(blocks: [.init(kind: .paragraph, runs: [.init(text: "Verification code: 042819")])]), quoteStartsAt: nil, notices: [])
        let reader = MailReaderModel(id: id, source: source)
        var incoming = conversation(body: .text)
        source.onChange?(incoming)
        await reader.waitForBodies()
        XCTAssertEqual(reader.verificationCode?.value, "042819")
        var reply = incoming.messages[0]
        reply = MailMessage(id: .init(account: id.account, message: "newer"), from: reply.from, to: [], cc: [], bcc: [], replyTo: [], deliveredTo: nil, listName: nil, date: reply.date.addingTimeInterval(1), isUnread: false, isMine: true, firstLine: "Thanks", body: .text, attachments: [], delivery: nil, draft: nil)
        incoming.messages.append(reply)
        source.onChange?(incoming)
        XCTAssertNil(reader.verificationCode, "An older code disappears before the new body is read")
        await reader.waitForBodies()
        XCTAssertNil(reader.verificationCode)
    }
    func testNewIncomingReplyDoesNotPromoteTheOriginalSubjectsCode() async {
        let source = Source()
        source.value = text
        let reader = MailReaderModel(id: id, source: source)
        var value = conversation(body: .text)
        value.subject = "Verification code: 042819"
        source.onChange?(value)
        await reader.waitForBodies()
        XCTAssertEqual(reader.verificationCode?.value, "042819")
        let old = value.messages[0]
        value.messages.append(MailMessage(id: .init(account: id.account, message: "reply"), from: old.from, to: [], cc: [], bcc: [], replyTo: [], deliveredTo: nil, listName: nil, date: old.date.addingTimeInterval(1), isUnread: true, isMine: false, firstLine: "Thanks", body: .text, attachments: [], delivery: nil, draft: nil))
        source.onChange?(value)
        XCTAssertNil(reader.verificationCode)
        await reader.waitForBodies()
        XCTAssertNil(reader.verificationCode)
    }

    func testCodeAppearsBeforeOlderBodiesFinishLoading() async {
        let source = Source()
        let codeBody = MailBody.text(MailText(blocks: [.init(kind: .paragraph, runs: [.init(text: "Verification code: 042819")])]), quoteStartsAt: nil, notices: [])
        source.values[messageID] = codeBody
        let oldID = MailMessageID(account: id.account, message: "older")
        source.suspendMessage = oldID
        let started = expectation(description: "older body read suspended")
        source.began = { started.fulfill() }
        var value = conversation(body: .text)
        let old = value.messages[0]
        value.messages.append(MailMessage(id: oldID, from: old.from, to: [], cc: [], bcc: [], replyTo: [], deliveredTo: nil, listName: nil, date: old.date.addingTimeInterval(-1), isUnread: false, isMine: false, firstLine: "Older", body: .text, attachments: [], delivery: nil, draft: nil))
        let reader = MailReaderModel(id: id, source: source)
        source.onChange?(value)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(reader.verificationCode?.value, "042819", "Reading old history must not delay the top code")
        source.waiting?.resume(returning: text); source.waiting = nil
        await reader.waitForBodies()
    }

    func testUnchangedHeadersReuseTheCodeAndChangedSubjectUsesTheCachedBody() async {
        let source = Source()
        source.value = .text(MailText(blocks: [.init(kind: .paragraph, runs: [.init(text: "042819")])]), quoteStartsAt: nil, notices: [])
        let reader = MailReaderModel(id: id, source: source)
        var value = conversation(body: .text)
        value.subject = "Your verification code"
        source.onChange?(value)
        await reader.waitForBodies()
        XCTAssertEqual(reader.verificationCode?.value, "042819")
        let reads = source.reads
        value.messages[0].isUnread = false
        source.onChange?(value)
        await reader.waitForBodies()
        XCTAssertEqual(reader.verificationCode?.value, "042819")
        XCTAssertEqual(source.reads, reads)
        value.subject = "Order receipt"
        source.onChange?(value)
        XCTAssertNil(reader.verificationCode)
        await reader.waitForBodies()
        XCTAssertNil(reader.verificationCode)
        XCTAssertEqual(source.reads, reads, "Changing the header must not re-read a ready body")
    }

    func testLateCodeCannotSurviveConversationRemoval() async {
        let source = Source(); source.suspendFirst = true
        let started = expectation(description: "code read suspended")
        source.began = { started.fulfill() }
        let reader = MailReaderModel(id: id, source: source)
        source.onChange?(conversation(body: .text))
        await fulfillment(of: [started], timeout: 2)
        source.onChange?(nil)
        source.waiting?.resume(returning: .text(MailText(blocks: [.init(kind: .paragraph, runs: [.init(text: "Verification code: 042819")])]), quoteStartsAt: nil, notices: []))
        source.waiting = nil
        await reader.waitForBodies()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(reader.verificationCode)
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
