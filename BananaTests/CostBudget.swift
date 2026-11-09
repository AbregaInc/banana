import XCTest

/// A component cost budget (docs/performance/regression-testing.md): a ceiling in milliseconds
/// that a piece of work must stay under. The ceilings are set for optimized code, so they are
/// enforced only where the tests run optimized: the Release run of `BananaModelTests`, which
/// `tools/preflight.sh` makes. An unoptimized (Debug) build still runs every other assertion of
/// the test, then skips it as "not measured in an unoptimized build", with the numbers it saw,
/// because a Debug figure says nothing about the budget either way. No ceiling moves.
///
///     let budget = CostBudget(self)
///     … the work, timed, and its correctness assertions …
///     budget.expect(samples, below: 100, "Search exceeded the local UI ceiling")
///     try budget.finish()
final class CostBudget {
    static let unmeasured = "not measured in an unoptimized build"

    /// Whether this code was compiled with optimization. The test bundle compiles the app's
    /// sources itself, so this is the build of the code being timed too.
    static var isOptimized: Bool { !_isDebugAssertConfiguration() }

    /// In an unoptimized build: per budget (its message and ceiling), the worst sample and how
    /// many there were, in the order first seen.
    private var seen: [(key: String, worst: Double, count: Int)] = []
    private var finished = false

    init(_ test: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        // A budget that is never finished would pass a Debug run without saying it measured
        // nothing.
        // (A test that already failed or threw stopped before it could finish; that is reported.)
        test.addTeardownBlock { [self, weak test] in
            guard test?.testRun?.hasSucceeded ?? true, test?.testRun?.hasBeenSkipped != true else { return }
            XCTAssertTrue(finished, "a CostBudget was made and never finished", file: file, line: line)
        }
    }

    func expect(_ milliseconds: Double, below limit: Double, orEqual: Bool = false, _ message: @autoclosure () -> String = "",
                file: StaticString = #filePath, line: UInt = #line) {
        expect([milliseconds], below: limit, orEqual: orEqual, message(), file: file, line: line)
    }

    func expect(_ samples: [Double], below limit: Double, orEqual: Bool = false, _ message: @autoclosure () -> String = "",
                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(samples.isEmpty, "no samples for a cost budget", file: file, line: line)
        guard Self.isOptimized else {
            let text = message()
            let key = (text.isEmpty ? "" : text + ": ") + String(format: "%.0f ms", limit)
            let worst = samples.max() ?? 0
            if let at = seen.firstIndex(where: { $0.key == key }) {
                seen[at].worst = max(seen[at].worst, worst); seen[at].count += samples.count
            } else {
                seen.append((key, worst, samples.count))
            }
            return
        }
        for sample in samples {
            if orEqual {
                XCTAssertLessThanOrEqual(sample, limit, message(), file: file, line: line)
            } else {
                XCTAssertLessThan(sample, limit, message(), file: file, line: line)
            }
        }
    }

    /// The end of the measured test: nothing in an optimized build; in an unoptimized one, the
    /// skip that says the budget was not measured (after every other assertion has run).
    func finish() throws {
        finished = true
        guard !Self.isOptimized, !seen.isEmpty else { return }
        let report = seen.map { $0.key + " ceiling, worst " + String(format: "%.1f ms of %d", $0.worst, $0.count) }
        throw XCTSkip("\(Self.unmeasured) (Debug: \(report.joined(separator: "; ")))")
    }
}
