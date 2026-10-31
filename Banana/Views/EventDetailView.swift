#if os(iOS)
import SwiftUI

/// Tapping an event on the phone opens this: what it is, when, where, and how to get in — Join
/// or Directions one tap away — with Edit in the corner.
///
/// Tapping used to open the edit form straight away, so joining a call from the calendar meant
/// finding the link inside an editable notes field, and an address was a text field rather
/// than a way to get there. This is the phone's version of the Mac's event drawer
/// (`MacEventInspectorView`), laid out for a thumb.
struct EventDetailView: View {
    let meeting: MeetingInfo
    /// After an edit or a reply, so the caller can refresh.
    var onChange: (() -> Void)? = nil
    /// Closes it where it isn't a sheet: the iPad's panel beside the calendar.
    var close: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var smart: SmartScheduleStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var details: GoogleCalendarEvent?
    @State private var notesText: AttributedString?
    @State private var editing = false
    @State private var askDirections = false
    /// Your reply as last chosen here — shown at once, before Google and the grid catch up.
    @State private var reply: MeetingResponse?
    /// No was chosen here: shown at once, as the sheet closes and the event leaves the day.
    @State private var declined = false
    @State private var replyError: String?

    private func finish() {
        if let close { close() } else { dismiss() }
    }

    private var calendarDot: Color {
        (details?.calendarColorHex ?? meeting.calendarID.flatMap { smart.calendarColorHex[$0] })
            .map { calendarTint($0) } ?? .secondary
    }

