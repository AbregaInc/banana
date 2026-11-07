#if !BANANA_PUBLIC
import Foundation

/// One of Banana's own Gmail labels, read from its name (MAIL-ENGINE 8.1).
enum BananaLabel: Equatable, Sendable {
    case snoozed(Date), returned, muted
}

/// What a conversation's Banana labels say about it. Times are ms since 1970, as the index keeps them.
struct BananaState: Equatable, Sendable {
    /// The latest `Snoozed/<t>` on the conversation: when it comes back, or came back.
    var wakeAt: Int64?
    /// `Returned` is on it: it came back, at this time.
    var returnedAt: Int64?
    var inInbox = false
    var muted = false

    /// Out of the inbox until `wakeAt`: what the Snoozed mailbox lists.
    var isSnoozed: Bool { wakeAt != nil && returnedAt == nil && !inInbox }
    /// Back in the inbox because its time came: "Back from snooze".
    var isBack: Bool { returnedAt != nil && inInbox }
}

/// Banana's snooze, kept in Gmail as hidden labels, because Gmail's API has no snooze (MAIL-ENGINE 8).
/// A snoozed conversation really is out of the inbox, for every client; the time it comes back is in
/// a label's name; waking it is "this message has `INBOX`", the same whether one device says it, three,
/// or the cloud mailbox does. Every rule here produces a desired end state, so a second wake is the
/// same change as the first. The service runs the same three rules (Service/src/mail-snooze.js).
enum BananaLabelRules {
    static let prefix = "Banana/"
    static let snoozedPrefix = "Banana/Snoozed/"
    static let returned = "Banana/Returned"
    static let muted = "Banana/Muted"
    /// An intent's reference to a label by its name, until delivery has Gmail's id for it (6.5 step 2).
    static let namePrefix = "name:"

    private static let step: TimeInterval = 5 * 60
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Rounded up to five minutes, so at most 288 snooze labels can exist for a day.
    static func rounded(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / step).rounded(.up) * step)
    }

    /// `Banana/Snoozed/20261107T0805Z`: UTC, rounded up to five minutes.
    static func snoozedName(until: Date) -> String {
        let calendar = utc
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: rounded(until))
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return snoozedPrefix + String(format: "%04d", parts.year ?? 0) + two(parts.month) + two(parts.day)
            + "T" + two(parts.hour) + two(parts.minute) + "Z"
    }

    static func parse(_ name: String) -> BananaLabel? {
        if name == returned { return .returned }
        if name == muted { return .muted }
        guard name.hasPrefix(snoozedPrefix) else { return nil }
        let stamp = Array(name.dropFirst(snoozedPrefix.count))
        guard stamp.count == 14, stamp[8] == "T", stamp[13] == "Z" else { return nil }
        let digits = stamp[0..<8] + stamp[9..<13]
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        func number(_ range: Range<Int>) -> Int { Int(String(stamp[range]))! }
        var parts = DateComponents()
        parts.year = number(0..<4); parts.month = number(4..<6); parts.day = number(6..<8)
        parts.hour = number(9..<11); parts.minute = number(11..<13)
        // A date that does not exist (the 30th of February, 24:00) does not come back as itself.
        let calendar = utc
        guard let date = calendar.date(from: parts) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == parts.year, back.month == parts.month, back.day == parts.day,
              back.hour == parts.hour, back.minute == parts.minute else { return nil }
        return .snoozed(date)
    }

    static func isSnoozedName(_ name: String) -> Bool {
        if case .snoozed? = parse(name) { return true }
        return false
    }

    /// Whether a message takes part: the bin is never woken into the inbox.
    private static func counts(_ message: MessageFacts) -> Bool {
        message.vis != 3 && !message.labels.contains("TRASH") && !message.labels.contains("SPAM")
    }
    private static func snoozeTimes(_ message: MessageFacts) -> [Int64] {
        message.bananaLabels.compactMap {
            if case .snoozed(let date)? = parse($0) { return Int64(date.timeIntervalSince1970 * 1000) }
            return nil
        }
    }

    /// What a conversation's labels say about it. With several Snoozed labels, the latest time.
    static func state(_ messages: [MessageFacts]) -> BananaState {
        var state = BananaState()
        for message in messages where counts(message) {
            let times = snoozeTimes(message)
            if let latest = times.max() { state.wakeAt = max(state.wakeAt ?? latest, latest) }
            if message.labels.contains("INBOX") { state.inInbox = true }
            if message.bananaLabels.contains(muted) { state.muted = true }
        }
        let carrying = messages.filter { counts($0) && $0.bananaLabels.contains(returned) }
        if !carrying.isEmpty {
            state.returnedAt = carrying.flatMap(snoozeTimes).max() ?? state.wakeAt ?? 0
        }
        return state
    }

    /// The label refs a message carries that a snooze put there: every `Snoozed/*` and `Returned`.
    static func snoozeRefs(_ message: MessageFacts) -> [String] {
        message.bananaLabelIDs.filter { name, _ in name == returned || isSnoozedName(name) }.map(\.value).sorted()
    }

    /// The id to name a Banana label by: Gmail's when this account has it, its name until then.
    static func ref(_ name: String, ids: [String: String]) -> String { ids[name] ?? namePrefix + name }

    /// The assertions due for one conversation at `now` (8.2 rules 1, 2 and 5), each `origin: .rule`.
    /// Nothing that is already true is produced.
    static func due(_ messages: [MessageFacts], account: String, ids: [String: String], now: Int64) -> [Assertion] {
        let live = messages.filter(counts)
        let carrying = messages.filter { $0.vis != 3 && !snoozeRefs($0).isEmpty }
        guard !carrying.isEmpty else { return [] }
        var result: [Assertion] = []
        func set(_ ref: String, _ want: Bool, on message: MessageFacts) {
            guard message.labels.contains(ref) != want else { return }
            result.append(Assertion(account: account, messageID: message.gmailID, labelRef: ref, want: want, origin: .rule))
        }
        func clear(_ values: [MessageFacts]) {
            for message in values { for ref in snoozeRefs(message) { set(ref, false, on: message) } }
        }
        let snoozedLive = live.filter { !snoozeTimes($0).isEmpty }
        // Every snoozed message is in the bin: nothing to bring back, only labels to take off.
        if snoozedLive.isEmpty, !carrying.contains(where: counts) { clear(carrying); return result }
        let state = Self.state(messages)
        if state.returnedAt == nil, !state.inInbox, let wake = state.wakeAt, wake <= now {
            // 1. Wake: INBOX on the last message that is not a draft, Returned on every message that
            //    carries a snooze label, in one request per message, the INBOX one first.
            let ordered = live.filter { !$0.labels.contains("DRAFT") }.sorted {
                ($0.internalDate, $0.gmailID) < ($1.internalDate, $1.gmailID)
            }
            guard let last = ordered.last else { return [] }
            let returnedRef = ref(returned, ids: ids)
            set("INBOX", true, on: last)
            set("UNREAD", true, on: last)
            if !snoozeTimes(last).isEmpty { set(returnedRef, true, on: last) }
            for message in snoozedLive where message.gmailID != last.gmailID { set(returnedRef, true, on: message) }
        } else if state.returnedAt == nil, state.inInbox, state.wakeAt != nil {
            // 2. Came back early — a reply arrived, or he moved it back in Gmail: the snooze is over.
            clear(carrying)
        } else if state.returnedAt != nil, !state.inInbox {
            // 5. Left the inbox after coming back: nothing of the snooze is left to fire.
            clear(carrying)
        }
        return result
    }
}

#endif
