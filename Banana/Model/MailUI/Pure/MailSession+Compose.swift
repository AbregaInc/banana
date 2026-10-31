#if !BANANA_PUBLIC
import Foundation
import Combine

/// Which answer: to the sender, to everyone, or on to someone else.
enum MailReplyStyle: Equatable, Sendable {
    case reply, replyAll, forward
}

/// Send and Done, between the person pressing it and the model handing back the screen half of
/// the undo entry (T38).
struct PendingSend: Equatable, Sendable {
    var draft: MailDraftID
}

/// Writing mail (MAIL-UX 6.3): the session's half of the composer. The composer's text is
/// `MailComposerModel`'s; where the screen is, what Undo puts back and what the toast says are the
/// model's, the undo stack's and `MailToastText`'s, as for every other action. What lives here is
/// the order things happen in: a key opens a composer, a send pushes one undo entry, a close keeps
/// or drops a draft.
extension MailSession {

    /// The undo hold, until Settings says otherwise (6.3.7): how long a send's toast stays, and
    /// when the entry it makes stops being a send that can be taken back. The composer does not
    /// choose it: the source holds for the same ten seconds when asked for `hold: nil`.
    static let undoHold: TimeInterval = 10

    var composer: MailComposerModel? { navigation.composer }

    // MARK: Opening

    /// `R`, `F`, `↵` in an open conversation, or the header's menu: answer the conversation he is
    /// looking at — the open one, or the one the pane shows. With the list alone, `R` and `F` open
    /// the conversation with the composer open, as T38 says.
    func reply(_ style: MailReplyStyle, requestFocus: Bool = true) {
        guard allowsComposing else { explainComposingUnavailable(); return }
        if let composer { composer.askForFocus(); return }
        let target: MailConversationID
        if let open = model.open?.id {
            target = open
        } else if pane.isActive, let cursor = model.cursor {
            target = cursor
        } else {
            switch style {
            case .reply: send(.openAndReply(.reply))
            case .forward: send(.openAndReply(.forward))
            case .replyAll: break
            }
            return
        }
        switch style {
        case .reply: begin(.reply(target), requestFocus: requestFocus)
        case .replyAll: begin(.replyAll(target), requestFocus: requestFocus)
        case .forward: begin(.forward(target), requestFocus: requestFocus)
        }
    }

    /// `C`, ⌘N in Mail, and the list's pencil: a new message. One he began and set aside is the one
    /// he comes back to.
    func compose(requestFocus: Bool = true) {
        guard allowsComposing else { explainComposingUnavailable(); return }
        if let composer { composer.askForFocus(); return }
        // A new message is written in the pane. A conversation open full width over the pane
        // would hide it, so that conversation is closed first: the message is where he can see it.
        if pane.isActive, model.open != nil { send(.close) }
        if let kept = keptNewDraft {
            begin(.continuing(kept), requestFocus: requestFocus)
        } else {
            begin(.new, requestFocus: requestFocus)
        }
    }

    /// The composer is on screen in the frame after the key; what the draft says arrives after.
    func begin(_ start: MailComposeStart, requestFocus: Bool = true) {
        guard allowsComposing else { explainComposingUnavailable(); return }
        let composer = MailComposerModel(start: start, source: source, timers: timers, clock: clock,
                                         device: deviceName, requestFocus: requestFocus)
        navigation.setComposer(composer)
        composer.load()
    }

    /// A new message is not written in a conversation, so another conversation chosen leaves it.
    func leaveNewMessage() {
        if let composer, composer.host == nil { closeComposer() }
    }

    /// The pane moved to another conversation: a reply written in the one it left is left too.
    func paneShows(_ id: MailConversationID?) {
        guard let id, let host = composer?.host, host != id, model.open == nil else { return }
        closeComposer()
    }

    // MARK: Typing

