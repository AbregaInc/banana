#if !BANANA_PUBLIC
import SwiftUI

/// The composer's header rows (MAIL-UX 6.3.1, 6.3.3): To, then Cc and Bcc once asked for, then
/// From when there is more than one address to send as, with the suggestions under the row they are
/// for. Every row completes against the people in his mail, makes chips, and takes them back to be
/// changed; "Cc Bcc" at the end of the To row asks for the other two, and so do ⇧⌘C and ⇧⌘B.
///
/// It observes the composer's model and nothing else, as the composer does.
struct MailRecipientsView: View {
    @ObservedObject var model: MailComposerModel
    var focused: FocusState<MailComposerModel.Field?>.Binding

    @State private var toSelection: TextSelection?
    @State private var ccSelection: TextSelection?
    @State private var bccSelection: TextSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(MailRecipientField.all, id: \.self) { field in
                if model.shows(field) {
                    MailRecipientRow(model: model, field: field, focused: focused, selection: selection(field))
                    if model.suggestionField == field, !model.suggestions.isEmpty {
                        MailSuggestionList(model: model)
                    }
                }
            }
            if model.showsFrom {
                MailFromRow(model: model)
            }
        }
        .background { MailRecipientShortcuts(model: model) }
        .onChange(of: model.caretToEnd) { _, _ in
            // Text was put in for him: the caret is after it.
            switch focused.wrappedValue {
            case .to: toSelection = TextSelection(insertionPoint: model.toText.endIndex)
            case .cc: ccSelection = TextSelection(insertionPoint: model.ccText.endIndex)
            case .bcc: bccSelection = TextSelection(insertionPoint: model.bccText.endIndex)
            default: break
            }
        }
    }

    private func selection(_ field: MailRecipientField) -> Binding<TextSelection?> {
        switch field {
        case .to: $toSelection
        case .cc: $ccSelection
        case .bcc: $bccSelection
        }
    }
}

/// ⇧⌘O, ⇧⌘C and ⇧⌘B (MAIL-UX 4.2.6): the caret goes to the row, which appears if it was not there.
/// Always in the tree, hidden, because the visible words are gone once the row is shown.
private struct MailRecipientShortcuts: View {
    @ObservedObject var model: MailComposerModel

