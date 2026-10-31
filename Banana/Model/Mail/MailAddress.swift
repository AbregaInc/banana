#if !BANANA_PUBLIC
import Foundation

// Who a message says it is from, and everything that has to be read to say it: the rules of
// MAIL-ENGINE 10.8, the reading of an address list (RFC 5322 section 3.4, with the shapes real
// mail takes), and the decoding of RFC 2047 encoded words.
//
// This is the most hostile text the app reads. Every name and address in a header was written
// by whoever sent the message, and a person decides what to do with a message by who it
// appears to be from. So each reader here answers for every input, in time proportional to
// its length, and keeps apart what the sender put apart: a display name is never merged into
// the address beside it, because a name that says "noor@plan.example" beside the address
// x@evil.example is the whole of the attack.
//
// There is no system parser for address lists (reuse review B-15), so the reader is built
// here; the parts of it a system component does are not: charsets are
// `CFStringConvertIANACharSetNameToEncoding`, base64 is Foundation, a non-ASCII domain is
// converted by `URLComponents`, "reads as a URL" is `NSDataDetector`, and a letter's script
// is `NSRegularExpression`'s `\p{Script=…}`.

// MARK: - The rules

enum MailAddressRules {

    /// The longest address that is accepted, in UTF-8 bytes: 64 for the local part, the "@",
    /// and 255 for the domain, as the standards allow, with a little over. A longer one is not
    /// an address.
    static let maxAddressBytes = 320

    /// The longest display name that is shown, in characters. A name is a few words; one
    /// longer than this is text meant to fill the space beside the address, and the address is
    /// shown instead. It also bounds the checks below, which are not free.
    static let maxNameCharacters = 256

    /// Whether `address` is one: `normalized` gives an answer.
    static func isValid(_ address: String) -> Bool {
        normalized(address) != nil
    }

    /// `address` as it is to be kept and compared, or nil when it is not an address
    /// (MAIL-ENGINE 10.8, "What an address may contain"). An address is `local@domain` with
    /// exactly one `@` (U+0040), at most 320 bytes, and:
    ///
    /// - **the local part** holds only ASCII letters and digits, the characters
    ///   ``!#$%&'*+-/=?^_`{|}~.``, and, outside ASCII, letters, combining marks and digits. No
    ///   quotation mark, bracket, parenthesis, backslash, colon, semicolon, comma or space: a
    ///   quoted local part is legal and is not read. It is **unchanged by compatibility
    ///   folding** (NFKC), so a full-width `＠`, a small `﹫`, full-width or mathematical letters
    ///   cannot stand in it. It holds **no default-ignorable character**: a variation selector,
    ///   a grapheme joiner and the Hangul fillers are marks and letters and are still
    ///   refused. It **does not begin with a combining mark**, which would attach to whatever
    ///   a screen draws before it. And **no word of it mixes two of Latin, Cyrillic and
    ///   Greek**, the rule for a name, because the address is what is shown *instead of* a
    ///   suspect name and is the last thing that may deceive.
    /// - **the domain** is held to the same: letters, marks and digits and `-`, `_`, `.`, unchanged
    ///   by NFKC and with nothing invisible in it, so that the system's conversion cannot join
    ///   two domains that differ to the eye (it drops what is invisible and maps a full-width
    ///   letter to the plain one). It is then lower-cased, turned to its `xn--` form by the
    ///   system when it is not ASCII, and held to letters, digits, hyphen and underscore in at
    ///   least two labels of 1 to 63 bytes.
    ///
    /// **An address is never cleaned or repaired into one:** one that fails any of this is not
    /// an address, and what it was in is unreadable. The local part is returned as written, its
    /// case included; compare two addresses through `MailAddress.key`.
    static func normalized(_ address: String) -> String? {
        guard !address.isEmpty, address.utf8.count <= maxAddressBytes else { return nil }

        let scalars = Array(address.unicodeScalars)
        var at: Int?
        for (offset, scalar) in scalars.enumerated() where scalar == "@" {
            if at != nil { return nil }                // one "@"
            at = offset
        }
        guard let at, at > 0, at < scalars.count - 1 else { return nil }   // both sides non-empty

        let local = scalars[..<at]
        guard isAllowedLocalPart(local) else { return nil }
        guard let host = asciiHost(scalars[(at + 1)...]) else { return nil }
        return String(String.UnicodeScalarView(local)) + "@" + host
    }

