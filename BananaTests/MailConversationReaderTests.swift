import XCTest
import GRDB

final class MailConversationReaderTests: XCTestCase {
    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-conversation-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    private func message() throws -> GmailMessage {
        let json = #"{"id":"m1","threadId":"t1","historyId":"100","internalDate":"1000","labelIds":["INBOX","UNREAD"],"snippet":"Preview","payload":{"partId":"0","mimeType":"multipart/mixed","headers":[{"name":"From","value":"Sender <sender@example.com>"},{"name":"Subject","value":"Subject"},{"name":"To","value":"a@example.com"},{"name":"Bcc","value":"hidden@example.com"},{"name":"Reply-To","value":"reply@example.com"},{"name":"Delivered-To","value":"a@example.com"}],"parts":[{"partId":"1","mimeType":"text/plain","body":{"data":"SGVsbG8"}},{"partId":"2","mimeType":"application/pdf","filename":"report.pdf","body":{"attachmentId":"remote","size":123}}]}}"#
        return try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }
    private func importMessage(_ message: GmailMessage, stores: MailStores) async throws {
        let fetched = FetchedMessage(wire: message, floor: 100, headers: MessageHeaders(payload: message.payload), structure: nil)
        _ = try await MailWriter(stores: stores, sink: nil).transact { db in
            try MailMessageImporter.apply(fetched, account: "a@example.com", myAddresses: ["a@example.com"], in: db)
        }
    }
    func testCachedHeadersAreReadableBeforeBodyAndAccountIsIsolated() async throws {
        let stores = try await stores(), wire = try message()
        try await importMessage(wire, stores: stores)
        let reader = MailConversationReader(stores: stores)
        let value = try await reader.conversation(MailConversationID(account: "a@example.com", thread: "t1"))
        XCTAssertEqual(value?.subject, "Subject")
        XCTAssertEqual(value?.messages.first?.from.address, "sender@example.com")
        XCTAssertEqual(value?.messages.first?.bcc.first?.address, "hidden@example.com")
        XCTAssertEqual(value?.messages.first?.body, .notOnDevice)
        XCTAssertTrue(value?.messages.first?.isUnread == true)
        XCTAssertTrue(value?.messages.first?.to.first?.isMe == true)
        let other = try await reader.conversation(MailConversationID(account: "b@example.com", thread: "t1"))
        XCTAssertNil(other)
    }
    func testOneTrashedMessageDoesNotMarkActiveConversationAsTrashed() async throws {
        let stores = try await stores()
        var wire = try message()
        try await importMessage(wire, stores: stores)
        wire.id = "m2"; wire.labelIds = ["TRASH"]; wire.internalDate = 2000
        try await importMessage(wire, stores: stores)
        let value = try await MailConversationReader(stores: stores).conversation(MailConversationID(account: "a@example.com", thread: "t1"))
        XCTAssertTrue(value?.inInbox == true)
        XCTAssertNil(value?.system)
        XCTAssertEqual(value?.messages.count, 2)
    }

    func testMetadataAndPreparedStateDoNotReadRawBodyColumns() async throws {
        let stores = try await stores(), wire = try message()
        try await importMessage(wire, stores: stores)
        let blobs = MailBlobStore(stores: stores)
        try await blobs.put(wire, account: "a@example.com", extraction: MIMEStructure.extract(wire.payload!), ftsRowID: 1, at: 1000)
        _ = try await blobs.prepare(account: "a@example.com", messageID: "m1", at: 1001)
        // Deliberately corrupt only raw-body storage. Metadata projection must not decompress it.
        try await stores.blobs.write { db in try db.execute(sql: "UPDATE content SET plain=X'00',html=X'00'") }
        let value = try await MailConversationReader(stores: stores).conversation(MailConversationID(account: "a@example.com", thread: "t1"))
        XCTAssertEqual(value?.messages.first?.body, .text)
        XCTAssertEqual(value?.messages.first?.replyTo.first?.address, "reply@example.com")
        XCTAssertEqual(value?.messages.first?.deliveredTo, "a@example.com")
        XCTAssertEqual(value?.messages.first?.attachments.first?.name, "report.pdf")
        XCTAssertEqual(value?.messages.first?.attachments.first?.bytes, 123)
        let body = try await blobs.prepared(account: "a@example.com", messageID: "m1")
        XCTAssertEqual(body?.text.blocks.first?.runs.first?.text, "Hello")
    }
}
