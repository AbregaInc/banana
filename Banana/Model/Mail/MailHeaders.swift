#if !BANANA_PUBLIC
import Foundation

/// A message's headers, as Gmail sent them: every one, in the order the message has them,
/// found by name without regard to case (MAIL-ENGINE 5.6, 10.8).
///
/// The headers are the sender's, so they are read under limits. A message can carry a megabyte
/// of `Subject` and five thousand `Received` lines; reading them all is what such a message is
/// for. At most `maxLines` fields are kept, at most `maxBytes` of names and values together,
/// and no value is longer than `maxValueBytes`. What is cut is *unknown*, not absent
/// (invariant 1): a header that Gmail sent and a limit removed is not a header the message
/// lacks, so `isComplete` says whether anything was cut.
///
/// **A limit bounds what is kept, not what is known.** The headers the engine reads by name
/// (`namedHeaders`: the list of the header format, less `Authentication-Results`) are looked
/// for through the whole of what Gmail sent, and the first of each that the kept part lacks is
/// kept too, its value cut at 16 KB like any other. A `From` placed after five thousand lines
/// of padding is still the sender, as it is in Gmail: hiding it costs the sender nothing and
/// would otherwise have worked. `Authentication-Results` is not looked for further down. Its
/// meaning is its position (10.6), and it is read from what the limits keep or not at all.
/// (These extras are at most twenty headers of 16 KB each, beyond the limits.)
///
/// The order is kept because it carries meaning that the names do not: the first
/// `Authentication-Results` is the one Gmail added on receipt, and a sender's own sits below
/// it (`MailAuthRules`).
///
/// **Who a message is from is `sender`, and nothing else takes an address out of `From`.**
struct MessageHeaders: Equatable, Sendable {

    /// Most fields kept before the named headers past the cut.
    static let maxLines = 1_000
    /// Most bytes kept, names and values (UTF-8) together: 256 KB.
    static let maxBytes = 256 * 1_024
    /// Longest a value is kept, in UTF-8 bytes: 16 KB.
    static let maxValueBytes = 16 * 1_024

    /// The headers read by name, folded: the header format of 5.6 less `Authentication-Results`.
    static let namedHeaders: Set<String> = [
        "from", "sender", "to", "cc", "bcc", "reply-to", "subject", "date", "message-id",
        "in-reply-to", "references", "list-id", "list-unsubscribe", "list-unsubscribe-post",
        "content-type", "delivered-to", "auto-submitted", "x-google-original-message-id",
        "x-banana-send-at", "x-banana-send-owner",
    ]

    struct Field: Equatable, Sendable {
        /// As written.
        let name: String
        /// As written, unfolded or not as Gmail sent it, cut at `maxValueBytes`.
        let value: String
        /// Set when `value` is only the front of what Gmail sent, or when Gmail sent the header
        /// with no value at all (then it is empty and not known).
        let wasCut: Bool
        /// The name for comparing: ASCII upper case made lower, nothing else touched. Header
        /// names are ASCII; folding more than that would equate names the standard does not
        /// (the Kelvin sign is a "k" under full case folding).
        fileprivate let key: String
    }

    /// The fields kept, in the message's own order: the first `maxLines` or so, then the named
    /// headers found past them.
    private(set) var fields: [Field]

    /// False when this holds less than the message's headers: Gmail sent none (a `minimal`
    /// read has no headers at all), some had no name or no value, or a limit cut something.
    /// A header that is missing from an incomplete set may well be on the message — which is
    /// why the named ones are looked for past the cut.
    private(set) var isComplete: Bool

    /// How many `From` headers Gmail sent, counted through the whole of them, kept or not: a
    /// second one placed past the cut is still a second one.
    private(set) var fromHeaderCount: Int

    /// Headers of a message with none read: nothing is known, so it is not complete.
    static let unread = MessageHeaders([], isComplete: false)

    /// - Parameters:
    ///   - pairs: every header, name and value, in order.
    ///   - isComplete: false if `pairs` is already known to be only some of the message's
    ///     headers (a set restored from storage that had been cut). Cutting here can only
    ///     make it false.
    init(_ pairs: [(String, String)], isComplete: Bool = true) {
        self.init(entries: pairs.map { ($0.0, $0.1, false) }, isComplete: isComplete)
    }

