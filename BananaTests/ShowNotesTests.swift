import XCTest

/// Show notes arrive as HTML. The Episode info sheet used WebKit's importer, which froze the app;
/// these pin the plain-string replacement's output.
final class ShowNotesTests: XCTestCase {
    private func text(_ html: String) -> String? {
        ShowNotes.attributed(html).map { String($0.characters) }
    }

    func testParagraphsAndLineBreaks() {
        XCTAssertEqual(text("<p>First   paragraph\n here.</p><p>Second<br>line</p>"),
                       "First paragraph here.\n\nSecond\nline")
    }

    func testListItemsBecomeBullets() {
        XCTAssertEqual(text("<p>Chapters:</p><ul><li>Intro</li><li>Story</li></ul>"),
                       "Chapters:\n\n\u{2022} Intro\n\u{2022} Story")
    }

    func testEntitiesDecode() {
        XCTAssertEqual(text("Tom &amp; Jerry&rsquo;s &#8220;day&#x201D; &lt;3&nbsp;&hellip;"),
                       "Tom & Jerry\u{2019}s \u{201C}day\u{201D} <3 \u{2026}")
    }

    func testLinksKeepTheirTarget() throws {
        let notes = try XCTUnwrap(ShowNotes.attributed(#"Read <a href="https://example.com/a?b=1&amp;c=2">the essay</a> now."#))
        XCTAssertEqual(String(notes.characters), "Read the essay now.")
        let link = notes.runs.compactMap(\.link).first
        XCTAssertEqual(link?.absoluteString, "https://example.com/a?b=1&c=2")
    }

    func testOnlyWebAndMailLinks() {
        XCTAssertNil(ShowNotes.href(in: #" href="javascript:alert(1)""#))
        XCTAssertEqual(ShowNotes.href(in: #" class="x" HREF='mailto:hi@example.com'"#)?.absoluteString, "mailto:hi@example.com")
    }

    func testBareAddressesBecomeLinks() throws {
        let notes = try XCTUnwrap(ShowNotes.attributed("Sponsor: https://example.com/deal"))
        XCTAssertEqual(notes.runs.compactMap(\.link).first?.absoluteString, "https://example.com/deal")
    }

    func testPlainTextKeepsItsLineBreaks() {
        XCTAssertEqual(text("Line one\nLine two"), "Line one\nLine two")
    }

    func testScriptsStylesAndCommentsAreDropped() {
        XCTAssertEqual(text("<style>p{color:red}</style><!-- hi --><p>Kept</p><script>x()</script>"), "Kept")
    }

    func testEmptyIsNothing() {
        XCTAssertNil(text("   "))
        XCTAssertNil(text("<p> </p>"))
    }
}
