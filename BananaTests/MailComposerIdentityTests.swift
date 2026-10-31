#if DEBUG || MAIL_FIXTURES
import XCTest

/// Who a message is from and what signs it (MAIL-UX 6.3.3, 6.3.4): From shown only when there is a
/// choice, a reply from the address the message was sent to, a change of From swapping the
/// signature with it, and a signature that is its own block, comes off for one message, and is
/// never mangled by editing the text.
@MainActor
final class MailComposerIdentityTests: XCTestCase {

    private let z0 = MailFixtureConversations.account
    private let alias = MailFixtureConversations.alias
    private let abrega = MailFixtureConversations.secondAccount

    private func lines(_ part: MailDraftPart?) -> [String] {
        part?.text?.blocks.map { MailAttributedText.plain($0.runs) } ?? []
    }

    // MARK: From

    /// A source with one address to send as: nothing to choose.
    @MainActor
    private final class OneIdentity: MailSource {
        var accounts: [MailAccount] {
            [MailAccount(id: "me@example.com", shortName: "me", wantsMail: true, state: .connected,
                         health: .live, lastSyncAt: nil,
                         identities: [MailIdentity(account: "me@example.com", address: "me@example.com",
                                                   name: nil, isDefault: true, hasSignature: false)],
                         keptAfterRemoval: 0)]
        }
    }

    func testFromIsShownOnlyWhenThereIsMoreThanOneAddressToChoose() async {
        let one = MailComposerModel(start: .new, source: OneIdentity(), timers: .live, clock: Date.init,
                                    device: "Mac", requestFocus: false)
        XCTAssertEqual(one.identities.count, 1)
        XCTAssertFalse(one.showsFrom)

        let h = MailWriteHarness()
        let composer = await h.newMessage()
        XCTAssertEqual(composer.identities.map(\.address), [z0, alias, abrega],
                       "two accounts, and a second address on the first")
        XCTAssertTrue(composer.showsFrom)
    }

    func testANewMessageIsFromTheDefaultAddress() async {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        XCTAssertEqual(composer.from?.address, z0)
    }

    func testAReplyIsFromTheAddressTheMessageWasSentTo() async {
        let h = MailWriteHarness()
        let toTheAlias = await h.reply(to: "vip-1")
        XCTAssertEqual(toTheAlias.from?.address, alias, "sent to hello@plan.example")
        h.session.closeComposer()

        let toTheOtherAccount = await h.reply(to: "photos")
        XCTAssertEqual(toTheOtherAccount.from?.address, abrega, "sent to his other account")
        h.session.closeComposer()

        let toTheDefault = await h.reply(to: "q3")
        XCTAssertEqual(toTheDefault.from?.address, z0)
    }

    func testChangingFromSwapsTheSignatureAndTheSourceHasBoth() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        let draft = try XCTUnwrap(composer.draftID)
        XCTAssertEqual(lines(composer.signature), ["Noor", "Abrega Inc. \u{00B7} plan.example"])

        composer.changeFrom(to: try XCTUnwrap(composer.identities.first { $0.address == alias }))
        XCTAssertEqual(composer.from?.address, alias, "the row says so at once")
        await composer.waitForIdentity()
        XCTAssertEqual(lines(composer.signature).first, "Noor at work", "and the signature went with it")
        let kept = await h.source.draft(draft)
        XCTAssertEqual(kept?.from.address, alias)
        XCTAssertEqual(lines(kept?.signature).first, "Noor at work")

