import XCTest

final class CalendarEventTitlePolicyTests: XCTestCase {
    func testUserAuthoredBlockedEventIsVisible() {
        XCTAssertFalse(CalendarEventTitlePolicy.isPrivacyPlaceholder("Blocked"))
    }

    func testGenericBusyPlaceholderRemainsHidden() {
        XCTAssertTrue(CalendarEventTitlePolicy.isPrivacyPlaceholder("Busy"))
    }
}
