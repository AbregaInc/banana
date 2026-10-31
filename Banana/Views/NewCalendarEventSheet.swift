import SwiftUI
#if os(macOS)
import AppKit
#endif

// The new-event sheet, its calendar picker and guest avatar: the same sheet on the phone, the
// iPad and the Mac. (It lived in the retired Today screen's file.)

/// Creates a real event in a writable Apple Calendar destination. Unlike a task, this item owns
/// a fixed start and end and has no completion state.
struct NewCalendarEventSheet: View {
    @EnvironmentObject private var occurrences: OccurrenceStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var eventStart: Date
    @State private var eventEnd: Date
    @State private var isAllDay = false
    @State private var location = ""
    @State private var structuredLocation: CalendarEventLocation?
    @State private var videoCallLink = ""
    @State private var notes = ""
    @AppStorage("eventAuthoringAvailability") private var availability: CalendarEventAvailability = .busy
    @AppStorage("eventAuthoringAlertMinutes") private var alertMinutesBefore = 10
    @AppStorage("eventAuthoringSecondAlertMinutes") private var secondaryAlertMinutesBefore = -1
    @AppStorage("eventAuthoringLastCalendarID") private var lastCalendarID = ""
    /// Shared with the event editor (`RepeatPicker`): weekly on several days, custom, an end.
    @State private var recurrence: EventRecurrence = .none
    @State private var calendars: [CalendarSourceInfo] = []
    @State private var templates: [CalendarEventTemplate] = []
    @State private var calendarID: String?
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool
    /// Filling the form in from the words typed as the title (`EventPhrase`), and the form as it
    /// was before, for Undo.
    @State private var filling = false
    @State private var beforeFill: FilledFields?
    /// The title as Fill in left it: "Lunch with Sam" still names Sam, but that's been read.
    @State private var filledTitle: String?
    /// An end set together with a new start (Fill in, Undo): kept when the start's change lands,
    /// instead of being shifted along with it.
    @State private var pendingEnd: Date?
    /// Who it's with. Google emails each an invitation when the event is saved.
    @State private var guests: [GuestPerson] = []
    @State private var guestQuery = ""
    /// Everyone it could be with (`GuestSources`), favourites first when matched.
    @State private var people: [GuestPerson] = []
    /// Names typed that fit more than one person — "Which Sam?" — or no one.
    @State private var askingWhich: [GuestQuestion] = []
    /// The words each guest was chosen for, remembered on Save (`GuestPicks`).
    @State private var chosenFor: [String: String] = [:]

    private struct FilledFields {
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String
        var structuredLocation: CalendarEventLocation?
        var recurrence: EventRecurrence
        var guests: [GuestPerson]
        var askingWhich: [GuestQuestion]
    }

    struct GuestQuestion: Identifiable, Equatable {
        var name: String
        var options: [GuestPerson]
        var id: String { name }
    }

