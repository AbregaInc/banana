import XCTest

final class CloudMailRequestTests: XCTestCase {
    func testRoutingReferenceIsBoundToAccountAndContextAndCannotBecomeGoogleCredential() throws {
        let reference = CloudMailReference(email: "Noor@plan.example", context: "session-account")
        let restored = try CloudMailReference(value: reference.value)
        XCTAssertEqual(restored.email, "noor@plan.example")
        XCTAssertEqual(restored.context, "session-account")
        XCTAssertThrowsError(try CloudMailReference(value: "provider-access-token"))
        XCTAssertThrowsError(try GmailHTTP.request(["profile"], token: reference.value))
    }
    func testReadAndModifyEnvelopesRetainNativeSemantics() throws {
        let read = try CloudMailRequest.body(path: ["messages", "m1", "attachments", "a1"], email: "noor@plan.example", query: [], method: "GET", body: nil)
        let r = try XCTUnwrap(JSONSerialization.jsonObject(with: read) as? [String: Any])
        XCTAssertEqual(r["resource"] as? String, "attachment")
        XCTAssertEqual(r["attachmentID"] as? String, "a1")
        let write = try CloudMailRequest.body(path: ["messages", "m1", "modify"], email: "noor@plan.example", query: [], method: "POST", body: Data(#"{"addLabelIds":["STARRED"],"removeLabelIds":["UNREAD"]}"#.utf8))
        let w = try XCTUnwrap(JSONSerialization.jsonObject(with: write) as? [String: Any])
        XCTAssertEqual(w["add"] as? [String], ["STARRED"])
        XCTAssertEqual(w["remove"] as? [String], ["UNREAD"])
        XCTAssertNil(w["url"])
        XCTAssertNil(w["token"])
        XCTAssertThrowsError(try CloudMailRequest.body(path: ["messages", "send"], email: "noor@plan.example", query: [], method: "POST", body: nil))
    }
}