    /// The name to show, or nil to show the address instead (MAIL-ENGINE 10.8).
    ///
    /// A name is replaced by the address when it is empty, when it contains `@`, `<` or `>`
    /// (or a character that is those under compatibility folding, such as the full-width `＠`),
    /// when it reads as a web address, or when **a word of it mixes look-alike scripts**: letters
    /// of two of Latin, Cyrillic and Greek, the three whose letters pass for one another
    /// (`Pаypal` with a Cyrillic `а`). Nothing else is flagged: a Japanese name is Han and kana
    /// in one word and is a name, and "Tinkoff Банк" is two words, each in its own script.
    /// What it does not catch is a word spelt wholly in look-alike letters; the address beside
    /// the name of anyone he has not written to is what stands in for that.
    ///
    /// Otherwise the name, cleaned (`cleaned`), its whitespace made single spaces.
    ///
    /// **This is not cheap** — a compatibility fold, the system's link detector, and a regular
    /// expression per word — and it is asked *once*, when a message is stored; what is stored
    /// is the answer, and no list row asks again.
    ///
    /// `address` is in the signature the design gives, and no rule here needs it yet; the name
    /// is judged on its own, which is what makes a name that merely *contains* a different
    /// address unmistakable.
    static func displayName(_ name: String?, address: String) -> String? {
        guard let name else { return nil }
        let shown = singleSpaced(cleaned(name))
        guard !shown.isEmpty, shown.unicodeScalars.count <= maxNameCharacters else { return nil }

        // Judge what it looks like once folded, as well as what it is: a full-width `＠` reads
        // as an address whatever its code point is.
        let folded = shown.precomposedStringWithCompatibilityMapping
        for text in [shown, folded] where text.unicodeScalars.contains(where: isAddressPunctuation) {
            return nil
        }
        if readsAsURL(folded) { return nil }
        if MailScripts.hasWordMixingLookAlikeScripts(shown) { return nil }
        return shown
    }

    /// `text` with what cannot be seen removed (MAIL-ENGINE 10.8; `MailHiddenCharacters` says
    /// exactly what, and what is kept because it is doing its work). Emoji stay, whole. Applied
    /// to names, subjects, snippets, file names and link text when they are stored, so no
    /// screen has to remember to; applying it twice changes nothing.
    static func cleaned(_ text: String) -> String {
        MailHiddenCharacters.removing(from: text)
    }

    // MARK: - Pieces

    private static func isAddressPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "@" || scalar == "<" || scalar == ">"
    }

    /// Letters (any script), combining marks and decimal digits: what an address may hold
    /// outside ASCII.
    private static func isLetterMarkOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber:
            return true
        default:
            return false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// The ASCII an unquoted local part may hold.
    private static func isAllowedASCIILocal(_ value: UInt32) -> Bool {
        switch value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:          // digits, letters
            return true
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F, 0x3D, 0x3F, 0x5E...0x60, 0x7B...0x7E:
            // ! # $ % & '   * +   - . /   = ?   ^ _ `   { | } ~
            return true
        default:
            return false
        }
    }

    private static func isAllowedLocalPart(_ local: ArraySlice<Unicode.Scalar>) -> Bool {
        var hasNonASCII = false
        for scalar in local {
            if scalar.value < 0x80 {
                guard isAllowedASCIILocal(scalar.value) else { return false }
            } else {
                hasNonASCII = true
                guard isLetterMarkOrDigit(scalar), !scalar.properties.isDefaultIgnorableCodePoint
                else { return false }
            }
        }
        // Plain ASCII is Latin and stable under folding: nothing more to ask of it.
        guard hasNonASCII else { return true }
        guard let first = local.first, !isMark(first) else { return false }
        let text = String(String.UnicodeScalarView(local))
        guard isStableUnderFolding(text) else { return false }
        return !MailScripts.hasWordMixingLookAlikeScripts(text)
    }

    /// The host of a domain as ASCII: lower case, every label 1 to 63 bytes of letters, digits,
    /// hyphen and underscore, at least two labels, 253 bytes at most; nil if the domain holds
    /// anything it may not (see `normalized`).
    private static func asciiHost(_ domain: ArraySlice<Unicode.Scalar>) -> String? {
        var hasNonASCII = false
        for scalar in domain {
            if scalar.value < 0x80 {
                switch scalar.value {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: continue
                default: return nil
                }
            }
            hasNonASCII = true
            guard isLetterMarkOrDigit(scalar), !scalar.properties.isDefaultIgnorableCodePoint
            else { return nil }
        }
        var host = String(String.UnicodeScalarView(domain))
        if hasNonASCII {
            guard isStableUnderFolding(host) else { return nil }
            // `URLComponents` is the system's IDNA: it gives the `xn--` form, and gives back
            // what it cannot convert unchanged, which the check below then refuses.
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            guard let encoded = components.encodedHost else { return nil }
            host = encoded
        }
        host = host.lowercased()
        guard host.utf8.count <= 253 else { return nil }
        var labels = 0
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63 else { return nil }
            for byte in label.utf8 {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                     UInt8(ascii: "-"), UInt8(ascii: "_"):
                    continue
                default:
                    return nil
                }
            }
            labels += 1
        }
        return labels >= 2 ? host : nil
    }

    /// Whether compatibility folding (NFKC) leaves `text` exactly as it is, scalar for scalar.
    /// Swift's `==` on strings is canonical equivalence, under which a letter and a separate
    /// accent *equal* the one precomposed letter; the question here is whether they are the
    /// same scalars, so the scalars are compared.
    private static func isStableUnderFolding(_ text: String) -> Bool {
        text.precomposedStringWithCompatibilityMapping.unicodeScalars.elementsEqual(text.unicodeScalars)
    }

    /// `text` with every run of whitespace made one space and its ends trimmed.
    static func singleSpaced(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Reads as a URL

    /// `NSDataDetector` is an `NSRegularExpression`, which Apple documents as safe to use from
    /// several threads, and building one costs milliseconds, so there is one. Nil if the system
    /// could not make it, in which case only an explicit scheme is recognised.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Whether `text` — already folded — says a web address: a scheme and `://`, or something
    /// the system's link detector takes for a link or an address ("paypal.com", "www.x.org").
    ///
    /// The detector is a heuristic: it misses a top-level domain it does not know and, as seen,
    /// some upper-case ones, so the text is lower-cased first. It is one of three checks on a
    /// name, and the UI shows the address beside any name it has not seen him write to, so a
    /// name that gets past it is not the only thing standing between a sender and a person.
    private static func readsAsURL(_ text: String) -> Bool {
        if text.contains("://") { return true }
        guard let detector = linkDetector else { return false }
        let lowered = text.lowercased()
        let range = NSRange(location: 0, length: (lowered as NSString).length)
        return detector.firstMatch(in: lowered, options: [], range: range) != nil
    }
}