    /// A key reached Mail while a composer is open. It is his typing, whatever it is: `J`, `K` and
    /// `E` are letters, and none of them runs a command (K12). It is queued, in order, for the
    /// caret, which is asked for again if it is not on its way. `Esc` is the one key that is not
    /// typing: it leaves the composer, and the queue goes with it.
    func typing(_ key: MailKey, shift: Bool, typed: String?, into composer: MailComposerModel) -> Bool {
        switch key {
        case .escape:
            closeComposer()
            return true
        case .character(let character):
            let text = typed ?? (shift ? character.uppercased() : String(character))
            if Self.isWritable(text) { composer.typeAhead(text) }
        case .returnKey:
            composer.typeAhead("\n")
        case .delete:
            composer.typeAheadDelete()
        case .up, .down, .left, .right:
            break
        }
        if !composer.awaitingFocus { composer.askForFocus() }
        return true
    }

    /// Not a control character, and not one of the private-use codes the Mac gives function keys.
    private static func isWritable(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || (0xF700...0xF8FF).contains(scalar.value)
        }
    }

    // MARK: Closing

    /// `Esc`, Back, another conversation, another place: the composer is left and **the draft is
    /// kept**, with no question (6.3.8). One nothing was typed into leaves nothing behind.
    func closeComposer() {
        guard let composer else { return }
        navigation.setComposer(nil)
        switch composer.close() {
        case .kept(let id):
            // A reply's draft is marked in its conversation. A new message has none, so it says it
            // is kept, and `C` goes back to it.
            if composer.host == nil {
                keptNewDraft = id
                showToast(MailToastText.draftKept)
            }
        case .dropped, .pending:
            if let id = composer.draftID, keptNewDraft == id { keptNewDraft = nil }
        }
    }

    /// ⌘⇧, and the bin: the draft is gone, and the toast says so with Undo (T25). Never a question.
    func discardComposer() {
        guard let composer else { return }
        let hadContent = composer.hasContent
        // What Undo brings back is what he had written, not what the last save had.
        if hadContent { composer.flush() }
        let id = composer.discardNow()
        navigation.setComposer(nil)
        guard let id else { return }
        if keptNewDraft == id { keptNewDraft = nil }
        if hadContent {
            discardKept(id)
        } else {
            source.discard(id)
        }
    }

    /// A draft he set aside, discarded from its mark in the conversation: the same Undo.
    func discardKept(_ id: MailDraftID) {
        let receipt = source.discard(id)
        guard receipt.sequence != 0, receipt.count != 0 else { return }
        undoStack.push(MailUndoEntry(kind: .discard(id), receipt: receipt, description: "Discarded draft",
                                     count: 1, scope: scope), at: clock())
        showToast(MailToastText.draftDiscarded)
    }

    /// Writes down what is being written, when the app goes to the background (6.3.9).
    func flushComposer() {
        composer?.flush()
    }

    // MARK: The composer's chords

    /// A chord the Mac read from the event (`MailComposerChord`): what the composer does with it.
    /// False when no composer is open, so the key is not the composer's. True otherwise, whether
    /// or not it could do anything just now (Send before the draft has arrived, a format in the
    /// To row): the chord is the composer's either way and must not be passed on to a menu.
    @discardableResult
    func perform(_ chord: MailComposerChord) -> Bool {
        guard let composer else { return false }
        switch chord {
        case .send: sendComposer()
        case .sendAndDone: sendComposer(thenDone: true)
        case .discard: discardComposer()
        case .sendLater: if composer.isReady { composer.toggleTimePicker() }
        case .recipient(let field): composer.reveal(field)
        case .format, .paragraph, .pastePlain, .attach: composer.chords.perform(chord)
        }
        return true
    }

    // MARK: Sending

    /// ⌘↩, and ⌘⇧↩ for Send and Done. The composer is gone, the message is in its conversation, and
    /// the toast says so with Undo, all in this turn; what cannot be sent says why and stays open.
    func sendComposer(thenDone: Bool = false) {
        guard let composer, composer.isReady else { return }
        if let problem = composer.sendProblem() {
            switch problem {
            case .nothing: showToast(MailToastText.nothingToSend)
            case .nobody: showToast(MailToastText.addSomeone)
            case .notAnAddress(let text): showToast(MailToastText.notAnAddress(text))
            case .attachmentsTooLarge: showToast(MailAttachmentText.tooLargeToSend)
            }
            composer.askForFocus(composer.problemField)
            return
        }
        // The time he chose went by while he wrote: it is not one to send at.
        if composer.schedulePassed(now: clock()) {
            composer.clearSchedule()
            showToast(MailScheduleCopy.timePassed)
            return
        }
        let host = composer.host
        guard let draft = composer.handOver() else { return }
        navigation.setComposer(nil)
        source.save(draft)
        if keptNewDraft == draft.id { keptNewDraft = nil }
        // A time chosen: the message waits for it (`MailSession+Schedule.swift`).
        if let at = draft.schedule?.at {
            scheduleSend(draft, at: at)
            return
        }

        if thenDone, let host, model.rows.contains(where: { $0.id == host }) {
            // The model moves the cursor and the screen as for any Done, and hands back what was
            // showing; the send carries the Done, and the one entry is pushed there (T38).
            pendingSend = PendingSend(draft: draft.id)
            send(.act(.sendAndDone, on: host))
            guard pendingSend != nil else { return }
            pendingSend = nil
        }
        sendAlone(draft)
    }

    /// A send with nothing else done by it.
    func sendAlone(_ draft: MailDraft) {
        let receipt = source.send(draft.id, MailSendOptions(hold: nil, thenDone: false))
        guard receipt.sequence != 0, receipt.count != 0 else { return }
        let entry = MailUndoEntry(
            kind: .send(draft.id, holdEnds: clock().addingTimeInterval(Self.undoHold), doneSubject: nil),
            receipt: receipt, description: MailToastText.sentDescription,
            subjects: [draft.subject], count: 1, scope: scope)
        undoStack.push(entry, at: clock())
        showToast(Self.sendingToast(thenDone: false))
    }

    /// The model has moved the screen for Send and Done and handed back the half of the entry it
    /// knows: the send finishes it with its receipt and pushes it as the one entry.
    func finishSendAndDone(_ half: MailUndoEntry) {
        guard let pending = pendingSend else { return }
        pendingSend = nil
        let receipt = source.send(pending.draft, MailSendOptions(hold: nil, thenDone: true))
        guard receipt.sequence != 0, receipt.count != 0 else { return }
        var entry = half
        entry.receipt = receipt
        entry.kind = .send(pending.draft, holdEnds: clock().addingTimeInterval(Self.undoHold),
                           doneSubject: half.subjects.first)
        undoStack.push(entry, at: clock())
        showToast(Self.sendingToast(thenDone: true))
    }

    /// The toast stays as long as the hold does: Undo is there for as long as it can work.
    private static func sendingToast(thenDone: Bool) -> MailToast {
        var toast = MailToastText.sending(thenDone: thenDone)
        toast.lasts = undoHold
        return toast
    }

    // MARK: Undoing a send

    /// Undo inside the hold. The one undo that waits (T26): the source says whether the message
    /// could still be taken back, a few milliseconds later. If it could, the composer is open
    /// again exactly as it was, and a Done is reversed with it; if not, it had already left.
    func cancelSend(_ entry: MailUndoEntry) {
        guard case .send(let draft, _, _) = entry.kind else { return }
        cancelling = Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await self.source.cancelSend(draft)
            self.showToast(self.undoStack.outcome(cancelling: entry, succeeded: succeeded).toast)
            self.reverseDone(of: entry)
            if succeeded { self.begin(.continuing(draft)) }
        }
    }

    /// What a Send and Done did to the screen, put back: the Done is undone, and the conversation
    /// is where it was (T26). A send that was only a send has nothing here.
    func reverseDone(of entry: MailUndoEntry) {
        guard case .send(_, _, let done) = entry.kind, done != nil else { return }
        switchTo(entry.scope)
        let answer = source.undo(entry.receipt)
        run(model.handle(.restore(entry, through: answer.sequence)))
    }

    /// Finishes when an undo of a send has been answered. For tests.
    func settle() async {
        await cancelling?.value
    }
}

#endif
