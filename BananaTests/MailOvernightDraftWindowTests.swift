import XCTest

final class MailOvernightDraftWindowTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testNightSpansMidnightAndStopsAtSix() throws {
        XCTAssertNil(MailDraftNight.current(at: at(2, 21, 59), calendar: calendar))
        let night = try XCTUnwrap(MailDraftNight.current(at: at(2, 22), calendar: calendar))
        XCTAssertEqual(night.start, at(2, 22))
        XCTAssertEqual(night.end, at(3, 6))
        XCTAssertEqual(MailDraftNight.current(at: at(3, 5, 59), calendar: calendar)?.start, night.start)
        XCTAssertNil(MailDraftNight.current(at: at(3, 6), calendar: calendar))
        let transition = try XCTUnwrap(MailDraftNight.current(at: at(1, 3), calendar: calendar))
        XCTAssertEqual(transition.end.timeIntervalSince(transition.start), 9 * 3600)
    }

    func testLaterArrivalAfterAnEmptyScanAndRestart() throws {
        let bedtime = try XCTUnwrap(MailDraftNight.current(at: at(4, 22), calendar: calendar))
        var scan = MailOvernightScan.resume(nil, night: bedtime)
        scan.before = nil // The empty inbox page at bedtime is exhausted.
        let later = try XCTUnwrap(MailDraftNight.current(at: at(5, 1), calendar: calendar))
        scan = .resume(try JSONEncoder().encode(scan), night: later)
        XCTAssertNil(scan.before)
        let first = MailMessageID(account: "noor@plan.example", message: "m1")
        let reply = MailMessageID(account: first.account, message: "m2")
        XCTAssertTrue(scan.processed.insert(first).inserted)
        scan.before = MailOrderKey(group: 0, sortKey: 20, tie: 5)
        let resumed = MailOvernightScan.resume(try JSONEncoder().encode(scan), night: later)
        XCTAssertEqual(resumed.before, scan.before)
        XCTAssertTrue(resumed.processed.contains(first))
        XCTAssertFalse(resumed.processed.contains(reply))
        let tomorrow = try XCTUnwrap(MailDraftNight.current(at: at(5, 23), calendar: calendar))
        let newNight = MailOvernightScan.resume(try JSONEncoder().encode(scan), night: tomorrow)
        XCTAssertTrue(newNight.processed.isEmpty)
        XCTAssertNil(newNight.before)
    }
}
