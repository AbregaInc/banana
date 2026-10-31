#if !BANANA_PUBLIC
import Foundation

/// One toast: a line and at most one button (MAIL-UX 7.9). Handed to `ToastCenter.present` by
/// the screen; nothing here knows how it is drawn.
struct MailToast: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case undo
        /// What `Z` does after an undo, when the stack has another entry: "Undo previous: Marked
        /// Done". The associated text is that entry's description.
        case undoPrevious(String)
        case retry

        var title: String {
            switch self {
            case .undo: return "Undo"
            case .undoPrevious(let what): return "Undo previous: \(what)"
            case .retry: return "Retry"
            }
        }
    }

    var text: String
    var action: Action?
    /// How long it stays, when that is not the usual six seconds: a send's toast stays for the
    /// whole of its undo hold, so that Undo is there for as long as it can work (6.3.7).
    var lasts: TimeInterval? = nil

    /// How long the top entry's toast stays (T27). The undo entry outlives it.
    static let duration: TimeInterval = 6
}

/// The words Mail says when something has happened to a conversation, in one place, so that a
/// test can hold every line against the table in MAIL-UX 7.9 and a slip in the wording is a
/// failing test rather than something he reads.
///
/// A toast about one conversation names it, so a slip is seen at once; about several it counts
/// them. A conversation is named by its subject with "Re:" and "Fwd:" taken off (the row does
/// the same, 6.1.1), in curly quotes, cut to 30 characters and "…" so that the outcome — the
/// last word — is always on the line. A number is grouped. The device's name and a time's words
/// arrive from the screen, which knows them: this code has no default for either.
enum MailToastText {

    // MARK: Names and numbers

    /// A subject as a row says it: "Re: Fwd: Q3 numbers" is "Q3 numbers", and nothing at all is
    /// "(no subject)".
    static func cleanSubject(_ subject: String) -> String {
        var text = Substring(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["re:", "fwd:", "fw:"] where text.lowercased().hasPrefix(prefix) {
                text = text.dropFirst(prefix.count)
                text = Substring(text.trimmingCharacters(in: .whitespaces))
                stripped = true
                break
            }
        }
        return text.isEmpty ? "(no subject)" : String(text)
    }

    /// How many characters of a subject a toast keeps (7.9).
    static let subjectLength = 30

    /// “Q3 numbers”, and a longer subject cut to 30 characters and "…".
    static func quoted(_ subject: String) -> String {
        let clean = cleanSubject(subject)
        let name = clean.count > subjectLength ? String(clean.prefix(subjectLength)) + "\u{2026}" : clean
        return "\u{201C}\(name)\u{201D}"
    }

