#if !BANANA_PUBLIC
import Foundation

/// Where the composer's box is (direction A, chosen 7 Nov 2026): the bottom field grown into a box
/// docked above the keyboard; that box opened to the full height over the thread; or folded back
/// into the bottom field, the draft on one line with Send beside it while he reads.
///
/// Pure: the gestures and the keyboard are events, and what the screen must do in answer is an
/// effect. A new message opens at full height; a reply opens docked. Putting it away keeps the
/// draft (the session's close), so no event here ever asks a question or loses text.
struct MailComposerDock: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case docked, full, folded }

    enum Event: Equatable, Sendable {
        /// ⤢, or ⇧⌘↑ where there are keys.
        case expand
        /// ⤡.
        case collapse
        /// The grab handle let go, `translation` points down (negative: up), as predicted at the end.
        case dragEnded(translation: Double)
        /// He pulled the thread above the box down to read: the box folds into the field.
        case threadDraggedDown
        /// The keyboard went away (dismissed by him, not by focus moving from one row to the next).
        case keyboardHidden
        /// The folded field tapped: back to the box, the caret in the body.
        case resume
    }

    enum Effect: Equatable, Sendable {
        case none
        /// The caret goes back into the body.
        case focusBody
        /// Put away, the draft kept: the session closes the composer as Back does.
        case putAway
    }

    /// A drag shorter than this changes nothing: a tap on the handle, a wobble.
    static let dragThreshold: Double = 60
    /// A drag down at least this far puts the box away.
    static let awayDistance: Double = 200

    private(set) var mode: Mode

    init(new: Bool) { mode = new ? .full : .docked }
    init(mode: Mode) { self.mode = mode }

    var isFolded: Bool { mode == .folded }

    mutating func handle(_ event: Event) -> Effect {
        switch (event, mode) {
        case (.expand, .docked):
            mode = .full; return .none
        case (.expand, .folded):
            mode = .full; return .focusBody
        case (.collapse, .full):
            mode = .docked; return .none
        case (.dragEnded(let dy), .docked):
            if dy <= -Self.dragThreshold { mode = .full; return .none }
            if dy >= Self.awayDistance { return .putAway }
            if dy >= Self.dragThreshold { mode = .folded }
            return .none
        case (.dragEnded(let dy), .full):
            // From the full height a long pull goes past the docked box and away.
            if dy >= Self.awayDistance * 2 { return .putAway }
            if dy >= Self.dragThreshold { mode = .docked }
            return .none
        case (.dragEnded(let dy), .folded):
            if dy <= -Self.dragThreshold { mode = .docked; return .focusBody }
            if dy >= Self.dragThreshold { return .putAway }
            return .none
        case (.threadDraggedDown, .docked), (.keyboardHidden, .docked):
            mode = .folded; return .none
        case (.resume, .folded):
            mode = .docked; return .focusBody
        default:
            return .none
        }
    }
}

extension MailReplyStyle {
    /// What the switch at the start of a reply's To line says. With one other person on the thread
    /// Reply all and Reply are one answer, and it says Reply.
    func label(sameAsReply: Bool) -> String {
        switch self {
        case .replyAll: return sameAsReply ? "Reply" : "Reply all"
        case .reply: return "Reply"
        case .forward: return "Forward"
        }
    }
}

/// The assistant's draft in the body, with its one Undo (direction A's sparkle): the body as it
/// was before the draft was written in, kept until he types or takes it back.
struct MailAssistantUndo: Equatable, Sendable {
    let before: AttributedString
    let written: AttributedString

    /// Undo is offered while the body is still what the assistant wrote.
    func isCurrent(_ body: AttributedString) -> Bool { body == written }
}

#endif
