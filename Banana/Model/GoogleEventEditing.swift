import Foundation

// What an edit to a Google event may change, which events it applies to, and the exact body it
// sends. Pure — these decide what lands on a real calendar, other people's included, so they're
// covered by tests rather than trusted to the network code in GoogleCalendarService.

enum GoogleCalendarReminderSelection: Equatable {
    case calendarDefault
    case none
    case custom([Int])
}

/// How much of an event you can change.
enum GoogleEventEditAccess: Equatable {
    /// Title, time, place, notes, repeat, calendar — it's yours, or its organizer lets guests edit.
    case full
    /// An invitation someone else organized: only your own alerts, how it shows (busy/free) and
    /// your reply. Changing its title or time would rewrite their event for every guest.
    case personalOnly
    /// A read-only calendar, a birthday or working-location entry, or a block Banana wrote.
    case readOnly
}

enum GoogleEventEditPolicy {
    /// Event types Google manages itself; their main fields can't be patched.
    static let managedEventTypes: Set<String> = ["birthday", "workingLocation", "fromGmail", "outOfOffice", "focusTime"]

    static func access(calendarWritable: Bool, locked: Bool, organizerIsSelf: Bool?, guestsCanModify: Bool,
                       eventType: String?, isBananaBlock: Bool) -> GoogleEventEditAccess {
        guard !isBananaBlock, calendarWritable else { return .readOnly }
        if let eventType, managedEventTypes.contains(eventType) { return .readOnly }
        if locked { return .personalOnly }
        // No organizer at all is an event made on this calendar: yours.
        if organizerIsSelf != false || guestsCanModify { return .full }
        return .personalOnly
    }

    /// Whether Google should email the guests about this change: only when you organize the
    /// event and there's someone besides you on it. Everything else changes quietly.
    static func notifiesGuests(organizerIsSelf: Bool?, otherGuestCount: Int) -> Bool {
        organizerIsSelf != false && otherGuestCount > 0
    }

    /// Whether a save that changes the guest list is emailed: always. Someone added has to get
    /// the invitation, and someone taken off has to hear it's off their calendar.
    static func notifiesGuests(organizerIsSelf: Bool?, otherGuestCount: Int, guests: GoogleGuestChange) -> Bool {
        !guests.isEmpty || notifiesGuests(organizerIsSelf: organizerIsSelf, otherGuestCount: otherGuestCount)
    }

    /// Whether you organize it. Google leaves `self` out when it's false, so an organizer
    /// without it is someone else; no organizer at all is an event made on this calendar (nil).
    static func organizerIsSelf(_ organizer: GoogleEvent.Organizer?) -> Bool? {
        organizer.map { $0.selfOrganizer == true }
    }

    /// The private key Banana tags its own busy and travel blocks with.
    static func isBananaBlock(_ privateProperties: [String: String]?) -> Bool {
        privateProperties?[GoogleBusyBlocks.variantKey] != nil
    }
}

/// What a save asks before writing, for an event that repeats.
enum GoogleEventEditQuestion: Equatable {
    /// Nothing to ask: a single event, or a change to the repeat itself (which is the series').
    case none
    /// "This event" or "All events".
    case thisOrAll
    /// "This event", "This and following" or "All events" — only for a series with no other
    /// guests, where splitting it in two re-invites nobody.
    case thisFollowingOrAll
    /// Repeat set to Never on a series: "End the series after this event".
    case endSeries
}

enum GoogleEventEditScope {
    static func question(isRecurring: Bool, repeatChanged: Bool, repeatTurnedOff: Bool,
                         otherGuestCount: Int, usesCount: Bool) -> GoogleEventEditQuestion {
        guard isRecurring else { return .none }
        if repeatTurnedOff { return .endSeries }
        if repeatChanged { return .none }
        // A COUNT can't be split without renumbering both halves; keep to this/all there.
        return otherGuestCount == 0 && !usesCount ? .thisFollowingOrAll : .thisOrAll
    }

    /// Whether a change to the repeat is written to the series (always, for a series) — the
    /// rule lives only on the series' master, and an occurrence's id is refused.
    static func scope(forRepeatChangeOnRecurring isRecurring: Bool) -> GoogleCalendarEventScope {
        isRecurring ? .series : .occurrence
    }
}

/// What an edit does to an event's repeat.
enum GoogleRecurrenceChange: Equatable {
    case unchanged
    /// A new rule line; the series' EXDATE/RDATE lines are kept (`EventRepeat.replacingRule`).
    case setRule(String)
    /// Exactly these lines back, for Undo.
    case restore([String])
    /// Repeat set to Never on a series: it stops after the occurrence being edited.
    case endAfterOccurrence
}

enum GoogleEventPatch {
    /// The fields a save can change.
    struct Fields: Equatable {
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String
        var notes: String
        var availability: CalendarEventAvailability
        /// Nil leaves reminders alone.
        var reminders: GoogleCalendarReminderSelection?
        /// The event's own zone, when it has one.
        var timeZoneID: String?
    }

    /// The PATCH body. `recurrence` nil leaves the repeat untouched; an empty list is never sent
    /// (it would collapse a series to its first event and delete every other occurrence, past
    /// ones included) — Never on a series is a truncation instead. A repeating event's start and
    /// end always carry a time zone: Google requires one to expand the rule.
    static func body(_ fields: Fields, access: GoogleEventEditAccess, recurrence: [String]?,
                     isRecurring: Bool, fallbackTimeZoneID: String = TimeZone.current.identifier) -> [String: Any] {
        var body: [String: Any] = [
            "transparency": fields.availability == .free ? "transparent" : "opaque"
        ]
        if let reminders = fields.reminders { body["reminders"] = remindersJSON(reminders) }
        guard access == .full else { return body }

        let repeating = isRecurring || recurrence?.isEmpty == false
        let zone = fields.timeZoneID ?? (repeating ? fallbackTimeZoneID : nil)
        let location = fields.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = fields.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        body["summary"] = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        body["start"] = dateJSON(fields.start, allDay: fields.isAllDay, timeZoneID: zone)
        body["end"] = dateJSON(fields.end, allDay: fields.isAllDay, timeZoneID: zone)
        body["location"] = location.isEmpty ? NSNull() : location
        body["description"] = notes.isEmpty ? NSNull() : notes
        if let recurrence, !recurrence.isEmpty { body["recurrence"] = recurrence }
        return body
    }

