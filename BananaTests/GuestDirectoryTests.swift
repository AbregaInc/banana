import XCTest

/// Who "Sam" is when an event is typed "Lunch with Sam" (`GuestDirectory`): favourites — the
/// people you meet most, and whoever you picked for that name before — first.
final class GuestDirectoryTests: XCTestCase {
    private let samLee = GuestPerson(email: "sam.lee@example.com", name: "Sam Lee", met: 6)
    private let samOrtiz = GuestPerson(email: "Sam.Ortiz@example.com", name: "Sam Ortiz", met: 1, inContacts: true)
    private let jess = GuestPerson(email: "jess.park@example.com", name: "Jess Park", met: 2)

    func testNamesAfterWith() {
        XCTAssertEqual(GuestDirectory.names(in: "Lunch with Sam tomorrow at 1pm at Balthazar"), ["Sam"])
        XCTAssertEqual(GuestDirectory.names(in: "dinner w/ Jess and Ana Lee on Friday"), ["Jess", "Ana Lee"])
        XCTAssertEqual(GuestDirectory.names(in: "Call with Sam, Jess & Ana 3pm"), ["Sam", "Jess", "Ana"])
        XCTAssertEqual(GuestDirectory.names(in: "Sync with the team at 10"), [], "not a person")
        XCTAssertEqual(GuestDirectory.names(in: "Gym at 7"), [])
        XCTAssertEqual(GuestDirectory.emails(in: "Intro with Ana@Example.com Friday"), ["ana@example.com"])
    }

    func testAFavouriteWinsOverSomeoneSeldomMet() {
        XCTAssertEqual(GuestDirectory.best("Sam", in: [samOrtiz, samLee, jess])?.email, "sam.lee@example.com")
        XCTAssertEqual(GuestDirectory.matches("sam", in: [samOrtiz, samLee]).map(\.email),
                       ["sam.lee@example.com", "sam.ortiz@example.com"])
    }

    func testTwoAlikeAreAskedAbout() {
        let other = GuestPerson(email: "sam.kim@example.com", name: "Sam Kim", met: 5)
        XCTAssertNil(GuestDirectory.best("Sam", in: [samLee, other]), "neither is clearly the one")
    }

    func testThePersonPickedBeforeWins() {
        XCTAssertEqual(GuestDirectory.best("Sam", in: [samLee, samOrtiz], picks: ["sam.ortiz@example.com": 1])?.email,
                       "sam.ortiz@example.com")
    }

    func testAFullerNameNarrowsIt() {
        XCTAssertEqual(GuestDirectory.best("Sam Ortiz", in: [samLee, samOrtiz])?.email, "sam.ortiz@example.com")
        XCTAssertEqual(GuestDirectory.best("sam o", in: [samLee, samOrtiz])?.email, "sam.ortiz@example.com")
    }

    func testAnAddressWithNoNameStillAnswers() {
        let bare = GuestPerson(email: "jsmith@gmail.example", met: 3)
        let dotted = GuestPerson(email: "natalie.jones@gmail.example", met: 1)
        XCTAssertEqual(GuestDirectory.best("natalie", in: [bare, dotted])?.email, "natalie.jones@gmail.example")
        XCTAssertEqual(GuestDirectory.best("smith", in: [bare, dotted])?.email, "jsmith@gmail.example")
    }

    func testAnAddressTypedIsThatPerson() {
        XCTAssertEqual(GuestDirectory.best("new@example.com", in: [samLee])?.email, "new@example.com")
    }

    func testCalendarsAndContactsMergeByAddress() {
        let fromCalendar = GuestDirectory.fromEvents([
            (attendees: [("sam.lee@example.com", nil, false), ("me@x.com", nil, true), ("room@resource.calendar.google.com", "Room", false)],
             start: Date(timeIntervalSince1970: 1)),
            (attendees: [("Sam.Lee@example.com", nil, false)], start: Date(timeIntervalSince1970: 2)),
        ], own: ["me@x.com"])
        XCTAssertEqual(fromCalendar.map(\.email), ["sam.lee@example.com"], "rooms and you aren't guests")
        XCTAssertEqual(fromCalendar.first?.met, 2)
        let merged = GuestDirectory.merged(calendar: fromCalendar,
                                           contacts: [GuestPerson(email: "sam.lee@example.com", name: "Sam Lee", inContacts: true)])
        XCTAssertEqual(merged.first?.name, "Sam Lee")
        XCTAssertEqual(merged.first?.met, 2)
        XCTAssertTrue(merged.first?.inContacts == true)
    }

    func testThePhraseKeepsGuestsAndTheTitleKeepsThem() {
        let draft = EventPhrase.parse("Lunch with Sam and Jess tomorrow at 1pm at Balthazar")
        XCTAssertEqual(draft.guests, ["Sam", "Jess"])
        XCTAssertEqual(draft.title, "Lunch with Sam and Jess")
        XCTAssertTrue(EventPhrase.preview(draft).contains("With Sam, Jess"))
        XCTAssertTrue(EventPhrase.parse("Lunch with Sam").saysMore)
    }
}
