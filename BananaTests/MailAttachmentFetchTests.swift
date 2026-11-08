import XCTest
import GRDB
import Combine

@MainActor final class MailAttachmentFetchTests: XCTestCase {
    private final class Access: MailAccountAccess {
        var connectedAccountIDs = ["a@example.com"]
        var grant = MailGrant.granted
        func mailGrant(accountID: String) -> MailGrant { grant }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken {
            guard grant == .granted else { throw MailAccessError.notGranted }
            return MailAccessToken(value: "fixture", scopes: [MailScopes.gmailModify])
        }
        func dropMailAccessToken(accountID: String) {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome { grant = .granted; return .granted }
        func forgetMailAccess(accountID: String) async throws { grant = .none }
        func cancelMailTokenRequests() {}
    }

    actor Provider: GmailAPI {
        var message: GmailMessage
        var bytes: [String: Data]
        var refused: Set<String> = []
        var failuresLeft = 0
        var delay: UInt64 = 0
        var attachmentCalls: [String] = []
        var messageReads = 0
        init(message: GmailMessage, bytes: [String: Data]) { self.message = message; self.bytes = bytes }
        func refuse(_ id: String) { refused.insert(id) }
        func replace(_ message: GmailMessage) { self.message = message }
        func fail(times: Int) { failuresLeft = times }
        func slow(_ nanoseconds: UInt64) { delay = nanoseconds }
        func profile(token: String) async throws -> GmailProfile { throw GmailError.networkDisabled }
        func labels(token: String) async throws -> [GmailLabel] { [] }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { throw GmailError.networkDisabled }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.networkDisabled }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage { messageReads += 1; return message }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.networkDisabled }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody {
            attachmentCalls.append(attachmentID)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if failuresLeft > 0 { failuresLeft -= 1; throw GmailError.networkDisabled }
            guard !refused.contains(attachmentID), let data = bytes[attachmentID] else { throw GmailError.notFound }
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return GmailPartBody(size: data.count, data: encoded)
        }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { throw GmailError.malformed }
        func trash(token: String, id: String) async throws { throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { throw GmailError.malformed }
    }

    private let account = "a@example.com"
    private let docx = Data((0..<4_000).map { UInt8($0 % 251) })

    private func wire(name: String = "Report.docx", mime: String = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                      size: Int, attachmentID: String) -> GmailMessage {
        let json = """
        {"id":"m1","threadId":"t1","historyId":"100","internalDate":"1000","labelIds":["INBOX"],"payload":{"partId":"0","mimeType":"multipart/mixed",
        "headers":[{"name":"From","value":"Sender <sender@example.com>"},{"name":"Subject","value":"Report"},{"name":"To","value":"a@example.com"}],"parts":[
        {"partId":"1","mimeType":"text/plain","body":{"data":"SGVsbG8"}},
        {"partId":"2","mimeType":"\(mime)","filename":"\(name)","body":{"attachmentId":"\(attachmentID)","size":\(size)}}]}}
        """
        return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    private func setup(_ api: Provider) async throws -> (MailStores, MailLiveSource, MailAttachmentFetcher) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-attach-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let message = await api.message
        let fetched = FetchedMessage(wire: message, floor: 100, headers: MessageHeaders(payload: message.payload), structure: nil)
        _ = try await MailWriter(stores: stores, sink: nil).transact { db in
            try MailMessageImporter.apply(fetched, account: "a@example.com", myAddresses: ["a@example.com"], in: db)
        }
        try await MailBlobStore(stores: stores).put(message, account: account, extraction: MIMEStructure.extract(try XCTUnwrap(message.payload)), ftsRowID: 1, at: 1_000)
        let source = MailLiveSource(stores: stores, access: Access(), api: api)
        let fetcher = MailAttachmentFetcher(pictures: MailInlinePictures(stores: stores, api: api, token: { _ in "fixture" }))
        return (stores, source, fetcher)
    }

    private let id = MailAttachmentID(message: MailMessageID(account: "a@example.com", message: "m1"), part: "2")

