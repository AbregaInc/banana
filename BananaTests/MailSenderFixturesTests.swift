import XCTest

/// The sender fixtures of MAIL-ENGINE 17.5 (the security review's P-13), `header-1mb`, and the
/// fixtures P03a's code review added for the four ways a reader can be kinder than its own rule,
/// each run through the whole of what P03a reads: the wire model, the headers, the address list,
/// the name rule, and **`MessageHeaders.sender`**, the one reading of who a message is from.
///
/// **The fixtures are written by hand from Gmail's documented shapes; none is captured from a
/// live mailbox.** What each test shows is what the code does with that shape: what a person
/// would be shown, and that what the sender put apart is still apart. No test here takes
/// `mailboxes.first` of a `From` as the sender.
final class MailSenderFixturesTests: XCTestCase {

    private func headers(_ json: String) throws -> MessageHeaders {
        MessageHeaders(payload: try MailHostileMessages.decode(json).payload)
    }

    /// What the conversation header would show for a mailbox: its name if the name may be
    /// shown, else its address.
    private func shown(_ person: MailAddress) -> String {
        MailAddressRules.displayName(person.name, address: person.address) ?? person.address
    }

    private let victim = "ceo@victim.example"

    // MARK: - The set

    func testEveryFixtureIsAWholeMessageThatDecodesAsAGmailMessage() throws {
        let names = MailHostileMessages.senderAndHeaderSet.map(\.name)
        XCTAssertEqual(Array(names.prefix(7)),
                       ["from-name-is-address", "from-rlo-subject", "from-homograph-domain",
                        "reply-to-elsewhere", "correspondent-poison", "header-injection-reply", "header-1mb"],
                       "the seven of 17.5, in its order")
        XCTAssertEqual(Set(names).count, names.count, "names are unique")
        XCTAssertEqual(names.count, 21)
        for (name, json) in MailHostileMessages.senderAndHeaderSet {
            let message = try MailHostileMessages.decode(json)
            XCTAssertNotNil(message.id, name)
            XCTAssertEqual(message.threadId, message.id, name)
            XCTAssertEqual(message.labelIds, ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], name)
            XCTAssertNotNil(message.historyId, name)
            XCTAssertNotNil(message.internalDate, name)
            XCTAssertEqual(message.payload?.mimeType, "text/plain", name)
            XCTAssertFalse(message.payload?.headers?.isEmpty ?? true, name)
            XCTAssertEqual(message.payload?.body?.data, "SGVsbG8u", name)
        }
    }

    func testTheFixtureIdsAreDistinct() throws {
        let ids = try MailHostileMessages.senderAndHeaderSet.map { try MailHostileMessages.decode($0.json).id }
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, ids.count)
    }

    /// The registry is where the HTML and screen packages find the set.
    func testTheSetIsRegisteredWhereTheOtherPackagesReadIt() {
        let registered = MailSlices.hostileMessageSets.flatMap { $0() }.map(\.name)
        XCTAssertEqual(Set(registered), Set(MailHostileMessages.senderAndHeaderSet.map(\.name)))
    }

    // MARK: - The six

    func testFromNameIsAddressShowsTheAddress() throws {
        let h = try headers(MailHostileMessages.fromNameIsAddress)
        let from = try XCTUnwrap(h.sender)
        XCTAssertEqual(from.name, "noor@plan.example", "the name is kept, as written")
        XCTAssertEqual(from.address, "x@evil.example", "and the address is the one the message came from")
        XCTAssertEqual(shown(from), "x@evil.example", "what is shown is the address, not the name")
        XCTAssertEqual(h.deliveredTo.mailboxes.map(\.address), ["noor@plan.example"],
                       "his own address is where it was delivered, a separate thing")
        XCTAssertNotEqual(from.key, "noor@plan.example")
    }

    func testFromRLOSubjectLosesItsOverride() throws {
        let h = try headers(MailHostileMessages.fromRLOSubject)
        XCTAssertTrue(h.value("Subject")?.contains("\u{202E}") == true, "the fixture does carry the override")
        XCTAssertEqual(h.subject, "Invoice fdp.exe")
        XCTAssertFalse(h.subject?.unicodeScalars.contains("\u{202E}") ?? true)
        XCTAssertEqual(shown(try XCTUnwrap(h.sender)), "Accounts")
    }

    func testFromHomographDomainIsGivenAsPunycode() throws {
        let h = try headers(MailHostileMessages.fromHomographDomain)
        let from = try XCTUnwrap(h.sender)
        XCTAssertEqual(from.address, "support@xn--pple-43d.com")
        XCTAssertNotEqual(from.key, "support@apple.com", "it is not apple.com")
        XCTAssertEqual(from.name, "Apple Support")
        XCTAssertFalse(from.address.unicodeScalars.contains { $0.value > 0x7F }, "no non-ASCII reaches the UI")
        XCTAssertTrue(h.value("From")?.unicodeScalars.contains("\u{0430}") == true, "the fixture does carry the Cyrillic letter")
    }

    func testReplyToElsewhereKeepsBothAddressesAndNeverMergesThem() throws {
        let h = try headers(MailHostileMessages.replyToElsewhere)
        let from = try XCTUnwrap(h.sender)
        let replyTo = try XCTUnwrap(h.replyTo.mailboxes.first)
        XCTAssertEqual(from.address, "alice@example.com")
        XCTAssertEqual(replyTo.address, "alice.replies@other.example")
        XCTAssertNotEqual(from.key, replyTo.key)
        XCTAssertEqual(from.name, "Alice Example")
        XCTAssertEqual(replyTo.name, "Alice")
        XCTAssertEqual(h.replyTo.mailboxes.count, 1)
    }

    func testCorrespondentPoisonKeepsTheNameApartFromTheLookalikeAddress() throws {
        let h = try headers(MailHostileMessages.correspondentPoison)
        let from = try XCTUnwrap(h.sender)
        XCTAssertEqual(from.name, "Jane Park")
        XCTAssertEqual(from.address, "jane.park@z0-ai.example")
        // The Jane he writes to, at his own domain, is somebody else by key.
        let real = try XCTUnwrap(MailAddressList.parse("Jane Park <jane.park@plan.example>").mailboxes.first)
        XCTAssertEqual(real.name, from.name)
        XCTAssertNotEqual(real.key, from.key, "a name decides nothing about who someone is")
    }

    func testHeaderInjectionReplyLeavesNoLineBreakAndAddsNoAddress() throws {
        let h = try headers(MailHostileMessages.headerInjectionReply)
        XCTAssertTrue(h.value("Subject")?.contains("\r\n") == true, "the fixture does carry the break")
        XCTAssertEqual(h.subject, "Re: invoice Bcc: attacker@evil.example")
        XCTAssertFalse(h.subject?.contains(where: { $0.isNewline }) ?? true)

        let to = h.to
        XCTAssertEqual(to.mailboxes.count, 1, "the injected Bcc is no recipient")
        XCTAssertEqual(to.mailboxes.first?.address, "team@example.net")
        XCTAssertEqual(to.mailboxes.first?.name, "Team Bcc: attacker@evil.example")
        XCTAssertFalse(to.mailboxes.first?.name?.contains(where: { $0.isNewline }) ?? true)
        XCTAssertNil(MailAddressRules.displayName(to.mailboxes.first?.name, address: "team@example.net"),
                     "a name holding an address is not shown")
        XCTAssertTrue(h.bcc.items.isEmpty, "and there is no Bcc header")
        XCTAssertFalse(h.contains("Bcc"))
        XCTAssertEqual(h.sender?.address, "mallory@example.net")
    }

    // MARK: - MAJOR 1: what is in quotes is a name, never an address

    func testQuotedNameAndBareAddressIsOneMailboxWhoseNameIsAnAddressThatIsNotShown() throws {
        let h = try headers(MailHostileMessages.fromQuotedNameAndBareAddress)
        let list = h.addresses("From")
        XCTAssertEqual(list.items, [.mailbox(MailAddress(name: victim, address: "attacker@evil.example"))])
        let from = try XCTUnwrap(h.sender)
        XCTAssertEqual(from.address, "attacker@evil.example", "the victim is not the sender")
        XCTAssertEqual(shown(from), "attacker@evil.example", "and the victim's address is not shown as a name")
    }

    func testQuotedNameOnlyHoldsNoAddressAndTheSenderIsUnreadable() throws {
        let h = try headers(MailHostileMessages.fromQuotedNameOnly)
        XCTAssertTrue(h.addresses("From").mailboxes.isEmpty)
        XCTAssertTrue(h.addresses("From").hasUnreadable)
        XCTAssertNil(h.sender)
    }

    func testQuotedGroupNameIsAGroupOfOneAndAGroupIsNoSender() throws {
        let h = try headers(MailHostileMessages.fromQuotedGroupName)
        let list = h.addresses("From")
        XCTAssertEqual(list.mailboxes.map(\.address), ["a@evil.example"], "a standard reader's reading: the attacker's own")
        XCTAssertTrue(list.hasGroup)
        XCTAssertNil(h.sender)
    }

    func testTwoBareAddressesWithNoCommaAreOneUnreadableItemAndNoSender() throws {
        let h = try headers(MailHostileMessages.fromTwoBareAddresses)
        let list = h.addresses("From")
        XCTAssertTrue(list.mailboxes.isEmpty)
        XCTAssertEqual(list.items.count, 1)
        XCTAssertNil(h.sender)
    }

    func testNoFixtureOfTheFirstTableMakesTheVictimTheSender() throws {
        for json in [MailHostileMessages.fromQuotedNameAndBareAddress, MailHostileMessages.fromQuotedNameOnly,
                     MailHostileMessages.fromQuotedGroupName, MailHostileMessages.fromTwoBareAddresses] {
            XCTAssertNotEqual(try headers(json).sender?.address, victim)
        }
    }

    // MARK: - MAJOR 2: exactly one mailbox, or the unreadable sender

    func testTwoBracketedAddressesAreTwoMailboxesAndNoSender() throws {
        let h = try headers(MailHostileMessages.fromTwoBrackets)
        XCTAssertEqual(h.addresses("From").mailboxes.map(\.address), ["sam@plan.example", "x@evil.example"])
        XCTAssertNil(h.sender, "the first is the one a forger chose to put there")
    }

    func testABracketedAddressWithABareOneJoinedOnIsNoSender() throws {
        let h = try headers(MailHostileMessages.fromBracketThenBare)
        XCTAssertEqual(h.addresses("From").mailboxes.map(\.address), ["sam@plan.example", "x@evil.example"])
        XCTAssertNil(h.sender)
    }

    func testTwoFromHeadersAreNoSender() throws {
        let h = try headers(MailHostileMessages.fromTwoHeaders)
        XCTAssertEqual(h.values("From").count, 2)
        XCTAssertEqual(h.fromHeaderCount, 2)
        XCTAssertNil(h.sender)
    }

    func testGmailsOwnDMARCResultNamingAnotherDomainMakesTheSenderUnreadable() throws {
        let h = try headers(MailHostileMessages.fromDMARCDisagrees)
        XCTAssertEqual(h.addresses("From").mailboxes.map(\.address), ["boss@victim.example"], "what this reader read")
        XCTAssertFalse(MailAuthRules.dmarcAgrees(headers: h, with: "victim.example"), "and Gmail's header names evil.example")
        XCTAssertNil(h.sender, "two readers of one line, disagreeing: neither is shown")
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: h, fromDomain: "victim.example"),
                     "and nothing is authenticated for the domain this reader read")
        XCTAssertEqual(MailAuthRules.authenticatedDomain(headers: h, fromDomain: "evil.example"), "evil.example",
                       "the domain Gmail did authenticate is the one it named")
    }

    // MARK: - MAJOR 3: what an address may contain

    func testALookAlikeAtSignInTheLocalPartMakesTheSenderUnreadable() throws {
        let h = try headers(MailHostileMessages.fromFullwidthAtLocalPart)
        let list = h.addresses("From")
        XCTAssertTrue(list.mailboxes.isEmpty)
        XCTAssertTrue(list.hasUnreadable)
        XCTAssertNil(h.sender)
    }

    func testAnInvisibleCharacterInTheLocalPartMakesTheSenderUnreadable() throws {
        for json in [MailHostileMessages.fromVariationSelectorLocalPart, MailHostileMessages.fromHangulFillerLocalPart] {
            let h = try headers(json)
            XCTAssertTrue(h.addresses("From").mailboxes.isEmpty)
            XCTAssertTrue(h.addresses("From").hasUnreadable)
            XCTAssertNil(h.sender)
        }
    }

    func testAMixedScriptLocalPartMakesTheSenderUnreadable() throws {
        let h = try headers(MailHostileMessages.fromMixedScriptLocalPart)
        XCTAssertTrue(h.addresses("From").mailboxes.isEmpty)
        XCTAssertNil(h.sender)
    }

    // MARK: - MAJOR 4: only the first Authentication-Results, and only if it is Gmail's

    func testAForgedHeaderBelowAnotherServersAuthenticatesNobodyAndTheSenderIsStillRead() throws {
        let h = try headers(MailHostileMessages.authResultsForgedBelowOtherServer)
        XCTAssertEqual(h.values("Authentication-Results").count, 2)
        XCTAssertNil(MailAuthRules.authenticatedDomain(headers: h, fromDomain: "victim.example"))
        XCTAssertEqual(h.sender?.address, "boss@victim.example", "an unauthenticated sender is still a sender")
    }

    // MARK: - header-1mb, and what is known past the cut

    func testTheHeader1MBSenderIsFoundAfterFiveThousandLines() throws {
        let h = try headers(MailHostileMessages.header1MB())
        XCTAssertEqual(h.sender?.address, "sender@example.com")
        XCTAssertFalse(h.isComplete)
    }

    func testTwoFromsAfterFiveThousandLinesAreNoSender() throws {
        let h = try headers(MailHostileMessages.header1MB(twoFroms: true))
        XCTAssertNil(h.sender)
    }

    // MARK: - The pieces, through the same messages

    func testEverySenderFixtureThatIsReadableHasExactlyOneFromHeader() throws {
        for (name, json) in MailHostileMessages.senderAndHeaderSet {
            let h = try headers(json)
            if name == "from-two-headers" || name == "header-1mb-two-froms" {
                XCTAssertEqual(h.fromHeaderCount, 2, name)
            } else {
                XCTAssertEqual(h.fromHeaderCount, 1, name)
            }
        }
    }
}
