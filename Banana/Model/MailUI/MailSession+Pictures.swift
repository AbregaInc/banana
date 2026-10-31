#if !BANANA_PUBLIC
#if DEBUG
import Foundation

/// The states of writing that a screenshot is of, for `--mail-state <name>` (MailSession+App): the
/// Simulator cannot press a key. Each is made the way he would make it, through the composer's own
/// model and the session's own calls, and no composer from a route asks for the caret, so no keyboard
/// comes up over the picture.
///
/// `cc`: a reply with Cc and Bcc showing, a chip in each, and the people Cc offers for what is
/// typed. `from`: a reply with the list of addresses to send as open. `new-signature`: a new message
/// with its signature. `picker`: a reply with the time picker open and a time typed. `drafts`: three
/// drafts, and the Drafts place. `scheduled`: a reply that waits, in its conversation, with its
/// toast. `scheduled-place`: two that wait, in the Scheduled place. `late`: one whose time passed.
extension MailSession {

    /// True when `state` was one of these.
    func startPicture(_ state: String, target: MailConversationID?) -> Bool {
        switch state {
        case "cc", "from", "picker", "scheduled", "late":
            guard let target else { return true }
            Task { @MainActor in await self.replyPicture(state, in: target) }
        case "new-signature":
            Task { @MainActor in await self.newSignaturePicture() }
        case "drafts":
            Task { @MainActor in await self.draftsPicture() }
        case "scheduled-place":
            Task { @MainActor in await self.scheduledPlacePicture() }
        default:
            return false
        }
        return true
    }

    private func replyPicture(_ state: String, in target: MailConversationID) async {
        begin(.reply(target), requestFocus: false)
        guard let composer else { return }
        await composer.waitForDraft()
        composer.body = "Thanks \u{2014} I\u{2019}ll look at it tonight."
        switch state {
        case "cc":
            composer.cc = [MailFixtureConversations.jane]
            composer.bcc = [MailFixtureSource.person(address: "pat@quinn.example")]
            composer.ccText = "an"
            await composer.waitForSuggestions()
        case "from":
            composer.isChoosingFrom = true
        case "picker":
            composer.toggleTimePicker()
            composer.timePicker?.text = "fri 9am"
        case "scheduled", "late":
            ToastCenter.window = .seconds(120)
            let tomorrow = MailTimePresets.tomorrowMorning(now: clock(), calendar: .current)
            composer.chooseSchedule(tomorrow)
            let draft = composer.draftID
            sendComposer()
            if state == "late", let draft { (source as? MailFixtureSource)?.markLate(draft) }
        default:
            break
        }
    }

    private func newSignaturePicture() async {
        compose(requestFocus: false)
        guard let composer else { return }
        await composer.waitForDraft()
        composer.toText = "pat@quinn.example,"
        composer.subject = "Lunch Thursday"
        composer.body = "Are you free on Thursday?\nLet me know."
    }

    /// A new message and two replies, a moment apart, kept; then Drafts.
    private func draftsPicture() async {
        compose(requestFocus: false)
        if let composer {
            await composer.waitForDraft()
            composer.toText = "pat@quinn.example,"
            composer.subject = "Lunch Thursday"
            composer.body = "Are you free on Thursday?\nLet me know."
        }
        closeComposer()
        try? await Task.sleep(for: .milliseconds(20))
        begin(.reply(MailConversationID(account: MailFixtureConversations.account, thread: "q3")),
              requestFocus: false)
        if let composer {
            await composer.waitForDraft()
            composer.body = "Thanks \u{2014} I\u{2019}ll look at it tonight."
        }
        closeComposer()
        try? await Task.sleep(for: .milliseconds(20))
        begin(.reply(MailConversationID(account: MailFixtureConversations.account, thread: "me-newest")),
              requestFocus: false)
        if let composer {
            await composer.waitForDraft()
            composer.body = "The data clause, and the region."
        }
        closeComposer()
        show(.drafts)
    }

    private func scheduledPlacePicture() async {
        ToastCenter.window = .seconds(120)
        begin(.reply(MailConversationID(account: MailFixtureConversations.account, thread: "q3")),
              requestFocus: false)
        if let composer {
            await composer.waitForDraft()
            composer.body = "Thanks \u{2014} I\u{2019}ll look at it tonight."
            composer.chooseSchedule(MailTimePresets.tomorrowMorning(now: clock(), calendar: .current))
            sendComposer()
        }
        compose(requestFocus: false)
        if let composer {
            await composer.waitForDraft()
            composer.toText = "pat@quinn.example,"
            composer.subject = "Lunch Thursday"
            composer.body = "Are you free on Thursday?"
            composer.chooseSchedule(MailTimePresets.nextMonday(after: clock(), calendar: .current))
            sendComposer()
        }
        show(.outbox)
    }
}
#endif

#endif
