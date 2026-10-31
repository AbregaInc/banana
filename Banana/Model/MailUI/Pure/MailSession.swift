#if !BANANA_PUBLIC
import Foundation
import Combine

/// What the Mail screen is showing that is not the list's rows: the place, the conversation open
/// full width, and which of the optional columns he has asked for. The one thing `MailScreen`
/// observes. It changes when a conversation opens or closes, a place is chosen or a column is
/// toggled, and never when the cursor moves (MAIL-UX 3.11).
@MainActor
final class MailNavigation: ObservableObject {
    /// Dot-free, as every defaults key here is (the dotted-key render storm).
    static let paneKey = "mailShowsPane"
    static let detailsKey = "mailShowsDetails"

    @Published fileprivate(set) var reader: MailReaderModel?
    @Published fileprivate(set) var scope: MailScope
    /// The reading pane, when there is room for one.
    @Published fileprivate(set) var showsPane: Bool
    /// The details column, when there is a pane and room for both.
    @Published fileprivate(set) var showsDetails: Bool
    /// The composer he has open, if any. It is here so that what he is writing is still open when
    /// the iOS tree is rebuilt, and so that only a composer opening or closing changes what the
    /// screen observes: never a keystroke (that is the composer's own).
    @Published private(set) var composer: MailComposerModel?

    private let defaults: UserDefaults?

    /// `defaults` nil keeps the two toggles for this run only.
    init(scope: MailScope, defaults: UserDefaults?) {
        self.scope = scope
        self.defaults = defaults
        showsPane = defaults?.object(forKey: Self.paneKey) as? Bool ?? true
        showsDetails = defaults?.object(forKey: Self.detailsKey) as? Bool ?? true
    }

    var open: MailConversationID? { reader?.id }

    /// The session's: it opens and closes composers and nothing else does.
    func setComposer(_ model: MailComposerModel?) {
        composer = model
    }

    /// A toggle he made is kept; one a launch route asked for is not, or a screenshot would
    /// change what the next real launch shows.
    func setPane(_ on: Bool, persist: Bool = true) {
        guard showsPane != on else { return }
        showsPane = on
        if persist { defaults?.set(on, forKey: Self.paneKey) }
    }

    func setDetails(_ on: Bool, persist: Bool = true) {
        guard showsDetails != on else { return }
        showsDetails = on
        if persist { defaults?.set(on, forKey: Self.detailsKey) }
    }
}

/// What the triage model asks the list host to do with its scroll position.
enum MailHostCommand: Equatable, Sendable {
    /// Show the row whole, and one more beyond it in `beyond` when there is one.
    case reveal(MailConversationID, beyond: MailDirection?)
    case scrollToTop
}

/// The clocks the session runs on, so a test sets them by hand.
struct MailTimers {
    /// Runs `work` after `delay` seconds; the closure returned cancels it.
    var schedule: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void

    static let live = MailTimers { delay, work in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            work()
        }
        return { task.cancel() }
    }
}

/// The screen's loop around the triage model (MAIL-UX 3.11): it gives the model what the
/// source delivers and what the person does, and carries out what the model asks for, in order.
/// It decides nothing — where the cursor goes, what Undo restores and what the toast says are the
/// model's, the undo stack's and `MailToastText`'s.
///
/// It lives outside the view tree, held by the app, so the open conversation, the cursor and the
/// place are still there when the iOS tree is thrown away in the background and rebuilt, and when
/// the Mac's sidebar leaves Mail and comes back.
///
/// This is the slice's cut of the design's `MailSession`: three places (Inbox, Starred, Done) and
/// a model for each one visited, a plain-text composer (`MailSession+Compose.swift`), no selection,
/// no checking for mail. Each of those is an input the model already knows
/// and the session does not send yet.
@MainActor
final class MailSession {

    static let inbox = MailScope(place: .mailbox(.inbox))
    /// MAIL-UX 3.11: a list rests after three seconds without the person's hands.
    static let idleAfter: TimeInterval = 3

    let isSample: Bool
    let allowsChanges: Bool
    let allowsComposing: Bool
    private let supportsAction: @MainActor (MailAction) -> Bool
    private let allowsTarget: @MainActor (MailTarget) -> Bool
    private let targetRestriction: String
    let source: MailSource
    /// The moment the screens draw dates against. The sample mail's clock is fixed so that
    /// "9:12 AM" and "Yesterday" never drift.
    let now: Date
    let navigation: MailNavigation
    let places: MailPlacesModel
    let pane: MailPaneModel
    /// Scroll requests for the list host, which subscribes while it is on screen.
    let hostCommands = PassthroughSubject<MailHostCommand, Never>()

