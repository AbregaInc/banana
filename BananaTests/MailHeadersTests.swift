import XCTest

/// A message's headers: found by name in the order the message has them, read under limits,
/// and honest about what a limit cut (MAIL-ENGINE 5.6, 10.8).
///
/// The failure that matters is the quiet one: a header Gmail sent and a limit removed looking
/// like a header the message does not have. `isComplete` is how a reader knows the difference —
/// and the named headers are looked for past the cut, so that hiding a `From` behind five
/// thousand lines of padding costs the sender nothing and gains him nothing.
final class MailHeadersTests: XCTestCase {

    private func headers(_ pairs: [(String, String)], complete: Bool = true) -> MessageHeaders {
        MessageHeaders(pairs, isComplete: complete)
    }

    // MARK: - Lookup

    func testHeadersAreFoundByNameWithoutRegardToCase() {
        let h = headers([("From", "a@x.com"), ("SUBJECT", "Hi"), ("message-id", "<1@x.com>")])
        XCTAssertEqual(h.value("from"), "a@x.com")
        XCTAssertEqual(h.value("Subject"), "Hi")
        XCTAssertEqual(h.value("MESSAGE-ID"), "<1@x.com>")
        XCTAssertTrue(h.contains("sUbJeCt"))
        XCTAssertNil(h.value("Cc"))
        XCTAssertFalse(h.contains("Cc"))
    }

    func testHeadersKeepTheOrderTheMessageHasThem() {
        let h = headers([("Received", "1"), ("From", "a@x.com"), ("Received", "2"), ("Subject", "S"), ("Received", "3")])
        XCTAssertEqual(h.fields.map(\.name), ["Received", "From", "Received", "Subject", "Received"])
        XCTAssertEqual(h.values("received"), ["1", "2", "3"])
        XCTAssertEqual(h.pairs.map { $0.0 }, ["Received", "From", "Received", "Subject", "Received"])
        XCTAssertEqual(h.pairs.map { $0.1 }, ["1", "a@x.com", "2", "S", "3"])
    }

    /// Two `From` headers are how one message shows two senders to two readers. Both are kept, the
    /// first is what a plain lookup gives, neither is merged into the other, and **there is no
    /// sender**: the first of two is the one a forger chose to put there.
    func testAHeaderWrittenTwiceKeepsBothAndALookupGivesTheFirstAndThereIsNoSender() {
        let h = headers([("From", "Real <real@example.com>"), ("From", "Fake <fake@evil.example>")])
        XCTAssertEqual(h.value("From"), "Real <real@example.com>")
        XCTAssertEqual(h.values("From"), ["Real <real@example.com>", "Fake <fake@evil.example>"])
        XCTAssertEqual(h.addresses("From").mailboxes.map(\.address), ["real@example.com", "fake@evil.example"],
                       "both are read; neither is believed")
        XCTAssertEqual(h.fromHeaderCount, 2)
        XCTAssertNil(h.sender)
    }

    /// Only ASCII upper case is folded. The Kelvin sign is a "k" under full case folding, and a
    /// header named with it is not the header named with a "k".
    func testNamesAreFoldedAsASCIIOnly() {
        let h = headers([("X-Ban\u{212A}", "kelvin"), ("X-BANK", "ascii")])
        XCTAssertEqual(h.value("x-bank"), "ascii")
        XCTAssertEqual(h.values("x-bank"), ["ascii"])
        XCTAssertEqual(h.value("X-Ban\u{212A}"), "kelvin")
    }

    // MARK: - What Gmail sent, and what it did not

    func testAPayloadWithNoHeadersKeyIsUnknownAndOneWithAnEmptyListIsNot() {
        let none = MessageHeaders(payload: GmailPart(partId: "0"))
        XCTAssertTrue(none.fields.isEmpty)
        XCTAssertFalse(none.isComplete, "no headers were sent, which says nothing of whether there are any")
        let empty = MessageHeaders(payload: GmailPart(headers: []))
        XCTAssertTrue(empty.fields.isEmpty)
        XCTAssertTrue(empty.isComplete, "an empty list was sent: the message has no headers")
        XCTAssertFalse(MessageHeaders(payload: nil).isComplete)
        XCTAssertFalse(MessageHeaders.unread.isComplete)
        XCTAssertNil(MessageHeaders.unread.sender)
    }

