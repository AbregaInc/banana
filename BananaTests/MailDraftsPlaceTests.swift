#if DEBUG || MAIL_FIXTURES
import XCTest

/// The Drafts place (MAIL-UX 6.6): every draft he has written something into, replies and new
/// messages, newest first, with who it is to, what it is called and what it begins with; choosing
/// one opens its composer; discarding from there has Undo. And what a reply draft left in its
/// conversation stays.
@MainActor
final class MailDraftsPlaceTests: XCTestCase {

    /// Three drafts, written a minute apart: a new message, a reply and another new message.
    private func threeDrafts(_ h: MailWriteHarness) async -> [MailDraftID] {
        var ids: [MailDraftID] = []
        let first = await h.newMessage()
        first.toText = "pat@quinn.example,"
        first.subject = "Lunch"
        first.body = "Are you free on Thursday?\nLet me know."
        ids.append(first.draftID!)
        h.session.closeComposer()

        h.manual.advance(by: 60)
        let second = await h.reply(to: "q3")
        second.body = "Will look tonight."
        ids.append(second.draftID!)
        h.session.closeComposer()

        h.manual.advance(by: 60)
        let third = await h.newMessage()
        third.subject = "No one yet"
        third.body = "A note to myself"
        ids.append(third.draftID!)
        h.session.closeComposer()
        return ids
    }

    func testDraftsHoldsEveryKeptDraftNewestFirstWithWhoTheSubjectAndTheFirstLine() async throws {
        let h = MailWriteHarness()
        _ = await threeDrafts(h)
        XCTAssertEqual(h.count(.drafts), 3, "the count the control column shows")

        let rows = h.rows(.drafts)
        XCTAssertEqual(rows.map(\.subject), ["No one yet", "Re: Q3 numbers before Thursday", "Lunch"],
                       "newest first")
        XCTAssertEqual(rows.map(\.snippet), ["A note to myself", "Will look tonight.", "Are you free on Thursday?"])
        XCTAssertEqual(rows[1].people.map(\.address), ["sam@lee.example"], "who a reply is to")
        XCTAssertEqual(rows[2].people.map(\.address), ["pat@quinn.example"])
        XCTAssertEqual(rows[0].people, [], "nobody yet")
        XCTAssertEqual(rows[2].reason, .draft(firstLine: "Are you free on Thursday?"))

        // What the row says, as the list draws it.
        let displays = rows.map { MailRowDisplay($0, now: h.session.now) }
        XCTAssertEqual(displays.map(\.who), ["No recipient", "Sam Lee", "pat@quinn.example"])
        XCTAssertEqual(displays.map(\.subject), ["No one yet", "Q3 numbers before Thursday", "Lunch"])
        XCTAssertEqual(displays.map(\.draft), ["A note to myself", "Will look tonight.", "Are you free on Thursday?"])
    }

    func testEditingADraftBringsItToTheTop() async throws {
        let h = MailWriteHarness()
        let ids = await threeDrafts(h)
        h.manual.advance(by: 60)
        h.session.begin(.continuing(ids[0]), requestFocus: false)
        let composer = try XCTUnwrap(h.composer)
        await composer.waitForDraft()
        composer.body += "\nAnd bring the menu."
        h.session.closeComposer()
        XCTAssertEqual(h.rows(.drafts).map(\.subject).first, "Lunch")
        XCTAssertEqual(h.rows(.drafts).count, 3, "the same draft, not another")
    }

    func testAComposerWithNothingInItIsNotAFinishedDraft() async {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        XCTAssertNotNil(composer.draftID)
        XCTAssertEqual(h.count(.drafts), 0, "open and empty is not a draft yet")
        composer.body = "Something"
        composer.flush()
        XCTAssertEqual(h.count(.drafts), 1)
    }

    func testTheMarkInTheConversationAndTheLineOnItsRowStayWhereTheyWere() async throws {
        let h = MailWriteHarness()
        let ids = await threeDrafts(h)
        let conversation = try await h.thread("q3")
        XCTAssertEqual(conversation.draft, ids[1], "the conversation shows its draft")
        let row = try XCTUnwrap(h.rows(.inbox).first { $0.id == h.id("q3") })
        XCTAssertEqual(row.reason, .draft(firstLine: "Will look tonight."), "and the inbox row says Draft ·")
        XCTAssertFalse(h.rows(.done).contains { $0.id.thread.hasPrefix("local:") },
                       "a new message's draft is not in Done")
    }

