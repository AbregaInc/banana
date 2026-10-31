import XCTest

/// Every reader of text a stranger wrote answers for every input, and does it in time
/// proportional to the input's length (MAIL-ENGINE 17.5, invariants 1 and 21).
///
/// A message's headers and addresses are written by whoever sent it. A reader that took a
/// quadratic path on some input — a quote that is never closed, a comment nested to the depth of
/// the whole header, ten thousand encoded words — would hang the sync on one message, and a
/// message that hangs the sync is a message that is never read.
///
/// **How the time is judged.** No test here asserts a number of seconds; a shared Simulator's
/// clock proves nothing. Each input family is built at two sizes, one eight times the other, and
/// each reader runs on both. What is asserted is the *ratio* of the two times, which for
/// linear work is about 8 and for quadratic work about 64, against a limit of 24: three times
/// the linear figure, well short of the quadratic one. Each time is the fastest of several
/// runs, and the smaller is not allowed to be less than a fifth of a millisecond, so that work
/// too small to time is not compared against noise. A round over the limit is measured again
/// (up to three rounds, the least ratio counts), so that a busy machine does not fail what
/// is linear while what is quadratic fails every round. The ratios are printed (`hostile-ratio`).
///
/// Each family also asserts that what came back is *defined*: every mailbox is a valid address
/// with a clean name, nothing is longer than its limit, and nothing is a line break.
final class MailHostileInputTests: XCTestCase {

    private static let small = 8_000
    private static let large = 64_000                  // eight times
    private static let allowedRatio = 24.0
    private static let floor = 0.0002                  // seconds

    // MARK: - The measuring

    private func fastest(_ repeats: Int = 5, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<repeats {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }
        return max(best, Self.floor)
    }

    /// Builds `make` at both sizes and times `run` on each. A round whose ratio is over the limit
    /// is measured again, up to three times, and the least ratio counts: a machine that was busy
    /// for one round does not fail the test, and work that is quadratic fails every round.
    private func measure(make: (Int) -> String, run: (String) -> Void) -> (ratio: Double, small: Double, large: Double, rounds: Int) {
        let smallInput = make(Self.small)
        let largeInput = make(Self.large)
        run(smallInput)                                   // statics, caches
        var ratios: [Double] = []
        var small = 0.0
        var large = 0.0
        for _ in 0..<3 {
            small = fastest { run(smallInput) }
            large = fastest { run(largeInput) }
            ratios.append(large / small)
            if large / small < Self.allowedRatio { break }
        }
        return (ratios.min() ?? .infinity, small, large, ratios.count)
    }

    private func assertLinear(_ name: String, make: (Int) -> String, run: (String) -> Void,
                              file: StaticString = #filePath, line: UInt = #line) {
        let result = measure(make: make, run: run)
        print(String(format: "hostile-ratio %@ small=%.5fs large=%.5fs ratio=%.1f rounds=%d", name, result.small,
                     result.large, result.ratio, result.rounds))
        XCTAssertLessThan(result.ratio, Self.allowedRatio,
                          "\(name): eight times the input took \(result.ratio) times as long; linear is about 8",
                          file: file, line: line)
    }

    /// The measure has to be able to fail. Work that is quadratic — here, every byte compared with
    /// every other — shows a ratio far over the limit in every round, and linear work does not.
    func testTheRatioTestCatchesQuadraticWorkAndPassesLinearWork() {
        let quadratic = measure(make: { String(repeating: "a", count: $0 / 32) }, run: { input in
            let bytes = Array(input.utf8)
            var sum = 0
            for i in 0..<bytes.count { for j in 0..<bytes.count { sum &+= Int(bytes[i] ^ bytes[j]) } }
            XCTAssertEqual(sum, 0)
        })
        XCTAssertGreaterThan(quadratic.ratio, Self.allowedRatio, "quadratic work is not mistaken for linear")
        XCTAssertEqual(quadratic.rounds, 3, "and is measured the three times before it is failed")

        let linear = measure(make: { String(repeating: "a", count: $0) }, run: { input in
            XCTAssertEqual(input.utf8.reduce(0) { $0 &+ Int($1) }, 97 * input.utf8.count)
        })
        XCTAssertLessThan(linear.ratio, Self.allowedRatio)
    }

