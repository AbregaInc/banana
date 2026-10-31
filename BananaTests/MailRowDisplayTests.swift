import XCTest

/// What a row says (MAIL-UX 6.1.1), a row's date, and a message's text with its styles: the pure
/// half of the inbox screen, which is all a test can reach of it.
@MainActor
final class MailRowDisplayTests: XCTestCase {

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")

    private func moment(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Monday 5 October 2026, 9:41 AM: the sample mail's clock.
    private var now: Date { moment(2026, 10, 5, 9, 41) }

    private func person(_ name: String?, _ address: String = "x@example.com", me: Bool = false) -> MailPerson {
        MailPerson(name: name, address: address, isMe: me, isKnown: true, fromTheirMail: false)
    }

    private func row(people: [MailPerson] = [], subject: String = "Subject", snippet: String = "Snippet",
                     messages: Int = 1) -> MailRow {
        var row = TriageHarness.row("A", rank: 0, subject: subject, snippet: snippet)
        row.people = people
        row.peopleTotal = people.count
        row.messageCount = messages
        row.date = moment(2026, 10, 5)
        return row
    }

    private func display(_ row: MailRow) -> MailRowDisplay {
        MailRowDisplay(row, now: now, calendar: utc, locale: us)
    }

    /// 9:12 AM, where newer macOS puts a narrow no-break space before the AM.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: Who

    func testOneOtherPersonIsTheirNameOrTheirAddress() {
        XCTAssertEqual(display(row(people: [person("Sam Lee")])).who, "Sam Lee")
        XCTAssertEqual(display(row(people: [person(nil, "no-reply@accounts.example.com")])).who,
                       "no-reply@accounts.example.com",
                       "a name the engine withheld is shown as the address it really came from")
    }

    func testSeveralPeopleAreFirstNamesInOrderWithMeForNoor() {
        let people = [person("Sam Lee"), person("Noor", me: true), person("Jane Park")]
        XCTAssertEqual(display(row(people: people)).who, "Sam, me, Jane")
    }

    func testMoreThanThreeIsTheFirstAnEllipsisAndTheLastTwo() {
        let people = ["Sam Lee", "Jane Park", "Ana Ruiz", "Tom Okafor", "Mei Chen"].map { person($0) }
        XCTAssertEqual(display(row(people: people)).who, "Sam \u{2026} Tom, Mei")
    }

    func testHisOwnConversationAloneIsMe() {
        XCTAssertEqual(display(row(people: [person("Noor", me: true)])).who, "me")
    }

    func testARowWithADraftSaysWhatTheDraftBeginsWithAndOneBeingSentSaysSo() {
        var drafted = row(snippet: "What he was told")
        XCTAssertNil(display(drafted).draft)
        XCTAssertFalse(display(drafted).isSending)
        drafted.reason = .draft(firstLine: "Thanks, I'll look tonight")
        XCTAssertEqual(display(drafted).draft, "Thanks, I'll look tonight")
        XCTAssertEqual(display(drafted).snippet, "What he was told", "the snippet is still there to be replaced")
        drafted.reason = .draft(firstLine: "")
        XCTAssertEqual(display(drafted).draft, "", "a draft with no text yet is still a draft")
        drafted.reason = .held(until: now)
        XCTAssertNil(display(drafted).draft)
        XCTAssertTrue(display(drafted).isSending)
    }

    func testNobodyIsNothing() {
        XCTAssertEqual(display(row()).who, "")
    }

    // MARK: The rest of the row

    func testTheCountShowsFromTwoMessages() {
        XCTAssertNil(display(row(messages: 1)).count)
        XCTAssertEqual(display(row(messages: 3)).count, 3)
    }

    func testReplyAndForwardPrefixesAreRemovedAndNothingIsNoSubject() {
        XCTAssertEqual(display(row(subject: "Re: Fwd: Q3 numbers")).subject, "Q3 numbers")
        let blank = display(row(subject: ""))
        XCTAssertEqual(blank.subject, "(no subject)")
        XCTAssertTrue(blank.subjectIsPlaceholder)
        XCTAssertFalse(display(row(subject: "Q3")).subjectIsPlaceholder)
    }

    func testTheSnippetHasItsWhiteSpaceCollapsed() {
        XCTAssertEqual(display(row(snippet: "Can you  look\n\n at   this?")).snippet, "Can you look at this?")
    }

    func testTheMarksComeFromTheRow() {
        var marked = row()
        marked.isUnread = true
        marked.isStarred = true
        marked.hasAttachment = true
        marked.isInvitation = true
        let shown = display(marked)
        XCTAssertTrue(shown.isUnread && shown.isStarred && shown.hasAttachment && shown.isInvitation)
        marked.isUnread = false
        marked.isStarred = false
        marked.hasAttachment = false
        marked.isInvitation = false
        let quiet = display(marked)
        XCTAssertFalse(quiet.isUnread || quiet.isStarred || quiet.hasAttachment || quiet.isInvitation)
    }

    func testEqualRowsMakeEqualDisplays() {
        // What lets a row view be left alone when nothing it draws has changed.
        XCTAssertEqual(display(row(people: [person("Sam Lee")])), display(row(people: [person("Sam Lee")])))
        XCTAssertNotEqual(display(row(subject: "A")), display(row(subject: "B")))
    }

    // MARK: Date

    func testTodayIsTheTime() {
        XCTAssertEqual(plain(MailDateText.row(moment(2026, 10, 5), now: now, calendar: utc, locale: us)), "9:12 AM")
        XCTAssertEqual(MailDateText.row(moment(2026, 10, 5), now: now, calendar: utc, locale: gb), "09:12",
                       "a 24-hour locale gets the 24-hour clock")
    }

    func testYesterdayIsTheLocalesWord() {
        XCTAssertEqual(MailDateText.row(moment(2026, 10, 4, 19, 44), now: now, calendar: utc, locale: us), "Yesterday")
    }

    func testTwoToSixDaysAgoIsTheWeekday() {
        XCTAssertEqual(MailDateText.row(moment(2026, 10, 3), now: now, calendar: utc, locale: us), "Sat")
        XCTAssertEqual(MailDateText.row(moment(2026, 9, 29), now: now, calendar: utc, locale: us), "Tue")
    }

    func testThisYearIsTheDayAndMonthAndEarlierHasTheYear() {
        XCTAssertEqual(MailDateText.row(moment(2026, 9, 28), now: now, calendar: utc, locale: us), "Sep 28")
        XCTAssertEqual(MailDateText.row(moment(2025, 12, 2), now: now, calendar: utc, locale: us), "Dec 2, 2025")
    }

    func testAMessageHeaderHasTheWeekdayTheDateAndTheTime() {
        let full = plain(MailDateText.full(moment(2026, 10, 5), calendar: utc, locale: us))
        XCTAssertTrue(full.contains("Mon") && full.contains("Oct") && full.contains("9:12 AM"), full)
    }

    // MARK: Styled text

    func testStylesBecomeAttributesAndALinkIsUnderlinedButOpensNothing() {
        let runs = [
            MailTextRun(text: "plain "),
            MailTextRun(text: "bold", style: [.bold]),
            MailTextRun(text: " ital", style: [.italic]),
            MailTextRun(text: " link", link: URL(string: "https://example.com")),
        ]
        let made = MailAttributedText.make(runs)
        XCTAssertEqual(String(made.characters), "plain bold ital link")
        XCTAssertEqual(MailAttributedText.plain(runs), "plain bold ital link")

        var intents: [InlinePresentationIntent] = []
        var underlined = false
        for run in made.runs {
            if let intent = run.inlinePresentationIntent { intents.append(intent) }
            if run.underlineStyle != nil { underlined = true }
            XCTAssertNil(run.link, "a link's address is kept off: the slice opens nothing")
        }
        XCTAssertEqual(intents, [.stronglyEmphasized, .emphasized])
        XCTAssertTrue(underlined)
    }
}
