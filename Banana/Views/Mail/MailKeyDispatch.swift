#if !BANANA_PUBLIC
#if os(macOS)
import AppKit

/// Turns a key event into Mail's own `MailKey` and hands it to the session. The Mac's key monitor
/// calls this, and only while Mail is the section in front and no text field has focus
/// (`MacKeyMonitor.handle`); what each key means is `MailKeymap`'s, which has no `NSEvent` in it.
@MainActor
enum MailKeyDispatch {

    /// True when Mail took the key and the monitor should not pass it on.
    static func handle(_ event: NSEvent) -> Bool {
        guard let session = MailSession.existing, let key = key(from: event) else { return false }
        return session.handle(key, shift: event.modifierFlags.contains(.shift), isRepeat: event.isARepeat,
                              typed: event.characters)
    }

    /// A chord the composer owns, with a composer open (`MailComposerChord`): Send, Send and Done,
    /// ⌘B ⌘I ⌘U, the lists and the quote, plain paste, Attach, Send later, Discard, and the To, Cc
    /// and Bcc rows. Told by the event's exact modifiers, here, once, whoever has focus and in
    /// whichever window (the card, or the sheet) the composer is. True when it was one of them;
    /// the window's buttons are then never offered it, so SwiftUI's shortcut matching, which does
    /// not count Shift, cannot take ⌘C for ⇧⌘C or ⇧⌘↩ for ⌘↩. Anything else goes on untouched.
    static func handleComposerChord(_ event: NSEvent) -> Bool {
        guard let session = MailSession.existing, session.composer != nil else { return false }
        let flags = event.modifierFlags
        guard let chord = MailComposerChord.resolve(
            isReturn: event.keyCode == 36 || event.keyCode == 76,
            characters: event.charactersIgnoringModifiers ?? "",
            command: flags.contains(.command), shift: flags.contains(.shift),
            option: flags.contains(.option), control: flags.contains(.control)) else { return false }
        return session.perform(chord)
    }

    /// A composer has asked for the caret and has not got it: whatever is typed is its, in the
    /// order it was typed (K12). The monitor asks this before it looks at who has focus, because
    /// until the caret has landed nobody who has focus is the composer's.
    static var composerWaitsForTheCaret: Bool {
        MailSession.existing?.composer?.awaitingFocus == true
    }

    /// The monitor has already refused ⌘, ⌃ and ⌥, so only the key itself is left to read.
    static func key(from event: NSEvent) -> MailKey? {
        switch event.keyCode {
        case 125: return .down
        case 126: return .up
        case 123: return .left
        case 124: return .right
        case 36, 76: return .returnKey
        case 53: return .escape
        case 51: return .delete
        default:
            guard let text = event.charactersIgnoringModifiers?.lowercased(), text.count == 1,
                  let character = text.first else { return nil }
            return .character(character)
        }
    }
}
#endif

#endif
