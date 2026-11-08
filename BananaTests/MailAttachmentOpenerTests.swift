import XCTest

@MainActor final class MailAttachmentOpenerTests: XCTestCase {
    /// A source that is asked for an attachment and says what the test tells it to.
    private final class Source: MailSource {
        enum Behaviour { case silent, fails, arrives }
        var behaviour = Behaviour.silent
        var asked: [MailAttachmentID] = []
        let progress = MailProgress()
        func attachmentProgress(_ id: MailAttachmentID) -> MailProgress { progress }
        func fetchAttachment(_ id: MailAttachmentID) {
            asked.append(id)
            progress.state = .queued
            if behaviour == .fails { progress.state = .failed(.unavailable) }
        }
    }

    private let id = MailAttachmentID(message: MailMessageID(account: "a@example.com", message: "m1"), part: "2")
    private func display(file: URL? = nil) -> MailAttachmentDisplay {
        MailAttachmentDisplay(MailAttachment(id: id, name: "Report.docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                             typeMismatch: false, bytes: 82_000, localFile: file, isInline: false, isExecutable: false))
    }

    func testAFailedFetchStopsTheSpinnerAndOffersARetry() async throws {
        let source = Source(); source.behaviour = .fails
        let opener = MailAttachmentOpener(source: source)
        opener.open(display())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(opener.waiting)
        XCTAssertTrue(opener.failed.contains(id))
        opener.open(display())
        XCTAssertEqual(source.asked, [id, id], "tapping a failed one asks again")
        XCTAssertFalse(opener.failed.contains(id), "and clears the failure while it tries")
    }

    func testASourceThatNeverAnswersEndsInAFailureAfterTheTimeout() async throws {
        let opener = MailAttachmentOpener(source: Source(), timeout: .milliseconds(150))
        opener.open(display())
        XCTAssertEqual(opener.waiting, id)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(opener.waiting, "it never spins for ever")
        XCTAssertTrue(opener.failed.contains(id))
    }

    func testTheFileArrivingOpensItAndClearsTheTimeout() async throws {
        let opener = MailAttachmentOpener(source: Source(), timeout: .milliseconds(150))
        let url = URL(fileURLWithPath: "/tmp/Report.docx")
        let found = await MailFixtureSource().conversation(MailConversationID(account: MailFixtureConversations.account, thread: "attachments"))
        var message = try XCTUnwrap(found?.messages.first { !$0.attachments.isEmpty })
        message.attachments[0].localFile = url
        let asked = MailAttachmentDisplay(message.attachments[0])
        opener.open(MailAttachmentDisplay(MailAttachment(id: asked.id, name: asked.name, mimeType: "application/pdf", typeMismatch: false, bytes: 1,
                                                         localFile: nil, isInline: false, isExecutable: false)))
        opener.update([MailMessageDisplay(message)])
        XCTAssertEqual(opener.preview, url)
        XCTAssertNil(opener.waiting)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(opener.failed.isEmpty, "the timeout was cancelled")
    }

    func testAFileThatIsHereOpensWithoutAskingAnyone() {
        let source = Source()
        let opener = MailAttachmentOpener(source: source)
        let url = URL(fileURLWithPath: "/tmp/Report.docx")
        opener.open(display(file: url))
        XCTAssertEqual(opener.preview, url)
        XCTAssertEqual(source.asked, [])
    }
}
