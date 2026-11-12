import XCTest

final class MailSenderPolicyTests: XCTestCase {
    private let account = "noor@plan.example", sender = "offers@shop.example"
    actor Provider: MailSenderPolicyAPI {
        var value = MailSenderPolicyRemote(blocked: false, revision: 0, operation: nil)
        var writes = 0, loseReply = false, offline = false
        var onWrite: (@Sendable () async throws -> Void)?
        func configure(loseReply: Bool = false, offline: Bool = false, onWrite: (@Sendable () async throws -> Void)? = nil) {
            self.loseReply = loseReply; self.offline = offline; self.onWrite = onWrite
        }
        func read(account: String, sender: String) async throws -> MailSenderPolicyRemote {
            if offline { throw GmailError.neverLeft }; return value
        }
        func write(account: String, sender: String, blocked: Bool, revision: Int, operation: String) async throws -> MailSenderPolicyRemote {
            guard value.revision == revision else { throw MailSenderPolicyError.conflict(value) }
            writes += 1; value = .init(blocked: blocked, revision: revision + 1, operation: operation)
            try await onWrite?()
            if loseReply { loseReply = false; throw GmailError.unknownOutcome }
            return value
        }
        func elsewhere(_ blocked: Bool) { value = .init(blocked: blocked, revision: value.revision + 1, operation: UUID().uuidString) }
        func count() -> Int { writes }
    }
    private func directory() async throws -> MailDirectories {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sender-policy-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailDirectories(root: root) }.value
    }
    private func open(_ dirs: MailDirectories) async throws -> MailIntentStore {
        try await Task.detached { try MailIntentStore(directories: dirs) }.value
    }
    func testPendingRuleSurvivesReopeningAndOnlyConfirmsAfterProviderReadBack() async throws {
        let dirs = try await directory()
        var original: MailIntentStore? = try await open(dirs)
        try await original!.queueSenderPolicy(account: account, sender: sender, blocked: true)
        original = nil
        let store = try await open(dirs), api = Provider()
        let driver = MailSenderPolicyDriver(store: store, api: api, allowed: { _ in true })
        let pending = try await store.senderPolicy(account: account, sender: sender)
        XCTAssertTrue(try XCTUnwrap(pending).pending)
        _ = try await driver.deliverNext(account: account, at: Date())
        let saved = try await store.senderPolicy(account: account, sender: sender)
        XCTAssertEqual(saved?.remote?.blocked, true); XCTAssertEqual(saved?.pending, false)
        let writes = await api.count(); XCTAssertEqual(writes, 1)
    }
    func testLostReplyIsReconciledWithoutRepeatingTheWrite() async throws {
        let store = try await open(directory()), api = Provider()
        await api.configure(loseReply: true)
        let driver = MailSenderPolicyDriver(store: store, api: api, allowed: { _ in true })
        try await driver.queue(account: account, sender: sender, blocked: true)
        let now = Date()
        _ = try await driver.deliverNext(account: account, at: now)
        _ = try await driver.deliverNext(account: account, at: now.addingTimeInterval(31))
        let saved = try await store.senderPolicy(account: account, sender: sender)
        XCTAssertEqual(saved?.pending, false); XCTAssertEqual(saved?.remote?.blocked, true)
        let writes = await api.count(); XCTAssertEqual(writes, 1)
    }
    func testLostBlockReplyCannotOverwriteALaterUnblockOnAnotherDevice() async throws {
        let store = try await open(directory()), api = Provider()
        await api.configure(loseReply: true)
        let driver = MailSenderPolicyDriver(store: store, api: api, allowed: { _ in true })
        try await driver.queue(account: account, sender: sender, blocked: true)
        let now = Date(); _ = try await driver.deliverNext(account: account, at: now)
        await api.elsewhere(false)
        _ = try await driver.deliverNext(account: account, at: now.addingTimeInterval(31))
        let saved = try await store.senderPolicy(account: account, sender: sender)
        XCTAssertEqual(saved?.pending, false); XCTAssertEqual(saved?.failed, true); XCTAssertEqual(saved?.remote?.blocked, false)
        let writes = await api.count(); XCTAssertEqual(writes, 1)
    }
    func testNewIntentDuringAnOlderWriteRemainsPendingAndWinsNext() async throws {
        let store = try await open(directory()), api = Provider()
        let account = account, sender = sender
        await api.configure(onWrite: { try await store.queueSenderPolicy(account: account, sender: sender, blocked: false) })
        let driver = MailSenderPolicyDriver(store: store, api: api, allowed: { _ in true })
        try await driver.queue(account: account, sender: sender, blocked: true)
        _ = try await driver.deliverNext(account: account, at: Date())
        await api.configure()
        let pending = try await store.senderPolicy(account: account, sender: sender)
        XCTAssertEqual(pending?.want, false); XCTAssertEqual(pending?.pending, true)
        _ = try await driver.deliverNext(account: account, at: Date())
        let saved = try await store.senderPolicy(account: account, sender: sender)
        XCTAssertEqual(saved?.remote?.blocked, false); XCTAssertEqual(saved?.pending, false)
    }
    func testOfflineIntentIsDurableAndCanBeCancelledBeforeDelivery() async throws {
        let store = try await open(directory()), api = Provider()
        await api.configure(offline: true)
        let driver = MailSenderPolicyDriver(store: store, api: api, allowed: { _ in true })
        try await driver.queue(account: account, sender: sender, blocked: true)
        _ = try await driver.deliverNext(account: account, at: Date())
        let pending = try await store.senderPolicy(account: account, sender: sender)
        XCTAssertEqual(pending?.pending, true)
        try await driver.queue(account: account, sender: sender, blocked: false)
        await api.configure()
        _ = try await driver.deliverNext(account: account, at: Date())
        let saved = try await store.senderPolicy(account: account, sender: sender)
        XCTAssertEqual(saved?.remote?.blocked, false); XCTAssertEqual(saved?.pending, false)
        let writes = await api.count(); XCTAssertEqual(writes, 0)
    }
}
