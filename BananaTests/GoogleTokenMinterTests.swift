import XCTest

final class GoogleTokenMinterTests: XCTestCase {
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

    func testInjectedTransportAndOAuthFailureClassification() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for (status, payload, rejected) in [(400, #"{"error":"invalid_grant"}"#, true),
                                          (503, #"{"error":"temporarily_unavailable"}"#, false),
                                          (400, #"{"error":"rate_limit_exceeded"}"#, false)] {
            ResponseProtocol.response = { request in
                XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
                XCTAssertEqual(request.httpMethod, "POST")
                return (status, Data(payload.utf8))
            }
            do {
                _ = try await GoogleTokenMinter.mint(refreshToken: "fixture", clientID: "fixture", session: session)
                XCTFail("Expected failed refresh")
            } catch let error as GoogleTokenMinter.MintError {
                switch error {
                case .credentialRejected: XCTAssertTrue(rejected)
                case .transport: XCTAssertFalse(rejected)
                }
            }
        }
        ResponseProtocol.response = { _ in
            (200, Data(#"{"access_token":"fixture-access","expires_in":3600,"scope":"gmail-scope"}"#.utf8))
        }
        let token = try await GoogleTokenMinter.mint(refreshToken: "fixture", clientID: "fixture", session: session)
        XCTAssertEqual(token.accessToken, "fixture-access")
        XCTAssertEqual(token.scopes, ["gmail-scope"])
    }
    func testRefreshFormRoundTripsOpaqueValues() {
        let body = GoogleTokenMinter.refreshBody(refreshToken: "secret+with&=/% 雪", clientID: "client+&=")
        let values = String(decoding: body, as: UTF8.self).split(separator: "&").map {
            $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding! }
        }
        XCTAssertEqual(values, [["client_id", "client+&="], ["refresh_token", "secret+with&=/% 雪"],
                                ["grant_type", "refresh_token"]])
    }

    func testExpiryMarginAndScopes() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let result = try XCTUnwrap(GoogleTokenMinter.token(from: Data(#"{"access_token":"opaque","expires_in":3600,"scope":"one two one"}"#.utf8), now: now))
        XCTAssertEqual(result.accessToken, "opaque")
        XCTAssertEqual(result.expiresAt, now.addingTimeInterval(3540))
        XCTAssertEqual(result.scopes, ["one", "two"])
    }

    func testMissingAndEmptyScopesRemainUnknown() throws {
        for scope in ["", ",\"scope\":\"   \""] {
            let data = Data("{\"access_token\":\"opaque\",\"expires_in\":30\(scope)}".utf8)
            let now = Date(timeIntervalSince1970: 1000)
            let token = try XCTUnwrap(GoogleTokenMinter.token(from: data, now: now))
            XCTAssertNil(token.scopes)
            XCTAssertEqual(token.expiresAt, now)
        }
    }

    func testUnusableSuccessPayloadsAreRejected() {
        for json in [#"{"access_token":"","expires_in":3600}"#,
                     #"{"access_token":"  ","expires_in":3600}"#,
                     #"{"access_token":"opaque","expires_in":0}"#,
                     #"{"access_token":"opaque","expires_in":-1}"#, "{}", "not-json"] {
            XCTAssertNil(GoogleTokenMinter.token(from: Data(json.utf8), now: Date()))
        }
    }
}
