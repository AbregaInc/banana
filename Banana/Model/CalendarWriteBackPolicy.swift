import Foundation

enum CalendarWriteBackVariant {
    case production
    case beta

    /// The variant this build writes as.
    static var current: CalendarWriteBackVariant {
        #if BANANA_BETA
        .beta
        #else
        .production
        #endif
    }

    var markerScheme: String {
        switch self {
        case .production: "banana"
        case .beta: "banana-beta"
        }
    }

    func owns(markerScheme: String?, appItemID: String? = nil) -> Bool {
        switch self {
        case .production:
            return markerScheme == "banana" || markerScheme == "quarters"
        case .beta:
            if markerScheme == "banana-beta" { return true }
            // Before variants had distinct markers, beta mirrored the same external meetings as
            // production but also wrote beta-only task blocks. Production owns the ambiguous
            // shared mirrors; beta retains its non-mirror ledger entries so it can reconcile them
            // instead of stranding hundreds of old Busy events.
            return markerScheme == "banana"
                && appItemID?.hasPrefix("mirror-") == false
        }
    }

    /// A normal event is reusable coverage for both variants. Production ignores beta mirrors so
    /// it always wins when both apps are installed; beta then reuses production's block and
    /// removes its own duplicate on its next reconciliation.
    func reusesCoverage(markerScheme: String?, appItemID: String? = nil) -> Bool {
        guard Self.isAppMarker(markerScheme) else { return true }
        if owns(markerScheme: markerScheme, appItemID: appItemID) { return false }
        switch self {
        case .production:
            return false
        case .beta:
            return markerScheme == CalendarWriteBackVariant.production.markerScheme
                || markerScheme == "quarters"
        }
    }

    static func isAppMarker(_ markerScheme: String?) -> Bool {
        markerScheme == "banana" || markerScheme == "banana-beta" || markerScheme == "quarters"
    }
}

enum CalendarChangeEchoPolicy {
    static let ordinaryDebounce: TimeInterval = 5
    /// After a push from the Banana service: the change is one, and read already.
    static let pushDebounce: TimeInterval = 1
    static let selfCommitWindow: TimeInterval = 10
    private static let boundaryAllowance: TimeInterval = 0.25

    /// EventKit does not identify a notification's author. A change near Banana's own commit may
    /// be its harmless echo or a real edit made at the same time, so it must be deferred beyond
    /// the echo window rather than discarded.
    static func debounceDelay(lastSelfCommit: Date?, now: Date = Date()) -> TimeInterval {
        guard let lastSelfCommit else { return ordinaryDebounce }
        let elapsed = now.timeIntervalSince(lastSelfCommit)
        guard elapsed >= 0, elapsed < selfCommitWindow else { return ordinaryDebounce }
        return selfCommitWindow - elapsed + boundaryAllowance
    }
}

/// Matching an account name as Apple Calendar recorded it against a Google account.
enum GoogleCalendarRouting {
    /// Apple names a Google account's source after the address it was added with, sometimes
    /// decorated. Accept the address exactly or contained, and nothing else — matching on a
    /// calendar's title alone would apply one account's setting to another account's calendar.
    static func sourceIsAccount(_ sourceTitle: String, account: String) -> Bool {
        let email = account.lowercased()
        guard !email.isEmpty else { return false }
        let source = sourceTitle.lowercased()
        return source == email || source.contains(email)
    }
}

// MARK: - Removal safety

/// Which unwanted busy blocks may actually be removed this pass.
///
/// A block is removed because nothing wants it any more, and "nothing wants it" is inferred from
/// one pass's view of the calendars. Every mass deletion so far came from a single pass that saw
/// less than was really there — a rejected token, a calendar list that failed to load. So a block
/// is only removed once two passes, both with every source readable and at least
/// `confirmationDelay` apart, agree it is unwanted. A transient blip is then never enough on its
/// own, while a meeting that really was deleted loses its block a minute or two later. Erring
/// this way leaves time blocked slightly longer; erring the other way makes it bookable.
struct BlockRemovalGate: Codable, Equatable {
    static let confirmationDelay: TimeInterval = 90

