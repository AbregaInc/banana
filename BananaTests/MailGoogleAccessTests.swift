import XCTest

@MainActor
final class MailGoogleAccessTests: XCTestCase {
    private actor Store: MailCredentialStorage {
        var values: [MailCredential] = []
        var fail = false
        func load() throws -> [MailCredential] { values }
        func save(_ credentials: [MailCredential]) throws {
            if fail { throw MailAccessError.credentialStorage }
            values = credentials
        }
        func setFailure(_ value: Bool) { fail = value }
    }

    private func result(email: String = "a@example.com", scopes: [String] = [MailScopes.gmailModify]) -> GoogleConsentResult {
        .init(email: email, refreshToken: "fixture-refresh", grantedScopes: scopes)
    }

    func testConsentPersistsBeforeGrantAndCanReload() async throws {
        let store = Store()
        let response = result()
        let access = try await MailGoogleAccess.load(storage: store, accountIDs: { ["a@example.com"] },
            clientID: { "fixture-client" }, consent: { id, scopes in
                XCTAssertEqual(id, "a@example.com"); XCTAssertEqual(scopes, [MailScopes.gmailModify]); return response
            }, mint: { token, client, session in
                XCTAssertEqual(token, "fixture-refresh"); XCTAssertEqual(client, "fixture-client")
                XCTAssertEqual(session.configuration.timeoutIntervalForResource, 20)
                XCTAssertNil(session.configuration.urlCache)
                XCTAssertNil(session.configuration.httpCookieStorage)
                XCTAssertTrue(session.delegate is MailGoogleAccess.NoRedirect)
                return .init(accessToken: "fixture-access", expiresAt: Date().addingTimeInterval(3600))
            })
        let outcome = await access.requestMailAccess(accountID: "A@EXAMPLE.COM")
        XCTAssertEqual(outcome, .granted)
        XCTAssertEqual(access.mailGrant(accountID: "a@example.com"), .granted)
        let saved = try await store.load(); XCTAssertEqual(saved.count, 1)
        let token = try await access.mailAccessToken(accountID: "a@example.com")
        XCTAssertEqual(token.value, "fixture-access")
        let restored = try await MailGoogleAccess.load(storage: store, accountIDs: { ["a@example.com"] },
            clientID: { "fixture-client" }, consent: { _, _ in throw GoogleConsentError.cancelled })
        XCTAssertEqual(restored.mailGrant(accountID: "a@example.com"), .granted)
    }

    func testTokenSessionRefusesRedirect() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://oauth2.googleapis.com/token")!
        let redirect = URLRequest(url: URL(string: "https://example.com/unexpected")!)
        let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var answered = false
        MailGoogleAccess.NoRedirect().urlSession(session, task: session.dataTask(with: original),
            willPerformHTTPRedirection: response, newRequest: redirect) { request in
                XCTAssertNil(request); answered = true
            }
        XCTAssertTrue(answered)
    }

    func testFailedPersistenceNeverAcknowledgesConsent() async throws {
        let store = Store(); await store.setFailure(true)
        let response = result()
        let access = try await MailGoogleAccess.load(storage: store, accountIDs: { ["a@example.com"] },
            clientID: { "fixture-client" }, consent: { _, _ in response })
        let outcome = await access.requestMailAccess(accountID: "a@example.com")
        XCTAssertEqual(outcome, .failed(.credentialStorage))
        XCTAssertEqual(access.mailGrant(accountID: "a@example.com"), .none)
    }

    func testWrongAccountAndMissingScopeNeverPersist() async throws {
        for (response, expected) in [(result(email: "other@example.com"), MailAccessOutcome.differentAccount),
                                     (result(scopes: []), .declined)] {
            let store = Store()
            let access = try await MailGoogleAccess.load(storage: store, accountIDs: { ["a@example.com"] },
                clientID: { "fixture-client" }, consent: { _, _ in response })
            let outcome = await access.requestMailAccess(accountID: "a@example.com")
            XCTAssertEqual(outcome, expected)
            let saved = try await store.load(); XCTAssertTrue(saved.isEmpty)
        }
    }

    func testMissingConfigurationDoesNotPresentConsent() async throws {
        let access = try await MailGoogleAccess.load(storage: Store(), accountIDs: { ["a@example.com"] },
            clientID: { nil }, consent: { _, _ in XCTFail("Must not present"); throw GoogleConsentError.failed })
        let outcome = await access.requestMailAccess(accountID: "a@example.com")
        XCTAssertEqual(outcome, .failed(.notConfigured))
    }

    func testCredentialDecodeAllowsOlderOptionalFields() throws {
        let c = try JSONDecoder().decode(MailCredential.self,
            from: Data(#"{"email":"A@example.com","refreshToken":"fixture"}"#.utf8))
        XCTAssertEqual(c.id, "a@example.com"); XCTAssertNil(c.scopes); XCTAssertNil(c.grantedAt)
    }
}
