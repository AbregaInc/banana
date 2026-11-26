import XCTest

/// Whether an account's mail can be used on this device, row by row of MAIL-ENGINE 3.4.
///
/// The rule answers one word per account, from facts that come from four places. The failures
/// worth testing for are the two that mislead a person: telling him Mail is connected when
/// Google has taken the access back, and telling him Mail is not connected when it is working. The
/// second is the quiet one — a token response that carries no scope list must never be read as
/// a list that lacks Gmail — so those cases are written out rather than left to the grid.
final class MailAccountRulesTests: XCTestCase {

    private let gmail = MailScopes.gmailModify
    private let calendar = "https://www.googleapis.com/auth/calendar"

    /// The facts of a working, opened, connected account, each overridable.
    private func state(activated: Bool = true,
                       grant: MailGrant = .granted,
                       scopes: Set<String>? = nil,
                       serverRefused: Bool = false) -> MailAccountState {
        MailAccountRules.state(activatedOnThisDevice: activated,
                               grant: grant, tokenScopes: scopes,
                               serverRefusedScope: serverRefused)
    }

    // MARK: - Row 1: not connected

    /// Never connected with Gmail, or Google refused the grant: not connected, whatever else.
    func testAGrantWithoutGmailIsNotConnectedWhateverElseIsTrue() {
        let missing: [MailGrant] = [.none, .rejected(reason: .invalidGrant),
                                    .rejected(reason: .clientRejected), .rejected(reason: .emptyCredential)]
        for grant in missing {
            for activated in [false, true] {
                for refused in [false, true] {
                    for scopes in [nil, [calendar], [gmail]] as [Set<String>?] {
                        XCTAssertEqual(
                            state(activated: activated, grant: grant, scopes: scopes, serverRefused: refused),
                            .notConnected, "grant \(grant) is not connected")
                    }
                }
            }
        }
    }

    func testAGmailAnswerOf403ForAMissingScopeIsNotConnected() {
        XCTAssertEqual(state(serverRefused: true), .notConnected)
        XCTAssertEqual(state(scopes: [gmail], serverRefused: true), .notConnected,
                       "what Gmail says outranks what a token response claimed")
        XCTAssertEqual(state(activated: false, serverRefused: true), .notConnected)
    }

    func testATokenWhoseKnownScopesLackGmailIsNotConnected() {
        XCTAssertEqual(state(scopes: [calendar]), .notConnected)
        XCTAssertEqual(state(scopes: [calendar, "openid"]), .notConnected)
        XCTAssertEqual(state(activated: false, scopes: [calendar]), .notConnected)
    }

    /// The quiet failure: a response that did not say which scopes the token carries is not a
    /// response that says it lacks Gmail.
    func testUnknownScopesDoNotDisconnectAWorkingAccount() {
        XCTAssertEqual(state(scopes: nil), .connected)
    }

    func testKnownScopesThatIncludeGmailStayConnected() {
        XCTAssertEqual(state(scopes: [gmail]), .connected)
        XCTAssertEqual(state(scopes: [calendar, gmail, "openid"]), .connected)
    }

    // MARK: - Rows 2 and 3: waiting, connected

    func testAConnectedAccountThisDeviceHasNotOpenedIsWaitingForTheFirstOpen() {
        XCTAssertEqual(state(activated: false), .waitingForFirstOpen)
        XCTAssertEqual(state(activated: false, scopes: [gmail]), .waitingForFirstOpen)
    }

    func testAConnectedAccountThisDeviceHasOpenedIsConnected() {
        XCTAssertEqual(state(activated: true), .connected)
    }

    // MARK: - The kind of a rejection

    /// What the minter's summary looks like: Google's code, a colon, Google's sentence.
    func testInvalidGrantReadsAsInvalidGrant() {
        XCTAssertEqual(MailGrantRejection(oauthSummary: "invalid_grant: Token has been expired or revoked."),
                       .invalidGrant)
    }

    func testInvalidClientReadsAsClientRejected() {
        XCTAssertEqual(MailGrantRejection(oauthSummary: "invalid_client: The OAuth client was not found."),
                       .clientRejected)
    }

    func testUnauthorizedClientReadsAsClientRejected() {
        XCTAssertEqual(MailGrantRejection(oauthSummary: "unauthorized_client: Client is unauthorized."),
                       .clientRejected)
    }

    func testNoSummaryReadsAsInvalidGrant() {
        XCTAssertEqual(MailGrantRejection(oauthSummary: nil), .invalidGrant)
    }

    func testASummaryWeDoNotRecogniseReadsAsInvalidGrant() {
        XCTAssertEqual(MailGrantRejection(oauthSummary: "something_new: nobody has seen this"),
                       .invalidGrant)
        XCTAssertEqual(MailGrantRejection(oauthSummary: ""), .invalidGrant)
        XCTAssertEqual(MailGrantRejection(oauthSummary: ":"), .invalidGrant)
    }

    /// With no description the minter's summary is the code alone: there is no colon, so the
    /// whole text is the code.
    func testASummaryThatIsOnlyACodeIsReadAsThatCode() {
        XCTAssertEqual(MailGrantRejection(oauthSummary: "invalid_client"), .clientRejected)
        XCTAssertEqual(MailGrantRejection(oauthSummary: "invalid_grant"), .invalidGrant)
    }

    /// Only the text before the first colon is read. Google's sentence may say anything,
    /// including another code's name.
    func testOnlyTheCodeBeforeTheFirstColonIsRead() {
        XCTAssertEqual(MailGrantRejection(oauthSummary: "invalid_grant: not an invalid_client: really"),
                       .invalidGrant)
        XCTAssertEqual(MailGrantRejection(oauthSummary: "you saw invalid_client: here"),
                       .invalidGrant)
    }

    func testTheRejectionKindIsNeverReadFromAnEmptyCredentialSummary() {
        XCTAssertEqual(MailGrantRejection(oauthSummary: "emptyCredential"), .invalidGrant,
                       "an empty credential is the access object's finding, not Google's")
    }

    /// The kind is kept, so a renamed case would silently change what a stored value means.
    func testTheStoredFormOfARejectionKind() throws {
        XCTAssertEqual(MailGrantRejection.invalidGrant.rawValue, "invalidGrant")
        XCTAssertEqual(MailGrantRejection.clientRejected.rawValue, "clientRejected")
        XCTAssertEqual(MailGrantRejection.emptyCredential.rawValue, "emptyCredential")
        let json = try JSONEncoder().encode([MailGrantRejection.clientRejected])
        XCTAssertEqual(String(decoding: json, as: UTF8.self), "[\"clientRejected\"]")
    }
}
