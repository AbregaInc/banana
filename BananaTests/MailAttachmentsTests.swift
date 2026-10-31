#if DEBUG || MAIL_FIXTURES
import XCTest
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Files on a message: what the system says an attachment is; the chips and the size limit;
/// adding and taking off, with Undo; a forward that carries the original's files and a reply that
/// does not; the sample mailbox's stand-in files being the type they claim; and opening a received
/// one. The source keeps files in a folder of its own, written by the engine's door, never under the
/// app's data and swept by the next launch.
@MainActor
final class MailAttachmentsTests: XCTestCase {

    private let account = MailFixtureConversations.account

    private func id(_ key: String) -> MailConversationID {
        MailConversationID(account: account, thread: key)
    }

    /// A session on its own source with the toasts recorded; its timers never fire.
    @MainActor
    private final class Harness {
        var source = MailFixtureSource()
        var toasts: [MailToast] = []
        var toastUndo: (@MainActor () -> Void)?
        var session: MailSession!

        init() {
            session = MailSession(
                source: source, now: source.now, deviceName: "Mac",
                timers: MailTimers { _, _ in { } },
                present: { [unowned self] toast, undo in
                    self.toasts.append(toast)
                    self.toastUndo = undo
                })
            session.enter()
        }

        func compose(_ start: MailComposeStart = .new) async -> MailComposerModel {
            session.begin(start, requestFocus: false)
            let composer = session.composer!
            await composer.waitForDraft()
            return composer
        }
    }

    /// A file of his own, in the temporary directory.
    private func file(_ name: String, bytes: Int = 2_000) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MailAttachmentsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    /// A file that says it is this big and holds nothing.
    private func sparse(_ name: String, megabytes: Int) throws -> URL {
        let url = try file(name, bytes: 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(megabytes) * 1_000_000)
        try handle.close()
        return url
    }

