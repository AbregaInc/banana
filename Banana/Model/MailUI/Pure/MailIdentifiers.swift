#if !BANANA_PUBLIC
import Foundation

/// The accessibility identifiers of mail's controls, as constants.
///
/// Every control in mail has one, in the form `mail.<screen>.<thing>`, and UI tests find
/// controls by these and never by position (MAIL-UX 10.2). They are constants in one place,
/// rather than strings typed where they are used, because each is typed twice — once by the
/// view and once by the test that looks for it — and two spellings of one identifier is a test
/// that fails for no reason anyone can see.
///
/// So the same files are compiled twice: into the apps, and into the UI tests (`project.yml`
/// gives `BananaUITests` every `MailIdentifiers*.swift` of this folder). The UI tests have
/// nothing else of the app's, which makes one rule for these files: **they name Foundation
/// and each other, and nothing more** — no view, no model, not even the contract's types.
///
/// This file holds the two the first screens share. Each later package adds its own in
/// `MailIdentifiers+<package>.swift`, by extension, so no package edits another's file.
enum MailID {
    /// The conversation list itself.
    static let list = "mail.list"

    /// One row of the list. `key` is the conversation's fixture key in a UI test (`q3`), and
    /// the conversation id's `text` otherwise.
    static func row(_ key: String) -> String {
        list + ".row." + key
    }
}

#endif
