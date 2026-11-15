import XCTest

@MainActor
final class MailInviteLookupTests: XCTestCase {
    private let event = MailInviteEvent(calendarID: "noor@plan.example", eventID: "event", title: "Review", start: .distantPast, end: .distantFuture, isAllDay: false, response: nil)

    func testMissingAndFailedLookupsStayDistinctAndRetryCanRecover() async {
        let lookup = MailInviteLookup()
        await lookup.load(account: "noor@plan.example", uid: "uid") { _, _ in nil }
        XCTAssertEqual(lookup.phase, .missing)
        await lookup.load(account: "noor@plan.example", uid: "uid") { _, _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(lookup.phase, .failed)
        let event = event
        await lookup.load(account: "noor@plan.example", uid: "uid") { _, _ in event }
        XCTAssertEqual(lookup.phase, .ready(event))
    }

    func testLateOldAccountResultCannotReplaceTheNewAccount() async {
        let lookup = MailInviteLookup(), waiting = expectation(description: "old lookup waiting")
        var finish: CheckedContinuation<MailInviteEvent?, Never>?
        let old = Task { await lookup.load(account: "old@plan.example", uid: "same") { _, _ in
            await withCheckedContinuation { finish = $0; waiting.fulfill() }
        } }
        await fulfillment(of: [waiting], timeout: 3)
        await lookup.load(account: "new@plan.example", uid: "same") { _, _ in nil }
        finish?.resume(returning: event)
        await old.value
        XCTAssertEqual(lookup.phase, .missing)
    }

    func testSearchIncludesOnlyThisAccountsOwnedCalendars() throws {
        func calendar(_ id: String, account: String, role: String) throws -> GoogleCalendar {
            var result = try JSONDecoder().decode(GoogleCalendar.self, from: Data("{\"id\":\"\(id)\",\"accessRole\":\"\(role)\"}".utf8))
            result.accountEmail = account
            return result
        }
        let ids = try MailInviteLookup.calendarIDs(account: "NOOR@plan.example", calendars: [
            calendar("owned", account: "noor@plan.example", role: "owner"),
            calendar("shared", account: "noor@plan.example", role: "writer"),
            calendar("other", account: "other@plan.example", role: "owner")])
        XCTAssertEqual(ids, ["noor@plan.example", "owned"])
    }
}