// MARK: - Scripts

/// Which script a word's letters are in, for the one question asked of it: does a word mix
/// letters of two of **Latin, Cyrillic and Greek** (MAIL-ENGINE 10.8)?
///
/// Those are the three scripts whose letters pass for one another, and the spoof is a word that
/// looks like one he knows and is not spelt with its letters: `Pаypal` with a Cyrillic `а`, or
/// `bоris` in an address. The test is per **word**, a run of letters, marks and digits; a Japanese
/// name is Han and kana in one word and is not flagged, "Tinkoff Банк" is two words and is not.
///
/// The scripts come from `NSRegularExpression`, whose `\p{Script=…}` is a public API over the
/// system's own Unicode data. There is no table of ours. Swift's standard library does not
/// expose a scalar's script, and ICU's own spoof checker is private on Apple's platforms.
enum MailScripts {

    /// Latin, Cyrillic, Greek, compiled once. Nil if the system could not compile one — which
    /// `MailCleaningTests` asserts it can. A reader that finds it nil answers as if every word
    /// mixed: the name is not shown and the address is not read, the safe direction.
    private static let patterns: [NSRegularExpression]? = {
        var compiled: [NSRegularExpression] = []
        for pattern in [#"\p{Script=Latin}"#, #"\p{Script=Cyrillic}"#, #"\p{Script=Greek}"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            compiled.append(expression)
        }
        return compiled
    }()

    static var patternsCompile: Bool { patterns != nil }

    /// Whether any word of `text` has letters of two of the three scripts.
    static func hasWordMixingLookAlikeScripts(_ text: String) -> Bool {
        // A word with nothing outside ASCII is Latin and cannot mix; most text is that.
        guard text.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { return false }
        guard let patterns else { return true }

        var word = String.UnicodeScalarView()
        var wordHasNonASCII = false
        func mixes() -> Bool {
            defer { word = String.UnicodeScalarView(); wordHasNonASCII = false }
            guard wordHasNonASCII else { return false }
            let string = String(word)
            let range = NSRange(location: 0, length: string.utf16.count)
            var scripts = 0
            for expression in patterns where expression.firstMatch(in: string, options: [], range: range) != nil {
                scripts += 1
            }
            return scripts > 1
        }
        for scalar in text.unicodeScalars {
            if isWordCharacter(scalar) {
                word.append(scalar)
                if scalar.value >= 0x80 { wordHasNonASCII = true }
            } else if mixes() {
                return true
            }
        }
        return mixes()
    }

    /// A letter, a combining mark or a decimal digit.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber:
            return true
        default:
            return false
        }
    }
}

// MARK: - Addresses

/// One mailbox as a header wrote it: the name the sender gave, and the address.
///
/// The two are never merged. A name is whatever the sender typed — it may be an address of its
/// own, or a person's name over an address that is not theirs — and `MailAddressRules
/// .displayName` is what decides whether it may be shown.
///
/// **Not a sender.** A mailbox that was read out of a list is one of whatever the list held.
/// Who a message is from is `MessageHeaders.sender`, and nothing else takes an address out of
/// `From` (MAIL-ENGINE 10.8).
struct MailAddress: Hashable, Sendable {
    /// Decoded (RFC 2047) and cleaned (`MailAddressRules.cleaned`); nil when the sender wrote
    /// none. Not yet judged: ask `MailAddressRules.displayName`.
    var name: String?
    /// `local@domain`, valid (`MailAddressRules.normalized`), the domain in its ASCII form. A
    /// local part may honestly hold right-to-left letters, so a screen draws an address in a
    /// left-to-right isolate of its own, or its two halves can change places.
    var address: String

    /// What two addresses are compared by: the whole address in lower case. Two addresses that
    /// differ in any visible way have different keys; one that differs in an invisible way was
    /// never accepted.
    var key: String { address.lowercased() }

