import Foundation
import Combine
import GRDB
import Darwin
import XCTest

/// Replays the two read-only operations the live source calls for an on-device message.
@MainActor private final class DiskReaderSource: MailSource {
    let stores: MailStores
    var callback: ((MailConversation?) -> Void)?
    var reads = 0

    init(_ stores: MailStores) { self.stores = stores }

    func observeConversation(_ id: MailConversationID, _ change: @escaping @MainActor (MailConversation?) -> Void) -> MailObservation {
        callback = change
        return MailObservation {}
    }
    func body(_ id: MailMessageID) async -> MailBody {
        reads += 1
        do {
            return try await MailBlobStore(stores: stores).prepared(account: id.account, messageID: id.message)?.body ?? .notOnDevice
        } catch {
            XCTFail("Fixture body lookup failed: \(error)")
            return .notOnDevice
        }
    }
}

private let account = "reader@plan.example"
private struct ReaderWorkload {
    let name: String
    let count: Int
    let blocks: Int
    var thread: MailConversationID { .init(account: account, thread: name) }
    func message(_ index: Int) -> String { "\(name)-\(index)" }
    var newest: MailMessageID { .init(account: account, message: message(count - 1)) }
}

private let workloads = [
    ReaderWorkload(name: "single", count: 1, blocks: 2),
    ReaderWorkload(name: "small-thread", count: 12, blocks: 2),
    ReaderWorkload(name: "long-thread", count: 64, blocks: 14),
    ReaderWorkload(name: "large-html", count: 1, blocks: 1200)
]

private func seed(_ stores: MailStores) async throws {
    let blobs = MailBlobStore(stores: stores)
    var rowID: Int64 = 0
    for workload in workloads {
        for messageIndex in 0..<workload.count {
            let html = "<html><body>" + (0..<workload.blocks).map { section in
                "<p>Message \(messageIndex), section \(section). <strong>Project update</strong> " +
                String(repeating: "The group reviewed the weekly calendar and travel arrangements. ", count: 2) +
                "<a href='https://plan.example/details'>Review details</a>.</p>"
            }.joined() + "</body></html>"
            let data = Data(html.utf8)
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let payload = GmailPart(partId: "0", mimeType: "text/html", headers: [
                GmailHeader(name: "From", value: "Sender <sender@plan.example>"),
                GmailHeader(name: "To", value: account),
                GmailHeader(name: "Subject", value: "Team update")
            ], body: GmailPartBody(size: data.count, data: encoded))
            let wire = GmailMessage(id: workload.message(messageIndex), threadId: workload.name, labelIds: ["INBOX"], snippet: "Project update",
                historyId: 1, internalDate: Int64(1000 + messageIndex), sizeEstimate: data.count, payload: payload)
            let extraction = MIMEStructure.extract(payload)
            _ = try await stores.index.write { db in
                try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: payload),
                    structure: extraction.structure), account: account, myAddresses: [account], in: db)
            }
            rowID += 1
            try await blobs.put(wire, account: account, extraction: extraction, ftsRowID: rowID, at: 1)
            let prepared = try await blobs.prepare(account: account, messageID: workload.message(messageIndex), at: 2)
            XCTAssertNotNil(prepared)
        }
    }
}

@MainActor private func measureOpen(_ stores: MailStores, _ workload: ReaderWorkload, _ trial: Int, _ mode: String) async throws -> [String: Any] {
    let source = DiskReaderSource(stores)
    let start = ProcessInfo.processInfo.systemUptime
    func ms() -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    let reader = MailReaderModel(id: workload.thread, source: source)
    var firstMS: Double?
    var firstReads: Int?
    var publications = 0
    let observation = reader.$bodies.dropFirst().sink { value in
        publications += 1
        guard firstMS == nil, let body = value[workload.newest], case .text = body else { return }
        XCTAssertFalse(reader.styled[workload.newest]?.isEmpty ?? true)
        firstMS = ms()
        firstReads = source.reads
    }
    let headers = try await MailConversationReader(stores: stores).conversation(workload.thread)
    let diskHeadersMS = ms()
    XCTAssertEqual(headers?.messages.count, workload.count)
    source.callback?(headers)
    let modelHeadersMS = ms()
    await reader.waitForBodies()
    let completeMS = ms()
    XCTAssertEqual(reader.messages.first?.id, workload.newest)
    XCTAssertEqual(reader.bodies.count, workload.count)
    XCTAssertEqual(source.reads, workload.count)
    XCTAssertEqual(reader.styled.count, workload.count)
    for index in 0..<workload.count {
        let id = MailMessageID(account: account, message: workload.message(index))
        let text = try XCTUnwrap(reader.styled[id]?.first ?? nil)
        XCTAssertTrue(String(text.characters).contains("Message \(index), section 0."))
    }
    var changed = try XCTUnwrap(headers)
    let firstMessage = try XCTUnwrap(changed.messages.indices.first)
    changed.messages[firstMessage].isUnread.toggle()
    let reset = ms()
    source.callback?(changed)
    await reader.waitForBodies()
    let warmRefresh = ms() - reset
    XCTAssertEqual(source.reads, workload.count)
    XCTAssertEqual(reader.styled.count, workload.count)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let report: [String: Any] = [
        "mode": mode, "workload": workload.name, "trial": trial,
        "messages": workload.count, "bodyReads": source.reads, "firstReads": try XCTUnwrap(firstReads), "bodyPublications": publications,
        "diskHeadersMS": diskHeadersMS, "modelHeadersMS": modelHeadersMS, "firstBodyMS": try XCTUnwrap(firstMS),
        "allBodiesMS": completeMS, "warmHeaderChangeMS": warmRefresh, "processPeakBytes": usage.ru_maxrss
    ]
    withExtendedLifetime(observation) {}
    return report
}

/// Disk read, projection and delivery to the reader model. This does not drive the screen.
@MainActor final class MailReaderOpenCostTests: XCTestCase {
    func testPreparedBodyOpensOnDiskAndAfterEviction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-open-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func open() async throws -> MailStores {
            try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        }
        try await seed(open())
        let stores = try await open()
        var samples: [[String: Any]] = []
        for trial in 0..<7 {
            for workload in workloads {
                let mode = trial == 0 ? "first-open" : "new-reader-warm-database"
                samples.append(try await measureOpen(stores, workload, trial, mode))
            }
        }

        let workload = try XCTUnwrap(workloads.first { $0.name == "large-html" })
        try await stores.blobs.write { db in
            try db.execute(sql: "DELETE FROM prepared WHERE account=? AND gmail_id=?",
                           arguments: [account, workload.newest.message])
        }
        let blobs = MailBlobStore(stores: stores)
        let missing = try await blobs.prepared(account: account, messageID: workload.newest.message)
        XCTAssertNil(missing)
        let start = ProcessInfo.processInfo.systemUptime
        let rebuilt = try await blobs.prepare(account: account, messageID: workload.newest.message, at: 3)
        let rebuildMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertNotNil(rebuilt)
        samples.append(try await measureOpen(stores, workload, 0, "after-reprepare"))
        let data = try JSONSerialization.data(withJSONObject: ["samples": samples, "reprepareMS": rebuildMS],
                                              options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "mail-reader-open"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
