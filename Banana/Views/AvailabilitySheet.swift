import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Share availability: pick a meeting length and a range of days, get a paragraph of open times
/// to paste into an email. Reads the timeline Banana already has — no extra calendar fetch — so
/// it opens instantly and agrees with the grid behind it.
struct AvailabilitySheet: View {
    @ObservedObject private var store = OccurrenceStore.shared
    @Environment(\.dismiss) private var dismiss

    @AppStorage("availabilityDurationMinutes") private var durationMinutes = 30
    @AppStorage("availabilityDayCount") private var dayCount = 5
    @AppStorage("availabilityDayStartMinutes") private var dayStartMinutes = 9 * 60
    @AppStorage("availabilityDayEndMinutes") private var dayEndMinutes = 18 * 60
    @AppStorage("availabilityIncludeWeekends") private var includeWeekends = false
    @AppStorage("availabilityBufferMinutes") private var bufferMinutes = 0
    @State private var copied = false

    private var request: AvailabilityRequest {
        var r = AvailabilityRequest()
        r.duration = TimeInterval(durationMinutes * 60)
        r.dayCount = dayCount
        r.dayStartMinutes = dayStartMinutes
        r.dayEndMinutes = max(dayEndMinutes, dayStartMinutes + 15)
        r.includeWeekends = includeWeekends
        r.buffer = TimeInterval(bufferMinutes * 60)
        return r
    }

    /// Busy means what write-back would advertise as busy: meetings not marked free, plus
    /// Banana's own busy blocks (travel, scheduled work). Cues, tasks and alarms are not busy.
    static func busyIntervals(in occurrences: [Occurrence]) -> [DateInterval] {
        occurrences.compactMap { occurrence in
            // A day blocked all day offers none of it.
            if occurrence.blocksWholeDay, let end = occurrence.end, end > occurrence.start {
                return DateInterval(start: occurrence.start, end: end)
            }
            guard occurrence.hasScheduledTime, !occurrence.skipped else { return nil }
            let isMeeting = occurrence.source == .external && occurrence.behavior == .event
                && !occurrence.showsAsFree
            let isOwnBusyBlock = occurrence.isWritable && occurrence.writePolicy == .busy
            guard isMeeting || isOwnBusyBlock else { return nil }
            let end = occurrence.resolvedEnd
            guard end > occurrence.start else { return nil }
            return DateInterval(start: occurrence.start, end: end)
        }
    }

    static func slots(for request: AvailabilityRequest, in occurrences: [Occurrence]) -> [DateInterval] {
        AvailabilityFinder.freeSlots(busy: busyIntervals(in: occurrences), request: request,
                                     now: Date(), calendar: .current)
    }

    private var text: String {
        AvailabilityFinder.text(for: Self.slots(for: request, in: store.occurrences),
                                request: request, timeZone: .current)
    }

