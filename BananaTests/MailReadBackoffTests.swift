import XCTest
import GRDB

@MainActor final class MailReadBackoffTests: XCTestCase {
    private final class Access: MailAccountAccess {
        var connectedAccountIDs = ["a@example.com"]
        func mailGrant(accountID: String) -> MailGrant { .granted }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken {
            MailAccessToken(value: "fixture", scopes: [MailScopes.gmailModify])
        }
        func dropMailAccessToken(accountID: String) {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome { .granted }
        func forgetMailAccess(accountID: String) async throws {}
        func cancelMailTokenRequests() {}
    }

    private actor Provider: GmailAPI {
        let labelFailure: GmailError?
        let pageFailure: GmailError?
        var calls: [String] = []
        var pageFinished = false
        init(labels: GmailError?, page: GmailError?) {
            labelFailure = labels; pageFailure = page
        }
        func profile(token: String) async throws -> GmailProfile {
            calls.append("profile")
            return GmailProfile(emailAddress: "a@example.com", messagesTotal: 0, historyId: 10)
        }
        func labels(token: String) async throws -> [GmailLabel] {
            calls.append("labels")
            if let labelFailure { throw labelFailure }
            return []
        }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool,
                          pageToken: String?, maxResults: Int) async throws -> GmailIDPage {
            calls.append("page")
            // A later page failure must preserve an earlier, longer label deadline.
            try await Task.sleep(for: .milliseconds(30))
            pageFinished = true
            if let pageFailure { throw pageFailure }
            return GmailIDPage()
        }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
            calls.append("message"); throw GmailError.notFound
        }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread {
            calls.append("thread"); throw GmailError.notFound
        }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage {
            calls.append("history"); throw GmailError.malformed
        }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { XCTFail("Read test may not write Gmail"); throw GmailError.malformed }
        func trash(token: String, id: String) async throws { XCTFail("Read test may not write Gmail"); throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { XCTFail("Read test may not write Gmail"); throw GmailError.malformed }
    }

    private func check(labels: GmailError?, page: GmailError?, minimumDelay: TimeInterval) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-read-backoff-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached {
            try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations())
        }.value
        let api = Provider(labels: labels, page: page)
        let source = MailLiveSource(stores: stores, access: Access(), api: api)
        let started = Date()
        source.activate()
        defer { source.setVisible(false) }
        for _ in 0..<200 {
            if await api.pageFinished { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let finished = await api.pageFinished
        XCTAssertTrue(finished)
        try await Task.sleep(for: .milliseconds(50))
        guard case .limited(let until) = source.accounts.first?.health else {
            XCTFail("Page and label rate limits must be visible on the account"); return
        }
        XCTAssertGreaterThanOrEqual(until, started.addingTimeInterval(minimumDelay))
        let before = await api.calls
        source.checkNow()
        source.askGmail(MailScope(place: .mailbox(.inbox)))
        source.fetchBody(MailMessageID(account: "a@example.com", message: "m"))
        source.wants([MailConversationID(account: "a@example.com", thread: "t")])
        source.setVisible(false); source.setVisible(true)
        source.checkNow()
        try await Task.sleep(for: .milliseconds(100))
        let after = await api.calls
        XCTAssertEqual(after, before, "Manual refresh, paging, downloads and reactivation must honor Retry-After")
    }

    func testLabelRateLimitBlocksOtherReadEntrypoints() async throws {
        try await check(labels: .limited(.user, retryAfter: 120), page: nil, minimumDelay: 120)
    }
    func testPageRateLimitBlocksOtherReadEntrypoints() async throws {
        try await check(labels: nil, page: .limited(.user, retryAfter: 90), minimumDelay: 90)
    }
    func testLaterShorterRateLimitPreservesLongestDeadline() async throws {
        try await check(labels: .limited(.user, retryAfter: 300), page: .limited(.user, retryAfter: 30), minimumDelay: 300)
    }
    func testLaterServerFailurePreservesRateLimitDeadlineAndHealth() async throws {
        try await check(labels: .limited(.user, retryAfter: 300), page: .server(503), minimumDelay: 300)
    }
}
