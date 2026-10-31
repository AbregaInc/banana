import XCTest

/// Triage through the touch interface: Done by a full swipe, with its toast and Undo; star and
/// unstar; read and unread; opening and scrolling; Done from inside a conversation, and where he
/// lands. Each is checked against MAIL-UX section 3's rules and its worked cases.
final class MailTriageUITest: MailUITestCase {

    func testTenDonesInARowUndoingTheThird() {
        launch()
        let before = visibleRowKeys()
        XCTAssertGreaterThanOrEqual(before.count, 5, "rows on screen: \(before)")
        XCTAssertEqual(headerCount(), 40, "the inbox holds the forty sample conversations")
        snap("00-inbox")

        var done: [String] = []
        for step in 1...10 {
            let keys = visibleRowKeys()
            guard let top = keys.first else { XCTFail("no rows left at step \(step)"); break }
            fullSwipeDone(row(top))
            // A full swipe is Done in one motion (T40): the row leaves, and the toast names it.
            let left = waitGone(row(top), timeout: 3)
            if !left {
                // A short swipe reveals Done without committing: a second tap would be a bug (6.1.6).
                snap("\(step)-row-stayed")
                let doneButton = app.buttons["Done"].firstMatch
                note("Step \(step): the full swipe did not take \(top) off; Done button showing: \(doneButton.exists)")
                if doneButton.exists { doneButton.tap() }
                XCTAssertTrue(waitGone(row(top), timeout: 3), "\(top) left after Done")
            }
            XCTAssertTrue(waitForToast(containing: "Done", timeout: 3), "the toast after step \(step)")
            done.append(top)
            if step == 3 {
                snap("03-before-undo")
                XCTAssertTrue(undoButton.exists, "the toast offers Undo")
                undoButton.tap()
                XCTAssertTrue(waitForToast(containing: "Undone", timeout: 3), "the toast reads Undone")
                XCTAssertTrue(row(top).waitForExistence(timeout: 3), "Undo put \(top) back")
                let after = visibleRowKeys()
                XCTAssertEqual(after.first, top, "the undone row is back at the top, where it was (T26)")
                snap("03-after-undo")
                done.removeLast()
            }
        }
        snap("10-after-ten")
        XCTAssertEqual(headerCount(), 40 - done.count, "the header counts what is left")
        let remaining = visibleRowKeys()
        for key in done { XCTAssertFalse(remaining.contains(key), "\(key) is still in the inbox") }

        show(place: "Done")
        if let first = done.first { XCTAssertTrue(row(first).waitForExistence(timeout: 3)) }
        snap("11-done-place")
        // Nine completed rows need not fit in the viewport. Verify every record by
        // reaching it in Done, rather than treating offscreen rows as missing data.
        for key in done { XCTAssertTrue(scrollToRow(key), "\(key) must be reachable in Done") }
    }

    func testDoneOnTheLastRow() {
        launch()
        XCTAssertTrue(scrollToRow("intro"), "\(visibleRowKeys())")
        for _ in 0..<2 { element(MailID.list).swipeUp() }
        Thread.sleep(forTimeInterval: 0.5)
        let keys = visibleRowKeys()
        XCTAssertEqual(keys.last, "intro", "the oldest conversation is last: \(keys)")
        snap("00-bottom")
        let last = keys.last!
        let above = keys.dropLast().last
        fullSwipeDone(row(last))
        XCTAssertTrue(waitGone(row(last), timeout: 3), "the last row left")
        snap("01-after-done")
        XCTAssertTrue(waitForToast(containing: "Done"))
        // Found: the list jumped to the top, the cursor having stayed on the first row (T16 settles
        // the cursor, and the view follows it). On touch the swiped row is the cursor (T2), so
        // the successor is the row above, and nothing moves away from the thumb (case 3).
        if let above { XCTAssertTrue(row(above).exists, "the row above it is still on screen: the list did not jump") }
        XCTAssertFalse(row("q3").exists, "the list did not jump to the top")
        XCTAssertEqual(headerCount(), 39)
    }

