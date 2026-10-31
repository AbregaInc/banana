#if !BANANA_PUBLIC
import SwiftUI

extension EnvironmentValues {
    /// The session behind the Mail screen, for what a card does that no list does: a scheduled
    /// message's own buttons. Set once, where the screen is made.
    @Entry var mailSession: MailSession? = nil
}

/// A scheduled message's card says when it will go, and what can be done to it (MAIL-UX 6.3.6, 7.7):
/// edit it, change the time, send it now, or cancel the schedule and have a draft again. A late
/// one says so, warns, and asks: send now, or keep it as a draft. Nothing here is a question
/// that stops him: every button acts at once and has its Undo.
struct MailScheduledBanner: View {
    let scheduled: MailMessageDisplay.Scheduled

    @Environment(\.mailSession) private var session
    @State private var picker: MailTimePickerModel?

    /// "Scheduled · Thu 8:00 AM · from this Mac", or the late state: who sends it is the copy's.
    private var line: String {
        let holder = MailScheduleCopy.Holder.thisDevice(name: session?.deviceName ?? "")
        return scheduled.isLate ? MailScheduleCopy.lateMarker(when: scheduled.when, holder: holder)
            : MailScheduleCopy.marker(when: scheduled.when, holder: holder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: scheduled.isLate ? "exclamationmark.triangle.fill" : "clock")
                    .foregroundStyle(scheduled.isLate ? DS.Palette.warning : DS.Palette.info)
                Text(line).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            if let session {
                // A grid, so the buttons are one width and a row of them cannot be measured wrong.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Mail.actionButton), spacing: DS.Space.s)],
                          alignment: .leading, spacing: DS.Space.s) {
                    ForEach(buttons, id: \.title) { button in
                        Button { button.act(session) } label: {
                            Text(button.title).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(button.isMain ? DS.Palette.accent : nil)
                        .controlSize(.small)
                        .accessibilityIdentifier(button.identifier)
                    }
                }
                if let picker {
                    MailTimePickerPanel(picker: picker, choose: { date in
                        session.reschedule(scheduled.draft, from: scheduled.at, to: date)
                        self.picker = nil
                    }, close: { self.picker = nil })
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((scheduled.isLate ? DS.Palette.warning : DS.Palette.info).opacity(DS.Tint.soft),
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.scheduledBanner)
    }

    private struct Choice {
        var title: String
        var identifier: String
        var isMain = false
        var act: @MainActor (MailSession) -> Void
    }

    /// Late: send it or keep it. Waiting: change it, send it, or cancel it.
    private var buttons: [Choice] {
        let draft = scheduled.draft
        let edit = Choice(title: MailScheduleCopy.edit, identifier: MailID.scheduledEdit) {
            $0.editScheduled(draft)
        }
        let change = Choice(title: MailScheduleCopy.reschedule, identifier: MailID.scheduledReschedule) { session in
            picker = picker == nil
                ? MailTimePickerModel(now: session.clock, holder: .thisDevice(name: session.deviceName)) : nil
        }
        let now = Choice(title: MailScheduleCopy.sendNow, identifier: MailID.scheduledSendNow,
                          isMain: scheduled.isLate) { $0.sendScheduledNow(draft) }
        if scheduled.isLate {
            let keep = Choice(title: MailScheduleCopy.keepAsDraft, identifier: MailID.scheduledKeep) {
                $0.keepAsDraft(draft)
            }
            return [now, keep, change, edit]
        }
        let cancel = Choice(title: MailScheduleCopy.cancel, identifier: MailID.scheduledCancel) {
            [at = scheduled.at] in $0.cancelSchedule(draft, at: at)
        }
        return [edit, change, now, cancel]
    }
}

#endif
