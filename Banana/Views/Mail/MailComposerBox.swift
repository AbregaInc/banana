#if !BANANA_PUBLIC
import SwiftUI

/// How the box is drawn, handed down to the rows inside it (the editor's height, the format bar).
enum MailComposerBoxStyle: Equatable, Sendable {
    case docked, full
    /// Aa in the box: the format bar is hidden until asked for, and remembered apart from the card's.
    static let formatBarKey = "mailFormatBarShownInBox"
    /// The docked box grows with the text to this many lines, then the text scrolls.
    static let dockedLines = 4
    /// What the system editor sets its text in by, top and bottom together.
    static let editorInset: CGFloat = 16
    static let corner: CGFloat = 26
}

extension EnvironmentValues {
    /// Set inside the composer's box; nil in the standalone routes' card and sheet.
    @Entry var mailComposerBox: MailComposerBoxStyle? = nil
}

/// The composer in the app's shells (direction A, chosen 7 Nov 2026): the bottom field grown into a
/// solid box. Docked, it sits over the keyboard, To and the text growing to four lines with the
/// tools and Send under them, and the thread scrolls on its own above it; at full height it is an
/// editor over the thread. A grab handle and ⤢ move it between the two (`MailComposerDock`);
/// pulled down it folds into the bottom field (`MailComposerFoldedField`) or goes away, the draft
/// kept either way. Send is one split button: the word sends, the chevron opens send later.
///
/// It observes its model and the navigation's dock, nothing else: a keystroke re-evaluates the box,
/// never the thread above it or the list.
struct MailComposerBox: View {
    let session: MailSession
    @ObservedObject var model: MailComposerModel
    @ObservedObject var navigation: MailNavigation
    /// The full height where the container cannot give it (the shell's bar); nil fills the container.
    var fullHeight: CGFloat?

    @FocusState private var focused: MailComposerModel.Field?
    @State private var linking = false
    /// How far the handle has been pulled, while it is held.
    @State private var pull: CGFloat = 0
    /// The sparkle turned the tools row into the assistant's line.
    @State private var asking = false
    @State private var instruction = ""
    @State private var assistantTask: Task<Void, Never>?
    @State private var suggestion: String?
    @State private var suggestionContext: MailComposerModel.AssistantDraftContext?
    /// What the assistant last gave back for this reply, with its 👍 / 👎 and, for questions, the answers.
    @State private var aiDisplay: MailAIDisplay?
    @State private var aiFeedback: MailAIFeedback?
    @State private var aiForm: MailPickerForm?
    @State private var aiKey: AIKey?
    /// The conversation whose overnight outcome is shown, cleared from the store once dealt with.
    @State private var aiOvernight: MailConversationID?
    private var thinking: Bool { assistantTask != nil }
    @FocusState private var instructing: Bool

