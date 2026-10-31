#if !BANANA_PUBLIC
import Foundation

#if DEBUG
/// More states for a screenshot, since the Simulator cannot press a key or drag a file
/// (`--mail-state <name>`, with `--mail-open <key>` for the conversation):
///
/// `format`: a reply with bold, italic, a link, bullets and a numbered list in it, and the format bar
/// showing. `attach`: a new message to Sam with a PDF, a picture and a CSV attached. `attach-over`:
/// a new message with a PDF on it and a file that would take it over what Gmail takes, refused in
/// words. `format-attach`: the formatted reply with a PDF and a picture on it, to see the whole
/// composer at once. `sent-format`: that reply, sent, so the conversation shows what it looks like. A
/// composer from a route does not ask for the caret.
extension MailSession {

    /// True if `state` was one of these.
    func applyAttachRoute(_ state: String) -> Bool {
        switch state {
        case "format", "sent-format", "format-attach":
            guard let target = model.open?.id ?? model.cursor else { return true }
            Task { @MainActor in
                await self.writeFormattedForPicture(sent: state == "sent-format", attaching: state == "format-attach",
                                                    in: target)
            }
        case "attach", "attach-over":
            Task { @MainActor in await self.writeAttachedForPicture(over: state == "attach-over") }
        default:
            return false
        }
        return true
    }

    private func writeFormattedForPicture(sent: Bool, attaching: Bool = false, in target: MailConversationID) async {
        begin(.reply(target), requestFocus: false)
        guard let composer else { return }
        await composer.waitForDraft()
        func run(_ text: String, _ style: MailTextStyle = [], link: String? = nil) -> MailTextRun {
            MailTextRun(text: text, style: style, link: link.flatMap { URL(string: $0) })
        }
        func line(_ runs: MailTextRun...) -> MailTextBlock { MailTextBlock(kind: .paragraph, runs: runs) }
        func item(_ text: String, ordered: Bool = false, number: Int? = nil) -> MailTextBlock {
            MailTextBlock(kind: .item(ordered: ordered, depth: 0, number: number), runs: [run(text)])
        }
        composer.rich = MailRichText.attributed(MailText(blocks: [
            line(run("Thanks, "), run("everyone", .bold), run(". The draft is "), run("nearly", .italic),
                 run(" there; the "), run("revised numbers", link: "https://example.com/q3"), run(" are in.")),
            line(),
            line(run("Before Thursday:")),
            item("Check the churn assumptions"),
            item("Confirm the EMEA refund line"),
            line(),
            line(run("Then, in order:")),
            item("Send it to Northwind", ordered: true, number: 1),
            item("Mark the thread Done", ordered: true, number: 2),
        ]))
        if attaching {
            var urls: [URL] = []
            for name in ["agreement.pdf", "logo-mark.png"] {
                let made = MailSampleFiles.standIn(named: name)
                if let url = await MailSampleFiles.stage(made.data, named: name, type: made.type,
                                                         in: MailIntake.folder, from: nil) {
                    urls.append(url)
                }
            }
            composer.files.add(urls)
            await composer.files.settle()
        }
        if sent { sendComposer() }
    }

    private func writeAttachedForPicture(over: Bool) async {
        compose(requestFocus: false)
        guard let composer else { return }
        await composer.waitForDraft()
        composer.accept(MailFixtureConversations.sam)
        composer.subject = over ? "The recording" : "Files for Thursday"
        composer.body = over ? "Here is the recording." : "The agreement, the logo and the numbers."
        var urls: [URL] = []
        for name in over ? ["agreement.pdf"] : ["agreement.pdf", "logo-mark.png", "q3-numbers.csv"] {
            let made = MailSampleFiles.standIn(named: name)
            if let url = await MailSampleFiles.stage(made.data, named: name, type: made.type,
                                                     in: MailIntake.folder, from: nil) {
                urls.append(url)
            }
        }
        if over, let big = await Task.detached(operation: { Self.sparseFile(named: "recording.mov", megabytes: 30) }).value {
            urls.append(big)
        }
        composer.files.add(urls)
        await composer.files.settle()
    }

    /// A file that says it is this big and holds nothing: all a size limit needs.
    private nonisolated static func sparseFile(named name: String, megabytes: Int) -> URL? {
        let folder = MailIntake.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(megabytes) * 1_000_000)
            try handle.close()
            return url
        } catch {
            return nil
        }
    }
}
#endif

#endif
