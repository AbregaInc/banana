import XCTest
import GRDB

final class MailBlobStoreTests: XCTestCase {
    func testBodyStorageDoesNotWaitForBusyListReaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-reader-contention-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let occupied = expectation(description: "Both list readers occupied")
        occupied.expectedFulfillmentCount = 2
        let released = expectation(description: "Both readers released")
        released.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            stores.index.asyncRead { result in
                defer { released.fulfill() }
                do {
                    _ = try Int.fetchOne(result.get(), sql: "SELECT count(*) FROM account")
                    occupied.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                } catch { XCTFail("Reader failed: \(error)") }
            }
        }
        await fulfillment(of: [occupied], timeout: 2)
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(#"{"id":"m1","threadId":"t1","internalDate":"100","payload":{"partId":"p","mimeType":"text/plain","headers":[],"body":{"data":"SGVsbG8"}}}"#.utf8))
        let extraction = MIMEStructure.extract(message.payload!)
        // Controlled contention, not an estimate of real user latency. The old
        // pooled tombstone read must wait; the independent writer read need not.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
            release.signal(); release.signal()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        try await MailBlobStore(stores: stores).put(message, account: "a@example.com", extraction: extraction, ftsRowID: 1, at: 1)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("BODY_STORE_BUSY_READERS_MS \(ms)")
        await fulfillment(of: [released], timeout: 2)
        XCTAssertLessThan(ms, 100)
        let content = try await MailBlobStore(stores: stores).content(account: "a@example.com", messageID: "m1")
        XCTAssertEqual(content?.plain, "Hello")
    }

    func testRemovalRecoveryRejectsLateBodiesAndPreservesOtherAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-removal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let intents = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        let blobs = MailBlobStore(stores: stores)
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(#"{"id":"m1","threadId":"t1","internalDate":"100","payload":{"partId":"p","mimeType":"text/plain","headers":[],"body":{"data":"SGVsbG8"}}}"#.utf8))
        let extraction = MIMEStructure.extract(message.payload!)
        for account in ["a@example.com", "b@example.com"] {
            try await blobs.put(message, account: account, extraction: extraction, ftsRowID: 1, at: 1)
            _ = try await blobs.prepare(account: account, messageID: "m1", at: 2)
        }
        let file = stores.directories.attachments.appendingPathComponent("cached.bin")
        try Data([1, 2, 3]).write(to: file)
        try await stores.blobs.write { db in
            try db.execute(sql: "INSERT INTO attachment(account,gmail_id,part_id,path) VALUES('a@example.com','m1','p',?)", arguments: [file.path])
        }
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com')")
            try db.execute(sql: "INSERT INTO tombstone(account_pk,gmail_id,at) VALUES(1,'m1',3)")
        }
        let recovery = MailRemovalRecovery(stores: stores, intents: intents)
        for _ in 0..<2 {
            let count = try await recovery.recover(account: "a@example.com")
            XCTAssertEqual(count, 1)
            do {
                try await blobs.put(message, account: "a@example.com", extraction: extraction, ftsRowID: 1, at: 4)
                XCTFail("Late download resurrected a deleted body")
            } catch MailBlobStore.Failure.removed {}
        }
        let removed = try await blobs.content(account: "a@example.com", messageID: "m1")
        let prepared = try await blobs.prepared(account: "a@example.com", messageID: "m1")
        let other = try await blobs.content(account: "b@example.com", messageID: "m1")
        XCTAssertNil(removed); XCTAssertNil(prepared); XCTAssertEqual(other?.plain, "Hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let attachments = try await stores.blobs.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM attachment") }
        XCTAssertEqual(attachments, 0)
    }

    func testRemovalRecoveryRetainsUnsafeFileForExplicitRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-removal-path-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let intents = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        let protectedFile = stores.directories.intentAttachments.appendingPathComponent("draft.bin")
        try Data([42]).write(to: protectedFile)
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES(1,'a@example.com')")
            try db.execute(sql: "INSERT INTO tombstone(account_pk,gmail_id,at) VALUES(1,'m',1)")
        }
        try await stores.blobs.write { db in
            try db.execute(sql: "INSERT INTO attachment(account,gmail_id,part_id,path) VALUES('a@example.com','m','p',?)", arguments: [protectedFile.path])
        }
        do {
            _ = try await MailRemovalRecovery(stores: stores, intents: intents).recover(account: "a@example.com")
            XCTFail("Must retain invalid path for repair")
        } catch MailRemovalRecovery.Failure.unsafeAttachmentPath {}
        XCTAssertEqual(try Data(contentsOf: protectedFile), Data([42]))
        let attachments = try await stores.blobs.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM attachment") }
        XCTAssertEqual(attachments, 1)
    }

    func testCodecRoundTripsEmptyUnicodeAndIncompressibleBytes() throws {
        var state: UInt64 = 42
        let random = Data((0..<64000).map { _ in state = state &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: state >> 32) })
        for data in [Data(), Data("雪🙂 café".utf8), random] {
            XCTAssertEqual(try MailBlobCodec.decode(MailBlobCodec.encode(data)), data)
        }
    }
    func testCodecRejectsCorruptAndMisdeclaredLengths() throws {
        let valid = try MailBlobCodec.encode(Data(repeating: 65, count: 1000))
        XCTAssertThrowsError(try MailBlobCodec.decode(Data(valid.prefix(9))))
        var wrongLength = valid
        wrongLength[7] = 0
        XCTAssertThrowsError(try MailBlobCodec.decode(wrongLength))
        var excessive = valid
        excessive[4] = 255
        XCTAssertThrowsError(try MailBlobCodec.decode(excessive))
    }
    func testBodyCommitReadsBackAndSeparatesAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-bodies-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let store = MailBlobStore(stores: stores)
        let json = #"{"id":"m1","threadId":"t1","internalDate":"100","payload":{"partId":"p","mimeType":"text/plain","headers":[],"body":{"data":"SGVsbG8"}}}"#
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        let extraction = MIMEStructure.extract(message.payload!)
        try await store.put(message, account: "A@EXAMPLE.COM", extraction: extraction, ftsRowID: 1, at: 123)
        let saved = try await store.content(account: "a@example.com", messageID: "m1")
        let other = try await store.content(account: "b@example.com", messageID: "m1")
        XCTAssertEqual(saved?.plain, "Hello")
        XCTAssertEqual(saved?.structure.plainPartID, "p")
        XCTAssertNil(other)
        let prepared = try await store.prepare(account: "a@example.com", messageID: "m1", at: 124)
        XCTAssertEqual(prepared?.text.blocks.first?.runs.first?.text, "Hello")
        let cached = try await store.prepared(account: "a@example.com", messageID: "m1")
        XCTAssertEqual(cached, prepared)
        try await store.put(message, account: "a@example.com", extraction: extraction, ftsRowID: 1, at: 125)
        let invalidated = try await store.prepared(account: "a@example.com", messageID: "m1")
        XCTAssertNil(invalidated)
        let staleAccepted = try await store.savePrepared(try XCTUnwrap(prepared), sourceRevision: try XCTUnwrap(saved?.revision),
            account: "a@example.com", messageID: "m1", at: 126)
        XCTAssertFalse(staleAccepted)
        _ = try await store.prepare(account: "a@example.com", messageID: "m1", at: 127)
        var incomplete = extraction
        incomplete.missingBodyPartIDs = ["p"]
        do {
            try await store.put(message, account: "a@example.com", extraction: incomplete, ftsRowID: 1, at: 124)
            XCTFail()
        } catch MailBlobStore.Failure.incomplete {}
        let preserved = try await store.content(account: "a@example.com", messageID: "m1")
        XCTAssertEqual(preserved?.plain, "Hello")
        try stores.searchReader.close()
        try stores.searchWriter.close()
        try stores.blobs.close()
        try stores.index.close()
        let reopened = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let persisted = try await MailBlobStore(stores: reopened).content(account: "a@example.com", messageID: "m1")
        XCTAssertEqual(persisted?.plain, "Hello")
        let persistedPrepared = try await MailBlobStore(stores: reopened).prepared(account: "a@example.com", messageID: "m1")
        XCTAssertEqual(persistedPrepared, prepared)
    }
}
