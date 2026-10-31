#if !BANANA_PUBLIC
import Foundation

/// The engine's registry: the one file made to be added to by many packages (MAIL-ENGINE 18.2).
///
/// An extension can add a member to a type but cannot add an element to a list another file
/// wrote, so what many packages contribute to — every schema step, what reacts to a finished
/// sync pass, the benchmarks, the fixture mailbox's parts — is listed here. A section is added
/// by the first package that has the type it lists; after that a package adds one line.
///
/// This is the first section. The others arrive with their types: `passConsumers` (P23a),
/// `benches` (P09a), `fixtureParts` (C0b).
enum MailSlices {

    /// Every schema step of the three cache stores. Each store package adds its line:
    /// P06a registers the index's first migration here, P07 and P08b the later ones.
    /// (`intent.sqlite`'s migrations are registered inside `MailIntentStore`, which nothing
    /// else opens.)
    static func migrations() -> MailMigrations {
        var migrations = MailMigrations()
        MailIndexSchema.register(in: &migrations.index)
        MailLocalSearchSchema.register(in: &migrations.index)
        MailActionIndex.register(in: &migrations.index)
        MailLabelCatalog.register(in: &migrations.index)
        MailVerificationIndex.register(in: &migrations.index)
        MailSyncFill.register(in: &migrations.index)
        MailBlobSchema.register(in: &migrations.blobs)
        return migrations
    }

    #if DEBUG || MAIL_FIXTURES
    /// The hostile messages of 17.5, one set to each package that writes some: its fixtures by
    /// name, each a whole `users.messages.get` JSON object. P03a's are the senders' and the
    /// headers'; P03b, P20a, P20b, P21a and the rest add one line each, and a test, a route or a
    /// screen that wants every hostile message reads them from here.
    static let hostileMessageSets: [() -> [(name: String, json: String)]] = [
        { MailHostileMessages.senderAndHeaderSet },     // P03a
    ]
    #endif
}

#endif