    /// A number as the screens write one: "1,204", never "1204" (7.4).
    static func number(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: After an action on conversations

    /// The toast an action leaves, or nil when it leaves none: stars, reading and unreading show
    /// on the row (and are still an undo step), Send and Done is the composer's toast, and an
    /// action that is another feature's, or not built, has no line. `time` is the snooze's time
    /// as the screens word it ("Thu 8 AM"). `keepsInInbox` is a Done that acted on the messages
    /// seen only, because a reply has not been on screen (T45): the conversation is still there.
    static func toast(for action: MailAction, change: MailChange, subjects: [String],
                      count: Int, time: String? = nil, keepsInInbox: Bool = false) -> MailToast? {
        guard var text = line(for: action, change: change, subjects: subjects, count: count,
                              time: time)
        else { return nil }
        if keepsInInbox, action == .done, count == 1, let subject = subjects.first {
            text = "Marked Done \u{00B7} a new reply keeps \(quoted(subject)) in the inbox"
        }
        return MailToast(text: text, action: .undo)
    }

    private static func line(for action: MailAction, change: MailChange, subjects: [String],
                             count: Int, time: String?) -> String? {
        let one = count == 1 ? subjects.first.map(quoted) : nil
        let many = number(count)
        switch action {
        case .done:
            return one.map { "Marked \($0) Done" } ?? "\(many) marked Done"
        case .trash:
            return one.map { "Moved \($0) to Trash" } ?? "\(many) moved to Trash"
        case .spam:
            return one.map { "Marked \($0) as spam" } ?? "\(many) marked as spam"
        case .move(_, let label):
            return one.map { "Moved \($0) to \(label.name)" } ?? "\(many) moved to \(label.name)"
        case .removeLabel(_, let label):
            return one.map { "Removed \($0) from \(label.name)" } ?? "\(many) removed from \(label.name)"
        case .label(_, let add, let remove):
            if !add.isEmpty {
                let names = add.map(\.name).joined(separator: ", ")
                return one.map { "Labelled \($0) \(names)" } ?? "\(many) labelled \(names)"
            }
            let names = remove.map(\.name).joined(separator: ", ")
            return one.map { "Removed \($0) from \(names)" } ?? "\(many) removed from \(names)"
        case .backToInbox, .notSpam, .notDone:
            return one.map { "\($0) is back in the inbox" } ?? "\(many) are back in the inbox"
        case .restore:
            // Where a restored conversation returns to is Gmail's to say: it may not be the inbox.
            return one.map { "Restored \($0)" } ?? "\(many) restored"
        case .snooze(_, let ifNoReply):
            let until = (time.map { " until \($0)" } ?? "") + (ifNoReply ? ", unless they reply" : "")
            return one.map { "Snoozed \($0)\(until)" } ?? "\(many) snoozed\(until)"
        case .mute:
            return one.map { "Muted \($0)" } ?? "\(many) muted"
        case .toggleRead, .toggleStar, .sendAndDone, .addToPlan, .unsubscribe, .answerInvitation:
            return nil
        }
    }

    /// What the undo stack calls an entry, and what "Undo previous" and More › Undo say: the
    /// toast without the name — "Marked Done", "3 marked Done". Stars and reading have a
    /// description though they have no toast, because they are an undo step. An action that is
    /// another feature's, or not built, has none, and none is invented: it puts nothing on the
    /// stack.
    static func description(for action: MailAction, change: MailChange, count: Int) -> String {
        let base: String
        switch action {
        case .done: base = "Marked Done"
        case .trash: base = "Moved to Trash"
        case .spam: base = "Marked as spam"
        case .move(_, let label): base = "Moved to \(label.name)"
        case .removeLabel(_, let label): base = "Removed from \(label.name)"
        case .label(_, let add, let remove):
            base = add.isEmpty
                ? "Removed from \(remove.map(\.name).joined(separator: ", "))"
                : "Labelled \(add.map(\.name).joined(separator: ", "))"
        case .backToInbox, .notSpam, .notDone: base = "Back in the inbox"
        case .restore: base = "Restored"
        case .snooze: base = "Snoozed"
        case .mute: base = "Muted"
        case .sendAndDone: base = "Sent and marked Done"
        case .toggleRead:
            if case .read(let read) = change { base = read ? "Marked read" : "Marked unread" }
            else { base = "Marked read" }
        case .toggleStar:
            if case .star(let starred) = change { base = starred ? "Starred" : "Unstarred" }
            else { base = "Starred" }
        case .addToPlan, .unsubscribe, .answerInvitation: return ""
        }
        guard count > 1 else { return base }
        return "\(number(count)) \(base.prefix(1).lowercased())\(base.dropFirst())"
    }

    // MARK: After an undo

    /// "Undone", with the way to undo the entry before it when there is one (T26).
    static func undone(previous: String?) -> MailToast {
        MailToast(text: "Undone", action: previous.map { .undoPrevious($0) })
    }

    /// The source answered with a count of zero: every target is gone, or it can no longer
    /// reverse the change. The two cannot be told apart, so there is one line (T30).
    static let cannotBeUndone = MailToast(text: "That can no longer be undone.", action: nil)

    /// A send whose hold ended (T28). For a Send and Done the Done is undone and the line says
    /// where the conversation is.
    static func alreadySent(backInInbox subject: String? = nil) -> MailToast {
        guard let subject else { return MailToast(text: "Already sent.", action: nil) }
        return MailToast(text: "Already sent. \(quoted(subject)) is back in the inbox.", action: nil)
    }

    // MARK: When a change cannot stand (T36)

    /// "Couldn't move “Q3 numbers”: that label no longer exists." with Retry; for several,
    /// "Couldn't move 12 conversations: …". When Gmail's limit for the day was reached it has
    /// one sentence and no Retry: trying again today cannot help, and the change waits in
    /// Outbox, where Retry is still offered (7.6).
    static func refused(_ action: MailAction, change: MailChange, subjects: [String], count: Int,
                        failure: MailFailure) -> MailToast {
        let what: String
        if count == 1, let subject = subjects.first {
            what = quoted(subject)
        } else {
            what = "\(number(count)) conversations"
        }
        let verb: String
        switch action {
        case .done, .sendAndDone: verb = "mark \(what) Done"
        case .trash: verb = "move \(what) to Trash"
        case .spam: verb = "mark \(what) as spam"
        case .move: verb = "move \(what)"
        case .removeLabel(_, let label): verb = "take \(label.name) off \(what)"
        case .label(_, let add, let remove):
            // Never "label" for taking one off: it is the opposite of what he did.
            verb = add.isEmpty && !remove.isEmpty
                ? "take \(remove.map(\.name).joined(separator: ", ")) off \(what)"
                : "label \(what)"
        case .backToInbox, .notSpam, .notDone: verb = "move \(what) back to the inbox"
        case .restore: verb = "restore \(what)"
        case .snooze: verb = "snooze \(what)"
        case .mute: verb = "mute \(what)"
        case .toggleRead:
            if case .read(let read) = change { verb = "mark \(what) \(read ? "read" : "unread")" }
            else { verb = "mark \(what) read" }
        case .toggleStar:
            if case .star(let starred) = change { verb = "\(starred ? "star" : "unstar") \(what)" }
            else { verb = "star \(what)" }
        case .addToPlan, .unsubscribe, .answerInvitation: verb = "change \(what)"
        }
        let reason = failure == .limitReached
            ? "Gmail's limit for today was reached."
            : Self.reason(for: failure)
        return MailToast(text: "Couldn't \(verb): \(reason)",
                         action: failure == .limitReached ? nil : .retry)
    }

    /// Reasons, from the contract's closed list to words. Google's own are never shown. This is
    /// MAIL-UX 7.6's "after the colon" column, for a message that did not send.
    static func reason(for failure: MailFailure) -> String {
        switch failure {
        case .tooLarge: return "it's over Gmail's size limit."
        case .addressRejected: return "Gmail rejected one of the addresses."
        case .signedOut, .accessMissing: return "this account has to be allowed again."
        case .notAllowedByAdmin: return "the organisation doesn't allow it."
        case .labelMissing: return "that label no longer exists."
        case .limitReached: return "Gmail's limit for today was reached. Try again tomorrow."
        case .internalError, .other: return "Gmail refused it."
        }
    }

    /// "Couldn't save that: " and one of four plain reasons, none with a button (7.9). The device
    /// is named as the screens name it ("iPhone", "iPad", "Mac").
    static func notSaved(on device: String, problem: MailStoreProblem) -> MailToast {
        let reason: String
        switch problem {
        case .diskFull: reason = "this \(device) is full."
        case .damaged: reason = "Mail's data on this \(device) is being repaired."
        case .newerVersion: reason = "this \(device)'s mail was made by a newer Banana. Update Banana."
        case .unavailable: reason = "Mail's data can't be opened right now."
        }
        return MailToast(text: "Couldn't save that: \(reason)", action: nil)
    }

    // MARK: Sending and discarding (6.3.6, 7.9)

    static func sending(thenDone: Bool) -> MailToast {
        MailToast(text: thenDone ? "Sending · marked Done" : "Sending", action: .undo)
    }

    static let sent = MailToast(text: "Sent.", action: nil)

    /// What the stack calls a send that is not a Send and Done: "Undo previous: Sent".
    static let sentDescription = "Sent"

    /// Nothing written and nobody addressed (6.3.3).
    static let nothingToSend = MailToast(text: "Nothing to send yet.", action: nil)
    /// Something written, and nobody to send it to.
    static let addSomeone = MailToast(text: "Add someone to send to.", action: nil)

    /// The To field holds text that is not an address: "“sam@” isn't an address."
    static func notAnAddress(_ text: String) -> MailToast {
        MailToast(text: "\(quoted(text)) isn't an address.", action: nil)
    }

    /// A new message set aside: it has no conversation to show a mark in, so it says so, and
    /// where it is (`C` comes back to it).
    static let draftKept = MailToast(text: "Draft kept", action: nil)

    static let willSendWhenOnline =
        MailToast(text: "Will send when Banana is next open and online", action: .undo)

    static let draftDiscarded = MailToast(text: "Draft discarded", action: .undo)
}

#endif
