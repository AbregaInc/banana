import SwiftUI
#if os(macOS)
import AppKit
#endif

// The new-reminder sheet and its list picker, shared by every device. (It lived in the retired
// Today screen's file.)

/// Creates the task where Banana already reads tasks: the person's default Apple Reminders list.
/// A time makes it immediately eligible for calendar write-back; a day-only task waits in the
/// reminders line above the day.
struct NewTaskSheet: View {
    @EnvironmentObject private var occurrences: OccurrenceStore
    @EnvironmentObject private var smart: SmartScheduleStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var hasTime = true
    @State private var day: Date
    @State private var time: Date
    @AppStorage("taskAuthoringDurationMinutes")
    private var durationMinutes = TaskDurationStore.defaultMinutes
    @State private var notes = ""
    @State private var priority = 0
    @State private var recurrence: CalendarItemRecurrence = .never
    /// Due around a moment rather than only at its time — after your workout (`ReminderAnchors`).
    @State private var anchor: TimingAnchor?
    @State private var recurrenceHasEnd = false
    @State private var recurrenceEnd = Date()
    @State private var lists: [RemindersService.ReminderListInfo] = []
    @State private var listID: String?
    @AppStorage("taskAuthoringLastListID") private var lastListID = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var loading = false
    @FocusState private var titleFocused: Bool
    private let reminderID: String?
    /// Reminders has nothing under this id (deleted elsewhere since the plan last read): said as
    /// that, not as a save that failed.
    @State private var couldNotOpen = false
    /// The preview's made-up reminders aren't in Reminders; the sheet shows what the plan knows.
    private var isPreviewSample: Bool {
        #if DEBUG
        reminderID?.hasPrefix("preview-") == true
        #else
        false
        #endif
    }
    /// Opened from the plan: whether it's done, and what ticks it (`TaskTick`).
    private let tick: (done: Bool, toggle: () -> Void)?
    /// A repeating reminder's missed instances ("Missed yesterday"), and "Missed it" for an
    /// overdue one (`OccurrenceStore.markMissed`).
    struct Missed {
        var note: String?
        var markMissed: (() -> Void)?

        /// For a reminder on the plan; nil when there's nothing to say or do.
        @MainActor init?(_ occurrence: Occurrence) {
            guard !occurrence.completed, occurrence.missed != nil || occurrence.canBeMarkedMissed else { return nil }
            note = occurrence.missed?.text
            markMissed = occurrence.canBeMarkedMissed
                ? { Task { await OccurrenceStore.shared.markMissed(occurrence) } } : nil
        }
    }
    private let missed: Missed?