    /// Not `private(set)`: writing mail pushes its own entries (`MailSession+Compose.swift`).
    var undoStack = MailUndoStack()
    /// The place in front.
    private(set) var scope: MailScope

    /// Shows a toast. The second argument is what its button does.
    let present: @MainActor (MailToast, @escaping @MainActor () -> Void) -> Void
    let timers: MailTimers
    let clock: () -> Date
    /// How the screens name this device: "Mac", "iPhone", "iPad".
    let deviceName: String
    /// Send and Done, between the person pressing it and the model handing back the screen half
    /// of the undo entry (T38): what the composer is to finish it with.
    var pendingSend: PendingSend?
    /// A message he began and set aside; `C` goes back to it.
    var keptNewDraft: MailDraftID?
    /// Undoing a send waits for the source (T26): the one undo that does.
    var cancelling: Task<Void, Never>?
    private var paneSubscription: AnyCancellable?

    /// One model for each place he has visited, kept with its cursor marks.
    private var lists: [MailScope: (model: MailListModel, marks: MailRowMarks)] = [:]
    // Only small cursors survive paging; old list models and observations do not.
    private var historyPages: [MailOrderKey?] = []
    private var observation: MailObservation?
    private var eventObservation: MailObservation?
    private var pendingEvents: [MailEvent] = []
    private var registeringUndo = false
    private var pendingUndos: [MailReceipt: MailUndoEntry] = [:]
    private var activeToastReceipt: MailReceipt?
    private let dismissToast: @MainActor () -> Void
    private var isEntered = false
    private var answersEntry = false
    private var cancelIdle: (() -> Void)?
    private var queue: [MailListEffect] = []
    private var isDraining = false

    init(source: MailSource, now: Date, deviceName: String, defaults: UserDefaults? = nil,
         timers: MailTimers = .live, clock: @escaping () -> Date = Date.init, isSample: Bool = false, allowsChanges: Bool = true,
         allowsComposing: Bool? = nil,
         supportsAction: @escaping @MainActor (MailAction) -> Bool = { _ in true },
         allowsTarget: @escaping @MainActor (MailTarget) -> Bool = { _ in true },
         targetRestriction: String = "Changes aren’t available for this account.",
         dismissToast: @escaping @MainActor () -> Void = {},
         present: @escaping @MainActor (MailToast, @escaping @MainActor () -> Void) -> Void) {
        self.isSample = isSample
        self.allowsChanges = allowsChanges
        self.allowsComposing = allowsChanges && (allowsComposing ?? true)
        self.supportsAction = supportsAction
        self.allowsTarget = allowsTarget
        self.targetRestriction = targetRestriction
        self.source = source
        self.now = now
        self.deviceName = deviceName
        self.timers = timers
        self.clock = clock
        self.present = present
        self.dismissToast = dismissToast
        scope = Self.inbox
        navigation = MailNavigation(scope: Self.inbox, defaults: defaults)
        places = MailPlacesModel(source: source)
        pane = MailPaneModel(source: source, timers: timers) { [weak source] target in
            guard allowsChanges, allowsTarget(target) else { return }
            // Reading is the pane's, and is not an undo step: the receipt is of no use to anyone.
            _ = source?.apply(.read(true), to: target)
        }
        eventObservation = source.observeEvents { [weak self] event in self?.received(event) }
        source.activate()
        pane.follow(model)
        // A reply is written in the conversation it answers: when the pane moves to another one,
        // the composer is left, and its draft kept.
        paneSubscription = pane.$reader.dropFirst().sink { [weak self] reader in
            self?.paneShows(reader?.id)
        }
    }

    var model: MailListModel { list(for: scope).model }
    var marks: MailRowMarks { list(for: scope).marks }
    var feed: MailListFeed { model.list }
    var openConversation: MailConversationID? { navigation.open }

    private func list(for scope: MailScope) -> (model: MailListModel, marks: MailRowMarks) {
        if let existing = lists[scope] { return existing }
        let model = MailListModel(scope: scope, deviceName: deviceName, timePhrase: { MailDateText.full($0) })
        let made = (model, MailRowMarks(model: model))
        lists[scope] = made
        return made
    }

    // MARK: Entering and leaving

    /// The place is on screen. The first value its observation delivers is the answer to this
    /// entry, and is marked so (MAIL-UX 3.11).
    func enter() {
        guard !isEntered else { return }
        isEntered = true
        source.setVisible(true)
        begin()
    }

    /// Mail is off screen. The list's observation is let go; the models, the cursors, the place
    /// and the open conversation stay.
    func leave() {
        guard isEntered else { return }
        isEntered = false
        end()
        source.setVisible(false)
    }

