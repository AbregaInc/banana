import XCTest

@MainActor
final class MailGrantLedgerTests: XCTestCase {
    @MainActor private final class Mints {
        var calls: [(String, UInt64)] = []
        var pending: [Int: CheckedContinuation<MailTokenFlight.Minted, Error>] = [:]
        func mint(_ account: String, _ stamp: UInt64) async throws -> MailTokenFlight.Minted {
            let id = calls.count; calls.append((account, stamp))
            return try await withCheckedThrowingContinuation { pending[id] = $0 }
        }
        func wait(_ count: Int) async throws {
            for _ in 0..<10_000 {
                if calls.count >= count { return }
                await Task.yield()
            }
            XCTFail("Mint did not start"); throw CancellationError()
        }
        func succeed(_ id: Int, _ value: String) {
            pending.removeValue(forKey: id)!.resume(returning: (value, Date().addingTimeInterval(3600), nil))
        }
        func refuse(_ id: Int) {
            pending.removeValue(forKey: id)!.resume(throwing: MailCredentialRefused(reason: .invalidGrant))
        }
    }

    func testDeletedCredentialNeverReturnsInFlightToken() async throws {
        let m = Mints()
        let l = MailGrantLedger(clock: SystemMailClock(), mint: { try await m.mint($0, $1) })
        l.stored(account: "a", isEmpty: false)
        let token = Task { try await l.token(for: "a") }
        try await m.wait(1); l.deleted(account: "a"); m.succeed(0, "old")
        do { _ = try await token.value; XCTFail("Deleted credential returned a token") }
        catch { XCTAssertEqual(error as? MailAccessError, .notGranted) }
        XCTAssertEqual(l.grant(for: "a"), .none)
    }

    func testOldRejectionCannotRejectReplacement() async throws {
        let m = Mints()
        let ledger = MailGrantLedger(clock: SystemMailClock(), mint: { try await m.mint($0, $1) })
        let old = ledger.stored(account: "a", isEmpty: false)
        let token = Task { try await ledger.token(for: "a") }
        try await m.wait(1)
        let new = ledger.stored(account: "a", isEmpty: false)
        XCTAssertNotEqual(old, new)
        m.refuse(0); try await m.wait(2); m.succeed(1, "new")
        let result = try await token.value
        XCTAssertEqual(result.value, "new")
        XCTAssertEqual(m.calls[1].1, new)
        XCTAssertEqual(ledger.grant(for: "a"), .granted)
    }

    func testRejectionPersistsUntilReplacement() async throws {
        let m = Mints(); let ledger = MailGrantLedger(clock: SystemMailClock(), mint: { try await m.mint($0, $1) })
        ledger.stored(account: "a", isEmpty: false)
        let token = Task { try await ledger.token(for: "a") }
        try await m.wait(1); m.refuse(0)
        do { _ = try await token.value; XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? MailAccessError, .rejected) }
        XCTAssertEqual(ledger.grant(for: "a"), .rejected(reason: .invalidGrant))
        do { _ = try await ledger.token(for: "a"); XCTFail("Expected remembered rejection") }
        catch { XCTAssertEqual(error as? MailAccessError, .rejected) }
        XCTAssertEqual(m.calls.count, 1)
        ledger.stored(account: "a", isEmpty: true)
        XCTAssertEqual(ledger.grant(for: "a"), .rejected(reason: .emptyCredential))
    }

    func testDropIsAppliedBeforeNextTokenRequest() async throws {
        let m = Mints(); let ledger = MailGrantLedger(clock: SystemMailClock(), mint: { try await m.mint($0, $1) })
        ledger.stored(account: "a", isEmpty: false)
        let first = Task { try await ledger.token(for: "a") }
        try await m.wait(1); m.succeed(0, "first"); _ = try await first.value
        ledger.dropToken(account: "a")
        let second = Task { try await ledger.token(for: "a") }
        try await m.wait(2); m.succeed(1, "second")
        let value = try await second.value
        XCTAssertEqual(value.value, "second")
    }
}
