#if os(macOS)
import AppKit
import SwiftUI

/// The right-hand event drawer: click a meeting anywhere in the planner and the desktop's
/// spare width shows the whole event — time, place, join link, notes, and every participant
/// with their RSVP state — read from Google, with Banana's Google editor one click away.
struct MacEventInspectorView: View {
    let meeting: MeetingInfo
    /// The narrow, non-observing environment reference (same key `WeekView.swift` installs at
    /// the app root) — `smart` is only read in the Google sheet's completion callback, never in
    /// `body`, so an `@EnvironmentObject` here would only buy coarse re-renders.
    @Environment(\.weekSmartStore) private var smartRef
    @ObservedObject private var nav = MacNavigator.shared

    /// The full event, fetched once per meeting. The agenda's `MeetingInfo` has times, place and
    /// join link but not notes or guests; those come from this read.
    @State private var details: GoogleCalendarEvent?
    /// Linkified once when `details` arrives rather than on every render — building an
    /// `NSDataDetector` pass per hover made the drawer feel sticky.
    @State private var notesText: AttributedString?
    @State private var editingGoogle = false

    /// Your reply as last chosen here — shown immediately, before Google and the grid catch up.
    @State private var reply: MeetingResponse?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Text(meeting.title)
                        .font(.system(size: 17, weight: .semibold))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("mac.eventInspector.title")
                    Spacer(minLength: DS.Space.s)
                    Button { nav.inspectedMeeting = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close (Esc)")
                }

                // Facts as icon rows, one column of glyphs lining everything up.
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    infoRow("clock") {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            Text(meeting.isAllDay
                                 ? AllDayEvents.timeText(from: meeting.start, to: meeting.end)
                                 : TimeRangeText.compact(meeting.start, meeting.end))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let address = meeting.address, !address.isEmpty, meeting.joinURL == nil {
                        infoRow("mappin.and.ellipse") {
                            Text(address).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if let calendarTitle = details?.calendarTitle {
                        infoRow("calendar") {
                            Text(calendarTitle).foregroundStyle(.secondary)
                        }
                    }
                    if let repeats = details?.recurrence.detailLine(start: meeting.start) {
                        infoRow("repeat") {
                            Text(repeats).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(size: 13))

                if let joinURL = meeting.joinURL {
                    Link(destination: joinURL) {
                        Label(meeting.platform.map { "Join \($0.label)" } ?? "Join meeting",
                              systemImage: "video.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .foregroundStyle(.white)
                            .background(DS.Palette.accent, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if meeting.myResponse != nil || reply != nil {
                    rsvpRow
                }

                GettingThereView(meeting: meeting)
                    .font(.system(size: 13))

                if let attendees = details?.attendees, !attendees.isEmpty {
                    section("Guests · \(attendees.count)") {
                        VStack(alignment: .leading, spacing: DS.Space.s - 2) {
                            ForEach(attendees) { attendee in
                                HStack(spacing: DS.Space.s) {
                                    statusIcon(attendee.responseStatus)
                                    Text(attendee.displayName ?? attendee.email)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                    if attendee.isOrganizer {
                                        Text("Organizer").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    if attendee.isCurrentUser {
                                        Text("You").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
                if let notesText {
                    section("Notes") {
                        // Invites are mostly links (join URL, dial-ins); keep them clickable.
                        Text(notesText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: DS.Space.m) {
                    // Your own events in full; someone else's invitation for your alerts and show-as.
                    if details?.canEditPersonal != false {
                        Button("Edit event") { editingGoogle = true }
                            .controlSize(.regular)
                    }
                    if let link = details?.htmlLink {
                        Link(destination: link) {
                            Label("Open in Google Calendar", systemImage: "arrow.up.forward")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.link)
                    }
                }
                Spacer()
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        }
        // Deliberately NOT a toolbar close button: inspector toolbar items land in the window
        // toolbar next to the view toggles, crowding them and breaking the header alignment.
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: meeting.id) { reply = nil; await reload() }
        .sheet(isPresented: $editingGoogle) {
            GoogleCalendarEventView(meeting: meeting) {
                Task {
                    await smartRef.store?.refreshAgenda()
                    await OccurrenceStore.shared.recompute()
                    nav.inspectedMeeting = nil
                }
            }
        }
    }

    /// Yes / No / Maybe, right in the panel: replying used to be reachable only as E then Y/N/M.
    private var rsvpRow: some View {
        let current = reply ?? meeting.myResponse
        return HStack(spacing: DS.Space.m) {
            Text("Going?").font(.system(size: 13, weight: .medium))
            Spacer(minLength: DS.Space.s)
            HStack(spacing: 2) {
                rsvpButton("Yes", .accepted, response: .accepted, current: current)
                rsvpButton("No", .declined, response: nil, current: current)
                rsvpButton("Maybe", .tentative, response: .tentative, current: current)
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
    }

    private func rsvpButton(_ title: String, _ rsvp: GoogleCalendarRSVP, response: MeetingResponse?,
                            current: MeetingResponse?) -> some View {
        let selected = response != nil && response == current
        return Button {
            if let response { reply = response }
            MacCommandCenter.shared.perform(.respond(rsvp))
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(minWidth: 48, minHeight: 22)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control - 2, style: .continuous))
                .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
        .help("Reply \(title) (E then \(title.prefix(1)))")
    }

    private func infoRow(_ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            content()
        }
    }

    private func reload() async {
        details = nil
        notesText = nil
        guard let loaded = try? await GoogleCalendarService.shared.event(for: meeting) else { return }
        details = loaded
        let notes = loaded.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        notesText = notes.isEmpty ? nil : linkified(notes)
    }

    @ViewBuilder private func statusIcon(_ status: String?) -> some View {
        switch status {
        case "accepted":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
        case "declined":
            Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Palette.danger)
        case "tentative":
            Image(systemName: "questionmark.circle.fill").foregroundStyle(DS.Palette.accent)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Make bare URLs in invite notes clickable.
    private func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = Self.linkDetector else { return attributed }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let attrRange = attributed.range(of: String(text[range])) else { continue }
            attributed[attrRange].link = url
        }
        return attributed
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title.uppercased())
                .font(DS.Typeface.eyebrow)
                .tracking(DS.Typeface.eyebrowTracking)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}
#endif
