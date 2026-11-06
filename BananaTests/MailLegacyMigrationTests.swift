import XCTest
import GRDB

final class MailLegacyMigrationTests: XCTestCase {
    private func root() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-legacy-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func payload(_ id: String, account: String = "noor@plan.example") throws -> Data {
        let content = StoredDraft(localID: id, account: account, fromAlias: nil, kind: "new",
            to: [], cc: [], bcc: [], subject: "Saved draft", body: .init(blocks: []), signature: nil, quote: nil,
            format: .banana, rfcMessageID: "<fixture@plan.example>", mimeDate: Date(timeIntervalSince1970: 100),
            sourceMessageID: nil, threadID: nil, inReplyTo: nil, references: nil, contentRev: 1, attachments: [])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(content))
        return try JSONSerialization.data(withJSONObject: ["content":object,"editedAt":0,"discarded":false])
    }
    func testEarlierBetaDraftsRemainVisibleAndUncertainSendsCannotReplay() async throws {
        let location = root(), editing = try payload("editing"), sending = try payload("sending")
        let directories = try await Task.detached {
            let directories = try MailDirectories(root: location)
            _ = try MailStores.open(directories, migrations: MailSlices.migrations())
            _ = try MailIntentStore(directories: directories)
            let db = try MailStores.openIntentQueue(at: directories.intentDatabase)
            try db.write { db in
                // Reproduce the earlier Beta's actual migration ledger, not a fresh install.
                try db.execute(sql: "DROP TABLE draft_outbox; DROP TABLE legacy_draft_import; DELETE FROM grdb_migrations WHERE identifier IN ('v6-draft-outbox','v7-legacy-beta-import')")
                for (id,state,data) in [("editing","editing",editing),("sending","sending",sending)] {
                    try db.execute(sql: "INSERT INTO draft VALUES(?,?,1,0,?,?,?,0,0,1,?,NULL,0)",
                        arguments: [id,"noor@plan.example",state,data,"local:"+id,Data("{}".utf8)])
                }
            }
            return directories
        }.value
        let store = try await Task.detached { try MailIntentStore(directories: directories) }.value
        try await store.importLegacyDrafts(scope: "owner", accounts: ["different@plan.example"])
        let absent = try await store.draftRecords(scope: "owner")
        XCTAssertTrue(absent.isEmpty)
        try await store.importLegacyDrafts(scope: "owner", accounts: ["noor@plan.example"])
        try await store.importLegacyDrafts(scope: "owner", accounts: ["noor@plan.example"])
        let records = try await store.draftRecords(scope: "owner")
        XCTAssertEqual(records.count, 2)
        let recovered = try XCTUnwrap(records.first { $0.snapshot.id.raw == "editing" })
        XCTAssertEqual(recovered.snapshot.subject, "Saved draft")
        XCTAssertEqual(recovered.state, .editing)
        let uncertain = try XCTUnwrap(records.first { $0.snapshot.id.raw == "sending" })
        XCTAssertTrue(uncertain.legacyReview == true)
        XCTAssertEqual(uncertain.state, .uncertain)
        XCTAssertFalse(uncertain.needsDelivery)
        let reopened = try await Task.detached { try MailIntentStore(directories: directories) }.value
        let after = try await reopened.draftRecords(scope: "owner")
        XCTAssertEqual(after, records)
        let originals = try await Task.detached {
            let q = try DatabaseQueue(path: directories.intentDatabase.path)
            return try q.read { try Data.fetchAll($0, sql: "SELECT record FROM draft ORDER BY id") }
        }.value
        XCTAssertEqual(originals, [editing,sending])
    }
    func testKnownLegacyIndexOpensButUnknownFutureSchemaStillRefuses() async throws {
        let location = root()
        try await Task.detached {
            let directories = try MailDirectories(root: location)
            let stores = try MailStores.open(directories, migrations: MailSlices.migrations())
            try stores.index.write { db in
                try db.execute(sql: "INSERT INTO account(email) VALUES ('noor@plan.example')")
            }
            let reopened = try MailStores.open(directories, migrations: MailSlices.migrations())
            XCTAssertEqual(try reopened.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM account") }, 1)
            try reopened.index.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('unknown-future-step')") }
            XCTAssertThrowsError(try MailStores.open(directories, migrations: MailSlices.migrations())) { error in
                guard case MailStoreError.newerThanThisVersion(.index) = error else { return XCTFail("Wrong failure: \(error)") }
            }
        }.value
    }
    func testRetainedInstalledBetaCopyOpensWithoutLosingRecords() async throws {
        guard let path = ProcessInfo.processInfo.environment["BANANA_MAIL_UPGRADE_FIXTURE"] else {
            throw XCTSkip("Optional private installed-data copy was not supplied")
        }
        let location = root()
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: location)
        try await Task.detached {
            let directories = try MailDirectories(root: location)
            var previous = MailMigrations()
            MailIndexSchema.register(in: &previous.index)
            MailLocalSearchSchema.register(in: &previous.index)
            MailActionIndex.register(in: &previous.index)
            MailLabelCatalog.register(in: &previous.index)
            MailVerificationIndex.register(in: &previous.index)
            MailSyncFill.register(in: &previous.index)
            MailBlobSchema.register(in: &previous.blobs)
            XCTAssertThrowsError(try MailStores.open(directories, migrations: previous)) { error in
                guard case MailStoreError.newerThanThisVersion(.index) = error else { return XCTFail("Wrong original failure: \(error)") }
            }
            let stores = try MailStores.open(directories, migrations: MailSlices.migrations())
            let intent = try MailIntentStore(directories: directories)
            let accounts = try await stores.index.read { try String.fetchAll($0, sql: "SELECT email FROM account") }
            try await intent.importLegacyDrafts(scope: "installed-copy", accounts: Set(accounts))
            let records = try await intent.draftRecords(scope: "installed-copy")
            XCTAssertFalse(records.isEmpty, "Installed fixture has a saved draft")
            let integrity = try await stores.index.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
            XCTAssertEqual(integrity, "ok")
        }.value
    }
}
