import XCTest
import GRDB
import Darwin

final class MailIndexReaderTests: XCTestCase {
    private func reader(count: Int) async throws -> MailIndexReader {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-index-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached {
            return try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations())
        }.value
        let key = try MailIndexReader.viewKey(.unified(.inbox))
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES (1,'a@example.com'),(2,'b@example.com')")
            try db.execute(sql: "INSERT INTO view(view_pk,key,kind) VALUES (1,?,1)", arguments: [key])
            try db.execute(sql: """
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < ?)
                INSERT INTO thread(thread_pk,account_pk,gmail_id,tie,last_date,message_count,flags,subject,
                                   people,people_total,recipients,recipients_total)
                SELECT n,1+n%2,'thread-'||n,n,1000000+n/3,1,
                       512 + CASE WHEN n%5=0 THEN 1 ELSE 0 END + CASE WHEN n%7=0 THEN 32 ELSE 0 END,
                       'Subject '||n,'[]',0,'[{"a":"to@example.com","u":false,"isMe":false}]',1
                FROM seq
                """, arguments: [count])
            try db.execute(sql: """
                INSERT INTO view_thread(view_pk,sort_key,tie,thread_pk,unread)
                SELECT 1,last_date,tie,thread_pk,CASE WHEN thread_pk%3=0 THEN 1 ELSE 0 END FROM thread
                """)
        }
        return MailIndexReader(stores: stores)
    }

    private func request(before: MailOrderKey? = nil, limit: Int = 53,
                         account: String? = nil, filters: Set<MailFilter> = []) -> PageRequest {
        PageRequest(view: .unified(.inbox), account: account, filters: filters, before: before, limit: limit)
    }

    func testSnapshotScopePagingRetainsSelectionAcrossConcurrentChanges() async throws {
        let reader = try await reader(count: 6001)
        let snapshot = try await Task.detached { try reader.stores.index.makeSnapshot() }.value
        let boundary = MailOrderKey(group: 0, sortKey: 1000000 + 5000 / 3, tie: 5000)
        // A later write must not change the set selected from the snapshot.
        try await reader.stores.index.write { db in
            try db.execute(sql: "DELETE FROM view_thread WHERE thread_pk % 2 = 0")
            try db.execute(sql: "UPDATE thread SET last_date=2000000")
        }
        var cursor: MailOrderKey? = boundary, first = true, ids: [Int64] = []
        while true {
            let request = request(before: cursor, limit: 53)
            let inclusive = first
            let page = try await snapshot.read { try MailIndexReader.page(request, in: $0, includingBoundary: inclusive) }
            XCTAssertLessThanOrEqual(page.count, 53)
            guard let last = page.last else { break }
            ids += page.map(\.threadPK)
            cursor = MailOrderKey(group: 0, sortKey: last.sortKey, tie: last.tie)
            first = false
        }
        XCTAssertEqual(ids, (1...5000).reversed().map(Int64.init))
    }

    func testKeysetWalkReachesBeyondUICapWithoutDuplicatesOrMissingTies() async throws {
        let reader = try await reader(count: 6001)
        var before: MailOrderKey?, ids: [Int64] = []
        while true {
            let rows = try await reader.page(request(before: before))
            XCTAssertLessThanOrEqual(rows.count, 53)
            guard let last = rows.last else { break }
            ids += rows.map(\.threadPK)
            before = MailOrderKey(group: 0, sortKey: last.sortKey, tie: last.tie)
        }
        XCTAssertEqual(ids, (1...6001).reversed().map(Int64.init))
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testAccountAndUnreadFiltersPreserveKeysetOrder() async throws {
        let reader = try await reader(count: 100)
        let rows = try await reader.page(request(limit: 100, account: "A@EXAMPLE.COM", filters: [.unread]))
        XCTAssertEqual(rows.map(\.threadPK), (1...100).reversed().filter { $0 % 6 == 0 }.map(Int64.init))
        XCTAssertTrue(rows.allSatisfy { $0.account == "a@example.com" && $0.unread })
        let counts = try await reader.counts(request(account: "a@example.com", filters: [.unread]))
        XCTAssertEqual(counts.total.value, rows.count)
        XCTAssertEqual(counts.unread, rows.count)
    }

    func testFlagFiltersAndRecipientSummary() async throws {
        let reader = try await reader(count: 100)
        let rows = try await reader.page(request(limit: 100, filters: [.starred, .noReply]))
        XCTAssertEqual(rows.map(\.threadPK), [70, 35])
        XCTAssertEqual(rows.first?.recipients.first?.a, "to@example.com")
        XCTAssertEqual(rows.first?.recipientsTotal, 1)
    }

    func testStubIsCountedButDoesNotLeakIntoDatedRows() async throws {
        let reader = try await reader(count: 10)
        try await reader.stores.index.write { db in
            try db.execute(sql: "UPDATE view_thread SET sort_key=-1 WHERE thread_pk=10")
            try db.execute(sql: "UPDATE view_thread SET sort_key=42 WHERE thread_pk=9")
        }
        let rows = try await reader.page(request())
        XCTAssertFalse(rows.contains { $0.threadPK == 10 })
        let moved = try XCTUnwrap(rows.first { $0.threadPK == 9 })
        XCTAssertEqual(moved.sortKey, 42)
        XCTAssertEqual(moved.lastDate, 1000003)
        let counts = try await reader.counts(request())
        XCTAssertEqual(counts.total.value, 9); XCTAssertEqual(counts.stillLoading, 1)
    }

    func testNewerInsertionDoesNotRepeatPreviousPage() async throws {
        let reader = try await reader(count: 100)
        let first = try await reader.page(request(limit: 10))
        let last = try XCTUnwrap(first.last)
        try await reader.stores.index.write { db in
            try db.execute(sql: "INSERT INTO thread(thread_pk,account_pk,gmail_id,tie,last_date) VALUES (101,1,'new',101,2000000)")
            try db.execute(sql: "INSERT INTO view_thread VALUES (1,2000000,101,101,1)")
        }
        let next = try await reader.page(request(before: .init(group: 0, sortKey: last.sortKey, tie: last.tie), limit: 10))
        XCTAssertEqual(next.map(\.threadPK), Array((81...90).reversed()).map(Int64.init))
    }

    func testTotalsAreExplicitlyBoundedAndInvalidPageSizesFail() async throws {
        let reader = try await reader(count: 10005)
        let counts = try await reader.counts(request())
        XCTAssertEqual(counts.total, MailCount(value: 10000, isAtLeast: true))
        for limit in [0, -1, MailTuning.listCap + 1] {
            do { _ = try await reader.page(request(limit: limit)); XCTFail("Invalid page size accepted") }
            catch { XCTAssertTrue(error is MailIndexReader.Failure) }
        }
    }

    func testCorruptSummaryIsAnErrorRatherThanEmptyInbox() async throws {
        let reader = try await reader(count: 1)
        try await reader.stores.index.write { db in try db.execute(sql: "UPDATE thread SET people='broken'") }
        do { _ = try await reader.page(request()); XCTFail("Corrupt summary silently accepted") }
        catch { XCTAssertTrue(error is MailIndexReader.Failure) }
    }

    func testKeysetCostAgainstOffsetWithRetainedHistory() async throws {
        // 90 days at 2,000 messages/day, deliberately one conversation per message.
        // A native component comparison, not frame/input evidence or the full app workload.
        let reader = try await reader(count: 180000)
        let began = Date().timeIntervalSince1970
        let output = ProcessInfo.processInfo.environment["MAIL_INDEX_BENCHMARK_OUTPUT"]
        var measurements: [[String: Any]] = []
        var worst: Double = 0
        func offsetPage(_ offset: Int, limit: Int) async throws -> [IndexRow] {
            let key = try MailIndexReader.viewKey(.unified(.inbox))
            return try await reader.stores.index.read { db in
                let pk = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT view_pk FROM view WHERE key=?", arguments: [key]))
                return try Row.fetchAll(db, sql: """
                    SELECT t.thread_pk, a.email, t.gmail_id, v.sort_key, v.tie, v.unread,
                           t.message_count, t.flags, t.subject, t.snippet, t.people, t.people_total,
                           t.labels, t.wake_at, t.returned_at, t.waiting_until, t.pending,
                           t.last_date, t.recipients, t.recipients_total
                    FROM view_thread v JOIN thread t ON t.thread_pk=v.thread_pk
                    JOIN account a ON a.account_pk=t.account_pk
                    WHERE v.view_pk=? AND v.sort_key>0
                    ORDER BY v.sort_key DESC,v.tie DESC LIMIT ? OFFSET ?
                    """, arguments: [pk, limit, offset]).map(MailIndexReader.decode)
            }
        }
        for depth in [0, 1800, 90000, 179950] {
            for size in [50, 500, 2000] {
                let preceding = Int64(180000 - depth + 1)
                let key: MailOrderKey? = depth == 0 ? nil : .init(group: 0, sortKey: 1000000 + preceding / 3, tie: preceding)
                var samples = [[Double](), [Double]()]
                for round in 0..<12 {
                    var identity: [[Int64]] = []
                    for mode in (round % 2 == 0 ? [0, 1] : [1, 0]) {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let rows = try await (mode == 0 ? reader.page(request(before: key, limit: size)) : offsetPage(depth, limit: size))
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                        samples[mode].append(ms)
                        if mode == 0 { worst = max(worst, ms) }
                        identity.append(rows.map(\.threadPK))
                    }
                    XCTAssertEqual(identity[0], identity[1], "Controls must return the exact same ordered rows")
                }
                var eviction: [Double] = []
                for mode in [0, 1] {
                    await Task.detached { reader.stores.index.releaseMemory() }.value
                    let start = DispatchTime.now().uptimeNanoseconds
                    let rows = try await (mode == 0 ? reader.page(request(before: key, limit: size)) : offsetPage(depth, limit: size))
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    eviction.append(ms)
                    if mode == 0 { worst = max(worst, ms) }
                    XCTAssertEqual(rows.count, min(size, 180000 - depth))
                }
                measurements.append(["offset": depth, "limit": size, "keysetMS": samples[0],
                                     "offsetMS": samples[1], "evictionMS": eviction])
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var fileBytes: [String: Int64] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let path = reader.stores.directories.indexDatabase.path + suffix
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            fileBytes["index.sqlite" + suffix] = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let result: [String: Any] = ["rows": 180000, "cases": measurements, "peakProcessRSSBytes": usage.ru_maxrss,
            "databaseFileBytes": fileBytes, "databaseTotalBytes": fileBytes.values.reduce(0, +), "keysetMaxMS": worst,
            "testProcessID": ProcessInfo.processInfo.processIdentifier,
            "startedUnixSeconds": began, "finishedUnixSeconds": Date().timeIntervalSince1970,
            "scope": "Real GRDB keyset versus OFFSET with identical decode and row parity. First, warm and page-cache eviction samples retained; not cold filesystem, UI or frame acceptance."]
        if let output {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        } else {
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result), uniformTypeIdentifier: "public.json")
            attachment.name = "mail-index-keyset-ablation"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertLessThanOrEqual(worst, 100, "A query exceeding the entire UI budget cannot be accepted; raw samples retained")
    }
}