    // MARK: - What a reading must look like

    private func isClean(_ text: String) -> Bool {
        !text.unicodeScalars.contains { MailHiddenCharacters.isDirectionControl($0) || [0x200B, 0x2060, 0xFEFF].contains($0.value)
            || $0.properties.generalCategory == .control
            || $0.properties.generalCategory == .lineSeparator || $0.properties.generalCategory == .paragraphSeparator }
    }

    private func wellFormed(_ list: MailAddressList) -> Bool {
        for item in list.items {
            switch item {
            case .mailbox(let mailbox):
                guard MailAddressRules.isValid(mailbox.address),
                      MailAddressRules.normalized(mailbox.address) == mailbox.address,
                      mailbox.name.map(isClean) ?? true, mailbox.name?.isEmpty != true
                else { return false }
            case .emptyGroup(let name):
                guard isClean(name) else { return false }
            case .unreadable(let text):
                guard !text.isEmpty, text.unicodeScalars.count <= MailAddressList.maxUnreadableCharacters,
                      isClean(text)
                else { return false }
            }
        }
        return true
    }

    private func repeated(_ unit: String, to size: Int) -> String {
        String(repeating: unit, count: max(1, size / unit.count))
    }

    // MARK: - The address reader

    private var addressFamilies: [(String, (Int) -> String)] {
        [
            ("unbalanced quotes", { self.repeated("\"", to: $0) }),
            ("quotes before words", { self.repeated("\"ab ", to: $0) }),
            ("escaped quotes", { self.repeated("\\\"", to: $0) }),
            ("backslashes", { self.repeated("\\", to: $0) }),
            ("unbalanced angle brackets", { self.repeated("<", to: $0) }),
            ("angle openers with addresses", { self.repeated("<a@b.co", to: $0) }),
            ("angle openers and commas", { self.repeated("<a@b.co, ", to: $0) }),
            ("closing angle brackets", { self.repeated(">", to: $0) }),
            ("angle brackets in brackets", { self.repeated("<<a@b.co>>", to: $0) }),
            ("nested comments", { String(repeating: "(", count: $0 / 2) + String(repeating: ")", count: $0 / 2) }),
            ("comments that never close", { self.repeated("(", to: $0) }),
            ("closing parens", { self.repeated(")", to: $0) }),
            ("comments then an address", { self.repeated("(a) ", to: $0) + "<a@b.co>" }),
            ("openers then an address", { self.repeated("( ", to: $0) + "<a@b.co>" }),
            ("groups opened", { self.repeated("a:", to: $0) }),
            ("groups with members", { self.repeated("g: a@b.co, c@d.co; ", to: $0) }),
            ("colons", { self.repeated(":", to: $0) }),
            ("words then colons", { self.repeated("word ", to: $0 / 2) + self.repeated("x@y.co :", to: $0 / 2) }),
            ("semicolons", { self.repeated(";", to: $0) }),
            ("commas", { self.repeated(",", to: $0) }),
            ("many addresses", { self.repeated("<a@b.co>,", to: $0) }),
            ("addresses with no separator", { self.repeated("a@b.co ", to: $0) }),
            ("words with an @ and no dot", { self.repeated("a@b ", to: $0) }),
            ("names and no address", { self.repeated("Name ", to: $0) }),
            ("names that are addresses", { self.repeated("\"x@y.co\" <z@w.co>, ", to: $0) }),
            ("encoded words", { self.repeated("=?utf-8?B?SGk=?= ", to: $0) + "<a@b.co>" }),
            ("encoded word openers", { self.repeated("=?", to: $0) }),
            ("encoded word charsets", { self.repeated("=?utf-8?Q?", to: $0) }),
            ("encoded word that never ends", { "=?utf-8?B?" + String(repeating: "A", count: $0) }),
            ("empty encoded words", { self.repeated("=?a?Q?x?=", to: $0) }),
            ("encoded words in an unknown charset", { self.repeated("=?x-unknown?B?SGk=?= ", to: $0) }),
            ("encoded words in two charsets", { self.repeated("=?utf-8?Q?a?= =?iso-8859-1?Q?=E9?= ", to: $0) }),
            ("invisible characters", { self.repeated("a\u{200B}\u{202E}", to: $0) + " <a@b.co>" }),
            ("control characters", { self.repeated("\u{0}\r\n\t", to: $0) }),
            ("right to left text", { self.repeated("\u{202E}שלום ", to: $0) + "<a@b.co>" }),
            ("one very long word", { String(repeating: "x", count: $0) }),
            ("one very long address", { "<" + String(repeating: "a", count: $0) + "@b.co>" }),
            ("one very long domain", { "<a@" + String(repeating: "b.", count: $0 / 2) + "co>" }),
            ("international domains", { self.repeated("<a@bücher.de>,", to: $0 / 4) }),
            ("quoted names with an at sign", { self.repeated("\"a@b.co\" ", to: $0) }),
            ("quoted names and bare addresses", { self.repeated("\"a@b.co\" c@d.co ", to: $0) }),
            ("quoted group names", { self.repeated("\"a@b.co\": c@d.co; ", to: $0) }),
            ("non-ASCII local parts", { self.repeated("<\u{00FC}ser@example.com>,", to: $0) }),
            ("mixed-script local parts", { self.repeated("<n\u{043E}or@plan.example>,", to: $0) }),
            ("local parts with invisible characters", { self.repeated("<sam\u{FE00}@plan.example>,", to: $0) }),
            ("look-alike at signs", { self.repeated("<a\u{FF20}b@plan.example>,", to: $0) }),
            ("long non-ASCII local part", { "<" + String(repeating: "\u{00E9}", count: $0 / 2) + "@plan.example>" }),
            ("long Cyrillic word", { "<" + String(repeating: "\u{0430}", count: $0 / 2) + "@plan.example>" }),
        ]
    }

