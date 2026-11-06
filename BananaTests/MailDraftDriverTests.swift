import XCTest

final class MailDraftDriverTests: XCTestCase {
    private actor Provider: GmailDraftAPI, GmailAPI {
        var requests: [GmailDraftMutation] = []
        var loseReply = false
        var fetched: GmailDraftValue?
        var listing: GmailDraftPage?
        var reads = 0
        var parts: [(String, String, Int)] = []
        var losePart = false
        func setLostPart(_ value: Bool) { losePart = value }
        func uploadDraftPart(token: String, operationID: String, hash: String, data: Data) async throws {
            parts.append((operationID, hash, data.count))
            if losePart { throw GmailError.unknownOutcome }
        }
        var missing = false
        func setMissing(_ value: Bool) { missing = value }
        func setListing(_ value: GmailDraftPage) { listing = value }
        func setFetched(_ value: GmailDraftValue) { fetched = value }
        var onWrite: (@Sendable () async throws -> Void)?
        func setLost(_ value: Bool) { loseReply = value }
        func setHook(_ value: @escaping @Sendable () async throws -> Void) { onWrite = value }
        func drafts(token: String, pageToken: String?) async throws -> GmailDraftPage { guard let listing else { throw GmailError.networkDisabled }; return listing }
        func draft(token: String, id: String) async throws -> GmailDraftValue { if missing { throw GmailError.notFound }; guard let fetched else { throw GmailError.networkDisabled }; reads += 1; return fetched }
        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: "noor@plan.example") }
        func labels(token: String) async throws -> [GmailLabel] { [] }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { GmailIDPage(messages: []) }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.networkDisabled }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage { guard let fetched else { throw GmailError.networkDisabled }; return fetched.message }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.networkDisabled }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { GmailPartBody(size: 42, data: Data(repeating: 7, count: 42).base64EncodedString()) }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { throw GmailError.networkDisabled }
        func trash(token: String, id: String) async throws { throw GmailError.networkDisabled }
        func untrash(token: String, id: String) async throws { throw GmailError.networkDisabled }
        func mutateDraft(token: String, request: GmailDraftMutation) async throws -> Data {
            requests.append(request)
            if let hook = onWrite { onWrite = nil; try await hook() }
            if loseReply { throw GmailError.unknownOutcome }
            if request.action == .send { return Data(#"{"id":"sent","labelIds":["SENT"]}"#.utf8) }
            return try JSONEncoder().encode(GmailDraftReference(id: request.id ?? "gmail-draft", message: .init(id: request.operationID, threadId: "thread")))
        }
    }
    private func draft() -> MailDraft {
        let id = MailDraftID(raw: UUID().uuidString)
        return MailDraft(id: id, conversation: .init(account: "noor@plan.example", thread: "local:" + id.raw),
            account: "noor@plan.example", isReply: false, isForward: false,
            from: .init(account: "noor@plan.example", address: "noor@plan.example", name: "Noor", isDefault: true, hasSignature: false),
            to: [], cc: [], bcc: [], subject: "First", body: .init(blocks: []), signature: nil, quote: nil,
            attachments: [], format: .banana, schedule: nil, remindIfNoReply: nil, delivery: nil, encodedBytes: 0, editedAt: Date())
    }
    private func setup() async throws -> (MailDirectories, MailIntentStore, Provider) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-draft-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let values = try await Task.detached { () -> (MailDirectories, MailIntentStore) in
            let directories = try MailDirectories(root: root)
            return (directories, try MailIntentStore(directories: directories))
        }.value
        return (values.0, values.1, Provider())
    }
    private func driver(_ store: MailIntentStore, _ api: Provider, scope: String = "account-context") -> MailDraftDriver {
        MailDraftDriver(scope: scope, store: store, api: api, token: { _ in "routing-reference" }, allowed: { _ in true }, compose: { snapshot in
            GmailDraftComposition(from: .init(address: snapshot.account), to: [], cc: [], bcc: [], subject: snapshot.subject,
                plain: snapshot.subject, html: "", attachments: [], inReplyTo: nil, references: nil, threadID: nil)
        })
    }
    private func remote(_ version: String, subject: String, attachment: Bool = false) -> GmailDraftValue {
        let body = GmailPart(partId: "body", mimeType: "text/plain", body: GmailPartBody(size: 5, data: Data("Hello".utf8).base64EncodedString()))
        let payload = GmailPart(mimeType: "multipart/mixed", headers: [GmailHeader(name: "Subject", value: subject)],
            parts: attachment ? [body, GmailPart(partId: "file", mimeType: "application/pdf", filename: "notes.pdf", body: GmailPartBody(attachmentId: "file-id", size: 42))] : [body])
        return GmailDraftValue(id: "remote-draft", message: GmailMessage(id: version, threadId: "thread", internalDate: 1000, payload: payload))
    }
    func testRemoteDraftKeepsIdentityAcrossUpdatesAndSendsOriginalAttachments() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api)
        try await source.importDraft(remote("v1", subject: "Original", attachment: true), account: "noor@plan.example")
        let first = try await source.records(); let id = try XCTUnwrap(first.first?.snapshot.id)
        try await source.importDraft(remote("v2", subject: "Newer", attachment: true), account: "noor@plan.example")
        let records = try await source.records()
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.snapshot.id, id)
        XCTAssertEqual(records.first?.snapshot.subject, "Newer")
        XCTAssertEqual(records.first?.snapshot.attachments.first?.name, "notes.pdf")
        var opened = try XCTUnwrap(records.first?.snapshot.value); opened.editedAt = Date()
        try await source.save(opened)
        try await source.queueSend(id, options: .init(hold: 0, thenDone: false))
        try await source.flush(id, now: Date.distantFuture)
        let requests = await api.requests
        XCTAssertEqual(requests.map(\.action), [.send])
        XCTAssertEqual(requests.first?.expectedMessageID, "v2"); XCTAssertNil(requests.first?.content)
    }
    func testRemoteChangePreservesUnsavedLocalCompositionAndMarksConflict() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api); var local = draft()
        try await source.create(local); try await source.flush(local.id)
        local.subject = "Local precious edit"; try await source.save(local)
        var incoming = remote("other-version", subject: "Other device")
        incoming.id = "gmail-draft"
        try await source.importDraft(incoming, account: local.account)
        let value = try await source.record(local.id)
        XCTAssertEqual(value?.snapshot.subject, "Local precious edit"); XCTAssertEqual(value?.conflict, true)
        try await source.flush(local.id)
        let requests = await api.requests; XCTAssertEqual(requests.count, 1)
    }
    func testExplicitConflictResolutionUsesFreshProviderVersionAndNeverAutoSends() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api); var local = draft()
        try await source.create(local); try await source.flush(local.id)
        local.subject = "Keep this"; try await source.save(local)
        var incoming = remote("v2", subject: "Other device"); incoming.id = "gmail-draft"
        try await source.importDraft(incoming, account: local.account); await api.setFetched(incoming)
        try await source.resolveConflict(local.id, keepMine: true)
        try await source.flush(local.id)
        let requests = await api.requests
        XCTAssertEqual(requests.map(\.action), [.create, .update])
        XCTAssertEqual(requests.last?.expectedMessageID, "v2")
        XCTAssertEqual(requests.last?.content?.subject, "Keep this")
        local.subject = "Another local edit"; try await source.save(local)
        incoming.message.id = "v3"; incoming.message.payload?.headers = [GmailHeader(name: "Subject", value: "Use this instead")]
        try await source.importDraft(incoming, account: local.account); await api.setFetched(incoming)
        try await source.resolveConflict(local.id, keepMine: false)
        let resolved = try await source.record(local.id)
        XCTAssertEqual(resolved?.snapshot.subject, "Use this instead")
        XCTAssertEqual(resolved?.state, .editing); XCTAssertEqual(resolved?.conflict, false)
        XCTAssertEqual(resolved?.needsDelivery, false)
    }
    func testProviderListingImportsChangedVersionsWithoutRepeatedBodyReads() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api)
        let wire = remote("v1", subject: "Cross-device draft")
        await api.setFetched(wire)
        await api.setListing(GmailDraftPage(drafts: [.init(id: wire.id, message: wire.message)], nextPageToken: "next"))
        let cursor = try await source.syncPage(account: "noor@plan.example")
        XCTAssertEqual(cursor, "next")
        _ = try await source.syncPage(account: "noor@plan.example")
        let reads = await api.reads; XCTAssertEqual(reads, 1)
        let records = try await source.records()
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.snapshot.subject, "Cross-device draft")
    }

    func testConfirmedExternalDeletionRemovesCleanDraftButPreservesDirtyDraft() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api)
        try await source.importDraft(remote("v1", subject: "Other device draft"), account: "noor@plan.example")
        await api.setMissing(true)
        try await source.finishScan(account: "noor@plan.example", scan: "complete-list")
        let imported = try await source.records()
        XCTAssertEqual(imported.first?.state, .deleted)
        var local = draft(); try await source.create(local); try await source.flush(local.id)
        local.subject = "Keep local edit"; try await source.save(local)
        try await source.finishScan(account: local.account, scan: "next-complete-list")
        let conflict = try await source.record(local.id)
        XCTAssertEqual(conflict?.conflict, true); XCTAssertEqual(conflict?.snapshot.subject, "Keep local edit")
        try await source.resolveConflict(local.id, keepMine: true)
        let recovered = try await source.record(local.id)
        XCTAssertEqual(recovered?.state, .editing); XCTAssertNil(recovered?.remote)
        XCTAssertEqual(recovered?.snapshot.subject, "Keep local edit")
        let requests = await api.requests; XCTAssertFalse(requests.contains { $0.action == .send })
    }

    func testUnconfirmedDisappearanceNeverDeletesCachedDraft() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api)
        try await source.importDraft(remote("v1", subject: "Still kept"), account: "noor@plan.example")
        do { try await source.finishScan(account: "noor@plan.example", scan: "complete-list"); XCTFail("Read unavailable") } catch {}
        let records = try await source.records(); XCTAssertEqual(records.first?.state, .editing)
    }

    func testAttachmentCopyAndPendingPartsSurviveSourceRemovalAndNewerEdits() async throws {
        let (directories, store, api) = try await setup(); let source = driver(store, api); let local = draft()
        try await source.create(local)
        let original = directories.root.appendingPathComponent("notes.txt")
        try Data(repeating: 42, count: MailDraftFiles.chunkBytes + 3).write(to: original)
        let kept = try await source.addAttachment(original, to: local.id)
        XCTAssertNotEqual(kept.file, original)
        try FileManager.default.removeItem(at: original)
        await api.setLostPart(true)
        do { try await source.flush(local.id); XCTFail("Part acknowledgement lost") } catch {}
        let pending = try await source.record(local.id)
        XCTAssertEqual(pending?.pending?.content?.attachments.first?.chunks.count, 2)
        XCTAssertEqual(pending?.pendingFiles?.first?.id, kept.id)
        try await source.removeAttachment(kept.id, from: local.id)
        await api.setLostPart(false); try await source.flush(local.id)
        let writes = await api.requests, parts = await api.parts
        XCTAssertEqual(writes.map(\.action), [.create, .update])
        XCTAssertEqual(writes.first?.operationID, pending?.pending?.operationID)
        XCTAssertEqual(writes.first?.content?.attachments.count, 1)
        XCTAssertEqual(writes.last?.content?.attachments.count, 0)
        XCTAssertEqual(parts.map { $0.2 }, [MailDraftFiles.chunkBytes, MailDraftFiles.chunkBytes, 3])
        XCTAssertEqual(parts[0].0, parts[1].0); XCTAssertEqual(parts[0].1, parts[1].1)
        let saved = try await source.record(local.id)
        XCTAssertNil(saved?.pendingFiles); XCTAssertNil(saved?.deliveryFailed)
    }

    func testStaleOpenEditorCannotSilentlyOverwriteARefreshedProviderBaseline() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api); var opened = draft()
        try await source.create(opened); try await source.flush(opened.id)
        var external = remote("new-version", subject: "Edited on another device"); external.id = "gmail-draft"
        try await source.importDraft(external, account: opened.account)
        opened.subject = "Typing in the still-open editor"
        try await source.save(opened)
        let retained = try await source.record(opened.id)
        XCTAssertEqual(retained?.snapshot.subject, opened.subject)
        XCTAssertEqual(retained?.remote?.message.id, "new-version")
        XCTAssertEqual(retained?.conflict, true)
        try await source.flush(opened.id)
        let requests = await api.requests; XCTAssertEqual(requests.count, 1)
    }
    func testStaleForeignPreviewCannotSendTheNewerUnseenDraft() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api)
        try await source.importDraft(remote("v1", subject: "Seen"), account: "noor@plan.example")
        let values = try await source.records(); let opened = try XCTUnwrap(values.first?.snapshot.value)
        try await source.importDraft(remote("v2", subject: "Not seen"), account: opened.account)
        do { try await source.queueSend(opened.id, options: .init(hold: 0, thenDone: false), expectedEditToken: opened.editToken); XCTFail("Sent unseen content") } catch {}
        let requests = await api.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testExplicitTextRewritePreservesProviderAttachments() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api)
        let wire = remote("v1", subject: "Imported", attachment: true); await api.setFetched(wire)
        try await source.importDraft(wire, account: "noor@plan.example")
        let records = try await source.records(); let id = try XCTUnwrap(records.first?.snapshot.id)
        let editable = try await source.rewriteAsText(id)
        XCTAssertEqual(editable.format, .banana); XCTAssertEqual(editable.attachments.count, 1)
        let file = try XCTUnwrap(editable.attachments.first?.file)
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 7, count: 42))
        try await source.flush(id)
        let requests = await api.requests, parts = await api.parts
        XCTAssertEqual(requests.map(\.action), [.update]); XCTAssertEqual(requests.first?.id, "remote-draft")
        XCTAssertEqual(requests.first?.content?.attachments.first?.bytes, 42)
        XCTAssertEqual(parts.count, 1)
    }
    func testForwardMaterializesAttachmentsBeforeCreatingTheGmailDraft() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api)
        await api.setFetched(remote("original", subject: "Original", attachment: true))
        var local = draft(); local.isForward = true
        local.attachments = [.init(id: "file", name: "notes.pdf", bytes: 42, file: nil, isExecutable: false)]
        try await source.create(local, forwardMessageID: "original")
        try await source.flush(local.id)
        let requests = await api.requests
        XCTAssertEqual(requests.map(\.action), [.create])
        XCTAssertEqual(requests.first?.content?.attachments.first?.bytes, 42)
        // A later autosave from the original UI snapshot must not erase the materialized file.
        local.subject = "Later edit"; try await source.save(local)
        let saved = try await source.record(local.id)
        XCTAssertNotNil(saved?.snapshot.attachments.first?.file)
    }

    func testDraftAndUnknownCreateIdentitySurviveReopeningWithoutCrossAccountReads() async throws {
        let (directories, store, api) = try await setup(); let source = driver(store, api); let value = draft()
        try await source.create(value); await api.setLost(true)
        do { try await source.flush(value.id); XCTFail("Expected unknown outcome") } catch {}
        let beforeRead = try await source.record(value.id)
        let before = try XCTUnwrap(beforeRead)
        let reopened = try await Task.detached { try MailIntentStore(directories: directories) }.value
        let next = driver(reopened, api)
        await api.setLost(false); try await next.flush(value.id)
        let requests = await api.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(before.pending?.operationID, requests[1].operationID)
        let afterRead = try await next.record(value.id)
        let after = try XCTUnwrap(afterRead)
        XCTAssertNil(after.pending); XCTAssertEqual(after.remote?.id, "gmail-draft")
        let other = try await driver(reopened, api, scope: "different-account").record(value.id)
        XCTAssertNil(other)
    }
    func testAcknowledgementCannotEraseAnEditMadeDuringUpload() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api); var value = draft()
        try await source.create(value); value.subject = "Newer edit"; let edited = value
        await api.setHook { try await source.save(edited) }
        try await source.flush(value.id)
        let requests = await api.requests
        XCTAssertEqual(requests.map(\.action), [.create, .update])
        XCTAssertEqual(requests[1].content?.subject, "Newer edit")
        let resultRead = try await source.record(value.id)
        let result = try XCTUnwrap(resultRead)
        XCTAssertEqual(result.snapshot.subject, "Newer edit"); XCTAssertEqual(result.revision, result.acknowledgedRevision)
    }
    func testCancelBeforeHandoffAndUncertainSendReuseOnlyTheSavedIdentity() async throws {
        let (_, store, api) = try await setup(); let source = driver(store, api); let value = draft()
        try await source.create(value); try await source.flush(value.id)
        let now = Date(timeIntervalSince1970: 100)
        try await source.queueSend(value.id, options: .init(hold: 10, thenDone: false), now: now)
        let cancelled = try await source.cancelSend(value.id); XCTAssertTrue(cancelled)
        try await source.queueSend(value.id, options: .init(hold: 0, thenDone: false), now: now)
        await api.setLost(true)
        do { try await source.flush(value.id, now: now); XCTFail("Expected unknown outcome") } catch {}
        let cannotCancel = try await source.cancelSend(value.id); XCTAssertFalse(cannotCancel)
        await api.setLost(false); try await source.flush(value.id, now: now)
        let requests = await api.requests
        XCTAssertEqual(requests[1].action, .send); XCTAssertEqual(requests[1], requests[2])
        let result = try await source.record(value.id); XCTAssertEqual(result?.state, .sent)
    }
}