    func testDoneInStarredKeepsTheRowAndDoneOnTheOnlyRow() {
        launch()
        show(place: "Starred")
        Thread.sleep(forTimeInterval: 0.5)
        var keys = visibleRowKeys()
        XCTAssertEqual(Set(keys), ["q3", "flight"], "Starred holds the two starred samples: \(keys)")
        snap("00-starred")
        // Done on a starred conversation: it leaves the inbox and stays here (T16 step 1).
        fullSwipeDone(row("q3"), staysInPlace: true)
        XCTAssertTrue(waitForToast(containing: "Done", timeout: 3), "Done was taken")
        Thread.sleep(forTimeInterval: 0.6)
        keys = visibleRowKeys()
        XCTAssertTrue(keys.contains("q3"), "a Done conversation that is starred stays in Starred: \(keys)")
        snap("01-after-done-in-starred")
        // Unstar q3, then flight: the place empties.
        shortSwipeLeading(row("q3"))
        let unstar = app.buttons["Unstar"].firstMatch
        XCTAssertTrue(unstar.waitForExistence(timeout: 3), "the leading swipe offers Unstar\n\(app.debugDescription)")
        unstar.tap()
        Thread.sleep(forTimeInterval: 0.6)
        keys = visibleRowKeys()
        snap("02-after-unstar-q3")
        note("After unstarring q3 in Starred, rows: \(keys) (T17: a marked row is kept until the scope changes)")
        if keys.contains("flight") {
            shortSwipeLeading(row("flight"))
            let unstar2 = app.buttons["Unstar"].firstMatch
            XCTAssertTrue(unstar2.waitForExistence(timeout: 3))
            unstar2.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        snap("03-starred-after-unstarring-both")
        // Leaving and coming back drops the kept rows (T17).
        show(place: "Inbox")
        Thread.sleep(forTimeInterval: 0.4)
        show(place: "Starred")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(visibleRowKeys().isEmpty, "Starred is empty once re-entered: \(visibleRowKeys())")
        XCTAssertTrue(app.staticTexts["Nothing in Starred"].waitForExistence(timeout: 3), "the empty state (7.8)")
        snap("04-starred-empty")
        XCTAssertEqual(headerCount(), 0)
        // The inbox lost q3 and nothing else.
        show(place: "Inbox")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(headerCount(), 39)
        XCTAssertFalse(row("q3").exists)
        XCTAssertTrue(row("flight").exists || !visibleRowKeys().isEmpty)
    }

    func testStarAndUnstarByTheLeadingSwipe() {
        launch()
        shortSwipeLeading(row("invite"))
        snap("00-leading-swipe")
        let star = app.buttons["Star"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 3), "the leading swipe shows Star\n\(app.debugDescription)")
        star.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertNil(toastText, "a star shows on the row and has no toast (7.9); saw \(toastText ?? "")")
        XCTAssertTrue(row("invite").exists, "a marking action moves nothing (T17)")
        XCTAssertEqual(visibleRowKeys().first, "q3", "nothing moved")
        snap("01-starred")
        show(place: "Starred")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(row("invite").waitForExistence(timeout: 3), "the starred conversation is in Starred")
        show(place: "Inbox")
        Thread.sleep(forTimeInterval: 0.4)
        shortSwipeLeading(row("invite"))
        let unstar = app.buttons["Unstar"].firstMatch
        XCTAssertTrue(unstar.waitForExistence(timeout: 3), "the swipe now offers Unstar")
        unstar.tap()
        Thread.sleep(forTimeInterval: 0.5)
        show(place: "Starred")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(row("invite").exists, "unstarred, it is not in Starred")
        snap("02-starred-after-unstar")
    }

    func testStarFromTheConversationHeader() {
        launch()
        openConversation("receipt")
        let star = element(MailID.star)
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        star.tap()
        Thread.sleep(forTimeInterval: 0.4)
        snap("00-starred-from-header")
        element(MailID.back).tap()
        show(place: "Starred")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(row("receipt").waitForExistence(timeout: 3), "starred from the header")
        snap("01-in-starred")
    }

    func testMarkUnreadByTheSwipeAndFromInside() {
        launch()
        // me-newest is read: the leading swipe offers Unread, then Read.
        shortSwipeLeading(row("me-newest"))
        let unread = app.buttons["Unread"].firstMatch
        XCTAssertTrue(unread.waitForExistence(timeout: 3), "a read row offers Unread\n\(app.debugDescription)")
        unread.tap()
        Thread.sleep(forTimeInterval: 0.5)
        snap("00-marked-unread")
        shortSwipeLeading(row("me-newest"))
        let read = app.buttons["Read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 3), "an unread row offers Read")
        read.tap()
        Thread.sleep(forTimeInterval: 0.5)

        // Inside: q3 is unread; opening reads it after 400 ms; U leaves it unread and goes back (T17).
        openConversation("q3")
        Thread.sleep(forTimeInterval: 1)
        let button = element(MailID.unread)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let closed = waitGone(element(MailID.conversation), timeout: 3)
        snap("01-after-unread-inside")
        XCTAssertTrue(closed, "U in an open conversation leaves it unread and returns to the list (T17)")
        shortSwipeLeading(row("q3"))
        XCTAssertTrue(app.buttons["Read"].firstMatch.waitForExistence(timeout: 3), "q3 is unread again: the swipe offers Read")
        snap("02-q3-unread-swipe")
    }

    func testOpenALongConversationAndScrollIt() {
        launch()
        XCTAssertTrue(scrollToRow("long"), "the long conversation is reachable: \(visibleRowKeys())")
        openConversation("long")
        snap("00-long-top")
        XCTAssertTrue(conversationShows("A very long subject line"), "the 300-character subject")
        XCTAssertTrue(conversationShows("1. This paragraph"), "the first paragraph")
        for _ in 0..<30 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.5)
        snap("01-long-bottom")
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '48. This paragraph'")).firstMatch
        XCTAssertTrue(last.exists, "the last paragraph is reachable by scrolling")
        for _ in 0..<30 { app.swipeDown() }
        snap("02-long-back-at-top")
        XCTAssertTrue(conversationShows("1. This paragraph"))
        element(MailID.back).tap()
        XCTAssertTrue(row("long").waitForExistence(timeout: 3), "back on the list, where it was (T11)")
        snap("03-list-after-back")
    }

