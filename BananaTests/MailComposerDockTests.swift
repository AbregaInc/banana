#if DEBUG || MAIL_FIXTURES
import XCTest

/// The composer's box (direction A): docked, full height, folded into the field, put away; and the
/// switch at the start of a reply's To line (Reply all by default, Reply, Forward).
@MainActor
final class MailComposerDockTests: XCTestCase {

    // MARK: The state machine

    func testAReplyOpensDockedAndANewMessageAtFullHeight() {
        XCTAssertEqual(MailComposerDock(new: false).mode, .docked)
        XCTAssertEqual(MailComposerDock(new: true).mode, .full)
    }

    func testExpandAndCollapse() {
        var dock = MailComposerDock(new: false)
        XCTAssertEqual(dock.handle(.expand), .none)
        XCTAssertEqual(dock.mode, .full)
        XCTAssertEqual(dock.handle(.expand), .none)
        XCTAssertEqual(dock.mode, .full, "expanding the full box changes nothing")
        XCTAssertEqual(dock.handle(.collapse), .none)
        XCTAssertEqual(dock.mode, .docked)
        XCTAssertEqual(dock.handle(.collapse), .none)
        XCTAssertEqual(dock.mode, .docked)
    }

    func testTheHandleDragsUpToFullDownToDockedAndFurtherAway() {
        var dock = MailComposerDock(new: false)
        XCTAssertEqual(dock.handle(.dragEnded(translation: -20)), .none)
        XCTAssertEqual(dock.mode, .docked, "a wobble is nothing")
        XCTAssertEqual(dock.handle(.dragEnded(translation: -120)), .none)
        XCTAssertEqual(dock.mode, .full)
        XCTAssertEqual(dock.handle(.dragEnded(translation: 120)), .none)
        XCTAssertEqual(dock.mode, .docked)
        XCTAssertEqual(dock.handle(.dragEnded(translation: 100)), .none)
        XCTAssertEqual(dock.mode, .folded, "a short pull down folds it into the field")
        var docked = MailComposerDock(new: false)
        XCTAssertEqual(docked.handle(.dragEnded(translation: 400)), .putAway, "all the way down puts it away")
        var full = MailComposerDock(new: true)
        XCTAssertEqual(full.handle(.dragEnded(translation: 900)), .putAway)
    }

    func testReadingFoldsTheDockedBoxAndATapResumesInTheText() {
        var dock = MailComposerDock(new: false)
        XCTAssertEqual(dock.handle(.threadDraggedDown), .none)
        XCTAssertEqual(dock.mode, .folded)
        XCTAssertEqual(dock.handle(.threadDraggedDown), .none)
        XCTAssertEqual(dock.mode, .folded)
        XCTAssertEqual(dock.handle(.resume), .focusBody)
        XCTAssertEqual(dock.mode, .docked)
        XCTAssertEqual(dock.handle(.keyboardHidden), .none)
        XCTAssertEqual(dock.mode, .folded, "the keyboard put away folds it too")
        XCTAssertEqual(dock.handle(.expand), .focusBody)
        XCTAssertEqual(dock.mode, .full)
    }

    func testTheFullEditorIsNotFoldedByTheThreadOrTheKeyboard() {
        var dock = MailComposerDock(new: true)
        XCTAssertEqual(dock.handle(.threadDraggedDown), .none)
        XCTAssertEqual(dock.handle(.keyboardHidden), .none)
        XCTAssertEqual(dock.mode, .full)
        XCTAssertEqual(dock.handle(.resume), .none)
        XCTAssertEqual(dock.mode, .full)
    }

    func testTheAssistantsUndoHoldsOnlyWhileTheBodyIsWhatItWrote() {
        let undo = MailAssistantUndo(before: AttributedString("Thanks"), written: AttributedString("Yes, Friday works."))
        XCTAssertTrue(undo.isCurrent(AttributedString("Yes, Friday works.")))
        XCTAssertFalse(undo.isCurrent(AttributedString("Yes, Friday works. See you")))
    }

    // MARK: In the session

    private func session() -> (MailFixtureSource, MailSession) {
        let source = MailFixtureSource()
        let session = MailSession(source: source, now: source.now, deviceName: "Test",
                                  timers: MailTimers { _, _ in {} }, present: { _, _ in })
        session.enter()
        return (source, session)
    }

    private func id(_ key: String) -> MailConversationID {
        MailConversationID(account: MailFixtureConversations.account, thread: key)
    }

