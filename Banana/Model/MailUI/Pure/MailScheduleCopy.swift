#if !BANANA_PUBLIC
import Foundation

/// Every word Mail says about a message that waits for a time he chose, in one place.
///
/// **A scheduled message waits on the device it was scheduled on** (the owner's ruling, MAIL-UX
/// 6.5.5): that device sends it at the time if Banana is running; otherwise, when Banana next runs,
/// it is late and asks, and is never sent unasked. The words say so plainly, and they say it in
/// three places only — the picker's note, the marker on the message, and the late state — each
/// through `Holder`.
///
/// **`Holder` is the seam.** A service that holds scheduled messages is planned as a later product
/// feature. When it exists, "this Mac" becomes "Banana's service" by adding a case to `Holder` and
/// changing the lines below that use it; nothing else in Mail names who sends a scheduled message.
/// `MailScheduleCopyTests` holds that no other line here names one.
enum MailScheduleCopy {

    /// Who sends a scheduled message at its time.
    enum Holder: Equatable, Sendable {
        /// The device it was scheduled on; `name` is how the screens name it: "Mac", "iPhone", "iPad".
        case thisDevice(name: String)

        /// "this Mac".
        var phrase: String {
            switch self {
            case .thisDevice(let name): "this \(name)"
            }
        }
    }

    // MARK: Who sends it: the picker, the marker and the late state

    /// The picker's footer. Once a time is under the highlight it names it: "This Mac sends it
    /// Thu 8:00 AM if Banana is open."
    static func pickerNote(holder: Holder, at date: Date?, now: Date, calendar: Calendar = .current,
                           locale: Locale = .current) -> String {
        let who = holder.phrase.prefix(1).uppercased() + holder.phrase.dropFirst()
        let when = date.map { " " + Self.when($0, now: now, calendar: calendar, locale: locale) }
            ?? " at the time you choose,"
        return "\(who) sends it\(when) if Banana is open. If it isn\u{2019}t, the message is late, and waits for you."
    }

    /// The marker on the message: "Scheduled · Thu 8:00 AM · from this Mac" (MAIL-UX 6.5.5).
    static func marker(when: String, holder: Holder) -> String {
        "Scheduled \u{00B7} \(when) \u{00B7} from \(holder.phrase)"
    }

    /// The late state on the message (MAIL-UX 7.7): it is not sent, and it says why.
    static func lateMarker(when: String, holder: Holder) -> String {
        "Not sent yet. It was due \(when) and \(holder.phrase) wasn\u{2019}t running Banana."
    }

    // MARK: A time, in words

    /// "Thu 8:00 AM" within the coming week, "Mon 12 Oct, 8:00 AM" beyond it.
    static func when(_ date: Date, now: Date, calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate((0..<7).contains(days) ? "EEEjmm" : "EEEdMMMjmm")
        return formatter.string(from: date)
    }

    // MARK: On a row, and under the composer's footer

    /// "Scheduled · Thu 8:00 AM": where a row says what became of the message. A row names no device.
    static func scheduled(_ date: Date, now: Date, calendar: Calendar = .current,
                          locale: Locale = .current) -> String {
        "Scheduled \u{00B7} " + when(date, now: now, calendar: calendar, locale: locale)
    }

    /// "Was due Thu 8:00 AM · not sent yet" (MAIL-UX 6.5.5): a row's line for a late message.
    static func late(_ date: Date, now: Date, calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        "Was due " + when(date, now: now, calendar: calendar, locale: locale) + " \u{00B7} not sent yet"
    }

    /// Under the composer's footer once a time is chosen: the button then says Schedule.
    static func sendsAt(_ date: Date, now: Date, calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
        "Sends " + when(date, now: now, calendar: calendar, locale: locale)
    }

    // MARK: The buttons

    static let schedule = "Schedule"
    static let sendLater = "Send later"
    static let edit = "Edit"
    static let reschedule = "Reschedule"
    static let sendNow = "Send now"
    static let cancel = "Cancel schedule"
    static let keepAsDraft = "Keep as a draft"
    static let clear = "Clear the time"
    static let pickerTitle = "Send later\u{2026}"
    static let pickerPrompt = "Try: fri 9am, in 2 hours, tomorrow 8:30"
    static let inThePast = "That\u{2019}s in the past."

    // MARK: Toasts (MAIL-UX 7.9)

    static func scheduledToast(_ date: Date, now: Date, calendar: Calendar = .current) -> MailToast {
        MailToast(text: "Scheduled for " + when(date, now: now, calendar: calendar), action: .undo)
    }

    static func rescheduledToast(_ date: Date, now: Date, calendar: Calendar = .current) -> MailToast {
        MailToast(text: "Rescheduled for " + when(date, now: now, calendar: calendar), action: .undo)
    }

    /// Cancelling the schedule: the message is a draft again.
    static let backToDraft = MailToast(text: "Back to a draft", action: .undo)
    /// A late message he chose not to send.
    static let keptAsDraft = MailToast(text: "Kept as a draft", action: nil)
    /// The time he chose went by while he wrote.
    static let timePassed = MailToast(text: "That time has passed. Choose another.", action: nil)
    /// Send now on a message that had already gone.
    static let alreadyGone = MailToast(text: "Already sent.", action: nil)

    /// What the stack calls each: "Undo previous: Scheduled".
    static let scheduledDescription = "Scheduled"
    static let rescheduledDescription = "Rescheduled"
    static let cancelledDescription = "Back to a draft"
    static let keptDescription = "Kept as a draft"
}

#endif
