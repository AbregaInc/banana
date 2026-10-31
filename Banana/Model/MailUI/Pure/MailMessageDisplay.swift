#if !BANANA_PUBLIC
import Foundation

/// What one message's card says above its text, made once when the conversation arrives and not
/// in a view body: who wrote it, to whom, when, and its attachments by name.
struct MailMessageDisplay: Equatable, Identifiable, Sendable {
    var id: MailMessageID
    var sender: String
    /// "to me, Jane".
    var recipients: String
    var date: String
    /// What the folded row would say; shown until the body has arrived.
    var firstLine: String
    /// "Q3-revenue.xlsx · 412 KB".
    var attachments: [String]
    /// The same attachments as the reader draws them: a symbol and a size, whether the bytes are
    /// here to look at, and a note under a program or a file that is not what its name says.
    var files: [MailAttachmentDisplay]
    /// What a sample message says in place of a time it was not sent at, and nothing for a message
    /// that is not one. The sample mail "sends" and nothing leaves the machine, so every message it
    /// makes says so.
    var sampleNote: String?
    /// A message of his that waits for a time he chose, or is late (`MailScheduleCopy`).
    var scheduled: Scheduled?

    /// What a scheduled message's card says and can do: its draft, and the line.
    struct Scheduled: Equatable, Sendable {
        var draft: MailDraftID
        var at: Date
        /// "Thu 8:00 AM": what the marker and the late state say, with who sends it, which only
        /// the screen knows (`MailScheduleCopy.marker`).
        var when: String
        var isLate: Bool
    }

    /// In the id of every message the sample source makes by "sending", after the thread.
    nonisolated static let sampleMark = "~sample-"

    init(_ message: MailMessage, now: Date = Date(), calendar: Calendar = .current,
         locale: Locale = .current) {
        id = message.id
        sender = message.from.isMe ? "me" : (message.from.name ?? message.from.address)
        let names = message.to.map { person -> String in
            if person.isMe { return "me" }
            return person.name?.split(separator: " ").first.map(String.init) ?? person.address
        }
        recipients = "to " + names.joined(separator: ", ")
        date = MailDateText.full(message.date, calendar: calendar, locale: locale)
        firstLine = message.firstLine
        attachments = message.attachments.map {
            "\($0.name) \u{00B7} " + ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file)
        }
        files = message.attachments.map(MailAttachmentDisplay.init)
        scheduled = Self.scheduled(message, now: now, calendar: calendar, locale: locale)
        if message.id.message.contains(Self.sampleMark) {
            if case .held? = message.delivery {
                sampleNote = "Sending\u{2026} \u{00B7} sample, so nothing is really sent"
            } else if scheduled != nil {
                sampleNote = "Sample \u{00B7} nothing will really be sent"
            } else {
                sampleNote = "Sample \u{00B7} nothing was really sent"
            }
        }
    }

    /// A message that waits: scheduled, or asking because its time passed (`sendLate`).
    private static func scheduled(_ message: MailMessage, now: Date, calendar: Calendar,
                                  locale: Locale) -> Scheduled? {
        guard let draft = message.draft else { return nil }
        switch message.delivery {
        case .scheduled(let at)?:
            return Scheduled(draft: draft, at: at,
                             when: MailScheduleCopy.when(at, now: now, calendar: calendar, locale: locale),
                             isLate: false)
        case .asking(_, .sendLate(_, let since))?:
            return Scheduled(draft: draft, at: since,
                             when: MailScheduleCopy.when(since, now: now, calendar: calendar, locale: locale),
                             isLate: true)
        default:
            return nil
        }
    }
}

#endif
