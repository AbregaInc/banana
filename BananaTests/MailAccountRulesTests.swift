import XCTest

/// Whether an account's mail can be used on this device, row by row of MAIL-ENGINE 3.4.
///
/// The rule answers one word per account, from facts that come from four places. The failures
/// worth testing for are the two that mislead a person: telling him Mail is connected when
/// Google has taken the access back, and telling him Mail needs access when it is working. The
/// second is the quiet one — a token response that carries no scope list must never be read as
/// a list that lacks Gmail — so those cases are written out rather than left to the grid.
final class MailAccountRulesTests: XCTestCase {

    private let gmail = MailScopes.gmailModify
    private let calendar = "https://www.googleapis.com/auth/calendar"

    /// The facts of a working, opened, turned-on account, each overridable.
    private func state(wantsMail: Bool = true,
                       activated: Bool = true,
                       grant: MailGrant = .granted,
                       scopes: Set<String>? = nil,
                       serverRefused: Bool = false) -> MailAccountState {
        MailAccountRules.state(wantsMail: wantsMail, activatedOnThisDevice: activated,
                               grant: grant, tokenScopes: scopes,
                               serverRefusedScope: serverRefused)
    }

    private let everyGrant: [MailGrant] = [
        .none, .granted,
        .rejected(reason: .invalidGrant), .rejected(reason: .clientRejected),
        .rejected(reason: .emptyCredential),
    ]

    // MARK: - Row 1: off

    func testAccountWithMailTurnedOffIsOff() {
        XCTAssertEqual(state(wantsMail: false), .off)
    }

    /// Nothing about the credential may show through while Mail is off: an account he has not
    /// turned on is not one whose access he needs to hear about.
    func testMailTurnedOffIsOffWhateverElseIsTrue() {
        for grant in everyGrant {
            for activated in [false, true] {
                for refused in [false, true] {
                    for scopes in [nil, [], [calendar], [gmail]] as [Set<String>?] {
                        XCTAssertEqual(
                            state(wantsMail: false, activated: activated, grant: grant,
                                  scopes: scopes, serverRefused: refused),
                            .off,
                            "Mail off must hide grant \(grant), scopes \(String(describing: scopes))")
                    }
                }
            }
        }
    }

    // MARK: - Row 2: not allowed here

    /// Declining Mail, or never having been asked on this device, is a grant of none.
    func testDecliningMailIsNotAllowedHere() {
        XCTAssertEqual(state(grant: .none), .needsAccess(.notAllowedHere))
    }

    func testNotAllowedHereComesBeforeEveryLaterRow() {
        for activated in [false, true] {
            for refused in [false, true] {
                for scopes in [nil, [calendar], [gmail]] as [Set<String>?] {
                    XCTAssertEqual(
                        state(activated: activated, grant: .none, scopes: scopes,
                              serverRefused: refused),
                        .needsAccess(.notAllowedHere),
                        "an account never allowed here is not 'withdrawn' or 'waiting'")
                }
            }
        }
    }

    // MARK: - Row 3: withdrawn

    func testAGrantGoogleRejectedIsWithdrawnForEveryReason() {
        for reason in [MailGrantRejection.invalidGrant, .clientRejected, .emptyCredential] {
            XCTAssertEqual(state(grant: .rejected(reason: reason)), .needsAccess(.withdrawn),
                           "a credential Google refused (\(reason)) needs allowing again")
        }
    }

    func testAGmailAnswerOf403ForAMissingScopeIsWithdrawn() {
        XCTAssertEqual(state(serverRefused: true), .needsAccess(.withdrawn))
    }

    /// What Gmail itself says outranks what a token response claimed: a token that lists Gmail
    /// and is refused for a missing scope is a withdrawn account.
    func testAGmailAnswerOf403BeatsATokenResponseThatNamesGmail() {
        XCTAssertEqual(state(scopes: [gmail], serverRefused: true), .needsAccess(.withdrawn))
    }

    func testATokenWhoseKnownScopesLackGmailIsWithdrawn() {
        XCTAssertEqual(state(scopes: [calendar]), .needsAccess(.withdrawn))
        XCTAssertEqual(state(scopes: [calendar, "openid"]), .needsAccess(.withdrawn))
    }

    /// The quiet failure: a response that did not say which scopes the token carries is not a
    /// response that says it lacks Gmail.
    func testUnknownScopesDoNotWithdrawAWorkingAccount() {
        XCTAssertEqual(state(scopes: nil), .connected)
    }

    func testKnownScopesThatIncludeGmailDoNotWithdraw() {
        XCTAssertEqual(state(scopes: [gmail]), .connected)
        XCTAssertEqual(state(scopes: [calendar, gmail, "openid"]), .connected)
    }

    func testWithdrawnComesBeforeWaitingForTheFirstOpen() {
        XCTAssertEqual(state(activated: false, grant: .rejected(reason: .invalidGrant)),
                       .needsAccess(.withdrawn))
        XCTAssertEqual(state(activated: false, serverRefused: true), .needsAccess(.withdrawn))
        XCTAssertEqual(state(activated: false, scopes: [calendar]), .needsAccess(.withdrawn))
    }

    /// A rejected grant is withdrawn however good the other facts look, and whichever way the
    /// scope facts point.
    func testARejectedGrantIsWithdrawnWhateverTheScopesSay() {
        for refused in [false, true] {
            for scopes in [nil, [calendar], [gmail]] as [Set<String>?] {
                XCTAssertEqual(
                    state(grant: .rejected(reason: .clientRejected), scopes: scopes,
                          serverRefused: refused),
                    .needsAccess(.withdrawn))
            }
        }
    }

    // MARK: - Rows 4 and 5: waiting, connected

    func testAnAllowedAccountThisDeviceHasNotOpenedIsWaitingForTheFirstOpen() {
        XCTAssertEqual(state(activated: false), .waitingForFirstOpen)
        XCTAssertEqual(state(activated: false, scopes: [gmail]), .waitingForFirstOpen)
    }

    func testAnAllowedAccountThisDeviceHasOpenedIsConnected() {
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