    /// Ledger key → when a healthy pass first found it unwanted.
    private(set) var pendingSince: [String: Date] = [:]

    /// The keys that may be removed now. An unhealthy pass confirms nothing and forgets nothing:
    /// it has no standing to say what is or isn't wanted.
    mutating func review(unwanted: Set<String>, sourcesHealthy: Bool, now: Date) -> Set<String> {
        guard sourcesHealthy else { return [] }
        pendingSince = pendingSince.filter { unwanted.contains($0.key) }
        var confirmed: Set<String> = []
        for key in unwanted {
            if let since = pendingSince[key] {
                if now.timeIntervalSince(since) >= Self.confirmationDelay { confirmed.insert(key) }
            } else {
                pendingSince[key] = now
            }
        }
        return confirmed
    }

    /// Stop tracking keys that are gone (removed, or no longer ours to remove).
    mutating func forget(_ keys: some Sequence<String>) {
        for key in keys { pendingSince[key] = nil }
    }
}

/// A pass that would remove a large share of Banana's blocks at once is held for the person to
/// confirm. Even with two agreeing passes, a systematic misreading — an exclusion that no longer
/// matches, a calendar that stopped being listed — looks exactly like "all of these are unwanted",
/// and 291 blocks disappearing is not something to find out about later.
enum MassRemovalGuard {
    static let minimumCount = 20
    static let maximumShare = 1.0 / 3.0

    static func shouldHold(removing: Int, owned: Int) -> Bool {
        removing >= minimumCount && Double(removing) > Double(max(owned, 1)) * maximumShare
    }
}

// MARK: - Destinations

/// Which Google calendars busy blocks are written to.
enum WriteBackDestinations {
    struct Calendar: Equatable, Sendable {
        let infoID: String
        /// Google's `summary`, and the account holder's own rename of it if there is one — either
        /// can be what Apple Calendar showed.
        let titles: [String]
        let accountEmail: String
        /// `accessRole == "owner"`. A calendar you can write to but don't own is someone else's.
        let isOwner: Bool
    }

    /// An exclusion recorded by name rather than by id: `(source title, calendar title)` as the
    /// device that made it saw them. Apple Calendar names a Google account's source after the
    /// address it was added with; Banana's own pickers name it "Google · address".
    struct Identity: Hashable, Sendable {
        let sourceTitle: String
        let calendarTitle: String
    }

    /// Whether a name-based exclusion refers to this calendar.
    ///
    /// Deliberately looser than `GoogleCalendarRouting` — which decides where blocks are WRITTEN
    /// and must never guess — because an exclusion only ever stops writing. Apple names a Google
    /// account's source after its address on the Mac but after the address's local part on the
    /// iPhone ("Bbaker"), and a phone-made exclusion must still apply. Where a local part is
    /// shared across accounts (bo@… on three domains) the match can hit a same-titled calendar
    /// on each; that errs toward excluding, the safe direction.
    static func matches(_ identity: Identity, _ calendar: Calendar) -> Bool {
        guard calendar.titles.contains(where: {
            $0.caseInsensitiveCompare(identity.calendarTitle) == .orderedSame
        }) else { return false }
        if GoogleCalendarRouting.sourceIsAccount(identity.sourceTitle, account: calendar.accountEmail) {
            return true
        }
        let source = identity.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let email = calendar.accountEmail.lowercased()
        guard let at = email.firstIndex(of: "@"), !source.isEmpty else { return false }
        return source == String(email[..<at])
    }

    /// Every calendar excluded either by id or by a name-based identity. The identities are how an
    /// exclusion made against Apple Calendar — the Family calendar, a colleague's shared calendar —
    /// keeps applying once the same calendar is reached through Google instead.
    static func excluded(_ calendars: [Calendar], ids: Set<String>,
                         identities: Set<Identity>) -> Set<String> {
        Set(calendars.filter { calendar in
            ids.contains(calendar.infoID) || identities.contains { matches($0, calendar) }
        }.map(\.infoID))
    }