    /// The headers of a Gmail message part, normally `payload`.
    ///
    /// Gmail sends `headers` on `metadata` and `full` reads and not on `minimal` ones (UNVERIFIED
    /// exactly which formats do, which is why nothing here assumes): no `headers` key at all is
    /// *unknown*, an empty array is a message with no headers. A header with no name cannot be
    /// looked up and is dropped; one with a name and no value is kept, empty and marked cut, so
    /// that it holds its place — the first `Authentication-Results` must stay the first — and
    /// is not read. Either makes the set incomplete.
    init(payload: GmailPart?) {
        guard let list = payload?.headers else {
            self.init(entries: [], isComplete: false)
            return
        }
        var entries: [(String, String, Bool)] = []
        entries.reserveCapacity(list.count)
        var complete = true
        for header in list {
            guard let name = header.name, !name.isEmpty else { complete = false; continue }
            if header.value == nil { complete = false }
            entries.append((name, header.value ?? "", header.value == nil))
        }
        self.init(entries: entries, isComplete: complete)
    }

    private init(entries: [(String, String, Bool)], isComplete: Bool) {
        var kept: [Field] = []
        var complete = isComplete
        var bytes = 0
        var fromCount = 0
        var have = Set<String>()
        var stoppedAt: Int?

        for (index, entry) in entries.enumerated() {
            let (name, rawValue, unknown) = entry
            let nameBytes = name.utf8.count
            // A name that long is no header any reader here looks for, and keeping it would
            // spend the budget on nothing; dropping it is a cut like any other.
            guard nameBytes > 0, nameBytes <= Self.maxValueBytes else { complete = false; continue }
            if kept.count >= Self.maxLines { stoppedAt = index; break }
            let (value, cut) = Self.cut(rawValue)
            if bytes + nameBytes + value.utf8.count > Self.maxBytes { stoppedAt = index; break }
            bytes += nameBytes + value.utf8.count
            let wasCut = cut || unknown
            if wasCut { complete = false }
            let key = Self.fold(name)
            if key == "from" { fromCount += 1 }
            if Self.namedHeaders.contains(key) { have.insert(key) }
            kept.append(Field(name: name, value: value, wasCut: wasCut, key: key))
        }

        if let stop = stoppedAt {
            complete = false
            for entry in entries[stop...] {
                let (name, rawValue, unknown) = entry
                // Longer than the longest header looked for: it is none of them.
                guard name.utf8.count <= 32 else { continue }
                let key = Self.fold(name)
                if key == "from" { fromCount += 1 }
                guard Self.namedHeaders.contains(key), !have.contains(key) else { continue }
                have.insert(key)
                let (value, cut) = Self.cut(rawValue)
                kept.append(Field(name: name, value: value, wasCut: cut || unknown, key: key))
            }
        }

        fields = kept
        self.isComplete = complete
        fromHeaderCount = fromCount
    }

    /// Every field as a `(name, value)` pair, in order: the shape the rules that take headers
    /// (reply and unsubscribe rules) are given.
    var pairs: [(String, String)] { fields.map { ($0.name, $0.value) } }

    // MARK: - Lookup

    /// The first header named `name`, or nil if the set has none. Nil is "none *kept*"; see
    /// `isComplete`.
    func value(_ name: String) -> String? {
        let key = Self.fold(name)
        return fields.first { $0.key == key }?.value
    }

    /// The first header named `name`, with whether its value was cut.
    func field(_ name: String) -> Field? {
        let key = Self.fold(name)
        return fields.first { $0.key == key }
    }

    /// Every header named `name`, in order.
    func values(_ name: String) -> [String] {
        let key = Self.fold(name)
        return fields.filter { $0.key == key }.map(\.value)
    }

    func contains(_ name: String) -> Bool {
        let key = Self.fold(name)
        return fields.contains { $0.key == key }
    }

    // MARK: - Who it is from

