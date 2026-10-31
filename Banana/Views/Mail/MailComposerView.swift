#if !BANANA_PUBLIC
import SwiftUI

/// The composer (MAIL-UX 6.3): who it goes to, what it is called, its text, the original folded
/// beneath it, and Send. One view in two frames: a **card** with an accent spine, written in the
/// conversation or alone in the pane; and a **sheet** at a phone's width.
///
/// It observes its model and nothing else. A keystroke changes `MailComposerModel` and re-evaluates
/// this view; nothing the list or the reading pane reads changes, because nothing there observes the
/// model. The text is the model's and not this view's, so the view tree being thrown away behind a
/// backgrounded phone loses none of it.
struct MailComposerView: View {
    enum Frame { case card, sheet }

    let session: MailSession
    @ObservedObject var model: MailComposerModel
    let frame: Frame

    @FocusState private var focused: MailComposerModel.Field?
    /// The card is wide enough for the paperclip and Aa to sit in the footer (`MailComposerTools`).
    @State private var footerHasRoom = false
    @State private var linking = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            MailSampleChip(text: "Sample \u{2014} nothing is really sent")
                .accessibilityIdentifier(MailID.composerSampleNote)
            if frame == .sheet {
                Text(model.title).font(.headline)
            }
            MailRecipientsView(model: model, focused: $focused)
            MailSubjectRow(model: model, focused: $focused)
            MailDivider(axis: .horizontal)
            MailComposerBodyArea(session: session, model: model, focused: $focused,
                                 linking: $linking, toolsBelow: !footerHasRoom)
            MailSignatureBlock(model: model)
            if let quote = model.quote {
                MailQuotedBlock(part: quote)
            }
            MailDivider(axis: .horizontal)
            MailSendLaterPanel(model: model)
            MailComposerFooter(session: session, model: model, showsTools: footerHasRoom)
            #if os(macOS)
            MailKeyHints()
            #endif
        }
        .padding(DS.Space.m)
        .onGeometryChange(for: Bool.self) { $0.size.width >= MailComposerTools.footerRoom } action: { footerHasRoom = $0 }
        .modifier(MailComposerChrome(frame: frame))
        .mailAttachmentIntake(model.files)
        .background { MailLeaveComposerButton(action: escape) }
        .onKeyPress(.escape) {
            escape()
            return .handled
        }
        // Asked for in the update that makes the card, and for the Cc and Bcc rows in the update
        // that shows them. Where the field is not there yet the assignment is dropped (on the Mac,
        // always, the first time), so the request is also chased until the caret is in its field.
        .onChange(of: model.focusRequest, initial: true) { _, request in
            if let request { focused = request.field }
        }
        .task(id: model.focusRequest) { await chaseCaret() }
        .onChange(of: focused) { _, field in
            if let field { model.focusLanded(on: field) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.composer)
    }

    private func escape() {
        if linking {
            linking = false
            focused = .body
        } else if model.timePicker != nil {
            model.toggleTimePicker()
            focused = .body
        } else {
            session.closeComposer()
        }
    }

    /// Looks, a frame after the request, whether the caret is in the field it asked for, and asks
    /// again until it is (`MailCaretChase`). Where the first assignment took, this finds the
    /// request landed and does nothing.
    private func chaseCaret() async {
        guard let request = model.focusRequest else { return }
        await MailCaretChase.run(
            isWanted: { !Task.isCancelled && model.isAsking(for: request) },
            isThere: { focused == request.field },
            ask: { focused = request.field },
            landed: { model.focusLanded(on: request.field) })
    }
}

/// The card's edge: a washed card with the accent spine down its leading side; or nothing for a
/// sheet, which is its own surface.
private struct MailComposerChrome: ViewModifier {
    let frame: MailComposerView.Frame

    func body(content: Content) -> some View {
        switch frame {
        case .card:
            content
                .dsCard()
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(DS.Palette.accent)
                        .frame(width: DS.Mail.cursorSpine)
                        .padding(.vertical, DS.Space.xs)
                }
        case .sheet:
            content
        }
    }
}

/// Esc leaves the composer and keeps the draft (6.3.8). A hidden cancel button as well as the key
/// handler on the card, because a text view may take a key the handler would have had.
private struct MailLeaveComposerButton: View {
    let action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// The line that says this is sample mail: on the composer, and on every message the sample "sends".
struct MailSampleChip: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(.caption).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(DS.Palette.warning)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.hair)
        .background(DS.Palette.warning.opacity(DS.Tint.soft), in: Capsule())
    }
}

