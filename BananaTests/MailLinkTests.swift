import XCTest

final class MailLinkTests: XCTestCase {
    func testReceivedLinksAreInteractiveAndKeepTheirDestination() {
        let url = URL(string: "https://example.com/invite?a=1&b=2")!
        let text = MailAttributedText.make([MailTextRun(text: "Accept invite", link: url)])
        XCTAssertEqual(text.runs.first?.link, url)
        XCTAssertEqual(String(text.characters), "Accept invite")
    }
    func testReceivedUnsafeLinksDoNotBecomeInteractive() {
        for value in ["javascript:alert(1)", "file:///private/test", "data:text/html,test", "https:"] {
            let text = MailAttributedText.make([MailTextRun(text: "Link", link: URL(string: value))])
            XCTAssertNil(text.runs.first?.link)
        }
    }
}
