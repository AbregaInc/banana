import XCTest
import GRDB

final class MailLocalSearchTests: XCTestCase {
    private func makeReader(count: Int = 6001) async throws -> MailIndexReader {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-search-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO account(account_pk,email) VALUES (1,'a@example.com'),(2,'b@example.com')")
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<\(count))
                INSERT INTO thread(thread_pk,account_pk,gmail_id,tie,last_date,subject,people,recipients)
                SELECT x,1+x%2,'t'||x,x,10000+x,'Summary','[]','[]' FROM n;
                INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,subject,snippet,from_addr,recipients)
                SELECT thread_pk,account_pk,'m'||thread_pk,thread_pk,'Café project '||thread_pk,'budget planning','sender@example.com',
                    '{"to":["recipient@example.com"],"cc":[],"bcc":[]}' FROM thread;
                """)
        }
        return MailIndexReader(stores: stores)
    }
    func testRetainedHistoryKeysetAndAccountIsolation() async throws {
        let reader = try await makeReader()
        var query = MailLocalSearchQuery(text: "CAFE proj", account: "A@EXAMPLE.COM", limit: 47)
        var ids: [Int64] = []
        repeat {
            let rows = try await reader.search(query)
            guard let last = rows.last else { break }
            ids += rows.map(\.threadPK)
            query.before = MailOrderKey(group: 0, sortKey: last.sortKey, tie: last.tie)
        } while true
        XCTAssertEqual(ids, stride(from: 6000, through: 2, by: -2).map(Int64.init))
        let sender = try await reader.search(MailLocalSearchQuery(text: "sender@example", account: nil))
        let recipient = try await reader.search(MailLocalSearchQuery(text: "recipient", account: nil))
        XCTAssertEqual(sender.count, 50); XCTAssertEqual(recipient.count, 50)
        let blank = try await reader.search(MailLocalSearchQuery(text: "\"* ()", account: nil))
        XCTAssertTrue(blank.isEmpty)
    }
    func testEditsDeletesAndMultipleMessageHitsAreAtomic() async throws {
        let reader = try await makeReader()
        try await reader.stores.index.write { db in
            try db.execute(sql: "UPDATE message SET subject='unique needle' WHERE msg_pk=1")
            try db.execute(sql: "INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,subject) VALUES (7000,2,'second',1,'unique needle')")
        }
        var rows = try await reader.search(MailLocalSearchQuery(text: "unique needle", account: nil))
        XCTAssertEqual(rows.map(\.threadPK), [1])
        try await reader.stores.index.write { db in
            try db.execute(sql: "DELETE FROM message WHERE msg_pk=7000")
            try db.execute(sql: "UPDATE message SET subject='replaced' WHERE msg_pk=1")
        }
        rows = try await reader.search(MailLocalSearchQuery(text: "unique needle", account: nil))
        XCTAssertTrue(rows.isEmpty)
    }
    func testLiveStructuredFiltersUseDiskRowsAndPreservePaging() async throws {
        let reader = try await makeReader(count: 120)
        try await reader.stores.index.write { db in
            try db.execute(sql: "UPDATE thread SET unread_count=1 WHERE thread_pk IN (2,4,6)")
            try db.execute(sql: "UPDATE message SET from_name='Alex Morgan',from_addr='alex@example.com' WHERE msg_pk IN (2,6)")
        }
        let unread = LiveFilter(scope: "mail", terms: [.init(field: "unread", op: "is", value: "true")])
        var query = MailLocalSearchQuery(text: unread.searchExpression, account: "a@example.com", limit: 2)
        let first = try await reader.search(query)
        XCTAssertEqual(first.map(\.threadPK), [6,4])
        query.before = MailOrderKey(group: 0, sortKey: first.last!.sortKey, tie: first.last!.tie)
        let second = try await reader.search(query)
        XCTAssertEqual(second.map(\.threadPK), [2])
        var sender = unread
        sender.terms.append(.init(field: "person", op: "contains", value: "Alex Morgan"))
        let sent = try await reader.search(MailLocalSearchQuery(text: sender.searchExpression, account: nil))
        XCTAssertEqual(sent.map(\.threadPK), [6,2])
        let wrongAccount = try await reader.search(MailLocalSearchQuery(text: sender.searchExpression, account: "b@example.com"))
        XCTAssertTrue(wrongAccount.isEmpty)
        let future = try await reader.search(MailLocalSearchQuery(text: "banana-filter:invalid", account: nil))
        XCTAssertTrue(future.isEmpty)
        let invalid = LiveFilter(scope: "mail", terms: [.init(field: "bogus", op: "is", value: "true")])
        let rejected = try await reader.search(MailLocalSearchQuery(text: invalid.searchExpression, account: nil))
        XCTAssertTrue(rejected.isEmpty)
    }

    func testSearchCostAtRetainedHistoryScale() async throws {
        let reader = try await makeReader(count: 180000)
        var measurements: [String: [Double]] = [:]
        for term in ["180000", "budget"] {
            var values: [Double] = [], referenceValues: [Double] = []
            for trial in 0..<8 {
                var ids: [Int64] = []
                for reference in (trial % 2 == 0 ? [true, false] : [false, true]) {
                    let start = ContinuousClock.now
                    let query = MailLocalSearchQuery(text: term, account: nil)
                    let rows = try await (reference ? reader.searchReference(query) : reader.search(query))
                    let duration = start.duration(to: .now).components
                    let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                    if reference { referenceValues.append(ms) } else { values.append(ms) }
                    XCTAssertEqual(rows.count, term == "budget" ? 50 : 1)
                    if !ids.isEmpty { XCTAssertEqual(rows.map(\.threadPK), ids) }
                    ids = rows.map(\.threadPK)
                }
            }
            measurements[term] = values
            measurements[term + "-reference"] = referenceValues
        }
        if let path = ProcessInfo.processInfo.environment["MAIL_SEARCH_BENCHMARK_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["messages": 180000, "samplesMS": measurements,
                "scope": "Mac disk query component; first query then seven warm samples, no UI or eviction acceptance"], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
        for (term, samples) in measurements where !term.hasSuffix("-reference") {
            for sample in samples { XCTAssertLessThan(sample, 100, "Search \(term) exceeded local UI ceiling before rendering") }
        }
    }

    func testLiteralQueryDoesNotExecuteFTSOperators() {
        XCTAssertEqual(MailLocalSearchQuery(text: "red OR blue*", account: nil).match, "\"red\"* AND \"OR\"* AND \"blue\"*")
        XCTAssertNil(MailLocalSearchQuery(text: "   ", account: nil).match)
    }
}