    private func begin() {
        send(.enter)
        answersEntry = true
        observation = source.observeList(scope, limit: model.limit) { [weak self] snapshot in
            self?.received(snapshot)
        }
    }

    private func end() {
        observation?.cancel()
        observation = nil
        send(.leave)
    }

    /// A cold launch comes back to the conversation that was open: after entering, and only if
    /// the list still has it.
    func restoreOpen(_ id: MailConversationID) {
        guard navigation.open == nil, model.rows.contains(where: { $0.id == id }) else { return }
        send(.open(id))
    }

    private func received(_ snapshot: MailListSnapshot) {
        let marked = answersEntry
        answersEntry = false
        run(model.handle(.snapshot(snapshot, answersEntry: marked)))
    }

    private func received(_ event: MailEvent) {
        // A source may report failure during apply(). Finish installing its receipt/undo
        // entry before consuming that event, without deferring normal input to another task.
        if isDraining || registeringUndo { pendingEvents.append(event); return }
        switch event {
        case .applied(let receipt, let count):
            if pendingUndos.removeValue(forKey: receipt) != nil {
                if count == 0 { showToast(MailToastText.cannotBeUndone) }
                return
            }
            undoStack.setCount(count, for: receipt)
            if count == 0, activeToastReceipt == receipt {
                activeToastReceipt = nil
                dismissToast()
            }
        case .notSaved(let receipt, let problem):
            if let original = pendingUndos.removeValue(forKey: receipt) {
                undoStack.restoreFailedUndo(original)
                showToast(MailToastText.notSaved(on: deviceName, problem: problem))
                return
            }
            // An immediate Undo of this action has nothing to reverse if the action
            // itself never saved. Its eventual no-op must not replace the save error.
            pendingUndos = pendingUndos.filter { $0.value.receipt != receipt }
            guard let entry = undoStack.remove(receipt: receipt) else {
                showToast(MailToastText.notSaved(on: deviceName, problem: problem)); return
            }
            revert(entry, because: .notSaved(problem))
        case .refused(let receipt, let failure):
            guard let entry = undoStack.remove(receipt: receipt) else {
                showToast(MailToast(text: MailToastText.reason(for: failure), action: nil)); return
            }
            revert(entry, because: .refused(failure))
        default:
            break // Composer/send lifecycle is integrated separately.
        }
    }

    private func revert(_ entry: MailUndoEntry, because reason: MailReversal) {
        let effects = list(for: entry.scope).model.handle(.reverted(entry, reason))
        for effect in effects {
            if case .toast(let toast) = effect {
                if case .retry? = toast.action {
                    activeToastReceipt = nil
                    present(toast) { [weak source] in source?.retry(entry.receipt) }
                } else { showToast(toast) }
            } else if entry.scope == scope {
                // Repair retained lists without navigating away from the new place.
                run([effect])
            }
        }
    }

    // MARK: Places and columns

    /// A place chosen in the control column or the header's menu. The place left lets its
    /// observation go and keeps its model; the one chosen is entered, and its cursor is where
    /// he left it. A conversation open over the old place is closed first.
    func show(_ place: MailMailbox) {
        historyPages.removeAll()
        switchTo(MailScope(place: .mailbox(place)))
    }

    var historyBackTitle: String { historyPages.isEmpty ? "Newest" : "Newer" }
    var canShowOlderHistory: Bool {
        !scope.isWriting && feed.shown.hasDelivered && feed.shown.hasMore && !model.rows.isEmpty
    }
    func showOlderHistory() {
        guard canShowOlderHistory, let last = model.rows.last else { return }
        historyPages.append(scope.before)
        var next = scope
        next.before = last.key
        switchTo(next)
    }
    func showNewerHistory() {
        guard scope.before != nil else { return }
        var next = scope
        if let previous = historyPages.popLast() { next.before = previous }
        else { next.before = nil }
        switchTo(next)
    }

    func switchTo(_ target: MailScope) {
        guard target != scope else { return }
        closeComposer()
        if model.open != nil { run(model.handle(.close)) }
        if isEntered { end() }
        var oldPlace = scope, newPlace = target
        oldPlace.before = nil; newPlace.before = nil
        if oldPlace != newPlace { historyPages.removeAll() }
        if scope.before != nil || target.before != nil { lists.removeValue(forKey: scope) }
        else if case .search = scope.place { lists.removeValue(forKey: scope) }
        scope = target
        navigation.scope = target
        pane.follow(model)
        if isEntered { begin() }
    }

