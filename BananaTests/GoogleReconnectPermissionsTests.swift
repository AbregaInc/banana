import XCTest

final class GoogleReconnectPermissionsTests: XCTestCase {
    private let read = "https://www.googleapis.com/auth/gmail.readonly"
    private let modify = "https://www.googleapis.com/auth/gmail.modify"
    private func requested(_ mail: [String], readable: Bool = false, modifiable: Bool = false, enabled: Bool = true) -> Set<String> {
        Set(GoogleReconnectPermissions.scopes(calendar: ["calendar-read"], mail: mail, readable: readable,
            modifiable: modifiable, enabled: enabled, additional: ["contacts-read"]))
    }
    func testCalendarOnlyDoesNotEnrollInMail() {
        XCTAssertEqual(requested(["calendar-read"]), ["calendar-read"])
    }
    func testRefusedMailGrantCanBeRestoredWithNewRequirements() {
        XCTAssertEqual(requested([read]), ["calendar-read", read, "contacts-read"])
        XCTAssertFalse(requested([read]).contains(modify))
    }
    func testDisabledFeatureDoesNotRequestItsPermissions() {
        XCTAssertEqual(requested([modify], enabled: false), ["calendar-read"])
    }
    func testOlderServiceCanPreserveKnownReadOnlyAccess() {
        XCTAssertEqual(requested([], readable: true), ["calendar-read", read, "contacts-read"])
    }
    func testExistingGrantedScopesArePreservedAndDeduplicated() {
        let result = GoogleReconnectPermissions.scopes(calendar: ["calendar-read"], mail: [modify, "calendar-read"],
            readable: true, modifiable: true, enabled: true, additional: ["contacts-read", "contacts-read"])
        XCTAssertEqual(result, Set(result).sorted())
        XCTAssertEqual(Set(result), ["calendar-read", modify, "contacts-read"])
    }
}
