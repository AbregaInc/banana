import XCTest

/// Rules about how a message body and its attachments are handled, checked by reading the files
/// themselves (as `MailSourceTreeTests` does for the tree): the compiler enforces none of them.
///
/// - **No HTML is made or read by the system's text conversion.** `NSAttributedString` converts
///   HTML by running WebKit on the main thread and writes pages of inline style; the one place HTML
///   is written is `MailBodyHTML`, by hand.
/// - **An attachment is opened only through Quick Look**: no mail code opens a file URL in another
///   app (MAIL-UX 6.2.9; the security review's P-8).
/// - **A file's name is the engine's safe one**: nothing in the composer's or the reader's code builds
///   a path from a string a sender wrote.
///
/// Like the other source readers these skip where the checkout is not on the machine.
final class MailBodyRulesTests: XCTestCase {

    private func repositoryRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.appendingPathComponent("Banana/Model/Mail/MailContract.swift").path),
                          "the source tree is not on this machine")
        return root
    }

    /// Every Swift file under mail's UI folders, with its text.
    private func mailUISources() throws -> [(name: String, text: String)] {
        let root = try repositoryRoot()
        var found: [(String, String)] = []
        for folder in ["Banana/Model/MailUI", "Banana/Views/Mail", "Banana/Model/Mail"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        XCTAssertGreaterThan(found.count, 50)
        return found
    }

    /// The text without comments, so that a rule written down in one is not what it forbids.
    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testNothingInMailConvertsHTMLThroughTheSystemsTextConversion() throws {
        let forbidden = [".documentType", "NSAttributedString.DocumentType", "NSHTMLTextDocumentType",
                         "NSAttributedString(data:", "NSAttributedString(html", "AttributedString(markdown",
                         "AttributedString(html"]
        for (name, text) in try mailUISources() {
            let body = code(text)
            for call in forbidden {
                XCTAssertFalse(body.contains(call), "\(name) uses \(call)")
            }
        }
    }

    func testNothingInMailOpensAFileInAnotherApp() throws {
        let forbidden = ["NSWorkspace.shared.open", "NSWorkspace.shared.openFile", "NSWorkspace.shared.activateFileViewer",
                         "UIApplication.shared.open", "UIDocumentInteractionController", "openURL", "openInPlace"]
        for (name, text) in try mailUISources() {
            let body = code(text)
            for call in forbidden {
                XCTAssertFalse(body.contains(call), "\(name) uses \(call)")
            }
        }
    }

    func testTheAttachmentCodeBuildsNoPathFromAStringASenderWrote() throws {
        // Where a file name is joined to a folder, it has been through `MailFileName`.
        let root = try repositoryRoot()
        for file in ["Banana/Model/MailUI/Pure/Testing/MailSampleFiles.swift", "Banana/Model/MailUI/Pure/MailIntake.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("MailFileName.safe("), file)
            let joins = code(text).split(separator: "\n").filter { $0.contains("appendingPathComponent(") }
            XCTAssertFalse(joins.isEmpty, file)
            // A folder of ours, a fresh id, this launch's id, or the safe name; never a bare string.
            let allowed = ["UUID().uuidString", "launchID", "\"BananaMail", "\"draft-\"", "\"message-\"",
                           "MailFileName.safe(", "(name)"]
            for line in joins {
                XCTAssertTrue(allowed.contains { line.contains($0) }, "\(file): \(line)")
            }
        }
    }

    func testTheEditorIsTheSystemsAndNoTextViewIsWrappedByHand() throws {
        let root = try repositoryRoot()
        let area = try String(contentsOf: root.appendingPathComponent("Banana/Views/Mail/MailComposerBodyArea.swift"), encoding: .utf8)
        // The system's editor over the model's text: through a binding that writes only a change.
        XCTAssertTrue(area.contains("TextEditor(text: text, selection:"))
        XCTAssertTrue(area.contains("Binding(get: { model.rich }, set: { new in if new != model.rich { model.rich = new } })"))
        // The composer's own files: the list hosts wrap a table by hand, and rightly.
        let composer: Set<String> = ["MailComposerView.swift", "MailComposerBodyArea.swift", "MailBodyFormatting.swift",
                                     "MailAttachmentChips.swift", "MailAttachmentIntake.swift", "MailComposerTools.swift"]
        let sources = try mailUISources().filter { composer.contains($0.name) }
        XCTAssertEqual(sources.count, composer.count)
        for (name, text) in sources {
            let body = code(text)
            XCTAssertFalse(body.contains("UIViewRepresentable") || body.contains("NSViewRepresentable")
                           || body.contains("UITextView") || body.contains("NSTextView"), name)
        }
    }
}
