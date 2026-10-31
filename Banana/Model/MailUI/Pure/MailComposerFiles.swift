#if !BANANA_PUBLIC
import Foundation
import Combine

/// The files on one draft, as the composer holds them: the chips, the size they make, what to say
/// when one would take the message over what Gmail takes, and the way in from the file panel, a
/// drop, a paste and the photo picker, which all arrive here as file URLs.
///
/// **It is the composer's own small observable**, so adding a file re-evaluates the chips and not
/// the composer; and **no file is touched on the main thread**: the size is read off it, and the
/// bytes are copied by the source (`addAttachment`), a megabyte at a time. A chip is on screen at
/// once, with the file's name, before the file has been read.
///
/// The limit is `MailTuning.maxEncodedBytes`, held against what the attachments weigh once
/// encoded. A file that would take the message over is **not added**, and the line under the chips
/// says so in words (no dialog). A forward can arrive over the limit, carrying what it was sent
/// with: then the chips' line says so, and sending says so too (`isOver`).
@MainActor
final class MailComposerFiles: ObservableObject {

    /// A file being read: its chip, with its name, until it is added or refused.
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        var name: String
    }

    /// What taking a chip off needs to put it back.
    struct Removed: Equatable {
        var attachment: MailDraftAttachment
        var index: Int
    }

    @Published private(set) var items: [MailDraftAttachment] = [] {
        didSet { shown = items.map(MailDraftAttachmentDisplay.init) }
    }
    /// The chips, made when the files change and not when they are drawn.
    @Published private(set) var shown: [MailDraftAttachmentDisplay] = []
    @Published private(set) var pending: [Pending] = []
    /// What went wrong with the last file, in words; gone with the next change.
    @Published private(set) var notice: String?
    /// The file being looked at (Quick Look).
    @Published var preview: URL?
    /// A file is being dragged over the composer.
    @Published var isTargeted = false

    private let source: MailSource
    /// Whose draft this is, once it has arrived.
    var draftID: () -> MailDraftID? = { nil }
    /// Finishes when the draft has arrived.
    var whenReady: () async -> Void = {}
    /// Something about the draft's files changed: it is to be saved.
    var changed: () -> Void = {}

    private var touched = false
    private var queue: Task<Void, Never>?

    init(source: MailSource) {
        self.source = source
    }

    // MARK: What they are

    var isEmpty: Bool { items.isEmpty && pending.isEmpty }
    var bytes: Int { items.reduce(0) { $0 + $1.bytes } }
    /// What they weigh once encoded.
    var encodedBytes: Int { MailAttachmentSize.encoded(items.map(\.bytes)) }
    var isOver: Bool { encodedBytes > MailTuning.maxEncodedBytes }

    /// The line under the chips: how many and how big, or that it is too much.
    var summary: String? {
        guard !items.isEmpty else { return nil }
        return isOver ? MailAttachmentText.overTheLimit(bytes: bytes)
            : MailAttachmentText.summary(count: items.count, bytes: bytes)
    }

    /// Whether he has changed which files go: a forward's own are not something he typed.
    var isChanged: Bool { touched }

    // MARK: Arriving with a draft

    /// The draft arrived with these (a forward carries the original's). They are as the draft
    /// made them and not his doing, until he adds or removes one.
    func adopt(_ attachments: [MailDraftAttachment]) {
        items = attachments
        touched = false
    }

    // MARK: Adding

    /// Adds files. Their chips are there at once; each file is read and kept by the source in its
    /// turn, and a chip that cannot be is taken off and the notice says why. Each URL may be
    /// security-scoped (the file panel's): it is opened for as long as the source needs it.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let waiting = urls.map { Pending(name: MailFileName.safe($0.lastPathComponent)) }
        pending.append(contentsOf: waiting)
        let before = queue
        queue = Task { @MainActor [weak self] in
            await before?.value
            await self?.whenReady()
            for (url, chip) in zip(urls, waiting) {
                await self?.addOne(url, chip: chip)
            }
        }
    }

    /// Finishes when every file added so far has been dealt with. For tests.
    func settle() async {
        await queue?.value
    }

    private func addOne(_ url: URL, chip: Pending) async {
        defer { pending.removeAll { $0.id == chip.id } }
        // A file the system lent for a moment (a drop, a paste, a photo) is cleared away once the
        // source has its own copy, or has refused it.
        defer { Task { await MailIntake.discard(url) } }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let draft = draftID(),
              let size = await Task.detached(operation: { MailAttachmentSize.fileSize(url) }).value else {
            notice = MailAttachmentText.couldNotAttach(chip.name)
            return
        }
        // What it would weigh with this one in it: the notice is the answer, and the file is not
        // copied for nothing.
        if MailAttachmentSize.isOver(items.map(\.bytes) + [size]) {
            notice = MailAttachmentText.notAdded(chip.name, bytes: size)
            return
        }
        guard let added = await source.addAttachment(url, to: draft) else {
            notice = MailAttachmentText.couldNotAttach(chip.name)
            return
        }
        items.append(added)
        touched = true
        notice = nil
        changed()
    }

    /// Says something under the chips, in words: what could not be done.
    func say(_ words: String) {
        notice = words
    }

    // MARK: Taking off

    /// Takes a file off. What it needs to be put back is returned (the toast's Undo).
    @discardableResult
    func remove(_ id: String) -> Removed? {
        guard let index = items.firstIndex(where: { $0.id == id }), let draft = draftID() else { return nil }
        let attachment = items.remove(at: index)
        source.removeAttachment(id, from: draft)
        touched = true
        notice = nil
        changed()
        return Removed(attachment: attachment, index: index)
    }

    /// Puts a removed file back where it was, as it was.
    func restore(_ removed: Removed) {
        guard let file = removed.attachment.file, let draft = draftID() else { return }
        Task { @MainActor [weak self] in
            guard let self, let back = await self.source.addAttachment(file, to: draft) else { return }
            self.items.insert(back, at: min(removed.index, self.items.count))
            self.touched = true
            self.notice = nil
            self.changed()
        }
    }

    // MARK: Looking

    /// Opens a file for a look (Quick Look and nothing else); not a program.
    func look(at id: String) {
        guard let attachment = items.first(where: { $0.id == id }), let file = attachment.file else { return }
        let kind = MailAttachmentKind.of(name: attachment.name, mimeType: "")
        guard !kind.isProgram, !attachment.isExecutable else { return }
        preview = file
    }
}

/// Opening an attachment of a received message: Quick Look on the file when it is here, a request
/// for it when it is not, and a word when it is a program, which is never opened.
@MainActor
final class MailAttachmentOpener: ObservableObject {
    @Published var preview: URL?
    @Published private(set) var notice: String?
    @Published private(set) var waiting: MailAttachmentID?

    private let source: MailSource

    init(source: MailSource) {
        self.source = source
    }

    func open(_ file: MailAttachmentDisplay) {
        notice = nil
        guard !file.isProgram else {
            notice = "\u{201C}\(file.name)\u{201D} \u{2014} " + MailAttachmentText.program
            return
        }
        if let url = file.localFile {
            preview = url
        } else {
            waiting = file.id
            source.fetchAttachment(file.id)
        }
    }

    /// The conversation changed: a file that was asked for may be here now.
    func update(_ messages: [MailMessageDisplay]) {
        guard let waiting,
              let file = messages.flatMap(\.files).first(where: { $0.id == waiting }),
              let url = file.localFile else { return }
        self.waiting = nil
        preview = url
    }
}

#endif
