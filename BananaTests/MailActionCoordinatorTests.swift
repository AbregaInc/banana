import XCTest
import GRDB

final class MailActionCoordinatorTests: XCTestCase {
    private func setup() async throws -> (MailStores, MailIntentStore, MailActionCoordinator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-action-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (stores, intent) = try await Task.detached {
            let directories = try MailDirectories(root: root)
            return (try MailStores.open(directories, migrations: MailSlices.migrations()), try MailIntentStore(directories: directories))
        }.value
        let writer = MailWriter(stores: stores, sink: nil)
        for account in ["a@example.com", "b@example.com"] {
            let wire = GmailMessage(id: "m", threadId: "t", labelIds: ["INBOX", "UNREAD"], historyId: 1, internalDate: 1000,
                payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Subject")]))
            _ = try await writer.transact {
                try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload), structure: nil), account: account, myAddresses: [account], in: $0)
            }
        }
        return (stores, intent, MailActionCoordinator(stores: stores, intent: intent, writer: writer))
    }
    private let id = MailConversationID(account: "a@example.com", thread: "t")
    private func inbox(_ stores: MailStores) async throws -> [IndexRow] {
        try await MailIndexReader(stores: stores).page(PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 50))
    }
    func testBulkScopeBeyondLoadedWindowUsesOneReceiptAndDiskInverse() async throws {
        let (stores, intent, coordinator) = try await setup()
        let writer = MailWriter(stores: stores, sink: nil)
        _ = try await writer.transact { db in
            var changes = MailStoreChange()
            for n in 0..<2003 {
                let wire = GmailMessage(id: "bulk-\(n)", threadId: "bulk-\(n)", labelIds: ["INBOX", "UNREAD"], historyId: 1, internalDate: Int64(2000 + n), payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Bulk \(n)")]))
                changes.formUnion(try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload), structure: nil), account: "a@example.com", myAddresses: ["a@example.com"], in: db))
            }
            return changes
        }
        let before = try await MailIndexReader(stores: stores).counts(PageRequest(view: .unified(.inbox), account: "a@example.com", filters: [.unread], before: nil, limit: 50))
        XCTAssertEqual(before.total.value, 2004, "Fixture must contain fetched, visible conversations before the action")
        let result = try await coordinator.apply(.read(true), selection: .list(view: .unified(.inbox), account: "a@example.com", filters: [.unread], from: nil), sequence: 20, at: 1)
        XCTAssertEqual(result.count, 2004)
        XCTAssertEqual(result.sequence, 20)
        XCTAssertEqual(result.inverseGroup, 20)
        XCTAssertTrue(result.before.isEmpty, "Bulk inverse must stay on disk")
        XCTAssertNil(result.projectionError)
        let pending = try await intent.assertions(group: 20)
        XCTAssertEqual(pending.count, 500, "First intent page is bounded")
        let counts = try await MailIndexReader(stores: stores).counts(PageRequest(view: .unified(.inbox), account: "a@example.com", filters: [.unread], before: nil, limit: 50))
        XCTAssertEqual(counts.total.value, 0)
        let other = try await MailIndexReader(stores: stores).counts(PageRequest(view: .unified(.inbox), account: "b@example.com", filters: [.unread], before: nil, limit: 50))
        XCTAssertEqual(other.total.value, 1)
        let undo = try await coordinator.undo(result, change: .read(true), sequence: 21, at: 2)
        XCTAssertEqual(undo.count, 2004)
        XCTAssertNil(undo.projectionError)
        let restored = try await MailIndexReader(stores: stores).counts(PageRequest(view: .unified(.inbox), account: "a@example.com", filters: [.unread], before: nil, limit: 50))
        XCTAssertEqual(restored.total.value, 2004)
    }

    func testSearchScopeActionHonorsInclusiveBoundaryAndAccount() async throws {
        let (stores, _, coordinator) = try await setup()
        let rows = try await inbox(stores)
        let row = try XCTUnwrap(rows.first { $0.account == "a@example.com" })
        let result = try await coordinator.apply(.star(true), selection: .search(MailLocalSearchQuery(text: "Subject", account: row.account,
            before: MailOrderKey(group: 0, sortKey: row.lastDate, tie: row.tie))), sequence: 10, at: 1)
        XCTAssertEqual(result.count, 1)
        let after = try await inbox(stores)
        XCTAssertEqual(after.first { $0.account == row.account }?.flags.contains(.starred), true)
        XCTAssertEqual(after.first { $0.account != row.account }?.flags.contains(.starred), false)
    }

    func testUnifiedActionKeepsOneReceiptAndExactInversePerAccount() async throws {
        let (stores, intent, coordinator) = try await setup()
        let targets = [id, MailConversationID(account: "b@example.com", thread: "t")]
        let result = try await coordinator.apply(.star(true), to: targets.map {
            MailActionCoordinator.Target(id: $0, asOf: 1000)
        }, sequence: 11, at: 2)
        XCTAssertEqual(result.sequence, 11)
        XCTAssertEqual(result.count, 2)
        XCTAssertNil(result.projectionError)
        XCTAssertEqual(result.before.count, 2)
        XCTAssertTrue(result.before.allSatisfy { !$0.want && $0.labelRef == "STARRED" })
        let rows = try await inbox(stores)
        XCTAssertTrue(rows.allSatisfy { $0.flags.contains(.starred) })
        let pending = try await intent.assertions()
        XCTAssertEqual(Set(pending.map(\.seq)), [11])
        XCTAssertEqual(Set(pending.map { $0.assertion.account }), Set(targets.map(\.account)))
    }

    func testSnapshotBoundaryExcludesLaterReplyWithIdenticalDate() async throws {
        let (stores, intent, coordinator) = try await setup()
        let ceiling = try await stores.index.read { try Int64.fetchOne($0, sql: "SELECT max(arrival_seq) FROM message")! }
        let wire = GmailMessage(id: "late", threadId: "t", labelIds: ["INBOX", "UNREAD"], historyId: 2, internalDate: 1000,
            payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Later reply")]))
        let writer = MailWriter(stores: stores, sink: nil)
        _ = try await writer.transact {
            try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 2, headers: MessageHeaders(payload: wire.payload), structure: nil), account: self.id.account, myAddresses: [self.id.account], in: $0)
        }
        let result = try await coordinator.apply(.done, to: [MailActionCoordinator.Target(id: id, asOf: 1000, messageArrivalCeiling: ceiling)], sequence: 1, at: 2)
        XCTAssertEqual(result.count, 1)
        let pending = try await intent.assertions()
        XCTAssertEqual(Set(pending.map { $0.assertion.messageID }), ["m"])
        let rows = try await inbox(stores)
        XCTAssertTrue(rows.contains { $0.account == id.account }, "The new unread reply must remain in Inbox")
    }

    func testProjectionFailureStillReturnsInverseForSavedReceipt() async throws {
        let (stores, _, coordinator) = try await setup()
        try await stores.index.write { try $0.execute(sql: "CREATE TRIGGER fail_overlay BEFORE INSERT ON overlay BEGIN SELECT RAISE(ABORT,'injected failure'); END") }
        let result = try await coordinator.apply(.star(true), to: [MailActionCoordinator.Target(id: id, asOf: 1000)], sequence: 9, at: 2)
        XCTAssertEqual(result.sequence, 9)
        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(result.projectionError)
        XCTAssertEqual(result.before.count, 1)
        XCTAssertFalse(result.before[0].want)
    }
    func testArrivalBoundarySurvivesDeletedRowIDReuse() async throws {
        let (stores, intent, coordinator) = try await setup()
        let writer = MailWriter(stores: stores, sink: nil)
        func insert(_ message: String) async throws {
            let wire = GmailMessage(id: message, threadId: "t", labelIds: ["INBOX", "UNREAD"], historyId: 2, internalDate: 1000,
                payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Reply")]))
            _ = try await writer.transact {
                try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 2, headers: MessageHeaders(payload: wire.payload), structure: nil), account: self.id.account, myAddresses: [self.id.account], in: $0)
            }
        }
        try await insert("removed")
        let rows = try await inbox(stores)
        let shown = MailRowMapper.row(try XCTUnwrap(rows.first { $0.account == id.account }), labels: [], reason: nil, in: MailScope(place: .mailbox(.inbox)))
        guard case .reading(let readings) = MailTarget.asShown([shown]) else { return XCTFail("Missing UI snapshot boundary") }
        let oldPK = try await stores.index.read { try Int64.fetchOne($0, sql: "SELECT msg_pk FROM message WHERE gmail_id='removed'")! }
        try await stores.index.write { try $0.execute(sql: "DELETE FROM message WHERE gmail_id='removed'") }
        try await insert("new")
        let newPK = try await stores.index.read { try Int64.fetchOne($0, sql: "SELECT msg_pk FROM message WHERE gmail_id='new'")! }
        XCTAssertEqual(newPK, oldPK, "Exercise SQLite row-id reuse, not just increasing ids")
        _ = try await coordinator.apply(.done, to: readings.map { .init(id: $0.id, asOf: $0.asOf, messageArrivalCeiling: $0.arrivalSequence) }, sequence: 1, at: 3)
        let assertions = try await intent.assertions()
        XCTAssertEqual(Set(assertions.map { $0.assertion.messageID }), ["m"])
        let after = try await inbox(stores)
        XCTAssertTrue(after.contains { $0.account == id.account })
    }
    func testDurableArchiveMovesOnlyTheTargetAccountAndSurvivesProjectionLoss() async throws {
        let (stores, intent, coordinator) = try await setup()
        let seq = try await coordinator.apply(.done, to: id, asOf: 1000, at: 2)
        XCTAssertNotNil(seq)
        let rows = try await inbox(stores)
        XCTAssertEqual(rows.map(\.account), ["b@example.com"])
        let pending = try await intent.assertions()
        XCTAssertEqual(pending.count, 2)
        let provider = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_label ml JOIN label l ON l.label_pk=ml.label_pk WHERE l.gmail_id='INBOX'") }
        XCTAssertEqual(provider, 2, "Local actions must not overwrite raw provider truth")
        try await stores.index.write { try $0.execute(sql: "DELETE FROM overlay") }
        try await coordinator.refresh(account: id.account, messages: ["m"])
        let restored = try await inbox(stores)
        XCTAssertEqual(restored.map(\.account), ["b@example.com"])
    }
    func testRefusalAndRetryRecomputeRowStatusWithoutStickyFailure() async throws {
        let (stores, intent, coordinator) = try await setup()
        let applied = try await coordinator.apply(.star(true), to: id, asOf: 1000, at: 2)
        let seq = try XCTUnwrap(applied)
        let key = SentKey(account: id.account, messageID: "m", labelRef: "STARRED", sentSeq: seq)
        try await intent.markInFlight([key])
        try await intent.refused([key], failure: .accessMissing)
        try await coordinator.refresh(account: id.account, messages: ["m"])
        var rows = try await inbox(stores)
        XCTAssertEqual(rows.first { $0.account == id.account }?.pending, 2)
        XCTAssertEqual(rows.first { $0.account == id.account }?.flags.contains(.starred), false, "Refused intent must not override provider labels")
        try await intent.retry(group: seq)
        try await coordinator.refresh(account: id.account, messages: ["m"])
        rows = try await inbox(stores)
        XCTAssertEqual(rows.first { $0.account == id.account }?.pending, 1)
        XCTAssertEqual(rows.first { $0.account == id.account }?.flags.contains(.starred), true)
        try await intent.markInFlight([key]); try await intent.confirmed([key])
        try await coordinator.refresh(account: id.account, messages: ["m"])
        rows = try await inbox(stores)
        XCTAssertEqual(rows.first { $0.account == id.account }?.pending, 0)
    }
    func testIndexFailureDoesNotLoseCommittedIntent() async throws {
        let (stores, intent, coordinator) = try await setup()
        try await stores.index.write { try $0.execute(sql: "CREATE TRIGGER fail_overlay BEFORE INSERT ON overlay BEGIN SELECT RAISE(ABORT,'injected failure'); END") }
        do { _ = try await coordinator.apply(.star(true), to: id, asOf: 1000, at: 2); XCTFail() }
        catch MailActionCoordinator.Failure.projectionAfterCommit(let sequence, let underlying) {
            XCTAssertEqual(sequence, 1)
            XCTAssertTrue(underlying is DatabaseError)
        }
        catch { XCTFail("Lost the durable receipt: \(error)") }
        let rows = try await intent.assertions()
        XCTAssertEqual(rows.count, 1)
        try await stores.index.write { try $0.execute(sql: "DROP TRIGGER fail_overlay") }
        try await coordinator.recover()
        let inbox = try await inbox(stores)
        XCTAssertTrue(inbox.first { $0.account == id.account }!.flags.contains(.starred))
    }
    func testStartupRemovesConfirmedOverlayAndRecoversInterruptedDelivery() async throws {
        let (stores, intent, coordinator) = try await setup()
        let applied = try await coordinator.apply(.star(true), to: id, asOf: 1000, at: 2)
        let sequence = try XCTUnwrap(applied)
        let key = SentKey(account: id.account, messageID: "m", labelRef: "STARRED", sentSeq: sequence)
        try await intent.markInFlight([key])
        let restarted = MailActionCoordinator(stores: stores, intent: intent, writer: MailWriter(stores: stores, sink: nil))
        try await restarted.recover()
        let recovered = try await intent.assertions()
        XCTAssertEqual(recovered.first?.state, .pending)
        XCTAssertNil(recovered.first?.sentSeq)
        try await intent.markInFlight([key])
        try await intent.confirmed([key])
        // Simulate termination between durable confirmation and index cleanup.
        try await restarted.recover()
        let rows = try await inbox(stores)
        XCTAssertFalse(rows.first { $0.account == id.account }!.flags.contains(.starred))
        XCTAssertEqual(rows.first { $0.account == id.account }?.pending, 0)
        try await restarted.recover() // Recovery is idempotent.
        let remaining = try await intent.assertions()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testActionCommitCostForDenseConversations() async throws {
        var timings: [String: [Double]] = [:]
        for count in [1, 20, 100, 1000] {
            let (stores, _, coordinator) = try await setup()
            if count > 1 {
                try await stores.index.write { db in
                    try db.execute(sql: """
                        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?)
                        INSERT INTO message(account_pk,gmail_id,thread_pk,internal_date,fetch_state,flags)
                        SELECT m.account_pk,'extra'||n.x,m.thread_pk,1000+n.x,1,m.flags FROM message m JOIN account a ON a.account_pk=m.account_pk CROSS JOIN n WHERE a.email='a@example.com' AND m.gmail_id='m'
                        """, arguments: [count - 1])
                }
            }
            var samples: [Double] = []
            for trial in 0..<6 {
                let start = ContinuousClock.now
                _ = try await coordinator.apply(.important(trial % 2 == 0), to: id, asOf: Int64.max, at: Int64(trial + 10))
                let elapsed = start.duration(to: .now).components
                samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            timings[String(count)] = samples
        }
        if let path = ProcessInfo.processInfo.environment["MAIL_ACTION_BENCHMARK_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["samplesMS": timings,
                "scope": "Intent full-fsync plus index projection; first and five warm actions; no UI, device or eviction acceptance"], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        for (count, samples) in timings {
            for sample in samples { XCTAssertLessThan(sample, 100, "Action commit for \(count) messages exceeds component ceiling") }
        }
    }

    func testLaterOppositeActionReplacesEffectiveState() async throws {
        let (stores, intent, coordinator) = try await setup()
        _ = try await coordinator.apply(.star(true), to: id, asOf: 1000, at: 2)
        _ = try await coordinator.apply(.star(false), to: id, asOf: 1000, at: 3)
        let rows = try await inbox(stores)
        XCTAssertFalse(rows.first { $0.account == id.account }!.flags.contains(.starred))
        let pending = try await intent.assertions()
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending.first?.assertion.want, false)
    }
}