    private var style: MailComposerBoxStyle { navigation.dock?.mode == .full ? .full : .docked }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            handle
            if session.isSample {
                MailSampleChip(text: "Sample \u{2014} nothing is really sent")
                    .accessibilityIdentifier(MailID.composerSampleNote)
            }
            if model.isForeign {
                if let url = model.gmailDraftsURL { Link("Continue in Gmail", destination: url) }
                Button("Edit as text") { Task { await model.rewriteAsText() } }
            }
            if !session.isSample { MailDraftSaveStatus(title: model.syncStatusTitle) }
            MailRecipientsView(model: model, focused: $focused, compact: true).disabled(model.isForeign)
            // A new message has a subject to write; a reply and a forward keep theirs.
            if model.host == nil {
                MailSubjectRow(model: model, focused: $focused).disabled(model.isForeign)
            }
            MailDivider(axis: .horizontal)
            MailComposerBodyArea(session: session, model: model, focused: $focused,
                                 linking: $linking, toolsBelow: false).disabled(model.isForeign)
            if style == .full {
                MailSignatureBlock(model: model).disabled(model.isForeign)
                if let quote = model.quote { MailQuotedBlock(part: quote) }
            }
            if let suggestion, suggestionContext == model.assistantDraftContext {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Suggested draft").font(.subheadline.weight(.medium))
                    ScrollView { Text(suggestion).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 120)
                    HStack {
                        Button("Use draft") {
                            guard session.composer === model, suggestionContext == model.assistantDraftContext else { return }
                            model.writeAssistantDraft(suggestion)
                            clearAssistantSuggestion()
                        }
                        Button("Dismiss") { clearAssistantSuggestion() }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if model.canUndoAssistantDraft || draftFeedback != nil {
                HStack(spacing: DS.Space.s) {
                    if model.canUndoAssistantDraft {
                        Button("Undo") { model.undoAssistantDraft() }
                            .buttonStyle(.plain)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(MailID.composerAssistantUndo)
                    }
                    Spacer(minLength: 0)
                    if let draftFeedback { MailAIFeedbackRow(feedback: draftFeedback, noting: model.aiPicture?.noting == true) }
                }
            }
            if let aiDisplay, let aiFeedback, aiKey == currentAIKey, !aiDisplay.isDraft {
                MailAIOutcomePanel(display: aiDisplay, feedback: aiFeedback, form: $aiForm, writing: thinking,
                                   write: writeFromPicker, dismiss: dismissAIResult)
            }
            if model.allowsScheduling { MailSendLaterPanel(model: model) }
            MailDivider(axis: .horizontal)
            footer
        }
        .disabled(model.isResolving)
        .onDisappear {
            assistantTask?.cancel()
            assistantTask = nil
            clearAssistantSuggestion()
            clearAIResult()
        }
        .task(id: currentAIKey) { await showOvernightOutcome() }
        .onChange(of: model.aiPicture, initial: true) { _, picture in
            guard let picture else { return }
            show(picture.run, instruction: nil, answers: nil, overnight: false)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: style == .full ? fullHeight : nil, alignment: .top)
        .frame(maxHeight: style == .full && fullHeight == nil ? .infinity : nil, alignment: .top)
        .background(MailComposerBox.surface, in: RoundedRectangle(cornerRadius: MailComposerBoxStyle.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MailComposerBoxStyle.corner, style: .continuous)
                .strokeBorder(DS.Palette.separator.opacity(0.6))
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: -2)
        .offset(y: max(0, pull))
        .environment(\.mailComposerBox, style)
        .mailAttachmentIntake(model.files)
        .background { keys }
        .onKeyPress(.escape) {
            escape()
            return .handled
        }
        .onChange(of: model.focusRequest, initial: true) { _, request in
            if let request { focused = request.field }
        }
        .task(id: model.focusRequest) { await chaseCaret() }
        .onChange(of: focused) { _, field in
            if let field { model.focusLanded(on: field) }
        }
        .onDisappear {
            focused = nil
            instructing = false
            #if os(iOS)
            // Closing a retained draft must also end its native editing session. Otherwise
            // keyboard state can outlive the removed editor and hide the restored shell bar.
            // A replacement composer owns its own focus; leave that new editor alone.
            if session.composer == nil { ShellChrome.keyWindow?.endEditing(false) }
            #endif
        }
        .animation(.snappy(duration: 0.25), value: style)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.composer)
    }

    /// Solid, never glass: content is opaque (the approved images).
    static var surface: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }

    // MARK: The handle and ⤢

    private var handle: some View {
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { pull = $0.translation.height }
                        .onEnded { value in
                            pull = 0
                            session.dock(.dragEnded(translation: Double(value.predictedEndTranslation.height)))
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("Resize")
                .accessibilityIdentifier(MailID.composerHandle)
                .accessibilityAction(named: style == .full ? "Make smaller" : "Full height") {
                    session.dock(style == .full ? .collapse : .expand)
                }
                .accessibilityAction(named: "Put away") { session.closeComposer() }
            Button { session.dock(style == .full ? .collapse : .expand) } label: {
                Image(systemName: style == .full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(DS.Tint.soft), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Space.s)
            .accessibilityLabel(style == .full ? "Make smaller" : "Full height")
            .accessibilityIdentifier(MailID.composerExpand)
            .help(style == .full ? "Make smaller" : "Full height")
        }
        .padding(.top, DS.Space.xs)
    }

    // MARK: The tools and Send

    @ViewBuilder private var footer: some View {
        Group {
            if asking {
                assistantLine
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        writingTools
                        Spacer(minLength: DS.Space.s)
                        MailSendSplitButton(session: session, model: model)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack(spacing: 0) { writingTools; Spacer(minLength: 0) }
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            MailSendSplitButton(session: session, model: model)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var writingTools: some View {
        MailComposerTools(files: model.files, chords: model.chords, format: model.format, isReadOnly: model.isForeign).disabled(model.isForeign)
        if MailDraftAssistant.isAvailable {
            Button {
                asking = true
                instructing = true
            } label: {
                Image(systemName: "sparkle")
                    .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.isForeign)
            .accessibilityLabel("Write with Banana")
            .accessibilityIdentifier(MailID.composerAssistant)
        }
    }

    private var canDraftReplyWithoutInstructions: Bool {
        (model.replyStyle == .reply || model.replyStyle == .replyAll) && model.rich.characters.isEmpty
    }

    private var assistantLine: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "sparkle").foregroundStyle(DS.Palette.accent)
            TextField(canDraftReplyWithoutInstructions ? "Optional reply instructions" : "Say yes, Friday instead", text: $instruction)
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .focused($instructing)
                .submitLabel(.go)
                .onSubmit(runAssistant)
                .accessibilityIdentifier(MailID.composerAssistantField)
            if thinking {
                ProgressView().controlSize(.small)
            } else {
                Button(action: runAssistant) {
                    if canDraftReplyWithoutInstructions {
                        Text("Draft reply")
                    } else {
                        Image(systemName: "return")
                    }
                }
                    .buttonStyle(.plain)
                    .disabled(!canDraftReplyWithoutInstructions && instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(canDraftReplyWithoutInstructions ? "Draft reply" : "Write it")
            }
            Button {
                assistantTask?.cancel()
                assistantTask = nil
                asking = false
                instruction = ""
                clearAssistantSuggestion()
                focused = .body
            } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, DS.Space.m)
        .frame(minHeight: DS.Mail.header)
        .background(Color.primary.opacity(DS.Tint.soft), in: Capsule())
        .padding(.vertical, DS.Space.xs)
    }

    private func runAssistant() {
        let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty || canDraftReplyWithoutInstructions, !thinking, model.isReady, !model.isForeign else { return }
        clearAIResult()
        startAssistant(task: words.isEmpty ? "Draft a reply to the selected message." : words,
                       instruction: words.isEmpty ? nil : words, answers: nil, fieldWords: words)
    }

    /// The picker's Write: the answers go back to the assistant as the next instruction.
    private func writeFromPicker() {
        guard let form = aiForm, form.canWrite, !thinking, model.isReady, !model.isForeign else { return }
        startAssistant(task: form.instruction(), instruction: aiFeedback?.instruction, answers: form.summary(), fieldWords: nil)
    }

    /// `fieldWords` is what the assistant's line said when asked; nil when the picker asked.
    private func startAssistant(task: String, instruction shown: String?, answers: String?, fieldWords: String?) {
        let context = model.assistantDraftContext
        let original = model.rich
        let body = model.body
        clearAssistantSuggestion()
        assistantTask = Task { @MainActor in
            defer { if !Task.isCancelled { assistantTask = nil } }
            do {
                let run = try await MailDraftAssistant.replyRun(instruction: task, context: context, body: body,
                                                                source: session.source as? MailLiveSource)
                guard !Task.isCancelled, session.composer === model else { return }
                guard model.assistantDraftContext == context, !model.isForeign, !model.isResolving else {
                    session.showToast(MailToast(text: "Draft changed. Try again.", action: nil, lasts: nil))
                    return
                }
                if let fieldWords, instruction.trimmingCharacters(in: .whitespacesAndNewlines) != fieldWords { return }
                if let done = aiOvernight { clearStoredOvernight(done) }
                show(run, instruction: shown, answers: answers, overnight: false)
                if case .draft(let text) = run.outcome {
                    if model.rich == original {
                        model.writeAssistantDraft(text)
                    } else {
                        suggestionContext = context
                        suggestion = text
                    }
                }
                asking = false
                instruction = ""
            } catch {
                guard !Task.isCancelled, session.composer === model else { return }
                guard model.assistantDraftContext == context else { return }
                if let fieldWords, instruction.trimmingCharacters(in: .whitespacesAndNewlines) != fieldWords { return }
                let message: String
                if let issue = error as? MailDraftAssistant.NeedsInput {
                    message = issue.message
                } else if error is MailDraftPrompt.UnverifiedLink {
                    message = "Add the link or email address to your instructions and try again."
                } else {
                    message = "Banana couldn’t write that"
                }
                session.showToast(MailToast(text: message, action: nil, lasts: nil))
            }
        }
    }

    // MARK: The assistant's outcome

    /// The reply an outcome belongs to: the conversation and the message answered.
    struct AIKey: Equatable {
        var conversation: MailConversationID?
        var selected: MailMessageID?
    }

    private var currentAIKey: AIKey {
        let context = model.assistantDraftContext
        return AIKey(conversation: context.conversation, selected: context.selectedMessageID)
    }

    private var draftFeedback: MailAIFeedback? {
        guard let aiDisplay, aiDisplay.isDraft, aiKey == currentAIKey else { return nil }
        return aiFeedback
    }

    private func show(_ run: MailAIRun, instruction: String?, answers: String?, overnight: Bool) {
        let display = MailAIDisplay(run.outcome)
        aiDisplay = display
        aiFeedback = MailAIFeedback(run: run, instruction: instruction, answers: answers, overnight: overnight)
        if case .picker(let picker) = display { aiForm = MailPickerForm(picker) } else { aiForm = nil }
        aiKey = currentAIKey
    }

    private func clearAIResult() {
        aiDisplay = nil
        aiFeedback = nil
        aiForm = nil
        aiKey = nil
        aiOvernight = nil
    }

    private func dismissAIResult() {
        if let done = aiOvernight { clearStoredOvernight(done) }
        clearAIResult()
    }

    private func clearStoredOvernight(_ conversation: MailConversationID) {
        aiOvernight = nil
        guard let source = session.source as? MailLiveSource else { return }
        Task { await source.clearOvernightOutcome(for: conversation) }
    }

    /// What the overnight pass left for this reply: questions, a note or a no-reply line for the
    /// message being answered, or the facts of the overnight draft open here.
    private func showOvernightOutcome() async {
        let context = model.assistantDraftContext
        guard aiDisplay == nil, !thinking, let source = session.source as? MailLiveSource,
              let conversation = context.conversation,
              let found = await source.overnightOutcome(for: conversation),
              let stored = MailAIStoredOutcome.decode(found.payload), let run = stored.run,
              found.anchor.message == stored.anchor, !Task.isCancelled,
              model.assistantDraftContext == context, aiDisplay == nil else { return }
        if stored.kind == .draft {
            guard context.draftID == MailOvernightDrafts.draftID(for: conversation, anchor: found.anchor) else { return }
        } else {
            guard context.selectedMessageID == found.anchor else { return }
        }
        show(run, instruction: nil, answers: nil, overnight: true)
        aiOvernight = conversation
    }

    private func clearAssistantSuggestion() {
        suggestion = nil
        suggestionContext = nil
    }

    // MARK: Keys

    /// Esc puts the box away and keeps the draft; ⇧⌘↩ Send and Done and ⇧⌘, discard, as the card
    /// had them. Hidden buttons, because a text view may take a key a handler would have had.
    private var keys: some View {
        Group {
            Button("", action: escape).keyboardShortcut(.cancelAction)
            if model.canSendAndDone, model.schedule == nil {
                Button("") { session.sendComposer(thenDone: true) }
                    .composerShortcut(.return, [.command, .shift])
                    .disabled(!model.isReady)
            }
            Button("") { session.discardComposer() }.composerShortcut(",", [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func escape() {
        if asking {
            asking = false
            focused = .body
        } else if linking {
            linking = false
            focused = .body
        } else if model.timePicker != nil {
            model.toggleTimePicker()
            focused = .body
        } else {
            session.closeComposer()
        }
    }

    private func chaseCaret() async {
        guard let request = model.focusRequest else { return }
        await MailCaretChase.run(
            isWanted: { !Task.isCancelled && model.isAsking(for: request) },
            isThere: { focused == request.field },
            ask: { focused = request.field },
            landed: { model.focusLanded(on: request.field) })
    }
}

/// Send, one split button: the word sends (⌘↩); the chevron opens send later (⇧⌘L). Never a round
/// arrow. A message given a time says Schedule.
struct MailSendSplitButton: View {
    let session: MailSession
    @ObservedObject var model: MailComposerModel
    var sendIdentifier = MailID.send
    var laterIdentifier = MailID.composerSendLater
    /// Where the box is folded: the chevron first brings the box back, then opens the times.
    var beforeLater: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button { session.sendComposer() } label: {
                Text(model.schedule == nil ? "Send" : MailScheduleCopy.schedule)
                    .font(.body.weight(.semibold))
                    .padding(.leading, DS.Space.l)
                    .padding(.trailing, model.allowsScheduling ? DS.Space.m : DS.Space.l)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .composerShortcut(.return, .command)
            .accessibilityLabel(model.schedule == nil ? "Send" : MailScheduleCopy.schedule)
            .accessibilityIdentifier(sendIdentifier)
            .help(model.schedule == nil ? "Send (\u{2318}Return)" : "Schedule (\u{2318}Return)")
            if model.allowsScheduling {
                Rectangle().fill(.white.opacity(0.6)).frame(width: 1, height: 22)
                Button {
                    beforeLater?()
                    model.toggleTimePicker()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, DS.Space.m)
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .composerShortcut("l", [.command, .shift])
                .accessibilityLabel(MailScheduleCopy.sendLater)
                .accessibilityIdentifier(laterIdentifier)
                .help("\(MailScheduleCopy.sendLater) (\u{21E7}\u{2318}L)")
            }
        }
        .foregroundStyle(.white)
        .background(DS.Palette.accent, in: Capsule())
        .fixedSize()
        .disabled(!model.isReady)
        .opacity(model.isReady ? 1 : 0.5)
    }
}

/// The draft folded into the bottom field while he reads: its first line, and Send in the field's
/// end. A tap anywhere else brings the box back with the caret in the text.
struct MailComposerFoldedField: View {
    let session: MailSession
    @ObservedObject var model: MailComposerModel
    var height: CGFloat = 52

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button { session.dock(.resume) } label: {
                Text(line)
                    .foregroundStyle(MailPlainText.isBlank(model.body) ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Draft: \(line)")
            .accessibilityHint("Resumes writing")
            .accessibilityIdentifier(MailID.composerFolded)
            MailSendSplitButton(session: session, model: model, sendIdentifier: MailID.composerFoldedSend,
                                laterIdentifier: MailID.composerFoldedSendLater,
                                beforeLater: { session.dock(.resume) })
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.xs + 2)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(MailComposerBox.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(DS.Palette.separator) }
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            session.dock(.dragEnded(translation: Double(value.predictedEndTranslation.height)))
        })
    }

    private var line: String {
        let first = MailPlainText.firstLine(model.body)
        return MailPlainText.isBlank(first) ? model.title : first
    }
}

/// A conversation's "…" › Discard draft: the composer open on it, or the draft set aside in it.
/// Gone at once, with Undo in the toast; never a question.
struct MailDiscardDraftItem: View {
    let session: MailSession
    @ObservedObject var navigation: MailNavigation

    init(session: MailSession) {
        self.session = session
        _navigation = ObservedObject(wrappedValue: session.navigation)
    }

    /// The draft set aside in the conversation open, or the one the pane shows.
    private var draft: MailDraftID? {
        (navigation.reader ?? session.pane.reader)?.conversation?.draft
    }

    var body: some View {
        if navigation.composer != nil || draft != nil {
            Button(role: .destructive) {
                if navigation.composer != nil { session.discardComposer() }
                else if let draft { session.discardKept(draft) }
            } label: { Label("Discard draft", systemImage: "trash") }
                .accessibilityIdentifier(MailID.discardDraft)
        }
    }
}

#endif
