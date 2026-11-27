import Foundation
import Combine
import GRDB
import Darwin

/// Replays the two read-only operations the live source calls for an on-device message.
@MainActor final class DiskReaderSource: MailSource {
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
        do { return try await MailBlobStore(stores: stores).prepared(account: id.account, messageID: id.message)?.body ?? .notOnDevice }
        catch { fatalError("Fixture body lookup failed: \(error)") }
    }
}

private let account = "reader@plan.example"
struct Workload {
    let name: String
    let count: Int
    let blocks: Int
    var thread: MailConversationID { .init(account: account, thread: name) }
    func message(_ index: Int) -> String { "\(name)-\(index)" }
    var newest: MailMessageID { .init(account: account, message: message(count-1)) }
}
let workloads = [Workload(name: "single", count: 1, blocks: 2),
                 Workload(name: "small-thread", count: 12, blocks: 2),
                 Workload(name: "long-thread", count: 64, blocks: 14),
                 Workload(name: "large-html", count: 1, blocks: 1200),
                 Workload(name: "mixed-pictures", count: 12, blocks: 24),
                 Workload(name: "image-heavy", count: 12, blocks: 24)]
func seed(_ stores: MailStores) async throws {
    let blobs = MailBlobStore(stores: stores)
    var rowID: Int64 = 0
    for w in workloads {
        for i in 0..<w.count {
            let html = "<html><body>" + (0..<w.blocks).map { j in
                if w.name == "image-heavy" || (w.name == "mixed-pictures" && j.isMultiple(of: 4)) {
                    return "<p><img src='cid:part-\(j)' width='240' height='180' alt='Planning diagram \(j)'></p>"
                }
                return "<p>Message \(i), section \(j). <strong>Project update</strong> " +
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
            let wire = GmailMessage(id: w.message(i), threadId: w.name, labelIds: ["INBOX"], snippet: "Project update",
                historyId: 1, internalDate: Int64(1000 + i), sizeEstimate: data.count, payload: payload)
            let extraction = MIMEStructure.extract(payload)
            _ = try await stores.index.write { db in
                try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: payload),
                    structure: extraction.structure), account: account, myAddresses: [account], in: db)
            }
            rowID += 1
            try await blobs.put(wire, account: account, extraction: extraction, ftsRowID: rowID, at: 1)
            let prepared = try await blobs.prepare(account: account, messageID: w.message(i), at: 2)
            let pictures = prepared!.text.blocks.filter { if case .picture = $0.kind { true } else { false } }
            precondition(pictures.count == (w.name == "image-heavy" ? w.blocks : w.name == "mixed-pictures" ? w.blocks / 4 : 0))

        }
    }
}

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var size = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / 4)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
        }
    }
    precondition(result == KERN_SUCCESS)
    return info.phys_footprint
}
@MainActor func measure(_ stores: MailStores, _ w: Workload, _ trial: Int, _ mode: String) async throws {
    let source = DiskReaderSource(stores)
    let start = ProcessInfo.processInfo.systemUptime
    func ms() -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    let reader = MailReaderModel(id: w.thread, source: source)
    var firstMS: Double?, firstReads: Int?, publications = 0
    let observation = reader.$bodies.dropFirst().sink { value in
        publications += 1
        guard firstMS == nil, let body = value[w.newest], case .text = body else { return }
        precondition(reader.styled[w.newest]?.isEmpty == false)
        firstMS = ms()
        firstReads = source.reads
    }
    let headers = try await MailConversationReader(stores: stores).conversation(w.thread)
    let diskHeadersMS = ms()
    precondition(headers?.messages.count == w.count)
    source.callback?(headers)
    let modelHeadersMS = ms()
    await reader.waitForBodies()
    let completeMS = ms()
    precondition(reader.messages.first?.id == w.newest)
    precondition(reader.bodies.count == w.count && source.reads == w.count)
    precondition(reader.styled.count == w.count && firstMS != nil)
    var changed = headers!
    changed.messages[0].isUnread.toggle()
    let reset = ms()
    source.callback?(changed)
    await reader.waitForBodies()
    let warmRefresh = ms() - reset
    precondition(source.reads == w.count && reader.styled.count == w.count)
    var pictures = 0, textBytes = 0
    for body in reader.bodies.values {
        guard case .text(let text, _, _) = body else { fatalError("Unexpected prepared body") }
        for block in text.blocks {
            for run in block.runs { textBytes += run.text.utf8.count }
            if case .picture(let picture) = block.kind {
                guard case .cid = picture.source else { fatalError("Unexpected picture source") }
                pictures += 1
            }
        }
    }
    let expected = w.name == "image-heavy" ? w.blocks : w.name == "mixed-pictures" ? w.blocks / 4 : 0
    precondition(pictures == w.count * expected)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let openFootprint = footprint()
    var openingPageMS = 0.0, visitAndReturnMS = 0.0, fullReadingMS = 0.0, longestBlockMS = 0.0
    var visibleSink = 0, preparedBlocks = 0
    for (id, body) in reader.bodies {
        guard case .text(let text, _, _) = body, let precomputed = reader.styled[id] else { continue }
        preparedBlocks += precomputed.compactMap { $0 }.count
        func render(_ index: Int) {
            let start = ProcessInfo.processInfo.systemUptime
            let value = precomputed[index] ?? MailAttributedText.make(text.blocks[index].runs)
            longestBlockMS = max(longestBlockMS, (ProcessInfo.processInfo.systemUptime - start) * 1000)
            visibleSink += value.runs.count
        }
        var from = ProcessInfo.processInfo.systemUptime
        for i in text.blocks.indices.prefix(16) { render(i) }
        openingPageMS += (ProcessInfo.processInfo.systemUptime - from) * 1000
        from = ProcessInfo.processInfo.systemUptime
        for page in [1,2,3,2,1,0] {
            let indices = text.blocks.indices.dropFirst(min(page * 16, text.blocks.count)).prefix(16)
            for i in indices { render(i) }
        }
        visitAndReturnMS += (ProcessInfo.processInfo.systemUptime - from) * 1000
        from = ProcessInfo.processInfo.systemUptime
        for i in text.blocks.indices { render(i) }
        fullReadingMS += (ProcessInfo.processInfo.systemUptime - from) * 1000
    }
    let report: [String: Any] = ["mode": mode, "workload":w.name, "trial":trial,
        "messages": w.count, "pictures":pictures, "textBytes":textBytes,
        "preparedBlocks":preparedBlocks, "visibleSink":visibleSink, "openingPageMS":openingPageMS, "visitAndReturnMS":visitAndReturnMS, "fullReadingMS":fullReadingMS, "longestBlockMS":longestBlockMS, "footprintBytes":openFootprint, "bodyStride":MemoryLayout<MailBody>.stride,
        "blockStride":MemoryLayout<MailTextBlock>.stride, "bodyReads": source.reads, "firstReads":firstReads!, "bodyPublications": publications,
        "diskHeadersMS": diskHeadersMS, "modelHeadersMS": modelHeadersMS, "firstBodyMS":firstMS!,
        "allBodiesMS":completeMS, "warmHeaderChangeMS":warmRefresh, "processPeakBytes":usage.ru_maxrss]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    withExtendedLifetime(observation) {}
}

@main struct ReaderBench {
    static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[2])
        func open() async throws -> MailStores {
            try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        }
        if args[1] == "seed" { try await seed(open()); return }
        if args[1] == "evict" {
            let stores = try await open()
            let w = workloads.first { $0.name == args[3] }!
            try await stores.blobs.write { db in
                try db.execute(sql: "DELETE FROM prepared WHERE account=? AND gmail_id=?", arguments: [account, w.newest.message])
            }
            let blobs = MailBlobStore(stores: stores)
            let missing = try await blobs.prepared(account: account, messageID: w.newest.message)
            precondition(missing == nil)
            let start = ProcessInfo.processInfo.systemUptime
            let rebuilt = try await blobs.prepare(account: account, messageID: w.newest.message, at: 3)
            precondition(rebuilt != nil)
            print("{\"reprepareMS\":\((ProcessInfo.processInfo.systemUptime - start) * 1000)}")
            try await measure(stores, w, 0, "after-reprepare")
            return
        }
        let stores = try await open()
        for trial in 0..<7 {
            for w in workloads where args.count < 4 || args[3] == w.name {
                try await measure(stores, w, trial, trial == 0 ? "first-open" : "new-reader-warm-database")
            }
        }
    }
}
