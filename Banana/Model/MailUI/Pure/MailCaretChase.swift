#if !BANANA_PUBLIC
import Foundation

/// How a request for the caret is carried out when the field it is for may not be there yet.
///
/// **Why it needs one.** The composer is made in the same update that asks for the caret, and so
/// is a row the caret was asked to go to (Cc, Bcc) and the picker's field. On iPhone and iPad the
/// assignment made in that update takes. On the Mac it does not: the field's view does not exist
/// until the update has been laid out, the assignment finds nothing to focus and is dropped, and
/// the first responder stays where it was (the list). Nothing says so, and nothing asks again: the
/// keys typed meanwhile wait in the type-ahead queue (K12) until it is thrown away.
///
/// **The rule.** Ask, and look whether it took; if it did not, ask again, a short pause (a turn of
/// the run loop, a frame) later, until it has, or nothing wants it any more, or `attempts` asks
/// have been made. It is a loop on a fact (the field has the caret), not a delay chosen so that
/// the field is probably there by then: a slow first layout, as a loaded machine has, only makes
/// the loop go round more often.
enum MailCaretChase {
    /// The most times the caret is asked for after the first look. It is a count and not a time,
    /// so a loaded machine cannot cut it short; with `turn` it is a little under a second of
    /// frames, which is what the type-ahead waits (`MailComposerModel.caretWithin`).
    static let attempts = 60
    /// Between two looks: one frame.
    static let turn: Duration = .milliseconds(16)

    /// Looks, after one turn, and asks again while `isWanted` and not `isThere`. Calls `landed`
    /// when the caret was there without the request having been told (it was there already, as it
    /// is when it is asked for the field it is in). Returns how many times it asked.
    ///
    /// - Parameters:
    ///   - isWanted: the request is still the latest, nobody has the caret because of it, and the
    ///     view is still there.
    ///   - isThere: the field the request is for has the caret.
    ///   - ask: assigns the caret to the field.
    ///   - landed: tells the request that the caret is in its field.
    ///   - pause: one turn; a test's is instant.
    @MainActor
    @discardableResult
    static func run(isWanted: () -> Bool, isThere: () -> Bool, ask: () -> Void, landed: () -> Void,
                    pause: () async -> Void = { try? await Task.sleep(for: MailCaretChase.turn) }) async -> Int {
        var asks = 0
        await pause()
        while isWanted() {
            if isThere() {
                landed()
                return asks
            }
            guard asks < attempts else { return asks }
            ask()
            asks += 1
            await pause()
        }
        return asks
    }
}

#endif
