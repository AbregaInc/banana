import XCTest

final class AssistantCalendarIdentityTests: XCTestCase {
    private let operation = UUID(uuidString: "3D9A2DFE-279E-4AAF-95AD-B7D15E17CB54")!

    func testRetryKeepsIDAndReceiptAcrossDictionaryOrdering() throws {
        var first: [String: Any] = ["summary": "Lunch", "start": ["dateTime": "2026-10-26T13:00:00Z"], "end": ["dateTime": "2026-10-26T14:00:00Z"]]
        var second: [String: Any] = ["end": ["dateTime": "2026-10-26T14:00:00Z"], "start": ["dateTime": "2026-10-26T13:00:00Z"], "summary": "Lunch"]
        let a = try AssistantCalendarIdentity.attach(to: &first, operation: operation)
        let b = try AssistantCalendarIdentity.attach(to: &second, operation: operation)
        XCTAssertEqual(first["id"] as? String, "3d9a2dfe279e4aaf95adb7d15e17cb54")
        XCTAssertEqual(a, b)
        XCTAssertTrue(AssistantCalendarIdentity.matches(a, receipt: b))
    }

    func testChangedPayloadOrAnotherDraftIsNotAcceptedAsRetry() throws {
        var first: [String: Any] = ["summary": "Lunch"]
        var changed: [String: Any] = ["summary": "Dinner"]
        var other = first
        let a = try AssistantCalendarIdentity.attach(to: &first, operation: operation)
        let b = try AssistantCalendarIdentity.attach(to: &changed, operation: operation)
        let c = try AssistantCalendarIdentity.attach(to: &other, operation: UUID())
        XCTAssertFalse(AssistantCalendarIdentity.matches(a, receipt: b))
        XCTAssertFalse(AssistantCalendarIdentity.matches(a, receipt: c))
        XCTAssertFalse(AssistantCalendarIdentity.matches(nil, receipt: a))
    }
}
