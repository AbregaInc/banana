import XCTest

/// Who a message is from: `MessageHeaders.sender`, the one reading, and nothing else takes an
/// address out of `From` (MAIL-ENGINE 10.8, L12).
///
/// A single mailbox or nothing. It answers a mailbox only when Gmail sent exactly one `From`,
/// its value was not cut, it reads as exactly one mailbox with nothing left over and no group,
/// the address is one an address may be, and Gmail's own `dmarc=` result, where there is one,
/// names the same domain. Otherwise there is the unreadable sender, one state however it came
/// about. **In every shape with more than one mailbox the first is the one a forger chose to put
/// there**, so no test here, and no code, takes the first of several.
final class MailSenderTests: XCTestCase {

    private func sender(_ from: String, auth: String? = nil, more: [(String, String)] = []) -> MailAddress? {
        var pairs: [(String, String)] = []
        if let auth { pairs.append(("Authentication-Results", auth)) }
        pairs.append(("From", from))
        pairs += more
        return MessageHeaders(pairs).sender
    }

    // MARK: - Exactly one mailbox

    func testOneMailboxIsTheSenderWithItsNameAsWritten() {
        XCTAssertEqual(sender("Bob Smith <bob@example.com>"), MailAddress(name: "Bob Smith", address: "bob@example.com"))
        XCTAssertEqual(sender("bob@example.com"), MailAddress(name: nil, address: "bob@example.com"))
        XCTAssertEqual(sender("<bob@example.com>"), MailAddress(name: nil, address: "bob@example.com"))
        XCTAssertEqual(sender("bob@example.com (Bob)"), MailAddress(name: "Bob", address: "bob@example.com"))
        XCTAssertEqual(sender(#""Smith, Bob" <bob@example.com>"#), MailAddress(name: "Smith, Bob", address: "bob@example.com"))
        XCTAssertEqual(sender("=?UTF-8?B?Q2Fmw6k=?= <cafe@example.com>")?.name, "Café")
    }

    func testTheSenderIsAnAddressTheAddressRulesAccept() {
        XCTAssertEqual(sender("Bücher <info@bücher.de>")?.address, "info@xn--bcher-kva.de")
        XCTAssertEqual(sender("\u{674E}\u{96F7} <\u{674E}\u{96F7}@example.cn>")?.address, "\u{674E}\u{96F7}@example.cn")
    }

    func testNoFromIsTheUnreadableSender() {
        XCTAssertNil(MessageHeaders([("To", "noor@plan.example"), ("Subject", "x")]).sender)
        XCTAssertNil(MessageHeaders([]).sender)
        XCTAssertNil(MessageHeaders.unread.sender)
        XCTAssertNil(MessageHeaders(payload: GmailPart(partId: "")).sender, "headers that were never read")
    }

    func testAnEmptyOrWhitespaceFromIsTheUnreadableSender() {
        for value in ["", "   ", ",", ";", "()", "\"\""] {
            XCTAssertNil(sender(value), value.debugDescription)
        }
    }

    // MARK: - More than one is never the first

    func testTwoMailboxesInOneFromAreNoSender() {
        for value in ["Sam <sam@plan.example> <x@evil.example>", "<sam@plan.example>x@evil.example", "a@x.com, b@x.com",
                      "a@x.com; b@x.com", "Sam <sam@plan.example>, Mallory <x@evil.example>"] {
            XCTAssertNil(sender(value), value)
        }
    }

    func testTwoFromHeadersAreNoSenderWhicheverIsFirst() {
        XCTAssertNil(MessageHeaders([("From", "Sam <sam@plan.example>"), ("From", "Mallory <x@evil.example>")]).sender)
        XCTAssertNil(MessageHeaders([("From", "Mallory <x@evil.example>"), ("From", "Sam <sam@plan.example>")]).sender)
        XCTAssertNil(MessageHeaders([("From", "same@plan.example"), ("from", "same@plan.example")]).sender,
                     "even when they agree: one From header, exactly")
    }

    func testAMailboxWithAnythingLeftOverThatCouldNotBeReadIsNoSender() {
        XCTAssertNil(sender("Bob <bob@example.com> junk"))
        XCTAssertNil(sender("Bob <bob@example.com>, nonsense"))
        XCTAssertNil(sender("nonsense, Bob <bob@example.com>"))
    }

    func testAGroupIsNoSenderWhetherOrNotItHasOneMember() {
        XCTAssertNil(sender("Team: a@x.com;"))
        XCTAssertNil(sender("Team: a@x.com, b@x.com;"))
        XCTAssertNil(sender("undisclosed-recipients:;"))
        XCTAssertNil(sender(#""ceo@victim.example": a@evil.example;"#))
    }

    // MARK: - What is not an address, and what is in quotes

    func testAnAddressThatIsNotOneIsNoSender() {
        for value in ["Bob <bob@localhost>", "Bob <bob@>", "Bob <@example.com>", "Bob <bob example@example.com>",
                      "Sam <sam\u{200B}@plan.example>", "Sam <sam\u{FE00}@plan.example>", "Sam <sam\u{3164}@plan.example>",
                      "x <noor\u{FF20}plan.example@evil.example>", "Noor <n\u{043E}or@plan.example>", "<mailto:x@y.z>",
                      "\"a b\"@example.com", "Bob <bob@exam\u{FF45}ple.com>"] {
            XCTAssertNil(sender(value), value.debugDescription)
        }
    }

    /// Text that could not be read is never put where a sender goes: it may be `Noor <noor@plan.example`.
    func testWhatCouldNotBeReadIsNeverTheSender() {
        XCTAssertNil(sender("Noor <noor@plan.example"))
        XCTAssertNil(sender("Noor noor@z0"))
    }

    func testAQuotedStringIsAnAddressNowhere() {
        XCTAssertNil(sender(#""ceo@victim.example""#))
        XCTAssertNil(sender(#""ceo@victim.example" x"#))
        XCTAssertNil(sender("ceo@victim.example a@evil.example"))
        XCTAssertEqual(sender(#""ceo@victim.example" attacker@evil.example"#)?.address, "attacker@evil.example")
    }

    // MARK: - Cut

    func testAFromWhoseValueWasCutIsNoSenderEvenWhenItsFirstPartIsAnAddress() {
        let value = "Sam <sam@plan.example>" + String(repeating: " ", count: MessageHeaders.maxValueBytes) + "x"
        let h = MessageHeaders([("From", value)])
        XCTAssertEqual(h.field("From")?.wasCut, true)
        XCTAssertNil(h.sender)
    }

    func testAFromWithNoValueIsNoSender() {
        let h = MessageHeaders(payload: GmailPart(headers: [GmailHeader(name: "From", value: nil)]))
        XCTAssertNil(h.sender)
        XCTAssertEqual(h.fromHeaderCount, 1)
    }

    // MARK: - Gmail's own DMARC result

    private func gmail(_ results: String) -> String { "mx.google.com; " + results }

    func testAMatchingDMARCResultLeavesTheSender() {
        XCTAssertEqual(sender("Sam <sam@plan.example>", auth: gmail("dmarc=pass header.from=plan.example"))?.address, "sam@plan.example")
        XCTAssertEqual(sender("Sam <sam@plan.example>", auth: gmail("dmarc=fail header.from=PLAN.EXAMPLE."))?.address, "sam@plan.example",
                       "the verdict does not matter, only whose line Gmail says it read")
        XCTAssertEqual(sender("Sam <sam@bücher.de>", auth: gmail("dmarc=pass header.from=xn--bcher-kva.de"))?.address,
                       "sam@xn--bcher-kva.de")
    }

    func testADMARCResultNamingAnotherDomainMakesTheSenderUnreadable() {
        XCTAssertNil(sender("Sam <sam@plan.example>", auth: gmail("dmarc=pass header.from=evil.example")))
        XCTAssertNil(sender("Sam <sam@plan.example>", auth: gmail("dmarc=none header.from=mail.plan.example")))
        XCTAssertNil(sender("Sam <sam@mail.plan.example>", auth: gmail("dmarc=pass header.from=plan.example")), "DMARC names the domain exactly")
        XCTAssertNil(sender("Sam <sam@plan.example>", auth: gmail("dmarc=pass")), "a DMARC result that names no domain")
    }

    func testAHeaderThatIsNotGmailsOrHasNoDMARCResultSaysNothingAboutTheSender() {
        XCTAssertEqual(sender("Sam <sam@plan.example>", auth: gmail("spf=pass smtp.mailfrom=sam@plan.example"))?.address, "sam@plan.example")
        XCTAssertEqual(sender("Sam <sam@plan.example>", auth: "mx.other.example; dmarc=pass header.from=evil.example")?.address,
                       "sam@plan.example", "another server's header is not what Gmail read")
        // And only the first header: a second, whatever it says, is not consulted.
        XCTAssertEqual(sender("Sam <sam@plan.example>", auth: gmail("spf=pass"),
                              more: [("Authentication-Results", gmail("dmarc=pass header.from=evil.example"))])?.address,
                       "sam@plan.example")
    }

    func testAGmailHeaderThatWasCutLeavesNoSender() {
        let long = gmail("dmarc=pass header.from=plan.example; ") + String(repeating: "y", count: MessageHeaders.maxValueBytes)
        XCTAssertNil(sender("Sam <sam@plan.example>", auth: long), "what Gmail said about whose it is cannot be read")
    }

    // MARK: - Past the cut

    func testASenderPastTheLineLimitIsStillTheSenderAndAnAuthenticationHeaderPastItIsNotRead() {
        let padding = (0..<MessageHeaders.maxLines).map { ("Received", "hop \($0)") }
        let h = MessageHeaders(padding + [("From", "Sam <sam@plan.example>"),
                                          ("Authentication-Results", gmail("dmarc=pass header.from=evil.example"))])
        XCTAssertEqual(h.sender?.address, "sam@plan.example", "its disagreeing header is not looked for past the cut")
        XCTAssertNil(h.field("Authentication-Results"))
    }

    // MARK: - Not the first of anything

    /// The mailboxes of a `From` list stay readable for what they are, a list; but the reading
    /// that is the sender is a different thing, and it is nil wherever the list is not one.
    func testTheListAndTheSenderAreDifferentReadings() {
        let h = MessageHeaders([("From", "Sam <sam@plan.example> <x@evil.example>")])
        XCTAssertEqual(h.addresses("From").mailboxes.map(\.address), ["sam@plan.example", "x@evil.example"])
        XCTAssertNil(h.sender)
    }
}