    /// `initialDue` lets a caller that already knows the time — the week grid's "new reminder
    /// here" — open the sheet on that slot instead of an hour from now.
    /// - Parameter title: the reminder's title as the plan shows it, so the sheet opens with it
    ///   already there to read (and still has it if Reminders can't be read).
    init(reminderID: String? = nil, initialDue: Date? = nil, title: String? = nil,
         tick: (done: Bool, toggle: () -> Void)? = nil, missed: Missed? = nil) {
        self.reminderID = reminderID
        self.tick = tick
        self.missed = missed
        if let title { _title = State(initialValue: title) }
        // An hour from now lands on an arbitrary minute (14:37). Seed the grid the picker
        // steps on, so the default offered is 15:00 and not something only typing could reach.
        let initial = FiveMinuteGrid.snapped(
            initialDue ?? Date().addingTimeInterval(3_600))
        _day = State(initialValue: initial)
        _time = State(initialValue: initial)
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var due: Date {
        let calendar = Calendar.current
        guard hasTime else { return calendar.startOfDay(for: day) }
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        let exact = calendar.date(
            bySettingHour: clock.hour ?? 9,
            minute: clock.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
        // The five-minute grid is the product rule, not just the iOS picker's step: the Mac
        // still uses a plain minute picker, and an off-grid due date can arrive from a
        // reminder authored in Apple Reminders.
        return FiveMinuteGrid.snapped(exact)
    }

    private var selectedList: RemindersService.ReminderListInfo? {
        lists.first { $0.id == listID }
    }

    private var conflicts: [Occurrence] {
        guard hasTime else { return [] }
        return schedulingConflicts(
            in: occurrences,
            from: due,
            to: due.addingTimeInterval(TimeInterval(durationMinutes * 60))
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // On as many lines as it needs: this is where a reminder too long for its
                    // chip or its block is read.
                    TextField("What needs doing?", text: $title, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($titleFocused)
                        .accessibilityIdentifier("task.title")
                    if let selectedList {
                        NavigationLink {
                            ReminderDestinationPicker(lists: lists, selection: $listID)
                        } label: {
                            LabeledContent("List") {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(selectedList.title).foregroundStyle(.primary)
                                    Text(selectedList.sourceTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("task.list.destination")
                    } else {
                        LabeledContent("List") {
                            Text("Default").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Reminder")
                }

                if let tick {
                    // Read here, ticked here: where a block is too narrow to carry its own circle
                    // (a phone's week), this is the tick.
                    Section {
                        Button {
                            dismiss()
                            tick.toggle()
                        } label: {
                            Label(tick.done ? "Mark as not done" : "Mark as done",
                                  systemImage: tick.done ? "checkmark.circle.fill" : "circle")
                        }
                        .accessibilityIdentifier("task.tick")
                        if let markMissed = missed?.markMissed {
                            Button {
                                dismiss()
                                markMissed()
                            } label: {
                                Label("Missed it", systemImage: "xmark.circle")
                            }
                            .accessibilityIdentifier("task.missed")
                        }
                    } footer: {
                        if let note = missed?.note { Text(note) }
                    }
                }

                Section {
                    Toggle("Schedule a time", isOn: $hasTime)
                    if reminderID == nil {
                        DatePicker(
                            "Date",
                            selection: $day,
                            in: Calendar.current.startOfDay(for: Date())...,
                            displayedComponents: .date
                        )
                    } else {
                        DatePicker("Date", selection: $day, displayedComponents: .date)
                    }
                    if hasTime {
                        TimeField("Time", selection: $time)
                    }
                    Picker("Reserve", selection: $durationMinutes) {
                        ForEach(TaskDurationStore.options, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .accessibilityIdentifier("task.duration")
                    Picker("Priority", selection: $priority) {
                        Text("None").tag(0)
                        Text("High").tag(1)
                        Text("Medium").tag(5)
                        Text("Low").tag(9)
                    }
                    .accessibilityIdentifier("task.priority")
                    Picker("Repeat", selection: $recurrence) {
                        ForEach(CalendarItemRecurrence.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .accessibilityIdentifier("task.recurrence")
                } header: {
                    Text("When")
                } footer: {
                    Text(
                        hasTime
                            ? (smart.settings.reserveTaskTime
                                ? "Saved to Apple Reminders. Banana reserves every timed occurrence in your calendar by default."
                                : "Saved to Apple Reminders. Shows on your Banana timeline only — calendar reservations for reminders are off in Settings.")
                            : "Saved to Apple Reminders without a time. It waits in the line above today until you give it one."
                    )
                }

                if recurrence != .never {
                    Section {
                        TimingFields(anchor: $anchor, time: $time, others: anchorChoices, showsOwnTime: false)
                    } header: {
                        Text("Due around")
                    } footer: {
                        Text(anchor == nil
                             ? "Tie it to a moment \u{2014} after your workout, before breakfast \u{2014} and it\u{2019}s due then, not late before."
                             : "Its time above is when it\u{2019}s due on days the moment doesn\u{2019}t come. Banana moves it in Reminders on the day.")
                    }
                }

                if !conflicts.isEmpty {
                    AuthoringConflictSection(conflicts: conflicts)
                }


                Section("Notes") {
                    NotesField(title: "Notes", text: $notes)
                        .accessibilityIdentifier("task.notes")
                }
            }
            .editingFormStyle()
            .navigationTitle(reminderID == nil ? "New reminder" : "Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(cleanTitle.isEmpty || saving || loading)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .interactiveDismissDisabled(saving)
            .alert(reminderID == nil ? "Couldn’t create reminder" : (couldNotOpen ? "Couldn’t open reminder" : "Couldn’t save reminder"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                lists = occurrences.writableReminderLists
                if let reminderID {
                    loading = true
                    if let draft = occurrences.editableTask(reminderID) {
                        title = draft.title
                        notes = draft.notes
                        hasTime = draft.hasTime
                        day = draft.due
                        time = FiveMinuteGrid.snapped(draft.due)
                        priority = draft.priority
                        recurrence = draft.recurrence
                        anchor = ReminderAnchors.shared.anchor(externalID: externalID(of: reminderID), title: draft.title)
                        // Tied, today's due may have moved to its moment: the time shown is its own.
                        if anchor != nil, let usual = ReminderAnchors.shared.usualMinutes(
                            externalID: externalID(of: reminderID), title: draft.title),
                           let own = Calendar.current.date(bySettingHour: usual / 60, minute: usual % 60, second: 0, of: draft.due) {
                            time = own
                        }
                        durationMinutes = TaskDurationStore.shared.minutes(for: reminderID)
                        listID = lists.first(where: { $0.id == draft.listID })?.id
                            ?? lists.first(where: \.isDefault)?.id
                            ?? lists.first?.id
                    } else if !isPreviewSample {
                        couldNotOpen = true
                        errorMessage = "This reminder no longer exists."
                    }
                    loading = false
                } else {
                    listID = lists.first(where: { $0.id == lastListID })?.id
                        ?? lists.first(where: \.isDefault)?.id
                        ?? lists.first?.id
                    titleFocused = true
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !cleanTitle.isEmpty else { return }
        saving = true
        Task {
            do {
                if let reminderID {
                    try await occurrences.updateTask(
                        reminderID: reminderID,
                        title: cleanTitle,
                        due: due,
                        hasTime: hasTime,
                        durationMinutes: durationMinutes,
                        listID: listID,
                        notes: notes,
                        priority: priority,
                        recurrence: recurrence
                    )
                } else {
                    try await occurrences.createTask(
                        title: cleanTitle,
                        due: due,
                        hasTime: hasTime,
                        durationMinutes: durationMinutes,
                        listID: listID,
                        notes: notes,
                        priority: priority,
                        recurrence: recurrence
                    )
                }
                if let listID { lastListID = listID }
                saveAnchor()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }
}

extension NewTaskSheet {
    /// What a reminder could be due around besides the usual moments: other repeating reminders,
    /// and Taken items.
    var anchorChoices: [TimingAnchor.Moment] {
        var seen = Set<String>()
        let reminders = occurrences.occurrences
            .filter { $0.behavior == .task && $0.reminderID != reminderID && $0.title.lowercased() != cleanTitle.lowercased() }
            .compactMap { occurrence -> TimingAnchor.Moment? in
                guard seen.insert(occurrence.title.lowercased()).inserted else { return nil }
                return .reminder(id: occurrence.reminderExternalID ?? occurrence.title, title: occurrence.title)
            }
        return reminders + AnchoredTimingHub.otherMoments(excluding: nil, supplements: WellnessStore.shared.supplements)
    }

    func externalID(of reminderID: String) -> String? {
        occurrences.occurrences.first { $0.reminderID == reminderID }?.reminderExternalID
    }

    /// Ties it (or unties it) in `ReminderAnchors`, with its time of day as what it's due at otherwise.
    func saveAnchor() {
        let rules = ReminderAnchors.shared
        let external = reminderID.flatMap(externalID(of:))
        let had = rules.anchor(externalID: external, title: cleanTitle) != nil
        guard anchor != nil || had else { return }
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        rules.set(recurrence == .never ? nil : anchor, externalID: external, title: cleanTitle,
                  usualMinutes: hasTime ? (clock.hour ?? 20) * 60 + (clock.minute ?? 0) : nil)
    }
}

private struct ReminderDestinationPicker: View {
    let lists: [RemindersService.ReminderListInfo]
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss

    private struct Account: Identifiable {
        let id: String
        let title: String
        let lists: [RemindersService.ReminderListInfo]
    }

    private var accounts: [Account] {
        Dictionary(grouping: lists, by: \.sourceID)
            .map { sourceID, lists in
                Account(
                    id: sourceID,
                    title: lists.first?.sourceTitle.isEmpty == false
                        ? lists.first!.sourceTitle : "On My Device",
                    lists: lists.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                )
            }
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    var body: some View {
        List {
            ForEach(accounts) { account in
                Section(account.title) {
                    ForEach(account.lists) { list in
                        Button {
                            selection = list.id
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(DS.Palette.accent)
                                Text(list.title).foregroundStyle(.primary)
                                Spacer()
                                if selection == list.id {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(DS.Palette.accent)
                                }
                            }
                        }
                        .accessibilityLabel("\(list.title), \(account.title)")
                    }
                }
            }
        }
        .navigationTitle("Reminders list")
        .navigationBarTitleDisplayMode(.inline)
    }
}
