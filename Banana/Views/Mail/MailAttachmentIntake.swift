#if !BANANA_PUBLIC
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import UIKit
#else
import AppKit
#endif

/// The ways a file reaches a message he is writing, other than the file panel: dropped on the
/// composer, pasted from the paperclip's menu, and picked from photos. Each one is a file the system lends for a moment;
/// it is copied a megabyte at a time, off the main thread, into a folder of this app's temporary
/// directory (`MailIntake`), and then handed to the composer's files, which gives it to the source.
/// No bytes are read in a view, and none are held whole.
enum MailIncoming {

    /// What may be dropped or pasted: a file, or a picture.
    static let types: [UTType] = [.fileURL, .image]

    /// Takes in what the providers offer. True if there was anything that could be a file.
    @MainActor
    @discardableResult
    static func receive(_ providers: [NSItemProvider], into files: MailComposerFiles) -> Bool {
        let wanted = providers.filter { provider in
            types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        for provider in wanted {
            load(provider) { kept in
                guard let kept else { return }
                Task { @MainActor in files.add([kept]) }
            }
        }
        return !wanted.isEmpty
    }

    /// One provider's file, kept: a file's own address when it offers one, and otherwise its
    /// picture. The completion is called off the main thread.
    private static func load(_ provider: NSItemProvider, completion: @escaping @Sendable (URL?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else { return completion(nil) }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                completion(try? MailIntake.copy(url, into: MailIntake.folder).url)
            }
        } else if let picture = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            // The picture's own type (a PNG, a JPEG, a HEIC), as the provider has it.
            let name = provider.suggestedName ?? "Pasted picture"
            provider.loadFileRepresentation(forTypeIdentifier: picture) { url, _ in
                // The system's copy is only there until this returns, and its name is a hash.
                guard let url else { return completion(nil) }
                let ext = url.pathExtension
                completion(try? MailIntake.copy(url, into: MailIntake.folder,
                                                named: ext.isEmpty ? name : name + "." + ext).url)
            }
        } else {
            completion(nil)
        }
    }
}

#if os(iOS)
extension MailIncoming {
    /// Paste, for a file or a picture on the pasteboard. What is only text, or a web address, is not
    /// a file, and says so under the chips.
    @MainActor
    static func pasteFromPasteboard(into files: MailComposerFiles) {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages || pasteboard.hasURLs, receive(pasteboard.itemProviders, into: files) else {
            files.say(MailAttachmentText.nothingToPaste)
            return
        }
    }
}
#endif

#if os(macOS)
extension MailIncoming {
    /// The Mac's Paste, for a file or a picture on the pasteboard: files by their addresses, and a
    /// picture (a screenshot) as a file of its own. Says so under the chips when there is neither.
    @MainActor
    static func pasteFromPasteboard(into files: MailComposerFiles) {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            files.add(urls)
            return
        }
        let png = pasteboard.data(forType: .png)
        guard let data = png ?? pasteboard.data(forType: .tiff) else {
            files.say(MailAttachmentText.nothingToPaste)
            return
        }
        let name = png == nil ? "Pasted picture.tiff" : "Pasted picture.png"
        Task {
            if let url = await MailIntake.keep(data, named: name) { files.add([url]) }
        }
    }
}
#endif

extension View {
    /// Files and pictures can be dropped on the composer. A drop shows the accent edge while it is
    /// over.
    func mailAttachmentIntake(_ files: MailComposerFiles) -> some View {
        modifier(MailAttachmentIntake(files: files))
    }
}

private struct MailAttachmentIntake: ViewModifier {
    @ObservedObject var files: MailComposerFiles

    func body(content: Content) -> some View {
        // Paste is not here: a text editor that has the caret takes ⌘V for itself, and a handler
        // up the tree would only be asked when it has not. The paperclip's Paste is the way in.
        content
            .onDrop(of: MailIncoming.types, isTargeted: $files.isTargeted) { providers in
                MailIncoming.receive(providers, into: files)
            }
            .overlay {
                if files.isTargeted {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.Palette.accent, lineWidth: DS.Space.hair)
                        .allowsHitTesting(false)
                }
            }
    }
}

#if os(iOS)
/// A photo or a video from the system's picker, as a file.
struct MailPickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            // The picker's copy is only there until this returns.
            guard let kept = try? MailIntake.copy(received.file, into: MailIntake.folder).url else {
                throw CocoaError(.fileWriteUnknown)
            }
            return MailPickedFile(url: kept)
        }
    }
}
#endif

#endif
