import Foundation

/// Calls every member of `MailSource`, once each, so that a member a source has not really
/// built is found whether or not any other test happens to call it.
///
/// A source builds a member by declaring it; until it does, a default answers quietly and
/// reports to `MailNotYet` (MailSource+NotYet.swift). The hazard is the member that was meant
/// to be built and is not: forgotten, or declared with a slightly different signature — a
/// wrong label, `async` on a synchronous requirement — which Swift accepts as a separate
/// overload. The default then stays the one every screen reaches, because screens hold a
/// `MailSource`, while the source's own tests, which call the concrete type, pass.
///
/// So the question "which defaults does this source still reach?" is asked through the
/// protocol, of every member, in one place:
///
/// - `MailContractShapeTests` asks it of a source that has built nothing, and expects all of
///   `everyMember` — which proves that every default reports, and under which name.
/// - The gate-F test asks it of the engine **and** of the in-memory source, and expects
///   nothing but a short named list of members that come after the first release.
///
/// `MailSourceTreeTests` counts the protocol's requirements in the source and compares the
/// count with `everyMember`, so a requirement added to the contract cannot be left out of here.
@MainActor
enum MailSourceProbe {

    /// The name each default reports under, member for member, in the protocol's order.
    nonisolated static let everyMember: Set<String> = [
        "activate()", "setVisible(_:)",
        "accounts", "observeAccounts(_:)", "observePlaces(_:)", "cachedFirstPage(_:)",
        "syncLimit", "setSyncLimit(_:)", "conversationsBeyond(_:)",
        "observeList(_:limit:_:)", "observeConversation(_:_:)", "conversation(_:)", "body(_:)",
        "resource(_:for:presentation:)", "suggestions(for:)", "people(matching:limit:)",
        "queryTokens(_:)", "decideLink(_:in:)", "draft(_:)", "status", "badges",
        "attachmentProgress(_:)", "storageUsed()",
        "apply(_:to:)", "undo(_:)", "retry(_:)", "discard(_:) receipt",
        "newDraft(_:)", "save(_:)", "addAttachment(_:to:)", "removeAttachment(_:from:)",
        "rewriteAsText(_:)", "quoteAsText(in:)", "changeIdentity(of:to:)",
        "resource(_:forDraft:presentation:)", "discard(_:) draft", "send(_:_:)",
        "cancelSend(_:)", "retrySend(_:)", "hasUnfinishedSends", "finishSends(within:)",
        "answer(_:_:)",
        "checkNow()", "askGmail(_:)", "wants(_:)", "fetchBody(_:)", "fetchAttachment(_:)",
        "showPictures(in:always:)", "pictureRules()",
        "removePictureRule(_:)",
        "setWantsMail(_:account:)", "requestPermission(account:)", "forgetPermission(account:)",
        "saveSplits(_:)", "createLabel(named:account:)", "unsubscribe(_:)",
        "removeDownloadedMail(account:)", "reconsiderKeptMail(account:)",
        "observeEvents(_:)",
    ]

    /// The defaults `source` still reaches when every member is called: all of `everyMember`
    /// for a source that has built nothing, none for one that is finished.
    static func defaultsReached(by source: MailSource) async -> Set<String> {
        MailNotYet.reset()
        await touchEveryMember(of: source)
        let reached = MailNotYet.reachedNames
        MailNotYet.reset()
        return reached
    }

    /// One call of each of the protocol's members, through the protocol.
    ///
    /// **Only ever on a source over a throwaway store and a pretend Gmail.** It is not a
    /// read-only tour: it sends, discards, forgets a permission and removes downloaded mail,
    /// because those are members too. The arguments name things that do not exist, so a real
    /// source has nothing to act on — but that is a courtesy, not the safeguard.
    static func touchEveryMember(of source: MailSource) async {
        let account = "probe@example.com"
        let conversation = MailConversationID(account: account, thread: "probe-thread")
        let message = MailMessageID(account: account, message: "probe-message")
        let attachment = MailAttachmentID(message: message, part: "0")
        let draft = MailDraftID(raw: "probe-draft")
        let inbox = MailScope(place: .mailbox(.inbox))
        let search = MailScope(place: .search("probe"))
        let picture = URL(string: "https://example.com/probe.png")!
        let receipt = MailReceipt(sequence: 0, count: 0)

        // Life.
        source.activate()
        source.setVisible(false)

        // Reads.
        _ = source.accounts
        let observations = [
            source.observeAccounts { _ in },
            source.observePlaces { _ in },
            source.observeList(inbox, limit: MailTuning.firstPageRows) { _ in },
            source.observeConversation(conversation) { _ in },
            source.observeEvents { _ in },
        ]
        _ = source.cachedFirstPage(inbox)
        _ = await source.conversation(conversation)
        _ = await source.body(message)
        _ = await source.resource(picture, for: message, presentation: .warming)
        _ = await source.suggestions(for: "probe")
        _ = await source.people(matching: "probe", limit: 1)
        _ = source.queryTokens("probe")
        _ = await source.decideLink(picture, in: message)
        _ = await source.draft(draft)
        _ = source.status
        _ = source.badges
        _ = source.attachmentProgress(attachment)
        _ = await source.storageUsed()

        // Changes to conversations.
        source.apply(.read(true), to: .conversations([conversation]))
        source.undo(receipt)
        source.retry(receipt)
        source.discard(receipt)

        // Drafts and sending.
        let made = await source.newDraft(.new(account: account))
        source.save(made)
        _ = await source.addAttachment(URL(fileURLWithPath: "/dev/null"), to: draft)
        source.removeAttachment("probe-attachment", from: draft)
        _ = await source.rewriteAsText(draft)
        _ = await source.quoteAsText(in: draft)
        _ = await source.changeIdentity(of: draft, to: account)
        _ = await source.resource(picture, forDraft: draft, presentation: .warming)
        source.discard(draft)
        source.send(draft, MailSendOptions(hold: nil, thenDone: false))
        _ = await source.cancelSend(draft)
        source.retrySend(draft)
        _ = source.hasUnfinishedSends
        await source.finishSends(within: 0)

        // Questions.
        source.answer(MailQuestion.ID(raw: "probe-question"), .acknowledge)

        // Fetching.
        source.checkNow()
        _ = source.syncLimit
        source.setSyncLimit(.sixMonths)
        _ = await source.conversationsBeyond(.oneMonth)
        source.askGmail(search)
        source.wants([conversation])
        source.fetchBody(message)
        source.fetchAttachment(attachment)
        source.showPictures(in: message, always: nil)
        _ = await source.pictureRules()
        source.removePictureRule(.domain("example.com"))

        // Accounts, splits, labels.
        source.setWantsMail(false, account: account)
        _ = await source.requestPermission(account: account)
        source.forgetPermission(account: account)
        source.saveSplits([])
        _ = source.createLabel(named: "probe", account: account)
        _ = await source.unsubscribe(conversation)
        await source.removeDownloadedMail(account: account)
        source.reconsiderKeptMail(account: account)

        observations.forEach { $0.cancel() }
    }
}