    func testChoosingAReplyDraftOpensItsComposerInItsConversation() async throws {
        let h = MailWriteHarness()
        let ids = await threeDrafts(h)
        h.session.show(.drafts)
        h.session.open(h.id("q3"))                          // a tap on its row
        await h.session.settle()
        XCTAssertEqual(h.session.openConversation, h.id("q3"), "it opens in its conversation")
        let composer = try XCTUnwrap(h.composer)
        await composer.waitForDraft()
        XCTAssertEqual(composer.host, h.id("q3"))
        XCTAssertEqual(composer.draftID, ids[1])
        XCTAssertEqual(composer.body, "Will look tonight.")
        XCTAssertEqual(composer.title, "Reply")
    }

    func testChoosingANewMessageDraftOpensTheComposerAlone() async throws {
        let h = MailWriteHarness()
        let ids = await threeDrafts(h)
        h.session.show(.drafts)
        let row = try XCTUnwrap(h.rows(.drafts).first { $0.subject == "Lunch" })
        h.session.select(row.id)
        await h.session.settle()
        let composer = try XCTUnwrap(h.composer)
        await composer.waitForDraft()
        XCTAssertNil(composer.host, "a new message is written in no conversation")
        XCTAssertNil(h.session.openConversation)
        XCTAssertEqual(composer.draftID, ids[0])
        XCTAssertEqual(composer.subject, "Lunch")
        XCTAssertEqual(composer.to.map(\.address), ["pat@quinn.example"])
        XCTAssertEqual(composer.body, "Are you free on Thursday?\nLet me know.")
    }

    func testReturnOnTheCursorOpensTheDraftToo() async throws {
        let h = MailWriteHarness()
        _ = await threeDrafts(h)
        h.session.show(.drafts)
        XCTAssertTrue(h.session.handle(.returnKey))
        await h.session.settle()
        let composer = try XCTUnwrap(h.composer, "the cursor is on the newest")
        await composer.waitForDraft()
        XCTAssertEqual(composer.subject, "No one yet")
    }

    func testDiscardingFromDraftsHasUndoAndTheCountFollows() async throws {
        let h = MailWriteHarness()
        _ = await threeDrafts(h)
        h.session.show(.drafts)
        let row = try XCTUnwrap(h.rows(.drafts).first { $0.subject == "Lunch" })
        h.session.select(row.id)
        await h.session.settle()
        let composer = try XCTUnwrap(h.composer)
        await composer.waitForDraft()

        h.session.discardComposer()
        XCTAssertNil(h.composer)
        XCTAssertEqual(h.toasts.last, MailToastText.draftDiscarded, "\"Draft discarded\", with Undo")
        XCTAssertEqual(h.count(.drafts), 2)
        XCTAssertFalse(h.rows(.drafts).contains { $0.subject == "Lunch" })

        h.session.undoTop()
        let back = try XCTUnwrap(h.composer, "Undo brings it back and he is writing it again")
        await back.waitForDraft()
        XCTAssertEqual(back.subject, "Lunch")
        XCTAssertEqual(back.body, "Are you free on Thursday?\nLet me know.")
        XCTAssertEqual(h.count(.drafts), 3)
    }

    func testDiscardingTheMarkInAConversationUpdatesDraftsToo() async throws {
        let h = MailWriteHarness()
        let ids = await threeDrafts(h)
        h.session.discardKept(ids[1])
        XCTAssertEqual(h.count(.drafts), 2)
        XCTAssertEqual(h.toasts.last, MailToastText.draftDiscarded)
    }

    func testNothingInDraftsIsDoneOrStarredByAKey() async throws {
        let h = MailWriteHarness()
        _ = await threeDrafts(h)
        let inbox = h.rows(.inbox).map(\.id)
        h.session.show(.drafts)
        XCTAssertTrue(h.press("e"))
        XCTAssertTrue(h.press("s"))
        XCTAssertTrue(h.press("e", shift: true))
        XCTAssertEqual(h.rows(.inbox).map(\.id), inbox, "the conversation a reply draft is in was not touched")
        XCTAssertTrue(h.session.undoStack.isEmpty)
        h.session.act(.done)
        XCTAssertTrue(h.session.undoStack.isEmpty, "nor by a button or a swipe")
    }

    func testTheSendOfADraftTakesItOutOfDrafts() async throws {
        let h = MailWriteHarness()
        let ids = await threeDrafts(h)
        h.session.begin(.continuing(ids[1]), requestFocus: false)
        let composer = try XCTUnwrap(h.composer)
        await composer.waitForDraft()
        h.session.sendComposer()
        XCTAssertEqual(h.count(.drafts), 2)
    }
}
#endif
