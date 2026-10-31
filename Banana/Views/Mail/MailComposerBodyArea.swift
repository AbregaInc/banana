#if !BANANA_PUBLIC
import SwiftUI
import QuickLook
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The body of a message and what goes with it (MAIL-UX 6.3.4, 6.3.5): the editor, the files
/// attached, and the format bar (bold, italic, underline, a link, bullets, numbers, a quote), which
/// Aa in the footer (`MailComposerTools`) shows and hides.
///
/// **The text is the model's.** The editor is the system's (`TextEditor` over an
/// `AttributedString`); the only state here is where the caret is and what the bar shows of it, so
/// the view tree being thrown away behind a backgrounded phone loses nothing he typed.
struct MailComposerBodyArea: View {
    let session: MailSession
    @ObservedObject var model: MailComposerModel
    @ObservedObject private var formatModel: MailComposerFormat
    var focused: FocusState<MailComposerModel.Field?>.Binding
    /// The card is too narrow for the footer to hold the paperclip and Aa: they are here instead.
    let toolsBelow: Bool

    @State private var selection = AttributedTextSelection()
    @State private var format = MailFormatState()
    /// How many lines the body has, so that the editor grows with them, to the most it may.
    @State private var lines = 1
    /// The bar is shown until it is hidden; a sheet and a card remember it alike.
    @AppStorage("mailFormatBarShown") private var showsBar = true
    @Binding var linking: Bool
    @State private var linkText = ""
    @State private var linkTarget = AttributedTextSelection()
    /// Who registered this view's chords on the Mac (`MailComposerChords`).
    @State private var chordOwner = UUID()