    func retrySearch() {
        guard case .search = scope.place, isEntered else { return }
        end(); begin()
    }

    func togglePane() { navigation.setPane(!navigation.showsPane) }
    func toggleDetails() { navigation.setDetails(!navigation.showsDetails) }

    /// Whether a reading pane is on screen. The view says so when its arrangement changes.
    func setPaneVisible(_ visible: Bool) { pane.setActive(visible) }

    // MARK: The person

    /// The person's own input. Every one of them starts the three seconds again.
    func send(_ input: MailListInput) {
        switch input {
        case .act(let action, let explicit):
            guard allowsChanges, supportsAction(action) else { explainChangesUnavailable(); return }
            if let target = model.actionTarget(for: action, explicit: explicit), !allowsTarget(target) {
                present(MailToast(text: targetRestriction, action: nil, lasts: nil), {})
                return
            }
        case .openAndReply:
            guard allowsComposing else { explainComposingUnavailable(); return }
        case .readDelayElapsed(let id):
            guard allowsChanges, allowsTarget(.conversations([id])) else { return }
        default: break
        }
        scheduleIdle()
        run(model.handle(input))
    }

    func canPerform(_ action: MailAction, on id: MailConversationID? = nil) -> Bool {
        guard allowsChanges, supportsAction(action) else { return false }
        guard let target = model.actionTarget(for: action, explicit: id) else { return true }
        return allowsTarget(target)
    }

    func explainChangesUnavailable() {
        present(MailToast(text: "This Gmail action is still being integrated.", action: nil, lasts: nil), {})
    }

    func explainComposingUnavailable() {
        present(MailToast(text: "Gmail composing is still being integrated.", action: nil, lasts: nil), {})
    }

    /// A tap or click on a row, with no pane to show it in: the cursor goes there and the
    /// conversation opens full width.
    func open(_ id: MailConversationID) {
        leaveNewMessage()
        // A draft in Drafts is opened to be written, not read.
        if scope.isDrafts { openDraft(id); return }
        send(.open(id))
    }
    /// A tap or click on a row, with a pane: the cursor goes there and the pane follows.
    func select(_ id: MailConversationID) {
        leaveNewMessage()
        if scope.isDrafts { openDraft(id); return }
        send(.place(id))
    }
    func close() { send(.close) }
    func step(_ direction: MailDirection) { send(.step(direction)) }

    /// A swipe, or a button of the open conversation: one action on one conversation.
    func act(_ action: MailAction, on id: MailConversationID? = nil) {
        // Drafts and Scheduled hold messages of his own: Done and star mean nothing there.
        guard !scope.isWriting else { return }
        send(.act(action, on: id))
    }

    /// A key from the Mac. True when Mail took it, so the monitor does not pass it on. A key
    /// Mail knows and is being held down is taken and does nothing: it must not reach a
    /// responder that would beep at it.
    ///
    /// `typed` is what the key writes, case and all, for a key that is typing: Mail's own `MailKey`
    /// is the unshifted letter.
    func handle(_ key: MailKey, shift: Bool = false, isRepeat: Bool = false, typed: String? = nil) -> Bool {
        // With a composer open every key that reaches Mail is typing, never a command (K12).
        if let composer = navigation.composer {
            return typing(key, shift: shift, typed: typed, into: composer)
        }
        let isOpen = model.open != nil
        guard MailKeymap.command(for: key, shift: shift, isOpen: isOpen) != nil else { return false }
        guard let command = MailKeymap.command(for: key, shift: shift, isOpen: isOpen,
                                               isRepeat: isRepeat) else { return true }
        switch command {
        case .move(let direction): send(.move(direction))
        case .open:
            if scope.isDrafts, let cursor = model.cursor { openDraft(cursor) } else { send(.open(nil)) }
        case .close: send(.close)
        case .back: send(.back)
        case .act(let action): if !scope.isWriting { send(.act(action, on: nil)) }
        case .notDone: if !scope.isWriting { send(.act(MailAction.notDone(in: scope.place), on: nil)) }
        case .undo: undoTop()
        case .togglePane: togglePane()
        case .toggleDetails: toggleDetails()
        case .reply: reply(.reply)
        case .replyAll: reply(.replyAll)
        case .forward: reply(.forward)
        case .compose: compose()
        }
        return true
    }