private struct MailSubjectRow: View {
    @ObservedObject var model: MailComposerModel
    var focused: FocusState<MailComposerModel.Field?>.Binding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            MailRowLabel(text: "Subject")
            TextField("", text: $model.subject)
                .textFieldStyle(.plain)
                .focused(focused, equals: .subject)
                .onSubmit { focused.wrappedValue = .body }
                .accessibilityLabel("Subject")
                .accessibilityIdentifier(MailID.composerSubject)
        }
    }
}

// MARK: - The original, folded

/// The quoted original: its first line, "On Mon 5 Oct, 9:12 AM, Sam Lee wrote:", behind three dots,
/// and the whole of it when opened. Never part of what he types.
private struct MailQuotedBlock: View {
    let part: MailDraftPart
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: DS.Space.s) {
                    Text("\u{2022}\u{2022}\u{2022}")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.s)
                        .background(Color.primary.opacity(DS.Tint.soft), in: Capsule())
                    Text(part.attribution)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Hide quoted text" : "Show quoted text")
            .accessibilityIdentifier(MailID.composerQuote)
            if isOpen, let text = part.text {
                MailTextView(text: MailText(blocks: Array(text.blocks.dropFirst())))
            }
        }
    }
}

// MARK: - Send

/// The bin at one end, away from Send; Send and Done and Send at the other.
private struct MailComposerFooter: View {
    let session: MailSession
    @ObservedObject var model: MailComposerModel
    let showsTools: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button { session.discardComposer() } label: {
                Image(systemName: "trash")
                    .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .composerShortcut(",", [.command, .shift])
            .accessibilityLabel("Discard draft")
            .accessibilityIdentifier(MailID.discard)
            .help("Discard draft (\u{21E7}\u{2318},)")
            // Where there is room the paperclip and Aa sit here; in a narrow card they have a row of
            // their own under the body (`MailComposerBodyArea`), for the footer is full without them.
            if showsTools { MailComposerTools(files: model.files, chords: model.chords) }
            Spacer(minLength: DS.Space.s)
            // A message that waits for a time is not marked Done with it.
            if model.canSendAndDone, model.schedule == nil {
                Button("Send and Done") { session.sendComposer(thenDone: true) }
                    .composerShortcut(.return, [.command, .shift])
                    .disabled(!model.isReady)
                    .accessibilityIdentifier(MailID.sendAndDone)
                    .help("Send, and mark the conversation Done (\u{21E7}\u{2318}Return)")
            }
            MailSendLaterButton(model: model)
            Button(model.schedule == nil ? "Send" : MailScheduleCopy.schedule) { session.sendComposer() }
                .buttonStyle(.borderedProminent)
                .composerShortcut(.return, .command)
                .disabled(!model.isReady)
                .accessibilityIdentifier(MailID.send)
                .help(model.schedule == nil ? "Send (\u{2318}Return)" : "Schedule (\u{2318}Return)")
        }
    }
}

extension View {
    /// A composer chord on its button. On a touch device the button carries it: UIKit matches the
    /// modifiers exactly. On the Mac it does not, because SwiftUI's match does not count Shift,
    /// and every one of these chords has a twin one Shift away (⌘A and ⇧⌘A, ⌘C and ⇧⌘C, ⌘↩ and
    /// ⇧⌘↩, ⌘, and ⇧⌘,): the Mac's monitor reads the event instead and decides in one place
    /// (`MailComposerChord`, `MailKeyDispatch.handleComposerChord`).
    @ViewBuilder func composerShortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> some View {
        #if os(macOS)
        self
        #else
        keyboardShortcut(key, modifiers: modifiers)
        #endif
    }
}

#if os(macOS)
/// The keys of the composer, under it (6.3.1). Written as words: the return arrow is drawn as an
/// emoji on its own.
private struct MailKeyHints: View {
    var body: some View {
        Text("\u{2318}Return Send  \u{00B7}  \u{21E7}\u{2318}Return Send and Done  \u{00B7}  \u{21E7}\u{2318}L Send later  \u{00B7}  \u{21E7}\u{2318}C Cc  \u{21E7}\u{2318}B Bcc  \u{00B7}  Esc Keep draft")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
#endif

// MARK: - A line of chips

/// Set on the one view of a flow that takes the rest of its line: the typing field.
struct MailFlowFills: LayoutValueKey {
    static let defaultValue = false
}

/// Chips that wrap onto another line when the room runs out, with the typing field after them.
struct MailFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arranged.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            var fitted = min(size.width, width)
            if x > 0, x + fitted > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            if subview[MailFlowFills.self], width.isFinite { fitted = max(fitted, width - x) }
            frames.append(CGRect(x: x, y: y, width: fitted, height: size.height))
            x += fitted + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), frames)
    }
}

#endif
