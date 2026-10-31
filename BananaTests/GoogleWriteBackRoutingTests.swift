import XCTest

/// Exclusions made against Apple Calendar named a Google account the way Apple did. Matching that
/// name to an account must accept the address, decorated or not, and nothing else.
final class GoogleAccountNameMatchingTests: XCTestCase {
    func testTheAddressMatchesHoweverAppleDecoratedIt() {
        XCTAssertTrue(GoogleCalendarRouting.sourceIsAccount("bo@zeta.example", account: "bo@zeta.example"))
        XCTAssertTrue(GoogleCalendarRouting.sourceIsAccount("Bo@Zeta.example", account: "bo@zeta.example"))
        XCTAssertTrue(GoogleCalendarRouting.sourceIsAccount("Google (bo@zeta.example)", account: "bo@zeta.example"))
    }

    func testAnotherAccountOrProviderDoesNotMatch() {
        XCTAssertFalse(GoogleCalendarRouting.sourceIsAccount("bo@dewey.example", account: "bo@zeta.example"))
        XCTAssertFalse(GoogleCalendarRouting.sourceIsAccount("iCloud", account: "bo@zeta.example"))
        XCTAssertFalse(GoogleCalendarRouting.sourceIsAccount("anything", account: ""),
                       "an account with no address matches nothing")
    }
}
