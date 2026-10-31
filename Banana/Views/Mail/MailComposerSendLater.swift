#if !BANANA_PUBLIC
import SwiftUI

/// The clock beside Send (MAIL-UX 6.3.6): it opens the time picker, and ⇧⌘L does. Choosing a time
/// changes Send to Schedule and says when it will go.
struct MailSendLaterButton: View {
    @ObservedObject var model: MailComposerModel

    var body: some View {
        Button { model.toggleTimePicker() } label: {
            Image(systemName: model.schedule == nil ? "clock" : "clock.fill")
                .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .composerShortcut("l", [.command, .shift])
        .disabled(!model.isReady)
        .accessibilityLabel(MailScheduleCopy.sendLater)
        .accessibilityIdentifier(MailID.composerSendLater)
        .help("\(MailScheduleCopy.sendLater) (\u{21E7}\u{2318}L)")
    }
}

/// What sits above the footer when a time is being chosen, or has been: the picker, and the line
/// that reads the time back.
struct MailSendLaterPanel: View {
    @ObservedObject var model: MailComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let picker = model.timePicker {
                MailTimePickerPanel(picker: picker, choose: { model.chooseSchedule($0) },
                                    close: { model.toggleTimePicker() })
            }
            if let line = model.scheduleLine {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "clock").foregroundStyle(DS.Palette.info)
                    Text(line).font(.callout).monospacedDigit()
                    Spacer(minLength: 0)
                    Button { model.clearSchedule() } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: DS.Mail.glyphSlot, height: DS.Mail.glyphSlot)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(MailScheduleCopy.clear)
                    .accessibilityIdentifier(MailID.composerScheduleClear)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(MailID.composerSchedule)
            }
        }
    }
}

/// The time picker (MAIL-UX 6.5): a field that reads what is typed ("fri 9am", "in 2 hours"), and
/// a few times to take without typing, each saying when it is. Here it is a panel in the composer,
/// not an overlay: the same under a keyboard on a phone as on a Mac. `↑` `↓` move, `↵` takes the
/// highlighted time, `Esc` shuts the picker and nothing else.
struct MailTimePickerPanel: View {
    @ObservedObject var picker: MailTimePickerModel
    let choose: (Date) -> Void
    let close: () -> Void

    @Environment(\.layoutClass) private var layoutClass
    @FocusState private var isTyping: Bool

    /// The Mac always has a keyboard in hand, and sets no `layoutClass` (it is the touch shells'),
    /// so the width test that keeps a phone's caret out of the field would keep the Mac's out too.
    private var takesTheCaret: Bool {
        #if os(macOS)
        true
        #else
        layoutClass == .regular
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                TextField(MailScheduleCopy.pickerPrompt, text: $picker.text)
                    .textFieldStyle(.plain)
                    .focused($isTyping)
                    .onSubmit { if let date = picker.chosen() { choose(date) } }
                    .onKeyPress(.downArrow) {
                        picker.moveHighlight(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        picker.moveHighlight(by: -1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        close()
                        return .handled
                    }
                    .accessibilityLabel(MailScheduleCopy.pickerTitle)
                    .accessibilityIdentifier(MailID.timePickerField)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: DS.Row.minHeight)
            MailDivider(axis: .horizontal)
            if picker.isPast {
                Text(MailScheduleCopy.inThePast)
                    .font(.callout).foregroundStyle(DS.Palette.danger)
                    .padding(.horizontal, DS.Space.m)
                    .frame(height: DS.Mail.oneLineRow, alignment: .leading)
                    .accessibilityIdentifier(MailID.timePickerPast)
            }
            ForEach(Array(picker.rows.enumerated()), id: \.element.id) { index, row in
                Button { choose(row.date) } label: {
                    HStack(spacing: DS.Space.s) {
                        Text(row.title).font(.callout).lineLimit(1)
                        Spacer(minLength: DS.Space.s)
                        Text(row.time).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DS.Space.m)
                    .frame(height: DS.Mail.oneLineRow)
                    .background(index == picker.highlighted && !picker.isPast ? DS.Palette.selection : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(MailID.timePickerRow(row.id))
            }
            MailDivider(axis: .horizontal)
            // Who sends it, and when: `MailScheduleCopy` says, for the time under the highlight.
            Text(picker.note)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Space.m)
        }
        .background(Color.primary.opacity(DS.Tint.wash),
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Palette.separator)
        }
        // A thumb takes a time from the list; the keyboard is for a hand that is already typing.
        // The field is made in the update that opens the picker, so on the Mac the first assignment
        // finds nothing to focus: it is chased until the field has the caret (`MailCaretChase`).
        .task {
            guard takesTheCaret else { return }
            isTyping = true
            await MailCaretChase.run(isWanted: { !Task.isCancelled }, isThere: { isTyping },
                                     ask: { isTyping = true }, landed: {})
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.timePicker)
    }
}

#endif
