#if !BANANA_PUBLIC
import Foundation
import CryptoKit

/// How mail writes to the diagnostic journal, without being able to write anything that
/// identifies mail (MAIL-ENGINE 16, invariant 21).
///
/// The engine cannot name the app's journal (`PlaybackDiagnostics`, `Signpost`), so it is
/// handed this value at wiring time. **Its shape is the rule**: a line is an event from a
/// closed list and a handful of typed fields — a count, a time, a flag, a position in the
/// account list, a salted hash of an id, the raw value of a closed enum. There is no parameter
/// a subject, an address, a file name, a query, a label's name or Google's own error text could
/// be passed in, so no review has to find one that was.
///
/// One line per pass, not per message.
struct MailJournal: Sendable {
    var line: @Sendable (_ event: MailJournalEvent, _ fields: [MailJournalField]) -> Void
    var begin: @Sendable (_ name: StaticString) -> MailSignpost

    /// Writes nothing and times nothing. For a test that is not about the journal, and for a
    /// launch in which nothing should be recorded.
    static let silent = MailJournal(line: { _, _ in }, begin: { _ in MailSignpost(end: {}) })
}

/// What a journal line is about. The journal prints it with the mail marker the app uses.
enum MailJournalEvent: String, Sendable {
    case activate, sync, syncQuiet, quota, reconcile, outbox, send, prepare, index, store
    case search, wake, bg, ui
}

/// One field of a journal line. Every case carries a name chosen in code (`StaticString`) and a
/// value that cannot be free text.
enum MailJournalField: Sendable {
    case count(StaticString, Int)
    case ms(StaticString, Double)
    case flag(StaticString, Bool)
    /// `a1`, `a2`: the account's position in the account list, never its address.
    case account(Int)
    /// A salted hash of an id, below.
    case id(StaticString, MailJournalID)
    /// The raw value of a closed enum.
    case code(StaticString, any MailJournalCode)
}

/// Adopted only by closed enums with `String` raw values (`GmailError`, `MailFailure`,
/// `MailStoreProblem`, …). `String` itself does not adopt it, so a string cannot be passed as a
/// code.
protocol MailJournalCode: RawRepresentable, Sendable where RawValue == String {}

/// An id as the journal names it: the first ten hex digits of
/// SHA-256(salt `|` account `|` id).
///
/// The salt is random per install and is kept in `intent.sqlite`'s `meta`, so the lines of one
/// session can be matched with each other and with nothing outside this device. The two
/// separators are the literal bar, so that account `ab`, id `c` and account `a`, id `bc` are
/// not one hash.
struct MailJournalID: Sendable, Equatable, CustomStringConvertible {
    /// The ten hex digits.
    let text: String

    init(salt: Data, account: String, id: String) {
        var input = salt
        input.append(contentsOf: Array("|".utf8))
        input.append(contentsOf: Array(account.utf8))
        input.append(contentsOf: Array("|".utf8))
        input.append(contentsOf: Array(id.utf8))
        let digest = SHA256.hash(data: input)
        text = String(digest.map { String(format: "%02x", $0) }.joined().prefix(10))
    }

    var description: String { text }
}

/// A timed region that ends when told to. The journal's `begin` makes one; the engine's
/// signposts (`mail.sync`, `mail.apply`, `mail.prepare`, `mail.index`, `mail.send`) are these.
struct MailSignpost: Sendable {
    let end: @Sendable () -> Void
}

#endif
