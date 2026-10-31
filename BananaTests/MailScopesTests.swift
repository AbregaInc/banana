import XCTest

/// Reading the scopes out of a token response.
///
/// The one thing that matters here is the empty case. Whether the scopes are *known* decides
/// whether an account can be marked withdrawn, so "Google did not say" and "Google said none"
/// must never be the same value: nil is unknown and the empty set is never produced. A working
/// account marked withdrawn because one response left the field out is the failure.
final class MailScopesTests: XCTestCase {

    private let gmail = "https://www.googleapis.com/auth/gmail.modify"

    func testGmailModifyIsGooglesOwnName() {
        XCTAssertEqual(MailScopes.gmailModify, "https://www.googleapis.com/auth/gmail.modify")
    }

    func testNoScopeFieldIsUnknown() {
        XCTAssertNil(MailScopes.parse(nil))
    }

    func testAnEmptyScopeFieldIsUnknownNeverTheEmptySet() {
        XCTAssertNil(MailScopes.parse(""),
                     "an empty `scope` must not read as a list that lacks Gmail")
    }

    func testAScopeFieldOfOnlyBlanksIsUnknownToo() {
        XCTAssertNil(MailScopes.parse("   "))
        XCTAssertNil(MailScopes.parse(" \t\n"))
    }

    func testASingleScopeIsASetOfOne() {
        XCTAssertEqual(MailScopes.parse(gmail), [gmail])
    }

    func testASpaceSeparatedListIsThatSet() {
        let field = "openid https://www.googleapis.com/auth/userinfo.email \(gmail)"
        XCTAssertEqual(MailScopes.parse(field),
                       ["openid", "https://www.googleapis.com/auth/userinfo.email", gmail])
    }

    func testExtraSpacesBetweenAndAroundScopesAreIgnored() {
        XCTAssertEqual(MailScopes.parse("  openid   \(gmail)  "), ["openid", gmail])
    }

    func testAScopeListedTwiceIsOneScope() {
        XCTAssertEqual(MailScopes.parse("\(gmail) \(gmail)"), [gmail])
    }

    func testAListWithoutGmailParsesToASetWithoutGmail() throws {
        let scopes = try XCTUnwrap(MailScopes.parse("openid https://www.googleapis.com/auth/calendar"))
        XCTAssertFalse(scopes.contains(MailScopes.gmailModify))
    }

    /// The whole reason for the nil: an account whose token response carried no scope field is
    /// still a working account.
    func testATerseTokenResponseDoesNotWithdrawAWorkingAccount() {
        for field in [nil, "", "  "] as [String?] {
            XCTAssertEqual(
                MailAccountRules.state(wantsMail: true, activatedOnThisDevice: true,
                                       grant: .granted, tokenScopes: MailScopes.parse(field),
                                       serverRefusedScope: false),
                .connected)
        }
    }

    func testAResponseThatNamesOnlyOtherScopesDoesWithdraw() {
        XCTAssertEqual(
            MailAccountRules.state(wantsMail: true, activatedOnThisDevice: true,
                                   grant: .granted,
                                   tokenScopes: MailScopes.parse("openid email"),
                                   serverRefusedScope: false),
            .needsAccess(.withdrawn))
    }
}
