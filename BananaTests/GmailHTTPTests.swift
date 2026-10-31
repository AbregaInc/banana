import XCTest

final class GmailHTTPTests: XCTestCase {
    private final class ResponseProtocol: URLProtocol {
        static var response: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, data) = Self.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func transport(cap: Int = 4096, allowed: Bool = true) -> GmailHTTP {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseProtocol.self]
        return GmailHTTP(configuration: config, maximumBytes: cap, networkAllowed: { allowed })
    }
    func testMissingLabelDirectoryIsNotAnEmptySuccess() async throws {
        ResponseProtocol.response = { _ in (200, Data("{}".utf8)) }
        do { _ = try await transport().labels(token: "fixture"); XCTFail("Missing directory accepted") }
        catch { XCTAssertEqual(error as? GmailError, .malformed) }
        ResponseProtocol.response = { _ in (200, Data(#"{"labels":[]}"#.utf8)) }
        let empty = try await transport().labels(token: "fixture")
        XCTAssertTrue(empty.isEmpty)
    }

    func testDirectReadsNormalizeOmittedLabelsButHistoryKeepsThemUnknown() async throws {
        ResponseProtocol.response = { _ in (200, Data(#"{"id":"m","threadId":"t"}"#.utf8)) }
        let message = try await transport().message(token: "fixture", id: "m", format: .minimal)
        XCTAssertEqual(message.labelIds, [])
        ResponseProtocol.response = { _ in (200, Data(#"{"id":"t","messages":[{"id":"m","threadId":"t","labelIds":null}]}"#.utf8)) }
        let thread = try await transport().thread(token: "fixture", id: "t", format: .minimal)
        XCTAssertEqual(thread.messages?.first?.labelIds, [])
        ResponseProtocol.response = { _ in (200, Data(#"{"historyId":"2","history":[{"id":"2","messagesAdded":[{"message":{"id":"m","threadId":"t"}}]}]}"#.utf8)) }
        let page = try await transport().history(token: "fixture", start: "1", pageToken: nil, maxResults: 100)
        XCTAssertNil(page.history?.first?.messagesAdded?.first?.message?.labelIds)
    }

    func testMalformedReadLabelsCannotBecomeAnEmptySet() async throws {
        for value in [#""INBOX""#, #"["INBOX",7]"#, #"[""]"#, "{}"] {
            let payload = "{\"id\":\"m\",\"threadId\":\"t\",\"labelIds\":\(value)}"
            ResponseProtocol.response = { _ in (200, Data(payload.utf8)) }
            do { _ = try await transport().message(token: "fixture", id: "m", format: .minimal); XCTFail() }
            catch { XCTAssertEqual(error as? GmailError, .malformed) }
            let thread = "{\"id\":\"t\",\"messages\":[\(payload)]}"
            ResponseProtocol.response = { _ in (200, Data(thread.utf8)) }
            do { _ = try await transport().thread(token: "fixture", id: "t", format: .minimal); XCTFail() }
            catch { XCTAssertEqual(error as? GmailError, .malformed) }
        }
    }

    func testMalformedHistoryChangesCannotBecomeAnEmptySuccess() async throws {
        for field in ["messagesAdded", "messagesDeleted", "labelsAdded", "labelsRemoved"] {
            for value in ["{}", "[7]", "[null]"] {
                let payload = "{\"history\":[{\"id\":\"2\",\"\(field)\":\(value)}],\"historyId\":\"3\"}"
                ResponseProtocol.response = { _ in (200, Data(payload.utf8)) }
                do {
                    _ = try await transport().history(token: "fixture", start: "1", pageToken: nil, maxResults: 100)
                    XCTFail("Malformed \(field) was accepted: \(value)")
                } catch { XCTAssertEqual(error as? GmailError, .malformed) }
            }
        }
        ResponseProtocol.response = { _ in (200, Data(#"{"historyId":"3","nextPageToken":7}"#.utf8)) }
        do {
            _ = try await transport().history(token: "fixture", start: "1", pageToken: nil, maxResults: 100)
            XCTFail("Malformed continuation must not become a final page")
        } catch { XCTAssertEqual(error as? GmailError, .malformed) }
        ResponseProtocol.response = { _ in (200, Data(#"{"historyId":"3"}"#.utf8)) }
        let empty = try await transport().history(token: "fixture", start: "1", pageToken: nil, maxResults: 100)
        XCTAssertNil(empty.history)
        XCTAssertEqual(empty.historyId, 3)
    }

    func testMalformedListingContinuationCannotEndEnumeration() async throws {
        for value in ["7", "{}", "[]", "true"] {
            let payload = "{\"messages\":[],\"nextPageToken\":\(value)}"
            ResponseProtocol.response = { _ in (200, Data(payload.utf8)) }
            do {
                _ = try await transport().listMessages(token: "fixture", labelIDs: [], query: nil,
                    includeSpamTrash: true, pageToken: nil, maxResults: 500)
                XCTFail("Malformed continuation became a completed listing")
            } catch { XCTAssertEqual(error as? GmailError, .malformed) }
        }
    }

    func testSearchRequestAndDecode() async throws {
        ResponseProtocol.response = { request in
            XCTAssertEqual(request.url?.host, "gmail.googleapis.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "q" }?.value, "from:a+b@example.com 雪 &")
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "opaque+/=&")
            return (200, Data(#"{"messages":[{"id":"m1","threadId":"t1"}],"nextPageToken":"next"}"#.utf8))
        }
        let page = try await transport().listMessages(token: "fixture", labelIDs: [],
            query: "from:a+b@example.com 雪 &", includeSpamTrash: false, pageToken: "opaque+/=&", maxResults: 50)
        XCTAssertEqual(page.messages?.first?.id, "m1")
        XCTAssertEqual(page.nextPageToken, "next")
    }
    func testExternalBodyPartUsesEscapedAttachmentRoute() async throws {
        ResponseProtocol.response = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("messages/m%2F1/attachments/a%2F2"))
            return (200, Data(#"{"size":5,"data":"SGVsbG8"}"#.utf8))
        }
        let body = try await transport().attachment(token: "fixture", messageID: "m/1", attachmentID: "a/2")
        XCTAssertEqual(body.size, 5); XCTAssertEqual(body.data, "SGVsbG8")
    }
    func testNetworkGate() async {
        ResponseProtocol.response = { _ in XCTFail("Network must remain disabled"); return (200, Data()) }
        do { _ = try await transport(allowed: false).profile(token: "fixture"); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .networkDisabled) }
    }
    func testBoundedResponses() async {
        ResponseProtocol.response = { _ in (200, Data(repeating: 32, count: 65)) }
        do { _ = try await transport(cap: 64).profile(token: "fixture"); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .responseTooLarge) }
    }
    func testMalformedPageDoesNotBecomeEmptySuccess() async {
        ResponseProtocol.response = { _ in (200, Data(#"{"messages":"invalid"}"#.utf8)) }
        do {
            _ = try await transport().listMessages(token: "fixture", labelIDs: [], query: nil,
                includeSpamTrash: false, pageToken: nil, maxResults: 50)
            XCTFail()
        } catch { XCTAssertEqual(error as? GmailError, .malformed) }
    }
    func testStructuredFailures() {
        let cases: [(Int, String, GmailError)] = [
            (404, "<html>proxy</html>", .unexplained(404)),
            (404, #"{"error":{"status":"NOT_FOUND"}}"#, .notFound),
            (403, #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#, .scopeMissing),
            (403, #"{"error":{"status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#, .apiDisabled),
            (403, #"{"error":{"status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#, .scopeMissing),
            (401, "", .unauthorized), (503, "", .server(503)),
            (429, "", .limited(.user, retryAfter: 5))]
        for (status, payload, expected) in cases {
            XCTAssertEqual(GmailHTTPRules.failure(status: status, data: Data(payload.utf8), retryAfter: 5), expected)
        }
    }
    func testPathSegmentsCannotChangeEndpoint() throws {
        let request = try GmailHTTP.request(["messages", "a/b?c#d"], token: "fixture")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                       "/gmail/v1/users/me/messages/a%2Fb%3Fc%23d")
        XCTAssertThrowsError(try GmailHTTP.request(["messages", ".."], token: "fixture"))
    }
    func testInvalidPagingNeverStartsNetwork() async {
        ResponseProtocol.response = { _ in XCTFail("Invalid request reached network"); return (200, Data()) }
        for limit in [0, 501] {
            do {
                _ = try await transport().listMessages(token: "fixture", labelIDs: [], query: nil,
                    includeSpamTrash: false, pageToken: nil, maxResults: limit)
                XCTFail()
            } catch { XCTAssertEqual(error as? GmailError, .refused(.invalidArgument)) }
        }
        do { _ = try await transport().history(token: "fixture", start: "-1", pageToken: nil, maxResults: 50); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .refused(.invalidArgument)) }
    }
    func testMetadataRequestIncludesHeaders() async throws {
        ResponseProtocol.response = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "format" }?.value, "metadata")
            let headers = Set(query.filter { $0.name == "metadataHeaders" }.compactMap(\.value))
            XCTAssertTrue(headers.isSuperset(of: ["Subject", "From", "To", "Message-ID"]))
            return (200, Data(#"{"id":"m1"}"#.utf8))
        }
        let message = try await transport().message(token: "fixture", id: "m1", format: .header)
        XCTAssertEqual(message.id, "m1")
    }
    func testCancellationIsNotAnUnknownOutcome() async {
        ResponseProtocol.response = { _ in XCTFail("Cancelled request reached network"); return (200, Data()) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport().profile(token: "fixture")
        }
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testHTTPFailurePropagatesThroughTransport() async {
        ResponseProtocol.response = { _ in (404, Data("<html>proxy failure</html>".utf8)) }
        do { _ = try await transport().message(token: "fixture", id: "m1", format: .header); XCTFail() }
        catch { XCTAssertEqual(error as? GmailError, .unexplained(404)) }
    }
}
