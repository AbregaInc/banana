#if !BANANA_PUBLIC
#if DEBUG || MAIL_FIXTURES
import Foundation

/// The hostile messages of MAIL-ENGINE 17.5 that are about who a message says it is from and
/// about its headers: the six sender fixtures of the security review's P-13, `header-1mb`, and
/// the ones its code review added (L11–L15) for the four ways a reader can be kinder than its
/// own rule.
///
/// Each is a whole `users.messages.get` response (`format=full`) as JSON text in a Swift
/// literal, in code and not in a resource, because the same message has to drive the unit
/// tests, the web view test and a route inside the app, and the app has no fixtures folder.
/// The very large ones are made by a function.
///
/// **They are not captured from a live mailbox.** Every one was written by hand from the
/// shapes Gmail's documentation gives, with invented ids, addresses on reserved example domains
/// and one made-up number for a date. What they prove is what the code does with those shapes.
/// What a real Gmail does with the same message — whether it sends header values already
/// decoded, in what order, with what folding, whether it accepts a `From` such as these at all —
/// is for the read probe.
///
/// **No character in this file that cannot be seen or that looks like another is written as
/// itself.** A right-to-left override, a Cyrillic letter that passes for a Latin one, a
/// full-width `@`: each is an escape, `\#u{202E}`, so that a diff and an editor show what is
/// there and the lines around it are not drawn backwards. (`MailTestingFenceTests` refuses the
/// raw ones.) Inside the JSON, a quotation mark is `\"` and a line break `\r\n`.
///
/// The later hostile fixtures (the HTML ones, the attachment ones, the unsubscribe ones) are
/// written by the packages that first use them (17.5), and each package registers its set in
/// `MailSlices.hostileMessageSets`.
enum MailHostileMessages {

    /// Every fixture of this package, by the name 17.5 gives it where it has one. `header-1mb`
    /// and its two-`From` sibling are generated on each call.
    static var senderAndHeaderSet: [(name: String, json: String)] {
        [
            ("from-name-is-address", fromNameIsAddress),
            ("from-rlo-subject", fromRLOSubject),
            ("from-homograph-domain", fromHomographDomain),
            ("reply-to-elsewhere", replyToElsewhere),
            ("correspondent-poison", correspondentPoison),
            ("header-injection-reply", headerInjectionReply),
            ("header-1mb", header1MB()),
        ] + addedByTheReview
    }

    /// The fixtures the code review added, which 17.5's list does not yet name.
    static var addedByTheReview: [(name: String, json: String)] {
        [
            ("from-quoted-name-and-bare-address", fromQuotedNameAndBareAddress),
            ("from-quoted-name-only", fromQuotedNameOnly),
            ("from-quoted-group-name", fromQuotedGroupName),
            ("from-two-bare-addresses", fromTwoBareAddresses),
            ("from-two-brackets", fromTwoBrackets),
            ("from-bracket-then-bare", fromBracketThenBare),
            ("from-two-headers", fromTwoHeaders),
            ("from-dmarc-disagrees", fromDMARCDisagrees),
            ("from-fullwidth-at-local-part", fromFullwidthAtLocalPart),
            ("from-variation-selector-local-part", fromVariationSelectorLocalPart),
            ("from-hangul-filler-local-part", fromHangulFillerLocalPart),
            ("from-mixed-script-local-part", fromMixedScriptLocalPart),
            ("auth-results-forged-below-other-server", authResultsForgedBelowOtherServer),
            ("header-1mb-two-froms", header1MB(twoFroms: true)),
        ]
    }

