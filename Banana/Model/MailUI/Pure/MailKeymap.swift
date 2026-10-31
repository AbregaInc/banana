#if !BANANA_PUBLIC
import Foundation

/// A key on the Mac's keyboard with no ⌘, ⌃ or ⌥ held, as Mail reads it. The Mac's key monitor
/// turns an event into one of these; nothing here knows `NSEvent`.
enum MailKey: Equatable, Sendable {
    /// A letter or symbol, lower-cased.
    case character(Character)
    case up, down, left, right
    case returnKey, escape
    /// Backspace. Only the keys typed before a composer has the caret use it (K12).
    case delete
}

/// What a key means in Mail. The slice's keys only: moving, opening and closing, Done and not
/// Done, star, read and unread, Undo, the two columns that can be hidden, and writing: reply,
/// reply to all, forward and a new message. Selection, snooze, labels and the rest of MAIL-UX 4.2
/// come with their screens.
enum MailKeyCommand: Equatable, Sendable {
    case move(MailDirection)
    case open
    case close
    case back
    case act(MailAction)
    /// `⇧E`, named for the place it is pressed in: the session picks the action.
    case notDone
    case undo
    /// `\`: the reading pane. `]`: the details column. Both are free in MAIL-UX 4.2's map.
    case togglePane
    case toggleDetails
    /// `R`, `F`, and `↵` in an open conversation (4.2.3): the composer opens in the conversation
    /// (T38). `C`, and ⌘N from the menu: a new message.
    case reply
    case replyAll
    case forward
    case compose
}

/// The keymap as data, so a test holds every key against the document (MAIL-UX 4.2, K3, K7).
enum MailKeymap {

    /// `isOpen`: a conversation is open over the list. `isRepeat`: the key is being held down.
    /// A held `J` or `K` moves on every repeat; every other key acts once (K7), and so a held
    /// `E` is one Done, not ten. A shifted key is another key (⇧J selects) and is not Mail's yet,
    /// except `⇧E`.
    static func command(for key: MailKey, shift: Bool = false, isOpen: Bool,
                        isRepeat: Bool = false) -> MailKeyCommand? {
        if shift {
            return key == .character("e") && !isRepeat ? .notDone : nil
        }
        let command: MailKeyCommand
        switch key {
        case .character("j"), .down: command = .move(.older)
        case .character("k"), .up: command = .move(.newer)
        case .returnKey:
            // In a list it opens the conversation; in an open one it replies to all (4.2.3).
            command = isOpen ? .replyAll : .open
        case .right:
            guard !isOpen else { return nil }
            command = .open
        case .left:
            guard isOpen else { return nil }
            command = .close
        case .escape: command = .back
        case .character("e"): command = .act(.done)
        case .character("s"): command = .act(.toggleStar)
        case .character("u"): command = .act(.toggleRead)
        case .character("z"): command = .undo
        case .character("r"): command = .reply
        case .character("f"): command = .forward
        case .character("c"): command = .compose
        case .character("\\"): command = .togglePane
        case .character("]"): command = .toggleDetails
        case .character, .delete: return nil
        }
        if isRepeat {
            switch command {
            case .move: break
            default: return nil
            }
        }
        return command
    }
}

#endif
