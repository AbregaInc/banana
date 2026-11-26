import Foundation
import XCTest

/// Opt-in public corpus replay. Opens only a disposable projection built by trec_corpus.py.
final class TRECMailTests: XCTestCase {
    private struct Topic: Decodable {
        let id, split, query, target: String
    }

    private struct Sample: Encodable {
        let topic, split: String
        let limit, trial, rank: Int
        let elapsedMS: Double
        let hasMore, canRun: Bool
        let fields: [String]
    }

    func testHumanQueriesThroughNativeMail() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try XCTUnwrap(env["TREC_MAIL_FIXTURE"]))
        let ruleURL = URL(fileURLWithPath: try XCTUnwrap(env["TREC_MAIL_RULES"]))
        let output = URL(fileURLWithPath: try XCTUnwrap(env["TREC_MAIL_RESULTS"]))
        let rules = LiveFilterParser.compile(try Data(contentsOf: ruleURL))
        let topics = try JSONDecoder().decode([Topic].self, from: Data(contentsOf: root.appendingPathComponent("tasks.json")))
        XCTAssertEqual(topics.count, 150)
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailMigrations()) }.value
        var samples = [Sample]()
        for trial in 0..<3 {
            for slot in topics.indices {
                let topic = topics[(slot * 37 + trial * 53) % topics.count]
                for limit in (slot + trial).isMultiple(of: 2) ? [5, 50] : [50, 5] {
                    let start = ProcessInfo.processInfo.systemUptime
                    let parsed = LiveFilterParser.parse(topic.query, scope: "mail", rules: rules)
                    let query = MailLocalSearchQuery(text: parsed.searchExpression, account: nil, limit: limit)
                    let page = try await MailLocalSearch.rows(query, stores: stores)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    let rank = page.rows.firstIndex { $0.thread == topic.target }.map { $0 + 1 } ?? 0
                    samples.append(Sample(topic: topic.id, split: topic.split, limit: limit, trial: trial, rank: rank,
                                          elapsedMS: elapsed, hasMore: page.more, canRun: parsed.canRun,
                                          fields: parsed.terms.map(\.field)))
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(samples).write(to: output, options: .withoutOverwriting)
    }
}