    init(initialStart: Date = Date().addingTimeInterval(3_600), initialDurationMinutes: Int? = nil,
         initialTitle: String = "") {
        _title = State(initialValue: initialTitle)
        let remembered = UserDefaults.standard.integer(forKey: "eventAuthoringDurationMinutes")
        let duration = initialDurationMinutes ?? (remembered > 0 ? remembered : 60)
        // A new event has no owner-authored time to preserve — unlike editing an existing one,
        // there's nothing to silently move. Seed the grid the picker steps on, so a plain "+"
        // (no grid tap behind it) doesn't default to an arbitrary minute like 14:37.
        let start = FiveMinuteGrid.snapped(initialStart)
        _eventStart = State(initialValue: start)
        _eventEnd = State(initialValue: start.addingTimeInterval(
            TimeInterval(max(15, duration) * 60)))
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedStart: Date {
        guard isAllDay else { return eventStart }
        return Calendar.current.startOfDay(for: eventStart)
    }

    private var normalizedEnd: Date {
        guard isAllDay else { return eventEnd }
        let calendar = Calendar.current
        let inclusiveEndDay = calendar.startOfDay(for: max(eventStart, eventEnd))
        return calendar.date(byAdding: .day, value: 1, to: inclusiveEndDay) ?? inclusiveEndDay
    }

    private var cleanVideoCallURL: URL? {
        let value = videoCallLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              components.host?.isEmpty == false else { return nil }
        return components.url
    }

    private var videoCallLinkIsValid: Bool {
        videoCallLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || cleanVideoCallURL != nil
    }

    private var timeRangeIsValid: Bool { normalizedEnd > normalizedStart }

    private var conflicts: [Occurrence] {
        schedulingConflicts(
            in: occurrences,
            from: normalizedStart,
            to: normalizedEnd
        )
    }

    private var input: CalendarEventInput {
        // Weekly on days that don't include the start's: begin on the first of them — a series'
        // start always counts as an occurrence.
        let shift = recurrence.repeatValue?.alignedStart(normalizedStart)
            .map { $0.timeIntervalSince(normalizedStart) } ?? 0
        return CalendarEventInput(
            title: cleanTitle,
            start: normalizedStart.addingTimeInterval(shift),
            end: normalizedEnd.addingTimeInterval(shift),
            isAllDay: isAllDay,
            location: location,
            notes: notes,
            url: cleanVideoCallURL,
            availability: availability,
            alertMinutesBefore: alertMinutesBefore < 0 ? nil : alertMinutesBefore,
            structuredLocation: structuredLocation,
            secondaryAlertMinutesBefore: secondaryAlertMinutesBefore < 0
                ? nil : secondaryAlertMinutesBefore,
            // The whole rule, end included: set here rather than by deleting later, since cutting
            // a series short has to reach every copy of the calendar.
            recurrenceRules: recurrence.repeatValue.map { [$0.rule(isAllDay: isAllDay)] },
            attendees: guests.isEmpty ? nil : guests.map(\.email))
    }

    private var selectedCalendar: CalendarSourceInfo? {
        calendars.first { $0.id == calendarID }
    }

    private var matchingTemplates: [CalendarEventTemplate] {
        let query = cleanTitle
        guard query.count >= 2 else { return [] }
        return Array(templates.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                && $0.title.caseInsensitiveCompare(query) != .orderedSame
        }.prefix(3))
    }