    func testAHeaderWithNoNameIsDroppedAndOneWithNoValueHoldsItsPlaceAndIsNotRead() {
        let part = GmailPart(headers: [GmailHeader(name: "From", value: "a@x.com"),
                                       GmailHeader(name: nil, value: "orphan"),
                                       GmailHeader(name: "Subject", value: nil),
                                       GmailHeader(name: "To", value: "b@x.com")])
        let h = MessageHeaders(payload: part)
        XCTAssertEqual(h.fields.map(\.name), ["From", "Subject", "To"], "the nameless one cannot be looked up; the other keeps its place")
        XCTAssertFalse(h.isComplete)
        XCTAssertEqual(h.field("Subject")?.wasCut, true, "its value is unknown, and says so")
        XCTAssertEqual(h.value("Subject"), "")
    }

    /// The first `Authentication-Results` must stay the first: a header Gmail sent without a value
    /// is not removed to let a second one take its place.
    func testAnAuthenticationHeaderWithNoValueKeepsItsPlaceSoASecondIsNotTheFirst() {
        let part = GmailPart(headers: [GmailHeader(name: "Authentication-Results", value: nil),
                                       GmailHeader(name: "Authentication-Results",
                                                   value: "mx.google.com; dkim=pass header.d=example.com")])
        let h = MessageHeaders(payload: part)
        XCTAssertEqual(h.field("Authentication-Results")?.wasCut, true)
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: h, fromDomain: "example.com"))
    }

    func testAHeaderSetRestoredAsIncompleteStaysIncomplete() {
        XCTAssertFalse(headers([("From", "a@x.com")], complete: false).isComplete)
        XCTAssertTrue(headers([("From", "a@x.com")]).isComplete)
    }

    // MARK: - Limits: 1,000 lines, and what is known past them

    func testAThousandHeadersAreKeptAndTheThousandAndFirstIsCutAndSaid() {
        let thousand = (0..<1_000).map { ("X-\($0)", "v") }
        let kept = headers(thousand)
        XCTAssertEqual(kept.fields.count, 1_000)
        XCTAssertTrue(kept.isComplete, "exactly at the limit nothing was cut")

        let over = headers(thousand + [("X-1000", "v")])
        XCTAssertEqual(over.fields.count, 1_000, "a header nobody reads by name is cut at the limit")
        XCTAssertNil(over.value("X-1000"))
        XCTAssertFalse(over.isComplete)
    }

    /// A limit bounds what is kept, not what is known (5.6): the headers read by name are looked
    /// for past it, so a `From` after five thousand lines of padding is still the sender.
    func testAHeaderReadByNameIsFoundPastTheLineLimit() {
        let padding = (0..<1_000).map { ("Received", "hop \($0)") }
        let h = headers(padding + [("From", "Sam <sam@plan.example>"), ("Subject", "Hi"), ("X-Other", "v")])
        XCTAssertEqual(h.value("From"), "Sam <sam@plan.example>")
        XCTAssertEqual(h.subject, "Hi")
        XCTAssertNil(h.value("X-Other"), "not one of the named headers")
        XCTAssertEqual(h.sender?.address, "sam@plan.example")
        XCTAssertFalse(h.isComplete, "and the set still says it is not the whole")
        XCTAssertEqual(h.fields.count, 1_002)
    }

    func testEveryNamedHeaderIsFoundPastTheCutAndOnlyTheFirstOfEach() {
        let padding = (0..<1_000).map { ("Received", "hop \($0)") }
        let names = ["From", "Sender", "To", "Cc", "Bcc", "Reply-To", "Subject", "Date", "Message-ID",
                     "In-Reply-To", "References", "List-Id", "List-Unsubscribe", "List-Unsubscribe-Post",
                     "Content-Type", "Delivered-To", "Auto-Submitted", "X-Google-Original-Message-ID",
                     "X-Banana-Send-At", "X-Banana-Send-Owner"]
        XCTAssertEqual(Set(names.map { $0.lowercased() }), MessageHeaders.namedHeaders)
        let tail = names.flatMap { [($0.uppercased(), "first"), ($0, "second")] }
        let h = headers(padding + tail)
        for name in names {
            XCTAssertEqual(h.values(name), ["first"], name)
        }
        XCTAssertEqual(h.fields.count, 1_000 + names.count)
    }

    /// The first of each that the kept part *lacks*: a name already kept is not added to.
    func testANamedHeaderPastTheCutIsNotAddedWhenTheKeptPartHasOne() {
        let padding = (0..<999).map { ("Received", "hop \($0)") }
        let h = headers([("Subject", "kept")] + padding + [("Subject", "past the cut"), ("To", "a@x.com")])
        XCTAssertEqual(h.values("Subject"), ["kept"])
        XCTAssertEqual(h.value("To"), "a@x.com")
    }

    /// Count them all: a second `From` past the cut is still a second `From`.
    func testASecondFromPastTheCutIsStillCountedAndThereIsNoSender() {
        let padding = (0..<1_000).map { ("Received", "hop \($0)") }
        let h = headers(padding + [("From", "Sam <sam@plan.example>"), ("From", "Other <other@evil.example>")])
        XCTAssertEqual(h.fromHeaderCount, 2)
        XCTAssertEqual(h.values("From"), ["Sam <sam@plan.example>"], "the first of each is kept")
        XCTAssertNil(h.sender, "but there were two")
        let one = headers((0..<1_000).map { ("Received", "hop \($0)") } + [("From", "Sam <sam@plan.example>")])
        XCTAssertEqual(one.fromHeaderCount, 1)
        XCTAssertEqual(one.sender?.address, "sam@plan.example")
        let kept = headers([("From", "a@x.com")] + (0..<1_000).map { ("Received", "hop \($0)") } + [("From", "b@x.com")])
        XCTAssertEqual(kept.fromHeaderCount, 2, "one kept and one past the cut")
        XCTAssertNil(kept.sender)
    }

    func testAnAuthenticationResultsHeaderPastTheCutIsNotKept() {
        let padding = (0..<1_000).map { ("Received", "hop \($0)") }
        let h = headers(padding + [("Authentication-Results", "mx.google.com; dmarc=pass header.from=example.com")])
        XCTAssertNil(h.field("Authentication-Results"))
        XCTAssertNil(h.value("ARC-Authentication-Results"))
    }

    // MARK: - Limits: 16 KB a value

    func testAValueOfExactly16KBIsKeptWhole() {
        let value = String(repeating: "a", count: 16 * 1_024)
        let h = headers([("Subject", value)])
        XCTAssertEqual(h.value("Subject")?.utf8.count, 16 * 1_024)
        XCTAssertEqual(h.fields.first?.wasCut, false)
        XCTAssertTrue(h.isComplete)
    }

    func testAValueOverTheLimitIsCutAtTheLimitAndSaid() {
        let h = headers([("Subject", String(repeating: "a", count: 16 * 1_024 + 1)), ("To", "b@x.com")])
        XCTAssertEqual(h.value("Subject")?.utf8.count, 16 * 1_024)
        XCTAssertEqual(h.fields.first?.wasCut, true)
        XCTAssertEqual(h.value("To"), "b@x.com", "what follows a cut value is still read")
        XCTAssertFalse(h.isComplete)
    }

    /// Cut on a character boundary: two-byte and three-byte characters, and a four-byte one,
    /// are never split into a replacement character.
    func testAValueIsNeverCutInTheMiddleOfACharacter() {
        for character in ["é", "€", "😀"] {
            let value = String(repeating: character, count: 20_000)
            let h = headers([("Subject", value)])
            let kept = h.value("Subject") ?? ""
            XCTAssertLessThanOrEqual(kept.utf8.count, 16 * 1_024, character)
            XCTAssertGreaterThan(kept.utf8.count, 16 * 1_024 - character.utf8.count, character)
            XCTAssertFalse(kept.unicodeScalars.contains("\u{FFFD}"), "\(character) was split")
            XCTAssertEqual(Set(kept), [Character(character)], "\(character): only whole characters remain")
        }
    }

    // MARK: - Limits: 256 KB

    func testHeadersAreKeptUntilTheirNamesAndValuesFill256KBAndNoFurther() {
        // Twenty values of 15 KB is 300 KB: the budget runs out inside the eighteenth. A header
        // nobody reads by name is then cut; one that is read by name is still found.
        let big = String(repeating: "v", count: 15 * 1_024)
        let pairs = (0..<20).map { ("X-\($0)", big) } + [("From", "a@x.com"), ("X-Late", "v")]
        let h = headers(pairs)
        let prefix = h.fields.filter { $0.name.hasPrefix("X-") }
        let bytes = prefix.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
        XCTAssertLessThanOrEqual(bytes, 256 * 1_024)
        XCTAssertGreaterThan(bytes, 256 * 1_024 - 16 * 1_024 - 8)
        XCTAssertEqual(prefix.count, 17)
        XCTAssertNil(h.value("X-Late"))
        XCTAssertEqual(h.value("From"), "a@x.com", "found past the cut")
        XCTAssertFalse(h.isComplete)
    }

    func testAHeaderNameTooLongToBeAnyHeaderIsDroppedAndSaid() {
        let h = headers([(String(repeating: "N", count: 17_000), "v"), ("From", "a@x.com")])
        XCTAssertEqual(h.fields.map(\.name), ["From"])
        XCTAssertFalse(h.isComplete)
    }

    // MARK: - header-1mb

    /// "A 1 MB Subject and 5,000 Received lines; limits hold." Gmail's own header is on top and
    /// is kept; the first thousand fields are kept; and the sender, the subject and the rest of
    /// the named headers are found past them. The subject is cut at 16 KB.
    func testTheHeader1MBFixtureIsCutAtTheLimitsAndItsSenderIsStillFound() throws {
        let json = MailHostileMessages.header1MB()
        XCTAssertGreaterThan(json.utf8.count, 1_048_576 + 5_000 * 60, "it is a megabyte of subject and the lines")
        let message = try MailHostileMessages.decode(json)
        let h = MessageHeaders(payload: message.payload)

        XCTAssertEqual(h.fields.first?.name, "Authentication-Results")
        XCTAssertEqual(h.values("Received").count, MessageHeaders.maxLines - 1)
        XCTAssertEqual(h.fields.count, MessageHeaders.maxLines + 5, "the five named headers found past the cut")
        XCTAssertEqual(h.sender?.address, "sender@example.com", "its From came after the five thousand lines")
        XCTAssertEqual(h.subject?.utf8.count, MessageHeaders.maxValueBytes)
        XCTAssertEqual(h.field("Subject")?.wasCut, true)
        XCTAssertEqual(h.value("Date"), "Tue, 06 Oct 2026 09:18:00 +0000")
        XCTAssertFalse(h.isComplete, "and it still says that what Gmail sent was cut")
        let prefix = h.fields.prefix(MessageHeaders.maxLines)
        XCTAssertLessThanOrEqual(prefix.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }, MessageHeaders.maxBytes)
    }

    func testTwoFromsPastTheCutAreTwoFromsAndThereIsNoSender() throws {
        let message = try MailHostileMessages.decode(MailHostileMessages.header1MB(twoFroms: true))
        let h = MessageHeaders(payload: message.payload)
        XCTAssertEqual(h.fromHeaderCount, 2)
        XCTAssertNil(h.sender)
    }

    /// The same message with the subject early: now it is the value limit that cuts.
    func testAOneMegabyteSubjectNearTheTopIsCutTo16KBAndTheRestIsRead() {
        let h = headers([("From", "Sender <sender@example.com>"),
                         ("Subject", String(repeating: "S", count: 1_048_576)),
                         ("Date", "Tue, 06 Oct 2026 09:18:00 +0000")])
        XCTAssertEqual(h.subject?.utf8.count, 16 * 1_024)
        XCTAssertEqual(h.sender?.address, "sender@example.com")
        XCTAssertEqual(h.value("Date"), "Tue, 06 Oct 2026 09:18:00 +0000")
        XCTAssertFalse(h.isComplete)
    }

    // MARK: - Readers

    func testTheAddressReadersCoverEveryAddressHeader() {
        let h = headers([("From", "Ann <ann@x.com>"), ("Sender", "sec@x.com"), ("Reply-To", "Ann <ann.r@x.com>"),
                         ("To", "b@x.com, c@x.com"), ("Cc", "d@x.com"), ("Bcc", "e@x.com"),
                         ("Delivered-To", "me@plan.example")])
        XCTAssertEqual(h.sender?.address, "ann@x.com")
        XCTAssertEqual(h.sender?.name, "Ann")
        XCTAssertEqual(h.addresses("Sender").mailboxes.map(\.address), ["sec@x.com"])
        XCTAssertEqual(h.replyTo.mailboxes.map(\.address), ["ann.r@x.com"])
        XCTAssertEqual(h.to.mailboxes.map(\.address), ["b@x.com", "c@x.com"])
        XCTAssertEqual(h.cc.mailboxes.map(\.address), ["d@x.com"])
        XCTAssertEqual(h.bcc.mailboxes.map(\.address), ["e@x.com"])
        XCTAssertEqual(h.deliveredTo.mailboxes.map(\.address), ["me@plan.example"])
        XCTAssertNil(headers([]).sender)
        XCTAssertTrue(headers([]).to.items.isEmpty)
    }

    /// A value that was cut may end in half an address ("…, bo"): that last piece is left out
    /// rather than read as the address "bo@…", and the list says it is not complete.
    func testACutAddressListLeavesOutItsLastPieceAndSaysItIsIncomplete() {
        let entry = "person@example.com, "
        let count = (16 * 1_024) / entry.utf8.count + 50
        let h = headers([("To", String(repeating: entry, count: count))])
        XCTAssertEqual(h.fields.first?.wasCut, true)
        let list = h.to
        XCTAssertFalse(list.isComplete)
        XCTAssertFalse(list.hasUnreadable)
        XCTAssertTrue(list.mailboxes.allSatisfy { $0.address == "person@example.com" },
                      "no half address was read as an address")
        let whole = MailAddressList.parse(h.value("To") ?? "")
        XCTAssertEqual(list.items.count, whole.items.count - 1, "exactly the last piece is left out")
    }

    func testAGroupInTheListIsCarriedThroughTheAddressReader() {
        let h = headers([("To", "Team: a@x.com, b@x.com;")])
        XCTAssertTrue(h.to.hasGroup)
        XCTAssertEqual(h.to.mailboxes.map(\.address), ["a@x.com", "b@x.com"])
        XCTAssertFalse(headers([("To", "a@x.com")]).to.hasGroup)
    }

    func testSubjectIsDecodedAndCleanedWhetherOrNotGmailAlreadyDidIt() {
        let encoded = headers([("Subject", "=?UTF-8?B?Q2Fmw6k=?=")])
        let plain = headers([("Subject", "Café")])
        XCTAssertEqual(encoded.subject, "Café")
        XCTAssertEqual(plain.subject, "Café", "the same words come out either way: only an encoded word is touched")
        XCTAssertNil(headers([]).subject)
    }
}