    var body: some View {
        Group {
            Button("") { model.reveal(.to) }.composerShortcut("o", [.command, .shift])
            Button("") { model.reveal(.cc) }.composerShortcut("c", [.command, .shift])
            Button("") { model.reveal(.bcc) }.composerShortcut("b", [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// The words in front of a row: To, Cc, From, Subject. Their column grows with the text size, so
/// that at an accessibility size "Subject" is still one word and not one letter a line.
struct MailRowLabel: View {
    let text: String
    @ScaledMetric(relativeTo: .subheadline) private var width = DS.Mail.composerLabel

    var body: some View {
        Text(text)
            .font(.subheadline)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }
}

/// How far a list under a row is set in, to start where the row's text does: the label's column
/// at the text size in force, and the gap after it.
struct MailRowIndent: ViewModifier {
    @ScaledMetric(relativeTo: .subheadline) private var width = DS.Mail.composerLabel

    func body(content: Content) -> some View {
        content.padding(.leading, width + DS.Space.s)
    }
}

// MARK: - One row of people

private struct MailRecipientRow: View {
    @ObservedObject var model: MailComposerModel
    let field: MailRecipientField
    var focused: FocusState<MailComposerModel.Field?>.Binding
    @Binding var selection: TextSelection?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            MailRowLabel(text: field.label)
            MailFlowLayout(spacing: DS.Space.xs) {
                ForEach(model.people(in: field), id: \.address) { person in
                    MailRecipientChip(model: model, person: person)
                }
                typing
            }
            if field == .to, !model.hiddenRows.isEmpty {
                MailRevealWords(model: model)
            }
        }
    }

    private var typing: some View {
        TextField("", text: Binding(get: { model.text(of: field) }, set: { model.setText($0, of: field) }),
                  selection: $selection)
            .textFieldStyle(.plain)
            .focused(focused, equals: field.field)
            .frame(minWidth: DS.Mail.composerTyping)
            .layoutValue(key: MailFlowFills.self, value: true)
            .onSubmit { model.acceptHighlightedOrCommit(field) }
            .onKeyPress(.downArrow) {
                model.moveHighlight(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                model.moveHighlight(by: -1)
                return .handled
            }
            .onKeyPress(.tab) {
                guard !model.suggestions.isEmpty, model.suggestionField == field else { return .ignored }
                model.acceptHighlightedOrCommit(field)
                return .handled
            }
            .onKeyPress(.delete) {
                guard model.text(of: field).isEmpty, !model.people(in: field).isEmpty else { return .ignored }
                model.removeLastRecipient(from: field)
                return .handled
            }
            .accessibilityLabel(field.label)
            .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        switch field {
        case .to: MailID.composerTo
        case .cc: MailID.composerCc
        case .bcc: MailID.composerBcc
        }
    }
}

/// "Cc  Bcc" at the end of the To row: the rows that are not there yet, asked for by name.
private struct MailRevealWords: View {
    @ObservedObject var model: MailComposerModel

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(model.hiddenRows, id: \.self) { field in
                Button(field.label) { model.reveal(field) }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(MailID.composerReveal(field.label))
                    .help("\(field.label) (\u{21E7}\u{2318}\(field == .cc ? "C" : "B"))")
            }
        }
        .fixedSize()
    }
}

/// A person he is writing to: their name if he has written to them before, their address if not,
/// and a way to take them off. Choosing the name puts it back to be changed; an address that matches
/// nobody he knows has a thin outline, so it is seen to be a new one.
private struct MailRecipientChip: View {
    @ObservedObject var model: MailComposerModel
    let person: MailPerson

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Button { model.edit(person) } label: {
                Text(person.chipLabel).font(.callout).lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit")
            Button { model.remove(person) } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(person.chipLabel)")
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.hair)
        .background(Color.primary.opacity(DS.Tint.soft), in: Capsule())
        .overlay {
            if !person.isKnown {
                Capsule().strokeBorder(Color.secondary.opacity(DS.Tint.strong), lineWidth: 1)
            }
        }
        .help(person.isKnown ? person.address : "\(person.address): not someone you have written to")
        .contextMenu {
            Button("Edit") { model.edit(person) }
            ForEach(MailRecipientField.all.filter { $0 != model.field(of: person) }, id: \.self) { field in
                Button("Move to \(field.label)") { model.move(person, to: field) }
            }
            Button("Copy address") { MailClipboard.copy(person.address) }
            Button("Remove", role: .destructive) { model.remove(person) }
        }
        .accessibilityIdentifier(MailID.chip(person.address))
    }
}

/// Up to six people under a row, name and then address, the first highlighted. The people he has
/// only had mail from are by address, and say so.
private struct MailSuggestionList: View {
    @ObservedObject var model: MailComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.address) { index, person in
                Button { model.accept(person) } label: {
                    HStack(spacing: DS.Space.s) {
                        Text(person.fromTheirMail ? person.address : (person.name ?? person.address))
                            .font(.callout).lineLimit(1)
                        Text(person.fromTheirMail ? "from their mail" : person.address)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.s)
                    .frame(height: DS.Mail.oneLineRow)
                    .background(index == model.highlighted ? DS.Palette.selection : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(MailID.suggestion(person.address))
            }
        }
        .modifier(MailRowIndent())
        // A container, so each suggestion keeps its own identifier (by address) under this one.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.composerSuggestions)
    }
}

// MARK: - From

/// From: the address it goes from, and when there are others, a list of them under it. Choosing one
/// changes the signature with it. Not drawn at all when there is nothing to choose.
private struct MailFromRow: View {
    @ObservedObject var model: MailComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                MailRowLabel(text: "From")
                Button { model.isChoosingFrom.toggle() } label: {
                    HStack(spacing: DS.Space.xs) {
                        if let from = model.from {
                            Text(from.name ?? from.address).font(.callout)
                            if from.name != nil {
                                Text(from.address).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Image(systemName: model.isChoosingFrom ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("From")
                .accessibilityIdentifier(MailID.composerFrom)
            }
            if model.isChoosingFrom {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.identities, id: \.address) { identity in
                        Button { model.changeFrom(to: identity) } label: {
                            HStack(spacing: DS.Space.s) {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .opacity(identity == model.from ? 1 : 0)
                                    .frame(width: DS.Mail.glyphSlot)
                                Text(identity.name ?? identity.address).font(.callout).lineLimit(1)
                                Text(identity.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, DS.Space.s)
                            .frame(height: DS.Mail.oneLineRow)
                            .background(identity == model.from ? DS.Palette.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(MailID.composerFromChoice(identity.address))
                    }
                }
                .modifier(MailRowIndent())
            }
        }
    }
}

/// Copying an address, from a chip's menu.
enum MailClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

#endif
