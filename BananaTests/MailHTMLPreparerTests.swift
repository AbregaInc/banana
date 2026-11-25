import XCTest

final class MailHTMLPreparerTests: XCTestCase {
    private func text(_ prepared: MailPreparedBody) -> String { prepared.text.blocks.map { $0.runs.map(\.text).joined() }.joined(separator: "\n") }
    func testPlainTextIsLiteralAndKeepsLineBreaks() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: "Hello\n<script>literal</script>", html: nil)
        XCTAssertEqual(text(prepared), "Hello\n<script>literal</script>")
        XCTAssertFalse(prepared.shownAsText)
    }
    func testRemovesExecutableAndRemoteLoadingContent() throws {
        let input = #"<p onclick="steal()">Hello</p><script>alert(1)</script><style>body{background:url(https://tracker)}</style><img src="https://tracker/pixel"><iframe src="https://evil"></iframe><form action="https://evil"><input name="token"></form><svg onload="steal()"><script>bad()</script></svg>"#
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: input)
        XCTAssertEqual(text(prepared), "Hello")
        XCTAssertTrue(prepared.text.blocks.flatMap(\.runs).allSatisfy { $0.link == nil })
    }
    func testFormattingLinksAndQuotesBecomeNativeRuns() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: #"<h2>Heading</h2><p>Hello <b>bold</b> <a href="https://example.com">link</a></p><blockquote><p>Quoted</p></blockquote>"#)
        XCTAssertEqual(prepared.text.blocks.first?.kind, .heading(level: 2))
        XCTAssertTrue(prepared.text.blocks.flatMap(\.runs).contains { $0.text == "bold" && $0.style.contains(.bold) })
        XCTAssertEqual(prepared.text.blocks.flatMap(\.runs).first { $0.text == "link" }?.link?.absoluteString, "https://example.com")
        XCTAssertTrue(prepared.text.blocks.contains { $0.kind == .quote(depth: 1) })
        XCTAssertTrue(prepared.shownAsText)
    }
    func testUnsafeSchemesCannotBecomeNativeLinks() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: #"<a href="javascript:alert(1)">one</a><a href="data:text/html,bad">two</a><a href="ftp://example.com">three</a><a href="jav&#x61;script:alert(1)">four</a>"#)
        XCTAssertTrue(prepared.text.blocks.flatMap(\.runs).allSatisfy { $0.link == nil })
    }
    func testUnlistedWrappersKeepTextAndCheckedLinks() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: #"<center><font color="red">Big <a href="HTTPS://example.com/a">sale</a></font></center><section><p>Next <a href="/relative">rel</a> <a href="mailto:a@example.com">mail</a></p></section><noscript>quiet</noscript>"#)
        let runs = prepared.text.blocks.flatMap(\.runs)
        XCTAssertTrue(text(prepared).contains("Big sale"))
        XCTAssertEqual(runs.first { $0.text == "sale" }?.link?.absoluteString, "HTTPS://example.com/a")
        XCTAssertNil(runs.first { $0.text == "rel" }?.link)
        XCTAssertEqual(runs.first { $0.text == "mail" }?.link?.scheme, "mailto")
        XCTAssertTrue(text(prepared).contains("quiet"))
    }
    func testDeepNestingIsReadFlat() throws {
        // Deeper than the walk recurses: every word still shows, in order, its link kept (was tooComplex).
        let deep = String(repeating: "<div>", count: 300) + "<p>first <a href=\"https://example.com/a\">link</a></p><p>second<br>Third</p>"
            + String(repeating: "</div>", count: 300)
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: deep)
        XCTAssertEqual(text(prepared), "first link\nsecond\nThird")
        XCTAssertEqual(prepared.text.blocks.flatMap(\.runs).first { $0.text == "link" }?.link?.absoluteString, "https://example.com/a")
        // Tables in tables, as newsletters nest them: twenty levels down.
        let nested = String(repeating: "<table><tr><td>", count: 20) + "Deep words" + String(repeating: "</td></tr></table>", count: 20)
        XCTAssertEqual(text(try MailHTMLPreparer.prepare(plain: nil, html: nested)), "Deep words")
        // Depth alone never swaps the HTML for the plain part: the HTML is still read.
        XCTAssertEqual(text(try MailHTMLPreparer.prepare(plain: "Plain version", html: nested)), "Deep words")
    }

    func testManySmallTagsAreCountedBeforeParsing() throws {
        // Under the byte limit but past the tag limit: the plain part, never a parse of it all.
        let many = String(repeating: "<b>", count: MailHTMLPreparer.maximumTags + 10)
        XCTAssertLessThan(many.utf8.count, MailHTMLPreparer.maximumBytes)
        XCTAssertNotNil(MailHTMLPreparer.cutAtTagLimit(many))
        XCTAssertNil(MailHTMLPreparer.cutAtTagLimit("<p>fine</p>"))
        XCTAssertEqual(text(try MailHTMLPreparer.prepare(plain: "Plain version", html: many)), "Plain version")
        XCTAssertThrowsError(try MailOriginalDocument.prepare(many))
    }

    // MARK: Data tables, lists written as text, soft breaks (problem reports, Nov 2026)

    private func table(_ prepared: MailPreparedBody) -> MailTable? {
        prepared.text.blocks.lazy.compactMap { if case .table(let table) = $0.kind { return table }; return nil }.first
    }

    func testDataCellUsesNativeStatusTextWhenTheImageSuppliesIt() throws {
        let html = "<table><tr><th>Status</th><th>Job</th></tr><tr><td><img src='https://img.example/status.png' width='24' height='24' alt='Failed'></td><td>Build</td></tr><tr><td>Passed</td><td>Tests</td></tr></table>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertNotEqual(prepared.prefersOriginal, true)
        let grid = try XCTUnwrap(table(prepared))
        XCTAssertEqual(grid.rows[1][0].runs.map(\.text).joined(), "Failed")
        let noAlternative = html.replacingOccurrences(of: " alt='Failed'", with: "")
        XCTAssertEqual(try MailHTMLPreparer.prepare(plain: nil, html: noAlternative).prefersOriginal, true)
        let tracker = html.replacingOccurrences(of: "width='24' height='24'", with: "width='1' height='1'")
        let ignored = try MailHTMLPreparer.prepare(plain: nil, html: tracker)
        XCTAssertNotEqual(ignored.prefersOriginal, true)
        XCTAssertFalse(text(ignored).contains("Failed"))
    }

    func testDataTableIsAGrid() throws {
        let html = "<p>Key numbers</p><table><tr><th>Number</th><th>This week</th><th>Last week</th></tr>"
            + "<tr><td>Net cash</td><td><a href=\"https://example.com/c\">$3,261</a></td><td>$8,169</td></tr>"
            + "<tr><td>Purchases</td><td>8</td><td>6 <span>(&#9650; 2)</span></td></tr></table><p>After</p>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        let grid = try XCTUnwrap(table(prepared))
        XCTAssertEqual(grid.rows.map { $0.map { $0.runs.map(\.text).joined() } },
                       [["Number", "This week", "Last week"], ["Net cash", "$3,261", "$8,169"], ["Purchases", "8", "6 (\u{25B2} 2)"]])
        XCTAssertEqual(grid.rows[0].map(\.header), [true, true, true])
        XCTAssertEqual(grid.rows[1][1].runs.first?.link?.absoluteString, "https://example.com/c")
        // Its text (search, quoting) is a row to a line.
        XCTAssertTrue(text(prepared).contains("Net cash\u{2003}\u{2003}$3,261\u{2003}\u{2003}$8,169"))
        XCTAssertEqual(blockTexts(prepared).first, "Key numbers")
        XCTAssertEqual(blockTexts(prepared).last, "After")
    }

    func testHeaderOnlyTableRemainsNativeWithoutInventingDataRows() throws {
        let html = "<h2>Popular pages</h2><table style='width:640px'><thead><tr>"
            + "<th>Page</th><th>Impressions</th><th>Clicks</th></tr></thead></table>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertFalse(prepared.prefersOriginal == true)
        XCTAssertNil(table(prepared))
        for word in ["Popular pages", "Page", "Impressions", "Clicks"] {
            XCTAssertTrue(text(prepared).contains(word))
        }
    }

    func testWideSingleRecordUsesLabelsAndKeepsTheTrailingNote() throws {
        let header = "<tr><th>Date</th><th>Booking</th><th>Arrival Location</th><th>Time</th></tr>"
        let record = "<tr><td>Friday</td><td><a href='https://plan.example/booking'>AB1234</a></td><td>Terminal B<br>Door 3</td><td>6:00 PM</td></tr>"
        let note = "<tr><td colspan='4'>Bring ID to check in.</td></tr>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: "<table>" + header + record + note + "</table>")
        XCTAssertNil(table(prepared))
        XCTAssertEqual(blockTexts(prepared), ["Date\nFriday", "Booking\nAB1234", "Arrival Location\nTerminal B\nDoor 3",
                                              "Time\n6:00 PM", "Bring ID to check in."])
        XCTAssertTrue(try XCTUnwrap(prepared.text.blocks[1].runs.first).style.contains(.bold))
        XCTAssertEqual(prepared.text.blocks[1].runs.last?.link?.absoluteString, "https://plan.example/booking")

        let comparison = try MailHTMLPreparer.prepare(plain: nil, html: "<table>" + header + record + record + "</table>")
        XCTAssertEqual(table(comparison)?.rows.count, 3)
    }

    func testLayoutTablesStayText() throws {
        // One row of links, a single column, cells holding layout, mostly empty cells.
        let row = "<table><tr><th><a href=\"https://example.com/a\">Preferences</a></th><th>Online version</th></tr></table>"
        let column = "<table><tr><td>Hello</td></tr><tr><td>World</td></tr></table>"
        let layout = "<table><tr><td><h2>Title</h2></td><td>x</td></tr><tr><td>a</td><td>b</td></tr></table>"
        let heat = "<table><tr><td>Oct 11</td><td> </td><td> </td><td> </td></tr><tr><td>Oct 18</td><td> </td><td> </td><td> </td></tr></table>"
        for html in [row, column, layout, heat] { XCTAssertNil(table(try MailHTMLPreparer.prepare(plain: nil, html: html)), html) }
    }

    func testNumberedRowsInATableAreAList() throws {
        let html = "<p>Complete these 3 requirements:</p><table><tr><td>1.</td><td>Deposit $5,000</td></tr>"
            + "<tr><td>2.</td><td>Keep a balance</td></tr><tr><td>3.</td><td>Make 5 transactions</td></tr></table>"
        let blocks = try MailHTMLPreparer.prepare(plain: nil, html: html).text.blocks
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .item(ordered: true, depth: 0, number: 1), .item(ordered: true, depth: 0, number: 2), .item(ordered: true, depth: 0, number: 3)])
        XCTAssertEqual(blocks[1].runs.map(\.text).joined(), "Deposit $5,000")
    }

    func testSemanticListDoesNotDuplicateAuthoredBullets() throws {
        let html = "<ul><li><div>&bull;</div><div><strong>First</strong> item</div></li><li>&bull; Second item</li><li>-5 degrees</li></ul>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(blockTexts(prepared), ["First item", "Second item", "-5 degrees"])
        XCTAssertEqual(prepared.text.blocks.map(\.kind), Array(repeating: .item(ordered: false, depth: 0, number: nil), count: 3))
        XCTAssertEqual(prepared.text.blocks[0].runs.first?.style.contains(.bold), true)
    }

    func testShortReceiptRowsKeepLabelsWithTheirValues() throws {
        let html = "<table role='presentation'><tr><td><table><tr><td><span>Total</span></td><td><strong>$25</strong></td></tr></table>"
            + "<table><tr><td>Receipt</td><td><a href='https://plan.example/receipt'>Download</a></td></tr></table></td></tr></table>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(blockTexts(prepared), ["Total\u{2003}\u{2003}$25", "Receipt\u{2003}\u{2003}Download"])
        XCTAssertEqual(prepared.text.blocks.last?.runs.last?.link?.absoluteString, "https://plan.example/receipt")
        XCTAssertNil(table(prepared))
    }

    func testCompactRowsDoNotDiscardPicturesOrFlattenHeadings() throws {
        let html = "<table><tr><td><h2>Heading</h2><p>Words</p></td><td><img src='cid:picture' width='300' height='200'></td></tr></table>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertTrue(prepared.text.blocks.contains { if case .heading = $0.kind { return true }; return false })
        XCTAssertEqual(pictures(prepared).count, 1)
    }

    func testListsWrittenAsTextBecomeLists() throws {
        // A marker in one block, its words in the next.
        let split = try MailHTMLPreparer.prepare(plain: nil, html: "<div>1.</div><div>First thing</div><div>2.</div><div>Second thing</div>")
        XCTAssertEqual(split.text.blocks.map(\.kind), [.item(ordered: true, depth: 0, number: 1), .item(ordered: true, depth: 0, number: 2)])
        XCTAssertEqual(blockTexts(split), ["First thing", "Second thing"])
        // Lines that start with markers, broken in one paragraph or in several.
        let lines = try MailHTMLPreparer.prepare(plain: nil, html: "<p>a. Apples<br>b. Pears</p><p>&bull; One</p><p>&bull; Two</p>")
        XCTAssertEqual(lines.text.blocks.map(\.kind), Array(repeating: .item(ordered: false, depth: 0, number: nil), count: 4))
        XCTAssertEqual(blockTexts(lines), ["Apples", "Pears", "One", "Two"])
        // Short lines after a sentence ending in a colon, until a sentence.
        let leadIn = try MailHTMLPreparer.prepare(plain: nil, html: "<p>Pages are not indexed for these reasons:</p>"
            + "<div><p>Alternate page with proper canonical tag</p><p>Duplicate, Google chose a different canonical</p></div>"
            + "<p>If any of these are not intentional, fix them.</p>")
        XCTAssertEqual(leadIn.text.blocks.map(\.kind), [.paragraph, .item(ordered: false, depth: 0, number: nil), .item(ordered: false, depth: 0, number: nil), .paragraph])
        // Not lists: one numbered sentence, a colon followed by sentences, a year.
        let prose = try MailHTMLPreparer.prepare(plain: nil, html: "<p>1. is the loneliest number.</p><p>Here it is:</p><p>A sentence.</p><p>Another one.</p><p>2026.</p>")
        XCTAssertFalse(prose.text.blocks.contains { if case .item = $0.kind { return true }; return false })
    }

    func testBreakBeforeALowerCaseWordOnlyWrapsTheLine() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: "<h1>Bank with the Power <br>of Membership.</h1><p>Line one<br>Line two<br>and on</p><pre>keep\nlower</pre>")
        XCTAssertEqual(blockTexts(prepared), ["Bank with the Power of Membership.", "Line one\nLine two and on", "keep\nlower"])
    }

    func testLinkedPictureBesideItsOwnLinkHasNoSecondLabel() throws {
        let html = "<a href=\"https://example.com/in/ann?photo=1\"><img src=\"https://img.example.com/a.png\" width=\"96\" height=\"96\" alt=\"Ann Lee\"></a>"
            + "<p><a href=\"https://example.com/in/ann?name=1\">Ann Lee</a></p>"
            + "<a href=\"https://other.example.com/x\"><img src=\"https://img.example.com/b.png\" width=\"48\" height=\"48\" alt=\"Bo Chen\u{2019}s Profile Picture\"></a>"
            + "<p><a href=\"https://example.com/in/bo\">Bo Chen</a></p>"
            + "<a href=\"https://example.com/app\"><img src=\"https://img.example.com/c.png\" width=\"150\" height=\"40\" alt=\"Get the app, opens a new tab\"></a><p>Words</p>"
            + "<a href=\"https://example.com/m\"><img src=\"https://img.example.com/i.png\" height=\"25\" alt=\"Messaging\"></a>"
        let found = pictures(try MailHTMLPreparer.prepare(plain: nil, html: html))
        XCTAssertEqual(found.map(\.alt), ["", "", "Get the app"])
        XCTAssertEqual(found.map { $0.link?.host }, ["example.com", "other.example.com", "example.com"])
    }

    func testBlankLinkedCellsAreNotLinks() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: "<p>Oct 11 <a href=\"https://example.com\">&nbsp; </a> <a href=\"https://example.com/b\">Next</a></p>")
        XCTAssertEqual(prepared.text.blocks.flatMap(\.runs).filter { $0.link != nil }.map(\.text), ["Next"])
    }

    /// Past the bounds a message still gets a body, once: never a failure that every pull retries.
    func testInputAndNestingBoundsDegradeToTextInsteadOfFailing() throws {
        let max = MailHTMLPreparer.maximumBytes
        let long = try MailHTMLPreparer.prepare(plain: String(repeating: "é", count: max), html: nil)
        XCTAssertLessThanOrEqual(text(long).utf8.count, max, "cut to the bound, at a character boundary")
        XCTAssertTrue(text(long).hasPrefix("éé"))
        let deep = String(repeating: "<div>", count: 100) + "deep words" + String(repeating: "</div>", count: 100)
        let words = try MailHTMLPreparer.prepare(plain: nil, html: deep)
        XCTAssertTrue(text(words).contains("deep words"))
        XCTAssertTrue(words.shownAsText)
        let many = "<p>" + String(repeating: "<b>w</b> ", count: 60_000) + "</p>"
        let preferPlain = try MailHTMLPreparer.prepare(plain: "Plain\nlines", html: many)
        XCTAssertEqual(text(preferPlain), "Plain\nlines", "too many nodes: the plain part, with its line breaks, when there is one")
        XCTAssertTrue(text(try MailHTMLPreparer.prepare(plain: nil, html: many)).contains("w w w"), "too many nodes: the words")
        let huge = "<p>start</p>" + String(repeating: "<i>x</i>", count: max / 8 + 10)
        XCTAssertTrue(text(try MailHTMLPreparer.prepare(plain: nil, html: huge)).hasPrefix("start"), "too large: as much as is taken")
    }
    func testTablesAndListsRemainReadable() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: "<table><tr><td>Left</td><td>Right</td></tr></table><ol><li>First</li><li>Second</li></ol>")
        XCTAssertTrue(text(prepared).contains("Left\u{2003}\u{2003}Right"))
        XCTAssertEqual(prepared.text.blocks.filter { if case .item = $0.kind { return true }; return false }.count, 2)
    }
    func testOriginalRetainsLayoutAndLinksButRemovesActiveContent() throws {
        let html = #"<html><head><style>.card{color:red}</style><script>steal()</script><meta http-equiv="refresh" content="0;url=https://evil.example"></head><body><table class="card" style="width:600px" cellpadding="12"><tr><td><a href="https://example.com/invite?a=1&amp;b=2" onclick="steal()">Accept</a></td></tr></table><iframe src="https://evil.example"></iframe><form action="https://evil.example"><input name="x"></form><img src="https://example.com/image.png"></body></html>"#
        let fragment = try MailOriginalDocument.prepare(html)
        XCTAssertTrue(fragment.contains(".card{color:red}"))
        XCTAssertTrue(fragment.contains("width:600px"))
        XCTAssertTrue(fragment.contains("cellpadding=\"12\""))
        XCTAssertTrue(fragment.contains("https://example.com/invite?a=1&amp;b=2"))
        for value in ["<script", "onclick", "<iframe", "<form", "<input", "http-equiv"] {
            XCTAssertFalse(fragment.contains(value), value)
        }
        let blocked = MailOriginalDocument.page(fragment)
        XCTAssertTrue(blocked.contains("default-src 'none'"))
        XCTAssertTrue(blocked.contains("img-src 'none'"))
        XCTAssertTrue(blocked.contains("form-action 'none'"))
        XCTAssertTrue(MailOriginalDocument.page(fragment, remoteImages: true).contains("img-src https:"))
    }
    func testOriginalRejectsOversizedAndDeepDocuments() {
        XCTAssertThrowsError(try MailOriginalDocument.prepare(String(repeating: "x", count: MailHTMLPreparer.maximumBytes + 1)))
        XCTAssertThrowsError(try MailOriginalDocument.prepare(String(repeating: "<div>", count: 100) + "body" + String(repeating: "</div>", count: 100)))
    }

    func testShortHeadedPanelsKeepEachLabelWithItsValueAndLinkAsNativeText() throws {
        let html = """
        <table><tr><td><h2>Expected</h2><p><a href="https://example.com/expected">2 packages</a></p></td>
        <td></td><td><h2>Delivered</h2><p>1 today</p></td></tr></table>
        """
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(prepared.prefersOriginal, false)
        XCTAssertEqual(blockTexts(prepared), ["Expected 2 packages", "Delivered 1 today"])
        XCTAssertEqual(prepared.text.blocks.map(\.kind),
                       Array(repeating: .item(ordered: false, depth: 0, number: nil), count: 2))
        XCTAssertEqual(prepared.text.blocks[0].runs.compactMap(\.link).map(\.absoluteString), ["https://example.com/expected"])

        let rich = html.replacingOccurrences(of: "<p>1 today</p>", with: "<ul><li>1 today</li></ul>")
        XCTAssertEqual(try MailHTMLPreparer.prepare(plain: nil, html: rich).prefersOriginal, true)
    }

    func testHeadingsWithoutTheirOwnValuesKeepFormattedLayout() throws {
        let headers = "<tr><td><h2>Address</h2></td><td><h2>Time</h2></td></tr>"
        for html in [
            "<table>" + headers + "</table><ul><li>Check in at reception</li></ul>",
            "<table><tr><td><h2>Address</h2><p hidden>Reception</p></td><td><h2>Time</h2><p>Monday</p></td></tr></table>"
        ] {
            let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
            XCTAssertEqual(prepared.prefersOriginal, true)
            XCTAssertTrue(prepared.text.blocks.contains { if case .heading = $0.kind { return true }; return false })
        }
    }

    func testHeadedRecordsPairNativeValuesAndKeepRichContent() throws {
        let header = "<tr><td><h2>Address</h2></td><td><h2>Time<span class='visually-hidden'>Window</span></h2></td></tr>"
        let values = "<tr><td>Reception desk</td><td><a href='https://example.com/window'>Monday at nine</a></td></tr>"
        let tail = "<tr><td>Call on arrival</td></tr>"
        let result = try MailHTMLPreparer.prepare(plain: nil, html: "<table>" + header + values + tail + "</table>")
        XCTAssertEqual(result.prefersOriginal, false)
        XCTAssertEqual(blockTexts(result), ["Address\nReception desk", "Time Window\nMonday at nine", "Call on arrival"])
        XCTAssertEqual(result.text.blocks[1].runs.last?.link?.absoluteString, "https://example.com/window")

        let separated = """
        <table><tr><td></td><td><h3>Description</h3></td><td></td><td><h3>Budget</h3></td></tr></table>
        <table><tr><td></td><td><p>First project</p><ul><li>Draft the outline</li></ul></td><td></td><td>$200</td></tr>
        <tr><td colspan='4'></td></tr>
        <tr><td></td><td>Second project</td><td></td><td>$300</td></tr></table>
        """
        let rich = try MailHTMLPreparer.prepare(plain: nil, html: separated)
        XCTAssertEqual(rich.prefersOriginal, false)
        XCTAssertEqual(blockTexts(rich), ["Description", "First project", "Draft the outline", "Budget\n$200", "Description\nSecond project", "Budget\n$300"])
        XCTAssertEqual(rich.text.blocks[2].kind, .item(ordered: false, depth: 0, number: nil))
    }

    func testFormattedRenderingRequiresUnrepresentedStructureNotStyling() throws {
        let spanning = "<table><tr><th>Item</th><th>Amount</th></tr><tr><td rowspan='2'>Notebook</td><td>$12</td></tr><tr><td>$4</td></tr></table>"
        XCTAssertEqual(try MailHTMLPreparer.prepare(plain: nil, html: spanning).prefersOriginal, true)
        let caption = "<table><caption>Receipt</caption><tr><th>Item</th><th>Amount</th></tr><tr><td>Notebook</td><td>$12</td></tr></table>"
        XCTAssertEqual(try MailHTMLPreparer.prepare(plain: nil, html: caption).prefersOriginal, true)
        for html in ["<p>Hello <b>Noor</b>.</p>", "<p style='color:#123456'>Hello</p>",
                     "<style>p{color:red}</style><p>Hello</p>", "<img src='cid:receipt@message'>",
                     "<table role='presentation'><tr><td>Newsletter</td></tr></table>",
                     "<table><tr><th>Item</th><th>Amount</th></tr><tr><td>Notebook</td><td>$12</td></tr></table>",
                     "<table><tr><td><table><tr><th>Item</th><th>Amount</th></tr><tr><td>Notebook</td><td>$12</td></tr></table></td></tr></table>",
                     "<blockquote>" + spanning + "</blockquote>",
                     "<div hidden>" + spanning + "</div>"] {
            XCTAssertNotEqual(try MailHTMLPreparer.prepare(plain: nil, html: html).prefersOriginal, true, html)
        }
    }

    func testInlineLayoutKeepsCIDImagesOfflineAndRemoteImagesRequireConsent() throws {
        let fragment = try MailOriginalDocument.prepare("<table><tr><td>Receipt</td></tr></table><img src='cid:logo@message'><img src='https://images.example/pixel.png'>")
        XCTAssertTrue(fragment.contains("banana-mail-image://message/logo%40message"))
        let page = MailOriginalDocument.page(fragment, embedded: true)
        XCTAssertTrue(page.contains("img-src banana-mail-image:;"))
        XCTAssertTrue(page.contains("script-src 'none'"))
        XCTAssertTrue(page.contains("connect-src 'none'"))
        XCTAssertTrue(page.contains("color-scheme:light"))
        XCTAssertTrue(page.contains("height:auto!important;min-height:0!important"))
        XCTAssertTrue(page.contains("@media(max-width:360px)"))
        XCTAssertTrue(page.contains("white-space:normal!important;overflow-wrap:anywhere!important"))
        XCTAssertFalse(MailOriginalDocument.page(fragment).contains("height:auto!important;min-height:0!important"))
        XCTAssertTrue(MailOriginalDocument.page(fragment, remoteImages: true, embedded: true)
            .contains("img-src banana-mail-image: https:;"))
    }
    // MARK: Renderer climb fixtures (synthetic: each reproduces a pattern, none is a real message)

    private func blockTexts(_ prepared: MailPreparedBody) -> [String] { prepared.text.blocks.map { $0.runs.map(\.text).joined() } }

    func testPreviewLinePaddingAndHiddenTextAreNotShown() throws {
        let pad = String(repeating: "\u{034F}\u{200B}\u{00A0}\u{00AD}", count: 40)
        let html = "<div style=\"display:none;max-height:0;overflow:hidden\">Secret preview</div><div style=\"font-size:0\">hidden \(pad)</div>"
            + "<span class=\"mcnPreviewText\">Preheader words</span><p>Hello\(pad) there</p><p hidden>attr hidden</p>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(blockTexts(prepared), ["Hello there"])
    }

    func testWhitespaceIsCollapsedAndBlocksAreTrimmed() throws {
        let html = "<table><tr><td>\n   <p>\u{00A0} One \n  two\u{00A0}\u{00A0}three  </p>\n</td></tr></table><div>   </div><p><br><br>Four<br><br><br>Five<br></p>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(blockTexts(prepared), ["One two three", "Four", "Five"])
    }

    func testFloatedLabelAndValueShareALine() throws {
        let html = "<div><span style=\"float:left\">When</span><span style=\"float:right\">Today 10:00</span></div><div><span style=\"display:block\">A</span><span style=\"display:block\">B</span></div>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(blockTexts(prepared), ["When\u{2003}\u{2003}Today 10:00", "A", "B"])
    }

    func testContainerWithZeroFontSizeIsStillShown() throws {
        let html = "<div style=\"font-size:0px\"><table><tr><td style=\"font-size:16px\">Column text</td></tr></table></div>"
        XCTAssertEqual(blockTexts(try MailHTMLPreparer.prepare(plain: nil, html: html)), ["Column text"])
    }

    func testTrackingAddressTextIsShortened() throws {
        let long = "https://click.example.net/track/" + String(repeating: "a1b2", count: 20)
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: "<p><a href=\"\(long)\">\(long)</a></p>")
        let shown = blockTexts(prepared)[0]
        XCTAssertTrue(shown.hasPrefix("click.example.net/track/a1b2"))
        XCTAssertLessThanOrEqual(shown.count, 37)
        XCTAssertEqual(prepared.text.blocks[0].runs.first?.link?.absoluteString, long)
    }

    private func pictures(_ prepared: MailPreparedBody) -> [MailPicture] {
        prepared.text.blocks.compactMap { if case .picture(let picture) = $0.kind { return picture }; return nil }
    }

    func testPicturesStayInReadingOrderWithSizeAltAndLink() throws {
        let html = "<p>Before <img src=\"https://img.example.com/a.png\" width=\"600\" height=\"300\" alt=\"Chart\"> after</p>"
            + "<p><a href=\"https://example.com/go\"><img src=\"https://img.example.com/b.png\" style=\"width: 320px; height:80px\" alt=\"\"></a></p>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(prepared.text.blocks.map(\.kind).map { if case .picture = $0 { return "pic" }; return "text" }, ["text", "pic", "text", "pic"])
        XCTAssertEqual(blockTexts(prepared).filter { !$0.isEmpty }, ["Before", "after"])
        let found = pictures(prepared)
        XCTAssertEqual(found[0], MailPicture(source: .remote(URL(string: "https://img.example.com/a.png")!), width: 600, height: 300, alt: "Chart", link: nil))
        XCTAssertEqual(found[1].width, 320)
        XCTAssertEqual(found[1].height, 80)
        XCTAssertEqual(found[1].link?.absoluteString, "https://example.com/go")
    }

    func testTrackersSpacersAndIconsAreNotPictures() throws {
        let html = "<img src=\"https://t.example.com/x.gif\" width=\"1\" height=\"1\">"
            + "<img src=\"https://t.example.com/y.gif\" style=\"width:2px;height:2px\">"
            + "<img src=\"https://t.example.com/z.png\" style=\"display:none\" width=\"300\" height=\"100\">"
            + "<img src=\"https://t.example.com/wf/open?upn=abc\">"
            + "<img src=\"https://t.example.com/spacer.gif\">"
            + "<img src=\"https://t.example.com/line.png\" width=\"600\" height=\"2\">"
            + "<img src=\"https://t.example.com/icon.png\" width=\"24\" height=\"24\" alt=\"Follow us\">"
            + "<img src=\"data:image/png;base64,AAAA\" width=\"200\" height=\"100\">"
            + "<img src=\"/relative.png\" width=\"200\" height=\"100\">"
            + "<p>Text</p>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(pictures(prepared), [])
        XCTAssertEqual(blockTexts(prepared), ["Text"])
    }

    func testMessagePartsAreCidPictures() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: "<p><img src=\"cid:part-1@example\" width=\"200\" height=\"100\" alt=\"Photo\"></p>")
        XCTAssertEqual(pictures(prepared).first?.source, .cid("part-1@example"))
    }

    func testQuotedAndFinePrintPicturesAreDropped() throws {
        let html = "<img src=\"https://img.example.com/logo.png\" width=\"120\" height=\"40\" alt=\"Sender\"><p>Hello</p><p>Body</p>"
            + "<img src=\"https://img.example.com/hero.png\" width=\"600\" height=\"300\">"
            + "<blockquote><img src=\"https://img.example.com/sig.png\" width=\"100\" height=\"50\">Old</blockquote>"
            + "<p>Closing words</p><p>Click to unsubscribe</p><img src=\"https://img.example.com/badge.png\" width=\"140\" height=\"40\" alt=\"App\">"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(pictures(prepared).map(\.alt), ["Sender", ""])
    }

    func testRepeatedAndExcessPicturesAreLimited() throws {
        let same = String(repeating: "<img src=\"https://img.example.com/a.png\" width=\"200\" height=\"100\">", count: 3)
        XCTAssertEqual(pictures(try MailHTMLPreparer.prepare(plain: nil, html: same + "<p>x</p>")).count, 1)
        let many = (0..<60).map { "<p>t\($0)</p><img src=\"https://img.example.com/\($0).png\" width=\"200\" height=\"100\">" }.joined()
        XCTAssertEqual(pictures(try MailHTMLPreparer.prepare(plain: nil, html: many)).count, MailHTMLPreparer.maximumPictures)
    }

    func testListsKeepNumbersAndDepth() throws {
        let html = "<ol start=\"3\"><li>Three<ul><li>Inner</li></ul></li><li>Four</li></ol><ul><li>Dot</li></ul>"
        let kinds = try MailHTMLPreparer.prepare(plain: nil, html: html).text.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.item(ordered: true, depth: 0, number: 3), .item(ordered: false, depth: 1, number: nil),
                               .item(ordered: true, depth: 0, number: 4), .item(ordered: false, depth: 0, number: nil)])
    }

    func testReplyQuotesFromEveryClientAreQuotes() throws {
        let gmail = "<div>Thanks!</div><div class=\"gmail_quote\"><div class=\"gmail_attr\">On Tue, Ann wrote:<br></div><blockquote class=\"gmail_quote\">Original</blockquote></div>"
        let apple = "<div>Yes</div><div>On Nov 3, 2026, at 9:00, Ann &lt;ann@example.com&gt; wrote:</div><blockquote type=\"cite\">Original</blockquote>"
        let outlook = "<div>Fine</div><hr><div id=\"divRplyFwdMsg\"><b>From:</b> Ann<br><b>Sent:</b> Monday</div><div>Original body</div>"
        for html in [gmail, apple, outlook] {
            let blocks = try MailHTMLPreparer.prepare(plain: nil, html: html).text.blocks
            XCTAssertEqual(blocks.first?.kind, .paragraph)
            XCTAssertTrue(blocks.dropFirst().contains { if case .quote = $0.kind { return true }; return false })
            XCTAssertFalse(blocks.dropFirst().contains { $0.kind == .paragraph }, html)
        }
    }

    func testQuoteBeforeSignaturePictureCanFold() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html:
            "<p>Reply</p><blockquote><p>Earlier</p></blockquote><img src='cid:signature' width='200' height='100'>")
        XCTAssertEqual(prepared.quoteStartsAt, 1)
        XCTAssertEqual(pictures(prepared).count, 1)
    }

    func testSingleCellWrappersKeepReceiptLabelAndValueTogether() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html:
            "<table><tr><td></td><td><table><tr><td><span>Total</span></td></tr></table></td>"
            + "<td></td><td><table><tr><td><span>$25.00</span></td></tr></table></td><td></td></tr></table>")
        XCTAssertEqual(prepared.text.blocks.map { $0.runs.map(\.text).joined() }, ["Total\u{2003}\u{2003}$25.00"])
    }

    func testSingleRowTableBulletUsesOneNativeMarker() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html:
            "<table><tr><td><p>•</p></td><td><div>Checklist <a href='https://example.com'>entry</a></div></td></tr></table>")
        XCTAssertEqual(prepared.text.blocks.map(\.kind), [.item(ordered: false, depth: 0, number: nil)])
        XCTAssertEqual(prepared.text.blocks.first?.runs.map(\.text).joined(), "Checklist entry")
        XCTAssertEqual(prepared.text.blocks.first?.runs.last?.link, URL(string: "https://example.com"))
    }

    func testPreparedBodyRecordsWhereTheQuoteStarts() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: "<p>New</p><p>More</p><blockquote>Old</blockquote>")
        XCTAssertEqual(prepared.quoteStartsAt, 2)
        let none = try MailHTMLPreparer.prepare(plain: nil, html: "<p>New</p>")
        XCTAssertNil(none.quoteStartsAt)
    }

    /// Preparation parses a message as a document (one bulk pass) rather than a body fragment: what
    /// a document puts in its head never reaches the text, and the body reads as it did.
    func testDocumentHeadNeverReachesTheText() throws {
        let document = "<!DOCTYPE html><html><head><title>Subject line</title><style>p{color:red}</style><meta charset=utf-8>"
            + "<base href='https://example.com'><link rel=stylesheet href=x.css></head><body><p>Hello <b>there</b></p><p>Bye</p></body></html>"
        let loose = "<title>Subject line</title><style>p{}</style><p>Hello <b>there</b></p><p>Bye</p>"
        for html in [document, loose] {
            let blocks = try MailHTMLPreparer.prepare(plain: nil, html: html).text.blocks
            XCTAssertEqual(blocks.map { $0.runs.map(\.text).joined() }, ["Hello there", "Bye"], html)
        }
    }

    func testPreparationCostForGeneratedHTML() throws {
        let budget = CostBudget(self)
        var samples: [[String: Any]] = []
        let block = "<p>Message text with <b>emphasis</b> and <a href='https://example.com'>a link</a>.</p>"
        for size in [63 * 1024, 261 * 1024] {
            for iteration in 0..<8 {
                let html = "<h2>Message \(iteration)</h2>" + String(repeating: block, count: size / block.utf8.count)
                let start = DispatchTime.now().uptimeNanoseconds
                var phases: [String: Double] = [:]
                let result = try MailHTMLPreparer.prepare(plain: nil, html: html) { phases[$0] = $1 }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                XCTAssertFalse(result.text.blocks.isEmpty)
                samples.append(["inputBytes": html.utf8.count, "iteration": iteration, "milliseconds": elapsed, "phases": phases])
                budget.expect(elapsed, below: 100, orEqual: true, "Background preparation exceeded the component guardrail")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": samples,
            "scope": "Generated HTML parse, clean, serialization and native text; not newsletters, UI or body-store timing"], options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["MAIL_HTML_BENCHMARK_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.lifetime = .keepAlways; add(attachment)
        }
        try budget.finish()
    }
}
