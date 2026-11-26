import Foundation
import GRDB
import XCTest

/// Local replay of the production snapshot boundary. The retained report contains ranks and clocks only.
@MainActor final class RankedMailReplayTests: XCTestCase {
    struct Topic: Decodable {
        let family, query: String
        let targets: Set<String>
        let sameName: Set<String>?
    }
    struct Sample: Encodable {
        let topic: Int, family, method: String, limit, trial, rank: Int, exactFilenameFirst: Bool?, ms: Double
    }
    struct Report: Encodable { let buildSeconds: Double, samples: [Sample] }
    private func openFixture(_ root: URL) async throws -> MailStores {
        try await Task.detached {
            var migrations = MailSlices.migrations()
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("public-replay").path) {
                migrations = MailMigrations()
                MailRankedSchema.register(in: &migrations)
                MailCloudText.register(in: &migrations)
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-migrations.json").path) {
                // The read-only export may come from a later Beta. Its source schema is already materialized.
                // Exercise ranked migrations on that private copy without changing the app’s downgrade guard.
                let applied = try JSONDecoder().decode(
                    [String: [String]].self,
                    from: Data(contentsOf: root.appendingPathComponent("fixture-migrations.json")))
                migrations = MailMigrations()
                for id in applied["index.sqlite"] ?? [] { migrations.index.registerMigration(id) { _ in } }
                for id in applied["blobs.sqlite"] ?? [] { migrations.blobs.registerMigration(id) { _ in } }
                for id in applied["search.sqlite"] ?? [] { migrations.search.registerMigration(id) { _ in } }
                MailRankedSchema.register(in: &migrations)
                MailCloudText.register(in: &migrations)
            }
            return try MailStores.open(MailDirectories(root: root), migrations: migrations)
        }.value
    }
    func testFirstPage() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try XCTUnwrap(env["RANKED_MAIL_FIXTURE"]))
        let rules = LiveFilterParser.compile(
            try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["TREC_MAIL_RULES"]))))
        let topics = try JSONDecoder().decode(
            [Topic].self, from: Data(contentsOf: root.appendingPathComponent("tasks.json")))
        let stores = try await openFixture(root)
        let accounts = try await stores.index.read { Set(try String.fetchAll($0, sql: "SELECT email FROM account")) }
        let index = MailRankedIndex(stores)
        let before = ProcessInfo.processInfo.systemUptime
        try await index.synchronize()
        let build = ProcessInfo.processInfo.systemUptime - before
        let api = MailGmailSearchTests.Gmail()
        let deps = MailGmailSearch.Dependencies(
            api: api, token: { _ in throw GmailError.networkDisabled },
            store: { _, _ in XCTFail("unexpected network write") }, accounts: { [] }, changed: {})
        let methods = [
            ("chronological", MailGmailSearch(stores: stores, dependencies: deps)),
            ("ranked", MailGmailSearch(stores: stores, ranked: index, dependencies: deps)),
        ]
        var all: [Sample] = []
        for trial in 0..<3 {
            for pos in topics.indices {
                let slot = (pos + trial * 53) % topics.count
                let topic = topics[slot]
                for (name, service) in (pos + trial).isMultiple(of: 2) ? methods : methods.reversed() {
                    for limit in (pos + trial).isMultiple(of: 2) ? [5, 50] : [50, 5] {
                        let start = ProcessInfo.processInfo.systemUptime
                        let scope = MailScope(
                            place: .search(
                                LiveFilterParser.parse(topic.query, scope: "mail", rules: rules).searchExpression))
                        let page = try await service.snapshot(
                            scope, limit: limit, fresh: true, allowedAccounts: accounts, through: 0
                        ) {
                            MailRowMapper.row($0, labels: [], reason: nil, in: scope)
                        }
                        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        XCTAssertEqual(Set(page.rows.map(\.id)).count, page.rows.count)
                        XCTAssertTrue(zip(page.rows, page.rows.dropFirst()).allSatisfy { $0.key > $1.key })
                        let rank = page.rows.firstIndex { topic.targets.contains($0.id.thread) }.map { $0 + 1 } ?? 0
                        all.append(
                            Sample(
                                topic: slot, family: topic.family, method: name, limit: limit, trial: trial, rank: rank,
                                exactFilenameFirst: topic.sameName.map {
                                    $0.contains(page.rows.first?.id.thread ?? "")
                                }, ms: ms))
                        service.keep([])
                    }
                }
            }
        }
        try JSONEncoder().encode(Report(buildSeconds: build, samples: all)).write(
            to: URL(fileURLWithPath: try XCTUnwrap(env["RANKED_MAIL_RESULTS"])))
    }
}

extension RankedMailReplayTests {
    struct TopList: Encodable { let topic: Int, method: String, threads: [String] }

