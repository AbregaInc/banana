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
    func testProviderDraftStateSurvivesBeforeItsEditableRecordExists() async throws {
        let stores = try await stores()
        var wire = try message()
        try await importMessage(wire, stores: stores)
        wire.id = "provider-draft"; wire.labelIds = ["DRAFT"]; wire.internalDate = 2000
        try await importMessage(wire, stores: stores)
        let value = try await MailConversationReader(stores: stores).conversation(
            MailConversationID(account: "a@example.com", thread: "t1"))
        let draft = try XCTUnwrap(value?.messages.first { $0.id.message == "provider-draft" })
        XCTAssertTrue(draft.isUnsentDraft)
        XCTAssertNil(draft.draft, "Provider draft status does not invent a local editable id")
        XCTAssertFalse(try XCTUnwrap(value?.messages.first { $0.id.message == "m1" }).isUnsentDraft)
    }

    func testCachedPreviewDecodesEntitiesBeforeTheBodyArrives() async throws {
        let stores = try await stores()
        var wire = try message(); wire.snippet = "We&#39;ve got tea &amp; coffee"
        try await importMessage(wire, stores: stores)
        let value = try await MailConversationReader(stores: stores).conversation(MailConversationID(account: "a@example.com", thread: "t1"))
        XCTAssertEqual(value?.messages.first?.firstLine, "We've got tea & coffee")
    }

    func testEachMessageKeepsItsOwnBlindRecipientsAndPreparationState() async throws {
        let stores = try await stores()
        var wire = try message()
        try await importMessage(wire, stores: stores)
        wire.id = "m2"
        wire.internalDate = 2000
        try await importMessage(wire, stores: stores)
        try await stores.index.write { db in
            try db.execute(sql: "UPDATE message SET prep_state=1 WHERE gmail_id='m1'")
            try db.execute(sql: "UPDATE message SET recipients=NULL WHERE gmail_id='m2'")
        }
        let reader = MailConversationReader(stores: stores)
        let conversation = try await reader.conversation(.init(account: "a@example.com", thread: "t1"))
        let first = try XCTUnwrap(conversation?.messages.first { $0.id.message == "m1" })
        let second = try XCTUnwrap(conversation?.messages.first { $0.id.message == "m2" })
        XCTAssertEqual(first.bcc.map(\.address), ["hidden@example.com"])
        XCTAssertEqual(first.body, .preparing)
        XCTAssertTrue(second.bcc.isEmpty)
        XCTAssertEqual(second.body, .notOnDevice)
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

    func testUserLabelsFollowEffectiveMessagesAndUseTheirOwnAccountsCatalog() async throws {
        let stores = try await stores()
        var first = try message()
        first.labelIds = ["INBOX", "shared", "remove", "refused"]
        try await importMessage(first, stores: stores)
        var second = first
        second.id = "m2"
        second.labelIds = ["shared", "TRASH", "trash-only"]
        try await importMessage(second, stores: stores)
        let localID = #"local:Trip "A" / été"#
        try await stores.index.write { db in
            let accountPK = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT account_pk FROM account WHERE email=?", arguments: ["a@example.com"]))
            let messagePK = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT msg_pk FROM message WHERE account_pk=? AND gmail_id='m1'", arguments: [accountPK]))
            try db.execute(sql: "UPDATE label SET name='Revised',background_color='#ffeeaa' WHERE account_pk=? AND gmail_id='shared'", arguments: [accountPK])
            try db.execute(sql: "INSERT INTO label(account_pk,gmail_id,name,kind) VALUES (?,?,?,1)", arguments: [accountPK, localID, "Local"])
            try db.execute(sql: "INSERT INTO account(email) VALUES ('other@plan.example')")
            try db.execute(sql: "INSERT INTO label(account_pk,gmail_id,name,kind) VALUES (?,'shared','Another account',1)", arguments: [db.lastInsertedRowID])
            for (id, want, refused) in [(localID, true, false), ("remove", false, false), ("refused", false, true)] {
                try db.execute(sql: """
                    INSERT INTO overlay(msg_pk,label_pk,want,refused)
                    SELECT ?,label_pk,?,? FROM label WHERE account_pk=? AND gmail_id=?
                    """, arguments: [messagePK, want, refused, accountPK, id])
            }
        }
        let id = MailConversationID(account: "a@example.com", thread: "t1")
        let conversation = try await MailConversationReader(stores: stores).conversation(id)
        let labels = try XCTUnwrap(conversation).labels
        XCTAssertEqual(labels.map(\.id), [localID, "refused", "shared", "trash-only"].sorted())
        XCTAssertEqual(labels.first { $0.id == "shared" }?.name, "Revised")
        XCTAssertEqual(labels.first { $0.id == "shared" }?.colorHex, "#ffeeaa")
    }

    func testBrowserFreeUnsubscribeRequiresOneMatchedSignatureCoveringBothHeaders() throws {
        let url = try XCTUnwrap(URL(string: "https://lists.plan.example/unsubscribe"))
        let auth = ("Authentication-Results", "mx.google.com; dkim=pass header.i=@plan.example header.s=list header.b=abcdefgh")
        let signature = ("DKIM-Signature", "v=1; d=plan.example; s=list; h=from:list-unsubscribe:list-unsubscribe-post; b=abcdefghijklmnop")
        let post = ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
        let headers = [("From", "Noor <noor@plan.example>"), ("List-Id", "Updates <list.plan.example>"),
                       ("List-Unsubscribe", "<https://lists.plan.example/unsubscribe>")]
        XCTAssertEqual(MailUnsubscribeRules.decide(headers: MessageHeaders(headers + [auth, signature, post])), .oneClick(url))
        let unsignedPost = ("DKIM-Signature", "d=plan.example; s=list; h=from:list-unsubscribe; b=abcdefghijklmnop")
        XCTAssertEqual(MailUnsubscribeRules.decide(headers: MessageHeaders(headers + [auth, unsignedPost, post])), .openPage(url))
        XCTAssertEqual(MailUnsubscribeRules.decide(headers: MessageHeaders(headers + [auth, signature, signature, post])), .openPage(url))
        XCTAssertEqual(MailUnsubscribeRules.decide(headers: MessageHeaders(headers + [auth, signature, post, post])), .openPage(url))
        let otherHost = try XCTUnwrap(URL(string: "https://notplan.example/unsubscribe"))
        XCTAssertEqual(MailUnsubscribeRules.decide(headers: MessageHeaders(Array(headers.dropLast()) +
            [("List-Unsubscribe", "<https://notplan.example/unsubscribe>"), auth, signature, post])), .openPage(otherHost))
    }

    func testListUnsubscribeUsesTheNewestReceivedMessageAndHTTPS() async throws {
        let stores = try await stores()
        var wire = try message()
        let url = try XCTUnwrap(URL(string: "https://plan.example/unsubscribe"))
        wire.payload?.headers?.append(GmailHeader(name: "List-Unsubscribe",
            value: "<mailto:leave@plan.example>, <www.plan.example>, <" + url.absoluteString + ">"))
        try await importMessage(wire, stores: stores)
        let blobs = MailBlobStore(stores: stores)
        try await blobs.put(wire, account: "a@example.com", extraction: MIMEStructure.extract(try XCTUnwrap(wire.payload)),
                            ftsRowID: 1, at: 1000)
        let id = MailConversationID(account: "a@example.com", thread: "t1")
        let conversation = try await MailConversationReader(stores: stores).conversation(id)
        XCTAssertEqual(conversation?.unsubscribe, .openPage(url))
        let insecure = MessageHeaders([("List-Unsubscribe", "<http://plan.example/unsubscribe>")])
        XCTAssertNil(MailUnsubscribeRules.decide(headers: insecure))
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
