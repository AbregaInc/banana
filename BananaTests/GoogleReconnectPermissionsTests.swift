import XCTest

final class GoogleReconnectPermissionsTests: XCTestCase {
    private let read = "https://www.googleapis.com/auth/gmail.readonly"
    private let modify = "https://www.googleapis.com/auth/gmail.modify"
    private func requested(_ mail: [String], readable: Bool = false, enabled: Bool = true) -> Set<String> {
        Set(GoogleReconnectPermissions.scopes(calendar: ["calendar-read"], mail: mail, readable: readable,
            enabled: enabled, additional: ["contacts-read"]))
    }
    func testCalendarOnlyDoesNotEnrollInMail() {
        XCTAssertEqual(requested(["calendar-read"]), ["calendar-read"])
    }
    func testPreviouslyEnabledReadOnlyMailReconnectsWithWritePermission() {
        XCTAssertEqual(requested([read]), ["calendar-read", modify, "contacts-read"])
    }
    func testDisabledFeatureDoesNotRequestItsPermissions() {
        XCTAssertEqual(requested([modify], enabled: false), ["calendar-read"])
    }
    func testReconnectUpgradesMailWhenOnlyTheReadCapabilityWasReported() {
        XCTAssertEqual(requested([], readable: true), ["calendar-read", modify, "contacts-read"])
    }
    func testExistingGrantedScopesArePreservedAndDeduplicated() {
        let result = GoogleReconnectPermissions.scopes(calendar: ["calendar-read"], mail: [modify, "calendar-read"],
            readable: true, enabled: true, additional: ["contacts-read", "contacts-read"])
        XCTAssertEqual(result, Set(result).sorted())
        XCTAssertEqual(Set(result), ["calendar-read", modify, "contacts-read"])
    }
}