    /// The domain, after the one `@`.
    var domain: String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return String(address[address.index(after: at)...]).lowercased()
    }
}

/// What an address header says, in order, nothing dropped (MAIL-ENGINE invariant 1: what could
/// not be read is *unknown*, never empty).
struct MailAddressList: Equatable, Sendable {

    enum Item: Equatable, Sendable {
        case mailbox(MailAddress)
        /// A group the sender named and put nobody in: "undisclosed-recipients:;". The name is
        /// decoded and cleaned.
        case emptyGroup(String)
        /// Something was written that names no usable address — a name alone, an address with
        /// no domain, text in brackets that never closed, two bare addresses with no comma
        /// between them. The text, cleaned and cut short; never to be shown as anyone's address
        /// or put where a sender goes.
        case unreadable(String)
    }

    var items: [Item]
    /// False when the text this was read from was cut short, or this reader's own limit was
    /// reached; the last piece, which may have been cut in half, is then left out. A list that
    /// is not complete is not a statement that nobody else was on it.
    var isComplete: Bool
    /// Whether the text used group syntax (`Name: a@x.com;`), whether or not the group had
    /// anyone in it. A group's members are in `items` like any other mailbox.
    var hasGroup: Bool = false

    /// Every mailbox, in order, those of groups among them.
    var mailboxes: [MailAddress] {
        items.compactMap { if case .mailbox(let mailbox) = $0 { return mailbox } else { return nil } }
    }

    /// Whether anything was written that could not be read as an address.
    var hasUnreadable: Bool {
        items.contains { if case .unreadable = $0 { return true } else { return false } }
    }

    static let empty = MailAddressList(items: [], isComplete: true)

    /// The most input one reading takes, in characters. The header limits (`MessageHeaders`)
    /// are far lower; this is the bound for text that does not come through them, such as a
    /// pasted list. What is past it is not read and the list says so.
    static let maxInputCharacters = 262_144

    /// The longest text kept of an `unreadable` piece.
    static let maxUnreadableCharacters = 200

    /// Reads `text` as an RFC 5322 address list: mailboxes with or without a display name
    /// (`Bob <bob@x.com>`, `"Doe, John" <j@x.com>`, `bob@x.com (Bob)`, `bob@x.com`), groups
    /// (`Team: a@x.com, b@y.com;`), comments (nested), quoted strings, and RFC 2047 encoded
    /// words in names. Separated by commas, or semicolons outside a group.
    ///
    /// Tolerant where mail is, strict where it matters:
    /// - **What is in quotes is a name, always** (10.8). With angle brackets the address is what
    ///   is inside them and everything before is the name. Without, the address is the one
    ///   *unquoted* word that is an address; a quoted string beside it is its name, and a
    ///   quoted string alone is no mailbox. Two bare addresses with no comma between them are
    ///   not two mailboxes but one item that cannot be read.
    /// - A quote or bracket that never closes is ordinary text. An address is found only in
    ///   brackets that close, and `Bob <bob@x.com` is therefore not read as bob@x.com.
    /// - Words before an angle bracket are the name, always — even a word that is an address
    ///   (`evil@x.com <real@y.com>` is a name "evil@x.com" over real@y.com, two things kept
    ///   apart, not two mailboxes).
    /// - A name is decoded *after* the list has been split, so nothing an encoded word decodes
    ///   to can add an address or a boundary.
    /// - An address must pass `MailAddressRules.normalized`; one that does not is `unreadable`.
    ///
    /// Time is linear in the length of `text`: every scan looks ahead at most once past what it
    /// then consumes.
    ///
    /// - Parameter isComplete: false when `text` was itself cut (a header value over its
    ///   limit): the last piece is dropped, since it may be a half address.
    static func parse(_ text: String, isComplete: Bool = true) -> MailAddressList {
        var scalars = Array(text.unicodeScalars)
        var complete = isComplete
        if scalars.count > maxInputCharacters {
            scalars.removeSubrange(maxInputCharacters...)
            complete = false
        }
        var reader = Reader(scalars)
        reader.run()
        var items = reader.items
        if !complete, !items.isEmpty { items.removeLast() }
        return MailAddressList(items: items, isComplete: complete, hasGroup: reader.sawGroup)
    }

    // MARK: The reader

    /// A plain word or a quoted string, as the list wrote it.
    private struct Word {
        var text: String
        var quoted: Bool
    }

    private struct Reader {
        let s: [Unicode.Scalar]
        var items: [Item] = []
        private(set) var sawGroup = false

        /// For each "(" the index of the ")" that closes it, or -1: the comment's end, found
        /// once for the whole text so that a "(" that never closes is known without looking.
        private var closeOfComment: [Int]
        private var hasParens = false
        /// Set once a scan for a closing quote or bracket has run to the end and found none.
        /// None can be found for any later opener either, so none looks again.
        private var noMoreQuotes = false
        private var noMoreAngleCloses = false

