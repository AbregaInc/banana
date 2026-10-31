#if !BANANA_PUBLIC
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// The paperclip and Aa, in the composer's footer beside the bin (MAIL-UX 6.3.1, 6.3.2): the
/// paperclip attaches (the file panel; and, where there is a finger, the photo picker; and Paste for
/// a file or a picture on the pasteboard; ⇧⌘A), and Aa shows and hides the format bar that sits
/// under the body.
///
/// The files themselves are the composer's (`MailComposerFiles`) and the chips are drawn under the
/// body; this only asks for more.
struct MailComposerTools: View {
    /// How wide the card must be for the footer to hold these beside the bin, Send and Done, the
    /// clock and Send: a phone's width and the Mac's narrow pane are under it, and there the tools
    /// have a row of their own under the body.
    static let footerRoom: CGFloat = 440

    let files: MailComposerFiles
    /// Where ⇧⌘A is registered on the Mac (`MailComposerChord`): the Mac's monitor reads the key
    /// and asks for the panel here, because SwiftUI's own shortcut match does not count Shift and
    /// took plain ⌘A, Select All, for it.
    let chords: MailComposerChords
    /// The bar is shown until it is hidden; a sheet and a card remember it alike.
    @AppStorage("mailFormatBarShown") private var showsBar = true
    @State private var showsFilePanel = false
    @State private var chordOwner = UUID()
    #if os(iOS)
    @State private var showsPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    #endif

    var body: some View {
        HStack(spacing: 0) {
            attachControl
            formatToggle
        }
        .background {
            Button("") { showsFilePanel = true }
                .composerShortcut("a", [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .fileImporter(isPresented: $showsFilePanel, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { files.add(urls) }
        }
        #if os(macOS)
        .onAppear { chords.register(.attach, owner: chordOwner) { showsFilePanel = true } }
        .onDisappear { chords.unregister(owner: chordOwner) }
        #endif
        #if os(iOS)
        .photosPicker(isPresented: $showsPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { @MainActor in
                for item in items {
                    if let file = try? await item.loadTransferable(type: MailPickedFile.self) {
                        files.add([file.url])
                    }
                }
            }
        }
        #endif
    }

    private var formatToggle: some View {
        Button { showsBar.toggle() } label: {
            Text("Aa")
                .font(.callout.weight(.semibold))
                .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                .foregroundStyle(showsBar ? Color.primary : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(showsBar ? "Hide formatting" : "Show formatting")
        .accessibilityIdentifier(MailID.formatToggle)
        .help(showsBar ? "Hide the format bar" : "Show the format bar")
    }

    @ViewBuilder private var attachControl: some View {
        #if os(iOS)
        Menu {
            Button { showsPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            Button { showsFilePanel = true } label: { Label("Files", systemImage: "folder") }
            // Paste, for a file or a picture on the pasteboard. A picture copied in another app
            // asks once, as the system does, whether this app may read it.
            Button { MailIncoming.pasteFromPasteboard(into: files) } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
        } label: { attachLabel }
        .accessibilityLabel("Attach")
        .accessibilityIdentifier(MailID.attach)
        #else
        Menu {
            Button { showsFilePanel = true } label: { Label("Choose Files\u{2026}", systemImage: "folder") }
            Button { MailIncoming.pasteFromPasteboard(into: files) } label: {
                Label("Paste File or Picture", systemImage: "doc.on.clipboard")
            }
        } label: { attachLabel }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Attach")
        .accessibilityIdentifier(MailID.attach)
        .help("Attach files (\u{21E7}\u{2318}A)")
        #endif
    }

    private var attachLabel: some View {
        Image(systemName: "paperclip")
            .frame(width: DS.Row.minHeight, height: DS.Mail.header)
            .contentShape(Rectangle())
    }
}

#endif
