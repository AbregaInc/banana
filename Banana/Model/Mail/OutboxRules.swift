#if !BANANA_PUBLIC
import Foundation

/// Message-level assertions; never issue a thread mutation that can sweep in a later reply.
enum OutboxRules {
    enum Failure: Error { case unsupportedChange, invalidLabels }

    /// `bananaLabelIDs`: this account's own labels Gmail already has, name → id (section 8). A Banana
    /// label it does not have yet is named (`name:<name>`) and delivery creates it (6.5 step 2).
    static func assertions(for change: MailChange, account: String, messages: [MessageFacts], asOf: Int64,
                           bananaLabelIDs: [String: String] = [:]) throws -> [Assertion] {
        let eligible = messages.filter {
            (0...2).contains($0.vis) && $0.internalDate <= asOf && !$0.labels.contains("DRAFT")
        }.sorted {
            if $0.internalDate != $1.internalDate { return $0.internalDate < $1.internalDate }
            return $0.gmailID < $1.gmailID
        }
        var result: [Assertion] = []
        func set(_ label: String, _ want: Bool, on values: [MessageFacts]) {
            for message in values {
                let present: Bool? = message.labels.contains(label) ? true : message.labelsKnown ? false : nil
                guard !isMoot(want: want, gmailHas: present) else { continue }
                result.append(Assertion(account: account, messageID: message.gmailID, labelRef: label, want: want, origin: .person))
            }
        }
        let last = eligible.last.map { [$0] } ?? []
        /// Any change of his that takes a conversation out of the inbox also ends what a snooze left
        /// on it, so nothing of it is left to fire (8.2, E-5). `keeping`: the snooze being made now.
        func endSnooze(keeping: String? = nil) {
            for message in eligible {
                for ref in BananaLabelRules.snoozeRefs(message) where ref != keeping { set(ref, false, on: [message]) }
            }
        }
        switch change {
        case .done: set("INBOX", false, on: eligible); set("UNREAD", false, on: eligible); endSnooze()
        case .notDone: set("INBOX", true, on: last)
        case .read(let read): set("UNREAD", !read, on: read ? eligible : last)
        case .star(let star): set("STARRED", star, on: star ? last : eligible)
        case .important(let important): set("IMPORTANT", important, on: eligible)
        case .trash: set("TRASH", true, on: eligible); endSnooze()
        case .restore: set("TRASH", false, on: eligible)
        case .spam: set("SPAM", true, on: eligible); set("INBOX", false, on: eligible); endSnooze()
        case .notSpam: set("SPAM", false, on: eligible); set("INBOX", true, on: eligible)
        case .label(let owner, let add, let remove):
            guard owner.lowercased() == account.lowercased() else { return [] }
            guard !add.contains(""), !remove.contains(""), Set(add).isDisjoint(with: remove) else { throw Failure.invalidLabels }
            for label in Set(add).sorted() { set(label, true, on: eligible) }
            for label in Set(remove).sorted() { set(label, false, on: eligible) }
        case .move(let owner, let to, let from):
            guard owner.lowercased() == account.lowercased() else { return [] }
            guard !to.isEmpty, from != "", to != (from ?? "INBOX") else { throw Failure.invalidLabels }
            set(to, true, on: eligible); set(from ?? "INBOX", false, on: eligible); endSnooze()
        case .snooze(let until, let ifNoReply):
            // "If no reply" is Waiting/<t> (8.1, P19b), which is not built: never a plain snooze in disguise.
            guard !ifNoReply else { throw Failure.unsupportedChange }
            // Out of the inbox, with the time it comes back in a label's name; any other snooze and a
            // Returned from an earlier one go, so two devices that snoozed offline converge (8.2).
            let ref = BananaLabelRules.ref(BananaLabelRules.snoozedName(until: until), ids: bananaLabelIDs)
            set(ref, true, on: eligible); set("INBOX", false, on: eligible)
            endSnooze(keeping: ref)
        case .unsnooze:
            endSnooze(); set("INBOX", true, on: last)
        case .mute:
            // Mute needs rule 6 (replies kept out of the inbox) running somewhere; not built.
            throw Failure.unsupportedChange
        }
        return result
    }

    static func isMoot(want: Bool, gmailHas: Bool?) -> Bool { gmailHas == want }
}

#endif
