#if !BANANA_PUBLIC
import Foundation

/// Where the session meets the rest of the app: which source it runs on, the shared toast, the
/// one field of `ShellState` it writes, and the launch routes. The session itself
/// (`Pure/MailSession.swift`) knows none of them.
extension MailSession {

    @MainActor private static var made: MailSession?
    @MainActor private static var launched = false

    /// Synchronous fixture route or an already-open live session. Normal first use opens
    /// asynchronously through MailApplication; Beta alone never selects sample data.
    @MainActor static var shared: MailSession? {
        if let made { return made }
        #if DEBUG && targetEnvironment(simulator)
        if MailRemovalReviewFixture.enabled { return nil }
        #endif
        #if DEBUG || MAIL_FIXTURES
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--stress-days") || arguments.contains("--mail") ||
              arguments.contains("--mail-fresh") || arguments.contains("--mail-fixtures") else { return nil }
        // Scheduled messages are kept across a launch, so that one can be found late. `--mail-fresh`
        // (Debug only) neither reads nor writes them: a picture is of this launch alone, and a
        // snapshot of the Mac leaves nothing in the defaults of the Beta he is using.
        #if DEBUG
        let kept: UserDefaults? = ProcessInfo.processInfo.arguments.contains("--mail-fresh") ? nil : .standard
        #else
        let kept: UserDefaults? = .standard
        #endif
        #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
        let source: MailFixtureSource
        if ScaleStress.days != nil {
            source = MailFixtureSource(samples: MailFixtureConversations.stress(days: ScaleStress.mailDays), defaults: nil)
        } else {
            source = MailFixtureSource(defaults: kept)
        }
        #else
        let source = MailFixtureSource(defaults: kept)
        #endif
        var toastID: UUID?
        let session = MailSession(source: source, now: source.now, deviceName: DeviceRole.current.name,
                                  defaults: .standard, isSample: true,
                                  dismissToast: { if let toastID { ToastCenter.shared.dismiss(ifMatching: toastID) } }) { toast, undo in
            ToastCenter.shared.present(toast.text, actionTitle: toast.action?.title ?? "",
                                       window: toast.lasts.map { .seconds($0) },
                                       action: toast.action == nil ? nil : undo)
            toastID = ToastCenter.shared.toast?.id
        }
        made = session
        return session
        #else
        return nil
        #endif
    }

    @MainActor static func installLive(_ source: MailLiveSource) -> MailSession {
        if let made { return made }
        var toastID: UUID?
        let session = MailSession(source: source, now: Date(), deviceName: DeviceRole.current.name,
                                  defaults: .standard, allowsChanges: true, allowsComposing: false,
                                  supportsAction: { $0.isIntegratedGmailAction },
                                  allowsTarget: { [weak source] in source?.permitsChanges(to: $0) ?? false },
                                  targetRestriction: "This account is read only in Beta. Mark it as a test account in Settings to enable changes.",
                                  dismissToast: { if let toastID { ToastCenter.shared.dismiss(ifMatching: toastID) } }) { toast, undo in
            ToastCenter.shared.present(toast.text, actionTitle: toast.action?.title ?? "",
                window: toast.lasts.map { .seconds($0) }, action: toast.action == nil ? nil : undo)
            toastID = ToastCenter.shared.toast?.id
        }
        made = session
        return session
    }

    /// The session if one has been made, and never makes one: the key monitor and the
    /// background hook ask this, so asking costs a launch that has no Mail nothing.
    @MainActor static var existing: MailSession? { made }

    // MARK: First appearance

    /// Once, after the first time Mail is on screen: back to the conversation that was open when
    /// a reclaimed process went away, then whatever a launch route asked for.
    func finishLaunch() {
        guard !Self.launched else { return }
        Self.launched = true
        if let text = ShellNavigation.shared.state.mail?.open, let id = MailConversationID(text: text) {
            restoreOpen(id)
        }
        #if DEBUG
        applyLaunchRoute(ProcessInfo.processInfo.arguments)
        #endif
    }

