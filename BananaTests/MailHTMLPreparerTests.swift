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
        XCTAssertTrue(text(prepared).contains("Left\tRight"))
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
