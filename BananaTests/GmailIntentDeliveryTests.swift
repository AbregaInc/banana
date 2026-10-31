import XCTest

final class GmailIntentDeliveryTests: XCTestCase {
    actor Provider: GmailAPI {
        var account = "a@example.com", labels: Set<String> = ["INBOX", "UNREAD"]
        var mutationFailure: GmailError?, applies = true, profiles = 0, writes = 0
        var onWrite: (@Sendable () async throws -> Void)?
        func configure(error: GmailError? = nil, applies: Bool = true, account: String = "a@example.com", onWrite: (@Sendable () async throws -> Void)? = nil) {
            mutationFailure = error; self.applies = applies; self.account = account; self.onWrite = onWrite
        }
        func profile(token: String) async throws -> GmailProfile { profiles += 1; return GmailProfile(emailAddress: account, messagesTotal: 1, historyId: 100) }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
            XCTAssertEqual(format, .minimal)
            return GmailMessage(id: id, threadId: "t", labelIds: labels.sorted(), historyId: 101)
        }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws {
            writes += 1; XCTAssertEqual(id, "m")
            if applies { labels.formUnion(add); labels.subtract(remove) }
            try await onWrite?()
            if let mutationFailure { throw mutationFailure }
        }
        func trash(token: String, id: String) async throws { try await modify(token: token, id: id, add: ["TRASH"], remove: []) }
        func untrash(token: String, id: String) async throws { try await modify(token: token, id: id, add: [], remove: ["TRASH"]) }
        func labels(token: String) async throws -> [GmailLabel] { [] }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { throw GmailError.malformed }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.malformed }
    }
    private func setup() async throws -> (MailIntentStore, Provider, GmailIntentDelivery) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-delivery-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try await Task.detached { try MailIntentStore(directories: MailDirectories(root: root)) }.value
        let api = Provider()
        return (store, api, GmailIntentDelivery(store: store, api: api, token: { _ in "fixture" }, allowed: { _ in true }, accept: { _, _ in }))
    }
    @discardableResult private func record(_ store: MailIntentStore, want: Bool = false) async throws -> Int64 {
        try await store.record(.read(!want), account: "a@example.com", assertions: [Assertion(account: "a@example.com", messageID: "m", labelRef: "UNREAD", want: want, origin: .person)], conversations: 1, at: 100)
    }
    func testUnmatchedConfirmationStillImportsProviderStateBeforeRefusal() async throws {
        let (store, api, _) = try await setup()
        try await record(store)
        await api.configure(error: .domainPolicy, applies: false)
        actor Events {
            var values: [String] = []
            func append(_ value: String) { values.append(value) }
        }
        let events = Events()
        let worker = GmailIntentDelivery(store: store, api: api, token: { _ in "fixture" }, allowed: { _ in true }, accept: { _, value in
            XCTAssertTrue(value.labelIds?.contains("UNREAD") == true)
            await events.append("import")
        }, settled: { _, _, _, outcome in
            XCTAssertEqual(outcome, .refused)
            let rows = try? await store.assertions()
            XCTAssertEqual(rows?.first?.state, .refused)
            await events.append("settled")
        })
        let outcome = try await worker.deliverNext(account: "a@example.com", at: 100)
        XCTAssertEqual(outcome, .refused)
        let order = await events.values
        XCTAssertEqual(order, ["import", "settled"])
    }

    func testAmbiguousWriteClearsOnlyAfterConfirmation() async throws {
        let (store, api, worker) = try await setup()
        try await record(store)
        await api.configure(error: .unknownOutcome)
        let outcome = try await worker.deliverNext(account: "a@example.com", at: 100)
        XCTAssertEqual(outcome, .confirmed)
        let remaining = try await store.assertions()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testSuccessWithoutMatchingLabelsStaysDurableAndBacksOff() async throws {
        let (store, api, worker) = try await setup()
        try await record(store)
        await api.configure(applies: false)
        let outcome = try await worker.deliverNext(account: "a@example.com", at: 100)
        XCTAssertEqual(outcome, .deferred)
        let remaining = try await store.assertions()
        XCTAssertEqual(remaining.first?.state, .pending)
        XCTAssertGreaterThan(remaining.first?.nextAttemptAt ?? 0, 100)
        let idle = try await worker.deliverNext(account: "a@example.com", at: 101)
        XCTAssertEqual(idle, .idle)
        let reads = await api.profiles
        XCTAssertEqual(reads, 1, "Backoff must not keep touching the network")
    }
    func testWrongAccountNeverClaimsOrWrites() async throws {
        let (store, api, worker) = try await setup()
        try await record(store)
        await api.configure(account: "other@example.com")
        do { _ = try await worker.deliverNext(account: "a@example.com", at: 100); XCTFail() }
        catch { XCTAssertTrue(error is GmailIntentDelivery.Failure) }
        let writes = await api.writes
        let remaining = try await store.assertions()
        XCTAssertEqual(writes, 0); XCTAssertEqual(remaining.first?.state, .pending)
    }
    func testPermanentRefusalIsRetainedForExplicitRetry() async throws {
        let (store, api, worker) = try await setup()
        let seq = try await record(store)
        await api.configure(error: .domainPolicy, applies: false)
        let outcome = try await worker.deliverNext(account: "a@example.com", at: 100)
        XCTAssertEqual(outcome, .refused)
        let remaining = try await store.assertions()
        XCTAssertEqual(remaining.first?.failure, .notAllowedByAdmin)
        let idle = try await worker.deliverNext(account: "a@example.com", at: 10000)
        XCTAssertEqual(idle, .idle)
        try await store.retry(group: seq)
        await api.configure()
        let retried = try await worker.deliverNext(account: "a@example.com", at: 10001)
        XCTAssertEqual(retried, .confirmed)
    }
    func testRateLimitHintIsDurablyRespected() async throws {
        let (store, api, worker) = try await setup()
        try await record(store)
        await api.configure(error: .limited(.user, retryAfter: 60), applies: false)
        let outcome = try await worker.deliverNext(account: "a@example.com", at: 100)
        XCTAssertEqual(outcome, .deferred)
        let rows = try await store.assertions()
        XCTAssertEqual(rows.first?.nextAttemptAt, 60100)
        let idle = try await worker.deliverNext(account: "a@example.com", at: 60099)
        XCTAssertEqual(idle, .idle)
    }
    func testDisabledDeliveryDoesNotTouchProviderOrClaimIntent() async throws {
        let (store, api, _) = try await setup()
        try await record(store)
        let worker = GmailIntentDelivery(store: store, api: api, token: { _ in "fixture" }, allowed: { _ in false }, accept: { _, _ in })
        do { _ = try await worker.deliverNext(account: "a@example.com", at: 100); XCTFail() }
        catch { XCTAssertTrue(error is GmailIntentDelivery.Failure) }
        let profiles = await api.profiles
        let rows = try await store.assertions()
        XCTAssertEqual(profiles, 0); XCTAssertEqual(rows.first?.state, .pending)
    }
    func testCancellationLeavesDurableRetryableIntent() async throws {
        let (store, api, worker) = try await setup()
        try await record(store)
        await api.configure(onWrite: { try await Task.sleep(for: .seconds(30)) })
        let delivery = Task { try await worker.deliverNext(account: "a@example.com", at: 100) }
        var started = false
        for _ in 0..<200 {
            if await api.writes > 0 { started = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        delivery.cancel()
        do { _ = try await delivery.value; XCTFail("Cancelled delivery succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(started)
        let rows = try await store.assertions()
        XCTAssertEqual(rows.first?.state, .pending)
        XCTAssertNil(rows.first?.sentSeq)
        await api.configure()
        let retry = try await worker.deliverNext(account: "a@example.com", at: 100)
        XCTAssertEqual(retry, .confirmed)
    }

    func testNewerIntentSurvivesOldProviderConfirmation() async throws {
        let (store, api, worker) = try await setup()
        try await record(store)
        await api.configure(onWrite: {
            _ = try await store.record(.read(false), account: "a@example.com", assertions: [Assertion(account: "a@example.com", messageID: "m", labelRef: "UNREAD", want: true, origin: .person)], conversations: 1, at: 101)
        })
        let outcome = try await worker.deliverNext(account: "a@example.com", at: 100)
        XCTAssertEqual(outcome, .confirmed)
        let remaining = try await store.assertions()
        XCTAssertEqual(remaining.count, 1); XCTAssertEqual(remaining.first?.assertion.want, true)
        await api.configure()
        let next = try await worker.deliverNext(account: "a@example.com", at: 102)
        XCTAssertEqual(next, .confirmed)
    }
}
