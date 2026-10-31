#if DEBUG || MAIL_FIXTURES
import XCTest

/// Cc and Bcc in every composer (MAIL-UX 6.3.3): hidden until asked for, each completing against
/// the people in the sample mail as To does, chips that can be changed and moved, an address that
/// matches nobody accepted as what it is, and the keys typed on the way to the field going into it.
@MainActor
final class MailComposerRecipientsTests: XCTestCase {

    func testCcAndBccAreHiddenUntilAskedFor() async {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        XCTAssertTrue(composer.shows(.to))
        XCTAssertFalse(composer.shows(.cc))
        XCTAssertFalse(composer.shows(.bcc))
        XCTAssertEqual(composer.hiddenRows, [.cc, .bcc], "the words at the end of the To row")

        composer.reveal(.cc)
        XCTAssertTrue(composer.shows(.cc))
        XCTAssertEqual(composer.hiddenRows, [.bcc])
        XCTAssertEqual(composer.focusRequest?.field, .cc, "the caret goes to the row asked for")

        composer.reveal(.bcc)
        XCTAssertEqual(composer.hiddenRows, [])
        XCTAssertEqual(composer.focusRequest?.field, .bcc)
    }

    func testARowWithSomeoneInItIsShownWithoutBeingAskedFor() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        XCTAssertFalse(composer.shows(.cc))
        composer.cc = [MailFixtureConversations.jane]       // as reply to all fills it
        XCTAssertTrue(composer.shows(.cc))
        XCTAssertEqual(composer.hiddenRows, [.bcc])
    }

    func testEachRowCompletesAgainstThePeopleInTheMail() async throws {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        composer.reveal(.cc)
        composer.reveal(.bcc)

        composer.ccText = "sa"
        await composer.waitForSuggestions()
        XCTAssertEqual(composer.suggestionField, .cc)
        XCTAssertEqual(composer.suggestions.first?.address, "sam@lee.example")
        composer.acceptHighlightedOrCommit(.cc)
        XCTAssertEqual(composer.cc.map(\.address), ["sam@lee.example"])
        XCTAssertEqual(composer.ccText, "")
        XCTAssertEqual(composer.suggestions, [])

        composer.bccText = "ja"
        await composer.waitForSuggestions()
        XCTAssertEqual(composer.suggestionField, .bcc)
        composer.accept(try XCTUnwrap(composer.suggestions.first), into: .bcc)
        XCTAssertEqual(composer.bcc.map(\.address), ["jane@parkdesign.example"])
        XCTAssertEqual(composer.to, [], "each row is its own")
    }

    func testSomeoneAlreadyInARowIsNotOfferedOrAddedAgain() async {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        composer.cc = [MailFixtureConversations.sam]
        composer.toText = "sa"
        await composer.waitForSuggestions()
        XCTAssertFalse(composer.suggestions.contains { $0.address == "sam@lee.example" })

        composer.toText = ""
        composer.accept(MailFixtureConversations.sam, into: .to)
        XCTAssertEqual(composer.to, [], "he is in Cc already")
        XCTAssertEqual(composer.cc.map(\.address), ["sam@lee.example"])
    }

    func testAnAddressThatMatchesNobodyIsAcceptedAndShownByItsAddress() async throws {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        composer.reveal(.bcc)
        composer.bccText = "Pat Quinn <pat@quinn.example>,"
        let pat = try XCTUnwrap(composer.bcc.first)
        XCTAssertEqual(pat.address, "pat@quinn.example")
        XCTAssertFalse(pat.isKnown, "he has not written to this address")
        XCTAssertEqual(pat.chipLabel, "pat@quinn.example", "shown by its address, so a look-alike cannot pass for a friend")
        XCTAssertEqual(composer.bccText, "")
    }

    func testSomethingThatIsNotAnAddressStaysAsTypedAndStopsTheSendInItsRow() async {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        composer.reveal(.cc)
        composer.ccText = "sam@"
        XCTAssertEqual(composer.sendProblem(), .notAnAddress("sam@"))
        XCTAssertEqual(composer.problemField, .cc, "focus goes to the row with the problem")
        XCTAssertEqual(composer.ccText, "sam@", "nothing is thrown away")
        h.session.sendComposer()
        XCTAssertEqual(h.toasts.last?.text, "\u{201C}sam@\u{201D} isn't an address.")
        XCTAssertEqual(composer.focusRequest?.field, .cc)
        XCTAssertNotNil(h.composer, "and nothing was sent")
    }

    func testAMessageToBccAloneCanBeSent() async {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        composer.bcc = [MailFixtureConversations.jane]
        composer.body = "Hello"
        XCTAssertNil(composer.sendProblem())
    }

    func testAChipCanBeEditedMovedAndRemoved() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        let sam = try XCTUnwrap(composer.to.first)

        composer.move(sam, to: .bcc)
        XCTAssertEqual(composer.to, [])
        XCTAssertEqual(composer.bcc.map(\.address), ["sam@lee.example"])
        XCTAssertTrue(composer.shows(.bcc))

        composer.edit(sam)
        XCTAssertEqual(composer.bcc, [], "the chip is text again")
        XCTAssertEqual(composer.bccText, "sam@lee.example")
        XCTAssertEqual(composer.focusRequest?.field, .bcc)

        composer.bccText = "sam@lee.example,"
        XCTAssertEqual(composer.bcc.map(\.address), ["sam@lee.example"], "and a chip again")

        composer.removeLastRecipient(from: .bcc)
        XCTAssertEqual(composer.bcc, [])
        composer.cc = [MailFixtureConversations.jane]
        composer.remove(MailFixtureConversations.jane)
        XCTAssertEqual(composer.cc, [])
    }

    func testCcAndBccAreKeptWithTheDraftAndGoOutWithTheMessage() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        let draft = try XCTUnwrap(composer.draftID)
        composer.cc = [MailFixtureConversations.jane]
        composer.bcc = [MailFixtureConversations.ana]
        composer.body = "Looping you both in."
        composer.flush()
        let kept = await h.source.draft(draft)
        XCTAssertEqual(kept?.cc.map(\.address), ["jane@parkdesign.example"])
        XCTAssertEqual(kept?.bcc.map(\.address), ["ana@northwind.example"])

        h.session.sendComposer()
        let sent = try await h.lastMessage("q3")
        XCTAssertEqual(sent.cc.map(\.address), ["jane@parkdesign.example"])
        XCTAssertEqual(sent.bcc.map(\.address), ["ana@northwind.example"])
    }

    func testAComposerWithOnlyABccIsContentAndIsKept() async {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        XCTAssertFalse(composer.hasContent)
        composer.bcc = [MailFixtureConversations.jane]
        XCTAssertTrue(composer.hasContent, "he chose someone")
    }

    // MARK: Keys on the way to the caret (K12)

    func testKeysTypedBeforeTheCaretLandInTheCcFieldAndTriggerNoCommand() async throws {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        let inbox = h.session.model.rows.map(\.id)
        composer.reveal(.cc)                             // asks for the caret in Cc

        // "sae": s, a and e are letters, and e is also Done. Nothing here is a command.
        for key: Character in ["s", "a", "e"] { h.press(key) }
        XCTAssertEqual(composer.typedAhead, "sae")
        XCTAssertEqual(h.session.model.rows.map(\.id), inbox, "nothing was marked Done")
        XCTAssertTrue(h.session.undoStack.isEmpty)

        composer.focusLanded(on: .cc)
        XCTAssertEqual(composer.ccText, "sae", "in order, in the field the caret landed in")
        XCTAssertEqual(composer.toText, "")
        XCTAssertEqual(composer.typedAhead, "")
    }

    func testKeysTypedOnTheWayToBccLandInBcc() async {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        composer.reveal(.bcc)
        h.press("j")
        composer.focusLanded(on: .bcc)
        XCTAssertEqual(composer.bccText, "j")
    }
}
#endif