    #if DEBUG
    /// `--mail-place inbox|starred|done`, `--mail-cursor <key>`, `--mail-open <key>`,
    /// `--mail-pane off`, `--mail-details off` and `--mail-state <state>`: the states a screenshot is
    /// of, since the Simulator cannot press a key (MAIL-UX 13.1). Keys are the fixtures' keys. The
    /// two toggles are for this launch only: a route must not change what the next real launch
    /// shows.
    ///
    /// The states: `done` (the conversation marked Done, with its toast); `reply`, `reply-all` and
    /// `forward` (a composer open in the conversation open, or under the cursor, with a line typed);
    /// `new` (a new message with "sa" typed in To, and its suggestions); `sent` (just after Send,
    /// with the toast); `draft` (after Esc: the conversation with a kept draft). A composer from a
    /// route does not ask for the caret, so no keyboard comes up over the picture.
    private func applyLaunchRoute(_ arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        func conversation(_ key: String) -> MailConversationID {
            MailConversationID(account: MailFixtureConversations.account, thread: key)
        }
        if value(after: "--mail-pane") == "off" { navigation.setPane(false, persist: false) }
        if value(after: "--mail-details") == "off" { navigation.setDetails(false, persist: false) }
        if let name = value(after: "--mail-place"),
           let mailbox = MailPlacesModel.all.first(where: { $0.title.lowercased() == name })?.mailbox {
            show(mailbox)
        }
        if let key = value(after: "--mail-cursor") { send(.place(conversation(key))) }
        if let key = value(after: "--mail-open") { send(.open(conversation(key))) }
        guard let state = value(after: "--mail-state") else { return }
        switch state {
        case "done":
            // A toast stays six seconds; a picture is taken when it is taken.
            ToastCenter.window = .seconds(120)
            send(.act(.done, on: nil))
        case "reply", "reply-all", "forward", "sent", "draft":
            guard let target = model.open?.id ?? model.cursor else { return }
            Task { @MainActor in await self.writeForPicture(state, in: target) }
        case "new":
            Task { @MainActor in await self.writeNewForPicture() }
        default:
            // Formatting and attachments (MailSession+AttachRoute), then Cc and Bcc, From, a
            // signature, Drafts and send later (MailSession+Pictures).
            if applyAttachRoute(state) { break }
            _ = startPicture(state, target: model.open?.id ?? model.cursor)
        }
    }

    /// A reply with a line in it, and then what `state` says happened to it.
    private func writeForPicture(_ state: String, in target: MailConversationID) async {
        let start: MailComposeStart
        switch state {
        case "reply-all": start = .replyAll(target)
        case "forward": start = .forward(target)
        default: start = .reply(target)
        }
        begin(start, requestFocus: false)
        guard let composer else { return }
        await composer.waitForDraft()
        composer.body = "Thanks \u{2014} I\u{2019}ll look at it tonight."
        if state == "forward" { composer.accept(MailFixtureConversations.jane) }
        switch state {
        case "sent": sendComposer()
        case "draft": closeComposer()
        default: break
        }
    }

    private func writeNewForPicture() async {
        compose(requestFocus: false)
        guard let composer else { return }
        await composer.waitForDraft()
        composer.toText = "sa"
        await composer.waitForSuggestions()
    }
    #endif

    // MARK: Where he was

    /// Writes the open conversation to `ShellState`, for a cold launch within the hour. Only when
    /// the app goes to the background: a conversation opening and closing is `MailNavigation`'s,
    /// which the shell does not observe, so no key writes this (MAIL-UX 3.11).
    @MainActor static func noteBackgrounding() {
        guard let session = existing else { return }
        // What he is writing is written down now, whatever the view tree does next (6.3.9).
        session.flushComposer()
        let state = ShellNavigation.shared.state.mail
        let open = session.openConversation?.text
        guard state?.open != open else { return }
        ShellNavigation.shared.state.mail = open.map { MailShellState(open: $0) }
    }
}

#endif
