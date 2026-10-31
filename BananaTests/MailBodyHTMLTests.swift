import XCTest

/// What a message he wrote is, sent: the HTML and the plain text made from it. The serialiser is
/// written by hand because nothing in the system makes mail-safe HTML, so these hold every
/// construct, their nesting, what is escaped, a link whose scheme is not allowed, and a body with
/// nothing in it. The allow-list is the point: only `p`, `br`, `b`, `i`, `u`, `a href`, `ul`, `ol`,
/// `li` and `blockquote` are ever written.
final class MailBodyHTMLTests: XCTestCase {

    // MARK: Making a body

    private func run(_ text: String, _ style: MailTextStyle = [], link: String? = nil) -> MailTextRun {
        MailTextRun(text: text, style: style, link: link.flatMap { URL(string: $0) })
    }

    private func line(_ runs: MailTextRun...) -> MailTextBlock {
        MailTextBlock(kind: .paragraph, runs: runs)
    }

    private func line(_ text: String) -> MailTextBlock {
        MailTextBlock(kind: .paragraph, runs: text.isEmpty ? [] : [run(text)])
    }

    private func bullet(_ text: String) -> MailTextBlock {
        MailTextBlock(kind: .item(ordered: false, depth: 0, number: nil), runs: [run(text)])
    }

    private func number(_ text: String, _ n: Int) -> MailTextBlock {
        MailTextBlock(kind: .item(ordered: true, depth: 0, number: n), runs: [run(text)])
    }

    private func quote(_ text: String, depth: Int = 1) -> MailTextBlock {
        MailTextBlock(kind: .quote(depth: depth), runs: text.isEmpty ? [] : [run(text)])
    }

    private func html(_ blocks: MailTextBlock...) -> String { MailBodyHTML.html(MailText(blocks: blocks)) }
    private func plain(_ blocks: MailTextBlock...) -> String { MailBodyHTML.plain(MailText(blocks: blocks)) }

    // MARK: Paragraphs

    func testAParagraphIsAParagraphInBothForms() {
        XCTAssertEqual(html(line("Hello")), "<p>Hello</p>")
        XCTAssertEqual(plain(line("Hello")), "Hello")
    }

    func testLinesTypedOneAfterTheOtherAreOneParagraphWithLineBreaks() {
        XCTAssertEqual(html(line("one"), line("two"), line("three")), "<p>one<br>two<br>three</p>")
        XCTAssertEqual(plain(line("one"), line("two"), line("three")), "one\ntwo\nthree")
    }

    func testABlankLineSeparatesParagraphsAndMoreBlankLinesAreKept() {
        XCTAssertEqual(html(line("a"), line(""), line("b")), "<p>a</p><p>b</p>")
        XCTAssertEqual(html(line("a"), line(""), line(""), line("b")), "<p>a</p><p><br></p><p>b</p>")
        XCTAssertEqual(html(line("a"), line(""), line(""), line(""), line("b")),
                       "<p>a</p><p><br></p><p><br></p><p>b</p>")
        XCTAssertEqual(plain(line("a"), line(""), line("b")), "a\n\nb")
    }

    func testBlankLinesBeforeAndAfterWhatHeSaidAreNotSent() {
        XCTAssertEqual(html(line(""), line(" "), line("a"), line(""), line("")), "<p>a</p>")
        XCTAssertEqual(plain(line(""), line("a"), line(""), line("")), "a")
    }

    func testSpacesAReaderWouldFoldAwayAreKept() {
        XCTAssertEqual(html(line("a  b")), "<p>a &nbsp;b</p>")
        XCTAssertEqual(html(line("  indented")), "<p>&nbsp;&nbsp;indented</p>")
        XCTAssertEqual(html(line("a   b")), "<p>a &nbsp;&nbsp;b</p>")
        XCTAssertEqual(html(line(run("bold", .bold), run(" next"))), "<p><b>bold</b> next</p>",
                       "one space between two runs is one space")
    }

    // MARK: Emptiness

    func testNothingAtAllIsTheEmptyStringInBothForms() {
        XCTAssertEqual(MailBodyHTML.html(MailText(blocks: [])), "")
        XCTAssertEqual(MailBodyHTML.plain(MailText(blocks: [])), "")
    }

    func testABodyOfWhiteSpaceAloneIsEmptyInBothForms() {
        let blocks = [line(" "), line("\t"), line(run("  ", .bold)), bullet(" "), quote(" ")]
        XCTAssertEqual(MailBodyHTML.html(MailText(blocks: blocks)), "")
        XCTAssertEqual(MailBodyHTML.plain(MailText(blocks: blocks)), "")
        XCTAssertEqual(MailBodyHTML.html(from: AttributedString("  \n \n")), "")
        XCTAssertEqual(MailBodyHTML.plain(from: AttributedString("  \n \n")), "")
    }