    func testTheAddressReaderIsLinearOnEveryHostileShapeAndAlwaysAnswers() {
        for (name, make) in addressFamilies {
            assertLinear("address list: \(name)", make: make, run: { input in
                let list = MailAddressList.parse(input)
                XCTAssertTrue(self.wellFormed(list), name)
            })
        }
    }

    // MARK: - What the readers answer, for a few of them

    func testAHundredThousandCharacterHeaderAnswersWithinTheLimits() {
        let value = String(repeating: "a", count: 100_000)
        let headers = MessageHeaders([("To", value), ("Subject", value), ("From", "Bob <bob@example.com>")])
        XCTAssertEqual(headers.value("To")?.utf8.count, MessageHeaders.maxValueBytes)
        XCTAssertEqual(headers.subject?.utf8.count, MessageHeaders.maxValueBytes)
        XCTAssertFalse(headers.isComplete)
        XCTAssertEqual(headers.sender?.address, "bob@example.com")
        XCTAssertTrue(headers.to.items.isEmpty, "a single cut word is no address, and its last piece is dropped")
        XCTAssertFalse(headers.to.isComplete)
    }

    func testAHeaderOfNothingButUnclosedQuotesAndBracketsAnswersWithNoMailbox() {
        for text in [String(repeating: "\"", count: 100_001), String(repeating: "<", count: 100_000),
                     String(repeating: "(", count: 100_000), String(repeating: "\"<(", count: 33_333)] {
            let list = MailAddressList.parse(text)
            XCTAssertTrue(list.mailboxes.isEmpty)
            XCTAssertTrue(wellFormed(list))
        }
    }

    func testThousandsOfAddressesInOneHeaderAreReadWithinTheLimitAndSaidToBeCut() {
        let entry = "user@example.com, "
        let headers = MessageHeaders([("To", String(repeating: entry, count: 10_000))])
        let to = headers.to
        XCTAssertGreaterThan(to.mailboxes.count, 800, "16 KB holds about 900 of them")
        XCTAssertLessThanOrEqual(to.mailboxes.count, MessageHeaders.maxValueBytes / entry.utf8.count)
        XCTAssertFalse(to.isComplete, "so a missing recipient is not one who was not there")
        XCTAssertTrue(wellFormed(to))
    }

    // MARK: - The text readers

