import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The app's one confirmation surface: a short line at the bottom of the screen, with at most
/// one action — Undo when the change can be reversed.
///
/// It replaces confirmation dialogs for anything recoverable (DESIGN-SYSTEM.md, "Confirming and
/// undoing"). Every tab and the Mac content pane host it (`toastHost()`), so a feature only
/// calls in here — none of them should build their own.
///
/// Two kinds of undo:
/// - **Deferred removal.** The item disappears at once (`hiddenIDs`), and the real removal is
///   only sent when the window closes, the app goes to the background, or the next change is
///   made. Undo just shows it again — nothing was sent, so nothing has to be recreated. If the
///   app dies inside the window, the item is still there: the safe failure.
/// - **Applied change.** Already written when the toast appears; undo writes it back.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    /// A `var` so tests can shorten it; nothing in the app changes it.
    static var window: Duration = .seconds(6)

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let canUndo: Bool
        /// The action's label: Undo, or Retry for a save that failed.
        var actionTitle = "Undo"
    }

    @Published private(set) var toast: Toast?
    /// Ids of items whose removal is waiting on the undo window. Lists leave these out.
    @Published private(set) var hiddenIDs: Set<String> = []

    private var undoAction: (() async -> String?)?
    private var pendingCommit: (() async -> Void)?
    private var expiry: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        #if os(iOS)
        let name = UIApplication.didEnterBackgroundNotification
        #else
        let name = NSApplication.willResignActiveNotification
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in await ToastCenter.shared.commitPending() }
        })
    }

    /// Hide `id` now; run `commit` when the undo window closes. `commit` returns an error
    /// message, or nil on success; a failure brings the item back and says so via `failure`.
    func deferRemoval(id: String, message: String,
                      failure: @escaping (String) -> String,
                      commit: @escaping () async -> String?) async {
        // Take the previous change's commit before awaiting it: a second removal arriving while
        // the first one's network call is in flight must not overwrite this one's commit (which
        // left its item hidden forever and never removed).
        let previous = takePending()
        hiddenIDs.insert(id)
        pendingCommit = { [weak self] in
            let error = await commit()
            guard let self else { return }
            self.hiddenIDs.remove(id)
            if let error { self.show(failure(error), undo: nil) }
        }
        show(message) { [weak self] in
            self?.hiddenIDs.remove(id)
            return nil
        }
        await previous?()
    }

    /// A change shown at once and written when the undo window closes (or the app leaves the
    /// front, or the next change arrives). `undo` puts the screen back, and nothing was written:
    /// the only kind of Undo that works for everything, a repeating reminder's tick included,
    /// which Reminders can't take back once it has moved the series on.
    func deferCommit(message: String, undo: @escaping () async -> Void, commit: @escaping () async -> Void) async {
        let previous = takePending()
        pendingCommit = commit
        show(message) {
            await undo()
            return nil
        }
        await previous?()
    }

    /// Whether a change is waiting on the undo window.
    var hasPendingCommit: Bool { pendingCommit != nil }

    /// A change that already landed. `undo` reverses it (returning an error message, or nil);
    /// pass nil when it can't be reversed and the toast is only a notice.
    func offerUndo(_ message: String, undo: (() async -> String?)?) async {
        let previous = takePending()
        show(message, undo: undo)
        await previous?()
    }

    /// A change that is already stored, shown now and returned from at once: Mail's toast
    /// (MAIL-UX 5.2). A key handler must not await anything, and nothing here is deferred — there
    /// is no commit to run when the window closes. `action` is what the button does; nil makes
    /// the toast a notice. The toast it replaces has its pending commit run, as `notify` does.
    ///
    /// `window` is how long it stays when that is not the usual six seconds: a message being sent
    /// keeps its Undo up for the whole of its hold.
    func present(_ message: String, actionTitle: String = "Undo", window: Duration? = nil,
                 action: (@MainActor () -> Void)? = nil) {
        let previous = takePending()
        show(message, undo: action.map { run in { run(); return nil } }, actionTitle: actionTitle,
             window: window)
        Task { await previous?() }
    }

    /// A plain confirmation ("Times copied to clipboard"): the same toast, nothing to undo.
    func notify(_ message: String) {
        let previous = takePending()
        show(message, undo: nil)
        Task { await previous?() }
    }

    func undo() {
        Task { await performUndo() }
    }

    func performUndo() async {
        guard let action = undoAction else { return }
        expiry?.cancel()
        undoAction = nil
        pendingCommit = nil
        toast = nil
        if let failure = await action() {
            show("Couldn\u{2019}t undo: \(failure)", undo: nil)
        }
    }

    func dismiss() {
        Task { await commitPending() }
    }

    /// Withdraw only the originating notice; an unrelated newer toast must survive.
    func dismiss(ifMatching id: UUID) {
        guard toast?.id == id else { return }
        let previous = takePending()
        Task { await previous?() }
    }

    /// Run the deferred removal now, if there is one, and close the toast.
    func commitPending() async {
        await takePending()?()
    }

    /// Close the toast and hand back the pending commit, all synchronously, so nothing that
    /// arrives while the caller awaits it can see — or overwrite — a half-finished state.
    private func takePending() -> (() async -> Void)? {
        expiry?.cancel()
        expiry = nil
        undoAction = nil
        toast = nil
        let commit = pendingCommit
        pendingCommit = nil
        return commit
    }

    #if DEBUG
    /// A toast with a no-op undo, for snapshot captures.
    func showPreview(_ message: String) {
        show(message) { nil }
        expiry?.cancel()
    }
    #endif

    /// A save that didn't go through, with Retry. `retry` runs the save again — and shows its
    /// own toast for how that went.
    func offerRetry(_ message: String, retry: @escaping () async -> Void) async {
        let previous = takePending()
        show(message, undo: {
            await retry()
            return nil
        }, actionTitle: "Retry")
        await previous?()
    }

    private func show(_ message: String, undo: (() async -> String?)?, actionTitle: String = "Undo",
                      window: Duration? = nil) {
        undoAction = undo
        toast = Toast(message: message, canUndo: undo != nil, actionTitle: actionTitle)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: window ?? Self.window)
            guard !Task.isCancelled, let self else { return }
            // Detach this task from `expiry` first: `commitPending` cancels `expiry`, and
            // cancelling ourselves made the deferred delete's own network call fail as
            // "cancelled" — the event came back with an error every time the window ran out.
            self.expiry = nil
            await self.commitPending()
        }
    }
}