    // MARK: Styles

    func testBoldItalicUnderlineAreTheirTags() {
        XCTAssertEqual(html(line(run("b", .bold))), "<p><b>b</b></p>")
        XCTAssertEqual(html(line(run("i", .italic))), "<p><i>i</i></p>")
        XCTAssertEqual(html(line(run("u", .underline))), "<p><u>u</u></p>")
    }

    func testStylesNestInOneFixedOrderAndNeighboursWithTheSameLookAreOne() {
        XCTAssertEqual(html(line(run("all", [.bold, .italic, .underline]))), "<p><b><i><u>all</u></i></b></p>")
        XCTAssertEqual(html(line(run("a", .bold), run("b", .bold))), "<p><b>ab</b></p>")
        XCTAssertEqual(html(line(run("plain "), run("bold", .bold), run(" and "), run("italic", .italic))),
                       "<p>plain <b>bold</b> and <i>italic</i></p>")
    }

    func testWhatTheSetOfTagsHasNoPlaceForIsDropped() {
        // Strikethrough and code are not in the allow-list.
        XCTAssertEqual(html(line(run("struck", .strikethrough), run(" "), run("code", .code))), "<p>struck code</p>")
    }

    func testStylesAreNotInThePlainText() {
        XCTAssertEqual(plain(line(run("bold", .bold), run(" and "), run("italic", .italic))), "bold and italic")
    }

    // MARK: Links

    func testALinkIsAnAnchorWithItsAddressAndIsNotAlsoUnderlined() {
        XCTAssertEqual(html(line(run("here", link: "https://example.com/a"))),
                       "<p><a href=\"https://example.com/a\">here</a></p>")
        XCTAssertEqual(html(line(run("here", [.underline, .bold], link: "https://example.com"))),
                       "<p><a href=\"https://example.com\"><b>here</b></a></p>",
                       "a link is already underlined")
    }

    func testAnAddressWithAmpersandsAndQuotesIsEscapedInTheAttribute() {
        let url = "https://example.com/a?b=1&c=%22x%22"
        XCTAssertEqual(html(line(run("q", link: url))),
                       "<p><a href=\"https://example.com/a?b=1&amp;c=%22x%22\">q</a></p>")
    }

    func testHttpHttpsAndMailtoAreTheOnlyLinks() {
        for address in ["http://example.com", "https://example.com", "mailto:sam@lee.example", "HTTPS://Example.com/x"] {
            XCTAssertTrue(html(line(run("x", link: address))).contains("<a href="), address)
            XCTAssertNotNil(MailBodyHTML.safeLink(URL(string: address)), address)
        }
    }

    func testAHostileOrUnknownSchemeIsNotALinkAndTheWordsAreOnlyWords() {
        let hostile = [
            "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html;base64,PHNjcmlwdD4=", "file:///etc/passwd",
            "vbscript:msgbox", "ftp://example.com", "tel:+15551234", "sms:+15551234", "x-apple-reminderkit://", "blob:https://x",
            "//example.com", "example.com", "java%09script:alert(1)", "http://", "https:///path", "mailto:",
            "https://exa mple.com",
        ]
        for address in hostile {
            let out = html(line(run("the words", link: address)))
            XCTAssertEqual(out, "<p>the words</p>", address)
            XCTAssertEqual(plain(line(run("the words", link: address))), "the words", address)
            XCTAssertNil(MailBodyHTML.safeLink(URL(string: address)), address)
        }
        XCTAssertNil(MailBodyHTML.safeLink(nil))
    }

    func testLinksInPlainTextAreTheWordsAndTheAddress() {
        XCTAssertEqual(plain(line(run("the report", link: "https://example.com/r"))),
                       "the report (https://example.com/r)")
        XCTAssertEqual(plain(line(run("https://example.com", link: "https://example.com"))), "https://example.com",
                       "an address that is the link's words says itself once")
        XCTAssertEqual(plain(line(run("write to me", link: "mailto:noor@plan.example"))), "write to me (noor@plan.example)")
        XCTAssertEqual(plain(line(run("noor@plan.example", link: "mailto:noor@plan.example"))), "noor@plan.example")
        XCTAssertEqual(plain(line(run("see "), run("this", .bold, link: "http://x.example"), run(" now"))),
                       "see this (http://x.example) now")
    }

    // MARK: Escaping

    func testEverythingThatCouldBeMarkupIsEscaped() {
        XCTAssertEqual(html(line("<script>alert('x' & \"y\")</script>")),
                       "<p>&lt;script&gt;alert(&#39;x&#39; &amp; &quot;y&quot;)&lt;/script&gt;</p>")
        XCTAssertEqual(html(line("5 < 6 > 4 & 2")), "<p>5 &lt; 6 &gt; 4 &amp; 2</p>")
        XCTAssertEqual(plain(line("5 < 6 & 2")), "5 < 6 & 2", "plain text is not escaped")
    }

