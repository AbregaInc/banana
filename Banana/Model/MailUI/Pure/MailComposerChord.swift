#if !BANANA_PUBLIC
import Foundation

/// A key chord the composer owns on the Mac (MAIL-UX 4.2.6), and the one place that tells which
/// from the key's own modifiers.
///
/// **Why not `.keyboardShortcut`.** On the Mac, SwiftUI matches a shortcut to a key event without
/// counting Shift. Seen in the driver, with the shortcuts as they were: plain ⌘A opened the file
/// panel (⇧⌘A is Attach), ⌘C revealed Cc, ⌘, discarded the draft, ⌘8 and ⌘L and ⌘O did what ⇧⌘8,
/// ⇧⌘L and ⇧⌘O do, ⇧⌘↩ sent without Done (⌘↩ took it), and ⌘B for bold would have taken ⇧⌘B's Bcc.
/// Every chord here has a twin one Shift away, usually the system's. So the Mac reads the event
/// once (`MailKeyDispatch.handleComposerChord`), by the exact set of ⌘, ⇧, ⌥ and ⌃, and none of
/// these chords is offered to a button's shortcut at all: whatever is not exactly one of them
/// goes on to the Edit menu, Settings and the sections as it always did. UIKit matches modifiers
/// exactly, so on iPhone and iPad the buttons still carry their shortcuts.
enum MailComposerChord: Hashable, Sendable {
    case send, sendAndDone
    /// ⌘B, ⌘I, ⌘U: an `NSTextView` takes these through a Format menu, which the Mac app does not
    /// have, so the composer runs the format bar's own toggle.
    case format(MailFormatting.Trait)
    /// ⇧⌘7 numbers, ⇧⌘8 bullets, ⇧⌘9 quotes.
    case paragraph(MailParagraphKind)
    case pastePlain
    case attach
    case sendLater
    case discard
    /// ⇧⌘O, ⇧⌘C, ⇧⌘B: the caret goes to the row, which appears if it was not there.
    case recipient(MailRecipientField)

    /// `isReturn`: the Return key or the keypad's Enter. `characters`: the event's
    /// `charactersIgnoringModifiers`, which is the key's own letter whatever the layout does with
    /// Shift for it: "7" or "&" for the key with 7 on it, "," or "<", "b" or "B".
    static func resolve(isReturn: Bool, characters: String, command: Bool, shift: Bool, option: Bool,
                        control: Bool) -> MailComposerChord? {
        guard command, !option, !control else { return nil }
        if isReturn { return shift ? .sendAndDone : .send }
        let key = Self.key(of: characters)
        if !shift {
            return MailFormatting.Trait.allCases.first { String($0.chordKey) == key }.map { .format($0) }
        }
        switch key {
        case "7": return .paragraph(.number)
        case "8": return .paragraph(.bullet)
        case "9": return .paragraph(.quote)
        case "v": return .pastePlain
        case "a": return .attach
        case "l": return .sendLater
        case ",": return .discard
        case "o": return .recipient(.to)
        case "c": return .recipient(.cc)
        case "b": return .recipient(.bcc)
        default: return nil
        }
    }

    /// Whether the composer is offered a chord at all. It is not while the command menu is up
    /// (its field has the keys, and ⌘↩ there must not send a letter he is not looking at), nor
    /// for a key typed in the system's file panel, where ⇧⌘O, ⇧⌘A, ⇧⌘C and ⇧⌘L are the panel's
    /// own (Documents, Applications, Computer, Downloads). The monitor that reads the chords
    /// sees every window's keys, which the buttons these chords used to sit on did not.
    static func isOffered(commandMenuShown: Bool, inFilePanel: Bool) -> Bool {
        !commandMenuShown && !inFilePanel
    }

    /// The key's own character: lower case, and a symbol that Shift made out of a digit or the
    /// comma named by what is on the keycap.
    static func key(of characters: String) -> String {
        let shifted: [String: String] = ["&": "7", "*": "8", "(": "9", "<": ","]
        let lowered = characters.lowercased()
        return shifted[lowered] ?? lowered
    }
}

/// What the views behind the body's chords do, registered by them while they are on screen and
/// asked by the one place that reads the keys. A chord nobody registered a handler for (the body
/// is gone, or this is not a Mac) does nothing, and is still the composer's: it is not passed on.
@MainActor
final class MailComposerChords {
    private var handlers: [MailComposerChord: (owner: UUID, run: () -> Void)] = [:]

    /// Sets what `chord` does, for the view `owner`. A view that is made again while the old one
    /// is going registers before the old one unregisters; the old one's `unregister` leaves what
    /// the new one set.
    func register(_ chord: MailComposerChord, owner: UUID, _ run: @escaping () -> Void) {
        handlers[chord] = (owner, run)
    }

    /// Takes back every chord that `owner` registered, and no one else's.
    func unregister(owner: UUID) {
        handlers = handlers.filter { $0.value.owner != owner }
    }

    /// True when something was registered and ran.
    @discardableResult
    func perform(_ chord: MailComposerChord) -> Bool {
        guard let handler = handlers[chord] else { return false }
        handler.run()
        return true
    }
}

#endif
