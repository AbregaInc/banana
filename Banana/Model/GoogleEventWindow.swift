import Foundation
import CoreLocation

/// One event as Google returned it, with the calendar it was read from.
struct GoogleFetchedEvent {
    /// The raw Google calendar id (not Banana's prefixed info id).
    let calendarID: String
    let event: GoogleEvent
}

/// Turns raw Google events into the calendar window the rest of Banana plans with: the agenda,
/// the busy coverage write-back reuses, the located events travel reads, and the travel blocks
/// another device wrote.
///
/// This is the Google-only replacement for `CalendarService.eventWindow`, and it keeps that
/// function's rules on purpose — the same events count as meetings, as busy, and as travel — so
/// dropping Apple Calendar changes where the data comes from, not what Banana does with it. The
/// one real difference is ownership: a block Banana wrote is recognised by the private extended
/// properties Google stores for it, which survive sync, instead of by a URL marker that CalDAV
/// strips.
enum GoogleEventWindowBuilder {

    /// Who wrote an event, read from its private extended properties.
    struct Ownership: Equatable {
        /// The writing build's marker (`banana`, `banana-beta`, legacy `quarters`).
        let variant: String
        let appItemID: String
    }

    /// An event reduced to the fields any of the outputs need.
    struct Normalized {
        let calendarID: String
        let eventID: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let notes: String?
        let conferenceURL: URL?
        /// "Show as: Free". Still on the timeline, never busy.
        let isFree: Bool
        let isDeclined: Bool
        /// Your reply as Google spells it, when you are on the guest list.
        let myResponse: String?
        /// There are other (human) guests and every one of them declined.
        let othersAllDeclined: Bool
        /// Guests other than you (rooms excluded).
        let otherGuestCount: Int
        let attendeeCount: Int
        let isRecurring: Bool
        let timeZone: TimeZone?
        let ownership: Ownership?
        /// Google's kind: "default", or one it manages ("birthday", "workingLocation"…).
        var eventType: String? = nil
        /// Raw ids of other calendars this event was merged from by `dedupe`.
        var alsoOn: [String] = []
        var isSharedCalendar = false
        var calendarOwner: String? = nil
        var iCalUID: String? = nil
        var originalStart: Date? = nil

        var copyKey: String? {
            guard let uid = iCalUID, !uid.isEmpty else { return nil }
            return "uid:\(uid)\u{1F}\(originalStart.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "")"
        }

        var isAppWritten: Bool { ownership != nil && !isSharedCalendar }

        var isSharedAvailability: Bool {
            isSharedCalendar && CalendarEventTitlePolicy.isPrivacyPlaceholder(title) && otherGuestCount == 0
        }

        /// A privacy-style title ("Busy", "Private", untitled) on something that is not a real
        /// meeting in its own right — another tool's copy, or a free/busy-only view of someone
        /// else's calendar. An *invitation* you're on is a real meeting whatever its title: a
        /// "Busy" invite dropped here once never reached the other calendars, and Calendly
        /// booked straight over it.
        var isPlaceholder: Bool {
            !isSharedCalendar && CalendarEventTitlePolicy.isPrivacyPlaceholder(title) && otherGuestCount == 0
        }
    }

    // MARK: - Ownership

    static func ownership(of event: GoogleEvent) -> Ownership? {
        guard let properties = event.extendedProperties?.private,
              let variant = properties[GoogleBusyBlocks.variantKey],
              CalendarWriteBackVariant.isAppMarker(variant),
              let id = properties[GoogleBusyBlocks.itemIDKey],
              !id.isEmpty
        else { return nil }
        return Ownership(variant: variant, appItemID: id)
    }

    // MARK: - Normalising