    var body: some View {
        let text = self.text
        NavigationStack {
            Form {
                // The booking link first: guests pick a time themselves, live.
                Section { CopyBookingLinkButton() }
                Section {
                    Picker("Meeting length", selection: $durationMinutes) {
                        ForEach([15, 30, 45, 60, 90], id: \.self) { Text(Self.lengthLabel($0)).tag($0) }
                    }
                    Picker("Days", selection: $dayCount) {
                        Text("Next 3 days").tag(3)
                        Text("Next 5 days").tag(5)
                        Text("Next 10 days").tag(10)
                    }
                    Toggle("Include weekends", isOn: $includeWeekends)
                }
                Section("Hours") {
                    Picker("From", selection: $dayStartMinutes) {
                        ForEach(Array(stride(from: 6 * 60, through: 12 * 60, by: 30)), id: \.self) {
                            Text(Self.clockLabel($0)).tag($0)
                        }
                    }
                    Picker("Until", selection: $dayEndMinutes) {
                        ForEach(Array(stride(from: 13 * 60, through: 22 * 60, by: 30)), id: \.self) {
                            Text(Self.clockLabel($0)).tag($0)
                        }
                    }
                    Picker("Gap around meetings", selection: $bufferMinutes) {
                        Text("None").tag(0)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                    }
                }
                Section("Preview") {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("availability.preview")
                }
            }
            .editingFormStyle()
            .navigationTitle("Share availability")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "Copied" : "Copy") { copy(text) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("availability.copy")
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 560, idealHeight: 620)
        #endif
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private static func lengthLabel(_ minutes: Int) -> String {
        DS.duration(minutes: Double(minutes))
    }

    private static func clockLabel(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

#if os(macOS)
/// The Mac's share-availability panel: a right-hand drawer beside the week, like the event
/// inspector, so the times being offered are visible on the calendar while you choose them
/// (see `OfferedSlotsOverlay`). Same settings as the iPhone sheet, stored under the same keys.
struct MacAvailabilityPanel: View {
    @ObservedObject private var store = OccurrenceStore.shared
    @ObservedObject private var booking = BookingCenter.shared
    @ObservedObject private var nav = MacNavigator.shared

    @AppStorage("availabilityDurationMinutes") private var durationMinutes = 30
    @AppStorage("availabilityDayCount") private var dayCount = 5
    @AppStorage("availabilityDayStartMinutes") private var dayStartMinutes = 9 * 60
    @AppStorage("availabilityDayEndMinutes") private var dayEndMinutes = 18 * 60
    @AppStorage("availabilityIncludeWeekends") private var includeWeekends = false
    @AppStorage("availabilityBufferMinutes") private var bufferMinutes = 0

    private var request: AvailabilityRequest {
        var r = AvailabilityRequest()
        r.duration = TimeInterval(durationMinutes * 60)
        r.dayCount = dayCount
        r.dayStartMinutes = dayStartMinutes
        r.dayEndMinutes = max(dayEndMinutes, dayStartMinutes + 15)
        r.includeWeekends = includeWeekends
        r.buffer = TimeInterval(bufferMinutes * 60)
        return r
    }

    var body: some View {
        let slots = AvailabilitySheet.slots(for: request, in: store.occurrences)
        let text = AvailabilityFinder.text(for: slots, request: request, timeZone: .current)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share availability").font(.system(size: 15, weight: .semibold))
                    Text("Offered times are outlined on the calendar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { nav.showsAvailability = false } label: {
                    Image(systemName: "xmark")
                }
                .iconButton()
                .foregroundStyle(.secondary)
                .help("Close (Esc)")
            }
            .padding(DS.Space.l)

            // The booking link first: guests pick a time themselves, live.
            if booking.isAvailable, booking.shareURL != nil {
                CopyBookingLinkButton()
                    .buttonStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], DS.Space.l)
            }

            Divider()

            VStack(spacing: 0) {
                row("clock", "Length") {
                    Picker("Length", selection: $durationMinutes) {
                        ForEach([15, 30, 45, 60], id: \.self) { Text("\($0)m").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 168)
                }
                row("calendar", "Days") {
                    Picker("Days", selection: $dayCount) {
                        Text("Next 3 days").tag(3)
                        Text("Next 5 days").tag(5)
                        Text("Next 10 days").tag(10)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row("sun.max", "Hours") {
                    HStack(spacing: DS.Space.xs) {
                        clockPicker($dayStartMinutes, range: stride(from: 6 * 60, through: 12 * 60, by: 30))
                        Text("–").foregroundStyle(.secondary)
                        clockPicker($dayEndMinutes, range: stride(from: 13 * 60, through: 22 * 60, by: 30))
                    }
                }
                row("arrow.left.and.right", "Gap around meetings") {
                    Picker("Gap", selection: $bufferMinutes) {
                        Text("None").tag(0)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row("calendar.day.timeline.left", "Include weekends") {
                    Toggle("", isOn: $includeWeekends).formControls().controlSize(.small).labelsHidden()
                }
            }
            .padding(.vertical, DS.Space.xs)

            Divider()

            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.l)
                    .accessibilityIdentifier("availability.preview")
            }

            Divider()

            HStack(spacing: DS.Space.s) {
                Button("Close") { nav.showsAvailability = false }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ToastCenter.shared.notify("Times copied to clipboard")
                } label: {
                    HStack(spacing: DS.Space.s) {
                        Text("Copy times")
                        Text("⌘C").font(.caption).foregroundStyle(DS.Palette.onAccent.opacity(0.7))
                    }
                }
                .buttonStyle(.primary)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(slots.isEmpty)
                .accessibilityIdentifier("availability.copy")
            }
            .padding(DS.Space.l)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { nav.offeredSlots = slots }
        .onChange(of: slots) { _, new in nav.offeredSlots = new }
    }

    /// One setting: icon, label, control — the icon column lines every row up, as in an inspector.
    private func row(_ symbol: String, _ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label).font(.system(size: 13)).lineLimit(1).fixedSize()
            Spacer(minLength: DS.Space.s)
            control()
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 36)
    }

    private func clockPicker(_ value: Binding<Int>, range: StrideThrough<Int>) -> some View {
        Picker("", selection: value) {
            ForEach(Array(range), id: \.self) { minutes in
                let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                                 second: 0, of: Date()) ?? Date()
                Text(TimeRangeText.time(date)).tag(minutes)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
#endif
