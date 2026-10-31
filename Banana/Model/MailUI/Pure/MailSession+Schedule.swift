#if !BANANA_PUBLIC
import Foundation

/// Send later, and the places of what he is writing (MAIL-UX 6.3.6, 6.5, 7.7): the session's half.
/// What the words say is `MailScheduleCopy`; what time means is `MailTimePhrase` and
/// `MailTimePresets`; what is held until then is the source's. What lives here is the order things
/// happen in: a schedule is one undo entry that takes it back, a cancel is one that puts it back, and
/// every one of them shows at once and never asks.
extension MailSession {

    // MARK: Scheduling

    /// Send, with a time chosen: the composer is gone and the message is in its conversation,
    /// reading "Scheduled · Thu 8:00 AM". Undo, until then, is a cancel (`cancelSend`): it is a
    /// draft again and the composer is open as it was.
    func scheduleSend(_ draft: MailDraft, at: Date) {
        let receipt = source.send(draft.id, MailSendOptions(hold: nil, thenDone: false, at: at))
        guard receipt.sequence != 0, receipt.count != 0 else { return }
        undoStack.push(
            MailUndoEntry(kind: .send(draft.id, holdEnds: at, doneSubject: nil), receipt: receipt,
                          description: MailScheduleCopy.scheduledDescription, subjects: [draft.subject],
                          count: 1, scope: scope), at: clock())
        showToast(MailScheduleCopy.scheduledToast(at, now: clock()))
    }

    // MARK: A scheduled message's own buttons

    /// Edit: it is a draft again, with the time still on it, and the composer opens on it.
    func editScheduled(_ draft: MailDraftID) {
        cancelling = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.source.cancelSend(draft) else {
                self.showToast(MailScheduleCopy.alreadyGone)
                return
            }
            self.closeComposer()
            self.begin(.continuing(draft))
        }
    }

    /// Cancel the schedule: back to a draft, with Undo, which schedules it again for the same time.
    func cancelSchedule(_ draft: MailDraftID, at: Date) {
        cancelling = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.source.cancelSend(draft) else {
                self.showToast(MailScheduleCopy.alreadyGone)
                return
            }
            self.pushRestore(draft, to: at, description: MailScheduleCopy.cancelledDescription)
            self.showToast(MailScheduleCopy.backToDraft)
        }
    }

    /// A late message he chose not to send: a draft again. Reversing it would be a schedule in the
    /// past, so it has no Undo; the draft is in Drafts, whole.
    func keepAsDraft(_ draft: MailDraftID) {
        cancelling = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.source.cancelSend(draft) else {
                self.showToast(MailScheduleCopy.alreadyGone)
                return
            }
            self.showToast(MailScheduleCopy.keptAsDraft)
        }
    }

    /// Reschedule: the same message, another time. Undo puts the old time back, when it is still ahead.
    func reschedule(_ draft: MailDraftID, from old: Date, to new: Date) {
        cancelling = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.source.cancelSend(draft) else {
                self.showToast(MailScheduleCopy.alreadyGone)
                return
            }
            let receipt = self.source.send(draft, MailSendOptions(hold: nil, thenDone: false, at: new))
            guard receipt.sequence != 0, receipt.count != 0 else { return }
            var toast = MailScheduleCopy.rescheduledToast(new, now: self.clock())
            if old > self.clock() {
                self.pushRestore(draft, to: old, description: MailScheduleCopy.rescheduledDescription,
                                 receipt: receipt)
            } else {
                toast.action = nil
            }
            self.showToast(toast)
        }
    }

    /// Send now: it takes the message over and sends it now, through the ordinary undo hold.
    func sendScheduledNow(_ id: MailDraftID) {
        cancelling = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.source.cancelSend(id), let draft = await self.source.draft(id) else {
                self.showToast(MailScheduleCopy.alreadyGone)
                return
            }
            self.sendAlone(draft)
        }
    }

    private func pushRestore(_ draft: MailDraftID, to time: Date, description: String,
                             receipt: MailReceipt = MailReceipt(sequence: 1, count: 1)) {
        undoStack.push(MailUndoEntry(kind: .schedule(draft, restoreTo: time), receipt: receipt,
                                     description: description, count: 1, scope: scope), at: clock())
    }

    /// Undo of a cancel or a reschedule: the message waits for the time it had.
    func restoreSchedule(_ draft: MailDraftID, at: Date) {
        cancelling = Task { @MainActor [weak self] in
            guard let self else { return }
            // Scheduled for another time still: it is a draft first.
            _ = await self.source.cancelSend(draft)
            guard at > self.clock() else {
                self.showToast(MailToastText.cannotBeUndone)
                return
            }
            let receipt = self.source.send(draft, MailSendOptions(hold: nil, thenDone: false, at: at))
            guard receipt.sequence != 0, receipt.count != 0 else {
                self.showToast(MailToastText.cannotBeUndone)
                return
            }
            self.showToast(MailToastText.undone(previous: self.undoStack.top?.description))
        }
    }

    // MARK: Drafts

    /// A draft chosen in Drafts: its composer opens. A reply opens in its conversation (the pane
    /// shows it, or it opens full width where there is no pane), and a new message is written where
    /// a new message is.
    func openDraft(_ conversation: MailConversationID) {
        cancelling = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let found = await self.source.conversation(conversation), let id = found.draft,
                  let draft = await self.source.draft(id) else { return }
            self.closeComposer()
            if draft.conversation.thread.hasPrefix("local:") {
                self.send(.place(conversation))
                self.begin(.continuing(id))
            } else {
                self.send(self.pane.isActive ? .place(conversation) : .open(conversation))
                self.begin(draft.isForward ? .forward(conversation) : .reply(conversation))
            }
        }
    }
}

#endif
