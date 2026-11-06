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
    func testAttachmentRequestCarriesBinaryBodyAndAccountHeader() {
        let operation = "10000000-0000-4000-8000-000000000001", hash = String(repeating: "a", count: 64)
        let request = BananaService.request(.mailAttachment(email: "noor@plan.example", operation: operation, hash: hash, data: Data([0, 1, 255])), host: "service.example", session: "session")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.httpBody, Data([0, 1, 255]))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Banana-Mail-Account"), "noor@plan.example")
        XCTAssertEqual(request.url?.path, "/v1/mail/attachment/" + operation + "/" + hash)
    }

    func testDraftReadsStayBehindTheAccountScopedCloudTransport() throws {
        for (path, resource) in [(["drafts"], "drafts"), (["drafts", "gmail-draft"], "draft")] {
            let data = try CloudMailRequest.body(path: path, email: "noor@plan.example", query: [], method: "GET", body: nil)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["resource"] as? String, resource)
        }
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
