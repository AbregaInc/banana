#if !BANANA_PUBLIC
import Foundation
import Combine

/// What the reading pane shows: the conversation under the cursor, once the cursor has rested.
///
/// It is its own small observable, and the list container reads nothing of it: the pane's views
/// observe `reader`, and the cursor's own highlight (`MailRowMark`) moves at once, in the same
/// turn as the key. The pane waits `rest` after the last move before it loads anything, so a held
/// `J` crossing thirty conversations a second makes one reader, for the one it stops on.
///
/// While it is on screen it also reads: a conversation it has shown for `MailListModel.readDelay`
/// is marked read, as opening one does (T10). That is the session's rule here and not the triage
/// model's, which knows only reading by opening; it is not an undo step either way.
@MainActor
final class MailPaneModel: ObservableObject {

    /// How long the cursor rests before the pane follows it.
    static let rest: TimeInterval = 0.15

    @Published private(set) var reader: MailReaderModel?

    private let source: MailSource
    private let timers: MailTimers
    private let markRead: @MainActor (MailTarget) -> Void
    private weak var model: MailListModel?
    private var subscription: AnyCancellable?
    private var cancelRest: (() -> Void)?
    private var cancelDwell: (() -> Void)?
    private(set) var isActive = false

    init(source: MailSource, timers: MailTimers, markRead: @escaping @MainActor (MailTarget) -> Void) {
        self.source = source
        self.timers = timers
        self.markRead = markRead
    }

    /// Follows this list's cursor from now on, and shows where it is at once.
    func follow(_ model: MailListModel) {
        self.model = model
        subscription = model.markChanges.sink { [weak self] change in
            if case .cursor = change { self?.cursorMoved() }
        }
        cancelRest?()
        cancelRest = nil
        if isActive { showCursor() }
    }

    /// Whether a pane is on screen. Off, it holds nothing and loads nothing: a phone, a narrow
    /// window or a hidden pane costs no reader.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        cancelRest?()
        cancelRest = nil
        if on {
            showCursor()
        } else {
            cancelDwell?()
            cancelDwell = nil
            reader = nil
        }
    }

    private func cursorMoved() {
        guard isActive else { return }
        cancelRest?()
        cancelRest = timers.schedule(Self.rest) { [weak self] in
            self?.cancelRest = nil
            self?.showCursor()
        }
    }

    private func showCursor() {
        cancelDwell?()
        cancelDwell = nil
        guard let model, let id = model.cursor else {
            reader = nil
            return
        }
        if reader?.id != id { reader = MailReaderModel(id: id, source: source) }
        guard isUnread(id) else { return }
        cancelDwell = timers.schedule(MailListModel.readDelay) { [weak self] in
            self?.cancelDwell = nil
            self?.dwelled(on: id)
        }
    }

    private func dwelled(on id: MailConversationID) {
        guard isActive, reader?.id == id, isUnread(id) else { return }
        guard let row = model?.rows.first(where: { $0.id == id }) else { return }
        markRead(.asShown([row]))
    }

    private func isUnread(_ id: MailConversationID) -> Bool {
        model?.rows.first { $0.id == id }?.isUnread == true
    }
}

#endif