    init(session: MailSession, model: MailComposerModel, focused: FocusState<MailComposerModel.Field?>.Binding,
         linking: Binding<Bool>, toolsBelow: Bool) {
        self.session = session
        self.model = model
        self.focused = focused
        _linking = linking
        self.toolsBelow = toolsBelow
        _formatModel = ObservedObject(wrappedValue: model.format)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            MailRichEditor(model: model, focused: focused, selection: $selection, lines: lines)
            MailAttachmentChips(session: session, model: model, files: model.files)
            if toolsBelow {
                HStack(spacing: 0) {
                    MailComposerTools(files: model.files, chords: model.chords)
                    Spacer(minLength: 0)
                }
            }
            if showsBar || linking {
                MailFormatBar(state: format, linking: linking, linkText: $linkText,
                              act: act, applyLink: applyLink, removeLink: removeLink, cancelLink: cancelLink)
            }
        }
        .background { keys }
        .modifier(MailFilePreview(files: model.files))
        .onChange(of: selection) { _, _ in refresh() }
        .onChange(of: model.rich) { _, _ in refresh() }
        .onChange(of: focused.wrappedValue) { _, field in
            model.format.bodyFocused = field == .body
        }
        .onChange(of: model.caretToEnd) { _, _ in
            // Text was put in for him while the caret was on its way: it is after it.
            guard focused.wrappedValue == .body else { return }
            selection = AttributedTextSelection(insertionPoint: model.rich.endIndex)
        }
        .onChange(of: formatModel.linkRequest) { _, _ in beginLink() }
        .onAppear {
            model.format.bodyFocused = focused.wrappedValue == .body
            refresh()
            #if os(macOS)
            registerChords()
            #endif
        }
        #if os(macOS)
        .onDisappear { model.chords.unregister(owner: chordOwner) }
        #endif
    }

    // MARK: The keys

    /// The editor's keys that the editor does not take itself: ⌘K, the lists and the quote, a plain
    /// paste, and on the Mac ⌘B, ⌘I and ⌘U. UIKit's editor takes those three; an `NSTextView`
    /// takes them through the Format menu's key equivalents, and the Mac app has no Format menu
    /// (`MacCommands`), so they are bound here, to the toggle the format bar's buttons run, and
    /// the bar's highlight follows as it does for a click. (`TextFormattingCommands` was the other
    /// way: a Format menu with fonts, spacing and alignment, none of which the draft can keep, on
    /// every section of the app, acting on any text field's attributes behind the model's back.)
    ///
    /// On a touch device these are hidden buttons, as the composer's others are, on only while the
    /// body has the caret. On the Mac the chords are read from the event's exact modifiers
    /// (`MailComposerChord`: SwiftUI's own match does not count Shift, and every one of these has
    /// a twin one Shift away) and this view registers what each does (`registerChords`). ⌘K is
    /// the exception on both: it has no twin, and without selected words it is the command menu's.
    private var keys: some View {
        let inBody = focused.wrappedValue == .body
        return Group {
            Button("") { beginLink() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!(inBody && format.hasSelection))
            #if os(iOS)
            Button("") { act(.paragraph(.number)) }
                .keyboardShortcut("7", modifiers: [.command, .shift]).disabled(!inBody)
            Button("") { act(.paragraph(.bullet)) }
                .keyboardShortcut("8", modifiers: [.command, .shift]).disabled(!inBody)
            Button("") { act(.paragraph(.quote)) }
                .keyboardShortcut("9", modifiers: [.command, .shift]).disabled(!inBody)
            Button("") { pastePlain() }
                .keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!inBody)
            #endif
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    #if os(macOS)
    /// What the Mac's chords do in the body: only while the caret is in it. In To or Subject a
    /// chord is the composer's and does nothing; it is not passed on to File ▸ Library or the like.
    private func registerChords() {
        let chords = model.chords, owner = chordOwner
        func register(_ chord: MailComposerChord, _ run: @escaping () -> Void) {
            chords.register(chord, owner: owner) { if focused.wrappedValue == .body { run() } }
        }
        for trait in MailFormatting.Trait.allCases {
            register(.format(trait)) { act(.trait(trait)) }
        }
        for kind in [MailParagraphKind.number, .bullet, .quote] {
            register(.paragraph(kind)) { act(.paragraph(kind)) }
        }
        register(.pastePlain) { pastePlain() }
    }
    #endif

    // MARK: Doing

    enum Action {
        case trait(MailFormatting.Trait)
        case paragraph(MailParagraphKind)
        case link
    }

    private func act(_ action: Action) {
        switch action {
        case .trait(let trait):
            MailFormatting.toggle(trait, in: &model.rich, selection: &selection)
        case .paragraph(let kind):
            MailFormatting.toggle(kind, in: &model.rich, selection: &selection)
        case .link:
            beginLink()
            return
        }
        refresh()
        focused.wrappedValue = .body
    }

    private func refresh() {
        format = MailFormatting.state(of: model.rich, in: selection)
        model.format.hasSelection = format.hasSelection
        lines = model.rich.characters.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func beginLink() {
        guard MailFormatting.hasSelectedText(model.rich, selection) else { return }
        let words = MailFormatting.selectedText(model.rich, selection)
        linkTarget = selection
        if let existing = format.link {
            linkText = existing.absoluteString
            linking = true
        } else if MailFormatting.looksLikeAnAddress(words), let url = MailFormatting.link(from: words) {
            // The words are the address: nothing to ask.
            MailFormatting.setLink(url, in: &model.rich, selection: &selection)
            refresh()
        } else {
            linkText = ""
            linking = true
        }
    }

    private func applyLink() {
        finishLink(MailFormatting.link(from: linkText))
    }

    private func removeLink() {
        finishLink(nil)
    }

    private func finishLink(_ url: URL?) {
        defer {
            linking = false
            focused.wrappedValue = .body
        }
        guard url != nil || format.link != nil else { return }
        var target = linkTarget
        MailFormatting.setLink(url, in: &model.rich, selection: &target)
        selection = target
        refresh()
    }

    private func cancelLink() {
        linking = false
        focused.wrappedValue = .body
    }

    private func pastePlain() {
        #if os(iOS)
        guard let text = UIPasteboard.general.string else { return }
        #else
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        #endif
        model.rich.replaceSelection(&selection, withCharacters: text)
        refresh()
    }
}

// MARK: - The editor

/// The system's text editor over the body. Return in a list or a quote goes on with the same mark,
/// and ends the list on an empty item.
private struct MailRichEditor: View {
    @ObservedObject var model: MailComposerModel
    var focused: FocusState<MailComposerModel.Field?>.Binding
    @Binding var selection: AttributedTextSelection
    let lines: Int
    @ScaledMetric(relativeTo: .body) private var lineHeight = DS.Space.xl

    /// Ignore selection-only writes. The model retains changed text immediately and defers
    /// its view notification until the native editor's storage callback has unwound.
    private var text: Binding<AttributedString> {
        Binding(get: { model.rich }, set: { new in if new != model.rich { model.rich = new } })
    }

    /// At least as tall as its lines, a line more for the one being written, and no taller than the
    /// composer allows; the editor scrolls past that.
    private var height: CGFloat {
        min(max(DS.Mail.composerBodyMin, lineHeight * CGFloat(lines + 1)), DS.Mail.composerBodyMax)
    }

    var body: some View {
        TextEditor(text: text, selection: $selection)
            .attributedTextFormattingDefinition(MailBodyFormatting())
            .focused(focused, equals: .body)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: height, maxHeight: DS.Mail.composerBodyMax)
            .accessibilityLabel("Message")
            .accessibilityIdentifier(MailID.composerBody)
            .onChange(of: model.rich) { old, _ in
                MailFormatting.continueAfterReturn(from: old, text: &model.rich, selection: &selection)
            }
    }
}

