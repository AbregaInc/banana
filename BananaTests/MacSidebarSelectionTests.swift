import XCTest

/// The Mac sidebar selects its rows by their ids (`AppSection.chosen`): a badge or any other
/// modifier on a row can't stop a click from reaching its section.
final class MacSidebarSelectionTests: XCTestCase {
    func testARowsIdChoosesItsSection() {
        for section in AppSection.macSidebar {
            XCTAssertEqual(AppSection.chosen(section.id, current: .settings), section)
        }
    }

    func testMailIsARowOfItsOwnAndSecond() {
        XCTAssertEqual(AppSection.macSidebar.map(\.id).prefix(3), ["plan", "mail", "workouts"])
        XCTAssertEqual(AppSection.chosen("mail", current: .plan), .mail)
    }

    func testNoRowOrAnUnknownIdKeepsTheSection() {
        XCTAssertEqual(AppSection.chosen(nil, current: .nutrition), .nutrition)
        XCTAssertEqual(AppSection.chosen("rhythm", current: .plan), .plan)
    }
}
