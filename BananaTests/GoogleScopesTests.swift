import XCTest

/// Every Google consent asks for the whole submitted set, never more.
final class GoogleScopesTests: XCTestCase {
    func testEveryConsentAsksForExactlyTheVerifiedSet() {
        XCTAssertEqual(GoogleScopes.all, [
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            "https://www.googleapis.com/auth/calendar.events",
            "https://www.googleapis.com/auth/contacts.other.readonly",
            "https://www.googleapis.com/auth/contacts.readonly",
            "https://www.googleapis.com/auth/gmail.modify",
        ])
    }
    func testItCarriesWhatCalendarAndMailEachNeed() {
        let all = Set(GoogleScopes.all)
        XCTAssertTrue(all.isSuperset(of: [GoogleScopes.calendarEvents, GoogleScopes.calendarList]))
        XCTAssertTrue(all.isSuperset(of: [MailScopes.gmailModify] + MailScopes.senderPhotos))
        XCTAssertEqual(EmailSetup.gmailScope, MailScopes.gmailModify)
    }
}

/// A consent that comes back without a permission is explained and asked again.
final class GoogleScopesMissingTests: XCTestCase {
    func testEveryPermissionIsCoveredByTheRequestAndTheRequestByThem() {
        XCTAssertEqual(Set(GoogleScopes.permissions.flatMap(\.scopes)), Set(GoogleScopes.all))
        XCTAssertEqual(GoogleScopes.permissions, [.calendar, .gmail, .contacts])
    }
    func testAFullGrantMissesNothing() {
        XCTAssertEqual(GoogleScopes.missing(granted: Set(GoogleScopes.all) .union(["openid", "email"])), [])
    }
    func testEachUntickedBoxIsNamedOnce() {
        let all = Set(GoogleScopes.all)
        XCTAssertEqual(GoogleScopes.missing(granted: all.subtracting([MailScopes.gmailModify])), [.gmail])
        XCTAssertEqual(GoogleScopes.missing(granted: all.subtracting([GoogleScopes.calendarList])), [.calendar],
                       "half of the calendar is the calendar missing")
        XCTAssertEqual(GoogleScopes.missing(granted: all.subtracting(MailScopes.senderPhotos + [MailScopes.gmailModify])), [.gmail, .contacts])
        XCTAssertEqual(GoogleScopes.missing(granted: []), [.calendar, .gmail, .contacts])
    }
}
