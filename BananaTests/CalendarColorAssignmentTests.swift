import XCTest

/// Every calendar its own colour (`CalendarColorAssignment`), tested on the colours real
/// Google calendars actually have: two work accounts both Peacock, another person's two calendars both grey.
final class CalendarColorAssignmentTests: XCTestCase {
    private typealias Cal = CalendarColorAssignment.Calendar

    private let mine: [Cal] = [
        Cal(id: "gmail", googleHex: "#42d692", isPrimary: true, account: "bbaker@gmail.example", title: "bbaker@gmail.example"),
        Cal(id: "acme", googleHex: "#985df6", isPrimary: true, account: "bo@acme.example", title: "bo@acme.example"),
        Cal(id: "dewey", googleHex: "#9fe1e7", isPrimary: true, account: "bo@dewey.example", title: "bo@dewey.example"),
        Cal(id: "zeta", googleHex: "#9fe1e7", isPrimary: true, account: "bo@zeta.example", title: "bo@zeta.example"),
        Cal(id: "dana", googleHex: "#c2c2c2", account: "bbaker@gmail.example", title: "cbaker@gmail.example"),
        Cal(id: "sable", googleHex: "#c2c2c2", account: "bbaker@gmail.example", title: "c.baker@sable.example"),
        Cal(id: "launches", googleHex: "#f83a22", account: "bbaker@gmail.example", title: "Launches"),
    ]

    func testNoTwoCalendarsLookAlike() {
        let colours = CalendarColorAssignment.assign(mine)
        XCTAssertEqual(colours.count, mine.count)
        let values = mine.map { colours[$0.id]! }
        for i in values.indices {
            for j in values.indices where j > i {
                XCTAssertFalse(CalendarColorAssignment.clash(values[i], values[j]),
                               "\(mine[i].title) and \(mine[j].title) both \(values[i]) / \(values[j])")
            }
        }
    }

    func testGooglesColourIsKeptWhereNothingElseHasIt() {
        let colours = CalendarColorAssignment.assign(mine)
        XCTAssertEqual(colours["gmail"], "#42d692")
        XCTAssertEqual(colours["acme"], "#985df6")
        XCTAssertEqual(colours["dewey"], "#9fe1e7", "first of the two Peacocks by account keeps it")
        XCTAssertNotEqual(colours["zeta"], "#9fe1e7")
        XCTAssertEqual(colours["launches"], "#f83a22")
        XCTAssertEqual(colours["sable"], "#c2c2c2", "first grey by name keeps grey")
        XCTAssertNotEqual(colours["dana"], "#c2c2c2")
    }

    func testEveryDeviceColoursTheSameWhateverTheOrder() {
        XCTAssertEqual(CalendarColorAssignment.assign(mine), CalendarColorAssignment.assign(mine.reversed()))
        XCTAssertEqual(CalendarColorAssignment.assign(mine), CalendarColorAssignment.assign(mine.shuffled()))
    }

    func testYourChoiceStandsEvenIfItMatchesAnother() {
        let colours = CalendarColorAssignment.assign(mine, chosen: ["zeta": "#42d692"])
        XCTAssertEqual(colours["zeta"], "#42d692")
        XCTAssertEqual(colours["dewey"], "#9fe1e7")
        XCTAssertNotEqual(colours["gmail"], "#42d692", "your choice took it, so gmail moves")
    }

    /// A colour given out never pushes another calendar off a Google colour it could have kept.
    func testANewColourNeverDisplacesAKeptOne() {
        let cals = [Cal(id: "a", googleHex: "#9fe1e7", isPrimary: true, account: "a"),
                    Cal(id: "b", googleHex: "#9fe1e7", isPrimary: true, account: "b"),
                    Cal(id: "red", googleHex: "#f83a22", account: "c"),
                    Cal(id: "orange", googleHex: "#ff7537", account: "d")]
        let colours = CalendarColorAssignment.assign(cals)
        XCTAssertEqual(colours["red"], "#f83a22")
        XCTAssertNotEqual(colours["b"], "#9fe1e7")
        XCTAssertFalse(CalendarColorAssignment.clash(colours["b"]!, "#f83a22"))
    }

    func testThePaletteIsEighteenHuesNoTwoAlike() {
        let palette = CalendarColorAssignment.palette
        XCTAssertEqual(palette.count, 18)
        XCTAssertEqual(Set(palette).count, 18)
        for i in palette.indices { for j in palette.indices where j > i {
            XCTAssertFalse(CalendarColorAssignment.clash(palette[i], palette[j]), "\(palette[i]) \(palette[j])")
        } }
        XCTAssertEqual(CalendarColorAssignment.name(palette[0]), "Red")
        XCTAssertEqual(CalendarColorAssignment.hex(hue: 0, saturation: 1, brightness: 1), "#ff0000")
    }

    func testAlikeMeansTheSameHueAfterEvening() {
        XCTAssertTrue(CalendarColorAssignment.clash("#4986e7", "#9fc6e7"), "blue and light blue look alike in Banana")
        XCTAssertTrue(CalendarColorAssignment.clash("#c2c2c2", "#cabdbf"), "greys are one colour")
        XCTAssertFalse(CalendarColorAssignment.clash("#c2c2c2", "#9fe1e7"))
        XCTAssertFalse(CalendarColorAssignment.clash("#42d692", "#f83a22"))
        XCTAssertTrue(CalendarColorAssignment.hueDistance(0.98, 0.02) < 0.05, "hue wraps around red")
    }
}