    /// `Z`, and the toast's Undo: the newest thing on the stack (T26). An entry made in another
    /// place shows that place first, as the model's undo expects.
    func undoTop() {
        scheduleIdle()
        switch undoStack.beginUndo(now: clock()) {
        case .nothingToUndo:
            break
        case .reverse(let entry):
            // A schedule's undo is a send again, which the source is not asked to reverse.
            if case .schedule(let draft, let at) = entry.kind {
                restoreSchedule(draft, at: at)
                return
            }
            switchTo(entry.scope)
            registeringUndo = true
            let answer = source.undo(entry.receipt)
            if answer.sequence != 0, answer.count != 0 {
                pendingUndos[answer] = entry
                if pendingUndos.count > MailUndoStack.depth,
                   let oldest = pendingUndos.keys.min(by: { $0.sequence < $1.sequence }) { pendingUndos[oldest] = nil }
            }
            let outcome = undoStack.outcome(reversing: entry, answer: answer)
            showToast(outcome.toast)
            if case .undone = outcome {
                if case .discard(let draft) = entry.kind {
                    // A discarded draft is back, and he is writing it again.
                    begin(.continuing(draft))
                } else {
                    run(model.handle(.restore(entry, through: answer.sequence)))
                }
            }
            registeringUndo = false
            while !registeringUndo && !pendingEvents.isEmpty { received(pendingEvents.removeFirst()) }
        case .cancelSend(let entry):
            cancelSend(entry)
        case .alreadySent(let entry):
            showToast(undoStack.outcome(forAlreadySent: entry).toast)
            reverseDone(of: entry)
        }
    }

    // MARK: Carrying out what the model asks

    /// The model's effects, in order. An effect's own answer (a receipt) is more effects, and goes
    /// to the back of the line: nothing is handled inside the model's own call.
    func run(_ effects: [MailListEffect]) {
        queue.append(contentsOf: effects)
        guard !isDraining else { return }
        isDraining = true
        defer {
            isDraining = false
            while !registeringUndo && !pendingEvents.isEmpty { received(pendingEvents.removeFirst()) }
        }
        while !queue.isEmpty {
            carry(queue.removeFirst())
        }
    }

    private func carry(_ effect: MailListEffect) {
        switch effect {
        case .perform(let request):
            let receipt = source.apply(request.change, to: request.target)
            queue.append(contentsOf: model.handle(.performed(token: request.token, receipt)))
        case .pushUndo(let entry):
            undoStack.push(entry, at: clock())
        case .toast(let toast):
            showToast(toast)
        case .open(let id, let start, _):
            if navigation.open != id { navigation.reader = MailReaderModel(id: id, source: source) }
            // A composer is written in one conversation: another one opening leaves it.
            if let host = navigation.composer?.host, host != id { closeComposer() }
            switch start {
            case .reply?: if navigation.composer == nil { begin(.reply(id)) }
            case .forward?: if navigation.composer == nil { begin(.forward(id)) }
            case nil: break
            }
        case .close:
            navigation.reader = nil
            closeComposer()
        case .reveal(let id, let beyond):
            hostCommands.send(.reveal(id, beyond: beyond))
        case .scrollToTop:
            hostCommands.send(.scrollToTop)
        case .markReadAfter(let id, let delay):
            guard allowsChanges, allowsTarget(.conversations([id])) else { return }
            _ = timers.schedule(delay) { [weak self] in
                guard let self else { return }
                self.send(.readDelayElapsed(id))
            }
        case .settled(let entry):
            finishSendAndDone(entry)
        case .growTo(let limit):
            guard isEntered else { break }
            let previous = observation
            let next = source.observeList(scope, limit: limit) { [weak self] snapshot in
                // Keep live updates until the replacement's first reading, as the source
                // contract requires. Growing is not a new entry: retain cursor and viewport.
                previous?.cancel()
                self?.received(snapshot)
            }
            observation = MailObservation {
                // Leaving before that first reading must also cancel the old subscription.
                previous?.cancel()
                next.cancel()
            }
        case .scrollPage, .restoreViewport, .checkNow, .leaveSearch, .clearFilters:
            // Paging, a saved scroll position, checking for mail and leaving a
            // search belong to screens this slice does not have.
            break
        }
    }

    func showToast(_ toast: MailToast) {
        let receipt: MailReceipt?
        switch toast.action {
        case .undo?, .undoPrevious?: receipt = undoStack.top?.receipt
        default: receipt = nil
        }
        activeToastReceipt = receipt
        present(toast) { [weak self] in
            guard let self, let receipt, self.undoStack.top?.receipt == receipt else { return }
            self.undoTop()
        }
    }

    func scheduleIdle() {
        cancelIdle?()
        cancelIdle = timers.schedule(Self.idleAfter) { [weak self] in
            guard let self else { return }
            self.cancelIdle = nil
            self.run(self.model.handle(.idle))
        }
    }
}

#endif