    /// Decodes a fixture's JSON as the engine would.
    static func decode(_ json: String) throws -> GmailMessage {
        try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    // MARK: - The six sender fixtures

    /// The display name is an address — and not the one the message came from. A reader that
    /// shows the name shows "noor@plan.example" over a message from x@evil.example.
    static let fromNameIsAddress = message(
        id: "17f1a0c2d3e4b501",
        headers: #"""
        {"name": "Delivered-To", "value": "noor@plan.example"},
        {"name": "From", "value": "\"noor@plan.example\" <x@evil.example>"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Please confirm the transfer"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:12:00 +0000"},
        {"name": "Message-ID", "value": "<name-is-address@evil.example>"}
        """#)

    /// A right-to-left override in the subject, which would make "fdp.exe" read as "exe.pdf".
    static let fromRLOSubject = message(
        id: "17f1a0c2d3e4b502",
        headers: #"""
        {"name": "From", "value": "Accounts <accounts@example.org>"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Invoice \#u{202E}fdp.exe"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:13:00 +0000"},
        {"name": "Message-ID", "value": "<rlo-subject@example.org>"}
        """#)

    /// A Cyrillic "a" (U+0430) in the domain of an address that is meant to read as Latin. The
    /// address has to reach the UI as its `xn--` form, where the difference shows.
    static let fromHomographDomain = message(
        id: "17f1a0c2d3e4b503",
        headers: #"""
        {"name": "From", "value": "Apple Support <support@\#u{0430}pple.com>"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Your account"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:14:00 +0000"},
        {"name": "Message-ID", "value": "<homograph@example.org>"}
        """#)

    /// A reply would go somewhere other than where the message came from.
    static let replyToElsewhere = message(
        id: "17f1a0c2d3e4b504",
        headers: #"""
        {"name": "From", "value": "Alice Example <alice@example.com>"},
        {"name": "Reply-To", "value": "Alice <alice.replies@other.example>"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Hello"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:15:00 +0000"},
        {"name": "Message-ID", "value": "<reply-to@example.com>"}
        """#)

    /// A name planted on a lookalike address: "Jane Park" at an address that is not the Jane he
    /// writes to. Nothing may join them by name.
    static let correspondentPoison = message(
        id: "17f1a0c2d3e4b505",
        headers: #"""
        {"name": "From", "value": "\"Jane Park\" <jane.park@z0-ai.example>"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Lunch?"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:16:00 +0000"},
        {"name": "Message-ID", "value": "<poison@z0-ai.example>"}
        """#)

    /// Line breaks where a header value must have none: a subject and a name that, copied into
    /// a reply as they are, would add a `Bcc`.
    static let headerInjectionReply = message(
        id: "17f1a0c2d3e4b506",
        headers: #"""
        {"name": "From", "value": "Mallory <mallory@example.net>"},
        {"name": "To", "value": "\"Team\r\nBcc: attacker@evil.example\" <team@example.net>"},
        {"name": "Subject", "value": "Re: invoice\r\nBcc: attacker@evil.example"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:17:00 +0000"},
        {"name": "Message-ID", "value": "<injection@example.net>"}
        """#)

    // MARK: - MAJOR 1: what is in quotes is a name, never an address

    /// Without angle brackets, a quoted name beside a bare address. The sender is the bare
    /// address; the quoted text is its name, and is an address that is not shown. A reader that
    /// tried the quoted string first would make the victim the sender.
    static let fromQuotedNameAndBareAddress = message(
        id: "17f1a0c2d3e4b510",
        headers: ordinary(from: #"\"ceo@victim.example\" attacker@evil.example"#))

    /// A quoted name and a word that is no address: nothing in the line is an address outside the
    /// quotes, and the sender is unreadable, not the victim.
    static let fromQuotedNameOnly = message(
        id: "17f1a0c2d3e4b511",
        headers: ordinary(from: #"\"ceo@victim.example\" x"#))

    /// A quoted group name holding the victim's address, then the attacker's address as its one
    /// member. A standard reader sees a group of one, the attacker's; and a group is no sender.
    static let fromQuotedGroupName = message(
        id: "17f1a0c2d3e4b512",
        headers: ordinary(from: #"\"ceo@victim.example\": a@evil.example;"#))

    /// Two bare addresses with no comma between them: one thing that cannot be read, and the
    /// first of them is the victim's.
    static let fromTwoBareAddresses = message(
        id: "17f1a0c2d3e4b513",
        headers: ordinary(from: "ceo@victim.example a@evil.example"))

    // MARK: - MAJOR 2: the sender when From is not exactly one mailbox

    /// Two bracketed addresses: the first is the forged one.
    static let fromTwoBrackets = message(
        id: "17f1a0c2d3e4b514",
        headers: ordinary(from: "Sam <sam@plan.example> <x@evil.example>"))

    /// A bracketed address with a bare one joined on.
    static let fromBracketThenBare = message(
        id: "17f1a0c2d3e4b515",
        headers: ordinary(from: "<sam@plan.example>x@evil.example"))

    /// Two `From` headers. Gmail is believed to refuse such a message at the door; if it does not,
    /// it and the screen would otherwise be reading different lines.
    static let fromTwoHeaders = message(
        id: "17f1a0c2d3e4b516",
        headers: #"""
        {"name": "From", "value": "Sam <sam@plan.example>"},
        {"name": "From", "value": "Mallory <x@evil.example>"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Two senders"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:20:00 +0000"},
        {"name": "Message-ID", "value": "<two-froms@example.org>"}
        """#)

    /// Gmail's own header says it took the sender to be evil.example, and the `From` line reads
    /// as victim.example: two readers of one line, disagreeing about whose it is.
    static let fromDMARCDisagrees = message(
        id: "17f1a0c2d3e4b517",
        headers: #"""
        {"name": "Authentication-Results", "value": "mx.google.com; dkim=pass header.i=@evil.example header.s=sel header.b=abcd1234; spf=pass (google.com: domain of x@evil.example designates 192.0.2.1 as permitted sender) smtp.mailfrom=x@evil.example; dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=evil.example"},
        {"name": "From", "value": "Boss <boss@victim.example>"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Wire transfer"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:21:00 +0000"},
        {"name": "Message-ID", "value": "<dmarc-disagrees@evil.example>"}
        """#)

    // MARK: - MAJOR 3: what an address may contain

    /// A full-width commercial at (U+FF20) in the local part: `noor`, that character, `plan.example@evil.example`
    /// reads as his own address with a tail, and the one real "@" is the last.
    static let fromFullwidthAtLocalPart = message(
        id: "17f1a0c2d3e4b518",
        headers: ordinary(from: #"x <noor\#u{FF20}plan.example@evil.example>"#))

    /// A variation selector (U+FE00) in the local part: cannot be told from `sam@plan.example`.
    static let fromVariationSelectorLocalPart = message(
        id: "17f1a0c2d3e4b519",
        headers: ordinary(from: #"Sam <sam\#u{FE00}@plan.example>"#))

    /// A Hangul filler (U+3164), a letter that draws nothing, in the local part.
    static let fromHangulFillerLocalPart = message(
        id: "17f1a0c2d3e4b51a",
        headers: ordinary(from: #"Sam <sam\#u{3164}@plan.example>"#))

    /// A Cyrillic "o" (U+043E) among Latin letters in one word of the local part: `noor`.
    static let fromMixedScriptLocalPart = message(
        id: "17f1a0c2d3e4b51b",
        headers: ordinary(from: #"Noor <n\#u{043E}or@plan.example>"#))

    // MARK: - MAJOR 4: only the first Authentication-Results, and only if it is Gmail's

    /// A message that did not come through Gmail's receiving servers: another provider's header
    /// is on top, and a line the sender wrote, claiming to be Google's and passing DMARC for
    /// the victim's domain, sits below it.
    static let authResultsForgedBelowOtherServer = message(
        id: "17f1a0c2d3e4b51c",
        headers: #"""
        {"name": "Authentication-Results", "value": "mx.other-provider.example; dkim=fail header.d=victim.example; dmarc=fail header.from=victim.example"},
        {"name": "Authentication-Results", "value": "mx.google.com; dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=victim.example"},
        {"name": "From", "value": "Boss <boss@victim.example>"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Please pay this"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:22:00 +0000"},
        {"name": "Message-ID", "value": "<forged-auth@victim.example>"}
        """#)

    // MARK: - header-1mb

    /// "A 1 MB `Subject` and 5,000 `Received` lines": Gmail's own `Authentication-Results` on
    /// top, five thousand trace lines as a sender who wants to bury what follows would write
    /// them, then `From`, a `Subject` of one mebibyte, and the rest. Read under the header
    /// limits, the first thousand fields are kept; `From` and the other named headers are found
    /// past them (5.6), so the sender is still the sender and the subject is cut at 16 KB.
    ///
    /// - Parameter twoFroms: add a second `From` after the first, both past the cut: still two
    ///   `From` headers, and so no sender.
    static func header1MB(received: Int = 5_000, subjectBytes: Int = 1_048_576,
                          twoFroms: Bool = false) -> String {
        var headers: [[String: String]] = [
            ["name": "Authentication-Results",
             "value": "mx.google.com; spf=pass smtp.mailfrom=sender@example.com"],
        ]
        for n in 0..<received {
            headers.append([
                "name": "Received",
                "value": "from relay\(n).example.net (relay\(n).example.net [192.0.2.\(n % 250)]) "
                    + "by mx.example.net with ESMTP id r\(n); Tue, 06 Oct 2026 09:18:00 +0000",
            ])
        }
        headers.append(["name": "From", "value": "Sender <sender@example.com>"])
        if twoFroms { headers.append(["name": "From", "value": "Other <other@evil.example>"]) }
        headers.append(["name": "To", "value": "noor@plan.example"])
        headers.append(["name": "Subject", "value": String(repeating: "S", count: subjectBytes)])
        headers.append(["name": "Date", "value": "Tue, 06 Oct 2026 09:18:00 +0000"])
        headers.append(["name": "Message-ID", "value": "<header-1mb@example.com>"])

        let object: [String: Any] = [
            "id": twoFroms ? "17f1a0c2d3e4b51d" : "17f1a0c2d3e4b507",
            "threadId": twoFroms ? "17f1a0c2d3e4b51d" : "17f1a0c2d3e4b507",
            "labelIds": ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], "snippet": "Hello.",
            "historyId": "904007", "internalDate": "1791277920000", "sizeEstimate": 1_600_000,
            "payload": [
                "partId": "", "mimeType": "text/plain", "filename": "",
                "headers": headers,
                "body": ["size": 6, "data": "SGVsbG8u"],
            ] as [String: Any],
        ]
        // The input is a dictionary of strings and numbers, which always serialises.
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Shape

    /// The headers of an ordinary message from `from`, which is JSON text already (its quotation
    /// marks escaped), so that a fixture is its `From` line and nothing else.
    private static func ordinary(from: String) -> String {
        """
        {"name": "From", "value": "\(from)"},
        {"name": "To", "value": "noor@plan.example"},
        {"name": "Subject", "value": "Hello"},
        {"name": "Date", "value": "Tue, 06 Oct 2026 09:19:00 +0000"},
        {"name": "Message-ID", "value": "<ordinary@example.org>"}
        """
    }

    /// The shape every one shares: a received, unread, personal message with a one-line text
    /// body, whose headers are the point.
    private static func message(id: String, headers: String) -> String {
        """
        {
          "id": "\(id)",
          "threadId": "\(id)",
          "labelIds": ["INBOX", "UNREAD", "CATEGORY_PERSONAL"],
          "snippet": "Hello.",
          "historyId": "904001",
          "internalDate": "1791277920000",
          "sizeEstimate": 2310,
          "payload": {
            "partId": "",
            "mimeType": "text/plain",
            "filename": "",
            "headers": [
              \(headers)
            ],
            "body": {"size": 6, "data": "SGVsbG8u"}
          }
        }
        """
    }
}
#endif

#endif
