import XCTest

/// What Mail says of a message that waits for a time, and of who sends it (`MailScheduleCopy`). The
/// device that sends it is named in three places, each through `MailScheduleCopy.Holder`, and in no
/// other line: that is what lets a service that holds scheduled messages change one type.
final class MailScheduleCopyTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")

    /// The system puts a narrow no-break space before AM and PM; a test reads a plain one.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Wednesday 7 October 2026, 10:10 AM, and Thursday 8:00 AM.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10, minute: 10))! }
    private var thursday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 8))! }

    func testATimeIsSaidAsWeekdayAndTimeWithinAWeekAndWithTheDateBeyond() {
        XCTAssertEqual(plain(MailScheduleCopy.when(thursday, now: now, calendar: calendar, locale: locale)), "Thu 8:00 AM")
        let later = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))!
        let said = plain(MailScheduleCopy.when(later, now: now, calendar: calendar, locale: locale))
        XCTAssertTrue(said.contains("Mon") && said.contains("19") && said.contains("8:00 AM"), said)
    }

    func testTheMarkerAndTheLateStateNameTheDeviceThatSendsIt() {
        let mac = MailScheduleCopy.Holder.thisDevice(name: "Mac")
        XCTAssertEqual(MailScheduleCopy.marker(when: "Thu 8:00 AM", holder: mac),
                       "Scheduled \u{00B7} Thu 8:00 AM \u{00B7} from this Mac")
        XCTAssertEqual(MailScheduleCopy.lateMarker(when: "Thu 8:00 AM", holder: mac),
                       "Not sent yet. It was due Thu 8:00 AM and this Mac wasn\u{2019}t running Banana.")
        let phone = MailScheduleCopy.Holder.thisDevice(name: "iPhone")
        XCTAssertEqual(MailScheduleCopy.marker(when: "Thu 8:00 AM", holder: phone),
                       "Scheduled \u{00B7} Thu 8:00 AM \u{00B7} from this iPhone")
        XCTAssertTrue(MailScheduleCopy.lateMarker(when: "Thu 8:00 AM", holder: phone).contains("this iPhone"))
    }

    func testThePickerNoteSaysWhoSendsItAndWhatHappensIfBananaIsNotOpen() {
        let mac = MailScheduleCopy.Holder.thisDevice(name: "Mac")
        XCTAssertEqual(plain(MailScheduleCopy.pickerNote(holder: mac, at: thursday, now: now, calendar: calendar, locale: locale)),
                       "This Mac sends it Thu 8:00 AM if Banana is open. If it isn\u{2019}t, the message is late, and waits for you.")
        XCTAssertEqual(MailScheduleCopy.pickerNote(holder: .thisDevice(name: "iPad"), at: nil, now: now,
                                                   calendar: calendar, locale: locale),
                       "This iPad sends it at the time you choose, if Banana is open. If it isn\u{2019}t, the message is late, and waits for you.")
    }

    func testNoOtherLineNamesWhoSendsIt() {
        let others = [
            MailScheduleCopy.scheduled(thursday, now: now, calendar: calendar, locale: locale),
            MailScheduleCopy.late(thursday, now: now, calendar: calendar, locale: locale),
            MailScheduleCopy.sendsAt(thursday, now: now, calendar: calendar, locale: locale),
            MailScheduleCopy.scheduledToast(thursday, now: now, calendar: calendar).text,
            MailScheduleCopy.rescheduledToast(thursday, now: now, calendar: calendar).text,
            MailScheduleCopy.backToDraft.text, MailScheduleCopy.keptAsDraft.text,
            MailScheduleCopy.timePassed.text, MailScheduleCopy.alreadyGone.text,
            MailScheduleCopy.schedule, MailScheduleCopy.sendLater, MailScheduleCopy.edit,
            MailScheduleCopy.reschedule, MailScheduleCopy.sendNow, MailScheduleCopy.cancel,
            MailScheduleCopy.keepAsDraft, MailScheduleCopy.clear, MailScheduleCopy.pickerTitle,
            MailScheduleCopy.pickerPrompt, MailScheduleCopy.inThePast,
            MailScheduleCopy.scheduledDescription, MailScheduleCopy.rescheduledDescription,
            MailScheduleCopy.cancelledDescription, MailScheduleCopy.keptDescription,
        ]
        for line in others {
            for word in ["this ", "Mac", "iPhone", "iPad", "Google", "Gmail", "service", "server"] {
                XCTAssertFalse(line.contains(word), "\u{201C}\(line)\u{201D} names a place with \u{201C}\(word)\u{201D}")
            }
        }
    }

    func testTheRowSaysScheduledAndWhenAndLateSaysItWasDue() {
        XCTAssertEqual(plain(MailScheduleCopy.scheduled(thursday, now: now, calendar: calendar, locale: locale)),
                       "Scheduled \u{00B7} Thu 8:00 AM")
        XCTAssertEqual(plain(MailScheduleCopy.late(thursday, now: now, calendar: calendar, locale: locale)),
                       "Was due Thu 8:00 AM \u{00B7} not sent yet")
        XCTAssertEqual(plain(MailScheduleCopy.sendsAt(thursday, now: now, calendar: calendar, locale: locale)), "Sends Thu 8:00 AM")
    }

    func testTheToastsSayWhatHappenedAndOfferUndoWhereUndoCanWork() {
        XCTAssertEqual(MailScheduleCopy.scheduledToast(thursday, now: now, calendar: calendar).action, .undo)
        XCTAssertEqual(MailScheduleCopy.backToDraft, MailToast(text: "Back to a draft", action: .undo))
        XCTAssertNil(MailScheduleCopy.keptAsDraft.action,
                     "reversing a late message's keep would be a schedule in the past")
    }
}
