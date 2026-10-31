import XCTest

final class MailMIMETests: XCTestCase {
    private func part(_ id: String, _ mime: String, _ text: String, filename: String? = nil) -> GmailPart {
        GmailPart(partId: id, mimeType: mime, filename: filename,
            body: GmailPartBody(size: text.utf8.count, data: Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")))
    }
    func testAlternativeBodiesAndAttachedTextStaySeparate() {
        let payload = GmailPart(partId: "root", mimeType: "multipart/mixed", parts: [
            GmailPart(partId: "body", mimeType: "multipart/alternative", parts: [
                part("plain", "text/plain", "Hello"), part("html", "text/html", "<p>Hello</p>")]),
            part("file", "text/plain", "An attachment", filename: "notes.txt")])
        let result = MIMEStructure.extract(payload)
        XCTAssertEqual(result.plain, "Hello")
        XCTAssertEqual(result.html, "<p>Hello</p>")
        XCTAssertEqual(result.structure.attachments.map(\.partID), ["file"])
        XCTAssertEqual(result.structure.plainPartID, "plain")
    }
    func testCharsetAndNulHandling() {
        let payload = GmailPart(partId: "latin", mimeType: "text/plain",
            headers: [GmailHeader(name: "Content-Type", value: "text/plain; charset=\"iso-8859-1\"")],
            body: GmailPartBody(data: Data([0x43, 0x61, 0x66, 0xe9, 0]).base64EncodedString()))
        XCTAssertEqual(MIMEStructure.extract(payload).plain, "Café")
        XCTAssertEqual(MIMEStructure.extract(part("utf", "text/plain", "雪🙂")).plain, "雪🙂")
    }
    func testMissingBodyAndMalformedDataAreNotEmptySuccess() {
        let absent = MIMEStructure.extract(GmailPart(partId: "p", mimeType: "text/plain", body: GmailPartBody(attachmentId: "remote", size: 100)))
        XCTAssertNil(absent.plain)
        XCTAssertEqual(absent.missingBodyPartIDs, ["p"])
        let malformed = MIMEStructure.extract(GmailPart(partId: "p", mimeType: "text/plain", body: GmailPartBody(data: "%%%")))
        XCTAssertTrue(malformed.malformedBody)
        XCTAssertNil(malformed.plain)
        let empty = MIMEStructure.extract(GmailPart(partId: "p", mimeType: "text/plain", body: GmailPartBody(size: 0)))
        XCTAssertEqual(empty.plain, "")
        XCTAssertTrue(empty.missingBodyPartIDs.isEmpty)
    }
    func testTreeAndDecodedByteLimitsDiscardPartialBodies() {
        let body = part("plain", "text/plain", "Hello")
        let wide = GmailPart(mimeType: "multipart/mixed", parts: [body, body, body])
        let width = MIMEStructure.extract(wide, limits: MIMELimits(parts: 2))
        XCTAssertEqual(width.structure.cut, .parts)
        XCTAssertNil(width.plain)
        let depth = MIMEStructure.extract(wide, limits: MIMELimits(depth: 0))
        XCTAssertEqual(depth.structure.cut, .depth)
        XCTAssertNil(depth.plain)
        let bytes = MIMEStructure.extract(body, limits: MIMELimits(bodyBytes: 4))
        XCTAssertTrue(bytes.bodyTooLarge)
        XCTAssertNil(bytes.plain)
    }
    func testInviteMetadataAndAttachment() {
        let result = MIMEStructure.extract(part("invite", "text/calendar", "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nUID:unique\r\nEND:VCALENDAR", filename: "invite.ics"))
        XCTAssertEqual(result.structure.invite?.method, "REQUEST")
        XCTAssertEqual(result.structure.invite?.uid, "unique")
        XCTAssertEqual(result.structure.attachments.first?.isInvite, true)
        XCTAssertNil(result.plain)
    }
    func testDepthCutStopsWideTraversal() {
        let root = GmailPart(mimeType: "multipart/mixed", parts: Array(repeating: part("p", "text/plain", "a"), count: 2000))
        let result = MIMEStructure.extract(root, limits: MIMELimits(depth: 0))
        XCTAssertEqual(result.structure.cut, .depth)
        XCTAssertEqual(result.structure.root.children.count, 1)
    }
    func testLargeInvitationDoesNotDiscardOrdinaryBody() {
        let root = GmailPart(mimeType: "multipart/mixed", parts: [part("body", "text/plain", "Hello"),
            part("invite", "text/calendar", String(repeating: "x", count: 300 * 1024), filename: "large.ics")])
        let result = MIMEStructure.extract(root)
        XCTAssertEqual(result.plain, "Hello")
        XCTAssertFalse(result.bodyTooLarge)
        XCTAssertEqual(result.structure.invite?.partID, "invite")
        XCTAssertNil(result.structure.invite?.uid)
    }
    func testExtractionCostAtBodySizes() throws {
        var samples: [[String: Any]] = []
        for size in [63 * 1024, 261 * 1024, 2 * 1024 * 1024] {
            let input = part("body", "text/plain", String(repeating: "x", count: size))
            for iteration in 0..<8 {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = MIMEStructure.extract(input)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                XCTAssertEqual(result.plain?.utf8.count, size)
                XCTAssertFalse(result.bodyTooLarge)
                samples.append(["bodyBytes": size, "iteration": iteration, "milliseconds": elapsed])
                XCTAssertLessThanOrEqual(elapsed, 100, "Extraction alone exceeded the entire UI budget")
            }
        }
        let report: [String: Any] = ["samples": samples, "processID": ProcessInfo.processInfo.processIdentifier,
            "scope": "Release component extraction, no HTML parse, disk I/O, UI or device latency; no cache used"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["MAIL_MIME_BENCHMARK_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    func testMixedInlineSectionsPreserveBothSidesOfAlternative() {
        let root = GmailPart(mimeType: "multipart/mixed", parts: [part("intro", "text/plain", "Intro"),
            GmailPart(mimeType: "multipart/alternative", parts: [part("old", "text/plain", "Old"),
                part("chosen", "text/plain", "Chosen"), part("html", "text/html", "<p>Chosen</p>")]),
            part("footer", "text/plain", "Footer")])
        let result = MIMEStructure.extract(root)
        XCTAssertEqual(result.plain, "Intro\n\nChosen\n\nFooter")
        XCTAssertEqual(result.html, "<pre>Intro</pre>\n<p>Chosen</p>\n<pre>Footer</pre>")
    }
    func testRelatedStartSelectsRootInsteadOfLaterTextResource() {
        var body = part("body", "text/html", "<p>Body</p>")
        body.headers = [GmailHeader(name: "Content-ID", value: "<root@example>")]
        let root = GmailPart(mimeType: "multipart/related",
            headers: [GmailHeader(name: "Content-Type", value: "multipart/related; start=\"<root@example>\"")],
            parts: [part("resource", "text/html", "Resource"), body, part("other", "text/html", "Other")])
        let result = MIMEStructure.extract(root)
        XCTAssertEqual(result.html, "<p>Body</p>")
        XCTAssertEqual(result.structure.htmlPartID, "body")
    }
    func testMissingRelatedRootIsNotReplacedWithUnrelatedContent() {
        let root = GmailPart(mimeType: "multipart/related",
            headers: [GmailHeader(name: "Content-Type", value: "multipart/related; start=\"<absent>\"")],
            parts: [part("resource", "text/html", "Wrong content")])
        let result = MIMEStructure.extract(root)
        XCTAssertNil(result.html)
        XCTAssertTrue(result.malformedBody)
    }
    func testPlainSectionCannotBecomeMarkupInCombinedHTML() {
        let root = GmailPart(mimeType: "multipart/mixed", parts: [part("p", "text/plain", "<script>&hello</script>"),
            part("h", "text/html", "<p>Content</p>")])
        let result = MIMEStructure.extract(root)
        XCTAssertEqual(result.html, "<pre>&lt;script&gt;&amp;hello&lt;/script&gt;</pre>\n<p>Content</p>")
    }
}