    var body: some View {
        Group {
            if close != nil {
                // Beside the calendar its buttons are its own: a sheet's toolbar here joins the
                // Plan's bar, which then drops the Day/Week switch for Edit and Done.
                VStack(spacing: 0) {
                    panelBar
                    Divider()
                    page
                }
                .background(Color(.systemGroupedBackground))
            } else {
                NavigationStack {
                    page
                        .navigationBarTitleDisplayMode(.inline)
                        // Done on the right, where the thumb is and where iOS puts the button that
                        // closes a sheet — it's what you tap most. Edit, the rarer step, on the left.
                        .toolbar {
                            if canEdit {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Edit") { editing = true }
                                        .accessibilityIdentifier("eventDetail.edit")
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { finish() }
                            }
                        }
                }
            }
        }
        .task(id: meeting.id) { await reload() }
        .sheet(isPresented: $editing) {
            GoogleCalendarEventView(meeting: meeting) {
                onChange?()
                finish()
            }
        }
        .confirmationDialog("Open directions in", isPresented: $askDirections, titleVisibility: .visible) {
            Button("Apple Maps") { settings.mapsProvider = .apple; openDirections(.apple) }
            Button("Google Maps") { settings.mapsProvider = .google; openDirections(.google) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pick your maps app. You can change this later in Settings.")
        }
    }

    /// Your own events in full; someone else's invitation for your alerts and show-as.
    private var canEdit: Bool { details?.canEditPersonal != false }

    /// The system's grouped list (DESIGN-SYSTEM.md, the standard): the event's name and time
    /// on the page itself, the one thing to do under it, then where and how as rows.
    private var page: some View {
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.xs, bottom: DS.Space.s, trailing: DS.Space.xs))
            if meeting.joinURL != nil || meeting.hasPhysicalLocation {
                Section { primaryAction }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            facts
            if meeting.myResponse != nil || reply != nil { rsvp }
            GettingThereView(meeting: meeting, style: .form)
            guests
            notes
            if let link = details?.htmlLink {
                Section {
                    Link(destination: link) {
                        Label("Open in Google Calendar", systemImage: "arrow.up.forward")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
    }

    /// The panel's own row: Edit on the left, Done on the right, as the sheet's toolbar has them.
    private var panelBar: some View {
        HStack {
            if canEdit {
                Button("Edit") { editing = true }
                    .accessibilityIdentifier("eventDetail.edit")
            }
            Spacer()
            Button("Done") { finish() }
                .fontWeight(.semibold)
        }
        .buttonStyle(.inline)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let calendar = details?.calendarTitle {
                HStack(spacing: DS.Space.xs + 2) {
                    Circle().fill(calendarDot).frame(width: 8, height: 8)
                    Text(calendar)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(meeting.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                // An all-day event says so, as the Mac's inspector does: this read "12 AM–12 AM".
                Text(meeting.isAllDay
                     ? AllDayEvents.timeText(from: meeting.start, to: meeting.end)
                     : TimeRangeText.compact(meeting.start, meeting.end))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.body)
        }
    }

    /// The one thing you most likely came to do: join the call, or get directions.
    @ViewBuilder private var primaryAction: some View {
        if let url = meeting.joinURL {
            Button { openURL(url) } label: {
                Label(meeting.platform.map { "Join \($0.label)" } ?? "Join meeting", systemImage: "video.fill")
            }
            .buttonStyle(.primaryPage)
            .accessibilityIdentifier("eventDetail.join")
        } else if meeting.hasPhysicalLocation {
            Button { directions() } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            .buttonStyle(.primaryPage)
            .accessibilityIdentifier("eventDetail.directions")
        }
    }

    /// Where and how, one row each: the place (its name over its address) opens directions, the
    /// link copies, the rest just says.
    @ViewBuilder private var facts: some View {
        let place = Self.place(meeting.address)
        if place != nil || meeting.joinURL != nil || details?.recurrence.detailLine(start: meeting.start) != nil || meeting.showsAsFree {
            Section {
                if let place {
                    // Tappable even beside a Join button: a hybrid meeting has both.
                    Button { directions() } label: {
                        row("mappin", title: place.name, detail: place.rest, opens: true)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { UIPasteboard.general.string = meeting.address } label: {
                            Label("Copy address", systemImage: "doc.on.doc")
                        }
                    }
                }
                if let url = meeting.joinURL {
                    Button { openURL(url) } label: {
                        row("link", title: url.host() ?? url.absoluteString, opens: true)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { UIPasteboard.general.url = url } label: {
                            Label("Copy link", systemImage: "doc.on.doc")
                        }
                    }
                }
                if let repeats = details?.recurrence.detailLine(start: meeting.start) {
                    row("repeat", title: repeats)
                        .accessibilityIdentifier("eventDetail.repeats")
                }
                if meeting.showsAsFree {
                    row("circle.dashed", title: "Shown as free")
                }
            }
        }
    }

    /// "Chelsea Piers Fitness, 62 Chelsea Piers, New York, NY 10011" → the name over the rest; an
    /// address that starts with its number stays one line.
    static func place(_ address: String?) -> (name: String, rest: String?)? {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return nil }
        guard let comma = address.range(of: ", "), address.first?.isNumber == false else { return (address, nil) }
        let rest = String(address[comma.upperBound...])
        return (String(address[..<comma.lowerBound]), rest.isEmpty ? nil : rest)
    }

    /// Yes / No / Maybe, reflected at once. Buttons, not a segmented `Picker`: tapping the answer
    /// already shown sends it again (the way to retry a reply that failed), which a picker won't.
    private var rsvp: some View {
        let current = reply ?? meeting.myResponse
        return Section {
            HStack {
                Text("Going?")
                Spacer()
                HStack(spacing: DS.Space.s) {
                    rsvpButton("Yes", .accepted, response: .accepted, current: current)
                    declineButton
                    rsvpButton("Maybe", .tentative, response: .tentative, current: current)
                }
                // Each button its own target in a list row, not the whole row.
                .buttonStyle(.borderless)
            }
        } footer: {
            if let replyError {
                Text(replyError).foregroundStyle(DS.Palette.danger)
            }
        }
    }

    /// No: the event leaves your day at once, with Undo for a few seconds, and the sheet closes —
    /// you aren't going (`InvitationReply.decline`).
    private var declineButton: some View {
        Button {
            declined = true
            reply = nil
            Task {
                await InvitationReply.decline(meeting)
                onChange?()
                try? await Task.sleep(for: .milliseconds(250))   // long enough to see it chosen
                finish()
            }
        } label: {
            Text("No").fontWeight(declined ? .semibold : .regular)
        }
        .buttonStyle(.secondarySmall)
        .tint(declined ? DS.Palette.accent : .primary)
        .disabled(declined)
        .accessibilityIdentifier("event.rsvp.no")
    }

    private func rsvpButton(_ title: String, _ rsvp: GoogleCalendarRSVP, response: MeetingResponse?,
                            current: MeetingResponse?) -> some View {
        let selected = !declined && response != nil && response == current
        return Button {
            declined = false
            if let response { reply = response }
            Task { await respond(rsvp) }
        } label: {
            Text(title).fontWeight(selected ? .semibold : .regular)
        }
        .buttonStyle(.secondarySmall)
        .tint(selected ? DS.Palette.accent : .primary)
    }

    @ViewBuilder private var guests: some View {
        if let attendees = details?.attendees, !attendees.isEmpty {
            Section("Guests \u{00B7} \(attendees.count)") {
                ForEach(attendees) { attendee in
                    HStack(spacing: DS.Space.s) {
                        statusIcon(attendee.responseStatus)
                        Text(attendee.displayName ?? attendee.email)
                            .lineLimit(1)
                        if attendee.isOrganizer {
                            Text("Organizer").font(.caption).foregroundStyle(.tertiary)
                        }
                        if attendee.isCurrentUser {
                            Text("You").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if let notesText {
            Section("Notes") {
                Text(notesText)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        }
    }

    /// A row of the sheet: its symbol in a small tile, what it is, and a chevron when it opens
    /// something.
    private func row(_ symbol: String, title: String, detail: String? = nil, opens: Bool = false) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: symbol, tint: DS.Palette.accent, style: .soft)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(title).foregroundStyle(.primary).lineLimit(2)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: DS.Space.s)
            if opens { RowChevron() }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func statusIcon(_ status: String?) -> some View {
        switch status {
        case "accepted":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
        case "declined":
            Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Palette.danger)
        case "tentative":
            Image(systemName: "questionmark.circle.fill").foregroundStyle(DS.Palette.warning)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func directions() {
        if let provider = settings.mapsProvider { openDirections(provider) } else { askDirections = true }
    }

    private func openDirections(_ provider: MapsProvider) {
        if let url = provider.directionsURL(for: meeting) { openURL(url) }
    }

    private func respond(_ rsvp: GoogleCalendarRSVP) async {
        do {
            try await InvitationReply.send(rsvp, to: meeting)
            replyError = nil
            onChange?()
        } catch {
            reply = nil
            replyError = "Couldn\u{2019}t send your reply: \(error.localizedDescription)"
        }
    }

    private func reload() async {
        guard let loaded = try? await GoogleCalendarService.shared.event(for: meeting) else { return }
        details = loaded
        let text = loaded.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        notesText = text.isEmpty ? nil : Self.linkified(text)
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bare URLs in invite notes (dial-ins, docs) become tappable.
    static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = linkDetector else { return attributed }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let attrRange = attributed.range(of: String(text[range])) else { continue }
            attributed[attrRange].link = url
        }
        return attributed
    }
}
#endif