    func testTheTextReadersAreLinear() {
        let families: [(String, (Int) -> String)] = [
            ("encoded words folded", { self.repeated("=?utf-8?B?SGk=?=\r\n ", to: $0) }),
            ("line breaks", { self.repeated("\r\n", to: $0) }),
            ("unfolds", { self.repeated("a\r\n b", to: $0) }),
            ("invisible characters", { self.repeated("a\u{200B}\u{202E}", to: $0) }),
            ("encoded openers", { self.repeated("=?", to: $0) }),
            ("encoded words that fail", { self.repeated("=?x-unknown?B?SGk=?= ", to: $0) }),
            ("encoded words in an unknown charset, split bytes", { self.repeated("=?x-unknown?Q?=C3?= ", to: $0) }),
            ("undefined bytes in an unknown charset", { self.repeated("=?x-unknown?Q?=81=8D?= ", to: $0) }),
            ("joined emoji", { self.repeated("\u{1F469}\u{200D}\u{1F4BB}", to: $0) }),
            ("Persian joiners", { self.repeated("\u{0628}\u{200C}\u{062A}", to: $0) }),
            ("joiners between letters", { self.repeated("a\u{200D}b", to: $0) }),
            ("variation selectors", { self.repeated("a\u{FE0F}\u{FE00}", to: $0) }),
            ("tag characters", { self.repeated("\u{E0067}", to: $0) }),
            ("flags", { self.repeated("\u{1F3F4}\u{E0067}\u{E0062}\u{E007F}", to: $0) }),
            ("transparent marks before a joiner", { String(repeating: "\u{064E}", count: $0) + "\u{200C}" }),
            ("one long word", { String(repeating: "x", count: $0) }),
        ]
        for (name, make) in families {
            assertLinear("subject: \(name)", make: make, run: { input in
                let text = MailHeaderText.unstructured(input)
                XCTAssertTrue(self.isClean(text), name)
                XCTAssertFalse(text.contains(where: { $0.isNewline }), name)
            })
        }
    }

    func testTheNameRulesAreLinearAndBounded() {
        let families: [(String, (Int) -> String)] = [
            ("dots", { self.repeated("a.b ", to: $0) }),
            ("www", { self.repeated("www.", to: $0) }),
            ("at signs", { self.repeated("@", to: $0) }),
            ("slashes", { self.repeated("://", to: $0) }),
            ("invisible characters", { self.repeated("a\u{200B}", to: $0) }),
            ("mixed scripts", { self.repeated("aБ", to: $0) }),
            ("many Cyrillic words", { self.repeated("\u{0430}\u{0431} ", to: $0) }),
            ("many accented words", { self.repeated("caf\u{00E9} ", to: $0) }),
            ("many Han words", { self.repeated("\u{674E}\u{96F7} ", to: $0) }),
            ("one long word", { String(repeating: "x", count: $0) }),
        ]
        for (name, make) in families {
            assertLinear("name: \(name)", make: make, run: { input in
                _ = MailAddressRules.displayName(input, address: "x@y.co")
                _ = MailAddressRules.cleaned(input)
                _ = MailAddressRules.isValid(input + "@b.co")
                _ = MailAddressRules.normalized(input)
            })
        }
    }

    // MARK: - Headers

