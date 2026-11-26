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