    /// The calendars blocks are written to.
    ///
    /// A calendar you own is written to unless you excluded it. A calendar you can edit but don't
    /// own — a colleague's, a team's, family's — is written to only if you turned it on. Google
    /// lists every calendar an account subscribes to, where Apple Calendar only showed what was
    /// selected for sync, and writing "Busy" into someone else's calendar notifies everyone it is
    /// shared with. So that is opt-in, the same on every device, and cannot be undone by a
    /// settings sync from a device that has never seen the calendar.
    /// Calendars remembered from earlier passes that Google no longer lists. Only a complete list
    /// can say that — with an account signed out, its calendars are absent without being gone.
    static func vanishedCalendars(remembered: Set<String>, listed: Set<String>,
                                  listIsComplete: Bool) -> Set<String> {
        guard listIsComplete, !listed.isEmpty else { return [] }
        return remembered.subtracting(listed)
    }

    static func destinations(_ calendars: [Calendar], excludedIDs: Set<String>,
                             excludedIdentities: Set<Identity>,
                             includedShared: Set<String>) -> [String] {
        let excluded = excluded(calendars, ids: excludedIDs, identities: excludedIdentities)
        return calendars.filter { calendar in
            calendar.isOwner
                ? !excluded.contains(calendar.infoID)
                : includedShared.contains(calendar.infoID) && !excluded.contains(calendar.infoID)
        }
        .map(\.infoID)
        .sorted()
    }
}

/// The name a block is written under. Every device must arrive at the same name for the same
/// thing: ownership is read from the server, so a device that names a block differently sees the
/// other device's copy as unwanted and removes it, and the two fight forever.
enum WriteBackItemID {
    /// A task occurrence is named after its reminder's device-local id (`task:<id>` or
    /// `task:<id>:<due>`). For the block, that id is swapped for the provider id every synced
    /// device shares. Anything else keeps its occurrence id, which is already device-independent.
    static func forOccurrence(id: String, reminderID: String?, reminderExternalID: String?) -> String {
        guard let reminderID, let external = reminderExternalID, !external.isEmpty,
              id.hasPrefix("task:\(reminderID)") else { return id }
        return "task:\(external)" + id.dropFirst("task:\(reminderID)".count)
    }
}

/// Several copies of one busy block — two devices wrote it at the same moment, or copies adopted
/// from Apple Calendar. Every device reconciles the same blocks, so each must keep the same copy:
/// keeping "the one my own ledger knows" let the phone keep A and delete B while the iPad kept B
/// and deleted A, and the block vanished.
enum BusyBlockDuplicates {
    /// Chosen by the event id alone, so devices reconciling at the same time agree.
    static func copyToKeep(_ eventIDs: [String]) -> String? {
        eventIDs.min()
    }
}

/// A marker identifies Banana scaffolding, not the person who wrote it. On a calendar this
/// account owns, every marked block is its own. On anyone else's (a shared or family calendar)
/// a marked block is this person's only when it is the exact copy this app recorded writing, or
/// one of this person's connected accounts created it (the same person's other device). Anything
/// else is another person's: a pass never updates, deduplicates or removes it.
enum BusyBlockCleanupPolicy {
    static func mayDelete(calendarIsOwner: Bool, recordedEventID: String?, eventID: String,
                          creatorEmail: String? = nil, accountEmails: Set<String> = []) -> Bool {
        isOurs(calendarIsOwner: calendarIsOwner, eventID: eventID,
               recordedEventIDs: recordedEventID.map { [$0] } ?? [],
               creatorEmail: creatorEmail, accountEmails: accountEmails)
    }

    static func isOurs(calendarIsOwner: Bool, eventID: String, recordedEventIDs: Set<String>,
                       creatorEmail: String?, accountEmails: Set<String>) -> Bool {
        if calendarIsOwner || recordedEventIDs.contains(eventID) { return true }
        guard let creator = creatorEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !creator.isEmpty else { return false }
        return accountEmails.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == creator }
    }
}

// MARK: - Taking over blocks written through Apple Calendar

enum LegacyAdoptionDecision {
    /// Whether a clean dry run would change nothing on Google, so there is nothing to ask.
    static func isNothingToConfirm(_ preview: LegacyAdoptionReport) -> Bool {
        preview.errors.isEmpty && preview.adopted == 0
    }
}

