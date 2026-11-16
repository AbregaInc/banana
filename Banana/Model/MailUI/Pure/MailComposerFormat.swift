#if !BANANA_PUBLIC
import Foundation
import Combine

/// What the body's keys and the Mac's menu need to ask of the editor: whether words are selected in
/// it, and a way to ask for a link. The editor's selection is the view's (it is where the caret
/// is, not what he typed), so the view tells this what matters and this tells the view what was
/// asked. Nothing here is redrawn by a keystroke: only explicit editor requests are published.
@MainActor
final class MailComposerFormat: ObservableObject {
    /// Moves when a link is asked for: ⌘K, from the editor or from the Mac's menu.
    @Published private(set) var linkRequest = 0

    struct LinkInsertion: Equatable {
        let id = UUID()
        let url: URL
    }
    @Published private(set) var linkInsertion: LinkInsertion?

    /// An explicit composer action, including when the caret was last in a recipient field.
    func requestLinkInsertion(_ url: URL) {
        linkInsertion = LinkInsertion(url: url)
    }

    /// A composer tool sheet hides the keyboard without putting away the draft.
    var isPresentingSheet = false

    /// The body has the caret.
    var bodyFocused = false
    /// Words are selected in the body.
    var hasSelection = false

    /// ⌘K: a link for the selected words (MAIL-UX 4.2.6). With no words selected it is not for the
    /// body, and the key is the command menu's.
    @discardableResult
    func requestLink() -> Bool {
        guard bodyFocused, hasSelection else { return false }
        linkRequest += 1
        return true
    }
}

#endif
