import XCTest

/// Reading an address header (MAIL-ENGINE 10.8, RFC 5322 section 3.4).
///
/// The reader is for text a stranger wrote, so each test is one shape such text takes, and
/// what it asks of the answer is the same every time: something *defined* comes back, nothing
/// that was written is lost without being said (an unreadable piece is kept as one), and
/// what the sender put apart stays apart — a name is never merged into the address beside it.
final class MailAddressListTests: XCTestCase {

    private func parse(_ text: String) -> MailAddressList { MailAddressList.parse(text) }

    private func mailbox(_ item: MailAddressList.Item) -> MailAddress? {
        if case .mailbox(let mailbox) = item { return mailbox }
        return nil
    }

    // MARK: - The ordinary shapes

    func testAnAddressWithNoDisplayNameIsAMailboxWithNoName() {
        let list = parse("bob@example.com")
        XCTAssertEqual(list.items, [.mailbox(MailAddress(name: nil, address: "bob@example.com"))])
        XCTAssertTrue(list.isComplete)
        XCTAssertEqual(parse("<bob@example.com>").items, list.items)
    }

    func testANameAndAnAddressInBracketsAreAMailbox() {
        XCTAssertEqual(parse("Bob Smith <bob@example.com>").items,
                       [.mailbox(MailAddress(name: "Bob Smith", address: "bob@example.com"))])
    }

