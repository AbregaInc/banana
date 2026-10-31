import SwiftUI

/// Identifiable box so a tapped meeting can drive a `.sheet(item:)`.
struct CalendarEventSheet: Identifiable {
    let id = UUID()
    let googleMeeting: MeetingInfo

    init(googleMeeting: MeetingInfo) {
        self.googleMeeting = googleMeeting
    }
}

struct CalendarEventSheetView: View {
    let sheet: CalendarEventSheet
    var onComplete: (() -> Void)? = nil
    /// Where it isn't a sheet (the iPad's panel beside the calendar), how it closes.
    var close: (() -> Void)? = nil

    /// On the phone a tap opens the event to read and act on (Join, Directions, reply), with Edit
    /// one tap further; the Mac has its side drawer for that, so its sheet is the editor.
    var body: some View {
        #if os(iOS)
        EventDetailView(meeting: sheet.googleMeeting, onChange: onComplete, close: close)
        #else
        GoogleCalendarEventView(meeting: sheet.googleMeeting, onComplete: onComplete)
        #endif
    }
}

/// Banana's editor for an event in Google Calendar — the same form on the iPhone, iPad and Mac.
/// It patches only the fields shown here, so conference data and anything else Google keeps
/// survive an edit unchanged. Guests can be added and taken off on an event that is yours to
/// edit; everyone who stays keeps their reply (`GoogleGuestPatch`).
///
/// What it lets you change follows `GoogleEventEditPolicy`: everything on your own events,
/// only your alerts and show-as on someone else's invitation, nothing on a read-only calendar.
/// Saving closes it at once; the edit shows on the calendar straight away and the toast offers
/// Undo (`SmartScheduleStore.saveEventEdit`).
struct GoogleCalendarEventView: View {
    let meeting: MeetingInfo
    var onComplete: (() -> Void)? = nil
    /// A loaded event to show without asking Google — for previews and screenshots.
    var preloaded: GoogleCalendarEvent? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var smart: SmartScheduleStore
    @StateObject private var google = GoogleCalendarService.shared
    @State private var source: GoogleCalendarEvent?
    @State private var title = ""
    @State private var start = Date()
    @State private var displayedEnd = Date().addingTimeInterval(3_600)
    @State private var isAllDay = false
    @State private var location = ""
    /// The place picked from search, if one was. Google stores only the text; this is what puts
    /// the place in the recents list for next time.
    @State private var structuredLocation: CalendarEventLocation?
    @State private var notes = ""
    @State private var availability: CalendarEventAvailability = .busy
    @State private var destinationCalendarInfoID = ""
    @State private var firstAlert = -2
    @State private var secondAlert = -1
    @State private var recurrence: EventRecurrence = .none
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var question: GoogleEventEditQuestion?
    @State private var deleteQuestion = false
    /// Guests to invite on Save, and the addresses of ones to take off.
    @State private var addedGuests: [GuestPerson] = []
    @State private var removedGuests: Set<String> = []
    @State private var guestQuery = ""
    /// Everyone it could be with (`GuestSources`), read the first time the field is typed in.
    @State private var people: [GuestPerson] = []

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedStart: Date {
        isAllDay ? Calendar.current.startOfDay(for: start) : start
    }

    private var normalizedEnd: Date {
        guard isAllDay else { return displayedEnd }
        let lastDay = Calendar.current.startOfDay(for: max(start, displayedEnd))
        return Calendar.current.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
    }

    private var canEdit: Bool { source?.canEdit == true }

    private var canSave: Bool {
        guard let source, source.canEditPersonal else { return false }
        guard source.canEdit else { return true }
        return calendarChoices.contains(where: { $0.id == destinationCalendarInfoID })
            && !cleanTitle.isEmpty
            && normalizedEnd > normalizedStart
    }