    /// **Who the message is from, or nil: the one reading, and nothing else takes an address out
    /// of `From`** (MAIL-ENGINE 10.8). A single mailbox or nothing — never the first of several,
    /// because in every shape with more than one the first is the one a forger chose to put
    /// there.
    ///
    /// It answers a mailbox only when **all** of these hold:
    /// - Gmail sent exactly one `From` header (counted through all of them, kept or not);
    /// - its value was not cut;
    /// - it reads as exactly one mailbox: one address, no second, no group, nothing left over
    ///   that could not be read, and a list that is complete;
    /// - that address is one an address may be (`MailAddressRules.normalized`, which also
    ///   refuses the look-alike and the invisible); and
    /// - when Gmail's own header (`MailAuthRules`) carries a `dmarc=` result, of any verdict,
    ///   its `header.from` is the domain of that address. Gmail and Banana are two readers of
    ///   one line; when they disagree about whose it is, what Gmail authenticated is not what
    ///   the screen would show, and the honest answer is neither.
    ///
    /// Nil is **the unreadable sender**, one state however it came about: no `From`, more than
    /// one, a group, an address that is not one, a value cut before its address, a `From` Gmail
    /// read differently. Nothing downstream tells them apart. The mailbox's `name` is not yet
    /// judged (`MailAddressRules.displayName`, asked once, when the message is stored).
    var sender: MailAddress? {
        guard fromHeaderCount == 1 else { return nil }
        let from = fields.filter { $0.key == "from" }
        guard from.count == 1, !from[0].wasCut else { return nil }
        let list = MailAddressList.parse(from[0].value)
        guard list.isComplete, !list.hasGroup, list.items.count == 1,
              case .mailbox(let mailbox) = list.items[0] else { return nil }
        guard MailAuthRules.dmarcAgrees(headers: self, with: mailbox.domain) else { return nil }
        return mailbox
    }

    // MARK: - The readers

    /// The address headers, read: `Sender`, `Reply-To`, `To`, `Cc`, `Bcc` and `Delivered-To` are
    /// lists of mailboxes, and every one is read the same way (`MailAddressList.parse`). **`From`
    /// is read with the rest and is not a sender** — ask `sender`.
    ///
    /// All the occurrences of `name`, joined in order. A header written twice is two lists, and
    /// both are there. A value that was cut has its last mailbox left out, since it may be half
    /// an address, and the list says it is incomplete.
    func addresses(_ name: String) -> MailAddressList {
        let key = Self.fold(name)
        var items: [MailAddressList.Item] = []
        var complete = true
        var group = false
        for field in fields where field.key == key {
            let list = MailAddressList.parse(field.value, isComplete: !field.wasCut)
            items += list.items
            if !list.isComplete { complete = false }
            if list.hasGroup { group = true }
        }
        return MailAddressList(items: items, isComplete: complete, hasGroup: group)
    }

    var replyTo: MailAddressList { addresses("Reply-To") }
    var to: MailAddressList { addresses("To") }
    var cc: MailAddressList { addresses("Cc") }
    var bcc: MailAddressList { addresses("Bcc") }
    var deliveredTo: MailAddressList { addresses("Delivered-To") }

    /// The text of an unstructured header (`Subject`) as a person reads it: unfolded, its
    /// RFC 2047 words decoded, cleaned of what cannot be seen (`MailHeaderText.unstructured`).
    /// The first occurrence; nil if there is none.
    func text(_ name: String) -> String? {
        value(name).map(MailHeaderText.unstructured)
    }

    var subject: String? { text("Subject") }

    // MARK: - Limits

    /// ASCII lower case only.
    static func fold(_ name: String) -> String {
        var needsFold = false
        for byte in name.utf8 where byte >= 0x41 && byte <= 0x5A { needsFold = true; break }
        guard needsFold else { return name }
        return String(decoding: name.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 },
                      as: UTF8.self)
    }

    /// `value` cut to `maxValueBytes` on a character boundary.
    private static func cut(_ value: String) -> (String, Bool) {
        guard value.utf8.count > maxValueBytes else { return (value, false) }
        // Back off from the limit to the start of a scalar (a UTF-8 continuation byte is
        // 10xxxxxx), so that nothing is cut in the middle of a character.
        var end = maxValueBytes
        let bytes = Array(value.utf8.prefix(maxValueBytes + 1))
        while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return (String(decoding: bytes[..<end], as: UTF8.self), true)
    }
}

#endif
