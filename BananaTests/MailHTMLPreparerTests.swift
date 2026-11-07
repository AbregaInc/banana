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
    func testInputAndNestingBounds() throws {
        XCTAssertThrowsError(try MailHTMLPreparer.prepare(plain: String(repeating: "x", count: MailHTMLPreparer.maximumBytes + 1), html: nil))
        let deep = String(repeating: "<div>", count: 100) + "text" + String(repeating: "</div>", count: 100)
        XCTAssertThrowsError(try MailHTMLPreparer.prepare(plain: nil, html: deep))
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

    func testImageLinkKeepsItsDescriptionAndTrackingAddressIsShortened() throws {
        let long = "https://click.example.net/track/" + String(repeating: "a1b2", count: 20)
        let html = "<p><a href=\"https://example.com/get\"><img alt=\"Get the app\" src=\"https://example.com/b.png\"></a></p><p><a href=\"https://example.com/logo\"><img alt=\"\" src=\"https://example.com/l.png\"></a></p><p><a href=\"\(long)\">\(long)</a></p>"
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: html)
        XCTAssertEqual(blockTexts(prepared).first, "Get the app")
        XCTAssertTrue(blockTexts(prepared)[1].hasPrefix("click.example.net/track/a1b2"))
        XCTAssertLessThanOrEqual(blockTexts(prepared)[1].count, 37)
        XCTAssertEqual(prepared.text.blocks[0].runs.first?.link?.absoluteString, "https://example.com/get")
        XCTAssertEqual(prepared.text.blocks[1].runs.first?.link?.absoluteString, long)
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

    func testPreparedBodyRecordsWhereTheQuoteStarts() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: "<p>New</p><p>More</p><blockquote>Old</blockquote>")
        XCTAssertEqual(prepared.quoteStartsAt, 2)
        let none = try MailHTMLPreparer.prepare(plain: nil, html: "<p>New</p>")
        XCTAssertNil(none.quoteStartsAt)
    }

    func testPreparationCostForGeneratedHTML() throws {
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
                XCTAssertLessThanOrEqual(elapsed, 100, "Background preparation exceeded the component guardrail")
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
    }
}