    func testAQuotedNameMayHoldCommasAndColonsAndSemicolonsAndQuotes() {
        let list = parse(#""Smith, Bob" <bob@example.com>, "a: b; c" <x@y.com>, "Bob \"The Builder\"" <b@z.com>"#)
        XCTAssertEqual(list.mailboxes.map(\.name), ["Smith, Bob", "a: b; c", #"Bob "The Builder""#])
        XCTAssertEqual(list.mailboxes.map(\.address), ["bob@example.com", "x@y.com", "b@z.com"])
    }

    func testACommentAfterABareAddressIsItsName() {
        XCTAssertEqual(parse("bob@example.com (Bob Smith)").items,
                       [.mailbox(MailAddress(name: "Bob Smith", address: "bob@example.com"))])
    }

    func testACommentBesideANameIsNotPartOfIt() {
        XCTAssertEqual(parse("Bob (the builder) <bob@example.com>").mailboxes.map(\.name), ["Bob"])
    }

    func testNestedCommentsAreOneCommentAndEscapesInThemAreResolved() {
        let list = parse(#"Bob (a (nested (deep)) comment \) still) <bob@example.com>"#)
        XCTAssertEqual(list.mailboxes.map(\.address), ["bob@example.com"])
        XCTAssertEqual(list.mailboxes.map(\.name), ["Bob"])
    }

    func testSeveralAddressesAreReadInOrderWhetherCommaOrSemicolonSeparated() {
        XCTAssertEqual(parse("a@x.com, B <b@x.com>,c@x.com").mailboxes.map(\.address), ["a@x.com", "b@x.com", "c@x.com"])
        XCTAssertEqual(parse("a@x.com; b@x.com").mailboxes.map(\.address), ["a@x.com", "b@x.com"])
        XCTAssertEqual(parse("a@x.com,\r\n\tb@x.com").mailboxes.map(\.address), ["a@x.com", "b@x.com"])
    }

    /// Two bare addresses with no comma between them are not two mailboxes but one thing that
    /// cannot be read: which is whose cannot be told, and the first is the one a forger chose.
    func testTwoBareAddressesWithNoSeparatorAreOneItemThatCannotBeRead() {
        let list = parse("a@x.com b@x.com")
        XCTAssertEqual(list.items, [.unreadable("a@x.com b@x.com")])
        XCTAssertTrue(list.mailboxes.isEmpty)
        XCTAssertEqual(parse("a@x.com b@x.com c@x.com").items.count, 1)
    }

    // MARK: - What is in quotes is a name, never an address (L11)

    /// The four shapes of the code review's first table: a quoted string holding the victim's
    /// address, beside something an address-trying reader would have taken for the sender.
    func testAQuotedNameBesideABareAddressIsItsNameAndNotASecondAddress() {
        let list = parse(#""ceo@victim.example" attacker@evil.example"#)
        XCTAssertEqual(list.items, [.mailbox(MailAddress(name: "ceo@victim.example", address: "attacker@evil.example"))])
        XCTAssertNil(MailAddressRules.displayName("ceo@victim.example", address: "attacker@evil.example"),
                     "the name looks like an address, and is therefore not shown")
    }

    func testAQuotedNameAloneIsNoMailbox() {
        XCTAssertEqual(parse(#""ceo@victim.example" x"#).items, [.unreadable("ceo@victim.example x")])
        XCTAssertEqual(parse(#""ceo@victim.example""#).items, [.unreadable("ceo@victim.example")])
        XCTAssertTrue(parse(#""ceo@victim.example" x"#).mailboxes.isEmpty)
        XCTAssertTrue(parse(#""ceo@victim.example""#).mailboxes.isEmpty)
        XCTAssertTrue(parse(#""a@x.com" "b@x.com""#).mailboxes.isEmpty)
    }

    func testAQuotedGroupNameHoldingAnAddressIsAGroupOfItsMembersAndNotTheAddress() {
        let list = parse(#""ceo@victim.example": a@evil.example;"#)
        XCTAssertEqual(list.items, [.mailbox(MailAddress(name: nil, address: "a@evil.example"))])
        XCTAssertTrue(list.hasGroup)
    }

    func testTwoBareAddressesAfterAQuotedNameAreStillOneItemThatCannotBeRead() {
        let list = parse(#""ceo@victim.example" a@evil.example b@evil.example"#)
        XCTAssertTrue(list.mailboxes.isEmpty)
        XCTAssertEqual(list.items.count, 1)
    }

    func testAnUnquotedWordBesideAQuotedNameIsStillTriedAsTheAddress() {
        XCTAssertEqual(parse(#""Bob Smith" bob@x.com"#).items,
                       [.mailbox(MailAddress(name: "Bob Smith", address: "bob@x.com"))])
        XCTAssertEqual(parse(#"bob@x.com "Bob Smith""#).items,
                       [.mailbox(MailAddress(name: "Bob Smith", address: "bob@x.com"))])
    }

    func testGroupSyntaxIsSaidWhetherOrNotTheGroupHasAnyone() {
        XCTAssertTrue(parse("Team: a@x.com;").hasGroup)
        XCTAssertTrue(parse("undisclosed-recipients:;").hasGroup)
        XCTAssertFalse(parse("a@x.com, b@x.com").hasGroup)
        XCTAssertFalse(parse(#""Re: lunch" <bob@x.com>"#).hasGroup)
    }

    func testNothingAtAllIsAnEmptyCompleteList() {
        for text in ["", "   ", "\r\n", ",", ";;,"] {
            XCTAssertEqual(parse(text), MailAddressList(items: [], isComplete: true), text.debugDescription)
        }
    }

    // MARK: - Groups

    func testAGroupGivesItsMembers() {
        let list = parse(#"Team: a@x.com, "B" <b@x.com>;"#)
        XCTAssertEqual(list.items, [.mailbox(MailAddress(name: nil, address: "a@x.com")),
                                    .mailbox(MailAddress(name: "B", address: "b@x.com"))])
    }

    func testAGroupWithNobodyInItIsSaidAndIsNotAnAddress() {
        let list = parse("undisclosed-recipients:;")
        XCTAssertEqual(list.items, [.emptyGroup("undisclosed-recipients")])
        XCTAssertTrue(list.mailboxes.isEmpty)
        XCTAssertEqual(parse("Team: ;, a@x.com").items.first, .emptyGroup("Team"))
    }

    func testAddressesAfterAGroupAreNotInIt() {
        let list = parse("Team: a@x.com; c@x.com")
        XCTAssertEqual(list.mailboxes.map(\.address), ["a@x.com", "c@x.com"])
    }

    func testAGroupThatIsNeverClosedRunsToTheEnd() {
        XCTAssertEqual(parse("Team: a@x.com, b@x.com").mailboxes.map(\.address), ["a@x.com", "b@x.com"])
    }

    func testAMailtoPrefixIsAGroupNameAndTheAddressIsStillRead() {
        XCTAssertEqual(parse("mailto:bob@example.com").mailboxes.map(\.address), ["bob@example.com"])
    }

    func testAColonInsideQuotesOrAfterAnAddressIsNotAGroup() {
        XCTAssertEqual(parse(#""Re: lunch" <bob@x.com>"#).mailboxes.map(\.name), ["Re: lunch"])
        XCTAssertEqual(parse("bob@x.com: nonsense").mailboxes.map(\.address), ["bob@x.com"])
    }

    func testAGroupInsideAGroupIsDefinedAndKeepsTheAddress() {
        XCTAssertEqual(parse("a: b: c@x.com;").mailboxes.map(\.address), ["c@x.com"])
    }

    // MARK: - A name with no address, an address with no name

    /// Nothing that was written is dropped: text with no usable address is kept as such, so a
    /// reader knows something was there and could not be read.
    func testANameWithNoAddressIsKeptAsUnreadable() {
        XCTAssertEqual(parse("John Smith").items, [.unreadable("John Smith")])
        XCTAssertEqual(parse("a@x.com, nonsense, b@x.com").items.map { mailbox($0)?.address ?? "?" },
                       ["a@x.com", "?", "b@x.com"])
        XCTAssertEqual(parse("a@x.com, nonsense, b@x.com").items[1], .unreadable("nonsense"))
    }

    func testBracketsWithNoUsableAddressInThemAreUnreadableAndKeepTheName() {
        for text in [#""John Smith" <>"#, "John <not an address>", "John <bob@example>", "John <@example.com>",
                     "John <bob@>"] {
            let list = parse(text)
            XCTAssertTrue(list.mailboxes.isEmpty, text)
            XCTAssertEqual(list.items.count, 1, text)
            guard case .unreadable(let kept)? = list.items.first else { return XCTFail(text) }
            XCTAssertTrue(kept.contains("John"), "\(text): \(kept)")
        }
    }

    func testAnAddressWithNoDomainIsNotAMailbox() {
        XCTAssertTrue(parse("bob@").mailboxes.isEmpty)
        XCTAssertTrue(parse("bob@localhost").mailboxes.isEmpty)
        XCTAssertTrue(parse("@example.com").mailboxes.isEmpty)
        XCTAssertTrue(parse("bob@localhost").hasUnreadable)
    }

    // MARK: - Unbalanced quotes, brackets and comments

    /// A quote that never closes is a character; the address after it is still found.
    func testAQuoteThatNeverClosesIsText() {
        let list = parse(#""Bob <bob@example.com>"#)
        XCTAssertEqual(list.mailboxes.map(\.address), ["bob@example.com"])
        XCTAssertEqual(list.mailboxes.first?.name, "\"Bob")
    }

    /// An address is found only in brackets that close: `Bob <bob@example.com` is not read as
    /// bob@example.com, which is what "closes" would have to mean to be a statement about it.
    func testABracketThatNeverClosesIsTextAndNoAddressIsTakenFromIt() {
        let list = parse("Bob <bob@example.com")
        XCTAssertTrue(list.mailboxes.isEmpty)
        XCTAssertEqual(list.items, [.unreadable("Bob <bob@example.com")])
    }

    func testACommentThatNeverClosesIsText() {
        let list = parse("Bob (note <bob@example.com>")
        XCTAssertEqual(list.mailboxes.map(\.address), ["bob@example.com"])
        XCTAssertEqual(list.mailboxes.first?.name, "Bob (note")
    }

    func testAStrayClosingBracketOrParenIsText() {
        XCTAssertEqual(parse("Bob) <bob@example.com>").mailboxes.first?.name, "Bob)")
        XCTAssertEqual(parse("Bob <bob@example.com>>").mailboxes.map(\.address), ["bob@example.com"])
    }

    func testBracketsInsideBracketsAreNotAnAddress() {
        XCTAssertTrue(parse("<a<b@example.com>").mailboxes.isEmpty)
        XCTAssertTrue(parse("<<bob@example.com>>").mailboxes.isEmpty)
    }

    func testTextAfterTheClosingBracketIsTheNextThingNotPartOfThisOne() {
        let list = parse("Bob <bob@example.com> junk")
        XCTAssertEqual(list.items, [.mailbox(MailAddress(name: "Bob", address: "bob@example.com")),
                                    .unreadable("junk")])
        XCTAssertEqual(parse("Bob <bob@example.com> Alice <alice@example.com>").mailboxes.map(\.name), ["Bob", "Alice"])
    }

    // MARK: - Spoofing shapes: a name is not an address

    /// `from-name-is-address`: the name says one address and the brackets another. Both are
    /// kept, apart, and `displayName` is what refuses the name.
    func testANameThatIsAnAddressStaysApartFromTheRealAddress() {
        let list = parse(#""noor@plan.example" <x@evil.example>"#)
        XCTAssertEqual(list.items, [.mailbox(MailAddress(name: "noor@plan.example", address: "x@evil.example"))])
        let person = list.mailboxes[0]
        XCTAssertNil(MailAddressRules.displayName(person.name, address: person.address),
                     "the UI shows x@evil.example, not noor@plan.example")
    }

    func testAnAddressInsideAQuotedNameWithBracketsStaysApart() {
        let list = parse(#""Sam Lee <sam@plan.example>" <x@evil.example>"#)
        XCTAssertEqual(list.mailboxes.map(\.address), ["x@evil.example"])
        XCTAssertEqual(list.mailboxes.first?.name, "Sam Lee <sam@plan.example>")
        XCTAssertEqual(list.mailboxes.count, 1)
        XCTAssertNil(MailAddressRules.displayName(list.mailboxes[0].name, address: "x@evil.example"))
    }

    /// With no quotes at all the words before the brackets are still the name: one mailbox
    /// whose name looks like an address, not two mailboxes.
    func testAnUnquotedAddressBeforeBracketsIsTheNameNotASecondMailbox() {
        let list = parse("noor@plan.example <x@evil.example>")
        XCTAssertEqual(list.items, [.mailbox(MailAddress(name: "noor@plan.example", address: "x@evil.example"))])
    }

    /// Two bracketed addresses in a row are two mailboxes: neither is hidden behind the other.
    func testTwoBracketedAddressesInARowAreTwoMailboxes() {
        let list = parse("Sam <sam@plan.example> <x@evil.example>")
        XCTAssertEqual(list.mailboxes.map(\.address), ["sam@plan.example", "x@evil.example"])
    }

    /// What an encoded word decodes to is a name and nothing else: it cannot add an address, a
    /// comma or a group, because the list was split before anything was decoded.
    func testAnEncodedWordThatDecodesToAnAddressAddsNoMailbox() {
        let angle = parse("=?utf-8?Q?Bob_=3Cevil=40x.com=3E?= <bob@example.com>")
        XCTAssertEqual(angle.mailboxes.map(\.address), ["bob@example.com"])
        XCTAssertEqual(angle.mailboxes.first?.name, "Bob <evil@x.com>")

        let comma = parse("=?utf-8?Q?a=2C_b=40x.com=3B_c=3A?= <real@y.com>")
        XCTAssertEqual(comma.items.count, 1)
        XCTAssertEqual(comma.mailboxes.map(\.address), ["real@y.com"])
    }

    /// `correspondent-poison`: a name planted on a lookalike address is the same name on a
    /// different address, and is kept as that: a name never decides who someone is.
    func testTheSameNameOnAnotherAddressIsAnotherPerson() {
        let real = parse("Jane Park <jane.park@plan.example>").mailboxes[0]
        let fake = parse(#""Jane Park" <jane.park@z0-ai.example>"#).mailboxes[0]
        XCTAssertEqual(real.name, fake.name)
        XCTAssertNotEqual(real.key, fake.key)
    }

    // MARK: - Domains

    func testAHomographDomainIsGivenInItsPunycodeForm() {
        let list = parse("Apple Support <support@\u{0430}pple.com>")
        XCTAssertEqual(list.mailboxes.map(\.address), ["support@xn--pple-43d.com"])
        XCTAssertNotEqual(list.mailboxes.first?.key, "support@apple.com")
    }

    func testAnInternationalDomainAndALocalPartInUnicodeAreRead() {
        XCTAssertEqual(parse("Bücher <info@bücher.de>").mailboxes.map(\.address), ["info@xn--bcher-kva.de"])
        XCTAssertEqual(parse("<üser@example.com>").mailboxes.map(\.address), ["üser@example.com"])
    }

    // MARK: - Right-to-left and zero-width

    func testDirectionControlsAndInvisibleCharactersAreRemovedFromANameAndKeptOutOfAnAddress() {
        let name = parse("\u{202E}Alice\u{200B} <a@x.com>")
        XCTAssertEqual(name.mailboxes.first?.name, "Alice")
        XCTAssertEqual(name.mailboxes.first?.address, "a@x.com")

        // In an address they are not removed — that would turn the sender's mailbox into a
        // different, real one — the address is refused and kept as unreadable.
        let address = parse("Sam <sam\u{200B}@plan.example>")
        XCTAssertTrue(address.mailboxes.isEmpty)
        XCTAssertTrue(address.hasUnreadable)
        XCTAssertTrue(parse("Sam <sam@plan.example\u{202E}>").mailboxes.isEmpty)
    }

    func testARightToLeftNameIsKeptWithoutItsControls() {
        let list = parse("\"\u{2067}שלום עולם\u{2069}\" <a@x.com>")
        XCTAssertEqual(list.mailboxes.first?.name, "שלום עולם")
    }

    // MARK: - Names with line breaks and controls

    func testAFoldedHeaderReadsLikeAnUnfoldedOne() {
        XCTAssertEqual(parse("Bob\r\n Smith\r\n <bob@example.com>").mailboxes.first?.name, "Bob Smith")
    }

    func testControlCharactersInANameAreNotKept() {
        let list = parse("\"a\u{0000}b\u{0007}c\" <x@y.com>")
        XCTAssertEqual(list.mailboxes.first?.name, "abc")
    }

    // MARK: - Incomplete input

    /// A value that was cut may end in half an address. "b@example.co" is a whole address and
    /// "b@example.com" cut at the o is not a different one, so the last piece goes either way.
    func testWhenTheTextWasCutTheLastPieceIsLeftOutAndTheListIsIncomplete() {
        let list = MailAddressList.parse("a@example.com, b@example.co", isComplete: false)
        XCTAssertEqual(list.mailboxes.map(\.address), ["a@example.com"])
        XCTAssertFalse(list.isComplete)
        let empty = MailAddressList.parse("", isComplete: false)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertFalse(empty.isComplete)
    }

    func testTextLongerThanTheReadersLimitIsReadToTheLimitAndSaidToBeIncomplete() {
        let entry = "a@example.com, "
        let count = MailAddressList.maxInputCharacters / entry.count + 10
        let list = parse(String(repeating: entry, count: count))
        XCTAssertFalse(list.isComplete)
        XCTAssertGreaterThan(list.mailboxes.count, 1_000)
        XCTAssertLessThanOrEqual(list.mailboxes.count, MailAddressList.maxInputCharacters / entry.count)
    }

    // MARK: - Size

    func testAHundredThousandCharacterWordIsOneUnreadablePieceCutShort() {
        let list = parse(String(repeating: "x", count: 100_000))
        XCTAssertEqual(list.items.count, 1)
        guard case .unreadable(let kept)? = list.items.first else { return XCTFail("expected unreadable") }
        XCTAssertEqual(kept.count, MailAddressList.maxUnreadableCharacters)
    }

    func testThousandsOfAddressesInOneFieldAreAllReadInOrder() {
        let text = (0..<5_000).map { "User \($0) <user\($0)@example.com>" }.joined(separator: ", ")
        let list = parse(text)
        XCTAssertEqual(list.mailboxes.count, 5_000)
        XCTAssertEqual(list.mailboxes.first?.address, "user0@example.com")
        XCTAssertEqual(list.mailboxes.last?.address, "user4999@example.com")
        XCTAssertEqual(list.mailboxes[1234].name, "User 1234")
        XCTAssertTrue(list.isComplete)
        XCTAssertFalse(list.hasUnreadable)
    }

    func testANameOfAHundredThousandCharactersIsReadAndThenNotShown() {
        let text = "\"" + String(repeating: "n", count: 100_000) + "\" <a@x.com>"
        let list = parse(text)
        XCTAssertEqual(list.mailboxes.map(\.address), ["a@x.com"])
        let person = list.mailboxes[0]
        XCTAssertNil(MailAddressRules.displayName(person.name, address: person.address),
                     "the address is shown: this is not a name")
    }
}
