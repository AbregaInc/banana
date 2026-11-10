import XCTest

/// A person's face in the list and on a message (MailFace): their initial and a colour of their own.
final class MailFaceTests: XCTestCase {
    private func person(_ name: String?, _ address: String, me: Bool = false) -> MailPerson {
        MailPerson(name: name, address: address, isMe: me, isKnown: false, fromTheirMail: false)
    }

    func testInitialIsTheFirstLetterOfTheNameElseTheAddress() {
        XCTAssertEqual(MailFace(person("Ann Lee", "ann@example.com")).initial, "A")
        XCTAssertEqual(MailFace(person("[Plan] weekly", "x@example.com")).initial, "P")
        XCTAssertEqual(MailFace(person("élan", "e@example.com")).initial, "É")
        XCTAssertEqual(MailFace(person(nil, "noor@plan.example")).initial, "N")
        XCTAssertEqual(MailFace(person("123", "456@example.com")).initial, "E")
        XCTAssertEqual(MailFace(person(nil, "1@2.3")).initial, "?")
    }

    func testTheSameAddressHasTheSameColourWhateverItsCase() {
        let a = MailFace(person("Ann", "Ann@Example.com")), b = MailFace(person("Annie", "ann@example.com"))
        XCTAssertEqual(a.hue, b.hue)
        XCTAssertTrue((0..<MailFace.hueCount).contains(a.hue))
        // Spread: forty addresses use more than half the colours.
        let hues = Set((0..<40).map { MailFace.hue("person\($0)@example.com") })
        XCTAssertGreaterThan(hues.count, MailFace.hueCount / 2)
    }

    func testARowShowsTheFirstPersonWhoIsNotHim() {
        let me = person("Noor", "noor@plan.example", me: true), ann = person("Ann", "ann@example.com")
        XCTAssertEqual(MailFace.of([me, ann]), MailFace(ann))
        XCTAssertEqual(MailFace.of([me]), MailFace(me))
        XCTAssertNil(MailFace.of([]))
    }
}
