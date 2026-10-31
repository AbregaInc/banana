import XCTest
import GRDB

@MainActor final class MailAccessLifecycleTests: XCTestCase {
    private final class Access: MailAccountAccess {
        var connectedAccountIDs = ["a@example.com"]
        var grant = MailGrant.granted
        var forgetting: CheckedContinuation<Void, Never>?
        var requests = 0
        var failForget = false
        func mailGrant(accountID: String) -> MailGrant { grant }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken { throw MailAccessError.notGranted }
        func dropMailAccessToken(accountID: String) {}
        func cancelMailTokenRequests() {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome {
            requests += 1; grant = .granted; return .granted
        }
        func forgetMailAccess(accountID: String) async throws {
            await withCheckedContinuation { forgetting = $0 }
            if failForget { throw MailAccessError.notGranted }
            grant = .none
        }
        func finishForgetting() { forgetting?.resume(); forgetting = nil }
    }

    func testForgettingBlocksAccessImmediatelyAndCannotRaceNewConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("access-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let access = Access()
        let source = MailLiveSource(stores: stores, access: access, api: GmailMailboxSyncTests.Provider())
        source.forgetPermission(account: "a@example.com")
        XCTAssertEqual(source.accounts.first?.state, .needsAccess(.notAllowedHere))
        for _ in 0..<100 where access.forgetting == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(access.forgetting)
        let blocked = await source.requestPermission(account: "a@example.com")
        XCTAssertEqual(blocked, .cancelled)
        XCTAssertEqual(access.requests, 0)
        access.finishForgetting()
        for _ in 0..<100 where access.grant != .none { try await Task.sleep(for: .milliseconds(1)) }
        // Allow the source's cleanup continuation to finish on the main actor.
        for _ in 0..<10 { await Task.yield() }
        let allowed = await source.requestPermission(account: "a@example.com")
        XCTAssertEqual(allowed, .granted)
        XCTAssertEqual(access.requests, 1)
        access.failForget = true
        source.forgetPermission(account: "a@example.com")
        for _ in 0..<100 where access.forgetting == nil { try await Task.sleep(for: .milliseconds(1)) }
        access.finishForgetting()
        for _ in 0..<100 where source.accounts.first?.state != .off { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(source.accounts.first?.state, .off, "Failed credential cleanup must not silently resume the account")
        if case .cannotSave = source.status.value.store {} else { XCTFail("Credential cleanup failure must be visible") }
        source.setVisible(false)
    }
}
