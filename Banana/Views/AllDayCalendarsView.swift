import SwiftUI

/// Calendar inclusion is independent of whether the wake/bedtime planner is enabled.
struct IndividualCalendarsView: View {
    @EnvironmentObject private var smart: SmartScheduleStore
    @ObservedObject private var google = GoogleCalendarService.shared

    var previewCalendars: [GoogleCalendar]? = nil

    private var calendars: [GoogleCalendar] {
        (previewCalendars ?? google.calendars).filter { !$0.isDeleted && !$0.isHidden }
    }

    private var accounts: [String] {
        Set(calendars.map(\.accountEmail)).sorted()
    }

    private enum Control: String, CaseIterable { case visibility = "Visibility", notifications = "Notifications" }
    @State private var control: Control = .visibility

    var body: some View {
        Form {
            Section {
                Picker("Calendar control", selection: $control) {
                    ForEach(Control.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("calendars.control")
            } footer: {
                Text(control == .visibility
                     ? "Choose which calendars appear in Banana and count toward your availability."
                     : "Choose which calendars can notify you. Hidden calendars do not send notifications.")
            }
            if calendars.isEmpty {
                Section {
                    Text(google.isConnected ? "No calendars loaded. Refresh to try again." : "Connect a Google account to choose its calendars.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(accounts, id: \.self) { account in
                Section {
                    ForEach(calendars.filter { $0.accountEmail == account }
                        .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }) { calendar in
                        calendarRow(calendar)
                    }
                } header: {
                    Text(verbatim: account.isEmpty ? "Calendars" : account)
                }
            }
            Section {} footer: {
                Text("These choices sync across your devices. Other calendar apps keep their own notification settings.")
            }
            if google.isConnected {
                Section {
                    Button("Refresh calendars") {
                        Task {
                            await google.refresh()
                            await smart.refreshCalendarAuthorization()
                        }
                    }
                    .disabled(google.isWorking)
                    if let error = google.lastError {
                        Text(error).font(.footnote).foregroundStyle(DS.Palette.danger)
                    }
                }
            }
        }
        .settingsFormStyle()
        .navigationTitle("Calendar visibility")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func calendarRow(_ calendar: GoogleCalendar) -> some View {
        let included = inclusion(calendar).wrappedValue
        let selected = control == .visibility ? included : included && notifications(calendar).wrappedValue
        let disabled = control == .notifications && !included
        return Button {
            if control == .visibility { inclusion(calendar).wrappedValue.toggle() }
            else { notifications(calendar).wrappedValue.toggle() }
        } label: {
            HStack(spacing: 12) {
                Circle().fill(calendarColor(calendar)).frame(width: 12, height: 12)
                Text(calendar.displayTitle).foregroundStyle(disabled ? .secondary : .primary)
                Spacer()
                if disabled {
                    Text("Hidden").font(.subheadline).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(calendar.displayTitle)
        .accessibilityValue(control == .visibility ? (included ? "Shown" : "Hidden") : (selected ? "Notifications on" : "Notifications off"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("calendars.\(control == .visibility ? "include" : "notify").\(calendar.id)")
    }

    private func calendarColor(_ calendar: GoogleCalendar) -> Color {
        guard let hex = calendar.backgroundColor?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              let value = UInt32(hex, radix: 16), hex.count == 6 else { return .accentColor }
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    private func notifications(_ calendar: GoogleCalendar) -> Binding<Bool> {
        Binding(
            get: { !smart.settings.mutedCalendarIDs.contains(calendar.id) },
            set: { enabled in
                if enabled { smart.settings.mutedCalendarIDs.remove(calendar.id) }
                else { smart.settings.mutedCalendarIDs.insert(calendar.id) }
            })
    }

    private func inclusion(_ calendar: GoogleCalendar) -> Binding<Bool> {
        let id = GoogleCalendarService.calendarInfoID(calendar.id)
        return Binding(
            get: { !smart.settings.excludedCalendarIDs.contains(id) },
            set: { included in
                if included { smart.settings.excludedCalendarIDs.remove(id) }
                else { smart.settings.excludedCalendarIDs.insert(id) }
            })
    }
}

/// Settings › Accounts & calendars › All-day events: whose all-day events show (`AllDayEvents`).
/// Yours are on unless switched off; shared and subscribed calendars (a partner's, rocket
/// launches, holidays) are off unless switched on. Whether one blocks the day is its own Busy or
/// Free, not this.
struct AllDayCalendarsView: View {
    @EnvironmentObject private var smart: SmartScheduleStore
    @ObservedObject private var google = GoogleCalendarService.shared

    private var readable: [GoogleCalendar] {
        google.calendars.filter { !$0.isDeleted && !$0.isHidden
            && !smart.settings.excludedCalendarIDs.contains(GoogleCalendarService.calendarInfoID($0.id)) }
    }

    var body: some View {
        Form {
            let owned = readable.filter { $0.accessRole == "owner" }
            let others = readable.filter { $0.accessRole != "owner" }
            if !owned.isEmpty {
                Section {
                    ForEach(owned, id: \.id) { toggle($0, isOwner: true) }
                } header: {
                    Text("Your calendars")
                } footer: {
                    Text("Invitations you accept land here too. Working-location markers (\u{201C}Home\u{201D}, \u{201C}Office\u{201D}) never show.")
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.id) { toggle($0, isOwner: false) }
                } header: {
                    Text("Shared and subscribed")
                } footer: {
                    Text("Off unless you turn one on: someone else\u{2019}s days, launches and holidays aren\u{2019}t yours.")
                }
            }
            Section {
                Toggle("Birthdays", isOn: $smart.settings.showsBirthdays)
                    .accessibilityIdentifier("allDay.birthdays")
            } footer: {
                Text("Your contacts\u{2019} birthdays from Google. Hide just one from its menu: Hide in Banana.")
            }
            let hidden = smart.settings.allDayHiddenTitles.sorted()
            if !hidden.isEmpty {
                Section {
                    ForEach(hidden, id: \.self) { title in
                        HStack {
                            Text(title.capitalizedFirst).lineLimit(1)
                            Spacer()
                            Button("Show") { smart.settings.allDayHiddenTitles.remove(title) }
                                .buttonStyle(.inline)
                        }
                    }
                } header: {
                    Text("Hidden")
                } footer: {
                    Text("Hidden here, still in Google. Show brings one back.")
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("An all-day event marked Busy blocks its day \u{2014} here, in what you share, and on your other calendars, which is what Calendly reads. Google makes all-day events Free, so most only show; open one and choose Block this day.")
            }
        }
        .settingsFormStyle()
        .navigationTitle("All-day events")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func toggle(_ calendar: GoogleCalendar, isOwner: Bool) -> some View {
        Toggle(isOn: Binding(
            get: {
                AllDayEvents.shows(calendarID: calendar.id, isOwner: isOwner,
                                   hidden: smart.settings.allDayHiddenCalendarIDs,
                                   shown: smart.settings.allDayShownCalendarIDs)
            },
            set: { on in
                if isOwner {
                    if on { smart.settings.allDayHiddenCalendarIDs.remove(calendar.id) }
                    else { smart.settings.allDayHiddenCalendarIDs.insert(calendar.id) }
                } else {
                    if on { smart.settings.allDayShownCalendarIDs.insert(calendar.id) }
                    else { smart.settings.allDayShownCalendarIDs.remove(calendar.id) }
                }
            })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(calendar.displayTitle).lineLimit(1)
                if !calendar.accountEmail.isEmpty, calendar.accountEmail != calendar.displayTitle {
                    Text(calendar.accountEmail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("allDay.calendar.\(calendar.id)")
    }
}
