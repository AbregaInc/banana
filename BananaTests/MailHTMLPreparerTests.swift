import XCTest

final class MailHTMLPreparerTests: XCTestCase {
    private func text(_ prepared: MailPreparedBody) -> String { prepared.text.blocks.map { $0.runs.map(\.text).joined() }.joined(separator: "\n") }
    func testPlainTextIsLiteralAndKeepsLineBreaks() throws {
        let prepared = try MailHTMLPreparer.prepare(plain: "Hello\n<script>literal</script>", html: nil)
        XCTAssertEqual(text(prepared), "Hello\n<script>literal</script>")
        XCTAssertNil(prepared.safeHTML)
        XCTAssertFalse(prepared.shownAsText)
    }
    func testRemovesExecutableAndRemoteLoadingContent() throws {
        let input = #"<p onclick="steal()">Hello</p><script>alert(1)</script><style>body{background:url(https://tracker)}</style><img src="https://tracker/pixel"><iframe src="https://evil"></iframe><form action="https://evil"><input name="token"></form><svg onload="steal()"><script>bad()</script></svg>"#
        let prepared = try MailHTMLPreparer.prepare(plain: nil, html: input)
        let safe = prepared.safeHTML ?? ""
        for denied in ["<script", "<style", "<img", "<iframe", "<form", "<input", "<svg", "onclick", "tracker", "alert(1)"] {
            XCTAssertFalse(safe.contains(denied), denied)
        }
        XCTAssertEqual(text(prepared), "Hello")
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
        XCTAssertFalse(prepared.safeHTML?.contains("href=") ?? true)
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
        XCTAssertTrue(prepared.safeHTML?.contains("<table>") ?? false)
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
