import XCTest

/// Crash and performance reports for the service (docs/design/DIAGNOSTICS.md): the batch says
/// which build and carries MetricKit's own JSON, nothing about the person.
final class DiagnosticReportsTests: XCTestCase {
    private func report(_ kind: String, _ json: String, signature: String? = nil) -> DiagnosticReports.Report {
        .init(kind: kind, signature: signature, payload: Data(json.utf8))
    }

    func testTheBatchCarriesTheBuildAndEachReportsOwnJSON() throws {
        let body = try XCTUnwrap(DiagnosticReports.body(
            [report("crash", #"{"callStackTree":{"callStacks":[]}}"#, signature: "signal 11"), report("hang", "not json")],
            platform: "iphone", channel: "appstore", version: "1.0 (61)", os: "27.0.1"))
        let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(batch.keys), ["platform", "channel", "version", "os", "reports"])
        let reports = try XCTUnwrap(batch["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0]["kind"] as? String, "crash")
        XCTAssertEqual(reports[0]["signature"] as? String, "signal 11")
        XCTAssertNotNil((reports[0]["payload"] as? [String: Any])?["callStackTree"])
        XCTAssertNil(DiagnosticReports.body([report("hang", "x")], platform: "mac", channel: "dev", version: "1 (1)", os: "27.0.0"))
    }

    func testTheOutboxKeepsTheNewestAndDropsWhatTheServiceWouldRefuse() {
        let many = (0..<30).map { report("hang", #"{"n":\#($0)}"#) }
        let big = report("metrics", "{\"x\":\"" + String(repeating: "a", count: DiagnosticReports.mostPayload) + "\"}")
        let kept = DiagnosticReports.trimmed(many + [big])
        XCTAssertEqual(kept.count, DiagnosticReports.mostWaiting)
        XCTAssertEqual(kept.last, many.last)
    }
}