        /// The mailbox being read.
        private var words: [Word] = []
        private var comments: [String] = []
        private var angle: String?
        private var unquotedWordsWithAt = 0        // of `words`, those not quoted that hold an "@"
        private var group: String?                 // inside a group of this name
        private var groupMembers = 0

        init(_ scalars: [Unicode.Scalar]) {
            s = scalars
            hasParens = scalars.contains("(")
            closeOfComment = hasParens ? Array(repeating: -1, count: scalars.count) : []
            var open: [Int] = []
            var i = 0
            while hasParens, i < scalars.count {
                switch scalars[i] {
                case "\\": i += 1                          // the next scalar is not a paren
                case "(": open.append(i)
                case ")": if let start = open.popLast() { closeOfComment[start] = i }
                default: break
                }
                i += 1
            }
        }

        mutating func run() {
            var i = 0
            let n = s.count
            while i < n {
                let c = s[i]
                if isSpace(c) { i += 1; continue }
                switch c {
                case ",":
                    flush(); i += 1
                case ";":
                    flush()
                    if group != nil { endGroup() }
                    i += 1
                case "(" where commentClose(at: i) >= 0:
                    let close = commentClose(at: i)
                    comments.append(commentText(from: i + 1, to: close))
                    i = close + 1
                case "\"" where !noMoreQuotes:
                    if let end = closingQuote(after: i) {
                        pushWord(quotedText(from: i + 1, to: end), quoted: true)
                        i = end + 1
                    } else {
                        noMoreQuotes = true
                        i = atom(from: i)
                    }
                case "<" where !noMoreAngleCloses:
                    if let end = closingAngle(after: i) {
                        pushAngle(String(String.UnicodeScalarView(s[(i + 1)..<end])))
                        i = end + 1
                    } else {
                        noMoreAngleCloses = true
                        i = atom(from: i)
                    }
                case ":" where startsGroup():
                    startGroup(); i += 1
                default:
                    i = atom(from: i)
                }
            }
            flush()
            if group != nil { endGroup() }
        }

        // MARK: Tokens

        private func commentClose(at i: Int) -> Int { hasParens ? closeOfComment[i] : -1 }

        private func isSpace(_ c: Unicode.Scalar) -> Bool {
            c.properties.isWhitespace || c.properties.generalCategory == .control
        }

        /// Characters that end a plain word. `>` and `)` do not: stray, they are text.
        private func endsAtom(_ c: Unicode.Scalar) -> Bool {
            switch c {
            case ",", ";", "\"", "(", "<", ":": return true
            default: return isSpace(c)
            }
        }

        /// Reads a plain word starting at `start`, which is always taken, so that a character
        /// that would end a word but is being treated as text (a quote that never closes) makes
        /// progress. Returns where the next token begins.
        private mutating func atom(from start: Int) -> Int {
            var j = start + 1
            while j < s.count, !endsAtom(s[j]) { j += 1 }
            pushWord(String(String.UnicodeScalarView(s[start..<j])), quoted: false)
            return j
        }

        /// The closing quote of the string opened at `open`: the next quote not escaped by a
        /// backslash.
        private func closingQuote(after open: Int) -> Int? {
            var j = open + 1
            while j < s.count {
                if s[j] == "\\" { j += 2; continue }
                if s[j] == "\"" { return j }
                j += 1
            }
            return nil
        }

        private func closingAngle(after open: Int) -> Int? {
            var j = open + 1
            while j < s.count { if s[j] == ">" { return j }; j += 1 }
            return nil
        }

        /// A quoted string's text with its backslash escapes resolved.
        private func quotedText(from start: Int, to end: Int) -> String {
            var out = String.UnicodeScalarView()
            var j = start
            while j < end {
                if s[j] == "\\", j + 1 < end { j += 1 }
                out.append(s[j])
                j += 1
            }
            return String(out)
        }

        /// A comment's text: nested comments kept, with their parentheses, escapes resolved.
        private func commentText(from start: Int, to end: Int) -> String {
            quotedText(from: start, to: end)
        }

        // MARK: What a token does to the mailbox being read

        private mutating func pushWord(_ text: String, quoted: Bool) {
            // Words after a closed angle bracket belong to the next mailbox.
            if angle != nil { flush() }
            words.append(Word(text: text, quoted: quoted))
            if !quoted, text.contains("@") { unquotedWordsWithAt += 1 }
        }

        private mutating func pushAngle(_ content: String) {
            if angle != nil { flush() }
            angle = content
        }

        /// A colon starts a group when what precedes it is a name with no address in it, and
        /// no group is open. Anywhere else a colon is text. A quoted name may hold an `@`: it is
        /// a name, and `"ceo@victim.example": a@evil.example;` is a group of one.
        private func startsGroup() -> Bool {
            group == nil && angle == nil && !words.isEmpty && unquotedWordsWithAt == 0
        }

        private mutating func startGroup() {
            group = name(from: words, comments: comments) ?? ""
            sawGroup = true
            words = []
            comments = []
            unquotedWordsWithAt = 0
            groupMembers = 0
        }