    func testAnEntityHeTypedIsNotDecoded() {
        XCTAssertEqual(html(line("&amp; &lt;b&gt;")), "<p>&amp;amp; &amp;lt;b&amp;gt;</p>")
    }

    func testALineBreakInsideARunIsABreak() {
        XCTAssertEqual(html(line(run("a\nb"))), "<p>a<br>b</p>")
    }

    // MARK: Lists

    func testBulletsAndNumbersAreListsAndItemsAreEscaped() {
        XCTAssertEqual(html(bullet("one"), bullet("two & three")), "<ul><li>one</li><li>two &amp; three</li></ul>")
        XCTAssertEqual(html(number("first", 1), number("second", 2)), "<ol><li>first</li><li>second</li></ol>")
        XCTAssertEqual(plain(bullet("one"), bullet("two")), "- one\n- two")
        XCTAssertEqual(plain(number("first", 1), number("second", 2)), "1. first\n2. second")
    }

    func testPlainTextNumbersCountFromOneInEachList() {
        XCTAssertEqual(plain(number("x", 4), number("y", 9), line("break"), number("z", 3)), "1. x\n2. y\nbreak\n1. z")
    }

    func testAListBetweenParagraphsClosesAndOpensThem() {
        XCTAssertEqual(html(line("Before"), bullet("a"), bullet("b"), line("After")),
                       "<p>Before</p><ul><li>a</li><li>b</li></ul><p>After</p>")
        XCTAssertEqual(html(line("Before"), line(""), bullet("a"), line(""), line("After")),
                       "<p>Before</p><ul><li>a</li></ul><p>After</p>")
    }

    func testABulletedListFollowedByANumberedListAreTwoLists() {
        XCTAssertEqual(html(bullet("a"), number("b", 1)), "<ul><li>a</li></ul><ol><li>b</li></ol>")
    }

    func testAListItemMayHaveStylesAndALink() {
        let item = MailTextBlock(kind: .item(ordered: false, depth: 0, number: nil),
                                 runs: [run("see "), run("this", .bold, link: "https://example.com")])
        XCTAssertEqual(html(item), "<ul><li>see <a href=\"https://example.com\"><b>this</b></a></li></ul>")
    }

    func testAnItemWithNothingInItIsNotALine() {
        XCTAssertEqual(html(bullet("a"), MailTextBlock(kind: .item(ordered: false, depth: 0, number: nil), runs: []),
                            bullet("b")), "<ul><li>a</li><li>b</li></ul>")
    }

    // MARK: Quotes

    func testAQuoteIsABlockquoteAndItsLinesAreOneParagraph() {
        XCTAssertEqual(html(quote("a"), quote("b")), "<blockquote><p>a<br>b</p></blockquote>")
        XCTAssertEqual(plain(quote("a"), quote("b")), "> a\n> b")
    }

    func testABlankLineInAQuoteSeparatesItsParagraphs() {
        XCTAssertEqual(html(quote("a"), quote(""), quote("b")), "<blockquote><p>a</p><p>b</p></blockquote>")
        XCTAssertEqual(plain(quote("a"), quote(""), quote("b")), "> a\n>\n> b")
    }

    func testAQuoteOfAQuoteNests() {
        XCTAssertEqual(html(quote("outer"), quote("inner", depth: 2), quote("outer again")),
                       "<blockquote><p>outer</p><blockquote><p>inner</p></blockquote><p>outer again</p></blockquote>")
        XCTAssertEqual(html(quote("deep", depth: 2)), "<blockquote><blockquote><p>deep</p></blockquote></blockquote>")
        XCTAssertEqual(plain(quote("outer"), quote("inner", depth: 2)), "> outer\n>> inner")
    }

    func testAQuoteBetweenParagraphsAndBeforeAList() {
        XCTAssertEqual(html(line("He wrote:"), quote("yes"), line("I agree."), bullet("a")),
                       "<p>He wrote:</p><blockquote><p>yes</p></blockquote><p>I agree.</p><ul><li>a</li></ul>")
    }

    func testAQuoteIsNeverDeeperThanFive() {
        let deep = html(quote("x", depth: 40))
        XCTAssertEqual(deep.components(separatedBy: "<blockquote>").count - 1, 5)
        XCTAssertEqual(deep.components(separatedBy: "</blockquote>").count - 1, 5)
    }

    // MARK: Nothing outside the allow-list is ever written