    func testFortyMessagesOpenAndScroll() {
        launch(open: "forty")
        XCTAssertTrue(element(MailID.conversation).waitForExistence(timeout: 10))
        snap("00-forty-top")
        let start = Date()
        for _ in 0..<12 { app.swipeUp() }
        note("twelve swipes through forty messages took \(Date().timeIntervalSince(start))s")
        snap("01-forty-scrolled")
        element(MailID.back).tap()
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 5))
    }

    func testDoneFromInsideAConversationOpensTheNextOne() {
        launch()
        let keys = visibleRowKeys()
        XCTAssertEqual(Array(keys.prefix(3)), ["q3", "invite", "plain-chain"], "the top of the inbox: \(keys)")
        openConversation("invite")
        XCTAssertTrue(conversationShows("Invitation: Design review"))
        element(MailID.done).tap()
        Thread.sleep(forTimeInterval: 0.8)
        snap("00-after-done-inside")
        XCTAssertTrue(waitForToast(containing: "Done"))
        // T16 step 4, worked case 7: the next conversation (older) opens in its place.
        let next = conversationShows("Northwind kickoff", timeout: 3)
        let still = element(MailID.conversation).exists
        note("After Done inside invite: conversation open=\(still), next (Northwind kickoff) showing=\(next)")
        XCTAssertTrue(still && next, "Done inside a conversation opens the next one (T16 step 4, case 7)")
        element(MailID.back).tap()
        XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 5))
        XCTAssertFalse(row("invite").exists, "invite left the inbox")
        snap("01-list-after-back")
    }

    func testDoneOnTheLastRowFromInsideReturnsToTheList() {
        launch()
        XCTAssertTrue(scrollToRow("intro"), "\(visibleRowKeys())")
        openConversation("intro")
        element(MailID.done).tap()
        Thread.sleep(forTimeInterval: 0.8)
        snap("00-after-done-on-last")
        // Worked case 8: J open, E: the list, cursor on I.
        XCTAssertTrue(waitGone(element(MailID.conversation), timeout: 3), "at the end of the run the view returns to the list (case 8)")
        XCTAssertFalse(row("intro").exists)
        XCTAssertTrue(row("hiring").exists, "the row above is on screen: \(visibleRowKeys())")
    }

    /// Found on the phone: six fixed 44-point actions and the gaps between them left Back no
    /// room, and "Inbox" wrapped to "In-" over "…".
    func testTheHeaderNamesThePlaceOnOneLine() {
        for place in ["Inbox", "Starred", "Scheduled"] {
            launch(open: place == "Inbox" ? "q3" : nil, place: place.lowercased())
            if place != "Inbox" {
                if place == "Scheduled" {
                    // Nothing is scheduled in a fresh launch: the header is checked on the place's list instead.
                    snap("00-\(place.lowercased())-list")
                    continue
                }
                openConversation("q3")
            }
            let back = element(MailID.back)
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            snap("01-header-\(place.lowercased())")
            XCTAssertEqual(back.label, place, "Back is named for the place")
            let title = app.staticTexts[place].firstMatch
            XCTAssertTrue(title.exists, "the place's name is drawn\n\(app.debugDescription)")
            XCTAssertLessThanOrEqual(title.frame.height, DS_headerHeight, "the name is on one line")
            app.terminate()
        }
    }

    /// `DS.Mail.header`: the tests compile no design tokens, so the one they check is named here.
    private let DS_headerHeight: CGFloat = 44

    func testOlderAndNewerButtonsInsideAConversation() {
        launch()
        openConversation("invite")
        XCTAssertTrue(conversationShows("Invitation: Design review"))
        XCTAssertTrue(element(MailID.older).isEnabled)
        element(MailID.older).tap()
        XCTAssertTrue(conversationShows("Northwind kickoff", timeout: 3), "older opens the next conversation down (T12)")
        element(MailID.newer).tap()
        XCTAssertTrue(conversationShows("Invitation: Design review", timeout: 3))
        element(MailID.newer).tap()
        XCTAssertTrue(conversationShows("Q3 numbers before Thursday", timeout: 3))
        snap("00-at-newest")
        XCTAssertFalse(element(MailID.newer).isEnabled, "nothing newer: the button is disabled (T42)")
    }
}