/// What adopting Apple-Calendar-written blocks found. Every block ends up in exactly one bucket.
struct LegacyAdoptionReport: Codable, Equatable {
    var dryRun = false
    var examined = 0
    /// Tagged as Banana's (or, in a dry run, would be).
    var adopted = 0
    /// Another device had already tagged the same event.
    var alreadyAdopted = 0
    /// Apple Calendar no longer has the event: it was deleted, so there is nothing to adopt.
    var goneFromAppleCalendar = 0
    /// The block is on a calendar that is not a connected Google calendar.
    var notOnGoogle = 0
    /// Google has no event with that UID starting at the same time.
    var notFoundInGoogle = 0
    /// Written by the other build (production vs beta); left for it.
    var otherVariant = 0
    /// Failed a safety check (has attendees, no UID) and was left alone.
    var failedChecks = 0
    var errors: [String] = []

    var summary: String {
        "\(dryRun ? "DRY RUN — " : "")examined \(examined): adopted \(adopted), already adopted \(alreadyAdopted), gone \(goneFromAppleCalendar), not on Google \(notOnGoogle), not found in Google \(notFoundInGoogle), other build \(otherVariant), failed checks \(failedChecks), errors \(errors.count)"
    }
}

// MARK: - Copies whose source no longer qualifies, at any date

/// The Busy copies a set of events calls for, named as the writer names them
/// (`GoogleBusyBlocks.mirrorID` over the occurrence's title, start and end): each timed event that
/// is copied (`MeetingInfo.shouldMirrorBusyTime`) and each day of an all-day event that blocks it.
enum MirrorSources {
    static func qualifying(meetings: [MeetingInfo], allDay: [MeetingInfo], calendar: Calendar = .current) -> Set<String> {
        var ids = Set<String>()
        for meeting in meetings where meeting.shouldMirrorBusyTime {
            // `Occurrence.resolvedEnd`, as the writer has it.
            let end = meeting.end ?? meeting.start.addingTimeInterval(1800)
            guard end > meeting.start else { continue }
            ids.insert(GoogleBusyBlocks.mirrorID(title: meeting.title, start: meeting.start, end: end))
        }
        for event in allDay where !event.showsAsFree && event.calendarBlocksTime {
            let end = event.end ?? calendar.date(byAdding: .day, value: 1, to: event.start) ?? event.start
            for day in AllDayEvents.days(from: event.start, to: end, calendar: calendar) {
                let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                ids.insert(GoogleBusyBlocks.mirrorID(title: event.title, start: day, end: next))
            }
        }
        return ids
    }
}

/// A copy that should never have been written is wrong data whether its event is over or not.
/// The write-back pass judges current and future copies against what it plans; this judges the
/// rest of this person's Busy copies, at every date, against the events they copy.
///
/// Only copies of events (`mirror-…`) are judged here: their source is an event that can be read
/// back for any date. A past travel or task copy came from a route or a reminder that can no
/// longer be re-derived, so it is left. Copies that are current or ahead belong to the pass.
enum BusyCopySweep {
    /// The copies, by app item, whose event no longer calls for them. `copies` must already be
    /// only this person's (`BusyBlockCleanupPolicy`).
    static func unwanted(copies: [String: [BusyCopyPlanner.Owned]], qualifying: Set<String>,
                         now: Date) -> [String: [BusyCopyPlanner.Owned]] {
        var result: [String: [BusyCopyPlanner.Owned]] = [:]
        for (itemID, blocks) in copies where itemID.hasPrefix("mirror-") && !qualifying.contains(itemID) {
            let over = blocks.filter { $0.end <= now }
            if !over.isEmpty { result[itemID] = over }
        }
        return result
    }

    /// How far back the sources have to be read: the start of the earliest copy judged.
    static func earliestStart(copies: [String: [BusyCopyPlanner.Owned]], now: Date) -> Date? {
        copies.filter { $0.key.hasPrefix("mirror-") }.values.joined()
            .filter { $0.end <= now }.compactMap(\.start).min()
    }
}