    static func normalize(_ fetched: GoogleFetchedEvent) -> Normalized? {
        let event = fetched.event
        guard event.status != "cancelled",
              let eventID = event.id,
              let range = GoogleCalendarDates.range(of: event) else { return nil }
        let conferenceURL = event.hangoutLink.flatMap(URL.init(string:))
            ?? event.conferenceData?.entryPoints?
                .first(where: { $0.entryPointType == "video" })?.uri.flatMap(URL.init(string:))
        let me = event.attendees?.first(where: { $0.selfAttendee == true })
        let others = (event.attendees ?? []).filter {
            $0.selfAttendee != true && !($0.email ?? "").hasSuffix("resource.calendar.google.com")
        }
        return Normalized(
            calendarID: fetched.calendarID,
            eventID: eventID,
            title: event.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            start: range.start,
            end: range.end,
            isAllDay: range.isAllDay,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            notes: event.description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            conferenceURL: conferenceURL,
            isFree: event.transparency == "transparent",
            isDeclined: me?.responseStatus == "declined",
            myResponse: me?.responseStatus,
            othersAllDeclined: !others.isEmpty && others.allSatisfy { $0.responseStatus == "declined" },
            otherGuestCount: others.count,
            attendeeCount: event.attendees?.count ?? 0,
            isRecurring: event.recurringEventId != nil || event.recurrence?.isEmpty == false,
            timeZone: (event.start?.timeZone).flatMap(TimeZone.init(identifier:)),
            ownership: ownership(of: event),
            eventType: event.eventType,
            iCalUID: event.iCalUID,
            originalStart: event.originalStartTime.flatMap { original in
                original.dateTime.flatMap(GoogleCalendarDates.parseRFC3339)
                    ?? original.date.flatMap(GoogleCalendarDates.parseDate)
            }
        )
    }

    // MARK: - The window

    /// `allDayCalendarIDs`: the raw ids of the calendars whose all-day events show and block
    /// (`AllDayEvents.shows`). None by default: a read for something else (templates, probes)
    /// takes no all-day events.
    static func window(from fetched: [GoogleFetchedEvent],
                       calendar: Calendar = .current,
                       allDayCalendarIDs: Set<String> = [],
                       allDayChoice: AllDayEvents.Choice = .init(),
                       ownedCalendarIDs: Set<String>? = nil,
                       calendarOwners: [String: String] = [:]) -> CalendarEventWindow {
        // A stable order makes every tie below deterministic, so two devices reading the same
        // calendars keep the same copy of a duplicated meeting.
        let events = fetched.compactMap { item -> Normalized? in
            guard var event = normalize(item) else { return nil }
            event.calendarOwner = calendarOwners[item.calendarID]?.lowercased()
            event.isSharedCalendar = ownedCalendarIDs.map { !$0.contains(item.calendarID) } ?? false
            return event
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.eventID < $1.eventID
        }

        let busyIntervals = events.compactMap { event -> CalendarBusyInterval? in
            guard blocksTime(event) || blocksDays(event, shown: allDayCalendarIDs, choice: allDayChoice) else { return nil }
            return CalendarBusyInterval(
                calendarID: GoogleCalendarIDs.calendarInfoID(event.calendarID),
                start: event.start,
                end: event.end,
                isAppWritten: event.isAppWritten,
                appMarkerScheme: event.isAppWritten ? event.ownership?.variant : nil,
                appItemID: event.isAppWritten ? event.ownership?.appItemID : nil)
        }

        let meetings = perDay(events.filter(qualifiesAsMeeting), calendar: calendar)
            .map(meetingInfo)
            .sorted { $0.start < $1.start }

        let travelEvents = perDay(events.filter(qualifiesForTravel), calendar: calendar)
            .map(travelEvent)
            .sorted { $0.start < $1.start }

        let allDay = perDay(events.filter { qualifiesAsAllDay($0, shown: allDayCalendarIDs, choice: allDayChoice) },
                            calendar: calendar)
            .map(allDayInfo)
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.title < $1.title }