    /// Waits until the attachment's progress reaches a finished state, and returns every state it passed through.
    private func finish(_ progress: MailProgress, timeout: TimeInterval = 10) async -> [MailProgress.State] {
        var seen: [MailProgress.State] = [progress.state]
        let done = expectation(description: "attachment finished")
        done.assertForOverFulfill = false
        let watch = progress.$state.sink { state in
            if seen.last != state { seen.append(state) }
            if state == .done { done.fulfill() }
            if case .failed = state { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: timeout)
        watch.cancel()
        return seen
    }

    func testFetchStoresTheFileUnderItsNameAndRecordsIt() async throws {
        let api = Provider(message: wire(size: docx.count, attachmentID: "att1"), bytes: ["att1": docx])
        let (stores, _, fetcher) = try await setup(api)
        let url = try await fetcher.file(for: id)
        XCTAssertEqual(try Data(contentsOf: url), docx)
        XCTAssertEqual(url.lastPathComponent, "Report.docx", "the system viewer decides by the extension")
        XCTAssertTrue(url.path.hasPrefix(stores.directories.attachments.path))
        let row = try await stores.blobs.read { try Row.fetchOne($0, sql: "SELECT state, inline, bytes, filename, path FROM attachment WHERE gmail_id='m1' AND part_id='2'") }
        XCTAssertEqual(row?["state"] as Int?, 1)
        XCTAssertEqual(row?["inline"] as Int?, 0)
        XCTAssertEqual(row?["bytes"] as Int?, docx.count)
        XCTAssertEqual(row?["filename"] as String?, "Report.docx")
        XCTAssertTrue(MailInlinePictures.isSafe(try XCTUnwrap(row?["path"] as String?)))
    }

    func testProgressGoesFromQueuedThroughDownloadingToDoneAndTheConversationSaysWhereTheFileIs() async throws {
        let api = Provider(message: wire(size: docx.count, attachmentID: "att1"), bytes: ["att1": docx])
        let (stores, source, _) = try await setup(api)
        let progress = source.attachmentProgress(id)
        XCTAssertTrue(progress === source.attachmentProgress(id), "one progress object for one attachment")
        XCTAssertEqual(progress.state, .idle)
        source.fetchAttachment(id)
        XCTAssertEqual(progress.state, .queued)
        let states = await finish(progress)
        XCTAssertEqual(states.first, .queued)
        XCTAssertTrue(states.contains(.downloading))
        XCTAssertEqual(states.last, .done)
        XCTAssertEqual(progress.fraction, 1)
        let conversation = try await MailConversationReader(stores: stores).conversation(MailConversationID(account: account, thread: "t1"))
        let attachment = try XCTUnwrap(conversation?.messages.first?.attachments.first)
        XCTAssertEqual(attachment.localFile?.lastPathComponent, "Report.docx")
    }

    func testSecondFetchIsServedFromDiskWithoutTheMailbox() async throws {
        let api = Provider(message: wire(size: docx.count, attachmentID: "att1"), bytes: ["att1": docx])
        let (_, _, fetcher) = try await setup(api)
        let first = try await fetcher.file(for: id)
        let second = try await fetcher.file(for: id)
        XCTAssertEqual(first, second)
        let calls = await api.attachmentCalls
        XCTAssertEqual(calls, ["att1"])
    }

    func testStaleAttachmentIDIsReplacedByReadingTheMessageAgain() async throws {
        let api = Provider(message: wire(size: docx.count, attachmentID: "old"), bytes: ["old": docx, "new": docx])
        let (_, _, fetcher) = try await setup(api)
        await api.refuse("old")
        await api.replace(wire(size: docx.count, attachmentID: "new"))
        let url = try await fetcher.file(for: id)
        XCTAssertEqual(try Data(contentsOf: url), docx)
        let calls = await api.attachmentCalls
        XCTAssertEqual(calls, ["old", "new"])
        let reads = await api.messageReads
        XCTAssertEqual(reads, 1)
    }

    func testProgramsAndOversizedFilesAreRefusedBeforeAnyDownload() async throws {
        let program = Provider(message: wire(name: "setup.pkg", mime: "application/octet-stream", size: 100, attachmentID: "att1"), bytes: ["att1": docx])
        let (_, _, programFetcher) = try await setup(program)
        do { _ = try await programFetcher.file(for: id); XCTFail("a program is never fetched") }
        catch { XCTAssertEqual(error as? MailAttachmentFetcher.Failure, .notAllowed) }
        let programCalls = await program.attachmentCalls
        XCTAssertEqual(programCalls, [])

        let big = Provider(message: wire(size: MailAttachmentFetcher.maximumBytes + 1, attachmentID: "att1"), bytes: ["att1": docx])
        let (_, _, bigFetcher) = try await setup(big)
        do { _ = try await bigFetcher.file(for: id); XCTFail("26 MB is over the limit") }
        catch { XCTAssertEqual(error as? MailAttachmentFetcher.Failure, .tooLarge) }
        let bigCalls = await big.attachmentCalls
        XCTAssertEqual(bigCalls, [])

        let allowed = Provider(message: wire(size: MailAttachmentFetcher.maximumBytes, attachmentID: "att1"), bytes: ["att1": docx])
        let (_, _, allowedFetcher) = try await setup(allowed)
        let ok = try await allowedFetcher.file(for: id)
        XCTAssertEqual(ok.lastPathComponent, "Report.docx", "25 MB is allowed")
    }

    func testUnknownPartIsMissing() async throws {
        let api = Provider(message: wire(size: 10, attachmentID: "att1"), bytes: [:])
        let (_, _, fetcher) = try await setup(api)
        do { _ = try await fetcher.file(for: MailAttachmentID(message: id.message, part: "9")); XCTFail() }
        catch { XCTAssertEqual(error as? MailAttachmentFetcher.Failure, .missing) }
    }

    func testFailureThenRetrySucceeds() async throws {
        let api = Provider(message: wire(size: docx.count, attachmentID: "att1"), bytes: ["att1": docx])
        let (_, source, _) = try await setup(api)
        await api.fail(times: 2)   // the stored id, and the fresh one after the re-read
        let progress = source.attachmentProgress(id)
        source.fetchAttachment(id)
        let first = await finish(progress)
        XCTAssertEqual(first.last, .failed(.unavailable))
        source.fetchAttachment(id)
        XCTAssertEqual(progress.state, .queued, "a retry starts over")
        let second = await finish(progress)
        XCTAssertEqual(second.last, .done)
    }

    func testNoAnswerWithinTheDeadlineIsAFailureNotASpinner() async throws {
        let api = Provider(message: wire(size: docx.count, attachmentID: "att1"), bytes: ["att1": docx])
        let (_, _, fetcher) = try await setup(api)
        await api.slow(5_000_000_000)
        let start = Date()
        do { _ = try await fetcher.file(for: id, deadline: 0.3); XCTFail("must time out") }
        catch { XCTAssertEqual(error as? MailAttachmentFetcher.Failure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testATappedAttachmentDoesNotWaitForTheBodyQueue() async throws {
        // The body queue only runs on an active source, two at a time, and not during a read backoff. This source
        // is not active, so nothing queued would ever run; the attachment still arrives.
        let api = Provider(message: wire(size: docx.count, attachmentID: "att1"), bytes: ["att1": docx])
        let (_, source, _) = try await setup(api)
        source.fetchBody(MailMessageID(account: account, message: "m1"))
        source.fetchBody(MailMessageID(account: account, message: "m2"))
        source.fetchBody(MailMessageID(account: account, message: "m3"))
        let progress = source.attachmentProgress(id)
        source.fetchAttachment(id)
        let states = await finish(progress, timeout: 5)
        XCTAssertEqual(states.last, .done)
        let reads = await api.messageReads
        XCTAssertEqual(reads, 0, "no body was read: only the attachment ran")
    }

    func testWithoutAccessItFailsAtOnce() async throws {
        let api = Provider(message: wire(size: docx.count, attachmentID: "att1"), bytes: ["att1": docx])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-attach-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let access = Access(); access.grant = .none
        let source = MailLiveSource(stores: stores, access: access, api: api)
        source.fetchAttachment(id)
        XCTAssertEqual(source.attachmentProgress(id).state, .failed(.unavailable))
    }
}