    /// Writable calendars to move it to; the preview has none, so its own stands in.
    private var calendarChoices: [CalendarSourceInfo] {
        let writable = smart.writableEventCalendars
        if writable.isEmpty, preloaded != nil, let source {
            return [CalendarSourceInfo(id: source.calendarInfoID, title: source.calendarTitle,
                                       colorHex: source.calendarColorHex, sourceID: "preview",
                                       sourceTitle: "Google", isDefault: true, provider: .google)]
        }
        return writable
    }

    private var organizerName: String? {
        source?.attendees.first(where: \.isOrganizer).map { $0.displayName ?? $0.email }
    }

    /// RepeatPicker's words, for a repeat that can't be changed here.
    static func repeatWord(_ preset: EventRepeatPreset) -> String {
        switch preset {
        case .never: return "Never"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .custom: return "Custom"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading event…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if source != nil {
                    eventForm
                } else {
                    ContentUnavailableView {
                        Label("Event unavailable", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text(errorMessage ?? "This Google Calendar event is no longer available.")
                    } actions: {
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Edit event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addedGuests.isEmpty ? "Save" : "Save & Invite") { requestSave() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("eventEditor.save")
                }
            }
        }
        #if os(macOS)
        .frame(width: 620, height: 720)
        #else
        .presentationDetents([.large])
        #endif
        .task(id: meeting.eventID) { await load() }
        .confirmationDialog(
            questionTitle,
            isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } }),
            titleVisibility: .visible
        ) {
            if question == .endSeries {
                Button("End the series after this event") { save(scope: .occurrence) }
            } else {
                Button("This event") { save(scope: .occurrence) }
                if question == .thisFollowingOrAll {
                    Button("This and following events") { save(scope: .thisAndFollowing) }
                }
                Button("All events") { save(scope: .series) }
            }
            Button("Cancel", role: .cancel) { question = nil }
        } message: {
            if question == .endSeries {
                Text("This event and the ones before it stay; the ones after it are removed.")
            }
        }
        .confirmationDialog("Delete repeating event?", isPresented: $deleteQuestion, titleVisibility: .visible) {
            Button("Delete this event only", role: .destructive) { performDelete(scope: .occurrence) }
            Button("Delete this and following", role: .destructive) { performDelete(scope: .thisAndFollowing) }
            Button("Delete entire series", role: .destructive) { performDelete(scope: .series) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t delete event", isPresented: Binding(
            get: { errorMessage != nil && source != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var questionTitle: String {
        question == .endSeries ? "Stop repeating?" : "Change repeating event?"
    }

    private var eventForm: some View {
        Form {
            // Google makes an all-day event Free, an accepted invitation's included: it shows but
            // blocks nothing. One tap blocks the day (`AllDayBlocking`).
            if let source, source.isAllDay, source.availability == .free, source.canEditPersonal {
                Section {
                    Button {
                        AllDayBlocking.set(meeting, busy: true)
                        onComplete?()
                        dismiss()
                    } label: {
                        Label("Block this day", systemImage: "calendar.badge.clock")
                    }
                    .accessibilityIdentifier("event.blockDay")
                } footer: {
                    Text("It shows as Free, so it blocks nothing \u{2014} Calendly can book you that day. Blocking marks you Busy on your copy only: here, in Calendly, and on your other calendars.")
                }
            }
            Section("Event") {
                TextField("What’s happening?", text: $title)
                    .disabled(!canEdit)
                // Someone else's invite: who it's from is one plain row, not a note of its own.
                if let source, source.access == .personalOnly {
                    LabeledContent("Organiser", value: organizerName ?? "Someone else")
                }
                if let source, source.canEdit {
                    Picker("Calendar", selection: $destinationCalendarInfoID) {
                        ForEach(calendarChoices) { calendar in
                            Text(destinationLabel(calendar)).tag(calendar.id)
                        }
                    }
                } else if let source {
                    LabeledContent("Calendar") {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(calendarTint(smart.shownColor(source.calendarInfoID, google: source.calendarColorHex)))
                                .frame(width: 10, height: 10)
                            Text(readOnlyDestinationLabel(source))
                        }
                    }
                }
            }

            Section("When") {
                Toggle("All-day", isOn: $isAllDay)
                    .disabled(!canEdit)
                if isAllDay {
                    DatePicker("Starts", selection: $start, displayedComponents: .date)
                        .disabled(!canEdit)
                    DatePicker("Ends", selection: $displayedEnd, displayedComponents: .date)
                        .disabled(!canEdit)
                } else {
                    MomentField("Starts", selection: $start)
                        .disabled(!canEdit)
                    MomentField("Ends", selection: $displayedEnd)
                        .disabled(!canEdit)
                }
                if normalizedEnd <= normalizedStart {
                    Text("The event must end after it starts.")
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.danger)
                }
            }

            Section {
                if canEdit {
                    RepeatPicker(recurrence: $recurrence, start: start, isAllDay: isAllDay, identifier: "eventEditor")
                } else {
                    // The picker's own short words, read-only.
                    LabeledContent("Repeat", value: Self.repeatWord(EventRepeat.preset(of: recurrence)))
                }
            } header: {
                Text("Repeat")
            } footer: {
                if canEdit, source?.isRecurring == true {
                    Text("A change to Repeat applies to every event in the series.")
                }
            }

            Section("Where") {
                // The same address search as a new event: typing a place used to be a bare text
                // field here, so an existing event's location could only be typed out in full.
                EventLocationField(location: $location, structuredLocation: $structuredLocation)
                    .disabled(!canEdit)
                if let joinURL = meeting.joinURL {
                    Link(destination: joinURL) {
                        Label(
                            meeting.platform.map { "Join \($0.label)" } ?? "Join meeting",
                            systemImage: "video.fill"
                        )
                    }
                }
            }

            // How the trip there is timed, and where to fix it when "Chelsea" is the wrong Chelsea.
            GettingThereView(meeting: meeting, style: .form)

            Section("Scheduling") {
                Picker("Show as", selection: $availability) {
                    Text("Busy").tag(CalendarEventAvailability.busy)
                    Text("Free").tag(CalendarEventAvailability.free)
                }
                Picker("Alert", selection: $firstAlert) {
                    alertChoices(includesDefault: true)
                }
                if firstAlert >= 0 {
                    Picker("Second alert", selection: $secondAlert) {
                        alertChoices(includesDefault: false)
                    }
                }
            }
            .disabled(source?.canEditPersonal != true)

            Section("Notes") {
                NotesField(title: "Notes", text: $notes)
                    .disabled(!canEdit)
            }

            if let source, canEdit || !source.attendees.isEmpty {
                guestsSection(source)
            }

            if source?.access == .readOnly {
                Section {
                    Label(
                        "This event can’t be changed from here: its calendar is read-only for you, or Google manages it.",
                        systemImage: "lock"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if let link = source?.htmlLink {
                Section {
                    Link(destination: link) {
                        Label("Open in Google Calendar", systemImage: "arrow.up.forward.app")
                    }
                }
            }

            if canEdit {
                Section {
                    Button("Delete event", role: .destructive) { requestDelete() }
                }
            }

            // An all-day event can go from Banana even where it can't be deleted — a birthday
            // comes from Google Contacts, and Google lets no app delete one (`AllDayHiding`).
            if let source, source.isAllDay {
                Section {
                    Button {
                        AllDayHiding.hide(meeting)
                        onComplete?()
                        dismiss()
                    } label: {
                        Label("Hide in Banana", systemImage: "eye.slash")
                    }
                    .accessibilityIdentifier("event.hideAllDay")
                } footer: {
                    Text(source.access == .readOnly
                         ? "Birthdays come from Google Contacts, and Google doesn\u{2019}t let apps delete them. Hiding keeps this one off Banana every year; Settings \u{203A} All-day events lists what\u{2019}s hidden."
                         : "Keeps it off Banana every year without changing Google. Settings \u{203A} All-day events lists what\u{2019}s hidden.")
                }
            }
        }
        .editingFormStyle()
        .onChange(of: start) { oldStart, newStart in
            guard !isAllDay else { return }
            displayedEnd = newStart.addingTimeInterval(
                max(15 * 60, displayedEnd.timeIntervalSince(oldStart))
            )
        }
        .onChange(of: isAllDay) {
            if isAllDay {
                displayedEnd = start
            } else if displayedEnd <= start {
                displayedEnd = start.addingTimeInterval(3_600)
            }
        }
    }

    // MARK: - Guests

    /// Who it's with. On an event that is yours to edit: add someone by name or address, take
    /// someone off. On an invitation it is the organizer's list, shown as it is.
    private func guestsSection(_ source: GoogleCalendarEvent) -> some View {
        Section {
            ForEach(source.attendees) { attendee in
                let removed = removedGuests.contains(attendee.email.lowercased())
                HStack(spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attendee.displayName ?? attendee.email)
                            .strikethrough(removed)
                            .foregroundStyle(removed ? .secondary : .primary)
                        if attendee.displayName != nil {
                            Text(attendee.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if removed {
                            Text("Taken off when you save").font(.caption).foregroundStyle(.secondary)
                        } else if attendee.isOrganizer {
                            Text("Organizer").font(.caption).foregroundStyle(.secondary)
                        } else if let status = attendee.responseStatus {
                            Text(responseLabel(status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    // Not the organizer (it's their event) and not you (that is Decline).
                    if canEdit, !attendee.isOrganizer, !attendee.isCurrentUser {
                        Button {
                            let email = attendee.email.lowercased()
                            if removed { removedGuests.remove(email) } else { removedGuests.insert(email) }
                        } label: {
                            Image(systemName: removed ? "arrow.uturn.backward.circle" : "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .iconButton()
                        .accessibilityLabel(removed ? "Keep \(attendee.displayName ?? attendee.email)"
                                                    : "Remove \(attendee.displayName ?? attendee.email)")
                    }
                }
                .accessibilityIdentifier("eventEditor.guest")
            }
            ForEach(addedGuests) { person in
                HStack(spacing: DS.Space.m) {
                    GuestAvatar(person: person)
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(person.displayName)
                        Text(person.name == nil ? "Invited when you save" : "\(person.email) \u{00B7} invited when you save")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { addedGuests.removeAll { $0.email == person.email } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .iconButton()
                    .accessibilityLabel("Remove \(person.displayName)")
                }
                .accessibilityIdentifier("eventEditor.guest.added")
            }
            if canEdit {
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
                    .accessibilityIdentifier("eventEditor.guestField")
                ForEach(guestSuggestions) { person in
                    Button {
                        addGuest(person)
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
                    .accessibilityIdentifier("eventEditor.guest.suggestion")
                }
            }
        } header: {
            Text(source.attendees.isEmpty ? "Guests" : "Guests \u{00B7} \(source.attendees.count)")
        } footer: {
            Text(guestsFooter(source))
        }
    }

    private func guestsFooter(_ source: GoogleCalendarEvent) -> String {
        guard canEdit else { return "Guests and their responses are kept." }
        if !addedGuests.isEmpty || !removedGuests.isEmpty {
            var parts: [String] = []
            if !addedGuests.isEmpty { parts.append("emails an invitation to each guest you add") }
            if !removedGuests.isEmpty { parts.append("tells anyone you take off") }
            return "When you save, Google " + parts.joined(separator: " and ") + ". Everyone else keeps their reply."
        }
        return source.notifiesGuests
            ? "Guests and their responses are kept, and Google tells them about your change."
            : (source.attendees.isEmpty ? "People you meet most come first." : "Guests and their responses are kept.")
    }

    private var guestSuggestions: [GuestPerson] {
        let query = guestQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let onIt = Set((source?.attendees.map { $0.email.lowercased() } ?? []) + addedGuests.map(\.email))
            .subtracting(removedGuests)
        return Array(GuestDirectory.matches(query, in: people, picks: GuestPicks.picks(for: query))
            .filter { !onIt.contains($0.email) }.prefix(4))
    }

    private func addGuest(_ person: GuestPerson) {
        guestQuery = ""
        // Someone taken off a moment ago and added again is simply kept.
        if removedGuests.remove(person.email) != nil { return }
        guard source?.attendees.contains(where: { $0.email.lowercased() == person.email }) != true,
              !addedGuests.contains(where: { $0.email == person.email }) else { return }
        addedGuests.append(person)
    }

    /// Return in the guest field: the best match, or the address typed. A name that matches
    /// nobody and isn't an address stays in the field: nothing is invited by guesswork.
    private func addTypedGuest() {
        let query = guestQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let person = guestSuggestions.first ?? GuestDirectory.best(query, in: people),
           GoogleGuestPatch.isAddress(person.email) {
            addGuest(person)
        } else if GoogleGuestPatch.isAddress(query.lowercased()) {
            addGuest(GuestPerson(email: query))
        }
    }

    private var guestChange: GoogleGuestChange {
        guard canEdit else { return GoogleGuestChange() }
        return GoogleGuestChange(adding: addedGuests.map(\.email), removing: removedGuests.sorted())
    }

    @ViewBuilder
    private func alertChoices(includesDefault: Bool) -> some View {
        if includesDefault { Text("Calendar default").tag(-2) }
        Text("None").tag(-1)
        Text("At start").tag(0)
        Text("5 minutes before").tag(5)
        Text("10 minutes before").tag(10)
        Text("15 minutes before").tag(15)
        Text("30 minutes before").tag(30)
        Text("1 hour before").tag(60)
        Text("1 day before").tag(1_440)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let event: GoogleCalendarEvent
            if let preloaded { event = preloaded } else { event = try await google.event(for: meeting) }
            source = event
            title = event.title
            start = event.start
            displayedEnd = event.isAllDay
                ? (Calendar.current.date(byAdding: .day, value: -1, to: event.end) ?? event.end)
                : event.end
            isAllDay = event.isAllDay
            location = event.location
            notes = event.notes
            availability = event.availability
            destinationCalendarInfoID = event.calendarInfoID
            recurrence = event.recurrence
            switch event.reminders {
            case .calendarDefault:
                firstAlert = -2
                secondAlert = -1
            case .none:
                firstAlert = -1
                secondAlert = -1
            case .custom(let minutes):
                firstAlert = minutes.first ?? -1
                secondAlert = minutes.dropFirst().first ?? -1
            }
        } catch {
            source = nil
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    // MARK: - Saving

    /// The event as the form has it.
    private var edited: GoogleCalendarEvent? {
        guard var event = source else { return nil }
        if event.canEdit {
            event.title = cleanTitle
            event.start = normalizedStart
            event.end = normalizedEnd
            event.isAllDay = isAllDay
            event.location = location
            event.notes = notes
        }
        event.availability = availability
        if firstAlert == -2 {
            event.reminders = .calendarDefault
        } else {
            let minutes = [firstAlert, secondAlert].filter { $0 >= 0 }
            event.reminders = minutes.isEmpty ? .none : .custom(minutes)
        }
        return event
    }

    private var repeatChanged: Bool {
        guard let source, canEdit else { return false }
        return recurrence != source.recurrence
    }

    private var fieldsChanged: Bool {
        guard let source, let edited else { return false }
        return edited.patchFields != source.patchFields || destinationCalendarInfoID != source.calendarInfoID
    }

    private func requestSave() {
        guard canSave, let source else { return }
        let asked: GoogleEventEditQuestion
        if source.canEdit {
            asked = GoogleEventEditScope.question(
                isRecurring: source.isRecurring, repeatChanged: repeatChanged,
                repeatTurnedOff: repeatChanged && recurrence == .none,
                // Someone being invited counts: a series is never split in two with guests on it.
                otherGuestCount: source.otherGuestCount + addedGuests.count + removedGuests.count,
                usesCount: source.recurrenceRules.contains { $0.uppercased().contains("COUNT=") })
        } else {
            asked = source.isRecurring ? .thisOrAll : .none
        }
        guard repeatChanged || fieldsChanged || !guestChange.isEmpty else {
            dismiss()
            return
        }
        if asked == .none {
            save(scope: source.isRecurring && repeatChanged ? .series : .occurrence)
        } else {
            question = asked
        }
    }

    private func save(scope: GoogleCalendarEventScope) {
        let asked = question
        question = nil
        guard let source, var edited else { return }
        var change = GoogleRecurrenceChange.unchanged
        var message = "Saved \u{201C}\(edited.title)\u{201D}"
        if asked == .endSeries {
            change = .endAfterOccurrence
            message = "\u{201C}\(edited.title)\u{201D} ends after this one"
        } else if repeatChanged, case .rule(let rule) = recurrence {
            change = .setRule(rule.rule(isAllDay: edited.isAllDay))
            // A single event made weekly on other days starts on the first of them: a series'
            // start always counts as an occurrence.
            if !source.isRecurring, let aligned = rule.alignedStart(edited.start) {
                let length = edited.end.timeIntervalSince(edited.start)
                edited.start = aligned
                edited.end = aligned.addingTimeInterval(length)
            }
            let summary = rule.summary(start: edited.start)
            message = "\u{201C}\(edited.title)\u{201D} now repeats " + summary.prefix(1).lowercased() + summary.dropFirst()
        } else if scope == .thisAndFollowing {
            message = "Saved \u{201C}\(edited.title)\u{201D} from this one on"
        }
        let guests = guestChange
        let removedNames = source.attendees
            .filter { removedGuests.contains($0.email.lowercased()) }
            .map { $0.displayName ?? $0.email }
        message += GoogleGuestChange.savedSuffix(invited: addedGuests.map(\.displayName), removed: removedNames)
        smart.saveEventEdit(.init(
            original: source, edited: edited,
            destinationCalendarID: canEdit ? destinationCalendarInfoID : source.calendarInfoID,
            scope: scope, recurrence: change,
            fieldsChanged: edited.patchFields != source.patchFields || destinationCalendarInfoID != source.calendarInfoID,
            guests: guests,
            message: message))
        onComplete?()
        dismiss()
    }

    private func requestDelete() {
        if source?.isRecurring == true {
            deleteQuestion = true
        } else {
            performDelete(scope: .occurrence)
        }
    }

    /// Gone at once, with Undo; Google hears about it when the Undo window closes, and a failure
    /// puts the event back and says so (`ToastCenter.deferDelete`). It used to wait here for
    /// Google, with the editor open, before anything moved.
    private func performDelete(scope: GoogleCalendarEventScope) {
        guard let source else { return }
        let span: CalendarEditSpan
        switch scope {
        case .occurrence: span = .thisEvent
        case .thisAndFollowing: span = .futureEvents
        case .series: span = .allEvents
        }
        let google = google
        let smart = smart
        onComplete?()
        dismiss()
        Task {
            await ToastCenter.shared.deferDelete(eventID: source.id, hiding: span.hiding(source.id, start: source.start),
                                                 title: source.title, span: span) {
                do {
                    try await google.deleteEvent(eventInfoID: source.id, scope: scope)
                } catch {
                    return error.localizedDescription
                }
                await smart.refreshAgenda()
                await OccurrenceStore.shared.recompute(reason: "Google Calendar event deleted")
                return nil
            }
        }
    }

    private func responseLabel(_ status: String) -> String {
        switch status {
        case "accepted": return "Accepted"
        case "declined": return "Declined"
        case "tentative": return "Maybe"
        case "needsAction": return "Awaiting response"
        default: return status.capitalized
        }
    }

    private func destinationLabel(_ calendar: CalendarSourceInfo) -> String {
        let account = calendar.sourceTitle.isEmpty ? "Google" : calendar.sourceTitle
        return "\(calendar.title) — \(account)"
    }

    private func readOnlyDestinationLabel(_ event: GoogleCalendarEvent) -> String {
        guard let calendar = google.allCalendarInfos.first(where: { $0.id == event.calendarInfoID })
        else { return event.calendarTitle }
        return destinationLabel(calendar)
    }
}