/// Quick Look for the files on the draft.
private struct MailFilePreview: ViewModifier {
    @ObservedObject var files: MailComposerFiles

    func body(content: Content) -> some View {
        content.quickLookPreview($files.preview)
    }
}

// MARK: - The format bar

/// Bold, italic, underline, a link; bullets, numbers, a quote. A button is on when all of the
/// selection has it (or, with nothing selected, when what is typed next will).
private struct MailFormatBar: View {
    let state: MailFormatState
    let linking: Bool
    @Binding var linkText: String
    let act: (MailComposerBodyArea.Action) -> Void
    let applyLink: () -> Void
    let removeLink: () -> Void
    let cancelLink: () -> Void
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            MailFlowLayout(spacing: DS.Space.xs) {
                tool("bold", "Bold (\u{2318}B)", on: state.bold, MailID.formatBold) { act(.trait(.bold)) }
                tool("italic", "Italic (\u{2318}I)", on: state.italic, MailID.formatItalic) { act(.trait(.italic)) }
                tool("underline", "Underline (\u{2318}U)", on: state.underline, MailID.formatUnderline) {
                    act(.trait(.underline))
                }
                tool("link", "Link (\u{2318}K)", on: state.link != nil || linking, MailID.formatLink) { act(.link) }
                    .disabled(!state.hasSelection && !linking)
                tool("list.bullet", "Bulleted list (\u{21E7}\u{2318}8)", on: state.paragraph == .bullet,
                     MailID.formatBullets) { act(.paragraph(.bullet)) }
                tool("list.number", "Numbered list (\u{21E7}\u{2318}7)", on: state.paragraph == .number,
                     MailID.formatNumbers) { act(.paragraph(.number)) }
                tool("text.quote", "Quote (\u{21E7}\u{2318}9)", on: state.paragraph == .quote,
                     MailID.formatQuote) { act(.paragraph(.quote)) }
            }
            if linking { linkField }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.formatBar)
    }

    private func tool(_ symbol: String, _ label: String, on: Bool, _ identifier: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(minWidth: DS.Mail.oneLineRow, minHeight: DS.Mail.oneLineRow)
                .background(on ? Color.primary.opacity(DS.Tint.soft) : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .help(label)
    }

    /// Where the link goes, for words that are not an address themselves.
    private var linkField: some View {
        HStack(spacing: DS.Space.s) {
            TextField("Link address", text: $linkText)
                .textFieldStyle(.plain)
                .focused($linkFocused)
                .onSubmit(applyLink)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .padding(.horizontal, DS.Space.s)
                .frame(minHeight: DS.Mail.oneLineRow)
                .background(Color.primary.opacity(DS.Tint.subtle),
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityIdentifier(MailID.formatLinkField)
            Button("Link", action: applyLink)
                .disabled(MailFormatting.link(from: linkText) == nil)
            if state.link != nil {
                Button("Remove", action: removeLink)
            }
            Button(action: cancelLink) { Image(systemName: "xmark") }
                .accessibilityLabel("Cancel")
        }
        .buttonStyle(.borderless)
        // Made in the update that shows it, so on the Mac the first assignment finds no field and
        // the caret stays where it was: chased until the field has it (`MailCaretChase`).
        .task {
            linkFocused = true
            await MailCaretChase.run(isWanted: { !Task.isCancelled }, isThere: { linkFocused },
                                     ask: { linkFocused = true }, landed: {})
        }
    }
}

#endif