        private mutating func endGroup() {
            if groupMembers == 0, let name = group { items.append(.emptyGroup(name)) }
            group = nil
            groupMembers = 0
        }

        // MARK: Finishing a mailbox

        private mutating func flush() {
            defer { words = []; comments = []; angle = nil; unquotedWordsWithAt = 0 }
            let hadAnything = !words.isEmpty || !comments.isEmpty || angle != nil
            guard hadAnything else { return }

            let wordTexts = words.map(\.text)
            if let angle {
                emit(address: angle, name: name(from: words, comments: comments),
                     unreadableText: (wordTexts + ["<" + angle + ">"]).joined(separator: " "))
                return
            }

            // No brackets. The address is the one *unquoted* word that is an address: a quoted
            // string is a name, whatever it holds, and a quoted string alone is no mailbox.
            // Two such words are not two mailboxes: which is whose cannot be told, and the
            // first is the one a forger chose to put there.
            let candidates = words.indices.filter {
                !words[$0].quoted && MailAddressRules.normalized(words[$0].text) != nil
            }
            switch candidates.count {
            case 1:
                let at = candidates[0]
                var rest = words
                rest.remove(at: at)
                emit(address: words[at].text, name: name(from: rest, comments: comments),
                     unreadableText: wordTexts.joined(separator: " "))
            default:
                let text = (words.isEmpty ? comments : wordTexts).joined(separator: " ")
                if !text.isEmpty { addUnreadable(text) }
            }
        }

        private mutating func emit(address raw: String, name: String?, unreadableText: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let address = MailAddressRules.normalized(trimmed) {
                items.append(.mailbox(MailAddress(name: name, address: address)))
                if group != nil { groupMembers += 1 }
            } else {
                addUnreadable(unreadableText)
            }
        }

        private mutating func addUnreadable(_ text: String) {
            let cleaned = MailHeaderText.display(MailHeaderText.decodeEncodedWords(text))
            let cut = String(String.UnicodeScalarView(
                cleaned.unicodeScalars.prefix(MailAddressList.maxUnreadableCharacters)))
            // Text that is nothing once cleaned — spaces, empty quotes, what cannot be seen —
            // is not something that was written.
            guard !cut.isEmpty else { return }
            items.append(.unreadable(cut))
            if group != nil { groupMembers += 1 }
        }

        /// The name a mailbox gives: its words, else its comments, decoded and cleaned and
        /// with single spaces; nil if nothing is left.
        private func name(from words: [Word], comments: [String]) -> String? {
            let source = words.isEmpty ? comments : words.map(\.text)
            guard !source.isEmpty else { return nil }
            let text = MailAddressRules.singleSpaced(MailHeaderText.display(
                MailHeaderText.decodeEncodedWords(source.joined(separator: " "))))
            return text.isEmpty ? nil : text
        }
    }
}

// MARK: - Header text

/// Reading the text of a header: unfolding, RFC 2047 encoded words, and the cleaning every
/// stored name and subject gets.
enum MailHeaderText {

    /// A header value as a person reads it: unfolded, its encoded words decoded, hidden
    /// characters removed, control characters made spaces or removed, trimmed. For a subject.
    ///
    /// The value is decoded whether or not Gmail has already done it: an encoded word is
    /// decoded, plain text is left alone. (Whether Gmail's `payload.headers` arrive decoded is
    /// not known until the probe; only text that *is* an encoded word is touched, so either
    /// way the same words come out. A subject whose decoded text is itself the literal
    /// "=?utf-8?B?…?=" is decoded a second time, which nothing here can tell from the first.)
    static func unstructured(_ value: String) -> String {
        display(decodeEncodedWords(unfold(value)))
    }