        composer.changeFrom(to: try XCTUnwrap(composer.identities.first { $0.address == abrega }))
        await composer.waitForIdentity()
        XCTAssertNil(composer.signature, "the other account signs nothing")
        XCTAssertFalse(composer.canPutSignatureBack, "there is none to put back")
        let signed = await h.source.draft(draft)
        XCTAssertNil(signed?.signature)
    }

    func testChangingFromLeavesTheTextThePeopleAndTheQuoteAlone() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        composer.body = "Thanks, Sam."
        composer.cc = [MailFixtureConversations.jane]
        let quote = composer.quote
        composer.changeFrom(to: try XCTUnwrap(composer.identities.first { $0.address == alias }))
        await composer.waitForIdentity()
        XCTAssertEqual(composer.body, "Thanks, Sam.")
        XCTAssertEqual(composer.to.map(\.address), ["sam@lee.example"])
        XCTAssertEqual(composer.cc.map(\.address), ["jane@parkdesign.example"])
        XCTAssertEqual(composer.quote, quote)
        let draft = try XCTUnwrap(composer.currentDraft())
        XCTAssertEqual(draft.from.address, alias, "what is handed to the source says who it is from")
        XCTAssertEqual(MailPlainText.string(draft.body), "Thanks, Sam.")
    }

    func testTheMessageGoesOutFromTheAddressChosen() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        composer.body = "On it."
        composer.changeFrom(to: try XCTUnwrap(composer.identities.first { $0.address == alias }))
        await composer.waitForIdentity()
        h.session.sendComposer()
        let sent = try await h.lastMessage("q3")
        XCTAssertEqual(sent.from.address, alias)
    }

    // MARK: The signature

    func testANewMessageAndAReplyBothCarryTheirSignatureAsAPartOfTheDraft() async {
        let h = MailWriteHarness()
        let new = await h.newMessage()
        XCTAssertEqual(lines(new.signature), ["Noor", "Abrega Inc. \u{00B7} plan.example"])
        XCTAssertNil(new.quote)
        h.session.closeComposer()

        let reply = await h.reply(to: "q3")
        XCTAssertEqual(lines(reply.signature), ["Noor", "Abrega Inc. \u{00B7} plan.example"])
        XCTAssertNotNil(reply.quote, "the signature is under the text and above this")
    }

    func testOneIdentityHasNoSignatureToShowThatCase() async {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "photos")
        XCTAssertEqual(composer.from?.address, abrega)
        XCTAssertNil(composer.signature)
        XCTAssertFalse(composer.canPutSignatureBack)
    }

    func testTheSignatureIsNeverMangledByEditingTheBody() async throws {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        let signature = try XCTUnwrap(composer.signature)
        for text in ["", "H", "Hello,\n\nthanks.", "Noor\nAbrega Inc. \u{00B7} plan.example", "x"] {
            composer.body = text
            XCTAssertEqual(composer.signature, signature, "the part is the part, whatever the text does")
            let draft = try XCTUnwrap(composer.currentDraft())
            XCTAssertEqual(draft.signature, signature, "and it is what the source is handed")
            XCTAssertEqual(MailPlainText.string(draft.body), text, "the body is what he typed and nothing more")
        }
        composer.body = "Hi"
        composer.toText = "sam@lee.example,"
        composer.flush()
        let kept = await h.source.draft(try XCTUnwrap(composer.draftID))
        XCTAssertEqual(kept?.signature, signature)
        XCTAssertEqual(MailPlainText.string(try XCTUnwrap(kept).body), "Hi")
    }

    func testTheSignatureComesOffForThisMessageOnlyAndCanBePutBack() async throws {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        composer.body = "Quick one."
        composer.removeSignature()
        XCTAssertNil(composer.signature)
        XCTAssertTrue(composer.canPutSignatureBack)
        XCTAssertNil(composer.currentDraft()?.signature, "it goes out without it")
        composer.flush()
        let kept = await h.source.draft(try XCTUnwrap(composer.draftID))
        XCTAssertNil(kept?.signature, "and the source knows")

        composer.putSignatureBack()
        await composer.waitForIdentity()
        XCTAssertEqual(lines(composer.signature), ["Noor", "Abrega Inc. \u{00B7} plan.example"])
        composer.removeSignature()
        h.session.closeComposer()

        // The next message has it again.
        let next = await h.newMessage()
        XCTAssertNotNil(next.signature)
    }

    func testAMessageSentWithoutItsSignatureHasNoneInIt() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        composer.body = "Done."
        composer.removeSignature()
        h.session.sendComposer()
        let sent = try await h.lastMessage("q3")
        let body = await h.source.body(sent.id)
        guard case .text(let text, _, _) = body else { return XCTFail("a text body") }
        XCTAssertEqual(MailPlainText.string(text), "Done.")
    }
}
#endif