        return CalendarEventWindow(
            meetings: meetings,
            busyIntervals: busyIntervals,
            travelEvents: travelEvents,
            syncedTravelBlocks: syncedTravelBlocks(in: events),
            allDayEvents: allDay)
    }

    // MARK: - Rules (the same ones CalendarService applies to EventKit events)

    /// A timed entry that is really on your day: not all-day, not cancelled, not one you declined.
    /// Transparency is deliberately NOT considered here — a dinner marked free still shows.
    static func occupiesTimeline(_ event: Normalized) -> Bool {
        !event.isAllDay && event.end > event.start && !event.isDeclined
    }

    /// Whether an event consumes availability. Transparency is honoured here and only here.
    static func blocksTime(_ event: Normalized) -> Bool {
        occupiesTimeline(event) && !event.isFree
    }

    /// An all-day event that shows: on a calendar whose all-day events show, not declined, an
    /// event rather than a status ("Home"), not hidden by you, and not one of Banana's own busy
    /// copies.
    static func qualifiesAsAllDay(_ event: Normalized, shown: Set<String>,
                                  choice: AllDayEvents.Choice = .init()) -> Bool {
        event.isAllDay && event.end > event.start && !event.isDeclined && !event.isAppWritten
            && AllDayEvents.isEvent(eventType: event.eventType) && shown.contains(event.calendarID)
            && !AllDayEvents.isHidden(title: event.title, eventType: event.eventType, choice: choice)
    }

    /// An all-day event that blocks its days: one that shows and is Busy on your copy — or
    /// Banana's own busy copy of one, which is coverage another calendar already has.
    static func blocksDays(_ event: Normalized, shown: Set<String>,
                           choice: AllDayEvents.Choice = .init()) -> Bool {
        guard event.isAllDay, event.end > event.start, !event.isFree, !event.isDeclined else { return false }
        return event.isAppWritten || qualifiesAsAllDay(event, shown: shown, choice: choice)
    }

    /// Shown on the agenda as a meeting. Banana's own blocks never are — that is the loop where a
    /// block reads back as a meeting and gets mirrored again — and neither are bare "Busy"
    /// placeholders, which are coverage, not content.
    static func qualifiesAsMeeting(_ event: Normalized) -> Bool {
        guard !event.isAppWritten else { return false }
        guard !event.isPlaceholder else { return false }
        return occupiesTimeline(event)
    }

    /// Looser than a meeting: keeps all-day located events (a hotel stay is exactly the anchor
    /// for the days you're not flying). Only things with a place count.
    static func qualifiesForTravel(_ event: Normalized) -> Bool {
        !event.isAppWritten && !event.isSharedAvailability && !event.isDeclined && event.location != nil
    }

    /// Explicitly shared support text. Labels preserve equality only within this report;
    /// never include titles, addresses, emails, provider IDs or extended-property values.
    static func reconciliationReport(_ fetched: [GoogleFetchedEvent], calendars: [GoogleCalendar]) -> String {
        let byID = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var labels: [String: [String: String]] = [:]
        func label(_ value: String?, kind: String) -> String {
            guard let value, !value.isEmpty else { return "missing" }
            if let existing = labels[kind]?[value] { return existing }
            let result = "\(kind)\((labels[kind]?.count ?? 0) + 1)"
            labels[kind, default: [:]][value] = result
            return result
        }
        let events = fetched.compactMap { item -> Normalized? in
            guard var event = normalize(item), let calendar = byID[item.calendarID] else { return nil }
            event.isSharedCalendar = !calendar.isOwnedByAccount
            event.calendarOwner = calendar.reconciliationOwner
            return event
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.eventID < $1.eventID
        }
        // Report only intervals with shared availability: unrelated event details never enter it.
        struct Interval: Hashable { let start: Date; let end: Date; let allDay: Bool }
        let intervals = Set(events.filter(\.isSharedAvailability).map { Interval(start: $0.start, end: $0.end, allDay: $0.isAllDay) })
        var lines = ["Banana calendar reconciliation v1", "Report-local labels; no event titles, emails, locations or provider identifiers."]
        for event in events where intervals.contains(Interval(start: event.start, end: event.end, allDay: event.isAllDay)) {
            let role = byID[event.calendarID]?.accessRole ?? "missing"
            let fingerprint = event.isSharedAvailability ? event.ownership?.appItemID
                : GoogleBusyBlocks.mirrorID(title: event.title, start: event.start, end: event.end)
            lines.append("\(event.start.ISO8601Format())–\(event.end.ISO8601Format()) allDay=\(event.isAllDay) calendar=\(label(event.calendarID, kind: "c")) role=\(role) owner=\(label(event.calendarOwner, kind: "p")) availability=\(event.isSharedAvailability) free=\(event.isFree) uid=\(label(event.copyKey, kind: "u")) mirror=\(label(fingerprint, kind: "m")) marker=\(event.ownership != nil)")
        }
        lines.append("Shared availability entries: \(events.filter(\.isSharedAvailability).count)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Dedupe

    /// Collapse the same event seen on several calendars — an invite that reached two of your
    /// accounts, or a meeting and its "Busy" mirror. Scoped per day, like the EventKit reader.
    private static func perDay(_ events: [Normalized], calendar: Calendar) -> [Normalized] {
        var byDay: [Date: [Normalized]] = [:]
        var order: [Date] = []
        for event in events {
            let day = calendar.startOfDay(for: event.start)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(event)
        }
        return order.flatMap { dedupe(byDay[$0] ?? []) }
    }

    static func dedupe(_ events: [Normalized]) -> [Normalized] {
        struct Interval: Hashable { let start: Date; let end: Date; let allDay: Bool }
        var groups: [Interval: [Normalized]] = [:]
        var order: [Interval] = []
        for event in events {
            let key = Interval(start: event.start, end: event.end, allDay: event.isAllDay)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(event)
        }
        var result: [Normalized] = []
        for key in order {
            let group = groups[key] ?? []
            let real = group.filter { !$0.isPlaceholder }
            let candidates = real.isEmpty ? group : real
            if candidates.count == 1 { result.append(candidates[0]); continue }
            let hasMirrors = candidates.contains { $0.isSharedAvailability && $0.ownership?.appItemID.hasPrefix("mirror-") == true }
            var merged: [String: Normalized] = [:]
            var keys: [String] = []
            // Register every original copy BEFORE picking a richer winner: the winning invite
            // may be on the viewer's calendar while a losing copy belongs to the mirror's owner.
            var sources: [String: Set<String>] = [:]
            func add(_ event: Normalized, as key: String) {
                guard let existing = merged[key] else {
                    merged[key] = event; keys.append(key); return
                }
                let preferNew = (existing.isSharedAvailability && !event.isSharedAvailability)
                    || (existing.isSharedAvailability == event.isSharedAvailability && richness(event) > richness(existing))
                var winner = preferNew ? event : existing
                let loser = preferNew ? existing : event
                for id in [loser.calendarID] + loser.alsoOn where id != winner.calendarID && !winner.alsoOn.contains(id) {
                    winner.alsoOn.append(id)
                }
                merged[key] = winner
            }
            for event in candidates where !event.isSharedAvailability {
                let identity: String
                if let flight = FlightParser.parse(title: event.title, location: event.location, notes: event.notes) {
                    identity = "✈\(flight.destination.code)"
                } else if let copy = event.copyKey { identity = copy }
                else {
                    let scope = event.isSharedCalendar ? (event.calendarOwner ?? event.calendarID) : ""
                    identity = "title:\(scope):\(normalizedTitle(event.title))"
                }
                add(event, as: identity)
                if hasMirrors, !event.isFree, let owner = event.calendarOwner {
                    let mirror = GoogleBusyBlocks.mirrorID(title: event.title, start: event.start, end: event.end)
                    sources["\(owner)\u{1F}\(mirror)", default: []].insert(identity)
                }
            }
            for event in candidates where event.isSharedAvailability {
                var identity = "availability:\(event.calendarID):\(event.eventID)"
                if let copy = event.copyKey, merged[copy] != nil {
                    identity = copy
                } else if let owner = event.calendarOwner, let item = event.ownership?.appItemID, item.hasPrefix("mirror-") {
                    let source = "\(owner)\u{1F}\(item)"
                    if let matches = sources[source], matches.count == 1, let match = matches.first {
                        identity = match
                    } else {
                        // Without a visible original, proven mirrors still form ONE private Busy.
                        identity = "mirror:\(source)"
                    }
                }
                add(event, as: identity)
            }
            result += keys.compactMap { merged[$0] }
        }
        return result
    }

    /// Lowercased, scheduling prefixes and leading symbols removed, so the same meeting under
    /// slightly different names across accounts collapses to one.
    static func normalizedTitle(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["appointment:", "invitation:", "invite:", "canceled:", "cancelled:",
                        "accepted:", "declined:", "tentative:", "updated:", "fwd:", "re:"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        while let first = s.first, !first.isLetter, !first.isNumber { s = String(s.dropFirst()) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func richness(_ event: Normalized) -> Int {
        var score = 0
        if event.location != nil { score += 2 }
        if event.notes != nil { score += 1 }
        if event.attendeeCount > 0 { score += 1 }
        return score
    }

    // MARK: - Outputs

    private static func meetingInfo(_ event: Normalized) -> MeetingInfo {
        let location = event.isSharedAvailability ? nil : event.location
        let detected = event.isSharedAvailability ? nil : MeetingLink.detect(location: location, notes: event.notes,
                                          url: event.conferenceURL)
        // A link alone doesn't make it a call: Google adds a Meet link to any event you invite
        // someone to, so an appointment at a street address is somewhere you go — and gets its
        // travel time — while keeping the link for anyone joining remotely.
        let isVirtual = looksVirtual(location)
            || (detected != nil && !PlaceQuery.isStreetAddress(location ?? ""))
        return MeetingInfo(
            start: event.start,
            end: event.end,
            coordinate: nil,
            address: location,
            isVirtual: isVirtual,
            title: event.isSharedAvailability ? "Busy" : (event.title.isEmpty ? "your meeting" : event.title),
            eventID: GoogleCalendarIDs.eventInfoID(calendarID: event.calendarID, eventID: event.eventID),
            joinURL: detected?.url,
            platform: detected?.platform,
            calendarID: GoogleCalendarIDs.calendarInfoID(event.calendarID),
            showsAsFree: event.isFree,
            isRecurring: event.isRecurring,
            myResponse: MeetingResponse(googleStatus: event.myResponse),
            othersAllDeclined: event.othersAllDeclined,
            alsoOnCalendarIDs: event.alsoOn.map(GoogleCalendarIDs.calendarInfoID),
            isAvailabilityOnly: event.isSharedAvailability)
    }

    private static func allDayInfo(_ event: Normalized) -> MeetingInfo {
        MeetingInfo(
            start: event.start,
            end: event.end,
            coordinate: nil,
            address: event.location,
            isVirtual: false,
            title: event.title.isEmpty ? "All day" : event.title,
            eventID: GoogleCalendarIDs.eventInfoID(calendarID: event.calendarID, eventID: event.eventID),
            calendarID: GoogleCalendarIDs.calendarInfoID(event.calendarID),
            showsAsFree: event.isFree,
            isRecurring: event.isRecurring,
            myResponse: MeetingResponse(googleStatus: event.myResponse),
            othersAllDeclined: event.othersAllDeclined,
            alsoOnCalendarIDs: event.alsoOn.map(GoogleCalendarIDs.calendarInfoID),
            isAllDay: true)
    }

    private static func looksVirtual(_ address: String?) -> Bool {
        guard let address = address?.lowercased() else { return false }
        return ["http://", "https://", "zoom.", "zoom.us", "meet.google", "teams.microsoft", "webex"]
            .contains { address.contains($0) }
    }

    private static func travelEvent(_ event: Normalized) -> TravelEvent {
        TravelEvent(title: event.title, location: event.location, notes: event.notes,
                    coordinate: nil, start: event.start, end: event.end,
                    isAllDay: event.isAllDay, timeZone: event.timeZone)
    }

    /// Travel blocks Banana wrote — possibly on another device — grouped per item across the
    /// calendars they were mirrored to. Any variant's: a second device must defend the time either
    /// way, and none of these are ever written back again (they arrive as `.external`).
    static func syncedTravelBlocks(in events: [Normalized]) -> [CalendarSyncedTravelBlock] {
        let marked = events.filter {
            $0.isAppWritten && ($0.ownership?.appItemID.hasPrefix("travel-") == true) && blocksTime($0)
        }
        let grouped = Dictionary(grouping: marked) { $0.ownership!.appItemID }
        return grouped.compactMap { id, copies -> CalendarSyncedTravelBlock? in
            guard let start = copies.map(\.start).min(),
                  let end = copies.map(\.end).max(), end > start else { return nil }
            let informative = copies.map(\.title).first {
                let value = $0.lowercased()
                return !value.isEmpty && value != "busy"
            }
            return CalendarSyncedTravelBlock(appItemID: id, title: informative ?? "Travel time",
                                             start: start, end: end)
        }.sorted { $0.start < $1.start }
    }
}

/// Small agenda questions several screens ask of a meeting list.
enum CalendarAgenda {
    /// The first meeting on each day — the one a wake time is planned around. Today's already-
    /// started meetings don't count; later days count from midnight.
    static func firstMeetings(_ meetings: [MeetingInfo], now: Date,
                              calendar: Calendar = .current) -> [Date: MeetingInfo] {
        let today = calendar.startOfDay(for: now)
        var winner: [Date: MeetingInfo] = [:]
        for meeting in meetings where !meeting.isAvailabilityOnly {
            let day = calendar.startOfDay(for: meeting.start)
            guard meeting.start >= now || day > today else { continue }
            if let existing = winner[day], existing.start <= meeting.start { continue }
            winner[day] = meeting
        }
        return winner
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Finding the Google copy of a block Banana wrote through Apple Calendar, from the ledger alone.
///
/// An EventKit identifier for a CalDAV event is `<store id>:<event UID>`, and the UID is what
/// CalDAV hands Google as the event's iCalendar UID. So the ledger — on any device, read on any
/// device — names the Google event directly, and no Apple Calendar access is needed to find it.
enum LegacyBlockMatcher {
    enum Outcome: Equatable {
        /// Untagged, unambiguous, no attendees: this is the block.
        case adopt(calendarID: String, eventID: String)
        /// Already carries this build's marker.
        case alreadyOurs(calendarID: String, eventID: String, appItemID: String)
        /// Carries the other build's marker.
        case otherVariant
        /// No live event with that UID in the calendars read.
        case notFound
        /// Found, but not safe to claim: it has attendees, or the UID names different events.
        case unsafe
    }

    /// The event UID inside an EventKit identifier, or nil if it has no store prefix.
    static func uid(fromEventKitIdentifier identifier: String) -> String? {
        guard let colon = identifier.lastIndex(of: ":") else { return nil }
        let uid = identifier[identifier.index(after: colon)...]
        return uid.isEmpty ? nil : String(uid)
    }

    /// Google events indexed by upper-cased iCalUID. Cancelled events are left out.
    static func index(_ events: [GoogleFetchedEvent]) -> [String: [GoogleFetchedEvent]] {
        var index: [String: [GoogleFetchedEvent]] = [:]
        for item in events where item.event.status != "cancelled" {
            guard let uid = item.event.iCalUID, !uid.isEmpty, item.event.id != nil else { continue }
            index[uid.uppercased(), default: []].append(item)
        }
        return index
    }

    static func match(eventKitIdentifier: String, in index: [String: [GoogleFetchedEvent]],
                      variant: String) -> Outcome {
        guard let uid = uid(fromEventKitIdentifier: eventKitIdentifier),
              let hits = index[uid.uppercased()], !hits.isEmpty else { return .notFound }
        // A calendar shared between two accounts lists the same event twice, under one id.
        let distinct = Dictionary(hits.map { ($0.event.id!, $0) }, uniquingKeysWith: { first, _ in first })
        guard distinct.count == 1, let hit = distinct.values.first, let eventID = hit.event.id else {
            return .unsafe
        }
        guard hit.event.attendees?.isEmpty ?? true else { return .unsafe }
        if let owner = GoogleEventWindowBuilder.ownership(of: hit.event) {
            return owner.variant == variant
                ? .alreadyOurs(calendarID: hit.calendarID, eventID: eventID, appItemID: owner.appItemID)
                : .otherVariant
        }
        return .adopt(calendarID: hit.calendarID, eventID: eventID)
    }
}
