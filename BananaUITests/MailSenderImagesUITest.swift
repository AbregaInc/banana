import XCTest

/// Sender pictures over the faces (MAIL-UX "Sender images"), on the sample mail with drawn stand-ins
/// (`--mail-sender-images`, Debug: nothing leaves the device). The rows keep their places and
/// heights whether a picture came or not, and the list still scrolls and opens.
final class MailSenderImagesUITest: MailUITestCase {

    /// Each visible row's key and frame, top to bottom.
    private func rowFrames() -> [String: CGRect] {
        let prefix = MailID.list + ".row."
        guard let list = try? element(MailID.list).snapshot() else { return [:] }
        var found: [String: CGRect] = [:]
        func visit(_ seen: XCUIElementSnapshot) {
            if seen.identifier.hasPrefix(prefix), seen.frame.height > 0,
               seen.frame.minY >= list.frame.minY - 1, seen.frame.maxY <= list.frame.maxY + 1 {
                found[String(seen.identifier.dropFirst(prefix.count))] = seen.frame
            }
            for child in seen.children { visit(child) }
        }
        visit(list)
        return found
    }

    func testPicturesComeInWithoutMovingARow() {
        launch()
        let without = rowFrames()
        XCTAssertFalse(without.isEmpty)
        app.terminate()

        launch(extra: ["--mail-sender-images"])
        // Read after the screenshot too: by then the pictures have come in and faded up.
        snap("inbox")
        let with = rowFrames()
        XCTAssertEqual(Set(with.keys), Set(without.keys), "the same rows on screen")
        for (key, frame) in with {
            XCTAssertEqual(frame.minY, without[key]?.minY ?? -1, accuracy: 0.5, "\(key) did not move")
            XCTAssertEqual(frame.height, without[key]?.height ?? -1, accuracy: 0.5, "\(key) kept its height")
        }
        element(MailID.list).swipeUp()
        snap("inbox-scrolled")
        guard let first = visibleRowKeys().first else { return XCTFail("rows after the scroll") }
        row(first).tap()
        if !hasPane {
            XCTAssertTrue(element(MailID.conversation).waitForExistence(timeout: 10))
        }
        snap("open")
    }
}
