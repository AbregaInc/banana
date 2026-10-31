import SwiftUI

/// Configures the calendar-driven smart wake/sleep schedule.
struct SmartScheduleView: View {
    @EnvironmentObject var store: SmartScheduleStore
    @State private var showingHomePicker = false
    @State private var showingWorkPicker = false

    var body: some View {
        List {
            Section {
                Toggle("Plan my wake and bedtime", isOn: $store.settings.enabled)
            } footer: {
                Text("Wakes you before your first meeting.")
            }

            if store.settings.enabled {
                if !store.calendarAuthorized {
                    Section {
                        Button {
                            Task { await store.requestCalendarAccess() }
                        } label: {
                            Label("Connect Google Calendar", systemImage: "calendar")
                        }
                        .tint(DS.Palette.accent)
                    }
                } else if let plan = store.plan {
                    planSection(plan)
                }

                sleepSection
                healthSection
                travelSection
                commuteSection
                wakeWindowSection
                daysOffSection
                bedtimeSection
                if store.calendarAuthorized { calendarsSection }
            }
        }
        // A List, not a Form: its switches get the form's look here, once.
        .formControls()
        // One name for this screen: Settings called it "Wake & bedtime", Routines "Smart wake
        // schedule", and its own title said "Smart Schedule".
        .navigationTitle("Wake & bedtime")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.settings.enabled { await store.recompute() } }
        .sheet(isPresented: $showingHomePicker) { HomeLocationPicker() }
        .sheet(isPresented: $showingWorkPicker) { HomeLocationPicker(kind: .work) }
        .alert(
            "Location",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { store.errorMessage = nil } },
            message: { Text(store.errorMessage ?? "") }
        )
    }

    private var healthSection: some View {
        Section {
            Toggle("Adapt to sleep & recovery", isOn: $store.settings.healthAdaptive)
            if store.settings.healthAdaptive, let note = store.healthNote {
                Label(note, systemImage: "bed.double.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Recovery")
        }
    }

    private var travelSection: some View {
        Section {
            Toggle("Account for travel time", isOn: $store.settings.accountForTravel)
            if store.settings.accountForTravel {
                Picker("Default mode", selection: $store.settings.transitMode) {
                    ForEach(TransitMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                Button {
                    showingHomePicker = true
                } label: {
                    HStack {
                        Label("Home", systemImage: "house.fill")
                        Spacer()
                        Text(store.settings.homeLabel ?? "Set…").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                Toggle("Leave-by alerts", isOn: $store.settings.leaveByAlerts)
            }
        } header: {
            Text("Travel time")
        } footer: {
            Text("In-person meetings only.")
        }
    }

    private var commuteSection: some View {
        Section {
            Toggle("Commute nudges", isOn: $store.settings.commuteAlerts)
            if store.settings.commuteAlerts {
                Stepper(value: $store.settings.commuteBufferMinutes, in: 0...30, step: 5) {
                    HStack {
                        Text("Heads-up")
                        Spacer()
                        Text("\(store.settings.commuteBufferMinutes) min before").foregroundStyle(.secondary)
                    }
                }
                Button {
                    showingWorkPicker = true
                } label: {
                    HStack {
                        Label("Work", systemImage: "briefcase.fill")
                        Spacer()
                        Text(store.settings.workLabel ?? "Set…").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                if store.settings.hasWork {
                    Button("Clear work address", role: .destructive) {
                        store.settings.workLatitude = nil; store.settings.workLongitude = nil; store.settings.workLabel = nil
                    }
                }
            }
        } header: {
            Text("Commute")
        } footer: {
            Text("Needs your home set above.")
        }
    }

    // MARK: - Sections

    private func planSection(_ plan: WakePlan) -> some View {
        let now = Date()
        let nextWake = plan.days.compactMap(\.wake).first { $0 > now }
        return Section("This week") {
            Text(plan.explanation)
                .font(.subheadline)
            ForEach(plan.days) { day in
                let isPast = (day.wake.map { $0 <= now }) ?? false
                let isNext = day.wake != nil && day.wake == nextWake
                HStack {
                    Text(day.date, format: .dateTime.weekday(.abbreviated).day())
                        .frame(width: 60, alignment: .leading)
                        .foregroundStyle(.secondary)
                    if let wake = day.wake {
                        Label(wake.formatted(date: .omitted, time: .shortened),
                              systemImage: isPast ? "checkmark.circle" : "alarm")
                            .foregroundStyle(isPast ? .secondary : .primary)
                            .strikethrough(isPast, color: .secondary)
                    } else {
                        Text("No alarm").foregroundStyle(.secondary)
                    }
                    if isNext {
                        Tag(text: "NEXT", tint: DS.Palette.accent)
                    }
                    Spacer()
                    if let meeting = day.firstMeeting {
                        Text(meeting.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .opacity(isPast ? 0.55 : 1)
            }
        }
    }

    private var sleepSection: some View {
        Section("Sleep") {
            Stepper(value: $store.settings.sleepTargetMinutes, in: 300...600, step: 15) {
                labeledValue("Sleep target", duration(store.settings.sleepTargetMinutes))
            }
            Stepper(value: $store.settings.prepBufferMinutes, in: 0...180, step: 15) {
                labeledValue("Wake before meeting", duration(store.settings.prepBufferMinutes))
            }
            Stepper(value: $store.settings.fallAsleepMinutes, in: 0...60, step: 5) {
                labeledValue("Time to fall asleep", duration(store.settings.fallAsleepMinutes))
            }
        }
    }

    private var wakeWindowSection: some View {
        Section {
            TimeField("Earliest routine wake", selection: ClockTime.binding($store.settings.earliestWakeMinutes))
            TimeField("Default wake (no meetings)", selection: ClockTime.binding($store.settings.defaultWakeMinutes))
        } header: {
            Text("Wake window")
        }
    }

    private var daysOffSection: some View {
        Section("Days without meetings") {
            Picker("On off days", selection: $store.settings.weekendMode) {
                ForEach(WeekendMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if store.settings.weekendMode == .later {
                Stepper(value: $store.settings.offDayShiftMinutes, in: 15...240, step: 15) {
                    labeledValue("Sleep in by", duration(store.settings.offDayShiftMinutes))
                }
            }
        }
    }

    private var bedtimeSection: some View {
        Section("Bedtime") {
            Toggle("Bedtime reminder", isOn: $store.settings.bedtimeRemindersEnabled)
            if store.settings.bedtimeRemindersEnabled {
                Toggle("Wind-down nudge (30 min before)", isOn: $store.settings.windDownEnabled)
            }
        }
    }

    private var calendarsSection: some View {
        Section {
            ForEach(store.availableCalendars) { cal in
                Toggle(cal.title, isOn: calendarBinding(cal.id))
            }
        } header: {
            Text("Calendars counted")
        } footer: {
            Text("All-day events, declined invites, and events marked Free are always ignored.")
        }
    }

    // MARK: - Helpers

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func duration(_ minutes: Int) -> String { DS.duration(minutes: Double(minutes)) }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !store.settings.excludedCalendarIDs.contains(id) },
            set: { included in
                if included { store.settings.excludedCalendarIDs.remove(id) }
                else { store.settings.excludedCalendarIDs.insert(id) }
            }
        )
    }
}
