import XCTest

final class CloudCalendarOperationTests: XCTestCase {
    func testLostAcknowledgementAndRelaunchReuseDurableRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try XCTUnwrap(URL(string: "https://www.googleapis.com/calendar/v3/calendars/work/events"))
        let body = Data(#"{"summary":"Review"}"#.utf8)
        let journal = CloudProviderOperationJournal(directory: root)
        let first = try await journal.prepare(url: url, method: "POST", body: body, ifMatch: nil,
                                               email: "noor@plan.example", context: "account-one")
        let relaunched = CloudProviderOperationJournal(directory: root)
        let retried = try await relaunched.prepare(url: url, method: "POST", body: body, ifMatch: nil,
                                                   email: "noor@plan.example", context: "account-one")
        XCTAssertEqual(first.body, retried.body)
        let other = try await relaunched.prepare(url: url, method: "POST", body: body, ifMatch: nil,
                                                 email: "noor@plan.example", context: "account-two")
        XCTAssertNotEqual(first.key, other.key)
        try await relaunched.acknowledged(retried)
        let next = try await relaunched.prepare(url: url, method: "POST", body: body, ifMatch: nil,
                                                email: "noor@plan.example", context: "account-one")
        XCTAssertNotEqual(first.body, next.body, "A later intentional action has a new operation identity")
    }

    func testMoveAndConditionalEditKeepProviderSemanticsWithoutForwardingURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CloudProviderOperationJournal(directory: root)
        let url = try XCTUnwrap(URL(string: "https://www.googleapis.com/calendar/v3/calendars/work/events/event/move?destination=home&sendUpdates=all"))
        let ticket = try await journal.prepare(url: url, method: "POST", body: nil, ifMatch: "etag",
                                               email: "noor@plan.example", context: "context")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ticket.body) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "move")
        XCTAssertEqual(json["destination"] as? String, "home")
        XCTAssertEqual(json["ifMatch"] as? String, "etag")
        XCTAssertNil(json["url"])
        XCTAssertNil(json["token"])
    }

    func testCloudOwnershipSurvivesRelaunchAndIsScopedToProviderAndEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CloudProviderOperationJournal(directory: root)
        try await first.claim(email: "Noor@plan.example", host: "service.example")
        let relaunched = CloudProviderOperationJournal(directory: root)
        let owned = try await relaunched.requiresCloud(email: "noor@plan.example", host: "service.example")
        let another = try await relaunched.requiresCloud(email: "another@plan.example", host: "service.example")
        let staging = try await relaunched.requiresCloud(email: "noor@plan.example", host: "staging.example")
        XCTAssertTrue(owned)
        XCTAssertFalse(another)
        XCTAssertFalse(staging)
    }

    func testDiskFailureCannotPermitProviderDispatch() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("preserve".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = CloudProviderOperationJournal(directory: file)
        let url = try XCTUnwrap(URL(string: "https://www.googleapis.com/calendar/v3/calendars/work/events/event"))
        do {
            _ = try await journal.prepare(url: url, method: "DELETE", body: nil, ifMatch: nil,
                                           email: "noor@plan.example", context: "context")
            XCTFail("A delivery without durable intent must fail")
        } catch { XCTAssertEqual(try Data(contentsOf: file), Data("preserve".utf8)) }
    }
}