    /// The first 50 conversations each method returns per topic, for comparison with another engine.
    /// Writes Gmail thread IDs only. The file stays in the private work directory.
    func testTopLists() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let location = env["RANKED_MAIL_TOPLISTS"] else { return }
        let root = URL(fileURLWithPath: try XCTUnwrap(env["RANKED_MAIL_FIXTURE"]))
        let rules = LiveFilterParser.compile(
            try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["TREC_MAIL_RULES"]))))
        let topics = try JSONDecoder().decode(
            [Topic].self, from: Data(contentsOf: root.appendingPathComponent("tasks.json")))
        let stores = try await openFixture(root)
        let accounts = try await stores.index.read { Set(try String.fetchAll($0, sql: "SELECT email FROM account")) }
        let index = MailRankedIndex(stores)
        try await index.synchronize()
        let deps = MailGmailSearch.Dependencies(
            api: MailGmailSearchTests.Gmail(), token: { _ in throw GmailError.networkDisabled },
            store: { _, _ in XCTFail("unexpected network write") }, accounts: { [] }, changed: {})
        let methods = [
            ("chronological", MailGmailSearch(stores: stores, dependencies: deps)),
            ("ranked", MailGmailSearch(stores: stores, ranked: index, dependencies: deps)),
        ]
        var lists: [TopList] = []
        for (slot, topic) in topics.enumerated() {
            for (name, service) in methods {
                let scope = MailScope(
                    place: .search(LiveFilterParser.parse(topic.query, scope: "mail", rules: rules).searchExpression))
                let page = try await service.snapshot(
                    scope, limit: 50, fresh: true, allowedAccounts: accounts, through: 0
                ) { MailRowMapper.row($0, labels: [], reason: nil, in: scope) }
                lists.append(TopList(topic: slot, method: name, threads: page.rows.map(\.id.thread)))
                service.keep([])
            }
        }
        try JSONEncoder().encode(lists).write(to: URL(fileURLWithPath: location))
    }

    /// Run in its own process against the already-built disposable Beta export.
    func testReopenAndOneMessageChange() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let location = env["RANKED_MAIL_MAINTENANCE"] else { return }
        let root = URL(fileURLWithPath: try XCTUnwrap(env["RANKED_MAIL_FIXTURE"]))
        let stores = try await openFixture(root)
        let record = try await stores.index.read { db -> (Int64, Int64, String?, String) in
            let row = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT m.msg_pk,t.thread_pk,m.snippet,a.email FROM message m
                        JOIN thread t ON t.thread_pk=m.thread_pk JOIN account a ON a.account_pk=t.account_pk
                        WHERE t.last_date>0 ORDER BY m.msg_pk LIMIT 1
                        """))
            return (row[0], row[1], row[2], row[3])
        }
        let index = MailRankedIndex(stores)
        let start = ProcessInfo.processInfo.systemUptime
        try await index.synchronize()
        let reopen = ProcessInfo.processInfo.systemUptime - start
        let topics = try JSONDecoder().decode(
            [Topic].self, from: Data(contentsOf: root.appendingPathComponent("tasks.json")))
        let question = try XCTUnwrap(topics.first { $0.family == "known" })
        let accounts = try await stores.index.read { Set(try String.fetchAll($0, sql: "SELECT email FROM account")) }
        let rules = LiveFilterParser.compile(
            try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["TREC_MAIL_RULES"]))))
        let service = MailGmailSearch(
            stores: stores, ranked: index,
            dependencies: .init(
                api: MailGmailSearchTests.Gmail(), token: { _ in throw GmailError.networkDisabled },
                store: { _, _ in XCTFail("unexpected network write") }, accounts: { [] }, changed: {}))
        let lookup = ProcessInfo.processInfo.systemUptime
        let scope = MailScope(
            place: .search(LiveFilterParser.parse(question.query, scope: "mail", rules: rules).searchExpression))
        _ = try await service.snapshot(scope, limit: 5, fresh: true, allowedAccounts: accounts, through: 0) {
            MailRowMapper.row($0, labels: [], reason: nil, in: scope)
        }
        let firstLookup = ProcessInfo.processInfo.systemUptime - lookup
        let probe = "rankedmailfixturemarker"
        try await stores.index.write { db in
            try db.execute(sql: "UPDATE message SET snippet=? WHERE msg_pk=?", arguments: [probe, record.0])
        }
        let pending = try await index.top(probe, allowed: [record.3])
        XCTAssertNil(pending)
        let changed = ProcessInfo.processInfo.systemUptime
        try await index.synchronize()
        let elapsed = ProcessInfo.processInfo.systemUptime - changed
        let hit = try await index.top(probe, allowed: [record.3])
        XCTAssertEqual(hit?.map(\.threadPK), [record.1])
        try await stores.index.write { db in
            try db.execute(sql: "UPDATE message SET snippet=? WHERE msg_pk=?", arguments: [record.2, record.0])
        }
        try await index.synchronize()
        let cleared = try await index.top(probe, allowed: [record.3])
        XCTAssertEqual(cleared?.count, 0)
        try JSONEncoder().encode([
            "reopenMS": reopen * 1000, "oneMessageReplaceMS": elapsed * 1000, "firstShellLookupMS": firstLookup * 1000,
        ])
        .write(to: URL(fileURLWithPath: location))
    }
}
