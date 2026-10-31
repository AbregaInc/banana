#if !BANANA_PUBLIC
import Foundation

/// Who a reply goes to, what it is called, and which message it answers: the rules a draft is
/// made by (MAIL-UX 6.3.3 gives them to the engine, MAIL-ENGINE 7.2 names them `ReplyRules`). A
/// screen never works any of it out; the source that makes the draft does, and the sample source
/// makes it with these.
///
/// Pure: values in, values out, no source and no clock.
enum MailReplyRules {

    /// Where a draft starts out: the people it goes to.
    struct Recipients: Equatable, Sendable {
        var to: [MailPerson]
        var cc: [MailPerson]
    }

    /// The message a reply to the conversation answers: its newest. A conversation's messages are
    /// oldest first, with his unsent ones last, so that is the last of them.
    static func original(in conversation: MailConversation) -> MailMessage? {
        conversation.messages.last
    }

    // MARK: Who it goes to

    /// - **Reply** goes to the sender, or to the address the sender asked for replies at; to a
    ///   message he wrote himself, it goes to the people he wrote it to.
    /// - **Reply to all** adds everyone else who was on it: the original's To and Cc stay where they
    ///   were.
    /// - **Forward** goes to nobody yet.
    ///
    /// **His own address is never in the result** — not as the sender of a message he is
    /// answering, not as one of its recipients — and nobody is in it twice, in To or in Cc, whichever
    /// spelling of the address was used. `myAddresses` are his, lower-cased.
    static func recipients(for kind: MailDraftKind, original: MailMessage,
                           myAddresses: Set<String>) -> Recipients {
        switch kind {
        case .new, .toAddress, .forward:
            return Recipients(to: [], cc: [])
        case .reply:
            return cleaned(to: answered(original, myAddresses), cc: [], myAddresses)
        case .replyAll:
            return cleaned(to: answered(original, myAddresses) + original.to, cc: original.cc, myAddresses)
        }
    }

    /// Who a reply to this one message goes to, before anyone is taken out.
    private static func answered(_ message: MailMessage, _ mine: Set<String>) -> [MailPerson] {
        if message.isMine || isMine(message.from, mine) { return message.to }
        return message.replyTo.isEmpty ? [message.from] : message.replyTo
    }

    private static func isMine(_ person: MailPerson, _ mine: Set<String>) -> Bool {
        person.isMe || mine.contains(person.address.lowercased())
    }

    private static func cleaned(to: [MailPerson], cc: [MailPerson], _ mine: Set<String>) -> Recipients {
        var seen: Set<String> = []
        func keep(_ people: [MailPerson]) -> [MailPerson] {
            people.filter { person in
                guard !isMine(person, mine) else { return false }
                return seen.insert(person.address.lowercased()).inserted
            }
        }
        let kept = keep(to)
        return Recipients(to: kept, cc: keep(cc))
    }

    // MARK: What it is called

    /// "Re: " or "Fwd: " once, never stacked: "Re: Re: Q3" is "Re: Q3", and "RE: q3" is "Re: q3".
    /// A forward of a reply is "Fwd: Re: Q3", which is what it is.
    static func subject(for kind: MailDraftKind, original: String) -> String {
        switch kind {
        case .new:
            return ""
        case .toAddress(_, let subject):
            return subject ?? ""
        case .reply, .replyAll:
            return prefixed("Re:", counting: ["re:"], original)
        case .forward:
            return prefixed("Fwd:", counting: ["fwd:", "fw:"], original)
        }
    }

    private static func prefixed(_ prefix: String, counting spellings: [String], _ subject: String) -> String {
        var rest = Substring(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        var stripped = true
        while stripped {
            stripped = false
            for spelling in spellings where rest.lowercased().hasPrefix(spelling) {
                rest = Substring(rest.dropFirst(spelling.count).trimmingCharacters(in: .whitespaces))
                stripped = true
                break
            }
        }
        return rest.isEmpty ? prefix : prefix + " " + rest
    }
}

#endif