    private func inside(_ url: URL, _ folder: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    // MARK: What the system says an attachment is

    func testTheSymbolAndTheWordsComeFromTheSystemsTypes() {
        func kind(_ name: String, _ mime: String) -> MailAttachmentKind { .of(name: name, mimeType: mime) }
        XCTAssertEqual(kind("a.pdf", "application/pdf").symbol, "doc.richtext")
        XCTAssertEqual(kind("a.png", "image/png").symbol, "photo")
        XCTAssertEqual(kind("a.jpg", "image/jpeg").symbol, "photo")
        XCTAssertEqual(kind("a.csv", "text/csv").symbol, "tablecells")
        XCTAssertEqual(kind("a.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet").symbol, "tablecells")
        XCTAssertEqual(kind("a.zip", "application/zip").symbol, "doc.zipper")
        XCTAssertEqual(kind("a.txt", "text/plain").symbol, "doc.text")
        XCTAssertEqual(kind("a.mov", "video/quicktime").symbol, "film")
        XCTAssertEqual(kind("a.m4a", "audio/mp4").symbol, "waveform")
        XCTAssertEqual(kind("a.unknownthing", "application/octet-stream").symbol, "doc")
        XCTAssertEqual(kind("a.pdf", "application/pdf").label, "PDF document")
        XCTAssertFalse(kind("a.png", "image/png").label.isEmpty)
        XCTAssertFalse(kind("a.pdf", "application/pdf").isProgram)
    }

    func testAGenericTypeFallsBackToTheNamesAndNothingElseGuessesAtTheBytes() {
        XCTAssertEqual(MailAttachmentKind.of(name: "scan.pdf", mimeType: "application/octet-stream").type, .pdf)
        XCTAssertEqual(MailAttachmentKind.of(name: "scan.pdf", mimeType: "").type, .pdf)
        XCTAssertNil(MailAttachmentKind.of(name: "noextension", mimeType: "").type)
        XCTAssertEqual(MailAttachmentKind.of(name: "noextension", mimeType: "").symbol, "doc")
        XCTAssertEqual(MailAttachmentKind.of(name: "noextension", mimeType: "").label, "File")
    }

    func testAProgramIsKnownByItsTypeAndByItsName() {
        for name in ["setup.pkg", "run.command", "tool.sh", "App.app", "disk.dmg"] {
            XCTAssertTrue(MailAttachmentKind.of(name: name, mimeType: "application/octet-stream").isProgram, name)
        }
        // Named as a document and being a program, or named as a program and being a document.
        XCTAssertTrue(MailAttachmentKind.of(name: "setup.pkg", mimeType: "application/pdf").isProgram)
        XCTAssertEqual(MailAttachmentKind.of(name: "setup.pkg", mimeType: "").symbol, "exclamationmark.triangle")
    }

    func testAFileWhoseNameAndTypeDisagreeIsShownWithItsRealType() {
        let kind = MailAttachmentKind.of(name: "invoice.pdf", mimeType: "image/png", typeMismatch: true)
        XCTAssertEqual(kind.type, .png, "what the bytes are")
        XCTAssertEqual(kind.symbol, "photo")
        XCTAssertNotNil(kind.nameSays)
        XCTAssertTrue(kind.nameSays?.contains("PDF") == true, kind.nameSays ?? "")

        // The engine need not have said so: a name of one kind and a type of another is enough.
        XCTAssertNotNil(MailAttachmentKind.of(name: "report.pdf", mimeType: "image/png").nameSays)
        // A name and a type that agree say nothing, nor does a more general one that holds the other.
        XCTAssertNil(MailAttachmentKind.of(name: "a.pdf", mimeType: "application/pdf").nameSays)
        XCTAssertNil(MailAttachmentKind.of(name: "a.csv", mimeType: "text/plain").nameSays)
        XCTAssertNil(MailAttachmentKind.of(name: "a.png", mimeType: "application/octet-stream").nameSays)
    }

    func testTheReadersChipSaysWhatTheBytesAreAndThatTheNameSaysOtherwise() {
        let attachment = MailAttachment(
            id: MailAttachmentID(message: MailMessageID(account: account, message: "m"), part: "0"),
            name: "invoice\u{202E}fdp.exe", mimeType: "image/png", typeMismatch: true, bytes: 52_000,
            localFile: nil, isInline: false, isExecutable: false)
        let display = MailAttachmentDisplay(attachment)
        XCTAssertEqual(display.name, "invoicefdp.exe", "the name is made safe once more before it is shown")
        XCTAssertFalse(display.name.contains("\u{202E}"))

        let lie = MailAttachment(
            id: attachment.id, name: "invoice.pdf", mimeType: "image/png", typeMismatch: true, bytes: 52_000,
            localFile: nil, isInline: false, isExecutable: false)
        let shown = MailAttachmentDisplay(lie)
        XCTAssertEqual(shown.symbol, "photo")
        XCTAssertTrue(shown.kindText.lowercased().contains("png"), shown.kindText)
        XCTAssertEqual(shown.note, "Its name says PDF document.")
        XCTAssertFalse(shown.isProgram)

        var program = lie
        program.isExecutable = true
        let flagged = MailAttachmentDisplay(program)
        XCTAssertTrue(flagged.isProgram)
        XCTAssertEqual(flagged.note, MailAttachmentText.program)
        XCTAssertEqual(flagged.symbol, "exclamationmark.triangle")
    }

    // MARK: How big

    func testWhatAFileWeighsEncodedAndWhatGmailTakes() {
        XCTAssertEqual(MailAttachmentSize.encoded(0), 0)
        XCTAssertEqual(MailAttachmentSize.encoded(57), 76 + 2, "57 bytes are one line of 76 characters and its break")
        XCTAssertEqual(MailAttachmentSize.encoded(1), 4 + 2)
        XCTAssertFalse(MailAttachmentSize.isOver([25_000_000]), "about 25 MB of attachments is under the limit")
        XCTAssertTrue(MailAttachmentSize.isOver([28_000_000]))
        XCTAssertTrue(MailAttachmentSize.isOver([14_000_000, 14_000_000]), "the sum is what counts")
        XCTAssertGreaterThan(MailAttachmentSize.encoded(25_000_000), 25_000_000)
        XCTAssertLessThan(MailAttachmentSize.encoded(25_000_000), MailTuning.maxEncodedBytes)
    }

    func testTheWordsAboutTheLimitSpeakOfAttachmentsAndNotOfEncoding() {
        XCTAssertEqual(MailAttachmentText.limitWords, "about 25 MB of attachments")
        XCTAssertEqual(MailAttachmentText.overTheLimit(bytes: 31_000_000), "31 MB \u{00B7} Gmail takes about 25 MB of attachments")
        XCTAssertEqual(MailAttachmentText.notAdded("movie.mov", bytes: 80_000_000),
                       "\u{201C}movie.mov\u{201D} (80 MB) wasn\u{2019}t added. Gmail takes about 25 MB of attachments.")
        XCTAssertEqual(MailAttachmentText.tooLargeToSend.text,
                       "Too large for Gmail, which takes about 25 MB of attachments. Remove one to send.")
        XCTAssertNil(MailAttachmentText.tooLargeToSend.action)
        XCTAssertEqual(MailAttachmentText.summary(count: 1, bytes: 2_400_000), "1 attachment \u{00B7} 2.4 MB")
        XCTAssertEqual(MailAttachmentText.summary(count: 3, bytes: 2_400_000), "3 attachments \u{00B7} 2.4 MB")
        XCTAssertEqual(MailAttachmentText.removed("a.pdf").text, "Removed \u{201C}a.pdf\u{201D}")
        XCTAssertEqual(MailAttachmentText.removed("a.pdf").action, .undo)
    }

    // MARK: Adding

    func testAFileAddedIsAChipWithItsNameAndSizeAndIsKeptInTheSourcesOwnFolder() async throws {
        let h = Harness()
        let composer = await h.compose()
        let url = try file("agenda.txt", bytes: 3_000)
        composer.files.add([url])
        XCTAssertEqual(composer.files.pending.map(\.name), ["agenda.txt"], "the name is there at once")
        await composer.files.settle()

        XCTAssertEqual(composer.files.pending, [])
        XCTAssertEqual(composer.files.items.map(\.name), ["agenda.txt"])
        XCTAssertEqual(composer.files.items.map(\.bytes), [3_000])
        let shown = try XCTUnwrap(composer.files.shown.first)
        XCTAssertEqual(shown.symbol, "doc.text")
        XCTAssertEqual(shown.sizeText, MailAttachmentSize.text(3_000))
        XCTAssertNil(composer.files.notice)

        let kept = try XCTUnwrap(composer.files.items[0].file)
        XCTAssertNotEqual(kept, url, "a copy, never his own file")
        XCTAssertEqual(try Data(contentsOf: kept), try Data(contentsOf: url))
        XCTAssertTrue(inside(kept, MailSampleFiles.launchFolder), kept.path)
        XCTAssertTrue(inside(kept, FileManager.default.temporaryDirectory), "not under the app's data directory")
        XCTAssertFalse(kept.path.contains("Application Support") || kept.path.contains("/Documents/"))

        let draft = try XCTUnwrap(h.source.drafts[composer.draftID!])
        XCTAssertEqual(draft.attachments.map(\.name), ["agenda.txt"], "the source has it")
        XCTAssertEqual(draft.encodedBytes, MailAttachmentSize.encoded(3_000))
    }

    func testSeveralFilesAreAddedInTheOrderTheyCame() async throws {
        let h = Harness()
        let composer = await h.compose()
        composer.files.add([try file("one.txt"), try file("two.pdf"), try file("three.png")])
        await composer.files.settle()
        XCTAssertEqual(composer.files.items.map(\.name), ["one.txt", "two.pdf", "three.png"])
        XCTAssertEqual(composer.files.shown.map(\.symbol), ["doc.text", "doc.richtext", "photo"])
        XCTAssertEqual(composer.files.summary, MailAttachmentText.summary(count: 3, bytes: composer.files.bytes))
    }

    func testAFileIsKeptUnderItsSafeNameAndNeverOutsideItsFolder() async throws {
        let h = Harness()
        let composer = await h.compose()
        let url = try file("invoice\u{202E}fdp.exe")
        composer.files.add([url])
        await composer.files.settle()
        let item = try XCTUnwrap(composer.files.items.first)
        XCTAssertEqual(item.name, "invoicefdp.exe")
        XCTAssertEqual(try XCTUnwrap(item.file).lastPathComponent, "invoicefdp.exe")
        XCTAssertTrue(inside(try XCTUnwrap(item.file), MailSampleFiles.launchFolder))
    }

    func testAFolderOrAFileThatIsGoneIsNotAddedAndTheNoticeSaysSo() async throws {
        let h = Harness()
        let composer = await h.compose()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MailAttachmentsTests-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        composer.files.add([folder])
        await composer.files.settle()
        XCTAssertEqual(composer.files.items, [])
        XCTAssertEqual(composer.files.notice, MailAttachmentText.couldNotAttach(folder.lastPathComponent))
        composer.files.add([FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).pdf")])
        await composer.files.settle()
        XCTAssertNotNil(composer.files.notice)
        XCTAssertEqual(composer.files.pending, [], "and no chip is left waiting")
    }

    // MARK: The limit

    func testAFileThatWouldTakeTheMessageOverIsNotAddedAndTheNoticeSaysWhy() async throws {
        let h = Harness()
        let composer = await h.compose()
        composer.files.add([try file("small.pdf", bytes: 10_000), try sparse("recording.mov", megabytes: 30)])
        await composer.files.settle()
        XCTAssertEqual(composer.files.items.map(\.name), ["small.pdf"])
        XCTAssertEqual(composer.files.notice, MailAttachmentText.notAdded("recording.mov", bytes: 30_000_000))
        XCTAssertTrue(composer.files.notice?.contains("about 25 MB of attachments") == true)
        XCTAssertFalse(composer.files.isOver)
        let folder = MailSampleFiles.folder(forDraft: composer.draftID!)
        let kept = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertFalse(kept.contains { $0.hasSuffix("recording.mov") }, "the big file was not copied for nothing")

        // The next change clears the notice.
        composer.files.add([try file("next.txt")])
        await composer.files.settle()
        XCTAssertNil(composer.files.notice)
    }

    func testTwoFilesThatAreEachUnderButTogetherOverAreRefusedAtTheSecond() async throws {
        let h = Harness()
        let composer = await h.compose()
        composer.files.add([try sparse("first.mov", megabytes: 15), try sparse("second.mov", megabytes: 15)])
        await composer.files.settle()
        XCTAssertEqual(composer.files.items.map(\.name), ["first.mov"])
        XCTAssertNotNil(composer.files.notice)
    }

    func testAForwardCanArriveOverTheLimitAndSendingSaysSoAndNothingIsLost() async throws {
        let h = Harness()
        let composer = await h.compose(.forward(id("attachments")))
        composer.accept(MailFixtureConversations.sam)
        XCTAssertTrue(composer.files.items.contains { $0.bytes == 48_000_000 }, "brand-assets.zip")
        XCTAssertTrue(composer.files.isOver)
        XCTAssertEqual(composer.files.summary, MailAttachmentText.overTheLimit(bytes: composer.files.bytes))
        XCTAssertEqual(composer.sendProblem(), .attachmentsTooLarge)

        h.session.sendComposer()
        XCTAssertNotNil(h.session.composer, "the message is not sent and not lost")
        XCTAssertEqual(h.toasts.last, MailAttachmentText.tooLargeToSend)

        // Taking the big one off is what lets it go.
        let zip = try XCTUnwrap(composer.files.items.first { $0.name == "brand-assets.zip" })
        h.session.removeAttachment(zip.id, from: composer)
        XCTAssertFalse(composer.files.isOver)
        XCTAssertNil(composer.sendProblem())
        h.session.sendComposer()
        XCTAssertNil(h.session.composer, "now it is sent")
    }

    // MARK: A forward carries the files; a reply does not

    func testAForwardCarriesTheOriginalsFilesAsTheyWereSentAndAReplyCarriesNone() async throws {
        let h = Harness()
        let forward = await h.compose(.forward(id("attachments")))
        XCTAssertEqual(forward.files.items.map(\.name), ["Services-agreement-signed.pdf", "logo-mark.png", "brand-assets.zip"])
        XCTAssertEqual(forward.files.items.map(\.bytes), [2_400_000, 800_000, 48_000_000], "at the size they were sent")
        for item in forward.files.items {
            let kept = try XCTUnwrap(item.file, item.name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), item.name)
        }
        XCTAssertEqual(forward.files.shown.map(\.symbol), ["doc.richtext", "photo", "doc.zipper"])
        h.session.closeComposer()

        let reply = await h.compose(.reply(id("attachments")))
        XCTAssertEqual(reply.files.items, [])
        let replyAll = await h.compose(.replyAll(id("attachments")))
        XCTAssertEqual(replyAll.files.items, [])
    }

    func testAForwardOfAMessageWithNoFilesCarriesNone() async {
        let h = Harness()
        let composer = await h.compose(.forward(id("receipt")))
        XCTAssertEqual(composer.files.items, [])
    }

    func testAForwardsOwnFilesAreNotSomethingHeTypedSoItIsDroppedWhenLeftAlone() async throws {
        let h = Harness()
        let composer = await h.compose(.forward(id("attachments-many")))
        XCTAssertEqual(composer.files.items.count, 12)
        XCTAssertFalse(composer.hasContent)
        XCTAssertEqual(composer.close(), .dropped)
    }

    func testTakingOffOrAddingAFileIsSomethingHeDidAndTheDraftIsKept() async throws {
        let h = Harness()
        let composer = await h.compose(.forward(id("attachments-many")))
        let first = try XCTUnwrap(composer.files.items.first)
        h.session.removeAttachment(first.id, from: composer)
        XCTAssertTrue(composer.hasContent)
        let id = try XCTUnwrap(composer.draftID)
        guard case .kept = composer.close() else { return XCTFail("kept") }
        let saved = try XCTUnwrap(h.source.drafts[id])
        XCTAssertEqual(saved.attachments.count, 11, "the draft has what was left")
        XCTAssertFalse(saved.attachments.map(\.name).contains("receipt-1.pdf"))
    }

    func testANewMessageWithOnlyAFileIsKept() async throws {
        let h = Harness()
        let composer = await h.compose()
        XCTAssertFalse(composer.hasContent)
        composer.files.add([try file("only.pdf")])
        await composer.files.settle()
        XCTAssertTrue(composer.hasContent)
        guard case .kept(let draft) = composer.close() else { return XCTFail("kept") }
        XCTAssertEqual(h.source.drafts[draft]?.attachments.map(\.name), ["only.pdf"])
    }

    // MARK: Taking off, with Undo

    func testTakingAFileOffShowsAtOnceAndUndoPutsItBackWhereItWasAsItWas() async throws {
        let h = Harness()
        let composer = await h.compose()
        composer.files.add([try file("a.txt", bytes: 100), try file("b.txt", bytes: 200), try file("c.txt", bytes: 300)])
        await composer.files.settle()
        let middle = try XCTUnwrap(composer.files.items.first { $0.name == "b.txt" })

        h.session.removeAttachment(middle.id, from: composer)
        XCTAssertEqual(composer.files.items.map(\.name), ["a.txt", "c.txt"], "gone in the same turn")
        XCTAssertEqual(h.toasts.last, MailAttachmentText.removed("b.txt"))
        XCTAssertEqual(h.source.drafts[composer.draftID!]?.attachments.map(\.name), ["a.txt", "c.txt"])

        h.toastUndo?()
        for _ in 0..<50 where composer.files.items.count < 3 { await Task.yield() }
        XCTAssertEqual(composer.files.items.map(\.name), ["a.txt", "b.txt", "c.txt"], "back where it was")
        XCTAssertEqual(composer.files.items[1].bytes, 200)
        XCTAssertEqual(composer.files.items[1].id, middle.id, "the same one")
        XCTAssertEqual(h.source.drafts[composer.draftID!]?.attachments.count, 3)
    }

    func testUndoingTheRemovalOfAForwardedFileKeepsTheSizeItWasSentAt() async throws {
        let h = Harness()
        let composer = await h.compose(.forward(id("attachments")))
        let zip = try XCTUnwrap(composer.files.items.first { $0.name == "brand-assets.zip" })
        h.session.removeAttachment(zip.id, from: composer)
        XCTAssertFalse(composer.files.isOver)
        h.toastUndo?()
        for _ in 0..<50 where composer.files.items.count < 3 { await Task.yield() }
        XCTAssertEqual(composer.files.items.last?.bytes, 48_000_000)
        XCTAssertTrue(composer.files.isOver, "it is as it was, over what Gmail takes")
    }

    // MARK: Looking

    func testAFileOnTheDraftIsOpenedForALookAndAProgramIsNot() async throws {
        let h = Harness()
        let composer = await h.compose()
        composer.files.add([try file("notes.txt"), try file("setup.pkg")])
        await composer.files.settle()
        let notes = try XCTUnwrap(composer.files.items.first { $0.name == "notes.txt" })
        let program = try XCTUnwrap(composer.files.items.first { $0.name == "setup.pkg" })
        composer.files.look(at: program.id)
        XCTAssertNil(composer.files.preview, "never a program")
        composer.files.look(at: notes.id)
        XCTAssertEqual(composer.files.preview, notes.file)
    }

    // MARK: The way in

    func testAFileTheSystemLendsIsCopiedIntoTheIntakeFolderAndClearedAwayOnceTheSourceHasIt() async throws {
        let h = Harness()
        let composer = await h.compose()
        let lent = try file("photo.png", bytes: 4_000)
        let kept = try await XCTUnwrapAsync(await MailIntake.keep(lent))
        XCTAssertTrue(MailIntake.isKept(kept))
        XCTAssertTrue(inside(kept, FileManager.default.temporaryDirectory))
        XCTAssertEqual(try Data(contentsOf: kept), try Data(contentsOf: lent))
        XCTAssertFalse(MailIntake.isKept(lent), "his own file is never cleared away")

        composer.files.add([kept])
        await composer.files.settle()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: kept.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(composer.files.items.map(\.name), ["photo.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path), "cleared once the source had its own")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lent.path))
    }

    func testTheFormatObjectRefusesALinkUnlessWordsAreSelectedInTheBody() {
        let format = MailComposerFormat()
        XCTAssertFalse(format.requestLink())
        format.bodyFocused = true
        XCTAssertFalse(format.requestLink(), "nothing selected: the key is the command menu's")
        format.hasSelection = true
        XCTAssertTrue(format.requestLink())
        XCTAssertEqual(format.linkRequest, 1)
        format.bodyFocused = false
        XCTAssertFalse(format.requestLink(), "another field has the caret")
    }

    // MARK: Sending

    func testASentMessageCarriesItsFilesAndTheyOpen() async throws {
        let h = Harness()
        let composer = await h.compose()
        composer.accept(MailFixtureConversations.sam)
        composer.subject = "Files"
        composer.body = "Attached."
        composer.files.add([try file("agenda.pdf", bytes: 5_000)])
        await composer.files.settle()
        h.session.sendComposer()
        XCTAssertNil(h.session.composer)

        let sent = try await sentMessage(h)
        XCTAssertEqual(sent.attachments.map(\.name), ["agenda.pdf"])
        XCTAssertEqual(sent.attachments.map(\.bytes), [5_000])
        XCTAssertEqual(sent.attachments.map(\.mimeType), ["application/pdf"])
        let local = try XCTUnwrap(sent.attachments[0].localFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path), "it is here, so it opens")
        let display = MailMessageDisplay(sent)
        XCTAssertEqual(display.files.map(\.name), ["agenda.pdf"])
        XCTAssertEqual(display.files.first?.localFile, local)
        XCTAssertEqual(display.attachments.count, 1, "and the plain list the tests read is still there")
    }

    private func sentMessage(_ h: Harness) async throws -> MailMessage {
        let sentID = try XCTUnwrap(h.source.sentParts.keys.first)
        let thread = MailConversationID(account: sentID.account, thread: String(sentID.message.prefix { $0 != "~" }))
        let conversation = await h.source.conversation(thread)
        return try XCTUnwrap(conversation?.messages.first { $0.id == sentID })
    }

    func testASentMessageIsMadeBothAsHTMLAndAsPlainTextAndShowsItsFormattingInTheConversation() async throws {
        let h = Harness()
        let composer = await h.compose(.reply(id("q3")))
        var text = AttributedString("Thanks ")
        var bold = AttributedString("everyone"); bold.font = .body.bold(); text += bold
        var link = AttributedString(" report"); link.link = URL(string: "https://example.com/r"); text += link
        text += AttributedString("\n\n- one\n- two\n1. first")
        composer.rich = text
        let signature = composer.currentDraft()?.signature
        let quote = try XCTUnwrap(composer.quote, "a reply carries the original")
        h.session.sendComposer()

        let sent = try await sentMessage(h)
        let parts = try XCTUnwrap(h.source.sentParts[sent.id])
        let words = "<p>Thanks <b>everyone</b><a href=\"https://example.com/r\"> report</a></p>"
            + "<ul><li>one</li><li>two</li></ul><ol><li>first</li></ol>"
        // His words, then his signature, then the original: each as its own part, as it came.
        XCTAssertEqual(parts.html, words + (signature?.fragment.html ?? "") + quote.fragment.html)
        XCTAssertTrue(parts.html.hasPrefix(words), "his words are not merged with the rest")
        let plainWords = "Thanks everyone report (https://example.com/r)\n\n- one\n- two\n1. first"
        XCTAssertTrue(parts.plain.hasPrefix(plainWords), parts.plain)
        if signature != nil { XCTAssertTrue(parts.plain.contains("\n\n-- \n"), parts.plain) }
        XCTAssertTrue(parts.plain.contains("> "), "the original, as quoted lines: \(parts.plain)")
        XCTAssertEqual(MailBodyHTML.plain(from: text), plainWords)

        let body = await h.source.body(sent.id)
        guard case .text(let shown, _, _) = body else { return XCTFail("a text body: \(body)") }
        XCTAssertEqual(shown.blocks.map(\.kind), [
            .paragraph, .paragraph, .item(ordered: false, depth: 0, number: nil), .item(ordered: false, depth: 0, number: nil),
            .item(ordered: true, depth: 0, number: 1)])
        XCTAssertEqual(shown.blocks[0].runs.map(\.style), [[], .bold, []], "the conversation draws it bold")
        let drawn = MailAttributedText.make(shown.blocks[0].runs)
        XCTAssertTrue(drawn.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testADraftWithNoFormattingIsStillPlainAndSendsAsPlainParagraphs() async throws {
        let h = Harness()
        let composer = await h.compose(.reply(id("q3")))
        composer.body = "Hello there\nsecond line\n\nnew paragraph"
        let draft = try XCTUnwrap(composer.currentDraft())
        XCTAssertEqual(draft.body.blocks.map(\.kind), [.paragraph, .paragraph, .paragraph, .paragraph])
        XCTAssertEqual(draft.body.blocks.flatMap(\.runs).map(\.style), [[], [], []])
        XCTAssertEqual(MailBodyHTML.html(draft.body), "<p>Hello there<br>second line</p><p>new paragraph</p>")
        XCTAssertEqual(MailBodyHTML.plain(draft.body), "Hello there\nsecond line\n\nnew paragraph")
    }

    // MARK: Keeping and reopening formatted text

    func testFormattedTextIsKeptAsHeTypesItAndReopensAsHeLeftIt() async throws {
        let h = Harness()
        let composer = await h.compose(.reply(id("q3")))
        var text = AttributedString("Hello ")
        var bold = AttributedString("bold"); bold.font = .body.bold(); text += bold
        text += AttributedString("\n- one\n- two")
        composer.rich = text
        composer.flush()

        let id = try XCTUnwrap(composer.draftID)
        let saved = try XCTUnwrap(h.source.drafts[id])
        XCTAssertEqual(saved.body.blocks.map(\.kind), [.paragraph, .item(ordered: false, depth: 0, number: nil),
                                                      .item(ordered: false, depth: 0, number: nil)])
        XCTAssertEqual(saved.body.blocks[0].runs.map(\.style), [[], .bold], "the draft keeps the bold")

        guard case .kept = composer.close() else { return XCTFail("kept") }
        h.session.begin(.continuing(id), requestFocus: false)
        let again = try XCTUnwrap(h.session.composer)
        await again.waitForDraft()
        XCTAssertEqual(String(again.rich.characters), "Hello bold\n\u{2022} one\n\u{2022} two")
        XCTAssertEqual(MailRichText.text(again.rich), saved.body, "as he left it")
    }

    func testTheTypedAheadKeysKeepTheFormattingAlreadyThere() async throws {
        let h = Harness()
        let composer = await h.compose(.reply(id("q3")))
        var bold = AttributedString("Bold "); bold.font = .body.bold()
        composer.rich = bold
        composer.typeAhead("more")
        composer.focusLanded(on: .body)
        XCTAssertEqual(composer.body, "Bold more")
        XCTAssertEqual(MailRichText.text(composer.rich).blocks[0].runs.first?.style, .bold)
    }

    // MARK: The sample files are the type they claim

    private func entries(ofZip data: Data) throws -> [(name: String, data: Data, crc: UInt32)] {
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        let end = data.count - 22
        XCTAssertEqual(u32(end), 0x06054b50, "the last record")
        let count = u16(end + 10)
        var at = Int(u32(end + 16))
        var found: [(String, Data, UInt32)] = []
        for _ in 0..<count {
            XCTAssertEqual(u32(at), 0x02014b50)
            let crc = u32(at + 16), size = Int(u32(at + 24)), nameLength = u16(at + 28)
            let offset = Int(u32(at + 42))
            let name = String(decoding: data[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            XCTAssertEqual(u32(offset), 0x04034b50)
            let start = offset + 30 + u16(offset + 26) + u16(offset + 28)
            found.append((name, data.subdata(in: start..<(start + size)), crc))
            at += 46 + nameLength
        }
        return found
    }

    func testTheChecksumIsTheStandardOne() {
        XCTAssertEqual(MailSampleFiles.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(MailSampleFiles.crc32(Data()), 0)
    }

    func testAPDFStandInIsOnePageAndSaysSample() throws {
        let made = MailSampleFiles.standIn(named: "Services-agreement-signed.pdf")
        XCTAssertEqual(made.type, .pdf)
        let provider = try XCTUnwrap(CGDataProvider(data: made.data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 1)
        let pdf = try XCTUnwrap(PDFDocument(data: made.data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("SAMPLE") == true, "clearly a sample")
        XCTAssertTrue(pdf.string?.contains("Services-agreement-signed.pdf") == true)
    }

    func testPictureStandInsAreThePictureTypesTheyClaim() throws {
        for (name, type) in [("logo-mark.png", UTType.png), ("photo.jpg", .jpeg), ("photo.jpeg", .jpeg)] {
            let made = MailSampleFiles.standIn(named: name)
            XCTAssertEqual(made.type, type, name)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(made.data as CFData, nil), name)
            XCTAssertEqual(CGImageSourceGetType(source) as String?, type.identifier, name)
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 320)
            XCTAssertLessThan(made.data.count, 100_000, "small")
        }
    }

    func testTextStandInsAreTextAndSayTheyAreSamples() throws {
        let csv = MailSampleFiles.standIn(named: "dashboard-export.csv")
        XCTAssertEqual(csv.type, .commaSeparatedText)
        let rows = try XCTUnwrap(String(data: csv.data, encoding: .utf8)).split(separator: "\n")
        XCTAssertGreaterThan(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 2 })
        XCTAssertTrue(rows[1].contains("Sample"))

        let text = MailSampleFiles.standIn(named: "meeting-notes.txt")
        XCTAssertEqual(text.type, .plainText)
        let words = try XCTUnwrap(String(data: text.data, encoding: .utf8))
        XCTAssertTrue(words.hasPrefix("Sample file"))
        XCTAssertTrue(words.contains("meeting-notes.txt"))
    }

    func testTheSpreadsheetAndTheZipAreWhatTheirNamesSay() throws {
        let sheet = MailSampleFiles.standIn(named: "Q3-revenue.xlsx")
        XCTAssertEqual(sheet.type, UTType(filenameExtension: "xlsx"))
        XCTAssertTrue(sheet.type.conforms(to: .spreadsheet))
        let parts = try entries(ofZip: sheet.data)
        XCTAssertEqual(parts.map(\.name), ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
                                           "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"])
        for part in parts {
            XCTAssertEqual(MailSampleFiles.crc32(part.data), part.crc, part.name)
            let parser = XMLParser(data: part.data)
            XCTAssertTrue(parser.parse(), "\(part.name): \(parser.parserError?.localizedDescription ?? "")")
        }
        XCTAssertTrue(String(decoding: try XCTUnwrap(parts.last).data, as: UTF8.self).contains("Sample"))

        let zip = MailSampleFiles.standIn(named: "brand-assets.zip")
        XCTAssertEqual(zip.type, .zip)
        let inside = try entries(ofZip: zip.data)
        XCTAssertEqual(inside.map(\.name), ["README.txt"])
        XCTAssertTrue(String(decoding: inside[0].data, as: UTF8.self).hasPrefix("Sample file"))
    }

    func testEverySampleAttachmentHasAStandInOfTheTypeItsNameClaims() {
        for sample in MailFixtureConversations.threads() {
            for message in sample.messages {
                for file in message.files where message.actually[file.name] == nil {
                    let made = MailSampleFiles.standIn(named: file.name)
                    let claimed = MailAttachmentKind.type(ofName: file.name)
                    XCTAssertNotNil(claimed, file.name)
                    XCTAssertTrue(claimed.map { made.type.conforms(to: $0) } ?? false, "\(file.name): \(made.type)")
                }
            }
        }
    }

    func testAFileThatIsNotWhatItsNameSaysIsMadeOfWhatItIsAndShownThatWay() async throws {
        let sample = MailFixtureConversations.threads().first { $0.key == "attachments" }
        let message = try XCTUnwrap(sample?.messages.first { $0.files.contains { $0.name == "invoice-2026.pdf" } })
        XCTAssertEqual(message.actually["invoice-2026.pdf"], "png")

        let built = MailFixtureSource.build(try XCTUnwrap(sample))
        let attachment = try XCTUnwrap(built.stored.conversation.messages.flatMap(\.attachments)
            .first { $0.name == "invoice-2026.pdf" })
        XCTAssertEqual(attachment.mimeType, "image/png", "what the bytes are")
        XCTAssertTrue(attachment.typeMismatch)
        let display = MailAttachmentDisplay(attachment)
        XCTAssertEqual(display.symbol, "photo")
        XCTAssertEqual(display.note, "Its name says PDF document.")

        let made = MailSampleFiles.standIn(named: "invoice-2026.pdf", actually: "png")
        XCTAssertEqual(made.type, .png)
        XCTAssertNotNil(CGImageSourceCreateWithData(made.data as CFData, nil))
        XCTAssertNil(PDFDocument(data: made.data), "not a PDF")
        let url = try await XCTUnwrapAsync(await MailSampleFiles.stage(
            made.data, named: "invoice-2026.pdf", type: made.type, in: MailSampleFiles.launchFolder, from: nil))
        XCTAssertEqual(url.lastPathComponent, "invoice-2026.png", "Quick Look opens what the bytes are")
    }

    // MARK: Received files

    func testAReceivedFileIsMadeWhenItIsAskedForAndOpensAfterThat() async throws {
        let source = MailFixtureSource()
        let found = await source.conversation(id("attachments"))
        let conversation = try XCTUnwrap(found)
        let pdf = try XCTUnwrap(conversation.messages.flatMap(\.attachments).first { $0.name == "Services-agreement-signed.pdf" })
        XCTAssertNil(pdf.localFile, "the sample conversations list files with no bytes")

        let reader = MailReaderModel(id: id("attachments"), source: source)
        let display = try XCTUnwrap(reader.messages.flatMap(\.files).first { $0.id == pdf.id })
        XCTAssertNil(display.localFile)
        reader.opener.open(display)
        XCTAssertEqual(reader.opener.waiting, pdf.id)
        XCTAssertNil(reader.opener.preview, "not yet")

        for _ in 0..<200 where reader.opener.preview == nil { try await Task.sleep(for: .milliseconds(20)) }
        let url = try XCTUnwrap(reader.opener.preview, "the file arrived and Quick Look is asked to show it")
        XCTAssertNil(reader.opener.waiting)
        XCTAssertEqual(url.lastPathComponent, "Services-agreement-signed.pdf")
        XCTAssertTrue(inside(url, MailSampleFiles.launchFolder))
        XCTAssertNotNil(PDFDocument(url: url), "a real PDF")
        let now = try XCTUnwrap(reader.messages.flatMap(\.files).first { $0.id == pdf.id })
        XCTAssertEqual(now.localFile, url, "and the chip knows it is here")

        // Here already: Quick Look at once, and nothing is asked for.
        reader.opener.preview = nil
        reader.opener.open(now)
        XCTAssertEqual(reader.opener.preview, url)
        XCTAssertNil(reader.opener.waiting)
    }

    func testAProgramIsNeverOpenedAndNothingIsAskedForItsBytes() async throws {
        let source = MailFixtureSource()
        let opener = MailAttachmentOpener(source: source)
        let id = MailAttachmentID(message: MailMessageID(account: account, message: "q3~1"), part: "0")
        let program = MailAttachmentDisplay(MailAttachment(
            id: id, name: "setup.pkg", mimeType: "application/octet-stream", typeMismatch: false, bytes: 1_000,
            localFile: URL(fileURLWithPath: "/tmp/setup.pkg"), isInline: false, isExecutable: false))
        XCTAssertTrue(program.isProgram)
        opener.open(program)
        XCTAssertNil(opener.preview, "not even a file that is here")
        XCTAssertNil(opener.waiting)
        XCTAssertEqual(opener.notice, "\u{201C}setup.pkg\u{201D} \u{2014} " + MailAttachmentText.program)
    }

    func testAReceivedFileIsWrittenUnderASafeNameInsideItsFolder() async throws {
        let made = MailSampleFiles.standIn(named: "x.txt")
        let url = try await XCTUnwrapAsync(await MailSampleFiles.stage(
            made.data, named: "../../evil\u{202E}/..name.txt", type: made.type,
            in: MailSampleFiles.folder(forMessage: MailMessageID(account: account, message: "m~1")), from: "a@b.example"))
        XCTAssertTrue(inside(url, MailSampleFiles.launchFolder), url.path)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.hasPrefix("."))
        XCTAssertFalse(url.lastPathComponent.contains("\u{202E}"))
        XCTAssertEqual(url.lastPathComponent, "evil..name.txt", "the engine's rule: no separators, no leading dots, no overrides")
    }

    // MARK: Where files live

    func testTheNextLaunchSweepsWhatTheLastLeftAndKeepsItsOwn() async throws {
        let old = MailSampleFiles.root.appendingPathComponent("an-earlier-launch/draft-1", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent("left.pdf"))
        let own = MailSampleFiles.launchFolder.appendingPathComponent("draft-2", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: own.appendingPathComponent("mine.pdf"))

        await MailSampleFiles.sweepPreviousLaunches()
        XCTAssertFalse(FileManager.default.fileExists(atPath: MailSampleFiles.root.appendingPathComponent("an-earlier-launch").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.appendingPathComponent("mine.pdf").path))
        XCTAssertTrue(inside(MailSampleFiles.launchFolder, FileManager.default.temporaryDirectory))
        XCTAssertNotEqual(MailSampleFiles.launchID, "")
    }

    func testTheTemporaryNamesOfAWriteInProgressAreNotLeftBehind() async throws {
        let h = Harness()
        let composer = await h.compose()
        composer.files.add([try file("done.txt")])
        await composer.files.settle()
        let folder = MailSampleFiles.folder(forDraft: composer.draftID!)
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertFalse(names.contains { MailFiles.isTemporaryName(($0 as NSString).lastPathComponent) }, "\(names)")
    }

    // MARK: Typing still changes nothing outside the composer

    func testAddingAFileChangesNothingTheListThePaneOrTheConversationReads() async throws {
        let h = Harness()
        let composer = await h.compose(.reply(id("q3")))
        var publications = 0
        let watching = [h.session.feed.objectWillChange.sink { publications += 1 },
                        h.session.pane.objectWillChange.sink { publications += 1 },
                        h.session.navigation.objectWillChange.sink { publications += 1 }]
        var own = 0
        let files = composer.files.objectWillChange.sink { own += 1 }
        composer.files.add([try file("quiet.txt")])
        await composer.files.settle()
        XCTAssertEqual(publications, 0)
        XCTAssertGreaterThan(own, 0, "the chips are what changed")
        withExtendedLifetime((watching, files)) {}
    }

    // MARK: Helpers

    private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                                   line: UInt = #line) async throws -> T {
        let found = try await value()
        return try XCTUnwrap(found, file: file, line: line)
    }
}
#endif
