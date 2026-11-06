import XCTest

final class MailDraftDriverTests: XCTestCase {
    private actor Provider: GmailDraftAPI {
        var requests: [GmailDraftMutation] = []
        var loseReply = false
        var fetched: GmailDraftValue?
        var listing: GmailDraftPage?
        var reads = 0
        var missing = false
        func setMissing(_ value: Bool) { missing = value }
        func setListing(_ value: GmailDraftPage) { listing = value }
        func setFetched(_ value: GmailDraftValue) { fetched = value }
        var onWrite: (@Sendable () async throws -> Void)?
        func setLost(_ value: Bool) { loseReply = value }
        func setHook(_ value: @escaping @Sendable () async throws -> Void) { onWrite = value }
        func drafts(token: String, pageToken: String?) async throws -> GmailDraftPage { guard let listing else { throw GmailError.networkDisabled }; return listing }
        func draft(token: String, id: String) async throws -> GmailDraftValue { if missing { throw GmailError.notFound }; guard let fetched else { throw GmailError.networkDisabled }; reads += 1; return fetched }
        func mutateDraft(token: String, request: GmailDraftMutation) async throws -> Data {
            requests.append(request)
            if let hook = onWrite { onWrite = nil; try await hook() }
            if loseReply { throw GmailError.unknownOutcome }
            if request.action == .send { return Data(#"{"id":"sent","labelIds":["SENT"]}"#.utf8) }
            return try JSONEncoder().encode(GmailDraftReference(id: "gmail-draft", message: .init(id: request.operationID, threadId: "thread")))
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
