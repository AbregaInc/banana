#if !BANANA_PUBLIC
import Foundation

/// What one row of the list says, as strings and flags, made once per row off any view body
/// (MAIL-UX 6.1.1). Two equal rows make two equal displays, which is what lets a row view be
/// `Equatable` and be left alone when nothing it draws has changed.
///
/// This is the slice's cut of the design's row: who, how many, what about, what it says, when,
/// and the three marks the contract's row carries (unread, attachment, star, plus the invitation
/// glyph), and the two reason lines writing makes: a draft, and a message being sent. Labels and
/// the account chip are not here: the sample mail has none.
struct MailRowDisplay: Equatable, Sendable {
    var who: String
    /// Whose face the row shows (`MailFace.of`); nil for a row with nobody on it yet.
    var face: MailFace?
    /// The message count, when there are two or more.
    var count: Int?
    /// "Re:" and "Fwd:" removed; "(no subject)" when there is nothing left.
    var subject: String
    var subjectIsPlaceholder: Bool
    /// White space collapsed.
    var snippet: String
    var date: String
    var isUnread: Bool
    var isStarred: Bool
    var hasAttachment: Bool
    var isInvitation: Bool
    /// What a draft begins with, when he has one in this conversation: the row says "Draft · …"
    /// where the snippet would be. Empty for a draft with no text yet.
    var draft: String?
    /// A message of his is inside its undo hold: the row says "Sending…".
    var isSending: Bool
    /// A message of his waits for a time he chose, or its time passed and it is not sent: the row
    /// says "Scheduled · Thu 8:00 AM", or "Was due Thu 8:00 AM · not sent yet" (`isLate`).
    var scheduled: String?
    var isLate: Bool
    var isKeptAfterRemoval: Bool

    init(_ row: MailRow, now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        self.init(row, dates: MailDateText.Rows(now: now, calendar: calendar, locale: locale))
    }

    init(_ row: MailRow, dates: MailDateText.Rows) {
        var who = Self.who(for: row)
        // A draft with nobody on it yet has no one to name.
        if who.isEmpty {
            if case .draft? = row.reason { who = "No recipient" } else { who = "Unknown sender" }
        }
        self.who = who
        face = MailFace.of(row.people)
        count = row.messageCount >= 2 ? row.messageCount : nil
        let cleaned = MailToastText.cleanSubject(row.subject)
        subject = cleaned
        subjectIsPlaceholder = cleaned == "(no subject)"
        snippet = row.snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        date = dates.string(for: row.date)
        isUnread = row.isUnread
        isStarred = row.isStarred
        hasAttachment = row.hasAttachment
        isInvitation = row.isInvitation
        if case .keptAfterRemoval? = row.reason { isKeptAfterRemoval = true } else { isKeptAfterRemoval = false }
        switch row.reason {
        case .draft(let firstLine)?: draft = firstLine
        default: draft = nil
        }
        if case .held? = row.reason { isSending = true } else { isSending = false }
        if case .scheduled(let at, _, let late)? = row.reason {
            scheduled = late ? MailScheduleCopy.late(at, now: dates.now, calendar: dates.calendar, locale: dates.locale)
                : MailScheduleCopy.scheduled(at, now: dates.now, calendar: dates.calendar, locale: dates.locale)
            isLate = late
        } else {
            scheduled = nil
            isLate = false
        }
    }

    /// "Sam" for one person; "Sam, me, Jane" for several; more than three: the first, "…" and
    /// the last two. A person with no name (the engine withholds one that looks like an address)
    /// is their address.
    static func who(for row: MailRow) -> String {
        let people = row.people
        guard !people.isEmpty else { return "" }
        if people.count == 1 {
            let only = people[0]
            let name = only.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return only.isMe ? "me" : (name.flatMap { $0.isEmpty ? nil : $0 } ?? (only.address.isEmpty ? "Unknown sender" : only.address))
        }
        let names = people.map(shortName)
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names[0]) \u{2026} " + names.suffix(2).joined(separator: ", ")
    }

    private static func shortName(_ person: MailPerson) -> String {
        if person.isMe { return "me" }
        guard let name = person.name, let first = name.split(separator: " ").first else {
            return person.address.isEmpty ? "Unknown sender" : person.address
        }
        return String(first)
    }
}

/// A row's date, by how long ago it is (MAIL-UX 5.2's `DateText.row`, which the design system
/// does not have yet): today, the time; yesterday, the locale's own word; within the week, the
/// weekday; this year, the day and month; earlier, with the year.
enum MailDateText {

    static func row(_ date: Date, now: Date, calendar: Calendar = .current,
                    locale: Locale = .current) -> String {
        Rows(now: now, calendar: calendar, locale: locale).string(for: date)
    }

    /// A list update shares its reference day and creates only the formatters its rows need.
    final class Rows {
        let now: Date
        let calendar: Calendar
        let locale: Locale

        init(now: Date, calendar: Calendar = .current, locale: Locale = .current) {
            self.now = now
            self.calendar = calendar
            self.locale = locale
        }

        private lazy var today = calendar.startOfDay(for: now)
        private lazy var currentYear = calendar.component(.year, from: now)
        private lazy var time = MailDateText.formatter("jmm", calendar: calendar, locale: locale)
        private lazy var weekday = MailDateText.formatter("EEE", calendar: calendar, locale: locale)
        private lazy var dayMonth = MailDateText.formatter("dMMM", calendar: calendar, locale: locale)
        private lazy var dayMonthYear = MailDateText.formatter("dMMMyyyy", calendar: calendar, locale: locale)
        private lazy var yesterday: String = {
            let relative = RelativeDateTimeFormatter()
            relative.locale = locale
            relative.calendar = calendar
            relative.dateTimeStyle = .named
            relative.formattingContext = .beginningOfSentence
            return relative.localizedString(from: DateComponents(day: -1))
        }()

        func string(for date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            switch days {
            case ..<1: return time.string(from: date)
            case 1: return yesterday
            case 2...6: return weekday.string(from: date)
            default:
                let sameYear = calendar.component(.year, from: date) == currentYear
                return (sameYear ? dayMonth : dayMonthYear).string(from: date)
            }
        }
    }

    /// A message's own header: "Mon 5 Oct, 9:12 AM".
    static func full(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        fullFormatter(calendar: calendar, locale: locale).string(from: date)
    }

    /// One reader update formats every header using the same locale, calendar and time zone.
    static func fullFormatter(calendar: Calendar = .current, locale: Locale = .current) -> DateFormatter {
        formatter("EEEdMMMjmm", calendar: calendar, locale: locale)
    }

    private static func formatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

#endif
