#if !BANANA_PUBLIC
import SwiftUI

/// "…" › Snooze. On a Mac and an iPad a submenu that lists the four times, each saying when it is,
/// so a snooze is two clicks; on a phone one row that opens the picker as a sheet (MAIL-UX 6.5).
/// `target` nil is the conversation open, or under the cursor.
struct MailSnoozeMenu: View {
    let session: MailSession
    var target: MailConversationID? = nil
    @Environment(\.layoutClass) private var layoutClass

    private var asSheet: Bool {
        #if os(macOS)
        false
        #else
        layoutClass == .compact
        #endif
    }

    var body: some View {
        let probe = MailAction.snooze(until: .distantFuture, ifNoReply: false)
        Group {
            if asSheet {
                Button { session.askToSnooze(target) } label: { Label("Snooze\u{2026}", systemImage: "clock") }
                    .accessibilityIdentifier(MailID.snoozeMenu)
            } else {
                Menu {
                    ForEach(MailTimePresets.snoozeRows(now: session.clock()), id: \.id) { preset in
                        Button {
                            // Worked out again at the click: a menu drawn a while ago keeps its words.
                            let fresh = MailTimePresets.snoozeRows(now: session.clock()).first { $0.id == preset.id }
                            session.snooze(until: (fresh ?? preset).date, on: target)
                        } label: {
                            Text(preset.title)
                            Text(MailScheduleCopy.when(preset.date, now: session.clock()))
                        }
                        .accessibilityIdentifier(MailID.snoozePreset(preset.id))
                    }
                    Divider()
                    Button("Pick a date and time\u{2026}") { session.askToSnooze(target, custom: true) }
                        .accessibilityIdentifier(MailID.snoozeCustom)
                    if session.scope.place == .mailbox(.snoozed) {
                        Button("Unsnooze") { session.unsnooze(target) }
                            .accessibilityIdentifier(MailID.unsnooze)
                    }
                } label: { Label("Snooze", systemImage: "clock") }
                .accessibilityIdentifier(MailID.snoozeMenu)
            }
        }
        .disabled(!session.canPerform(probe, on: target))
    }
}

/// Puts the snooze picker over the screen while `MailNavigation.snoozeAsk` is set.
struct MailSnoozeSheetHost: ViewModifier {
    let session: MailSession
    @ObservedObject var navigation: MailNavigation

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { navigation.snoozeAsk }, set: { if $0 == nil { session.closeSnoozePicker() } })) { ask in
            MailSnoozeSheet(session: session, ask: ask)
        }
    }
}

/// The snooze picker (MAIL-UX 6.5): the times, a field that reads a typed one ("fri 9am"), a date and
/// time of his own, and Unsnooze for a conversation that is snoozed. The first row is highlighted,
/// so `H` `↵` snoozes to Later today; `Esc`, or dismissing the sheet, changes nothing.
struct MailSnoozeSheet: View {
    let session: MailSession
    let ask: MailSnoozeAsk
    @StateObject private var picker: MailTimePickerModel
    @State private var custom: Bool
    @State private var date: Date

    init(session: MailSession, ask: MailSnoozeAsk) {
        self.session = session
        self.ask = ask
        _picker = StateObject(wrappedValue: MailTimePickerModel(snoozingAt: session.clock))
        _custom = State(initialValue: ask.custom)
        _date = State(initialValue: MailTimePresets.tomorrowMorning(now: session.clock(), calendar: .current))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if custom { customPicker } else {
                    MailTimePickerPanel(picker: picker, choose: { session.snooze(until: $0, on: ask.target) },
                                        close: { session.closeSnoozePicker() }) {
                        MailDivider(axis: .horizontal)
                        row("Pick a date and time\u{2026}", id: MailID.snoozeCustom) { custom = true }
                        if ask.isSnoozed {
                            row("Unsnooze", id: MailID.unsnooze) { session.unsnooze(ask.target) }
                        }
                    }
                }
            }
            .padding(DS.Space.m)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 420, height: custom ? 460 : 360)
        #endif
        .accessibilityIdentifier(MailID.snoozeSheet)
    }

    private func row(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.callout)
                Spacer(minLength: DS.Space.s)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: DS.Mail.oneLineRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// A date and a time of his own, from now on, in five-minute steps (what a snooze label can say).
    private var customPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(picker.title).font(.headline)
            DatePicker("", selection: $date, in: session.clock()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityIdentifier(MailID.snoozeCustomPicker)
            HStack {
                Button("Cancel") { session.closeSnoozePicker() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Snooze") { session.snooze(until: date, on: ask.target) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(date <= session.clock())
                    .accessibilityIdentifier(MailID.snoozeCustomDone)
            }
        }
    }
}

#endif
