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
    func testRankedReaderReconcilesRenamesAndReusedIDsAcrossRelaunch() async throws {
        let reader = try await makeReader(count: 4), stores = reader.stores
        var first: MailRankedIndex? = MailRankedIndex(stores)
        try await stores.blobs.write { db in
            try db.execute(sql: "INSERT INTO attachment(account,gmail_id,part_id,filename) VALUES ('a@example.com','m2','1','expense-report.pdf')")
        }
        try await first!.synchronize()
        let file = try await first!.top("expense-report.pdf", allowed:["A@EXAMPLE.COM"])
        XCTAssertEqual(file?.first?.threadPK, 2)
        let other = try await first!.top("expense-report.pdf", allowed:["b@example.com"])
        XCTAssertTrue(other?.isEmpty == true)
        try await stores.blobs.write { db in try db.execute(sql:"UPDATE attachment SET filename='itinerary.txt'") }
        let stale = try await first!.top("expense-report.pdf", allowed:["a@example.com"])
        XCTAssertNil(stale)
        first = nil
        let next = MailRankedIndex(stores)
        try await next.synchronize()
        let renamed = try await next.top("itinerary.txt", allowed:["a@example.com"])
        let old = try await next.top("expense", allowed:["a@example.com"])
        XCTAssertEqual(renamed?.first?.threadPK,2)
        XCTAssertTrue(old?.isEmpty == true)
        try await stores.index.write { db in
            try db.execute(sql:"DELETE FROM message WHERE msg_pk=2; INSERT INTO message(msg_pk,account_pk,gmail_id,thread_pk,subject) VALUES(2,1,'different',4,'Replacement')")
        }
        try await next.synchronize()
        let removed = try await next.top("itinerary",allowed:["a@example.com"])
        let replacement = try await next.top("replacement",allowed:["a@example.com"])
        XCTAssertTrue(removed?.isEmpty == true)
        XCTAssertEqual(replacement?.first?.threadPK,4)
    }

    func testAttachmentTextIsSearchableAndFollowsItsChanges() async throws {
        let stores = try await makeReader(count: 4).stores
        let index = MailRankedIndex(stores)
        try await index.synchronize()
        let before = try await index.top("hetzner invoice", allowed: ["a@example.com"])
        XCTAssertEqual(before?.count, 0)
        try await stores.blobs.write { db in
            try MailCloudText.store([("A@example.com", "m2", [MailCloudText.Part(partId: "1", name: "statement.pdf", text: "Hetzner invoice for November")])], in: db)
        }
        try await index.synchronize()
        let found = try await index.top("hetzner invoice", allowed: ["a@example.com"])
        XCTAssertEqual(found?.first?.threadPK, 2)
        XCTAssertEqual(found?.first?.snippet, "Hetzner invoice for November · statement.pdf",
                       "a row found by its file shows the file and its words")
        let bySubject = try await index.top("summary", allowed: ["a@example.com"])
        XCTAssertFalse(bySubject?.contains { $0.snippet.contains("statement.pdf") } ?? true, "a row its own text explains keeps its snippet")
        let otherAccount = try await index.top("hetzner", allowed: ["b@example.com"])
        XCTAssertEqual(otherAccount?.count, 0)
        try await stores.blobs.write { db in try db.execute(sql: "DELETE FROM attachment_text") }
        try await index.synchronize()
        let gone = try await index.top("hetzner", allowed: ["a@example.com"])
        XCTAssertEqual(gone?.count, 0)
    }

    func testAttachmentExcerptNamesTheFileAndCutsAroundTheFirstMatch() {
        let long = String(repeating: "terms and conditions ", count: 10) + "Monthly rent is 2,400 dollars, due on the first." + String(repeating: " filler", count: 40)
        let stored = MailCloudText.indexed([.init(partId: "1", name: "notes.txt", text: "grocery list"),
                                            .init(partId: "2", name: "Lease Final.pdf", text: long)])
        let excerpt = MailCloudText.excerpt(stored, words: ["rent"])
        XCTAssertTrue(excerpt?.hasPrefix("…Monthly rent is 2,400 dollars") == true, excerpt ?? "nil")
        XCTAssertTrue(excerpt?.hasSuffix("… · Lease Final.pdf") == true, excerpt ?? "nil")
        XCTAssertEqual(MailCloudText.excerpt(stored, words: ["grocery"]), "grocery list · notes.txt")
        XCTAssertNil(MailCloudText.excerpt(stored, words: ["passport"]))
    }

    func testOriginalMIMEFilenameSupersedesCachedPartMetadata() async throws {
        let stores = try await makeReader(count: 4).stores
        let index = MailRankedIndex(stores)
        try await stores.blobs.write { db in
            let structure = try MailBlobCodec.encode(Data(#"{"attachments":[{"partID":"1","name":"revised.ods","isInline":false},{"partID":"2","name":"hiddenlogo.png","isInline":true}]}"#.utf8))
            try db.execute(sql: """
                INSERT INTO content(account,gmail_id,thread_id,internal_date,fts_rowid,headers,structure,level,bytes,stored_at,opened_at)
                VALUES('a@example.com','m2','t2',1,1,x'',?,1,0,1,1)
                """, arguments: [structure])
            try db.execute(sql: """
                INSERT INTO attachment(account,gmail_id,part_id,filename) VALUES
                ('a@example.com','m2','1','original.xlsx'),('a@example.com','m2','2','hiddenlogo.png')
                """)
        }
        try await index.synchronize()
        let current = try await index.top("revised.ods", allowed: ["a@example.com"])
        let old = try await index.top("original", allowed: ["a@example.com"])
        let inline = try await index.top("hiddenlogo", allowed: ["a@example.com"])
        XCTAssertEqual(current?.first?.threadPK, 2)
        XCTAssertEqual(old?.count, 0)
        XCTAssertEqual(inline?.count, 0)
    }

    func testInterruptedBodyReplacementRetainsQueueAndRetriesAfterOpeningAgain() async throws {
        let stores = try await makeReader(count: 4).stores
        try await stores.index.write { try $0.execute(sql: "UPDATE message SET fts_state=2 WHERE msg_pk=2") }
        try await stores.blobs.write { db in
            let text = try MailBlobCodec.encode(Data("originalpassage".utf8))
            try db.execute(sql: """
                INSERT INTO prepared(account,gmail_id,prep_version,body,text,bytes,made_at)
                VALUES ('a@example.com','m2',1,?,?,10,1)
                """, arguments: [text,text])
        }
        var first: MailRankedIndex? = MailRankedIndex(stores)
        try await first!.synchronize()
        try await stores.blobs.write { db in
            try db.execute(sql: "UPDATE prepared SET text=?", arguments: [try MailBlobCodec.encode(Data("replacementpassage".utf8))])
        }
        // Fail after the Tantivy commit but before SQLite acknowledges the replacement.
        try await stores.index.write { try $0.execute(sql: """
            CREATE TRIGGER fail_hint BEFORE INSERT ON ranked_hint BEGIN SELECT RAISE(ABORT,'fixture failure'); END
            """) }
        do {
            try await first!.synchronize()
            XCTFail("the failed acknowledgement must be retried")
        } catch {}
        let dirty = try await stores.blobs.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM ranked_blob_dirty") }
        XCTAssertEqual(dirty, 1)
        first = nil
        try await stores.index.write { try $0.execute(sql: "DROP TRIGGER fail_hint") }
        let reopened = MailRankedIndex(stores)
        try await reopened.synchronize()
        let new = try await reopened.top("replacementpassage", allowed: ["a@example.com"])
        let old = try await reopened.top("originalpassage", allowed: ["a@example.com"])
        XCTAssertEqual(new?.map(\.threadPK), [2])
        XCTAssertTrue(old?.isEmpty == true)
    }

    @MainActor func testRankedSnapshotPagesPastPromotedMatchesAndScopesActions() async throws {
        let reader = try await makeReader(count:220), stores = reader.stores
        let rank = MailRankedIndex(stores)
        try await rank.synchronize()
        let search = MailGmailSearch(stores:stores,ranked:rank,dependencies:.init(api:MailGmailSearchTests.Gmail(),
            token:{ _ in throw GmailError.networkDisabled },store:{ _,_ in },accounts:{ [] },changed:{}))
        let allowed: Set<String> = ["a@example.com"]
        var scope = MailScope(place:.search("budget"))
        func page(_ scope:MailScope, _ limit:Int) async throws -> MailListSnapshot {
            try await search.snapshot(scope,limit:limit,fresh:true,allowedAccounts:allowed,through:0) {
                MailRowMapper.row($0,labels:[],reason:nil,in:scope)
            }
        }
        let shell = try await page(scope,5)
        let mailbox = try await page(scope,105)
        XCTAssertEqual(shell.rows.map(\.id),Array(mailbox.rows.prefix(5)).map(\.id))
        XCTAssertEqual(mailbox.rows.prefix(100).last?.key.group,-1)
        XCTAssertEqual(mailbox.rows.last?.key.group,0)
        XCTAssertTrue(mailbox.rows.allSatisfy { $0.id.account == "a@example.com" })
        scope.before = shell.rows.last?.key
        let afterRank = try await page(scope,5)
        XCTAssertEqual(afterRank.rows.map(\.id),Array(mailbox.rows[5..<10]).map(\.id))
        scope.before = mailbox.rows.last?.key
        let last = try await page(scope,105)
        XCTAssertEqual(Set((mailbox.rows+last.rows).map(\.id)).count,110)
        XCTAssertEqual(last.rows.count,5)
        let query = try XCTUnwrap(search.actionQuery(scope,from:shell.rows.last?.key,allowed:allowed))
        let selected = try await reader.search(query)
        XCTAssertTrue(Set(selected.map(\.thread)).isDisjoint(with:shell.rows.prefix(4).map(\.id.thread)))
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

    func testBodyPageReadsUntilAnotherConversationOrTheMessageCap() async throws {
        let reader = try await makeReader(count: 402)
        let stores = reader.stores
        try await stores.index.write { db in
            try db.execute(sql: "UPDATE message SET fts_state=2")
        }
        try await stores.searchWriter.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<402)
                INSERT INTO body_doc(rowid,msg_pk) SELECT x,x FROM n;
                INSERT INTO msg_fts(rowid,body)
                SELECT rowid,CASE WHEN rowid<=399 THEN 'memo subset' ELSE 'memo' END FROM body_doc;
                """)
        }
        let all = MailLocalSearchQuery(text: "memo", account: nil, limit: 2)
        let first = try await stores.searchReader.read { try MailLocalSearch.bodyThreads(all, in: $0) }
        XCTAssertEqual(first.threads, [402, 401])
        XCTAssertTrue(first.more)

        try await stores.index.write { db in
            try db.execute(sql: "UPDATE message SET thread_pk=2-msg_pk%2")
        }
        let capped = try await stores.searchReader.read { try MailLocalSearch.bodyThreads(all, in: $0) }
        XCTAssertEqual(capped.threads, [2, 1])
        XCTAssertTrue(capped.more)
        let subset = MailLocalSearchQuery(text: "subset", account: nil, limit: 2)
        let exhausted = try await stores.searchReader.read { try MailLocalSearch.bodyThreads(subset, in: $0) }
        XCTAssertEqual(exhausted.threads, [1, 2])
        XCTAssertFalse(exhausted.more)
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
        let budget = CostBudget(self)
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
        for (term, samples) in measurements.sorted(by: { $0.key < $1.key }) where !term.hasSuffix("-reference") {
            budget.expect(samples, below: 100, "Search \(term) exceeded local UI ceiling before rendering")
        }
        try budget.finish()
    }

    func testLiteralQueryDoesNotExecuteFTSOperators() {
        XCTAssertEqual(MailLocalSearchQuery(text: "red OR blue*", account: nil).match, "\"red\"* AND \"OR\"* AND \"blue\"*")
        XCTAssertNil(MailLocalSearchQuery(text: "   ", account: nil).match)
    }
}