    func testTheSessionOpensTheDockAndPuttingItAwayKeepsTheDraft() async throws {
        let (source, session) = session()
        session.open(id("q3"))
        session.reply(.replyAll)
        let composer = try XCTUnwrap(session.composer)
        await composer.waitForDraft()
        XCTAssertEqual(session.navigation.dock?.mode, .docked)
        composer.body = "Thanks, I'll look at it tonight."
        session.dock(.threadDraggedDown)
        XCTAssertEqual(session.navigation.dock?.mode, .folded)
        XCTAssertNotNil(session.composer, "folded is still writing")
        session.dock(.resume)
        XCTAssertEqual(composer.focusRequest?.field, .body)
        session.dock(.dragEnded(translation: 600))
        XCTAssertNil(session.composer)
        XCTAssertNil(session.navigation.dock)
        let kept = await source.conversation(id("q3"))?.draft
        XCTAssertNotNil(kept, "swiped away, the draft is kept")
    }

    func testANewMessageOpensAtFullHeightWithToFirst() async throws {
        let (_, session) = session()
        session.compose()
        let composer = try XCTUnwrap(session.composer)
        XCTAssertEqual(session.navigation.dock?.mode, .full)
        XCTAssertEqual(composer.focusRequest?.field, .to)
    }

    // MARK: Reply all, Reply, Forward

    private func reply(_ key: String, _ style: MailReplyStyle = .replyAll) async throws -> (MailSession, MailComposerModel) {
        let (_, session) = session()
        session.open(id(key))
        session.reply(style)
        let composer = try XCTUnwrap(session.composer)
        await composer.waitForDraft()
        await composer.refreshReplyChoices()
        return (session, composer)
    }

    func testTheDefaultIsReplyAllToEveryoneButHimself() async throws {
        let (_, composer) = try await reply("q3")
        XCTAssertEqual(composer.replyStyle, .replyAll)
        XCTAssertEqual(composer.to.map(\.address), ["sam@lee.example", "jane@parkdesign.example"])
        XCTAssertFalse((composer.to + composer.cc).contains { $0.isMe || $0.address == MailFixtureConversations.account })
        XCTAssertFalse(composer.replyAllIsReply)
    }

    func testSwitchingToReplyKeepsTheTextAndAPersonAddedByHand() async throws {
        let (_, composer) = try await reply("q3")
        composer.body = "Thanks, I'll look at it tonight."
        composer.accept(MailPerson(name: "Pat Quinn", address: "pat@quinn.example", isMe: false, isKnown: true, fromTheirMail: false), into: .cc)
        composer.switchReply(to: .reply)
        await composer.waitForSwitch()
        XCTAssertEqual(composer.replyStyle, .reply)
        XCTAssertEqual(composer.to.map(\.address), ["sam@lee.example"])
        XCTAssertEqual(composer.cc.map(\.address), ["pat@quinn.example"], "added by hand, kept where he put it")
        XCTAssertEqual(composer.body, "Thanks, I'll look at it tonight.")
        composer.switchReply(to: .replyAll)
        await composer.waitForSwitch()
        XCTAssertEqual(composer.to.map(\.address), ["sam@lee.example", "jane@parkdesign.example"])
        XCTAssertEqual(composer.body, "Thanks, I'll look at it tonight.")
    }

    func testForwardGoesToNobodyAndCarriesTheOriginalsFiles() async throws {
        let (_, composer) = try await reply("q3")
        composer.body = "See below."
        composer.switchReply(to: .forward)
        await composer.waitForSwitch()
        XCTAssertEqual(composer.replyStyle, .forward)
        XCTAssertEqual(composer.to, [])
        XCTAssertEqual(composer.subject, "Fwd: Q3 numbers before Thursday")
        XCTAssertEqual(composer.body, "See below.")
        XCTAssertTrue(composer.quote?.attribution.contains("Forwarded message") == true)
        // What it carries is what a forward opened as one carries (the existing forward behaviour).
        let (_, direct) = try await reply("q3", .forward)
        XCTAssertEqual(composer.files.items.map(\.name), direct.files.items.map(\.name))
        XCTAssertEqual(composer.quote?.attribution, direct.quote?.attribution)
    }

    func testWithOneOtherPersonReplyAllIsReply() async throws {
        let (_, composer) = try await reply("receipt")
        XCTAssertTrue(composer.replyAllIsReply)
        XCTAssertEqual(MailReplyStyle.replyAll.label(sameAsReply: true), "Reply")
        XCTAssertEqual(MailReplyStyle.replyAll.label(sameAsReply: false), "Reply all")
    }
}
#endif