// MARK: - Calendar

/// Undo for the two grid edits that are easy to make by accident: dragging an event and
/// deleting one. Only single-occurrence moves offer undo — reversing a "this and all future"
/// move would mean stitching a split series back together.
extension ToastCenter {
    /// `hiding`: what to take off the day meanwhile — the event, or all of its series that's going
    /// (`PendingRemovals.seriesToken`).
    func deferDelete(eventID: String, hiding: String? = nil, title: String, span: CalendarEditSpan,
                     delete: @escaping () async -> String?) async {
        await deferRemoval(
            id: hiding ?? eventID,
            message: span == .futureEvents
                ? "Deleted \u{201C}\(title)\u{201D} and what follows"
                : "Deleted \u{201C}\(title)\u{201D}",
            failure: { "Couldn\u{2019}t delete \u{201C}\(title)\u{201D}: \($0)" },
            commit: delete)
    }

    func offerMoveUndo(title: String, to newStart: Date, span: CalendarEditSpan,
                       moveBack: @escaping () async -> String?) async {
        let when = newStart.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        await offerUndo("Moved \u{201C}\(title)\u{201D} to \(when)", undo: span == .thisEvent ? moveBack : nil)
    }
}

// MARK: - View

extension View {
    /// Shows `ToastCenter`'s toast at the bottom of this view, above its safe area — on iOS that
    /// is above the tab bar and the now-playing accessory, so apply it to each tab's content,
    /// not to the TabView.
    func toastHost() -> some View {
        overlay { ToastView() }
    }
}

struct ToastView: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        ZStack {
            if let toast = center.toast {
                HStack(spacing: DS.Space.m) {
                    Text(toast.message)
                        .font(.callout)
                        .lineLimit(2)
                    if toast.canUndo {
                        Button(toast.actionTitle) { center.undo() }
                            .buttonStyle(.inline)
                            #if os(iOS)
                            // A finger's target, reaching into the pill's padding like the
                            // close button's.
                            .frame(minHeight: DS.Row.minHeight)
                            .contentShape(Rectangle())
                            .padding(.vertical, -DS.Space.m)
                            .keyboardShortcut("z", modifiers: .command)
                            #endif
                            .accessibilityIdentifier(toast.actionTitle == "Undo" ? "toast.undo" : "toast.action")
                    }
                    Button { center.dismiss() } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                    .iconButton()
                    // The full-size target reaches into the pill's own padding, so the pill
                    // stays as tall as its words.
                    .padding(.vertical, -DS.Space.m)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
                .floatingCapsule()
                .padding(.bottom, 18)
                .padding(.horizontal, DS.Space.l)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.snappy(duration: 0.22), value: center.toast)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
