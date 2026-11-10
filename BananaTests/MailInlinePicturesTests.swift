import XCTest
import GRDB
import ImageIO
import UniformTypeIdentifiers

final class MailInlinePicturesTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    actor Provider: GmailAPI {
        var message: GmailMessage
        var bytes: [String: Data]
        var staleIDs: Set<String> = []
        var attachmentCalls: [String] = []
        var messageReads = 0
        init(message: GmailMessage, bytes: [String: Data]) { self.message = message; self.bytes = bytes }
        func refuse(_ id: String) { staleIDs.insert(id) }
        func replace(_ message: GmailMessage) { self.message = message }
        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: "a@example.com", messagesTotal: 1, historyId: 100) }
        func labels(token: String) async throws -> [GmailLabel] { [] }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { throw GmailError.malformed }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.malformed }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage { messageReads += 1; return message }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody {
            attachmentCalls.append(attachmentID)
            guard !staleIDs.contains(attachmentID), let data = bytes[attachmentID] else { throw GmailError.notFound }
            return GmailPartBody(size: data.count, data: MailInlinePicturesTests.base64URL(data))
        }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws { throw GmailError.malformed }
        func trash(token: String, id: String) async throws { throw GmailError.malformed }
        func untrash(token: String, id: String) async throws { throw GmailError.malformed }
    }

    private func gmailMessage(imageMime: String = "image/png", imageSize: Int, attachmentID: String) -> GmailMessage {
        let html = Self.base64URL(Data(#"<p>Hello</p><img src="cid:logo@example">"#.utf8))
        let json = """
        {"id":"m1","threadId":"t1","historyId":"100","internalDate":"1000","labelIds":["INBOX"],"payload":{"partId":"0","mimeType":"multipart/related",
        "headers":[{"name":"From","value":"sender@example.com"},{"name":"Subject","value":"S"}],"parts":[
        {"partId":"0.0","mimeType":"text/html","body":{"size":40,"data":"\(html)"}},
        {"partId":"0.1","mimeType":"\(imageMime)","filename":"logo.png","headers":[{"name":"Content-ID","value":"<logo@example>"},{"name":"Content-Disposition","value":"inline; filename=logo.png"}],
         "body":{"attachmentId":"\(attachmentID)","size":\(imageSize)}}]}}
        """
        return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    private let id = MailMessageID(account: "a@example.com", message: "m1")

    private func setup(_ api: Provider) async throws -> (MailStores, MailInlinePictures) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-inline-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stores = try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
        let message = await api.message
        let extraction = MIMEStructure.extract(try XCTUnwrap(message.payload))
        try await MailBlobStore(stores: stores).put(message, account: "a@example.com", extraction: extraction, ftsRowID: 1, at: 1_000)
        return (stores, MailInlinePictures(stores: stores, api: api, token: { _ in "fixture" }))
    }

    func testFetchesTheMessagesOwnPartOnceAndThenServesItFromDisk() async throws {
        let data = try png()
        let api = Provider(message: gmailMessage(imageSize: data.count, attachmentID: "att1"), bytes: ["att1": data])
        let (stores, pictures) = try await setup(api)
        let first = await pictures.resource(contentID: "logo@example", message: id)
        XCTAssertEqual(first?.data, data)
        XCTAssertEqual(first?.mimeType, "image/png")
        let second = await pictures.resource(contentID: "LOGO@example", message: id)
        XCTAssertEqual(second?.data, data)
        let calls = await api.attachmentCalls
        XCTAssertEqual(calls, ["att1"], "the second read must come from the attachment store")
        let row = try await stores.blobs.read { try Row.fetchOne($0, sql: "SELECT state, inline, bytes, path FROM attachment WHERE gmail_id='m1'") }
        XCTAssertEqual(row?["state"] as Int?, 1)
        XCTAssertEqual(row?["inline"] as Int?, 1)
        XCTAssertEqual(row?["bytes"] as Int?, data.count)
        let path: String = try XCTUnwrap(row?["path"])
        XCTAssertTrue(MailInlinePictures.isSafe(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stores.directories.attachments.appendingPathComponent(path).path))
    }

    func testStaleAttachmentIDIsReplacedByReadingTheMessageAgain() async throws {
        let data = try png()
        let api = Provider(message: gmailMessage(imageSize: data.count, attachmentID: "old"), bytes: ["old": data, "new": data])
        let (_, pictures) = try await setup(api)
        await api.refuse("old")
        await api.replace(gmailMessage(imageSize: data.count, attachmentID: "new"))
        let result = await pictures.resource(contentID: "logo@example", message: id)
        XCTAssertEqual(result?.data, data)
        let calls = await api.attachmentCalls
        XCTAssertEqual(calls, ["old", "new"])
        let reads = await api.messageReads
        XCTAssertEqual(reads, 1)
    }

    func testUnknownContentIDNonImageAndOversizedPartsAreNotPictures() async throws {
        let data = try png()
        let api = Provider(message: gmailMessage(imageSize: data.count, attachmentID: "att1"), bytes: ["att1": data])
        let (_, pictures) = try await setup(api)
        let unknown = await pictures.resource(contentID: "other@example", message: id)
        XCTAssertNil(unknown)

        let pdf = Provider(message: gmailMessage(imageMime: "application/pdf", imageSize: 10, attachmentID: "att1"), bytes: ["att1": data])
        let (_, pdfPictures) = try await setup(pdf)
        let notImage = await pdfPictures.resource(contentID: "logo@example", message: id)
        XCTAssertNil(notImage)

        let big = Provider(message: gmailMessage(imageSize: MailInlinePictures.maximumBytes + 1, attachmentID: "att1"), bytes: ["att1": data])
        let (_, bigPictures) = try await setup(big)
        let tooBig = await bigPictures.resource(contentID: "logo@example", message: id)
        XCTAssertNil(tooBig)
    }

    func testBytesThatAreNotAPictureAreRefused() async throws {
        let api = Provider(message: gmailMessage(imageSize: 20, attachmentID: "att1"), bytes: ["att1": Data("<svg onload=alert(1)></svg>".utf8)])
        let (_, pictures) = try await setup(api)
        let result = await pictures.resource(contentID: "logo@example", message: id)
        XCTAssertNil(result)
    }

    func testStoredPathsCannotLeaveTheAttachmentDirectory() {
        XCTAssertTrue(MailInlinePictures.isSafe("ab12/m1/inline-0-1"))
        for bad in ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a"] { XCTAssertFalse(MailInlinePictures.isSafe(bad), bad) }
    }

    func testLinkedPictureThatWillNotLoadFallsBackToItsLabel() {
        let link = URL(string: "https://example.com/go")
        func label(_ alt: String, link: URL? = link) -> String? {
            MailPicture(source: .remote(URL(string: "https://i.example.com/a.png")!), alt: alt, link: link).label
        }
        XCTAssertEqual(label("Get the app"), "Get the app")
        XCTAssertNil(label("Get the app", link: nil))
        XCTAssertNil(label(""))
        XCTAssertNil(label("Example logo"))
        XCTAssertNil(label("A very long description of what the photograph shows in detail"))
        for caption in ["Share icon", "Ann\u{2019}s profile photo", "Comment icon", "Hero image", "Profile Picture"] {
            XCTAssertNil(label(caption), caption)
        }
        XCTAssertEqual(label("Thumbs up"), "Thumbs up")
    }
}