    /// RFC 5322 unfolding: a line break followed by whitespace is removed, keeping the
    /// whitespace; any other CR or LF is a space. Never leaves a line break in the text.
    static func unfold(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else { return value }
        let scalars = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c == "\r" || c == "\n" else { out.append(c); i += 1; continue }
            // One line break: CRLF, or a lone CR or LF.
            var next = i + 1
            if c == "\r", next < scalars.count, scalars[next] == "\n" { next += 1 }
            if next < scalars.count, scalars[next] == " " || scalars[next] == "\t" {
                i = next                         // the whitespace stays
            } else {
                out.append(" ")
                i = next
            }
        }
        return String(out)
    }

    /// `text` ready to show: tabs and other whitespace-like controls and the Unicode line and
    /// paragraph separators made spaces, every other control character removed, what cannot be
    /// seen removed (`MailAddressRules.cleaned`), outer whitespace trimmed. Runs of spaces
    /// inside are kept as they are.
    static func display(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        let needsWork = scalars.contains { needsDisplayWork($0) }
        if needsWork {
            var mapped: [Unicode.Scalar] = []
            mapped.reserveCapacity(scalars.count)
            for scalar in scalars {
                switch scalar.properties.generalCategory {
                case .control:
                    if scalar.properties.isWhitespace { mapped.append(" ") }
                case .lineSeparator, .paragraphSeparator:
                    mapped.append(" ")
                default:
                    mapped.append(scalar)
                }
            }
            // The controls are gone before the invisible characters are judged, so that a
            // selector is kept or not by what is really before it.
            let cleaned = MailHiddenCharacters.removing(from: String(String.UnicodeScalarView(mapped)))
            scalars = Array(cleaned.unicodeScalars)
        }
        var start = 0
        var end = scalars.count
        while start < end, scalars[start].properties.isWhitespace { start += 1 }
        while end > start, scalars[end - 1].properties.isWhitespace { end -= 1 }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[start..<end])
        return String(out)
    }

    private static func needsDisplayWork(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    // MARK: - RFC 2047

    /// The longest encoded word looked for, in characters. The standard says 75; some mailers
    /// write more. Past this a "word" is text, and no start of one is looked past this far.
    static let maxEncodedWordCharacters = 1_024

    /// `text` with each RFC 2047 encoded word (`=?charset?B?…?=`, `=?charset?Q?…?=`) replaced
    /// by what it says. Whitespace between two encoded words is dropped, as the standard asks,
    /// and adjacent words in one charset are decoded together, since a character may have been
    /// split between them. Everything else is left exactly as it was.
    ///
    /// A charset the system does not know — or one whose bytes it cannot read — is not left as
    /// written: the one rule of `MailCharset` applies, UTF-8 if the bytes are valid UTF-8 and
    /// Windows-1252 if not. A word that is not an encoded word at all (base64 that is not
    /// base64, a word with a space in it) is text and stays as it is.
    static func decodeEncodedWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let s = Array(text.unicodeScalars)
        // An array, not a string's scalar view: `append(contentsOf:)` on the view copies the
        // whole string every time (measured: a hundred thousand calls took a second), and this
        // appends once per word and once per gap.
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        var pendingSpace: [Unicode.Scalar] = []
        // Adjacent encoded words of one charset, collected until something else comes.
        var run: Run?

        func flushRun() {
            guard let finished = run else { return }
            out.append(contentsOf: finished.decoded().unicodeScalars)
            run = nil
        }

        var i = 0
        while i < s.count {
            if s[i] == "=", i + 1 < s.count, s[i + 1] == "?", let word = encodedWord(in: s, at: i) {
                if let charset = run?.charset {
                    // Whitespace between two encoded words is dropped, whatever their charsets.
                    // Appended in place: a copy of the run per word would be quadratic.
                    if charset == word.charset {
                        run?.append(word)
                    } else {
                        flushRun()
                        run = Run(word)
                    }
                } else {
                    out.append(contentsOf: pendingSpace)
                    run = Run(word)
                }
                pendingSpace = []
                i = word.end
                continue
            }
            if s[i].properties.isWhitespace {
                pendingSpace.append(s[i])
                i += 1
                continue
            }
            flushRun()
            out.append(contentsOf: pendingSpace)
            pendingSpace = []
            out.append(s[i])
            i += 1
        }
        flushRun()
        out.append(contentsOf: pendingSpace)
        return String(String.UnicodeScalarView(out))
    }

    /// One encoded word, read.
    private struct Word {
        let charset: String               // lower case, without a language suffix
        let bytes: [UInt8]
        let end: Int                      // index after the closing "?="
    }

    /// The adjacent encoded words being gathered into one decoding.
    private struct Run {
        let charset: String
        var bytes: [UInt8]
        init(_ word: Word) {
            charset = word.charset
            bytes = word.bytes
        }
        mutating func append(_ word: Word) {
            bytes += word.bytes
        }
        func decoded() -> String {
            MailCharset.text(bytes, charset: charset)
        }
    }

    /// The encoded word starting at `start` (which is "=?"), or nil if what is there is not one.
    private static func encodedWord(in s: [Unicode.Scalar], at start: Int) -> Word? {
        let limit = min(s.count, start + maxEncodedWordCharacters)
        var j = start + 2

        // charset: up to the next "?", no spaces
        let charsetStart = j
        while j < limit, s[j] != "?", !s[j].properties.isWhitespace { j += 1 }
        guard j < limit, s[j] == "?", j > charsetStart else { return nil }
        let rawCharset = String(String.UnicodeScalarView(s[charsetStart..<j]))
        j += 1

        // encoding: one letter, then "?"
        guard j + 1 < limit, s[j + 1] == "?" else { return nil }
        let kind = s[j]
        j += 2

        // text: up to "?=", no spaces
        let textStart = j
        while j < limit, s[j] != "?", !s[j].properties.isWhitespace { j += 1 }
        guard j + 1 < limit, s[j] == "?", s[j + 1] == "=" else { return nil }
        let text = s[textStart..<j]
        let end = j + 2

        guard let charset = MailCharset.canonicalName(rawCharset) else { return nil }
        let bytes: [UInt8]?
        switch kind {
        case "B", "b": bytes = decodeB(text)
        case "Q", "q": bytes = decodeQ(text)
        default: bytes = nil
        }
        guard let bytes else { return nil }
        return Word(charset: charset, bytes: bytes, end: end)
    }

    /// base64 (the "B" encoding): padding is supplied if it is missing, anything that is not in
    /// the alphabet makes the word unreadable.
    private static func decodeB(_ text: ArraySlice<Unicode.Scalar>) -> [UInt8]? {
        var ascii = [UInt8]()
        ascii.reserveCapacity(text.count + 3)
        for scalar in text {
            guard scalar.value < 0x80 else { return nil }
            ascii.append(UInt8(scalar.value))
        }
        while ascii.count % 4 != 0 { ascii.append(UInt8(ascii: "=")) }
        guard let data = Data(base64Encoded: Data(ascii)) else { return nil }
        return [UInt8](data)
    }

    /// The "Q" encoding: `_` is a space, `=XX` a byte, anything else itself. A `=` not followed
    /// by two hex digits is itself.
    private static func decodeQ(_ text: ArraySlice<Unicode.Scalar>) -> [UInt8]? {
        let s = Array(text)
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            let c = s[i]
            guard c.value < 0x80 else { return nil }
            if c == "_" {
                bytes.append(0x20)
            } else if c == "=", i + 2 < s.count, let high = hex(s[i + 1]), let low = hex(s[i + 2]) {
                bytes.append(high << 4 | low)
                i += 2
            } else {
                bytes.append(UInt8(c.value))
            }
            i += 1
        }
        return bytes
    }

    private static func hex(_ c: Unicode.Scalar) -> UInt8? {
        switch c.value {
        case 0x30...0x39: return UInt8(c.value - 0x30)
        case 0x41...0x46: return UInt8(c.value - 0x41 + 10)
        case 0x61...0x66: return UInt8(c.value - 0x61 + 10)
        default: return nil
        }
    }
}