    static func remindersJSON(_ reminders: GoogleCalendarReminderSelection) -> [String: Any] {
        switch reminders {
        case .calendarDefault:
            return ["useDefault": true]
        case .none:
            return ["useDefault": false, "overrides": [[String: Any]]()]
        case .custom(let minutes):
            var seen = Set<Int>()
            let unique = minutes.filter { seen.insert($0).inserted }
            return ["useDefault": false, "overrides": unique.map { ["method": "popup", "minutes": $0] }]
        }
    }

    static func dateJSON(_ date: Date, allDay: Bool, timeZoneID: String?) -> [String: String] {
        if allDay { return ["date": GoogleCalendarDates.dateString(date)] }
        var value = ["dateTime": GoogleCalendarDates.rfc3339(date)]
        if let timeZoneID { value["timeZone"] = timeZoneID }
        return value
    }

    /// Whether `recurrence` may be sent to this event id: only a series' master or a single
    /// event. An occurrence's id (`<master>_<instant>`, with `recurringEventId`) is refused by
    /// Google — and a bug that sent it there would be editing the wrong thing.
    static func canCarryRecurrence(eventID: String, recurringEventID: String?) -> Bool {
        recurringEventID == nil && !eventID.contains("_")
    }

    /// The new series for "This and following": the master as Google sent it, minus everything
    /// that identifies the old series or can't be copied, with the edit's fields and times and
    /// the rule from this occurrence on. Guests are dropped — the option is only offered when
    /// there are none besides you.
    static func followingSeriesBody(master: [String: Any], fields: Fields, rule: [String],
                                    fallbackTimeZoneID: String = TimeZone.current.identifier) -> [String: Any] {
        let dropped: Set<String> = ["id", "iCalUID", "etag", "htmlLink", "created", "updated", "recurringEventId",
                                    "originalStartTime", "sequence", "organizer", "creator", "attendees",
                                    "conferenceData", "hangoutLink", "kind", "status", "privateCopy", "locked",
                                    "recurrence", "start", "end", "extendedProperties"]
        var body = master.filter { !dropped.contains($0.key) }
        for (key, value) in Self.body(fields, access: .full, recurrence: rule, isRecurring: true,
                                      fallbackTimeZoneID: fallbackTimeZoneID) where !(value is NSNull) {
            body[key] = value
        }
        return body
    }
}

/// Matching Banana's own writes against what a later read reports changed.
/// Guests added to and taken off an event that already exists.
struct GoogleGuestChange: Equatable, Sendable {
    /// Addresses to invite.
    var adding: [String] = []
    /// Addresses to take off.
    var removing: [String] = []

    var isEmpty: Bool { adding.isEmpty && removing.isEmpty }

    /// " · invited Sam and Alex", " · removed Pat", both, or nothing: what the saved toast adds.
    static func savedSuffix(invited: [String], removed: [String]) -> String {
        var parts: [String] = []
        if !invited.isEmpty { parts.append("invited " + ListFormatter.localizedString(byJoining: invited)) }
        if !removed.isEmpty { parts.append("removed " + ListFormatter.localizedString(byJoining: removed)) }
        return parts.isEmpty ? "" : " \u{00B7} " + parts.joined(separator: ", ")
    }
}

/// The guest list an edit sends. Google replaces the whole list with what it is given, so
/// everyone who stays goes back exactly as Google has them (their reply, their note, optional
/// or not: a list rebuilt from addresses alone would reset every reply to "awaiting"). People
/// taken off are left out, and new ones are added by address.
enum GoogleGuestPatch {
    /// Nil when the change changes nothing.
    static func attendees(_ current: [[String: Any]], change: GoogleGuestChange) -> [[String: Any]]? {
        func address(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !text.isEmpty else { return nil }
            return text
        }
        let removing = Set(change.removing.compactMap(address))
        var kept: [[String: Any]] = []
        var present = Set<String>()
        var changed = false
        for attendee in current {
            let email = address(attendee["email"])
            // The organizer can't be taken off their own event, and taking yourself off is a
            // reply (Decline), not an edit.
            let fixed = attendee["organizer"] as? Bool == true || attendee["self"] as? Bool == true
            if let email, removing.contains(email), !fixed {
                changed = true
                continue
            }
            if let email { present.insert(email) }
            kept.append(attendee)
        }
        for email in change.adding.compactMap(address) where isAddress(email) && present.insert(email).inserted {
            kept.append(["email": email])
            changed = true
        }
        return changed ? kept : nil
    }

    /// Enough of a check to keep a name typed without an address out of an invitation.
    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ")
    }
}

enum GoogleOwnWrites {
    /// A changed id is Banana's own when it was written, or is an occurrence of a series Banana
    /// wrote (`<master>_<instant>`) — adding a repeat to an event gives every occurrence a new id,
    /// and each used to read as someone else's change and re-plan the day.
    static func writtenAt(_ id: String, in ownWrites: [String: Date]) -> Date? {
        if let exact = ownWrites[id] { return exact }
        guard let separator = id.lastIndex(of: "_") else { return nil }
        return ownWrites[String(id[..<separator])]
    }
}
