import XCTest
import GRDB

final class GmailConversationLoaderTests: XCTestCase {
    actor Provider: GmailAPI {
        var full: GmailMessage
        var account = "a@example.com"
        var attachmentBody = GmailPartBody(size: 5, data: "SGVsbG8")
        var attachments: [String] = []
        var fullReads = 0
        var calendarBodies: [String: GmailPartBody] = [:]
        private var holdCalendars = false
        private var calendarGate: CheckedContinuation<Void, Never>?
        func holdCalendarAttachments() { holdCalendars = true }
        func releaseCalendarAttachments() {
            holdCalendars = false
            calendarGate?.resume(); calendarGate = nil
        }
        func calendarCopies(distinct: Bool = false) {
            let first = Data("BEGIN:VCALENDAR\r\nUID:first\r\nEND:VCALENDAR".utf8)
            let second = distinct ? Data("BEGIN:VCALENDAR\r\nUID:other\r\nEND:VCALENDAR".utf8) : first
            func body(_ data: Data) -> GmailPartBody { GmailPartBody(size: data.count, data: data.base64EncodedString()) }
            calendarBodies = ["calendar-a": body(first), "calendar-b": body(second)]
            full.payload?.parts = [GmailPart(partId: "body", mimeType: "text/plain", body: GmailPartBody(size: 5, data: "SGVsbG8")),
                GmailPart(partId: "invite-a", mimeType: "text/calendar", filename: "invite.ics", body: GmailPartBody(attachmentId: "calendar-a", size: first.count)),
                GmailPart(partId: "invite-b", mimeType: "application/ics", filename: "invite.ics", body: GmailPartBody(attachmentId: "calendar-b", size: second.count))]
        }
        init() {
            let json = #"{"id":"m1","threadId":"t1","historyId":"100","internalDate":"1000","labelIds":["INBOX"],"payload":{"partId":"0","mimeType":"multipart/mixed","headers":[{"name":"From","value":"sender@example.com"},{"name":"Subject","value":"Subject"}],"parts":[{"partId":"1","mimeType":"text/plain","body":{"attachmentId":"body-part","size":5}},{"partId":"2","mimeType":"application/pdf","filename":"report.pdf","body":{"attachmentId":"file-part","size":123}}]}}"#
            full = try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        }
        func wrongAccount() { account = "other@example.com" }
        func malformedBody() { attachmentBody.data = "not base64!" }
        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: account, messagesTotal: 1, historyId: 100) }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread {
            XCTAssertEqual(format, .header)
            var metadata = full; metadata.payload?.parts = nil
            return GmailThread(id: "t1", historyId: 100, messages: [metadata])
        }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
            XCTAssertEqual(format, .full); fullReads += 1; return full
        }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody {
            XCTAssertEqual(messageID, "m1"); attachments.append(attachmentID)
            if holdCalendars, calendarBodies[attachmentID] != nil {
                await withCheckedContinuation { calendarGate = $0 }
            }
            return calendarBodies[attachmentID] ?? attachmentBody
        }
        func labels(token: String) async throws -> [GmailLabel] { [] }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { GmailIDPage(messages: [], nextPageToken: nil, resultSizeEstimate: 0) }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { throw GmailError.malformed }
        func trash(token: String, id: String) async throws { throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { throw GmailError.malformed }
    }
    private func setup() async throws -> (MailStores, Provider, GmailConversationLoader) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-full-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let api = Provider()
        return (stores, api, GmailConversationLoader(stores: stores, writer: MailWriter(stores: stores, sink: nil), api: api, token: { _ in "fixture" }))
    }
    private let conversation = MailConversationID(account: "a@example.com", thread: "t1")
    private let message = MailMessageID(account: "a@example.com", message: "m1")

    func testThreadThenExternalBodyCommitsPreparedContentAndUsesWarmCache() async throws {
        let (stores, api, loader) = try await setup()
        let ids = try await loader.thread(conversation)
        XCTAssertEqual(ids, [message])
        try await loader.body(message)
        let prepared = try await MailBlobStore(stores: stores).prepared(account: message.account, messageID: message.message)
        XCTAssertEqual(prepared?.text.blocks.first?.runs.first?.text, "Hello")
        let state = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT fetch_state FROM message") }
        XCTAssertEqual(state, 2)
        let parts = await api.attachments
        XCTAssertEqual(parts, ["body-part"], "Opening mail must not eagerly download attached files")
        try await loader.body(message)
        let reads = await api.fullReads
        XCTAssertEqual(reads, 1)
    }
    func testOriginalCacheRecoversPreparationAndIndexWithoutNetwork() async throws {
        let (stores, api, loader) = try await setup()
        _ = try await loader.thread(conversation)
        try await loader.body(message)
        try await stores.blobs.write { try $0.execute(sql: "DELETE FROM prepared") }
        try await stores.index.write { try $0.execute(sql: "UPDATE message SET fetch_state=1,prep_state=0") }
        await api.wrongAccount() // Any provider request would fail identity validation.
        try await loader.body(message)
        let prepared = try await MailBlobStore(stores: stores).prepared(account: message.account, messageID: message.message)
        XCTAssertEqual(prepared?.text.blocks.first?.runs.first?.text, "Hello")
        let state = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT fetch_state FROM message WHERE prep_state=2") }
        XCTAssertEqual(state, 2)
        let reads = await api.fullReads
        XCTAssertEqual(reads, 1)
    }
    func testCachedCalendarCopiesRequireIdenticalBytesAndKeepOriginalParts() async throws {
        for distinct in [false, true] {
            let (stores, api, loader) = try await setup()
            await api.calendarCopies(distinct: distinct)
            _ = try await loader.thread(conversation)
            try await loader.body(message)
            let before = try await MailConversationReader(stores: stores).conversation(conversation)
            XCTAssertEqual(before?.messages.first?.attachments.count, 2, "names and sizes do not establish equality")
            let coldReads = await api.attachments
            XCTAssertTrue(coldReads.isEmpty, "ordinary body preparation does not download calendar files")
            try await loader.verifyCalendarCopies(message)
            let after = try await MailConversationReader(stores: stores).conversation(conversation)
            XCTAssertEqual(after?.messages.first?.attachments.count, distinct ? 2 : 1)
            let stored = try await MailBlobStore(stores: stores).content(account: message.account, messageID: message.message)
            XCTAssertEqual(stored?.structure.attachments.count, 2, "both original parts remain fetchable")
            XCTAssertTrue(stored?.structure.uncheckedCalendarCopies.isEmpty == true)
            try await loader.verifyCalendarCopies(message)
            let reads = await api.attachments
            XCTAssertEqual(reads, ["calendar-a", "calendar-b"], "fingerprints survive warm cache reads")
            let prepared = try await MailBlobStore(stores: stores).prepared(account: message.account, messageID: message.message)
            XCTAssertNotNil(prepared)
        }
    }

    func testCalendarVerificationFailurePreservesBothFilesAndPreparedBody() async throws {
        let (stores, api, loader) = try await setup()
        await api.calendarCopies()
        _ = try await loader.thread(conversation)
        try await loader.body(message)
        await api.wrongAccount()
        do { try await loader.verifyCalendarCopies(message); XCTFail("wrong mailbox") }
        catch { XCTAssertEqual(error as? GmailConversationLoader.Failure, .wrongAccount) }
        let value = try await MailConversationReader(stores: stores).conversation(conversation)
        XCTAssertEqual(value?.messages.first?.attachments.count, 2)
        let prepared = try await MailBlobStore(stores: stores).prepared(account: message.account, messageID: message.message)
        XCTAssertNotNil(prepared)
    }

    func testWrongAccountNeverImportsThread() async throws {
        let (stores, api, loader) = try await setup()
        await api.wrongAccount()
        do { _ = try await loader.thread(conversation); XCTFail() }
        catch { XCTAssertEqual(error as? GmailConversationLoader.Failure, .wrongAccount) }
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(count, 0)
    }
    func testMalformedExternalBodyNeverPromotesOrStoresCompleteContent() async throws {
        let (stores, api, loader) = try await setup()
        _ = try await loader.thread(conversation)
        await api.malformedBody()
        do { try await loader.body(message); XCTFail() }
        catch { XCTAssertEqual(error as? GmailConversationLoader.Failure, .incompleteBody) }
        let state = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT fetch_state FROM message") }
        let content = try await MailBlobStore(stores: stores).content(account: message.account, messageID: message.message)
        XCTAssertEqual(state, 1); XCTAssertNil(content)
    }
}