// MARK: - Charsets

/// Bytes and a charset name to text: the one rule, for an encoded word in a header and for a
/// body alike (MAIL-ENGINE 5.6).
///
/// A charset the system knows is used. **One it does not know is not an error and is not left as
/// written:** the bytes are read as UTF-8 if they are valid UTF-8, and as Windows-1252
/// otherwise, a byte Windows-1252 leaves undefined becoming U+FFFD. The label that turns up in
/// real mail is `unknown-8bit`, on text that is one of those two, and "Café" is better than
/// `=?unknown-8bit?Q?Caf=E9?=`. The same rule answers a known charset whose bytes it cannot read
/// (`us-ascii` on a Latin-1 message, which is also seen); declared UTF-8 with invalid bytes is
/// read as UTF-8, each bad byte U+FFFD.
///
/// Whatever comes out is a name or a subject and is cleaned (`MailAddressRules.cleaned`) by the
/// caller as any other text is.
enum MailCharset {

    /// The charset name as it will be compared and looked up: lower case, without an RFC 2231
    /// language suffix. Nil if it is not a name at all (empty, or longer than 64 bytes).
    static func canonicalName(_ name: String) -> String? {
        var base = name
        if let star = base.firstIndex(of: "*") { base = String(base[..<star]) }
        base = base.lowercased()
        guard !base.isEmpty, base.utf8.count <= 64 else { return nil }
        return base == "utf8" ? "utf-8" : base
    }

    /// The system's encoding for an IANA charset name, or nil if it knows none.
    static func encoding(named name: String) -> String.Encoding? {
        guard let base = canonicalName(name) else { return nil }
        if base == "utf-8" { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(base as CFString)
        guard cf != CFStringEncoding(kCFStringEncodingInvalidId) else { return nil }
        let raw = CFStringConvertEncodingToNSStringEncoding(cf)
        guard raw != 0, raw != UInt(kCFStringEncodingInvalidId) else { return nil }
        return String.Encoding(rawValue: raw)
    }

    /// `bytes` as text in `charset` (nil: none declared), by the rule above.
    static func text(_ bytes: [UInt8], charset: String?) -> String {
        if let charset, let encoding = encoding(named: charset) {
            if encoding == .utf8 { return String(decoding: bytes, as: UTF8.self) }
            if let text = String(data: Data(bytes), encoding: encoding) { return text }
        }
        return unknownCharsetText(bytes)
    }

    /// UTF-8 if the bytes are valid UTF-8, else Windows-1252 with U+FFFD for what it leaves
    /// undefined.
    static func unknownCharsetText(_ bytes: [UInt8]) -> String {
        if let text = String(data: Data(bytes), encoding: .utf8) { return text }
        if let text = String(data: Data(bytes), encoding: .windowsCP1252) { return text }
        // Some byte is undefined in Windows-1252 (the system gives nothing for the whole): ask
        // of each byte alone, and mark the ones it cannot.
        // An array: appending to a string's scalar view is not safe to do in a long loop.
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte < 0x80 {
                out.append(Unicode.Scalar(byte))
            } else if let one = String(data: Data([byte]), encoding: .windowsCP1252) {
                out.append(contentsOf: one.unicodeScalars)
            } else {
                out.append("\u{FFFD}")
            }
        }
        return String(String.UnicodeScalarView(out))
    }
}

#endif