    func testOnlyTheAllowedTagsAreEverWritten() throws {
        let blocks = [
            line(run("Hi <b onclick=x>", .bold), run("there", [.italic, .underline], link: "https://example.com/?a=<1>")),
            line(""), quote("quoted"), quote("nested", depth: 3), line("end"),
            bullet("x"), bullet("y"), number("p", 1), number("q", 2),
            line(run("struck", .strikethrough), run("code", .code), run("danger", link: "javascript:alert(1)")),
        ]
        let out = MailBodyHTML.html(MailText(blocks: blocks))
        let allowed: Set<String> = ["p", "br", "b", "i", "u", "a", "ul", "ol", "li", "blockquote"]
        let tags = try NSRegularExpression(pattern: "</?([a-zA-Z0-9]+)")
        let found = tags.matches(in: out, range: NSRange(out.startIndex..., in: out)).compactMap { match -> String? in
            Range(match.range(at: 1), in: out).map { String(out[$0]) }
        }
        XCTAssertFalse(found.isEmpty)
        XCTAssertEqual(Set(found).subtracting(allowed), [], out)
        XCTAssertFalse(out.contains("<b onclick"), "typed markup is only text")
        XCTAssertTrue(out.contains("&lt;b onclick=x&gt;"))
        XCTAssertFalse(out.contains("javascript"), out)
        XCTAssertFalse(out.contains("style="))
    }

    func testTheOnlyAttributeEverWrittenIsHref() throws {
        let out = html(line(run("a", link: "https://example.com"), run("b", [.bold, .italic, .underline])))
        let attributes = try NSRegularExpression(pattern: "\\s([a-zA-Z-]+)=")
        let names = attributes.matches(in: out, range: NSRange(out.startIndex..., in: out)).compactMap { match -> String? in
            Range(match.range(at: 1), in: out).map { String(out[$0]) }
        }
        XCTAssertEqual(Set(names), ["href"])
    }

    // MARK: A message: his words, his signature, the original

    private func part(_ html: String, _ blocks: MailTextBlock...) -> MailDraftPart {
        MailDraftPart(fragment: MailFragment(html: html),
                      body: .text(MailText(blocks: blocks), quoteStartsAt: nil, notices: []))
    }

    func testAMessageIsHisWordsThenHisSignatureThenTheOriginalEachItsOwnPart() {
        let body = MailText(blocks: [line(run("Thanks ", []), run("everyone", .bold))])
        let signature = part("<div>Noor<br>Abrega</div>", line("Noor"), line("Abrega"))
        let original = part("<blockquote>On Mon, Sam wrote:<br>yes</blockquote>",
                            line("On Mon, Sam wrote:"), quote("yes"))
        let out = MailBodyHTML.message(body: body, signature: signature, quote: original)
        XCTAssertEqual(out.html, "<p>Thanks <b>everyone</b></p><div>Noor<br>Abrega</div>"
                       + "<blockquote>On Mon, Sam wrote:<br>yes</blockquote>",
                       "the fragments are appended as they came, never run through the body's rules")
        XCTAssertEqual(out.plain, "Thanks everyone\n\n-- \nNoor\nAbrega\n\nOn Mon, Sam wrote:\n> yes")
    }

    func testTheOriginalAloneOrTheSignatureAloneOrNeitherIsJustThat() {
        let body = MailText(blocks: [line("Hi")])
        let signature = part("<div>Noor</div>", line("Noor"))
        let original = part("<blockquote>q</blockquote>", quote("q"))
        XCTAssertEqual(MailBodyHTML.message(body: body, signature: nil, quote: nil).html, "<p>Hi</p>")
        XCTAssertEqual(MailBodyHTML.message(body: body, signature: nil, quote: nil).plain, "Hi")
        XCTAssertEqual(MailBodyHTML.message(body: body, signature: nil, quote: original).html, "<p>Hi</p><blockquote>q</blockquote>")
        XCTAssertEqual(MailBodyHTML.message(body: body, signature: nil, quote: original).plain, "Hi\n\n> q")
        XCTAssertEqual(MailBodyHTML.message(body: body, signature: signature, quote: nil).plain, "Hi\n\n-- \nNoor")
        // Nothing written under a signature and an original is those two, and nothing is made up.
        let silent = MailBodyHTML.message(body: MailText(blocks: []), signature: signature, quote: original)
        XCTAssertEqual(silent.html, "<div>Noor</div><blockquote>q</blockquote>")
        XCTAssertEqual(silent.plain, "-- \nNoor\n\n> q")
    }

    // MARK: The attributed text, as the editor holds it

    func testTheEditedTextIsSerialisedThroughItsDraftForm() {
        var text = AttributedString("Hello ")
        var bold = AttributedString("world"); bold.font = .body.bold(); text += bold
        text += AttributedString("\n- one\n- two\n1. first")
        XCTAssertEqual(MailBodyHTML.html(from: text),
                       "<p>Hello <b>world</b></p><ul><li>one</li><li>two</li></ul><ol><li>first</li></ol>")
        XCTAssertEqual(MailBodyHTML.plain(from: text), "Hello world\n- one\n- two\n1. first")
    }
}