    func testTheHeaderLimitsAreLinear() {
        let families: [(String, (Int) -> [(String, String)])] = [
            ("many short headers", { n in (0..<(n / 10)).map { ("H\($0)", "v") } }),
            ("one huge value", { n in [("Subject", String(repeating: "S", count: n))] }),
            ("many large values", { n in (0..<(n / 4_000)).map { ("X\($0)", String(repeating: "v", count: 4_000)) } }),
            ("one huge name", { n in [(String(repeating: "N", count: n), "v")] }),
            ("multi-byte values", { n in [("Subject", String(repeating: "€", count: n))] }),
            ("padding then named headers", { n in (0..<(n / 10)).map { ("Received", "hop \($0)") } + [("From", "a@x.com"), ("Subject", "s")] }),
            ("padding then many Froms", { n in (0..<1_000).map { ("Received", "hop \($0)") } + (0..<(n / 10)).map { ("From", "a\($0)@x.com") } }),
            ("padding then every named header", { n in
                (0..<(n / 10)).map { ("Received", "hop \($0)") } + MessageHeaders.namedHeaders.map { ($0, "v") } }),
            ("padding then long unnamed names", { n in (0..<1_000).map { ("Received", "hop \($0)") } + [(String(repeating: "N", count: n), "v")] }),
        ]
        for (name, make) in families {
            assertLinear("headers: \(name)", make: { String(repeating: "x", count: $0) }, run: { input in
                let headers = MessageHeaders(make(input.count))
                // The limits, and the named headers found past them (at most twenty, 16 KB each).
                XCTAssertLessThanOrEqual(headers.fields.count, MessageHeaders.maxLines + MessageHeaders.namedHeaders.count, name)
                XCTAssertLessThanOrEqual(headers.fields.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count },
                                         MessageHeaders.maxBytes + MessageHeaders.namedHeaders.count * (MessageHeaders.maxValueBytes + 32), name)
                _ = headers.value("subject")
                _ = headers.subject
                _ = headers.sender
            })
        }
    }

    // MARK: - Authentication results

    func testTheAuthenticationReaderIsLinear() {
        let families: [(String, (Int) -> String)] = [
            ("results", { "mx.google.com; " + self.repeated("dkim=pass header.d=a.com; ", to: $0) }),
            ("results that fail alignment", { "mx.google.com; " + self.repeated("dkim=pass header.d=other.net; ", to: $0) }),
            ("open parens", { "mx.google.com; " + self.repeated("(", to: $0) }),
            ("comments", { "mx.google.com; " + self.repeated("(a) dkim=fail; ", to: $0) }),
            ("semicolons", { "mx.google.com" + self.repeated(";", to: $0) }),
            ("quotes", { "mx.google.com; dkim=pass " + self.repeated("\"", to: $0) }),
            ("words", { "mx.google.com; dkim=pass " + self.repeated("a=b ", to: $0) }),
            ("spaces around equals", { "mx.google.com; " + self.repeated("a = b ", to: $0) }),
            ("backslashes", { "mx.google.com; " + self.repeated("\\", to: $0) }),
            ("DMARC results for another domain", { "mx.google.com; " + self.repeated("dmarc=pass header.from=a.com; ", to: $0) }),
            ("identities", { "mx.google.com; " + self.repeated("dkim=pass header.i=@a.com@b.com; ", to: $0) }),
        ]
        for (name, make) in families {
            assertLinear("auth results: \(name)", make: make, run: { input in
                let domain = MailAuthRules.authenticatedDomain(
                    headers: [("Received", "x"), ("Authentication-Results", input)], fromDomain: "example.com")
                XCTAssertNil(domain, name)
            })
        }
    }

    /// Gmail's header first, a thousand and more of other servers' and the sender's after it: only
    /// the first is read, and the rest cost nothing to ignore. With another server's header
    /// first, Gmail wrote none and nothing is authenticated, however many Google-sounding ones
    /// follow.
    func testManyAuthenticationHeadersAreReadWithoutSlowingDown() {
        assertLinear("auth results: many headers", make: { String(repeating: "x", count: $0) }, run: { input in
            let others: [(String, String)] = (0..<(input.count / 40)).map {
                ("Authentication-Results", "evil\($0).example; dkim=pass header.d=other.net")
            }
            let gmail = ("Authentication-Results", "mx.google.com; dkim=pass header.d=example.com")
            XCTAssertEqual(MailAuthRules.authenticatedDomain(headers: [gmail] + others, fromDomain: "example.com"),
                           "example.com")
            XCTAssertNil(MailAuthRules.authenticatedDomain(headers: others + [gmail], fromDomain: "example.com"))
        })
    }

    // MARK: - File names

    func testTheFileNameRuleIsLinear() {
        let families: [(String, (Int) -> String)] = [
            ("dots", { self.repeated(".", to: $0) }),
            ("dots and spaces", { self.repeated(". ", to: $0) }),
            ("overrides", { self.repeated("\u{202E}", to: $0) }),
            ("slashes", { self.repeated("/", to: $0) }),
            ("words", { self.repeated("a b ", to: $0) }),
            ("one long name", { String(repeating: "x", count: $0) + ".pdf" }),
            ("multi-byte", { String(repeating: "é", count: $0) + ".txt" }),
            ("clusters", { self.repeated("🇯🇵", to: $0) + ".png" }),
            ("many dots inside", { self.repeated("a.", to: $0) }),
        ]
        for (name, make) in families {
            assertLinear("file name: \(name)", make: make, run: { input in
                let safe = MailFileName.safe(input)
                XCTAssertLessThanOrEqual(safe.utf8.count, MailFileName.maxBytes, name)
                XCTAssertFalse(safe.isEmpty, name)
            })
        }
    }

    // MARK: - The wire models

    func testAGmailMessageWithThousandsOfLabelsAndHeadersDecodesInLinearTime() {
        let families: [(String, (Int) -> String)] = [
            ("labels", { n in
                "{\"id\": \"a\", \"labelIds\": [" + (0..<(n / 12)).map { "\"Label_\($0)\"" }.joined(separator: ",") + "]}" }),
            ("headers", { n in
                "{\"id\": \"a\", \"payload\": {\"headers\": ["
                    + (0..<(n / 40)).map { "{\"name\": \"X-\($0)\", \"value\": \"value\"}" }.joined(separator: ",") + "]}}" }),
            ("parts", { n in
                "{\"id\": \"a\", \"payload\": {\"parts\": ["
                    + (0..<(n / 40)).map { "{\"partId\": \"\($0)\", \"mimeType\": \"text/plain\"}" }.joined(separator: ",") + "]}}" }),
            ("unknown keys", { n in
                "{\"id\": \"a\"," + (0..<(n / 20)).map { "\"k\($0)\": {\"v\": [1, 2]}" }.joined(separator: ",") + "}" }),
        ]
        for (name, make) in families {
            assertLinear("wire: \(name)", make: make, run: { json in
                XCTAssertNotNil(try? JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8)), name)
            })
        }
    }

    func testDeeplyNestedPartsFailQuicklyAndNeverRecurseWithoutBound() {
        func nested(_ depth: Int) -> String {
            var json = "{\"id\": \"a\", \"payload\": "
            for _ in 0..<depth { json += "{\"parts\": [" }
            json += "{}"
            for _ in 0..<depth { json += "]}" }
            return json + "}"
        }
        for depth in [1_000, 10_000, 100_000] {
            let json = nested(depth)
            XCTAssertThrowsError(try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8)), "depth \(depth)")
        }
        assertLinear("wire: nesting", make: { String(repeating: "x", count: $0) }, run: { input in
            _ = try? JSONDecoder().decode(GmailMessage.self, from: Data(nested(input.count / 8).utf8))
        })
    }

    // MARK: - A whole hostile message, end to end

    func testAMessageWithEveryHostileHeaderAtOnceIsReadWithoutIncident() throws {
        let big = String(repeating: "a", count: 100_000)
        let headers: [[String: String]] = [
            ["name": "From", "value": "\"noor@plan.example\" <x@evil.example>, \u{202E}Eve <e\u{200B}@evil.example>, " + big],
            ["name": "To", "value": String(repeating: "\"<(", count: 30_000)],
            ["name": "Cc", "value": String(repeating: "u@example.com, ", count: 5_000)],
            ["name": "Subject", "value": "=?x-unknown?B?SGk=?= \u{202E}fdp.exe\r\nBcc: x@evil.example " + big],
            ["name": "Authentication-Results", "value": String(repeating: "(", count: 50_000)],
        ]
        let object: [String: Any] = ["id": "a", "payload": ["headers": headers]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let message = try JSONDecoder().decode(GmailMessage.self, from: data)
        let h = MessageHeaders(payload: message.payload)

        XCTAssertFalse(h.isComplete)
        XCTAssertTrue(wellFormed(h.addresses("From")))
        XCTAssertEqual(h.addresses("From").mailboxes.first?.address, "x@evil.example", "the list is read; it is not a sender")
        XCTAssertFalse(h.addresses("From").mailboxes.contains { $0.address.contains("e\u{200B}") },
                       "the invisible character was not removed to make an address")
        XCTAssertNil(h.sender, "a From of several pieces, cut, is no sender")
        XCTAssertTrue(wellFormed(h.to))
        XCTAssertTrue(wellFormed(h.cc))
        XCTAssertTrue(isClean(h.subject ?? ""))
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: h, fromDomain: "example.com"))
    }
}
