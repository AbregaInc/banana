import XCTest

final class GoogleReconnectPermissionsTests: XCTestCase {
    private let calendar = [GoogleScopes.calendarEvents, GoogleScopes.calendarList]
    private let read = "https://www.googleapis.com/auth/gmail.readonly"
    private let full = "https://mail.google.com/"
    private let modify = MailScopes.gmailModify
    private var mailSet: Set<String> { Set(calendar + [modify] + MailScopes.senderPhotos) }

    private func requested(_ mail: [String], readable: Bool = false, enabled: Bool = true) -> Set<String> {
        Set(GoogleReconnectPermissions.scopes(calendar: calendar, mail: mail, readable: readable, enabled: enabled))
    }

    func testCalendarOnlyDoesNotEnrollInMail() {
        XCTAssertEqual(requested(calendar), Set(calendar))
        XCTAssertEqual(requested([]), Set(calendar))
    }
    func testDisabledFeatureDoesNotRequestItsPermissions() {
        XCTAssertEqual(requested([modify], enabled: false), Set(calendar))
    }
    func testEveryEarlierMailGrantComesBackAsTheSubmittedScopes() {
        for mail in [[modify], [read], [full], [read, modify, "https://www.googleapis.com/auth/calendar", "openid"]] {
            XCTAssertEqual(requested(mail), mailSet, "\(mail)")
        }
        XCTAssertEqual(requested([], readable: true), mailSet)
    }
    func testReconnectAsksOnlyForSubmittedScopes() {
        for mail in [[], [modify], [read], [full]] {
            XCTAssertTrue(requested(mail, readable: true).isSubset(of: GoogleScopes.submitted), "\(mail)")
        }
    }
    func testResultIsSortedWithoutRepeats() {
        let result = GoogleReconnectPermissions.scopes(calendar: calendar + calendar, mail: [modify], readable: true, enabled: true)
        XCTAssertEqual(result, Set(result).sorted())
    }
}

/// Every Google sign-in is cut to the scopes submitted for OAuth verification.
final class GoogleScopesTests: XCTestCase {
    func testSubmittedIsExactlyTheVerifiedSet() {
        XCTAssertEqual(GoogleScopes.submitted, [
            "https://www.googleapis.com/auth/calendar.events",
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            "https://www.googleapis.com/auth/gmail.modify",
            "https://www.googleapis.com/auth/contacts.readonly",
            "https://www.googleapis.com/auth/contacts.other.readonly",
        ])
    }
    func testUnsubmittedScopesAreDropped() {
        let asked = [GoogleScopes.calendarEvents, "https://www.googleapis.com/auth/gmail.readonly",
                     "https://mail.google.com/", "https://www.googleapis.com/auth/calendar", MailScopes.gmailModify,
                     MailScopes.gmailModify]
        XCTAssertEqual(GoogleScopes.allowed(asked), [GoogleScopes.calendarEvents, MailScopes.gmailModify].sorted())
    }
}