    var body: some View {
        NavigationStack {
            eventForm
                .navigationTitle("New event")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveTitle) { save() }
                            .disabled(cleanTitle.isEmpty || !timeRangeIsValid || !videoCallLinkIsValid || saving)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("event.save")
                    }
                }
                .interactiveDismissDisabled(saving)
                .alert("Couldn’t create event", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
        #if os(macOS)
        .frame(width: 620, height: 680)
        #else
        .presentationDetents([.large])
        #endif
        .task {
            await GoogleCalendarService.shared.restoreIfNeeded()
            calendars = occurrences.writableEventCalendars
            if calendarID == nil {
                calendarID = calendars.first(where: { $0.id == lastCalendarID })?.id
                    ?? calendars.first(where: \.isDefault)?.id
                    ?? calendars.first?.id
            }
            titleFocused = true
            templates = await occurrences.eventAuthoringTemplates()
            people = await GuestSources.people()
            #if DEBUG
            // `--new-calendar-event-fill`: the typed words filled in on open, to look at the result.
            if CommandLine.arguments.contains("--new-calendar-event-fill"), phraseDraft != nil { await fillIn() }
            #endif
        }
    }

    /// What the title's words say beyond a title — a time, a place, a repeat — when they do.
    private var phraseDraft: EventPhrase.Draft? {
        guard cleanTitle.count >= 4, cleanTitle != filledTitle else { return nil }
        let draft = EventPhrase.parse(cleanTitle, defaultDuration: max(15 * 60, eventEnd.timeIntervalSince(eventStart)))
        return draft.saysMore ? draft : nil
    }

    /// "Sat, Oct 4 · 1:00–2:00 PM · Balthazar" with Fill in; once filled, Undo.
    @ViewBuilder private var phraseRow: some View {
        if let draft = phraseDraft {
            Button { Task { await fillIn() } } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "wand.and.stars").foregroundStyle(DS.Palette.accent)
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(EventPhrase.preview(draft)).font(.subheadline).foregroundStyle(.primary)
                        if !draft.title.isEmpty {
                            Text("\u{201C}\(draft.title)\u{201D}").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: DS.Space.s)
                    if filling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Fill in").font(.subheadline.weight(.semibold)).foregroundStyle(DS.Palette.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(filling)
            .accessibilityIdentifier("event.fillIn")
        } else if beforeFill != nil {
            HStack {
                Label("Filled in from your words", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo", action: undoFill)
                    .buttonStyle(.inline)
                    .accessibilityIdentifier("event.fillIn.undo")
            }
        }
    }

    /// The form filled in from the title's words: the model says which words are which when
    /// there's one here, the dates are read by the system (`EventPhrase.read`).
    @MainActor private func fillIn() async {
        guard !filling else { return }
        filling = true
        defer { filling = false }
        let length = max(15 * 60, eventEnd.timeIntervalSince(eventStart))
        let draft = await EventPhrase.read(cleanTitle, defaultDuration: length)
        beforeFill = FilledFields(title: title, start: eventStart, end: eventEnd, isAllDay: isAllDay, location: location,
                                  structuredLocation: structuredLocation, recurrence: recurrence, guests: guests,
                                  askingWhich: askingWhich)
        if !draft.title.isEmpty { title = draft.title }
        if let start = draft.start {
            isAllDay = draft.isAllDay
            // All-day here ends on its last day, not the morning after.
            setTimes(start, draft.isAllDay ? start : (draft.end ?? start.addingTimeInterval(length)))
        }
        if let place = draft.location {
            location = place
            structuredLocation = nil
        }
        if let repeating = draft.recurrence { recurrence = repeating }
        filledTitle = cleanTitle
        await addGuests(named: draft.guests)
    }

    /// Who the names are: the one picked before for that name, else the only fit, else a favourite
    /// clearly ahead of the rest (`GuestDirectory.best`). Anyone unclear is asked about.
    @MainActor private func addGuests(named names: [String]) async {
        guard !names.isEmpty else { return }
        if names.contains(where: { !$0.contains("@") }) {
            // Names to match: the first time, contacts are asked for — here, where it's clear why.
            let had = GuestSources.contactsAllowed
            let allowed = await GuestSources.requestContactsIfNeeded()
            if people.isEmpty || (allowed && !had) { people = await GuestSources.people() }
        }
        for name in names {
            let picks = GuestPicks.picks(for: name)
            if let person = GuestDirectory.best(name, in: people, picks: picks) {
                addGuest(person, for: name)
            } else {
                askingWhich.removeAll { $0.name == name }
                askingWhich.append(GuestQuestion(name: name,
                                                 options: Array(GuestDirectory.matches(name, in: people, picks: picks).prefix(4))))
            }
        }
    }

    private func addGuest(_ person: GuestPerson, for name: String?) {
        if !guests.contains(where: { $0.email == person.email }) { guests.append(person) }
        if let name, !name.contains("@") { chosenFor[person.email] = name }
        askingWhich.removeAll { $0.name == name }
    }

    private var saveTitle: String { guests.isEmpty ? "Save" : "Save & Invite" }

    private var guestSuggestions: [GuestPerson] {
        let query = guestQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let chosen = Set(guests.map(\.email))
        return Array(GuestDirectory.matches(query, in: people, picks: GuestPicks.picks(for: query))
            .filter { !chosen.contains($0.email) }.prefix(4))
    }

    /// Who it's with: the guests, "Which Sam?" for a name that fits several, and a field that
    /// finds people by name — the ones you meet most first — or takes an address.
    private var guestsSection: some View {
        Section {
            ForEach(guests) { person in
                HStack(spacing: DS.Space.m) {
                    GuestAvatar(person: person)
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(person.displayName)
                        if person.name != nil {
                            Text(person.email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { guests.removeAll { $0.email == person.email }; chosenFor[person.email] = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .iconButton()
                    .accessibilityLabel("Remove \(person.displayName)")
                }
                .accessibilityIdentifier("event.guest")
            }
            ForEach(askingWhich) { question in
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(question.options.isEmpty
                         ? "No one called \u{201C}\(question.name)\u{201D} in your calendars or contacts \u{2014} add them by email below."
                         : "Which \(question.name)?")
                        .font(.subheadline)
                    ForEach(question.options) { person in
                        Button { addGuest(person, for: question.name) } label: {
                            HStack(spacing: DS.Space.s) {
                                GuestAvatar(person: person)
                                VStack(alignment: .leading, spacing: DS.Space.hair) {
                                    Text(person.displayName).foregroundStyle(.primary)
                                    Text(person.email).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("event.guest.option")
                    }
                }
            }
            TextField("Add a guest \u{2014} name or email", text: $guestQuery)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .autocorrectionDisabled()
                .onSubmit(addTypedGuest)
                .onChange(of: guestQuery) { _, query in
                    guard !query.isEmpty, people.isEmpty || !GuestSources.contactsAllowed else { return }
                    Task {
                        _ = await GuestSources.requestContactsIfNeeded()
                        people = await GuestSources.people()
                    }
                }
                .accessibilityIdentifier("event.guestField")
            ForEach(guestSuggestions) { person in
                Button {
                    addGuest(person, for: guestQuery)
                    guestQuery = ""
                } label: {
                    HStack(spacing: DS.Space.s) {
                        GuestAvatar(person: person)
                        VStack(alignment: .leading, spacing: DS.Space.hair) {
                            Text(person.displayName).foregroundStyle(.primary)
                            Text(person.isFavorite ? "\(person.email) \u{00B7} you meet often" : person.email)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("event.guest.suggestion")
            }
        } header: {
            Text("Guests")
        } footer: {
            Text(guests.isEmpty
                 ? "People you meet most come first."
                 : "Google emails each guest an invitation when you save.")
        }
    }

    /// Return in the guest field: the best match, or the address typed.
    private func addTypedGuest() {
        let query = guestQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let person = guestSuggestions.first ?? GuestDirectory.best(query, in: people) {
            addGuest(person, for: query)
            guestQuery = ""
        }
    }

    /// A start and an end together. Moving the start alone carries the end along (the handler on
    /// `eventStart`); here the end is the one given.
    private func setTimes(_ start: Date, _ end: Date) {
        if start != eventStart { pendingEnd = end }
        eventStart = start
        eventEnd = end
    }

    private func undoFill() {
        guard let before = beforeFill else { return }
        title = before.title
        isAllDay = before.isAllDay
        setTimes(before.start, before.end)
        location = before.location
        structuredLocation = before.structuredLocation
        recurrence = before.recurrence
        guests = before.guests
        askingWhich = before.askingWhich
        beforeFill = nil
        filledTitle = nil
    }

    private var eventForm: some View {
        Form {
            Section {
                TextField("What’s happening?", text: $title)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { if phraseDraft != nil { Task { await fillIn() } } }
                    .accessibilityIdentifier("event.title")
                phraseRow
                ForEach(matchingTemplates) { template in
                    Button {
                        apply(template)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(DS.Palette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(template.title).foregroundStyle(.primary)
                                Text(templateSubtitle(template))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let selectedCalendar {
                    NavigationLink {
                        CalendarDestinationPicker(
                            calendars: calendars,
                            selection: $calendarID
                        )
                    } label: {
                        HStack {
                            Text("Calendar")
                            Spacer()
                            Circle()
                                .fill(calendarTint(SmartScheduleStore.shared.shownColor(selectedCalendar.id, google: selectedCalendar.colorHex)))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(selectedCalendar.title)
                                    .foregroundStyle(.primary)
                                Text(selectedCalendar.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("event.calendar.destination")
                } else {
                    LabeledContent("Calendar") {
                        Text("Default")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Event")
            }

            Section("When") {
                Toggle("All-day", isOn: $isAllDay)
                if isAllDay {
                    DatePicker("Starts", selection: $eventStart, displayedComponents: .date)
                    DatePicker("Ends", selection: $eventEnd, displayedComponents: .date)
                } else {
                    MomentField("Starts", selection: $eventStart)
                    MomentField("Ends", selection: $eventEnd)
                    HStack(spacing: DS.Space.s) {
                        Text("Quick duration")
                        Spacer()
                        ForEach([30, 45, 60, 120], id: \.self) { minutes in
                            Button(durationLabel(minutes)) {
                                eventEnd = eventStart.addingTimeInterval(TimeInterval(minutes * 60))
                            }
                            .buttonStyle(.inline)
                        }
                    }
                }
                if !timeRangeIsValid {
                    Text("The event must end after it starts.")
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.danger)
                }
            }

            if !conflicts.isEmpty {
                AuthoringConflictSection(conflicts: conflicts)
            }

            Section("Where") {
                EventLocationField(
                    location: $location,
                    structuredLocation: $structuredLocation
                )
                TextField("Video call link", text: $videoCallLink)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("event.videoLink")
                if !videoCallLinkIsValid {
                    Text("Enter a valid web address, such as meet.google.com/…")
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.danger)
                }
            }

            guestsSection

            Section("Scheduling") {
                Picker("Show as", selection: $availability) {
                    ForEach(CalendarEventAvailability.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .accessibilityIdentifier("event.availability")
                Picker("Alert", selection: $alertMinutesBefore) {
                    Text("None").tag(-1)
                    Text("At start").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                }
                .accessibilityIdentifier("event.alert")
                Picker("Second alert", selection: $secondaryAlertMinutesBefore) {
                    Text("None").tag(-1)
                    Text("At start").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                    Text("1 day before").tag(1_440)
                }
                .accessibilityIdentifier("event.secondAlert")
                RepeatPicker(recurrence: $recurrence, start: normalizedStart, isAllDay: isAllDay)
                Text("Save this event here, then add invitees in Google Calendar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                NotesField(title: "Notes", text: $notes)
                    .accessibilityIdentifier("event.notes")
            }

            Section {
                Text("Banana saves directly to the selected Google calendar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .editingFormStyle()
        .onChange(of: eventStart) { oldStart, newStart in
            if let pendingEnd {
                eventEnd = pendingEnd
                self.pendingEnd = nil
                return
            }
            guard !isAllDay else { return }
            let oldDuration = max(15 * 60, eventEnd.timeIntervalSince(oldStart))
            eventEnd = newStart.addingTimeInterval(oldDuration)
        }
        .onChange(of: isAllDay) {
            if isAllDay {
                eventEnd = eventStart
            } else if eventEnd <= eventStart {
                eventEnd = eventStart.addingTimeInterval(3_600)
            }
        }
    }

    private func durationLabel(_ minutes: Int) -> String {
        DS.duration(minutes: Double(minutes))
    }

    private func templateSubtitle(_ template: CalendarEventTemplate) -> String {
        var parts = [durationLabel(template.durationMinutes)]
        if let location = template.location, !location.isEmpty { parts.append(location) }
        if template.useCount > 1 { parts.append("used \(template.useCount)×") }
        return parts.joined(separator: " · ")
    }

    private func apply(_ template: CalendarEventTemplate) {
        title = template.title
        eventEnd = eventStart.addingTimeInterval(TimeInterval(template.durationMinutes * 60))
        location = template.location ?? ""
        structuredLocation = template.structuredLocation
        if calendars.contains(where: { $0.id == template.calendarID }) {
            calendarID = template.calendarID
        }
    }

    private func save() {
        guard !cleanTitle.isEmpty, timeRangeIsValid, videoCallLinkIsValid else { return }
        saving = true
        // The event is recorded and drawn before the write finishes, so this closes at once
        // instead of holding the sheet open through a network round trip. A failure surfaces on
        // the event itself, on the grid, where it can be retried — not in a sheet that has gone.
        do {
            try occurrences.createCalendarEventOptimistically(input: input, calendarID: calendarID)
        } catch {
            // Keep the form and its draft when the local durable write fails.
            saving = false
            errorMessage = error.localizedDescription
            return
        }
        // Who each name meant, so the next "Sam" is this one without asking.
        for (email, name) in chosenFor where guests.contains(where: { $0.email == email }) {
            GuestPicks.record(name: name, email: email)
        }
        Task {
            do {
                if let calendarID {
                    lastCalendarID = calendarID
                }
                if !isAllDay {
                    UserDefaults.standard.set(
                        max(15, Int(eventEnd.timeIntervalSince(eventStart) / 60)),
                        forKey: "eventAuthoringDurationMinutes"
                    )
                }
                dismiss()
            }
        }
    }

}

struct CalendarDestinationPicker: View {
    let calendars: [CalendarSourceInfo]
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss

    private struct Account: Identifiable {
        let id: String
        let title: String
        let calendars: [CalendarSourceInfo]
    }

    private var accounts: [Account] {
        Dictionary(grouping: calendars, by: \.sourceID)
            .map { sourceID, calendars in
                let sourceTitle = calendars.first?.sourceTitle ?? ""
                return Account(
                    id: sourceID,
                    title: sourceTitle.isEmpty ? "On My Device" : sourceTitle,
                    calendars: calendars.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                )
            }
            .sorted {
                if $0.title != $1.title {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    var body: some View {
        List {
            ForEach(accounts) { account in
                Section(account.title) {
                    ForEach(account.calendars) { calendar in
                        Button {
                            selection = calendar.id
                            dismiss()
                        } label: {
                            HStack(spacing: DS.Space.m) {
                                Circle()
                                    .fill(calendarTint(SmartScheduleStore.shared.shownColor(calendar.id, google: calendar.colorHex)))
                                    .frame(width: 12, height: 12)
                                Text(calendar.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selection == calendar.id {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(DS.Palette.accent)
                                }
                            }
                        }
                        .accessibilityLabel("\(calendar.title), \(account.title)")
                    }
                }
            }

            Section {
                Text("Manage Apple accounts in Calendar settings and direct Google accounts in Banana settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shared: the week grids colour event blocks by their source calendar with this too.
/// A calendar's colour, evened out for the current appearance (see `CalendarColor`). A calendar
/// with no colour is neutral grey — never the brand accent, which means "Banana", not "unknown".
func calendarTint(_ hex: String?) -> Color {
    CalendarColor.color(hex: hex) ?? Color.secondary
}

/// Uses the already-materialized timeline for an immediate conflict preview. It intentionally
/// performs no EventKit or network fetch while the user edits dates, so scrolling a picker stays
/// cheap and the preview cannot turn into a background battery drain.
/// Conflicts for a proposed span.
///
/// Takes the store so it can use the `byDay` index rather than the whole horizon. This is called
/// from a computed property in the authoring sheets, so it re-runs on every render while someone
/// is spinning a time picker — scanning all 31 days each time to look at one. A span can only
/// conflict with the days it touches.
@MainActor
func schedulingConflicts(
    in store: OccurrenceStore,
    from start: Date,
    to end: Date,
    calendar cal: Calendar = .current
) -> [Occurrence] {
    guard end > start else { return [] }
    var candidates = store.occurrences(on: start)
    let endDay = cal.startOfDay(for: end)
    if endDay != cal.startOfDay(for: start) {
        candidates += store.occurrences(on: end)   // a span crossing midnight touches two
    }
    return schedulingConflicts(in: candidates, from: start, to: end)
}

func schedulingConflicts(
    in occurrences: [Occurrence],
    from start: Date,
    to end: Date
) -> [Occurrence] {
    guard end > start else { return [] }
    return occurrences.filter { occurrence in
        // A day blocked all day is in the way of anything that day.
        guard occurrence.hasScheduledTime || occurrence.blocksWholeDay,
              !occurrence.skipped,
              !occurrence.completed else { return false }
        let blocksTime: Bool
        switch occurrence.behavior {
        case .event:
            blocksTime = true
        case .allDay:
            blocksTime = occurrence.blocksWholeDay
        case .block:
            blocksTime = occurrence.writePolicy == .busy
        case .task:
            blocksTime = !occurrence.overdue
        case .cue:
            blocksTime = occurrence.schedule.moveable
        case .alarm:
            blocksTime = false
        }
        let occurrenceEnd: Date
        if occurrence.behavior == .cue,
           let duration = occurrence.schedule.constraints?.duration {
            occurrenceEnd = occurrence.start.addingTimeInterval(duration)
        } else {
            occurrenceEnd = occurrence.resolvedEnd
        }
        return blocksTime && occurrence.start < end && occurrenceEnd > start
    }
    .sorted { $0.start < $1.start }
}

struct AuthoringConflictSection: View {
    let conflicts: [Occurrence]

    var body: some View {
        Section {
            Label(
                "Conflicts with \(conflicts.count) \(conflicts.count == 1 ? "item" : "items")",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(DS.Palette.warning)
            ForEach(Array(conflicts.prefix(3))) { conflict in
                HStack {
                    Text(conflict.title).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(conflict.start, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.footnote)
            }
            if conflicts.count > 3 {
                Text("And \(conflicts.count - 3) more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("You can still save; this is a warning, not a blocker.")
        }
    }
}
/// A guest's initial in a circle, starred for someone you meet often.
struct GuestAvatar: View {
    let person: GuestPerson

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.primary.opacity(DS.Tint.soft))
                .frame(width: 30, height: 30)
                .overlay(Text(String(person.displayName.prefix(1)).uppercased()).font(.footnote.weight(.semibold)))
            if person.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Palette.accent)
                    .offset(x: 2, y: 2)
                    .accessibilityLabel("You meet often")
            }
        }
    }
}
