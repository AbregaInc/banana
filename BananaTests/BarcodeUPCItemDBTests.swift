import XCTest

/// Exercises UPCitemdb parsing and the rate limiter's pacing decision. No network access here —
/// the success/not-found fixtures are real captured responses (see `UPCItemDBFixtures.json`);
/// `rateLimitedQuota` follows UPCitemdb's documented trial-tier quota-exceeded body shape (a
/// non-"OK" `code` on an HTTP 200 — that combination, not a 429, is what the trial API actually
/// returns for this, so the parser has to inspect the body).
///
/// Deliberately does not touch `UPCItemDBRateLimiter` (the actor) directly: it persists to
/// `AppSupport.directory`, which is the owner's real on-disk state and must never be written by a
/// test run. `UPCItemDBRateLimiter.canAcquire` is the pure pacing decision split out specifically
/// so it's testable without that.
final class BarcodeUPCItemDBTests: XCTestCase {
    private func fixture(_ key: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "UPCItemDBFixtures", withExtension: "json"))
        let all = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return Data(try XCTUnwrap(all[key]).utf8)
    }

    // MARK: - Response parsing

    func testRealSuccessResponseParses() throws {
        guard case .found(let fields) = BarcodeProductLookup.parseUPCItemDBResponse(try fixture("natureMadeD3")) else {
            return XCTFail("expected .found")
        }
        XCTAssertEqual(fields.source, .upcItemDB)
        XCTAssertTrue(fields.name.contains("Vitamin D3"), fields.name)
        XCTAssertEqual(fields.brand, "Nature Made")
    }

    func testRealNotFoundResponseParsesAsNotFound() throws {
        XCTAssertEqual(BarcodeProductLookup.parseUPCItemDBResponse(try fixture("notFound")), .notFound)
    }

    func testQuotaExceededResponseMapsToItsOwnOutcomeDistinctFromNotFound() throws {
        // The rate-limit outcome must never collapse into `.notFound` — a throttled scan is not
        // "this product doesn't exist."
        XCTAssertEqual(BarcodeProductLookup.parseUPCItemDBResponse(try fixture("rateLimitedQuota")), .rateLimited)
    }

    func testMalformedResponseParsesAsNotFoundRatherThanCrashing() {
        XCTAssertEqual(BarcodeProductLookup.parseUPCItemDBResponse(Data("not json".utf8)), .notFound)
        XCTAssertEqual(BarcodeProductLookup.parseUPCItemDBResponse(Data()), .notFound)
    }

    // MARK: - Local pacing (rate-limit outcome from the client side, not just the body)

    func testAcquireAllowedWhenBudgetRemainsAndNoPriorRequest() {
        XCTAssertTrue(UPCItemDBRateLimiter.canAcquire(remaining: 100, lastRequestAt: nil, now: Date()))
    }

    func testAcquireDeniedWhenDailyBudgetExhausted() {
        XCTAssertFalse(UPCItemDBRateLimiter.canAcquire(remaining: 0, lastRequestAt: nil, now: Date()))
    }

    func testAcquireDeniedWithinTheSustainedPacingWindow() {
        let now = Date()
        let justRequested = now.addingTimeInterval(-3) // 3s ago, well inside the ~11s pacing gap
        XCTAssertFalse(UPCItemDBRateLimiter.canAcquire(remaining: 50, lastRequestAt: justRequested, now: now, minInterval: 11))
    }

    func testAcquireAllowedOncePacingWindowHasElapsed() {
        let now = Date()
        let longAgo = now.addingTimeInterval(-12) // just past the 11s pacing gap
        XCTAssertTrue(UPCItemDBRateLimiter.canAcquire(remaining: 50, lastRequestAt: longAgo, now: now, minInterval: 11))
    }

    func testPacingWindowNeverExceedsTheDocumentedBurstBucket() {
        // 6 requests per minute (the documented burst bucket) requires at least 10s of spacing;
        // the chosen interval must not dip below that even though it targets 10-13s "sustained".
        XCTAssertGreaterThanOrEqual(UPCItemDBRateLimiter.minInterval, 60.0 / 6.0)
    }
}
