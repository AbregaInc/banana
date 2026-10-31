import Foundation
import os
import Combine
import GoogleSignIn

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct GoogleCalendarEvent: Identifiable {
    let id: String
    let calendarInfoID: String
    let calendarTitle: String
    let calendarColorHex: String?
    /// What you may change (`GoogleEventEditPolicy`): everything, only your own alerts and
    /// show-as on someone else's invitation, or nothing.
    let access: GoogleEventEditAccess
    /// Nil when Google didn't say (an event made on this calendar: yours).
    let organizerIsSelf: Bool?
    /// The version read, sent back as If-Match so a save never overwrites a change made since.
    let etag: String?
    /// The series' version, when this is an occurrence (its repeat lives there).
    var seriesEtag: String? = nil
    let isRecurring: Bool
    let htmlLink: URL?
    let attendees: [GoogleCalendarAttendee]
    let timeZoneID: String?
    var originalReminders: GoogleCalendarReminderSelection
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String
    var notes: String
    var availability: CalendarEventAvailability
    var reminders: GoogleCalendarReminderSelection
    var recurrenceRules: [String]

    /// Title, time, place, notes, repeat and calendar.
    var canEdit: Bool { access == .full }
    /// Your own alerts and show-as, at least.
    var canEditPersonal: Bool { access != .readOnly }
    /// Guests besides you.
    var otherGuestCount: Int { attendees.filter { !$0.isCurrentUser }.count }
    var notifiesGuests: Bool {
        access == .full && GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: organizerIsSelf,
                                                                 otherGuestCount: otherGuestCount)
    }
    /// The repeat as the picker shows it.
    var recurrence: EventRecurrence { EventRepeat.parse(recurrenceRules, start: start) }

    /// This event as it was, to write back over `edited` — its alerts included, when the edit
    /// changed them (a save only sends alerts that differ from what was read).
    func undoing(_ edited: GoogleCalendarEvent) -> GoogleCalendarEvent {
        var copy = self
        copy.originalReminders = edited.reminders
        return copy
    }

    var patchFields: GoogleEventPatch.Fields {
        GoogleEventPatch.Fields(title: title, start: start, end: end, isAllDay: isAllDay, location: location,
                                notes: notes, availability: availability,
                                reminders: reminders == originalReminders ? nil : reminders,
                                timeZoneID: timeZoneID)
    }
}

#if DEBUG
extension GoogleCalendarEvent {
    /// `--event-editor`: a standup every Mon, Wed and Fri — or, as an invitation, someone else's —
    /// for the editor's screenshots and UI test, without Google.
    static func preview(invitation: Bool, withGuests: Bool = false) -> GoogleCalendarEvent {
        let calendar = Calendar.current
        let start = calendar.nextDate(after: Date(), matching: DateComponents(hour: 9, minute: 30, weekday: 2),
                                      matchingPolicy: .nextTime) ?? Date()
        let organizer = GoogleCalendarAttendee(email: "sam@example.com", displayName: "Sam Rivera",
                                               responseStatus: "accepted", isCurrentUser: false, isOrganizer: true)
        let me = GoogleCalendarAttendee(email: "me@example.com", displayName: nil, responseStatus: "accepted",
                                        isCurrentUser: true, isOrganizer: false)
        // `--event-editor-guests`: your own event with two guests, for the guest controls.
        let mine = [GoogleCalendarAttendee(email: "me@example.com", displayName: nil, responseStatus: "accepted",
                                           isCurrentUser: true, isOrganizer: true),
                    GoogleCalendarAttendee(email: "sam@example.com", displayName: "Sam Rivera",
                                           responseStatus: "accepted", isCurrentUser: false, isOrganizer: false),
                    GoogleCalendarAttendee(email: "pat@example.com", displayName: nil,
                                           responseStatus: "declined", isCurrentUser: false, isOrganizer: false)]
        return GoogleCalendarEvent(
            id: GoogleCalendarIDs.eventInfoID(calendarID: "preview@example.com", eventID: "preview"),
            calendarInfoID: GoogleCalendarIDs.calendarInfoID("preview@example.com"),
            calendarTitle: "Work", calendarColorHex: "#1A73E8",
            access: invitation ? .personalOnly : .full, organizerIsSelf: !invitation, etag: nil,
            isRecurring: true, htmlLink: nil, attendees: invitation ? [organizer, me] : (withGuests ? mine : []),
            timeZoneID: TimeZone.current.identifier, originalReminders: .calendarDefault,
            title: invitation ? "Design review" : "Team standup", start: start,
            end: start.addingTimeInterval(30 * 60), isAllDay: false, location: "", notes: "",
            availability: .busy, reminders: .calendarDefault,
            recurrenceRules: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"])
    }
}
#endif

/// What a save did, for its Undo.
struct GoogleEventEditOutcome {
    /// "This and following" made a new series from the edited occurrence on.
    var newSeriesInfoID: String?
    /// The series whose repeat was changed or cut short, and its lines before.
    var seriesInfoID: String?
    var seriesLinesBefore: [String]?
}

struct GoogleCalendarAttendee: Identifiable {
    let email: String
    let displayName: String?
    let responseStatus: String?
    let isCurrentUser: Bool
    let isOrganizer: Bool

    var id: String { email }
}

struct GoogleCalendarMeetingFetch {
    let meetings: [MeetingInfo]
    let succeeded: Bool
}

/// One read of every included Google calendar over a window.
struct GoogleWindowFetch {
    let window: CalendarEventWindow
    /// Every included calendar was read fresh just now, and no connected account is signed out or
    /// failed to list its calendars. Anything less is partial data — fine to show, never grounds
    /// for removing a busy block.
    let isComplete: Bool
    /// What could not be read, for the log and Settings.
    let problems: [String]
    /// Calendars (as calendar-info ids, the form `MeetingInfo.calendarID` carries) this window has
    /// events for — read now, or from the last good copy. A calendar missing here is one the
    /// timeline knows nothing new about, and keeps showing what it had.
    var covered: Set<String> = []

    static let nothingConnected = GoogleWindowFetch(window: .empty, isComplete: true, problems: [], covered: [])
}

/// Banana's calendar: every connected Google account, read and written through Google's REST API.
///
/// This is the only calendar provider. Apple Calendar used to be the primary one, with Google
/// added on top; it was dropped because a block written to a Google calendar through Apple's
/// CalDAV mirror comes back with its ownership marker stripped, so no device can prove it wrote
/// it, and because Apple's copy of a Google calendar lags and drops calendars the API sees.
@MainActor
final class GoogleCalendarService: ObservableObject {
    static let shared = GoogleCalendarService()

    static let eventsScope = "https://www.googleapis.com/auth/calendar.events"
    static let calendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    private static let requiredScopes = [eventsScope, calendarListScope]
    private static let accountHintKey = "googleCalendar.accountHint.v1"
    private static let log = Logger(subsystem: "com.boris.banana", category: "google")
    private static let calendarIDPrefix = "google-calendar:"
    private static let eventIDPrefix = "google-event:"

    /// Every connected account, newest last. Replaces the single `accountEmail`: `GIDSignIn`
    /// keeps one `currentUser`, so connecting a second Google account used to silently disconnect
    /// the first. Credentials live in `GoogleAccountStore`; the SDK is now used only to run the
    /// consent flow.
    @Published private(set) var accounts: [GoogleAccountCredential] = []

    /// Accounts whose credential Google has rejected. They stay CONNECTED and listed — dropping
    /// them was wrong twice over: the synced store would re-supply the account moments later, so
    /// it flapped; and a dropped account silently stops covering that calendar's time with no
    /// visible reason. Listed-but-broken is honest and fixable.
    @Published private(set) var accountsNeedingReconnect: Set<String> = []

    /// True when at least one account cannot currently be read.
    ///
    /// Write-back consults this before deleting anything: a calendar Banana cannot see is not a
    /// calendar with no meetings, and treating it that way deleted 291 busy blocks the first time
    /// a token was rejected.
    var hasDegradedSources: Bool {
        !accountsNeedingReconnect.isEmpty || !accountsWithUnreadableCalendars.isEmpty
    }

    /// Accounts whose calendar LIST failed to load on the last attempt. Their calendars are kept
    /// from the previous load rather than dropped — a calendar that vanishes from the list is read
    /// as "no meetings there", which is how a network blip used to turn into deleted blocks.
    @Published private(set) var accountsWithUnreadableCalendars: Set<String> = []

    /// Why each account needs reconnecting, in Google's own words.
    @Published private(set) var reconnectReasons: [String: String] = [:]

    /// Accounts the Banana service has no Google access of its own for (`BananaAccount`): each
    /// needs one more sign-in, with a code for the service, and until then shows as "Sign in
    /// again" like a rejected one. Reads still work: these aren't in `accountsNeedingReconnect`.
    @Published private(set) var accountsNeedingServiceSignIn: Set<String> = []

    /// Every account to sign in again, for either reason.
    var accountsToSignInAgain: Set<String> { accountsNeedingReconnect.union(accountsNeedingServiceSignIn) }

    /// The service said which connected accounts it can't act for yet (by lowercased email).
    func serviceNeedsSignIn(for emails: Set<String>) {
        guard emails != accountsNeedingServiceSignIn else { return }
        accountsNeedingServiceSignIn = emails
    }

    /// Last good read of each calendar over the core window. Serves the several screens that
    /// ask for overlapping ranges within a few seconds of each other from one request, and is the
    /// last-known-good copy shown when a read fails.
    ///
    /// Each copy carries a sync token, so bringing it up to date is an incremental read — see
    /// `GoogleEventSync` — and it is saved to disk, so a launch continues from it too.
    private var eventCache: [String: GoogleEventSync.Snapshot] = [:]
    /// Calendars whose disk copy has been looked for this run (found or not).
    private var diskCacheChecked: Set<String> = []

    /// Event ids Banana itself wrote, and when. A change to one of these within the echo window
    /// is Banana hearing its own write, not news — see `GoogleEventSync.containsNews`.
    private var recentOwnWrites: [String: Date] = [:]
    /// How many reads in this launch found a change someone else made
    /// (`newsSerialAfterRefreshing`).
    private(set) var newsSerial = 0
    /// When a read last found a change someone else made. `hasChanges(since:)` answers from it.
    private var lastNewsAt: Date?
    /// How the last core read went, per calendar: incremental, full, or failed. For the probe.
    private(set) var lastSyncTrace: [String: String] = [:]

    private func noteOwnWrite(_ eventIDs: String?...) {
        let now = Date()
        recentOwnWrites = GoogleEventSync.pruned(recentOwnWrites, now: now)
        for id in eventIDs.compactMap({ $0 }) { recentOwnWrites[id] = now }
    }

    /// How long a read is reused before asking Google again. Short: this is to collapse the burst
    /// of reads one recompute makes, not to hide real changes.
    private static let cacheLifetime: TimeInterval = 45

    /// When the calendar list was last loaded. It used to be loaded only at launch, sign-in and a
    /// manual refresh, so a calendar deleted in Google stayed "listed" in a running app — every
    /// read of it failed, and one failed read suspends all removals.
    private var calendarsLoadedAt: Date?

    /// Whether `calendars` is a complete, current answer: restored, loaded this launch, and every
    /// account's list read. Anything less is "not known yet" — never grounds for forgetting a
    /// calendar's colour or settings.
    var calendarListIsComplete: Bool {
        restorationFinished && calendarsLoadedAt != nil && accountsWithUnreadableCalendars.isEmpty
            && !calendars.isEmpty
    }
    private static let calendarListLifetime: TimeInterval = 10 * 60

    /// Load the calendar list if there is none or it is older than `calendarListLifetime`.
    private func loadCalendarsIfStale() async {
        if GoogleEventSync.calendarListIsStale(loadedAt: calendarsLoadedAt, isEmpty: calendars.isEmpty,
                                               someUnreadable: !accountsWithUnreadableCalendars.isEmpty,
                                               now: Date(), lifetime: Self.calendarListLifetime) {
            try? await loadCalendars()
        }
    }

    /// Google says this calendar does not exist (deleted, or access removed) — as opposed to a
    /// read that merely failed.
    nonisolated static func isCalendarGone(_ error: Error) -> Bool {
        if case GoogleCalendarError.api(let status, _) = error { return status == 404 || status == 410 }
        return false
    }

    /// A calendar turned out not to exist: reload the list on the next read rather than in ten
    /// minutes, so it stops being asked about.
    func noteCalendarGone() {
        calendarsLoadedAt = nil
    }
    /// The most recently connected account, kept for copy that names "your Google account".
    var accountEmail: String? { accounts.last?.email }
    /// Non-secret account identity learned from another Banana device. OAuth credentials remain
    /// in each device's local Google Sign-In keychain; this only preselects the right account.
    @Published private(set) var suggestedAccountEmail: String?
    @Published private(set) var calendars: [GoogleCalendar] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    private let cloud = NSUbiquitousKeyValueStore.default
    private var accountHintObserver: NSObjectProtocol?
    /// Minted access tokens per account, so a burst of calendar requests costs one refresh.
    private var tokenCache: [String: GoogleTokenMinter.MintedToken] = [:]
    /// Whether the saved accounts have been restored (or found absent) this launch. Before that,
    /// "no calendars" means "not loaded yet", not "none".
    private(set) var restorationFinished = false
    private var restorationTask: Task<Void, Never>?

    var isConfigured: Bool { clientID != nil }

    var isConnected: Bool { !accounts.isEmpty }

    /// Which account owns a calendar, for choosing the credential a request should use.
    private func account(forCalendarID id: String) -> GoogleAccountCredential? {
        guard let email = calendars.first(where: { $0.id == id })?.accountEmail else {
            // Fall back to the only account when there is one — a calendar list that has not
            // finished loading should not turn into "not connected".
            return accounts.count == 1 ? accounts.first : nil
        }
        return accounts.first { $0.id == email.lowercased() }
    }

    /// Whether this build may change anything in `email`'s account: always in Stable, and in
    /// Beta only an account marked as a test account. `send` refuses the rest.
    private func mayChange(account email: String) -> Bool {
        AppVariant.current.mayCallGoogle(method: "POST", account: email, testAccounts: BetaTestAccounts.all)
    }

    var writableCalendarInfos: [CalendarSourceInfo] {
        calendars
            .filter(\.isWritable)
            .map { calendarInfo(for: $0) }
            .sorted(by: Self.calendarInfoSort)
    }

    /// Every calendar busy blocks could be written to, with what write-back needs to decide
    /// whether it should be.
    var writeBackCandidates: [WriteBackDestinations.Calendar] {
        calendars.filter { $0.isWritable && !$0.isDeleted && mayChange(account: $0.accountEmail) }.map {
            WriteBackDestinations.Calendar(
                infoID: Self.calendarInfoID($0.id),
                titles: [$0.summaryOverride, $0.summary].compactMap { $0 }.filter { !$0.isEmpty },
                accountEmail: $0.accountEmail,
                isOwner: $0.isOwnedByAccount)
        }
    }

    /// Every calendar, in the shape exclusion matching needs (not only writable ones: a calendar
    /// can be excluded from what counts as a meeting without being writable).
    var matchableCalendars: [WriteBackDestinations.Calendar] {
        calendars.filter { !$0.isDeleted }.map {
            WriteBackDestinations.Calendar(
                infoID: Self.calendarInfoID($0.id),
                titles: [$0.summaryOverride, $0.summary].compactMap { $0 }.filter { !$0.isEmpty },
                accountEmail: $0.accountEmail,
                isOwner: $0.isOwnedByAccount)
        }
    }

    var allCalendarInfos: [CalendarSourceInfo] {
        calendars.map { calendarInfo(for: $0) }.sorted(by: Self.calendarInfoSort)
    }

    private var clientID: String? {
        BuildConfig.googleClientID()
    }

    private init() {
        if let clientID {
            // With the Banana service, each sign-in also hands over a one-time code for it
            // (`BananaAccount.googleSignedIn`).
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(
                clientID: clientID,
                serverClientID: BananaService.isAvailable ? BananaService.googleServerClientID : nil)
            // Known at once, not after the network. Whether an account is connected decides what
            // the first frame shows — the Mac's gate, Today's "not connected" card — and waiting
            // for the calendar list to load first put "Reconnect your Google account" on screen
            // at every launch. One keychain read; the calendars follow in `performRestore`.
            accounts = GoogleAccountStore.load()
        }
        observeAccountHint()
        Task { @MainActor [weak self] in
            await self?.restoreIfNeeded()
        }
    }

    func restoreIfNeeded() async {
        if restorationFinished { return }
        if let restorationTask {
            await restorationTask.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRestore()
        }
        restorationTask = task
        await task.value
        restorationTask = nil
    }

    func connect() async {
        guard isConfigured else {
            lastError = "Google Calendar isn’t configured for this Banana build."
            return
        }
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            // Only hint when there is nothing connected yet: that is the case the hint helps,
            // and the case where preselecting cannot hide an account you are trying to add.
            let result = try await interactiveSignIn(
                hint: accounts.isEmpty ? suggestedAccountEmail : nil)
            try accept(result.user)
            try await loadCalendars()
            Telemetry.shared.record(.feature(.calendarConnected))
            await BananaAccount.shared.googleSignedIn(code: result.serverAuthCode)
        } catch is CancellationError {
            // Closing Google's sign-in sheet is not an error worth persisting in Settings.
        } catch {
            lastError = Self.friendlyMessage(for: error)
            Telemetry.shared.record(.failure(.googleSignIn))
        }
    }

    /// Re-run consent for ONE account that is already connected.
    ///
    /// Needed because a credential can stop working without anything being wrong at this end:
    /// Google revokes a grant, a password changes, scopes are withdrawn. The minter drops the
    /// account when that happens, and until now the only way back was "Add another Google
    /// account" and picking it out of the chooser — which works, but reads as adding something
    /// you already have.
    ///
    /// The login hint IS right here, unlike when adding: this is a request to re-authorise one
    /// named account, so preselecting it is exactly what is wanted.
    func reconnect(email: String) async {
        guard isConfigured else {
            lastError = "Google Calendar isn’t configured for this Banana build."
            return
        }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let result = try await interactiveSignIn(hint: email)
            guard let signedIn = result.user.profile?.email,
                  signedIn.lowercased() == email.lowercased() else {
                // Signing in as someone else here would silently swap which account is connected.
                lastError = "That signed in as \(result.user.profile?.email ?? "another account"). Use “Add another Google account” for a different one."
                return
            }
            try accept(result.user)
            accountsNeedingReconnect.remove(email.lowercased())
            reconnectReasons[email.lowercased()] = nil
            tokenCache[email.lowercased()] = nil
            try await loadCalendars()
            await BananaAccount.shared.googleSignedIn(code: result.serverAuthCode)
        } catch is CancellationError {
        } catch {
            lastError = Self.friendlyMessage(for: error)
        }
    }

    /// Google's identity token for a connected account, minted with the refresh token already held:
    /// no sign-in sheet. Fresh each time (it lasts an hour and is used at once).
    func identityToken(forEmail email: String) async throws -> String {
        guard let account = accounts.first(where: { $0.id == email.lowercased() }), let clientID else {
            throw GoogleCalendarError.notConnected
        }
        let minted = try await GoogleTokenMinter.mint(refreshToken: account.refreshToken, clientID: clientID)
        tokenCache[account.id] = minted
        guard let idToken = minted.idToken else { throw GoogleCalendarError.notConnected }
        return idToken
    }

    /// Asks Google to tell the Banana service when a calendar changes (`events.watch`), with this
    /// device's own access. Changes nothing in the calendar, so Beta may do it for any account.
    func openWatch(calendarID: String, email: String, channelID: String, token: String,
                   address: String, ttlSeconds: Int) async throws -> (resourceID: String, expiration: Date) {
        guard let account = accounts.first(where: { $0.id == email.lowercased() }) else { throw GoogleCalendarError.notConnected }
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(Self.pathComponent(calendarID))/events/watch")!
        let body = try JSONSerialization.data(withJSONObject: [
            "id": channelID, "type": "web_hook", "address": address, "token": token,
            "params": ["ttl": String(ttlSeconds)],
        ])
        let data: Data
        do { data = try await watchCall(url: url, body: body, account: account) }
        catch GoogleCalendarError.api(status: 400, let message) where message?.localizedCaseInsensitiveContains("not supported") == true {
            throw CalendarWatchUnsupported()
        }
        struct Answer: Decodable { let resourceId: String; let expiration: String? }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw GoogleCalendarError.malformedResponse }
        let ms = answer.expiration.flatMap(Double.init) ?? (Date().timeIntervalSince1970 + Double(ttlSeconds)) * 1000
        return (answer.resourceId, Date(timeIntervalSince1970: ms / 1000))
    }

    /// Ends a watch this device's account opened (`channels.stop`). Gone already counts as ended.
    func closeWatch(channelID: String, resourceID: String, email: String) async {
        guard let account = accounts.first(where: { $0.id == email.lowercased() }),
              let body = try? JSONSerialization.data(withJSONObject: ["id": channelID, "resourceId": resourceID]) else { return }
        _ = try? await watchCall(url: URL(string: "https://www.googleapis.com/calendar/v3/channels/stop")!, body: body, account: account)
    }

    private func watchCall(url: URL, body: Data, account: GoogleAccountCredential) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("Bearer \(try await accessToken(for: account))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.malformedResponse }
            if http.statusCode == 401, attempt == 1 { tokenCache[account.id] = nil; continue }
            if http.statusCode == 404, url.path.hasSuffix("/channels/stop") { return data }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data))?.error.message
                throw GoogleCalendarError.api(status: http.statusCode, message: message)
            }
            return data
        }
    }

    /// A fresh Google sign-in whose one-time code shows the Banana service who is asking
    /// (deleting the account needs one). Nothing connected in the app changes.
    func freshSignInCode(hint: String?) async throws -> String {
        let result = try await interactiveSignIn(hint: hint)
        guard let code = result.serverAuthCode else { throw GoogleCalendarError.notConnected }
        return code
    }

    func disconnect() async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        for account in accounts { await BananaAccount.shared.googleDisconnected(email: account.email) }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                GIDSignIn.sharedInstance.disconnect { error in
                    if let error { continuation.resume(throwing: Self.signInFailure(error)) }
                    else { continuation.resume(returning: ()) }
                }
            }
        } catch {
            // Signing out locally still makes the requested disconnect effective on this device;
            // retain the revoke error so the user knows the remote grant may still exist.
            GIDSignIn.sharedInstance.signOut()
            lastError = Self.friendlyMessage(for: error)
        }
        GoogleAccountStore.removeAll()
        accounts = []
        calendars = []
        tokenCache = [:]
        eventCache = [:]
        coreFetchedAt = nil
        coreFailures = [:]
        accountsNeedingReconnect = []
        accountsNeedingServiceSignIn = []
        accountsWithUnreadableCalendars = []
        reconnectReasons = [:]
        restorationFinished = true
        clearAccountHint()
    }

    /// Pick up accounts connected on another device.
    ///
    /// The credential store is read once at launch, so a Mac left running never noticed an account
    /// added on the phone — iCloud Keychain had carried it across, but nothing re-read it. Cheap
    /// enough (one keychain read) to do whenever the app comes forward or a refresh is asked for.
    ///
    /// Only accounts ADDED elsewhere are adopted. A disconnect is not mirrored: a device that has
    /// not yet synced would otherwise look like "this account is gone" and drop a working
    /// credential, and losing calendar access is far worse than a stale row that one tap removes.
    @discardableResult
    func adoptAccountsFromStore() -> Bool {
        let stored = GoogleAccountStore.load()
        let known = Set(accounts.map(\.id))
        let added = stored.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return false }
        accounts = (accounts + added)
            .sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
        return true
    }

    func refresh() async {
        await restoreIfNeeded()
        adoptAccountsFromStore()
        guard isConnected else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            try await loadCalendars()
        } catch {
            lastError = Self.friendlyMessage(for: error)
        }
    }

    /// Google events in the requested half-open window. Partial on failure — use `meetingFetch`
    /// or `windowFetch` where the difference matters.
    func meetings(from start: Date, to end: Date, excluding excludedIDs: Set<String>) async -> [MeetingInfo] {
        await windowFetch(from: start, to: end, excluding: excludedIDs).window.meetings
    }

    /// Same fetch with an explicit success bit so a stale-while-revalidate caller can distinguish
    /// a real empty calendar from a network failure and retain its last-known-good Google slice.
    func meetingFetch(
        from start: Date,
        to end: Date,
        excluding excludedIDs: Set<String>
    ) async -> GoogleCalendarMeetingFetch {
        let fetch = await windowFetch(from: start, to: end, excluding: excludedIDs)
        return GoogleCalendarMeetingFetch(meetings: fetch.window.meetings, succeeded: fetch.isComplete)
    }

    /// Everything Banana plans with, read from every included calendar in `[start, end)`.
    ///
    /// Each calendar is read independently and in parallel. One that fails is served from its
    /// last good read if there is one, and the fetch is reported incomplete either way — so the
    /// timeline keeps showing what it knew, while write-back refuses to remove anything on the
    /// strength of it.
    /// `allDay`: whose all-day events to show (`AllDayEvents`); nil takes none — a read for
    /// something other than the timeline.
    func windowFetch(from start: Date, to end: Date,
                     excluding excludedIDs: Set<String>,
                     allDay: AllDayEvents.Choice? = nil) async -> GoogleWindowFetch {
        guard end > start else { return .nothingConnected }
        let began = Date()
        await restoreIfNeeded()
        guard isConnected else { return .nothingConnected }
        let restored = Date()
        await loadCalendarsIfStale()
        let listed = Date()
        defer {
            // Where a slow read went, when it was slow: signing in again, the calendar lists, or
            // the calendars themselves.
            let done = Date()
            if done.timeIntervalSince(began) > 1.5 {
                let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
                PlaybackDiagnostics.shared.log(
                    "📅 google read",
                    "\(ms(began, done))ms — sign-in \(ms(began, restored)) · lists \(ms(restored, listed)) · calendars \(ms(listed, done)) (\(calendars.count))")
            }
        }
        let readable = calendars.filter { !$0.isDeleted && !$0.isHidden }
        let included = readable.filter { !excludedIDs.contains(Self.calendarInfoID($0.id)) }

        var fetched: [GoogleFetchedEvent] = []
        var problems: [String] = []
        var covered: Set<String> = []
        var complete = !hasDegradedSources
        if !accountsNeedingReconnect.isEmpty {
            problems.append("signed out: \(accountsNeedingReconnect.sorted().joined(separator: ", "))")
        }
        if !accountsWithUnreadableCalendars.isEmpty {
            problems.append("calendar list unreadable: \(accountsWithUnreadableCalendars.sorted().joined(separator: ", "))")
        }

        let core = Self.coreWindow(now: Date())
        if core.start <= start && core.end >= end {
            // The routine case: one shared read of every calendar over the core window, reused by
            // every screen that asks within its lifetime and awaited by any that ask while it runs.
            await refreshCoreRead(readable, window: core)
            for calendar in included {
                if let failure = coreFailures[calendar.id] {
                    complete = false
                    problems.append("\(calendar.displayTitle): \(failure)")
                    let fallback = lastKnownGood(calendar.id, from: core.start, to: core.end)
                    if let fallback { fetched += fallback; covered.insert(Self.calendarInfoID(calendar.id)) }
                } else if let cached = eventCache[calendar.id] {
                    fetched += cached.events.map { GoogleFetchedEvent(calendarID: calendar.id, event: $0) }
                    covered.insert(Self.calendarInfoID(calendar.id))
                } else {
                    complete = false
                    problems.append("\(calendar.displayTitle): missing from the shared read")
                }
            }
        } else {
            // Somewhere else in time (another week, six months of history): read just that.
            let results = await readCalendars(included, from: start, to: end)
            for calendar in included {
                switch results[calendar.id] {
                case .success(let events):
                    fetched += events.map { GoogleFetchedEvent(calendarID: calendar.id, event: $0) }
                    covered.insert(Self.calendarInfoID(calendar.id))
                case .failure(let error):
                    complete = false
                    problems.append("\(calendar.displayTitle): \(Self.friendlyMessage(for: error))")
                    // Whatever the last good copy knows about this stretch of time.
                    if let fallback = lastKnownGood(calendar.id, from: start, to: end) {
                        fetched += fallback
                        covered.insert(Self.calendarInfoID(calendar.id))
                    }
                case nil:
                    complete = false
                }
            }
        }

        if problems.isEmpty { lastError = nil } else {
            lastError = problems.joined(separator: "; ")
            Self.log.error("[google] incomplete read — \(problems.joined(separator: "; "), privacy: .public)")
        }
        // Into the playback journal too, once per distinct set of problems: "events vanished,
        // then came back" was undiagnosable because this only reached the unified log.
        let summary = problems.sorted().joined(separator: "; ")
        if summary != lastJournaledProblems {
            lastJournaledProblems = summary
            if !summary.isEmpty {
                PlaybackDiagnostics.shared.log("calendar read incomplete", summary)
            }
        }
        let allDayIDs = allDay.map { choice in
            Set(included.filter {
                AllDayEvents.shows(calendarID: $0.id, isOwner: $0.accessRole == "owner",
                                   hidden: choice.hidden, shown: choice.shown)
            }.map(\.id))
        } ?? []
        // Thousands of events over a dozen calendars, sliced and built off the main thread: built
        // on it, every read held the app for seconds — the lag while the Day/Week spinner turned.
        let choice = allDay ?? .init()
        let read = fetched
        let ownedCalendarIDs = Set(included.filter(\.isOwnedByAccount).map(\.id))
        let calendarOwners = Dictionary(uniqueKeysWithValues: included.compactMap { calendar in
            calendar.reconciliationOwner.map { (calendar.id, $0) }
        })
        let window = await Task.detached(priority: .userInitiated) {
            // Sliced to what was asked for (Google's own rule: overlap).
            let sliced = read.filter { item in
                guard let span = GoogleCalendarDates.range(of: item.event) else { return false }
                return span.end > start && span.start < end
            }
            return GoogleEventWindowBuilder.window(from: sliced, allDayCalendarIDs: allDayIDs,
                                                   allDayChoice: choice, ownedCalendarIDs: ownedCalendarIDs,
                                                   calendarOwners: calendarOwners)
        }.value
        return GoogleWindowFetch(window: window, isComplete: complete, problems: problems, covered: covered)
    }

    private var lastJournaledProblems = ""

    /// Why each calendar failed in the last core read, if it did.
    private var coreFailures: [String: String] = [:]
    private var coreFetchedAt: Date?
    private var coreCalendarIDs: Set<String> = []
    private var coreRead: Task<Void, Never>?

    /// Make the core read current: reuse it if it is fresh and covers these calendars, join it if
    /// one is already running — then check again, because the running read may have been started
    /// for a different set of calendars (say, before the calendar list had loaded) — otherwise
    /// start one. On return every calendar in `readable` is either read or has a recorded failure.
    private func refreshCoreRead(_ readable: [GoogleCalendar], window: (start: Date, end: Date)) async {
        while let running = coreRead {
            await running.value
        }
        let ids = Set(readable.map(\.id))
        if let coreFetchedAt, ids.isSubset(of: coreCalendarIDs),
           Date().timeIntervalSince(coreFetchedAt) < Self.cacheLifetime,
           readable.allSatisfy({ isAnswered($0.id, window: window) }) {
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = Date()
            await self.loadDiskSnapshots(for: readable.map(\.id))
            let results = await self.syncCalendars(readable, window: window)
            var failures: [String: String] = [:]
            var toSave: [(String, GoogleEventSync.Snapshot)] = []
            var news = false
            let ownWrites = self.recentOwnWrites
            for calendar in readable {
                switch results[calendar.id] {
                case .success(let outcome):
                    self.eventCache[calendar.id] = outcome.snapshot
                    if !outcome.changedIDs.isEmpty || outcome.wasFullRead {
                        toSave.append((calendar.id, outcome.snapshot))
                    }
                    if outcome.hadBaseline,
                       GoogleEventSync.containsNews(outcome.changedIDs, ownWrites: ownWrites, now: startedAt) {
                        news = true
                        // Which calendar and events counted as someone else's change — a change
                        // poll that keeps finding "news" re-plans the whole timeline every time.
                        let foreign = outcome.changedIDs.filter { ownWrites[$0] == nil }
                        let titles = outcome.snapshot.events.filter { foreign.contains($0.id ?? "") }
                            .prefix(3).map { $0.summary ?? "?" }
                        PlaybackDiagnostics.shared.log("calendar news",
                            "\(calendar.displayTitle): \(outcome.changedIDs.count) changed, \(foreign.count) not ours, \(outcome.wasFullRead ? "full" : "incremental") — \(titles.joined(separator: " | "))")
                    }
                case .failure(let error):
                    failures[calendar.id] = Self.friendlyMessage(for: error)
                case nil:
                    failures[calendar.id] = "no answer from the read"
                }
            }
            if news {
                self.lastNewsAt = startedAt
                self.newsSerial += 1
            }
            if !toSave.isEmpty {
                // Encoding a busy calendar is real work; keep it off the main actor.
                Task.detached(priority: .utility) {
                    for (id, snapshot) in toSave { GoogleEventDiskCache.save(snapshot, calendarID: id) }
                }
            }
            self.coreFailures = failures
            self.coreCalendarIDs = ids
            self.coreFetchedAt = startedAt
            // Cleared by the read itself, so a caller waiting on it never sees a finished read
            // still marked as running.
            self.coreRead = nil
        }
        // Set before anything suspends, so the task cannot finish before it is recorded.
        coreRead = task
        await task.value
    }

    private(set) var lastReadTrace = ""

    /// Every event on every writable calendar over the core window, raw — for matching blocks
    /// by iCalendar UID. `complete` is false when any of those calendars failed to read.
    func writableCalendarEvents() async -> (events: [GoogleFetchedEvent], complete: Bool) {
        await restoreIfNeeded()
        await loadCalendarsIfStale()
        let writable = calendars.filter { $0.isWritable && !$0.isDeleted }
        let core = Self.coreWindow(now: Date())
        await refreshCoreRead(calendars.filter { !$0.isDeleted && !$0.isHidden } + writable.filter(\.isHidden),
                              window: core)
        var events: [GoogleFetchedEvent] = []
        var complete = !hasDegradedSources
        for calendar in writable {
            if coreFailures[calendar.id] != nil { complete = false }
            events += (eventCache[calendar.id]?.events ?? []).map {
                GoogleFetchedEvent(calendarID: calendar.id, event: $0)
            }
        }
        return (events, complete)
    }

    /// On-demand Settings report from the same cached inputs as Plan. Never sent automatically.
    func calendarReconciliationReport(from start: Date, to end: Date, excluding excludedIDs: Set<String>) -> String {
        let included = calendars.filter { !$0.isDeleted && !$0.isHidden && !excludedIDs.contains(Self.calendarInfoID($0.id)) }
        let fetched = included.flatMap { calendar in
            (eventCache[calendar.id]?.events ?? []).compactMap { event -> GoogleFetchedEvent? in
                guard let range = GoogleCalendarDates.range(of: event), range.end > start, range.start < end else { return nil }
                return GoogleFetchedEvent(calendarID: calendar.id, event: event)
            }
        }
        let missing = included.filter { eventCache[$0.id] == nil || coreFailures[$0.id] != nil }.count
        return GoogleEventWindowBuilder.reconciliationReport(fetched, calendars: included)
            + "\nCalendars missing or using a failed read: \(missing)"
    }

    /// Read-only owner-side ACL inspection. Existing OAuth grants only; never requests wider
    /// consent, writes an ACL, or treats a failed/partial read as proof of no sharing.
    func diagnoseSharing(with viewerEmail: String) async -> [String] {
        struct Page: Decodable {
            struct Rule: Decodable {
                struct Scope: Decodable { let type: String; let value: String? }
                let scope: Scope
                let role: String
            }
            let items: [Rule]?
            let nextPageToken: String?
        }
        let viewer = viewerEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard viewer.contains("@") else { return ["Supply a viewer email; no requests made."] }
        let domain = viewer.split(separator: "@").last.map(String.init) ?? ""
        var lines: [String] = []
        for calendar in calendars where calendar.isOwnedByAccount && !calendar.isDeleted {
            var roles: [String] = [], groups = 0, pageToken: String?
            do {
                repeat {
                    var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(Self.pathComponent(calendar.id))/acl")!
                    url.queryItems = [.init(name: "maxResults", value: "250"),
                                      .init(name: "fields", value: "items(scope(type,value),role),nextPageToken")]
                    if let pageToken { url.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
                    let page: Page = try await request(url: url.url!, account: account(forCalendarID: calendar.id))
                    for rule in page.items ?? [] where rule.role != "none" {
                        let value = rule.scope.value?.lowercased()
                        if rule.scope.type == "user" && value == viewer { roles.append("direct=\(rule.role)") }
                        if rule.scope.type == "domain" && value == domain { roles.append("domain=\(rule.role)") }
                        if rule.scope.type == "default" { roles.append("public=\(rule.role)") }
                        if rule.scope.type == "group" { groups += 1 }
                    }
                    pageToken = page.nextPageToken
                } while pageToken != nil
                lines.append("\(calendar.displayTitle) [\(calendar.accountEmail)]: \(roles.isEmpty ? "no direct/domain/public grant" : roles.joined(separator: ", ")); group grants with unverified membership=\(groups)")
            } catch {
                lines.append("\(calendar.displayTitle) [\(calendar.accountEmail)]: sharing UNKNOWN — \(Self.friendlyMessage(for: error))")
            }
        }
        return lines
    }

    /// For the headless probe: read each calendar directly, bypassing the shared read, and say
    /// exactly what came back.
    func diagnoseReads(from start: Date, to end: Date) async -> [String] {
        let readable = calendars.filter { !$0.isDeleted && !$0.isHidden }
        let results = await readCalendars(readable, from: start, to: end)
        var lines = ["direct read of \(readable.count) calendar(s), \(results.count) answer(s); shared read: fetched \(coreFetchedAt.map { "\(Int(-$0.timeIntervalSinceNow))s ago" } ?? "never"), covering \(coreCalendarIDs.count), failures \(coreFailures.count), cached \(eventCache.count)"]
        for calendar in readable {
            switch results[calendar.id] {
            case .success(let events): lines.append("  \(calendar.displayTitle): \(events.count) event(s)")
            case .failure(let error): lines.append("  \(calendar.displayTitle): FAILED \(String(describing: error))")
            case nil: lines.append("  \(calendar.displayTitle): NO RESULT")
            }
        }
        lines.append("  trace: \(lastReadTrace)")
        return lines
    }

    /// For the headless probe: sync, sync again, then check the synced copy of every calendar
    /// against a direct full read — the same ids, no more, no fewer.
    func diagnoseSync() async -> [String] {
        var lines: [String] = []
        let readable = calendars.filter { !$0.isDeleted && !$0.isHidden }
        let window = Self.coreWindow(now: Date())
        for round in 1...3 {
            let began = Date()
            let changed = await hasChanges(since: began.addingTimeInterval(-1), excluding: [])
            lines.append("round \(round): \(String(format: "%.2f", -began.timeIntervalSinceNow))s, news: \(changed.map(String.init(describing:)) ?? "unknown")")
            for calendar in readable {
                lines.append("  \(calendar.displayTitle): \(lastSyncTrace[calendar.id] ?? "no trace")")
            }
        }
        let direct = await readCalendars(readable, from: window.start, to: window.end)
        var mismatches = 0
        for calendar in readable {
            guard case .success(let truth)? = direct[calendar.id] else {
                lines.append("  \(calendar.displayTitle): direct read failed")
                continue
            }
            let inWindow: (GoogleEvent) -> Bool = { event in
                guard let span = GoogleCalendarDates.range(of: event) else { return false }
                return span.end > window.start && span.start < window.end
            }
            let synced = Set((eventCache[calendar.id]?.events ?? []).filter(inWindow).compactMap(\.id))
            let expected = Set(truth.filter { $0.status != "cancelled" }.filter(inWindow).compactMap(\.id))
            if synced != expected {
                mismatches += 1
                lines.append("  MISMATCH \(calendar.displayTitle): synced \(synced.count), direct \(expected.count), missing \(expected.subtracting(synced).count), extra \(synced.subtracting(expected).count)")
            }
        }
        lines.append("compared \(readable.count) calendar(s) with a direct read: \(mismatches) mismatch(es)")
        return lines
    }

    /// The last core read either has this calendar over the window, or knows why it doesn't.
    private func isAnswered(_ calendarID: String, window: (start: Date, end: Date)) -> Bool {
        if coreFailures[calendarID] != nil { return true }
        guard let cached = eventCache[calendarID] else { return false }
        return cached.covers(window.start, window.end)
    }

    /// Read several calendars concurrently. A calendar whose token cannot be minted fails on its
    /// own; the others still read.
    private func readCalendars(_ calendars: [GoogleCalendar], from start: Date,
                               to end: Date) async -> [String: Result<[GoogleEvent], Error>] {
        var results: [String: Result<[GoogleEvent], Error>] = [:]
        var requests: [(id: String, url: URL, token: String)] = []
        for calendar in calendars {
            do {
                let token = try await accessToken(forCalendarID: calendar.id)
                requests.append((calendar.id, Self.eventsListURL(calendarID: calendar.id,
                                                                 from: start, to: end), token))
            } catch {
                results[calendar.id] = .failure(error)
            }
        }
        // One task per calendar, all started before any is awaited, so the reads overlap.
        let running = requests.map { request in
            (request.id, Task.detached(priority: .userInitiated) { () -> Result<[GoogleEvent], Error> in
                do {
                    return .success(try await Self.fetchAllEvents(firstPage: request.url,
                                                                 token: request.token))
                } catch {
                    return .failure(error)
                }
            })
        }
        var fetched: [(String, Result<[GoogleEvent], Error>)] = []
        for (id, task) in running {
            fetched.append((id, await task.value))
        }
        lastReadTrace = "calendars \(calendars.count), token failures \(results.count), requests \(requests.count), answers \(fetched.count)"
        for (id, result) in fetched {
            if case .failure(let error) = result, Self.isCalendarGone(error) {
                Self.log.notice("[google] calendar \(id, privacy: .public) no longer exists — reloading the list")
                calendarsLoadedAt = nil
            }
            if case .failure(GoogleCalendarError.api(status: 401, _)) = result,
               let owner = account(forCalendarID: id) {
                // The token was minted fine and then refused — drop it so the next read mints
                // again rather than failing the same way for the rest of its hour.
                tokenCache[owner.id] = nil
            }
            results[id] = result
        }
        return results
    }

    /// The last good read of a calendar, whatever its age, if it covers the range.
    /// The last good copy's events for a calendar whose read just failed, or nil if there is none
    /// that reaches into the window.
    ///
    /// It used to require the copy to cover the WHOLE window. The core window moves with the date,
    /// so after midnight yesterday's copy never did — and a calendar whose first read of the day
    /// failed (it's a full read, since the window changed) showed nothing at all until a read
    /// succeeded: today's events vanished, then came back. Any overlap is now used; the caller
    /// slices to the window, and a failed read is never grounds for removing anything.
    private func lastKnownGood(_ calendarID: String, from start: Date, to end: Date) -> [GoogleFetchedEvent]? {
        guard let cached = eventCache[calendarID], GoogleEventSync.overlaps(cached, start, end) else { return nil }
        return cached.events.map { GoogleFetchedEvent(calendarID: calendarID, event: $0) }
    }

    /// The range every routine read falls inside: a week back (for yesterday's flight and the
    /// write-back cleanup window) to beyond the write-back travel horizon.
    private static func coreWindow(now: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -8, to: today) ?? today
        // Ownership cleanup uses elapsed days from now; leave two local days beyond its
        // end so a late-night read still covers it across a spring-forward transition.
        let end = calendar.date(byAdding: .day, value: OccurrenceStore.writeBackTravelHorizonDays + 16, to: today) ?? today
        return (start, end)
    }

    /// Forget cached reads, after Banana itself changed something on a calendar. The last good
    /// copies are kept for failure fallback; only their freshness is dropped.
    func invalidateEventCache() {
        coreFetchedAt = nil
    }

    /// Whether anything on the included calendars has changed since `date`, other than Banana's
    /// own writes. Brings the shared read up to date to find out — incrementally, so this is one
    /// small request per calendar, cheap enough to ask every couple of minutes while the app is
    /// open (it replaces Apple Calendar's change notification). Nil when nothing could be read.
    /// Brings the shared read up to date, incrementally (one small request per calendar), and
    /// returns `newsSerial`: how many reads in this launch have found a change someone else made.
    /// A poll that remembers the number it last saw is told of each change once
    /// (`CalendarRefreshPace.Seen`). Nil when nothing could be read.
    func newsSerialAfterRefreshing(excluding excludedIDs: Set<String>) async -> Int? {
        await restoreIfNeeded()
        guard isConnected else { return newsSerial }
        await loadCalendarsIfStale()
        let readable = calendars.filter { !$0.isDeleted && !$0.isHidden }
        let included = readable.filter { !excludedIDs.contains(Self.calendarInfoID($0.id)) }
        coreFetchedAt = nil
        await refreshCoreRead(readable, window: Self.coreWindow(now: Date()))
        guard included.contains(where: { coreFailures[$0.id] == nil }) else { return nil }
        return newsSerial
    }

    /// The same, by the clock, for the headless probe (`diagnoseSync`).
    func hasChanges(since date: Date, excluding excludedIDs: Set<String>) async -> Bool? {
        await restoreIfNeeded()
        guard isConnected else { return false }
        await loadCalendarsIfStale()
        let readable = calendars.filter { !$0.isDeleted && !$0.isHidden }
        let included = readable.filter { !excludedIDs.contains(Self.calendarInfoID($0.id)) }
        coreFetchedAt = nil
        await refreshCoreRead(readable, window: Self.coreWindow(now: Date()))
        guard included.contains(where: { coreFailures[$0.id] == nil }) else { return nil }
        return (lastNewsAt ?? .distantPast) > date
    }

    private static func eventsListURL(calendarID: String, from start: Date, to end: Date) -> URL {
        var components = URLComponents(url: eventsURL(calendarID: calendarID),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: rfc3339(start)),
            URLQueryItem(name: "timeMax", value: rfc3339(end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "2500"),
        ]
        return components.url!
    }

    /// Every page of an events list, off the main actor — a busy calendar is thousands of events
    /// of JSON, and decoding it is not work the UI should wait behind.
    nonisolated private static func fetchAllEvents(firstPage: URL, token: String) async throws -> [GoogleEvent] {
        try await fetchAllPages(firstPage: firstPage, token: token).events
    }

    /// Every page of a list, and the sync token the last page carries (if the request can be
    /// continued incrementally).
    nonisolated private static func fetchAllPages(firstPage: URL, token: String) async throws
        -> (events: [GoogleEvent], syncToken: String?) {
        var events: [GoogleEvent] = []
        var syncToken: String?
        var pageToken: String?
        repeat {
            var url = firstPage
            if let pageToken,
               var components = URLComponents(url: firstPage, resolvingAgainstBaseURL: false) {
                components.queryItems = (components.queryItems ?? [])
                    + [URLQueryItem(name: "pageToken", value: pageToken)]
                url = components.url ?? firstPage
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.malformedResponse }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data))?.error.message
                throw GoogleCalendarError.api(status: http.statusCode, message: message)
            }
            guard let page = try? JSONDecoder().decode(GoogleEventsResponse.self, from: data) else {
                throw GoogleCalendarError.malformedResponse
            }
            events += page.items ?? []
            pageToken = page.nextPageToken
            syncToken = page.nextSyncToken ?? syncToken
        } while pageToken != nil
        return (events, syncToken)
    }

    // MARK: - Incremental sync

    struct SyncOutcome {
        let snapshot: GoogleEventSync.Snapshot
        /// Ids added, removed or changed by this read.
        let changedIDs: Set<String>
        let wasFullRead: Bool
        /// There was a previous copy to compare with — the first read of a calendar is a
        /// baseline, not news.
        let hadBaseline: Bool
    }

    /// Pick up disk copies for calendars that have no copy in memory yet — once per calendar.
    private func loadDiskSnapshots(for ids: [String]) async {
        let wanted = ids.filter { eventCache[$0] == nil && !diskCacheChecked.contains($0) }
        guard !wanted.isEmpty else { return }
        diskCacheChecked.formUnion(wanted)
        let loaded = await Task.detached(priority: .userInitiated) {
            wanted.compactMap { id in GoogleEventDiskCache.load(calendarID: id).map { (id, $0) } }
        }.value
        for (id, snapshot) in loaded where eventCache[id] == nil {
            eventCache[id] = snapshot
        }
    }

    /// Bring each calendar's copy up to date: incrementally when it can be continued, in full
    /// otherwise (or when Google says the token has expired). All calendars run concurrently.
    private func syncCalendars(_ calendars: [GoogleCalendar],
                               window: (start: Date, end: Date)) async -> [String: Result<SyncOutcome, Error>] {
        var results: [String: Result<SyncOutcome, Error>] = [:]
        var requests: [(id: String, token: String, previous: GoogleEventSync.Snapshot?)] = []
        for calendar in calendars {
            do {
                requests.append((calendar.id, try await accessToken(forCalendarID: calendar.id),
                                 eventCache[calendar.id]))
            } catch {
                results[calendar.id] = .failure(error)
            }
        }
        let now = Date()
        let running = requests.map { request in
            (request.id, Task.detached(priority: .userInitiated) { () -> Result<SyncOutcome, Error> in
                do {
                    return .success(try await Self.sync(calendarID: request.id, token: request.token,
                                                        previous: request.previous, window: window, now: now))
                } catch {
                    return .failure(error)
                }
            })
        }
        var trace: [String: String] = [:]
        for (id, task) in running {
            let result = await task.value
            switch result {
            case .success(let outcome):
                trace[id] = "\(outcome.wasFullRead ? "full" : "incremental"), \(outcome.changedIDs.count) changed, token \(outcome.snapshot.syncToken == nil ? "none" : "yes")"
            case .failure(let error):
                trace[id] = "FAILED \(error)"
                if Self.isCalendarGone(error) {
                    Self.log.notice("[google] calendar \(id, privacy: .public) no longer exists — reloading the list")
                    calendarsLoadedAt = nil
                }
                if case GoogleCalendarError.api(status: 401, _) = error, let owner = account(forCalendarID: id) {
                    tokenCache[owner.id] = nil
                }
            }
            results[id] = result
        }
        lastSyncTrace = trace
        return results
    }

    nonisolated private static func sync(calendarID: String, token: String,
                                         previous: GoogleEventSync.Snapshot?,
                                         window: (start: Date, end: Date), now: Date) async throws -> SyncOutcome {
        if let previous, GoogleEventSync.canContinue(previous, window: window, now: now),
           let syncToken = previous.syncToken {
            do {
                let page = try await fetchAllPages(firstPage: incrementalURL(calendarID: calendarID, syncToken: syncToken),
                                                   token: token)
                var snapshot = previous
                snapshot.events = GoogleEventSync.apply(page.events, to: previous.events)
                snapshot.fetchedAt = now
                snapshot.syncToken = page.syncToken
                return SyncOutcome(snapshot: snapshot, changedIDs: GoogleEventSync.ids(in: page.events),
                                   wasFullRead: false, hadBaseline: true)
            } catch GoogleCalendarError.api(status: 410, _) {
                // Token expired: fall through to a full read.
            }
        }
        let page = try await fetchAllPages(firstPage: syncListURL(calendarID: calendarID, from: window.start, to: window.end),
                                           token: token)
        let live = page.events.filter { $0.status != "cancelled" }
        let snapshot = GoogleEventSync.Snapshot(start: window.start, end: window.end, fetchedAt: now,
                                                fullReadAt: now, syncToken: page.syncToken, events: live)
        let changed = previous.map { GoogleEventSync.changedIDs(from: $0.events, to: live) } ?? []
        return SyncOutcome(snapshot: snapshot, changedIDs: changed, wasFullRead: true,
                           hadBaseline: previous != nil)
    }

    /// The full read a sync starts from. No `orderBy`: Google will not continue a list that was
    /// ordered, and nothing downstream depends on the order.
    nonisolated private static func syncListURL(calendarID: String, from start: Date, to end: Date) -> URL {
        var components = URLComponents(url: eventsURL(calendarID: calendarID), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: rfc3339(start)),
            URLQueryItem(name: "timeMax", value: rfc3339(end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: "2500"),
        ]
        return components.url!
    }

    /// Continue a list: only what changed since `syncToken`, deletions included. The other
    /// parameters must match the full read's, less the ones Google forbids with a token.
    nonisolated private static func incrementalURL(calendarID: String, syncToken: String) -> URL {
        var components = URLComponents(url: eventsURL(calendarID: calendarID), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "syncToken", value: syncToken),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: "2500"),
        ]
        return components.url!
    }

    @discardableResult
    func createEvent(_ input: CalendarEventInput, calendarInfoID: String) async throws -> String {
        await restoreIfNeeded()
        guard isConnected else { throw GoogleCalendarError.notConnected }
        guard let rawCalendarID = Self.rawCalendarID(from: calendarInfoID),
              calendars.first(where: { $0.id == rawCalendarID })?.isWritable == true else {
            throw CalendarEventCreationError.calendarUnavailable
        }

        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CalendarEventCreationError.emptyTitle }
        guard input.end > input.start else { throw CalendarEventCreationError.invalidDuration }

        var body: [String: Any] = [
            "summary": title,
            "start": Self.eventDateJSON(input.start, allDay: input.isAllDay),
            "end": Self.eventDateJSON(input.end, allDay: input.isAllDay),
            "transparency": input.availability == .free ? "transparent" : "opaque"
        ]
        if let location = input.location?.trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            body["location"] = location
        }
        var description = input.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = input.url {
            if !description.isEmpty { description += "\n\n" }
            description += "Video call: \(url.absoluteString)"
        }
        if !description.isEmpty { body["description"] = description }
        if let recurrenceRules = input.recurrenceRules, !recurrenceRules.isEmpty {
            body["recurrence"] = recurrenceRules
        } else if input.recurrence != .never {
            let rule = ["RRULE:FREQ=\(input.recurrence.googleFrequency)"]
            // Same UNTIL rewriting as "delete this and all following", so a repeat that ends is
            // expressed identically however it came to have an end.
            body["recurrence"] = input.recurrenceEnd.map {
                GoogleRecurrenceRule.truncated(
                    rule, before: RecurrenceEndDate.firstExcludedInstant(lastDayIncluded: $0),
                    allDay: input.isAllDay)
            } ?? rule
        }
        let alertMinutes = [input.alertMinutesBefore, input.secondaryAlertMinutesBefore]
            .compactMap { $0 }
            .uniqued()
        if !alertMinutes.isEmpty {
            body["reminders"] = [
                "useDefault": false,
                "overrides": alertMinutes.map { ["method": "popup", "minutes": $0] }
            ]
        }

        let guests = (input.attendees ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("@") }
        if !guests.isEmpty { body["attendees"] = guests.map { ["email": $0] } }

        let data = try JSONSerialization.data(withJSONObject: body)
        let escaped = Self.pathComponent(rawCalendarID)
        // With guests, Google sends them the invitation — what adding them was for.
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(escaped)/events"
                      + (guests.isEmpty ? "" : "?sendUpdates=all"))!
        let response: GoogleEvent = try await request(url: url, method: "POST", body: data)
        guard let eventID = response.id else { throw GoogleCalendarError.malformedResponse }
        noteOwnWrite(eventID)
        lastError = nil
        return Self.eventInfoID(calendarID: rawCalendarID, eventID: eventID)
    }

    func event(for meeting: MeetingInfo) async throws -> GoogleCalendarEvent {
        guard let infoID = meeting.eventID else { throw GoogleCalendarError.eventUnavailable }
        return try await event(infoID: infoID)
    }

    func event(infoID: String) async throws -> GoogleCalendarEvent {
        #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
        // The action fixture exercises real routing/detail presentation with cached MeetingInfo.
        // It must never restore an account or fetch its synthetic IDs from a provider.
        if ScaleStress.calendarActionsEnabled { throw GoogleCalendarError.eventUnavailable }
        #endif
        await restoreIfNeeded()
        guard isConnected else { throw GoogleCalendarError.notConnected }
        guard let route = Self.rawEventRoute(from: infoID) else {
            throw GoogleCalendarError.eventUnavailable
        }
        if calendars.isEmpty { try await loadCalendars() }
        let raw = try await rawEvent(calendarID: route.calendarID, eventID: route.eventID)
        guard var value = calendarEvent(raw, calendarID: route.calendarID) else {
            throw GoogleCalendarError.eventUnavailable
        }
        if let masterID = raw.recurringEventId {
            let master = try await rawEvent(calendarID: route.calendarID, eventID: masterID)
            value.recurrenceRules = master.recurrence ?? []
            value.seriesEtag = master.etag
        }
        return value
    }

    /// Save an edit. `scope` picks the occurrence, the whole series, or this occurrence and
    /// every later one (a new series, `updateFollowing`). A change to the repeat always goes to
    /// the series' master — or to a single event, which it turns into a series.
    ///
    /// `checkUnchanged` sends the version read when the editor opened as If-Match, so a save
    /// never overwrites a change made in Google meanwhile; Undo, which writes back what was there
    /// a moment ago, turns it off. Guests hear about it only when you organize the event.
    @discardableResult
    func updateEvent(
        _ event: GoogleCalendarEvent,
        destinationCalendarInfoID: String? = nil,
        scope: GoogleCalendarEventScope = .occurrence,
        recurrence: GoogleRecurrenceChange = .unchanged,
        fieldsChanged: Bool = true,
        guests: GoogleGuestChange = GoogleGuestChange(),
        checkUnchanged: Bool = true
    ) async throws -> GoogleEventEditOutcome {
        await restoreIfNeeded()
        guard isConnected else { throw GoogleCalendarError.notConnected }
        // Guests are the event's, not yours alone: only where the whole event can be edited.
        guard guests.isEmpty || event.canEdit else { throw GoogleCalendarError.notYours }
        if calendars.isEmpty { try await loadCalendars() }
        guard event.canEditPersonal,
              let route = Self.rawEventRoute(from: event.id),
              calendars.first(where: { $0.id == route.calendarID })?.isWritable == true,
              let destinationCalendarID = Self.rawCalendarID(
                from: event.canEdit ? (destinationCalendarInfoID ?? event.calendarInfoID) : event.calendarInfoID
              ),
              calendars.first(where: { $0.id == destinationCalendarID })?.isWritable == true else {
            throw CalendarEventCreationError.calendarUnavailable
        }
        if event.canEdit {
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw CalendarEventCreationError.emptyTitle }
            guard event.end > event.start else { throw CalendarEventCreationError.invalidDuration }
        }

        let source = try await rawEvent(calendarID: route.calendarID, eventID: route.eventID)
        // Banana's own busy and travel blocks are written by write-back alone.
        guard !GoogleEventEditPolicy.isBananaBlock(source.extendedProperties?.private) else {
            throw GoogleCalendarError.notEditable
        }
        if checkUnchanged, let read = event.etag, let now = source.etag, read != now {
            throw GoogleCalendarError.changedElsewhere
        }
        let notify = event.access == .full && GoogleEventEditPolicy.notifiesGuests(
            organizerIsSelf: event.organizerIsSelf, otherGuestCount: event.otherGuestCount, guests: guests)

        // A split series is rebuilt from its master without the guest list: never with a guest change.
        if scope == .thisAndFollowing, guests.isEmpty,
           event.canEdit, source.recurringEventId != nil, recurrence == .unchanged {
            return try await updateFollowing(event, source: source, calendarID: route.calendarID,
                                             destinationCalendarID: destinationCalendarID,
                                             checkUnchanged: checkUnchanged)
        }

        var outcome = GoogleEventEditOutcome()
        if recurrence == .endAfterOccurrence {
            outcome = try await endSeries(after: source, calendarID: route.calendarID, isAllDay: event.isAllDay,
                                          ifMatch: checkUnchanged ? event.seriesEtag : nil, notify: notify)
            guard fieldsChanged || !guests.isEmpty else {
                lastError = nil
                return outcome
            }
        }

        // The repeat lives only on the series' master (or a single event).
        let changesRepeat: Bool
        switch recurrence {
        case .setRule, .restore: changesRepeat = true
        case .unchanged, .endAfterOccurrence: changesRepeat = false
        }
        let effectiveScope: GoogleCalendarEventScope = changesRepeat || scope == .series ? .series : .occurrence
        let target = try await mutationTarget(
            source: source,
            calendarID: route.calendarID,
            scope: effectiveScope
        )
        var start = event.start
        var end = event.end
        if target.id != source.id,
           let sourceRange = Self.eventRange(source),
           let targetRange = Self.eventRange(target.event) {
            let shift = event.start.timeIntervalSince(sourceRange.start)
            start = targetRange.start.addingTimeInterval(shift)
            end = start.addingTimeInterval(event.end.timeIntervalSince(event.start))
        }

        var lines: [String]?
        switch recurrence {
        case .setRule(let rule): lines = EventRepeat.replacingRule(in: target.event.recurrence ?? [], with: rule)
        case .restore(let original): lines = original
        case .unchanged, .endAfterOccurrence: lines = nil
        }
        if lines != nil {
            guard GoogleEventPatch.canCarryRecurrence(eventID: target.id,
                                                      recurringEventID: target.event.recurringEventId) else {
                throw GoogleCalendarError.eventUnavailable
            }
            outcome.seriesInfoID = Self.eventInfoID(calendarID: route.calendarID, eventID: target.id)
            outcome.seriesLinesBefore = target.event.recurrence ?? []
        }

        var fields = event.patchFields
        fields.start = start
        fields.end = end
        var patch = GoogleEventPatch.body(fields, access: event.access, recurrence: lines,
                                          isRecurring: event.isRecurring || target.event.recurrence?.isEmpty == false)
        // Undo of turning a single event into a series: the one time an empty list is right —
        // the series is the one this save made, a moment ago.
        if case .restore(let original) = recurrence, original.isEmpty { patch["recurrence"] = [String]() }
        if !guests.isEmpty {
            // The list as Google has it on the very event being written, read now: it is sent
            // back whole (`GoogleGuestPatch`), so nobody who stays loses their reply.
            let raw = try await send(url: Self.eventURL(calendarID: route.calendarID, eventID: target.id),
                                     method: "GET", body: nil, account: nil)
            let current = ((try JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["attendees"] as? [[String: Any]] ?? []
            if let updated = GoogleGuestPatch.attendees(current, change: guests) { patch["attendees"] = updated }
        }
        let body = try JSONSerialization.data(withJSONObject: patch)
        let isChangingCalendar = event.canEdit && destinationCalendarID != route.calendarID
        let ifMatch = checkUnchanged ? (target.id == source.id ? event.etag : event.seriesEtag) : nil
        noteOwnWrite(target.id, source.id)
        let _: GoogleEvent = try await request(
            url: Self.eventURL(calendarID: route.calendarID, eventID: target.id,
                               // A calendar move tells the guests once, after the fields are patched.
                               notify: notify && !isChangingCalendar),
            method: "PATCH", body: body, ifMatch: ifMatch)
        if isChangingCalendar {
            let _: GoogleEvent = try await request(
                url: Self.moveEventURL(
                    sourceCalendarID: route.calendarID,
                    eventID: target.id,
                    destinationCalendarID: destinationCalendarID,
                    notify: notify
                ),
                method: "POST"
            )
        }
        lastError = nil
        return outcome
    }

    /// Repeat set to Never on a series: it stops after this occurrence, which is kept. Never an
    /// empty recurrence, which would delete every occurrence but the first, past ones included.
    private func endSeries(after source: GoogleEvent, calendarID: String, isAllDay: Bool,
                           ifMatch: String?, notify: Bool) async throws -> GoogleEventEditOutcome {
        guard let sourceID = source.id, let occurrenceStart = Self.eventRange(source)?.start else {
            throw GoogleCalendarError.eventUnavailable
        }
        let masterID = source.recurringEventId ?? sourceID
        let master = masterID == sourceID ? source : try await rawEvent(calendarID: calendarID, eventID: masterID)
        let existing = master.recurrence ?? []
        guard !existing.isEmpty,
              GoogleEventPatch.canCarryRecurrence(eventID: masterID, recurringEventID: master.recurringEventId) else {
            throw GoogleCalendarError.eventUnavailable
        }
        // `truncated` keeps what starts before the cutoff: a second after this one keeps it.
        let lines = GoogleRecurrenceRule.truncated(existing, before: occurrenceStart.addingTimeInterval(1),
                                                   allDay: isAllDay)
        noteOwnWrite(masterID, sourceID)
        let _: GoogleEvent = try await request(
            url: Self.eventURL(calendarID: calendarID, eventID: masterID, notify: notify),
            method: "PATCH", body: try JSONSerialization.data(withJSONObject: ["recurrence": lines]),
            ifMatch: ifMatch)
        return GoogleEventEditOutcome(seriesInfoID: Self.eventInfoID(calendarID: calendarID, eventID: masterID),
                                      seriesLinesBefore: existing)
    }

    /// "This and following": a new series from the edited occurrence on, then the old one cut
    /// short before it — Google's own way, as its API has no other. Offered only when nobody else
    /// is on the event (a new series would re-invite them) and the rule has no COUNT. If cutting
    /// the old series fails, the new one is deleted again, so nothing is left doubled.
    private func updateFollowing(_ event: GoogleCalendarEvent, source: GoogleEvent, calendarID: String,
                                 destinationCalendarID: String,
                                 checkUnchanged: Bool) async throws -> GoogleEventEditOutcome {
        guard let sourceID = source.id, let masterID = source.recurringEventId,
              let occurrenceStart = Self.eventRange(source)?.start, event.otherGuestCount == 0 else {
            throw GoogleCalendarError.eventUnavailable
        }
        let masterData = try await send(url: Self.eventURL(calendarID: calendarID, eventID: masterID),
                                        method: "GET", body: nil, account: nil)
        guard let masterJSON = try JSONSerialization.jsonObject(with: masterData) as? [String: Any],
              let master = try? JSONDecoder().decode(GoogleEvent.self, from: masterData) else {
            throw GoogleCalendarError.malformedResponse
        }
        let existing = master.recurrence ?? []
        guard !existing.isEmpty, !existing.contains(where: { $0.uppercased().contains("COUNT=") }) else {
            throw GoogleCalendarError.eventUnavailable
        }
        if checkUnchanged, let read = event.seriesEtag, let now = master.etag, read != now {
            throw GoogleCalendarError.changedElsewhere
        }

        var fields = event.patchFields
        fields.reminders = event.reminders
        let newBody = GoogleEventPatch.followingSeriesBody(master: masterJSON, fields: fields, rule: existing)
        noteOwnWrite(masterID, sourceID)
        let created: GoogleEvent = try await request(
            url: Self.eventsURL(calendarID: destinationCalendarID), method: "POST",
            body: try JSONSerialization.data(withJSONObject: newBody))
        guard let newID = created.id else { throw GoogleCalendarError.malformedResponse }
        noteOwnWrite(newID)

        // `truncated` keeps what starts before the cutoff: this occurrence and later ones go.
        let cut = GoogleRecurrenceRule.truncated(existing, before: occurrenceStart, allDay: event.isAllDay)
        do {
            let _: GoogleEvent = try await request(
                url: Self.eventURL(calendarID: calendarID, eventID: masterID, notify: false),
                method: "PATCH", body: try JSONSerialization.data(withJSONObject: ["recurrence": cut]),
                ifMatch: checkUnchanged ? master.etag : nil)
        } catch {
            try? await requestVoid(url: Self.eventURL(calendarID: destinationCalendarID, eventID: newID, notify: false),
                                   method: "DELETE")
            throw error
        }
        lastError = nil
        return GoogleEventEditOutcome(
            newSeriesInfoID: Self.eventInfoID(calendarID: destinationCalendarID, eventID: newID),
            seriesInfoID: Self.eventInfoID(calendarID: calendarID, eventID: masterID),
            seriesLinesBefore: existing)
    }

    /// Undo of "This and following": the old series gets its lines back, then the new one goes.
    func undoFollowing(_ outcome: GoogleEventEditOutcome) async throws {
        guard let newID = outcome.newSeriesInfoID, let newRoute = Self.rawEventRoute(from: newID) else {
            throw GoogleCalendarError.eventUnavailable
        }
        try await restoreRecurrence(outcome)
        noteOwnWrite(newRoute.eventID)
        try await requestVoid(url: Self.eventURL(calendarID: newRoute.calendarID, eventID: newRoute.eventID,
                                                 notify: false),
                              method: "DELETE")
        lastError = nil
    }

    /// Undo of a change to a series' repeat, or of ending it: its lines back as they were.
    func restoreRecurrence(_ outcome: GoogleEventEditOutcome) async throws {
        guard let seriesID = outcome.seriesInfoID, let route = Self.rawEventRoute(from: seriesID),
              let lines = outcome.seriesLinesBefore, !lines.isEmpty else {
            throw GoogleCalendarError.eventUnavailable
        }
        noteOwnWrite(route.eventID)
        let _: GoogleEvent = try await request(
            url: Self.eventURL(calendarID: route.calendarID, eventID: route.eventID, notify: false),
            method: "PATCH", body: try JSONSerialization.data(withJSONObject: ["recurrence": lines]))
        lastError = nil
    }

    /// Resolve a drag to one immutable conditional PATCH. The journal saves this result
    /// before dispatch, including the master identity when moving an entire series.
    func prepareMove(_ intent: CalendarMoveIntent) async throws -> CalendarMoveIntent.PreparedMove {
        guard intent.scope != .following else { throw GoogleCalendarError.notEditable }
        let event = try await event(infoID: intent.eventID)
        guard event.canEdit else { throw GoogleCalendarError.notYours }
        guard let route = Self.rawEventRoute(from: intent.eventID),
              let owner = account(forCalendarID: route.calendarID),
              calendars.first(where: { $0.id == route.calendarID })?.isWritable == true else {
            throw CalendarEventCreationError.calendarUnavailable
        }
        let source = try await rawEvent(calendarID: route.calendarID, eventID: route.eventID)
        guard source.etag == event.etag, event.start == intent.originalStart,
              !GoogleEventEditPolicy.isBananaBlock(source.extendedProperties?.private) else {
            throw GoogleCalendarError.changedElsewhere
        }
        let target = try await mutationTarget(source: source, calendarID: route.calendarID,
                                             scope: intent.scope == .series ? .series : .occurrence)
        guard let range = Self.eventRange(target.event), let etag = target.event.etag,
              !etag.isEmpty else { throw GoogleCalendarError.eventUnavailable }
        let start = target.id == route.eventID ? intent.destination
            : range.start.addingTimeInterval(intent.destination.timeIntervalSince(intent.originalStart))
        let end = start.addingTimeInterval(event.end.timeIntervalSince(event.start))
        // Store exactly the precision sent over the wire, so read-back can reconcile it.
        func canonical(_ date: Date) -> Date {
            if range.isAllDay { return GoogleCalendarDates.parseDate(GoogleCalendarDates.dateString(date)) ?? date }
            return GoogleCalendarDates.parseRFC3339(GoogleCalendarDates.rfc3339(date)) ?? date
        }
        return CalendarMoveIntent.PreparedMove(
            accountEmail: owner.email, calendarID: route.calendarID, eventID: target.id,
            expectedETag: etag, destinationStart: canonical(start), destinationEnd: canonical(end),
            isAllDay: range.isAllDay, timeZoneID: event.timeZoneID ?? TimeZone.current.identifier,
            notifyGuests: event.notifiesGuests)
    }

    func applyPreparedMove(_ move: CalendarMoveIntent.PreparedMove) async throws {
        #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
        if ScaleStress.calendarActionsEnabled { throw GoogleCalendarError.eventUnavailable }
        #endif
        await restoreIfNeeded()
        if calendars.isEmpty { try await loadCalendars() }
        guard let owner = accounts.first(where: { $0.email.lowercased() == move.accountEmail.lowercased() }),
              calendars.contains(where: { $0.id == move.calendarID && $0.isWritable
                  && $0.accountEmail.lowercased() == move.accountEmail.lowercased() }) else {
            throw CalendarEventCreationError.calendarUnavailable
        }
        let url = Self.eventURL(calendarID: move.calendarID, eventID: move.eventID,
                                notify: move.notifyGuests)
        let current: GoogleEvent = try await request(
            url: Self.eventURL(calendarID: move.calendarID, eventID: move.eventID), account: owner)
        guard let range = Self.eventRange(current) else { throw GoogleCalendarError.eventUnavailable }
        switch move.reconcile(start: range.start, end: range.end, etag: current.etag) {
        case .alreadyApplied:
            invalidateEventCache()
            lastError = nil
            return
        case .conflict: throw GoogleCalendarError.changedElsewhere
        case .sendIfUnchanged: break
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "start": GoogleEventPatch.dateJSON(move.destinationStart, allDay: move.isAllDay,
                                              timeZoneID: move.timeZoneID),
            "end": GoogleEventPatch.dateJSON(move.destinationEnd, allDay: move.isAllDay,
                                            timeZoneID: move.timeZoneID)
        ])
        noteOwnWrite(move.eventID)
        let saved: GoogleEvent = try await request(url: url, method: "PATCH", body: body,
                                                   account: owner, ifMatch: move.expectedETag)
        guard let confirmed = Self.eventRange(saved),
              move.reconcile(start: confirmed.start, end: confirmed.end, etag: saved.etag) == .alreadyApplied else {
            throw GoogleCalendarError.eventUnavailable
        }
        invalidateEventCache()
        lastError = nil
    }

    func moveEvent(
        _ meeting: MeetingInfo,
        to newStart: Date,
        scope: GoogleCalendarEventScope = .occurrence
    ) async throws {
        var event = try await event(for: meeting)
        // Someone else's invitation is theirs to move; a save would only touch your alerts.
        guard event.canEdit else { throw GoogleCalendarError.notYours }
        let duration = event.end.timeIntervalSince(event.start)
        event.start = newStart
        event.end = newStart.addingTimeInterval(duration)
        try await updateEvent(event, scope: scope)
    }

    func deleteEvent(
        eventInfoID: String,
        scope: GoogleCalendarEventScope = .occurrence
    ) async throws {
        await restoreIfNeeded()
        guard isConnected else { throw GoogleCalendarError.notConnected }
        if calendars.isEmpty { try await loadCalendars() }
        guard let route = Self.rawEventRoute(from: eventInfoID),
              calendars.first(where: { $0.id == route.calendarID })?.isWritable == true else {
            throw CalendarEventCreationError.calendarUnavailable
        }
        let source = try await rawEvent(calendarID: route.calendarID, eventID: route.eventID)
        noteOwnWrite(route.eventID, source.recurringEventId)

        if scope == .thisAndFollowing {
            // Not a delete at all: truncate the series so it stops before this occurrence. The
            // earlier occurrences are the whole point of choosing this over "entire series".
            guard let masterID = source.recurringEventId else {
                // Not an instance of a series — nothing after it to keep, so a plain delete is
                // exactly right.
                try await requestVoid(url: Self.eventURL(
                    calendarID: route.calendarID, eventID: route.eventID, sendUpdates: true
                ), method: "DELETE")
                lastError = nil
                return
            }
            guard let cutoff = Self.eventRange(source)?.start else {
                throw GoogleCalendarError.eventUnavailable
            }
            let master = try await rawEvent(calendarID: route.calendarID, eventID: masterID)
            let existing = master.recurrence ?? []
            guard !existing.isEmpty else { throw GoogleCalendarError.eventUnavailable }
            let body = try JSONSerialization.data(withJSONObject: [
                "recurrence": GoogleRecurrenceRule.truncated(existing, before: cutoff,
                                                             allDay: Self.eventRange(source)?.isAllDay == true)
            ])
            let _: GoogleEvent = try await request(
                url: Self.eventURL(calendarID: route.calendarID, eventID: masterID, sendUpdates: true),
                method: "PATCH",
                body: body)
            lastError = nil
            return
        }

        let target = try await mutationTarget(
            source: source,
            calendarID: route.calendarID,
            scope: scope
        )
        noteOwnWrite(target.id)
        try await requestVoid(url: Self.eventURL(
            calendarID: route.calendarID,
            eventID: target.id,
            sendUpdates: true
        ), method: "DELETE")
        lastError = nil
    }

    /// Show yourself Busy or Free for an event — your copy only: "Show as" is each guest's own,
    /// so no one else's copy changes and no one is told. How a day is blocked: Google makes
    /// all-day events Free by default, an accepted invitation's included (`AllDayEvents`).
    func setAvailability(of meeting: MeetingInfo, busy: Bool) async throws {
        await restoreIfNeeded()
        guard let infoID = meeting.eventID, let route = Self.rawEventRoute(from: infoID) else {
            throw GoogleCalendarError.eventUnavailable
        }
        let body = try JSONSerialization.data(withJSONObject: ["transparency": busy ? "opaque" : "transparent"])
        noteOwnWrite(route.eventID)
        _ = try await send(url: Self.eventURL(calendarID: route.calendarID, eventID: route.eventID),
                           method: "PATCH", body: body, account: nil)
        invalidateEventCache()
        lastError = nil
    }

    /// Reply Yes / No / Maybe to an invitation. The event is read as raw JSON and written back
    /// with only this person's `responseStatus` changed (see `GoogleRSVPPatch`), and the organiser
    /// is notified as Google Calendar would.
    func respond(to meeting: MeetingInfo, with response: GoogleCalendarRSVP) async throws {
        guard let infoID = meeting.eventID, let route = Self.rawEventRoute(from: infoID) else {
            throw GoogleCalendarError.eventUnavailable
        }
        try await respondToInvite(calendarID: route.calendarID, eventID: route.eventID, with: response)
    }

    /// The same reply, from an alert's Accept / Decline (`EventAlerts`), which knows the raw ids.
    func respondToInvite(calendarID: String, eventID: String, with response: GoogleCalendarRSVP) async throws {
        await restoreIfNeeded()
        let route = (calendarID: calendarID, eventID: eventID)
        let url = Self.eventURL(calendarID: route.calendarID, eventID: route.eventID)
        let data = try await send(url: url, method: "GET", body: nil, account: nil)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attendees = json["attendees"] as? [[String: Any]],
              let updated = GoogleRSVPPatch.attendees(attendees, replying: response) else {
            throw GoogleCalendarError.api(status: 400, message: "You aren’t a guest on this event, so there is nothing to reply to.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["attendees": updated])
        noteOwnWrite(route.eventID)
        _ = try await send(url: Self.eventURL(calendarID: route.calendarID, eventID: route.eventID,
                                              sendUpdates: true),
                           method: "PATCH", body: body, account: nil)
        lastError = nil
        // The next read asks Google again: reused for up to 45 s, it still had the old reply, so a
        // declined event stayed on the day — and as Banana's own write, the change poll never
        // counted it as news to re-plan for.
        invalidateEventCache()
    }

    // MARK: - Busy blocks

    /// Create one busy block, returning its Google event id for the ledger.
    func createBusyBlock(calendarID: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                         appItemID: String, variant: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: GoogleBusyBlocks.body(
            title: title, start: start, end: end, timeZoneID: TimeZone.current.identifier,
            appItemID: appItemID, variant: variant, isAllDay: isAllDay))
        let created: GoogleEvent = try await request(
            url: Self.eventsURL(calendarID: calendarID), method: "POST", body: body)
        guard let id = created.id else { throw GoogleCalendarError.eventUnavailable }
        noteOwnWrite(id)
        return id
    }

    /// Rewrite an existing block in place. PATCH rather than delete-and-recreate: a new event id
    /// every time a meeting moves five minutes would churn the ledger and re-notify anyone the
    /// calendar is shared with.
    func updateBusyBlock(calendarID: String, eventID: String, title: String,
                         start: Date, end: Date, isAllDay: Bool = false,
                         appItemID: String, variant: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: GoogleBusyBlocks.body(
            title: title, start: start, end: end, timeZoneID: TimeZone.current.identifier,
            appItemID: appItemID, variant: variant, isAllDay: isAllDay))
        noteOwnWrite(eventID)
        let _: GoogleEvent = try await request(
            url: Self.eventURL(calendarID: calendarID, eventID: eventID), method: "PATCH", body: body)
    }

    func deleteBusyBlock(calendarID: String, eventID: String) async throws {
        noteOwnWrite(eventID)
        do {
            try await requestVoid(
                url: Self.eventURL(calendarID: calendarID, eventID: eventID), method: "DELETE")
        } catch GoogleCalendarError.api(status: 404, _), GoogleCalendarError.api(status: 410, _) {
            // Already gone — every device reconciles the same blocks, so another one got here
            // first. That's the outcome we wanted, not an error.
        }
    }

    /// Events on one calendar carrying an iCalendar UID — how a block written through Apple
    /// Calendar is found again through the API. Read-only.
    func events(calendarID: String, iCalUID: String) async throws -> [GoogleEvent] {
        var components = URLComponents(url: Self.eventsURL(calendarID: calendarID),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "iCalUID", value: iCalUID)]
        let page: GoogleEventsResponse = try await request(url: components.url!)
        return (page.items ?? []).filter { $0.status != "cancelled" }
    }

    /// Mark an existing event as a block this build owns, touching nothing else about it.
    ///
    /// PATCH merges `extendedProperties.private` key by key, so this adds the two ownership keys
    /// and leaves the title, times, attendees and any other app's properties exactly as they were.
    func tagAsOwnedBusyBlock(calendarID: String, eventID: String,
                             appItemID: String, variant: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "extendedProperties": ["private": [
                GoogleBusyBlocks.itemIDKey: appItemID,
                GoogleBusyBlocks.variantKey: variant,
            ]],
        ])
        noteOwnWrite(eventID)
        let _: GoogleEvent = try await request(
            url: Self.eventURL(calendarID: calendarID, eventID: eventID), method: "PATCH", body: body)
    }

    /// Every block this build wrote to one calendar in a window: app item id → event ids.
    ///
    /// Server-side filtering on the private property, so this is one request rather than listing
    /// the calendar and sifting. This is what lets a device clean up — or adopt — blocks it has no
    /// local ledger entry for, which a URL marker stripped by CalDAV could never support.
    ///
    /// Several ids for one item is a real state, not a corner case: the phone and the Mac each
    /// wrote their own copy of the same block through Apple Calendar, and adoption tags both. They
    /// are provably ours and identical, so all but one are removed.
    /// One occurrence as `--google-repeat` reads it back.
    struct ProbeOccurrence {
        let infoID: String
        let title: String
        let start: Date
    }

    /// For `--google-repeat` only: the occurrences in a window whose title starts with `query`,
    /// read straight from Google — no cache, no calendar settings. Filtered here rather than with
    /// Google's `q`, whose index can lag a write by seconds.
    func probeOccurrences(calendarID: String, query: String, from start: Date, to end: Date) async throws -> [ProbeOccurrence] {
        var components = URLComponents(url: Self.eventsURL(calendarID: calendarID), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: Self.rfc3339(start)),
            URLQueryItem(name: "timeMax", value: Self.rfc3339(end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
        ]
        let page: GoogleEventsResponse = try await request(url: components.url!)
        return (page.items ?? []).compactMap { event in
            guard event.status != "cancelled", let id = event.id, let range = Self.eventRange(event),
                  (event.summary ?? "").hasPrefix(query) else { return nil }
            return ProbeOccurrence(infoID: Self.eventInfoID(calendarID: calendarID, eventID: id),
                                   title: event.summary ?? "", start: range.start)
        }
    }

    func ownedBusyBlocks(calendarID: String, variant: String,
                         from start: Date, to end: Date) async throws -> [String: [String]] {
        try await ownedBusyBlockDetails(calendarID: calendarID, variant: variant, from: start, to: end)
            .mapValues { $0.map(\.eventID) }
    }

    /// One block Banana owns, with its span — so a caller can leave alone blocks that are over.
    struct OwnedBlock: Equatable {
        let eventID: String
        let start: Date
        let end: Date
    }

    func ownedBusyBlockDetails(calendarID: String, variant: String,
                               from start: Date, to end: Date) async throws -> [String: [OwnedBlock]] {
        var found: [String: [OwnedBlock]] = [:]
        var pageToken: String?
        repeat {
            var components = URLComponents(url: Self.eventsURL(calendarID: calendarID),
                                           resolvingAgainstBaseURL: false)!
            var query = [
                URLQueryItem(name: "timeMin", value: Self.rfc3339(start)),
                URLQueryItem(name: "timeMax", value: Self.rfc3339(end)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "maxResults", value: "2500"),
                URLQueryItem(name: "privateExtendedProperty",
                             value: GoogleBusyBlocks.ownershipFilter(variant: variant)),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = query
            let page: GoogleEventsResponse = try await request(url: components.url!)
            for event in page.items ?? [] where event.status != "cancelled" {
                guard let id = event.id,
                      let itemID = GoogleBusyBlocks.appItemID(
                        fromPrivateProperties: event.extendedProperties?.private, variant: variant),
                      let span = GoogleCalendarDates.range(of: event)
                else { continue }
                found[itemID, default: []].append(OwnedBlock(eventID: id, start: span.start, end: span.end))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return found
    }

    nonisolated private static func eventsURL(calendarID: String) -> URL {
        URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(pathComponent(calendarID))/events")!
    }

    // MARK: - Sign in

    /// Reconnect every account this person has, on any of their devices.
    ///
    /// The credential store is the source of truth now, so a launch needs no interaction — and
    /// because the store is in the synchronized keychain, an account connected on the Mac is
    /// already here. `GIDSignIn`'s own session is consulted only to adopt a sign-in made by a
    /// previous build, which is what stops this upgrade signing anyone out.
    private func performRestore() async {
        defer { restorationFinished = true }
        guard isConfigured else { return }
        accounts = GoogleAccountStore.load()

        if accounts.isEmpty, GIDSignIn.sharedInstance.hasPreviousSignIn() {
            do {
                let user: GIDGoogleUser = try await withCheckedThrowingContinuation { continuation in
                    GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                        if let error { continuation.resume(throwing: Self.signInFailure(error)) }
                        else if let user { continuation.resume(returning: user) }
                        else { continuation.resume(throwing: GoogleCalendarError.notConnected) }
                    }
                }
                try accept(user)   // migrates the old single-account session into the store
            } catch {
                GIDSignIn.sharedInstance.signOut()
                return
            }
        }
        guard !accounts.isEmpty else { return }
        do {
            try await loadCalendars()
        } catch {
            // Keep a valid scoped sign-in even when the API is temporarily unavailable or not
            // enabled in Google Cloud; Settings can now explain the actionable API error.
            lastError = Self.friendlyMessage(for: error)
        }
    }

    /// Take what the consent flow produced and keep the part that lasts.
    ///
    /// The SDK's session holds one user and is not consulted again after this; the refresh token
    /// is what actually identifies the account from here on, and storing it per-email is what
    /// makes a second account additive instead of replacing the first.
    private func accept(_ user: GIDGoogleUser) throws {
        let missing = Self.requiredScopes.filter { user.grantedScopes?.contains($0) != true }
        guard missing.isEmpty else { throw GoogleCalendarError.permissionMissing }
        guard let email = user.profile?.email, !email.isEmpty else {
            throw GoogleCalendarError.notConnected
        }
        accounts = GoogleAccountStore.upsert(GoogleAccountCredential(
            email: email,
            refreshToken: user.refreshToken.tokenString,
            grantedScopes: user.grantedScopes ?? []))
        publishAccountHint(email)
        restorationFinished = true
    }

    /// Run Google's consent flow.
    ///
    /// `hint` becomes OAuth's `login_hint`, which PRESELECTS an account and suppresses the
    /// chooser. That was right when only one account could be connected — reconnecting should go
    /// straight back to the same one, and the cross-device hint saves typing it. It is wrong when
    /// adding an account: hinting the one already connected is why Google would only offer that
    /// account, or others on its domain. Adding passes nil so the full chooser appears.
    /// Closing Google's page is someone changing their mind, not a failure. The sign-in package
    /// reports it as an error of its own, so it was kept and shown: "The user canceled the
    /// sign-in flow." Every caller already treats a `CancellationError` as nothing to report.
    nonisolated private static func signInFailure(_ error: Error) -> Error {
        if let error = error as? GIDSignInError, error.code == .canceled { return CancellationError() }
        return error
    }

    private func interactiveSignIn(hint: String?, scopes requestedScopes: [String]? = nil) async throws -> GIDSignInResult {
        let scopes = requestedScopes ?? Self.requiredScopes
        #if os(iOS)
        guard let presenter = Self.presentingViewController() else {
            throw GoogleCalendarError.noPresentationContext
        }
        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: hint,
                additionalScopes: scopes
            ) { result, error in
                if let error { continuation.resume(throwing: Self.signInFailure(error)) }
                else if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: GoogleCalendarError.notConnected) }
            }
        }
        #elseif os(macOS)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else {
            throw GoogleCalendarError.noPresentationContext
        }
        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: window,
                hint: hint,
                additionalScopes: scopes
            ) { result, error in
                if let error { continuation.resume(throwing: Self.signInFailure(error)) }
                else if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: GoogleCalendarError.notConnected) }
            }
        }
        #endif
    }

    // MARK: - Cross-device account hint

    /// Sync only the email address needed to select the same Google account on another device.
    /// Access and refresh tokens intentionally stay in Google Sign-In's device-local keychain.
    private func observeAccountHint() {
        applyAccountHint()
        accountHintObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyAccountHint() }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cloud.synchronize()
            self.applyAccountHint()
        }
    }

    private func applyAccountHint() {
        suggestedAccountEmail = Self.normalizedEmail(cloud.string(forKey: Self.accountHintKey))
    }

    private func publishAccountHint(_ email: String) {
        guard let email = Self.normalizedEmail(email) else { return }
        suggestedAccountEmail = email
        guard cloud.string(forKey: Self.accountHintKey) != email else { return }
        cloud.set(email, forKey: Self.accountHintKey)
        cloud.synchronize()
    }

    private func clearAccountHint() {
        suggestedAccountEmail = nil
        cloud.removeObject(forKey: Self.accountHintKey)
        cloud.synchronize()
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    #if os(iOS)
    private static func presentingViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        var current = root
        while let presented = current?.presentedViewController { current = presented }
        if let navigation = current as? UINavigationController { return navigation.visibleViewController }
        if let tabs = current as? UITabBarController { return tabs.selectedViewController }
        return current
    }
    #endif

    // MARK: - Calendar API

    /// Every connected account's calendars, merged.
    ///
    /// One account failing does not lose the others: a revoked grant or an API that is temporarily
    /// unavailable costs that account's calendars for this pass, and the rest still load. With a
    /// single account this behaves exactly as it did before.
    private func loadCalendars() async throws {
        guard !accounts.isEmpty else {
            calendars = []
            eventCache = [:]
            Task.detached(priority: .utility) { GoogleEventDiskCache.prune(keeping: []) }
            return
        }
        var merged: [GoogleCalendar] = []
        var failures: [String] = []
        var unreadable: Set<String> = []
        for account in accounts {
            do {
                let loaded = try await calendars(for: account)
                Self.log.notice("[google] \(account.email, privacy: .public): loaded \(loaded.count, privacy: .public) calendar(s)")
                let previously = calendars.filter { $0.accountEmail.lowercased() == account.id }
                if loaded.isEmpty, !previously.isEmpty {
                    // Every account has at least its primary calendar. An empty list from one that
                    // had calendars a moment ago is Google failing to answer, not the calendars
                    // vanishing — and believing it would read as "no meetings" everywhere.
                    throw GoogleCalendarError.malformedResponse
                }
                merged += loaded
            } catch {
                // Silence here is what made a connected-but-empty account impossible to diagnose:
                // the row showed a tick and no calendars, and nothing said why.
                Self.log.error("[google] \(account.email, privacy: .public): calendar load FAILED — \(String(describing: error), privacy: .public)")
                failures.append("\(account.email): \(Self.friendlyMessage(for: error))")
                unreadable.insert(account.id)
                // Keep what this account had. Dropping its calendars would make every one of them
                // read as empty — the first step of every mass deletion so far.
                merged += calendars.filter { $0.accountEmail.lowercased() == account.id }
            }
        }
        accountsWithUnreadableCalendars = unreadable
        calendarsLoadedAt = Date()
        // One entry per calendar, however many accounts can see it.
        //
        // A calendar shared between two connected accounts appears in BOTH calendar lists with the
        // same id — "Holidays in United States" and the transferred dewey calendars all do.
        // Downstream code reasonably assumes a calendar id identifies one calendar, and two
        // entries sharing one id crashed a settings write outright.
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.id).inserted }
        calendars = merged.sorted {
            if $0.accountEmail != $1.accountEmail {
                return $0.accountEmail.localizedCaseInsensitiveCompare($1.accountEmail) == .orderedAscending
            }
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
        if !failures.isEmpty, merged.isEmpty {
            lastError = failures.joined(separator: "; ")
        }
        if failures.isEmpty {
            // Only on a clean load: a calendar missing because its account failed to answer is
            // still there, and its copy is what a failed read falls back on.
            let listed = Set(merged.map(\.id))
            for id in eventCache.keys where !listed.contains(id) { eventCache[id] = nil }
            Task.detached(priority: .utility) { GoogleEventDiskCache.prune(keeping: listed) }
        }
    }

    private func calendars(for account: GoogleAccountCredential) async throws -> [GoogleCalendar] {
        var pageToken: String?
        var loaded: [GoogleCalendar] = []
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
            if let pageToken {
                components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
            }
            let page: GoogleCalendarListResponse = try await request(url: components.url!, account: account)
            loaded += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return loaded.filter { !$0.isDeleted }.map {
            var tagged = $0
            tagged.accountEmail = account.email
            return tagged
        }
    }

    /// Disconnect one account, leaving the others connected.
    func disconnect(email: String) async {
        await BananaAccount.shared.googleDisconnected(email: email)
        accounts = GoogleAccountStore.remove(email: email)
        tokenCache[email.lowercased()] = nil
        calendars.removeAll { $0.accountEmail.lowercased() == email.lowercased() }
        if accounts.isEmpty { clearAccountHint() }
        try? await loadCalendars()
    }

    private func rawEvent(calendarID: String, eventID: String) async throws -> GoogleEvent {
        try await request(url: Self.eventURL(calendarID: calendarID, eventID: eventID))
    }

    private func mutationTarget(
        source: GoogleEvent,
        calendarID: String,
        scope: GoogleCalendarEventScope
    ) async throws -> (event: GoogleEvent, id: String) {
        guard let sourceID = source.id else { throw GoogleCalendarError.eventUnavailable }
        guard scope == .series, let masterID = source.recurringEventId else {
            return (source, sourceID)
        }
        return (try await rawEvent(calendarID: calendarID, eventID: masterID), masterID)
    }

    private func calendarEvent(_ raw: GoogleEvent, calendarID: String) -> GoogleCalendarEvent? {
        guard let rawEventID = raw.id,
              let range = Self.eventRange(raw),
              let calendar = calendars.first(where: { $0.id == calendarID }) else { return nil }
        let attendees = (raw.attendees ?? []).compactMap { attendee -> GoogleCalendarAttendee? in
            guard let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty else { return nil }
            return GoogleCalendarAttendee(
                email: email,
                displayName: attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                responseStatus: attendee.responseStatus,
                isCurrentUser: attendee.selfAttendee == true,
                isOrganizer: attendee.organizer == true
            )
        }
        let reminders: GoogleCalendarReminderSelection
        if raw.reminders?.useDefault == true {
            reminders = .calendarDefault
        } else {
            let minutes = (raw.reminders?.overrides ?? [])
                .filter { $0.method == nil || $0.method == "popup" }
                .compactMap(\.minutes)
                .uniqued()
                .sorted()
            reminders = minutes.isEmpty ? .none : .custom(minutes)
        }
        return GoogleCalendarEvent(
            id: Self.eventInfoID(calendarID: calendarID, eventID: rawEventID),
            calendarInfoID: Self.calendarInfoID(calendarID),
            calendarTitle: calendar.displayTitle,
            calendarColorHex: calendar.backgroundColor,
            access: GoogleEventEditPolicy.access(
                calendarWritable: calendar.isWritable, locked: raw.locked == true,
                organizerIsSelf: GoogleEventEditPolicy.organizerIsSelf(raw.organizer),
                guestsCanModify: raw.guestsCanModify == true,
                eventType: raw.eventType,
                isBananaBlock: GoogleEventEditPolicy.isBananaBlock(raw.extendedProperties?.private)),
            organizerIsSelf: GoogleEventEditPolicy.organizerIsSelf(raw.organizer),
            etag: raw.etag,
            isRecurring: raw.recurringEventId != nil || raw.recurrence?.isEmpty == false,
            htmlLink: raw.htmlLink.flatMap(URL.init(string:)),
            attendees: attendees,
            timeZoneID: raw.start?.timeZone,
            originalReminders: reminders,
            title: raw.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Event",
            start: range.start,
            end: range.end,
            isAllDay: range.isAllDay,
            location: raw.location ?? "",
            notes: raw.description ?? "",
            availability: raw.transparency == "transparent" ? .free : .busy,
            reminders: reminders,
            recurrenceRules: raw.recurrence ?? []
        )
    }

    private static func eventRange(_ event: GoogleEvent) -> (start: Date, end: Date, isAllDay: Bool)? {
        GoogleCalendarDates.range(of: event)
    }

    private static func eventURL(
        calendarID: String,
        eventID: String,
        sendUpdates: Bool = false
    ) -> URL {
        let calendar = pathComponent(calendarID)
        let event = pathComponent(eventID)
        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/\(calendar)/events/\(event)"
        )!
        if sendUpdates {
            components.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
        }
        return components.url!
    }

    /// An event's URL saying whether Google should email the guests ("all") or not ("none").
    private static func eventURL(calendarID: String, eventID: String, notify: Bool) -> URL {
        var components = URLComponents(url: eventURL(calendarID: calendarID, eventID: eventID),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: notify ? "all" : "none")]
        return components.url!
    }

    private static func moveEventURL(
        sourceCalendarID: String,
        eventID: String,
        destinationCalendarID: String,
        notify: Bool = true
    ) -> URL {
        let calendar = pathComponent(sourceCalendarID)
        let event = pathComponent(eventID)
        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/\(calendar)/events/\(event)/move"
        )!
        components.queryItems = [
            URLQueryItem(name: "destination", value: destinationCalendarID),
            URLQueryItem(name: "sendUpdates", value: notify ? "all" : "none")
        ]
        return components.url!
    }

    private func token(for url: URL, account: GoogleAccountCredential?) async throws -> String {
        if let account { return try await accessToken(for: account) }
        if let calendarID = GoogleRequestRouting.calendarID(fromRequestURL: url) {
            return try await accessToken(forCalendarID: calendarID)
        }
        guard let only = accounts.first, accounts.count == 1 else {
            throw GoogleCalendarError.notConnected
        }
        return try await accessToken(for: only)
    }

    private func request<Response: Decodable>(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        account: GoogleAccountCredential? = nil,
        ifMatch: String? = nil
    ) async throws -> Response {
        let data = try await send(url: url, method: method, body: body, account: account, ifMatch: ifMatch)
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw GoogleCalendarError.malformedResponse }
    }

    private func requestVoid(url: URL, method: String,
                             account: GoogleAccountCredential? = nil) async throws {
        _ = try await send(url: url, method: method, body: nil, account: account)
    }

    /// One Calendar API call. A 401 means the cached access token was refused — revoked early, or
    /// minted for a grant that has since changed — so it is dropped and the call made once more
    /// with a fresh one before giving up.
    private func send(url: URL, method: String, body: Data?,
                      account: GoogleAccountCredential?, ifMatch: String? = nil) async throws -> Data {
        // Beta changes only accounts marked as test accounts (`AppVariant`).
        guard AppVariant.current.mayCallGoogle(method: method, account: owner(of: url, account: account)?.id,
                                               testAccounts: BetaTestAccounts.all) else {
            throw GoogleCalendarError.betaReadOnly
        }
        var attempt = 0
        while true {
            attempt += 1
            let token = try await token(for: url, account: account)
            // Never serve a URLCache response: a read right after a write must see the write.
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.malformedResponse }
            if http.statusCode == 401, attempt == 1 {
                dropCachedToken(for: url, account: account)
                continue
            }
            // If-Match failed: the event changed in Google since it was read.
            if http.statusCode == 412 { throw GoogleCalendarError.changedElsewhere }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data))?.error.message
                throw GoogleCalendarError.api(status: http.statusCode, message: message)
            }
            // Anything Banana changes makes the cached reads stale.
            if method != "GET" { coreFetchedAt = nil }
            return data
        }
    }

    /// The account a request is made for, as `token(for:account:)` chooses it.
    private func owner(of url: URL, account: GoogleAccountCredential?) -> GoogleAccountCredential? {
        if let account { return account }
        if let calendarID = GoogleRequestRouting.calendarID(fromRequestURL: url) {
            return self.account(forCalendarID: calendarID)
        }
        return accounts.count == 1 ? accounts.first : nil
    }

    private func dropCachedToken(for url: URL, account: GoogleAccountCredential?) {
        if let account {
            tokenCache[account.id] = nil
        } else if let calendarID = GoogleRequestRouting.calendarID(fromRequestURL: url),
                  let owner = self.account(forCalendarID: calendarID) {
            tokenCache[owner.id] = nil
        } else if accounts.count == 1, let only = accounts.first {
            tokenCache[only.id] = nil
        }
    }

    /// An access token for the account that owns `calendarID`.
    private func accessToken(forCalendarID calendarID: String) async throws -> String {
        guard let account = account(forCalendarID: calendarID) else {
            throw GoogleCalendarError.notConnected
        }
        return try await accessToken(for: account)
    }

    private func accessToken(for account: GoogleAccountCredential) async throws -> String {
        if let cached = tokenCache[account.id], cached.expiresAt > Date() {
            return cached.accessToken
        }
        guard let clientID else {
            Self.log.error("[google] no GIDClientID in this build; cannot mint a token")
            throw GoogleCalendarError.notConnected
        }
        guard !account.refreshToken.isEmpty else {
            // A credential stored without a refresh token can never mint anything. Worth naming
            // explicitly: it looks identical to a working account until something is fetched.
            Self.log.error("[google] \(account.email, privacy: .public): stored credential has NO refresh token")
            throw GoogleCalendarError.notConnected
        }
        do {
            let minted = try await GoogleTokenMinter.mint(
                refreshToken: account.refreshToken, clientID: clientID)
            Self.log.notice("[google] \(account.email, privacy: .public): minted an access token")
            accountsNeedingReconnect.remove(account.id)
            tokenCache[account.id] = minted
            return minted.accessToken
        } catch GoogleTokenMinter.MintError.credentialRejected(let reason) {
            Self.log.error("[google] \(account.email, privacy: .public): Google REJECTED the refresh token — \(reason ?? "no reason given", privacy: .public)")
            reconnectReasons[account.id] = reason
            // Mark it, do not remove it. Removing meant the synced credential store re-added the
            // same dead account on the next foreground, so it flapped between present and absent —
            // and every disappearance made its meetings vanish, which write-back read as "those
            // blocks are no longer wanted".
            accountsNeedingReconnect.insert(account.id)
            tokenCache[account.id] = nil
            lastError = "Google signed \(account.email) out\(reason.map { " (\($0))" } ?? ""). Reconnect it in Settings."
            throw GoogleCalendarError.notConnected
        }
    }


    // MARK: - Identity and formatting

    static func isGoogleCalendarInfoID(_ id: String?) -> Bool {
        GoogleCalendarIDs.isCalendarInfoID(id)
    }

    static func isGoogleEventInfoID(_ id: String?) -> Bool {
        GoogleCalendarIDs.isEventInfoID(id)
    }

    @discardableResult
    static func handleOpenURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    static func calendarInfoID(_ rawID: String) -> String {
        GoogleCalendarIDs.calendarInfoID(rawID)
    }

    static func rawCalendarID(from infoID: String) -> String? {
        GoogleCalendarIDs.rawCalendarID(from: infoID)
    }

    private static func eventInfoID(calendarID: String, eventID: String) -> String {
        GoogleCalendarIDs.eventInfoID(calendarID: calendarID, eventID: eventID)
    }

    private static func rawEventRoute(from infoID: String) -> (calendarID: String, eventID: String)? {
        GoogleCalendarIDs.rawEventRoute(from: infoID)
    }

    private func calendarInfo(for calendar: GoogleCalendar) -> CalendarSourceInfo {
        CalendarSourceInfo(
            id: Self.calendarInfoID(calendar.id),
            title: calendar.displayTitle,
            colorHex: calendar.backgroundColor,
            // Per calendar, not per service: with several accounts connected these group the
            // picker by the account a calendar actually belongs to.
            sourceID: "google-account:\(calendar.accountEmail.isEmpty ? "connected" : calendar.accountEmail)",
            sourceTitle: calendar.accountEmail.isEmpty ? "Google" : "Google · \(calendar.accountEmail)",
            isDefault: calendar.isPrimary,
            provider: .google
        )
    }

    private static func calendarInfoSort(
        _ lhs: CalendarSourceInfo,
        _ rhs: CalendarSourceInfo
    ) -> Bool {
        if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    nonisolated private static func pathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )) ?? raw
    }

    nonisolated private static func rfc3339(_ date: Date) -> String {
        GoogleCalendarDates.rfc3339(date)
    }

    private static func eventDateJSON(
        _ date: Date,
        allDay: Bool,
        timeZoneID: String? = TimeZone.current.identifier
    ) -> [String: String] {
        if allDay { return ["date": GoogleCalendarDates.dateString(date)] }
        var value = ["dateTime": rfc3339(date)]
        if let timeZoneID { value["timeZone"] = timeZoneID }
        return value
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let error = error as? LocalizedError, let message = error.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

/// Google sends no change notices for this calendar (holidays, subscribed feeds).
struct CalendarWatchUnsupported: Error {}

private enum GoogleCalendarError: LocalizedError {
    case notConnected
    case permissionMissing
    case noPresentationContext
    case malformedResponse
    case eventUnavailable
    /// Banana's own block, or something else nobody edits by hand.
    case notEditable
    /// If-Match failed: someone changed it in Google since it was opened.
    case changedElsewhere
    /// An invitation someone else organizes.
    case notYours
    /// Beta, and the account isn't marked as a test account.
    case betaReadOnly
    case api(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect Google Calendar in Banana Settings and try again."
        case .permissionMissing:
            return "Google Calendar permission wasn’t granted. Connect again and allow both calendar permissions."
        case .noPresentationContext:
            return "Banana couldn’t open Google sign-in. Bring the app window forward and try again."
        case .malformedResponse:
            return "Google Calendar returned data Banana couldn’t read."
        case .eventUnavailable:
            return "That Google Calendar event is no longer available."
        case .notEditable:
            return "Banana keeps this block up to date itself, so it can\u{2019}t be edited."
        case .notYours:
            return "Only the organizer can change this event\u{2019}s time."
        case .betaReadOnly:
            return "Banana Beta only changes test accounts. Mark this one in Settings \u{203A} Google Calendar."
        case .changedElsewhere:
            return "This event changed in Google Calendar since you opened it. Open it again to see the change, then make yours."
        case .api(let status, let message):
            if status == 403 {
                return message ?? "Google Calendar denied this request. Confirm the Calendar API and OAuth scopes are enabled in Google Cloud."
            }
            if status == 401 { return "Google refused Banana’s sign-in for this calendar. Reconnect the account in Settings." }
            return message ?? "Google Calendar request failed (\(status))."
        }
    }
}

private extension CalendarItemRecurrence {
    var googleFrequency: String {
        switch self {
        case .never: return ""
        case .daily: return "DAILY"
        case .weekly: return "WEEKLY"
        case .monthly: return "MONTHLY"
        case .yearly: return "YEARLY"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

extension MeetingInfo {
    /// Merge a direct provider into the EventKit agenda without showing the same Google event
    /// twice when that account is also configured in Apple Calendar. The primary list wins.
    static func merging(primary: [MeetingInfo], additional: [MeetingInfo]) -> [MeetingInfo] {
        var seen = Set(primary.map(mergeIdentity))
        var result = primary
        for meeting in additional where seen.insert(mergeIdentity(meeting)).inserted {
            result.append(meeting)
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func mergeIdentity(_ meeting: MeetingInfo) -> String {
        let title = meeting.title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return "\(Int(meeting.start.timeIntervalSince1970))-\(Int((meeting.end ?? meeting.start).timeIntervalSince1970))-\(title)"
    }
}

#if BANANA_UNRELEASED
extension GoogleCalendarService {
    /// Reuse Google's platform presenter without accepting a Calendar account or changing its grant.
    func googleConsent(hint: String, scopes: [String]) async throws -> GoogleConsentResult {
        guard clientID != nil else { throw GoogleConsentError.notConfigured }
        do {
            let result = try await interactiveSignIn(hint: hint, scopes: scopes)
            defer { GIDSignIn.sharedInstance.signOut() }
            guard let email = result.user.profile?.email else { throw GoogleConsentError.failed }
            return GoogleConsentResult(email: email,
                refreshToken: result.user.refreshToken.tokenString,
                grantedScopes: result.user.grantedScopes ?? [])
        } catch is CancellationError { throw GoogleConsentError.cancelled }
        catch GoogleCalendarError.noPresentationContext { throw GoogleConsentError.noWindow }
        catch { throw GoogleConsentError.failed }
    }
}

#endif

extension GoogleCalendarService {
    struct SearchPage {
        var events: [GoogleCalendarEvent]
        var calendarTitle: String?
        var next: CalendarSearchCursor?
    }

    /// One bounded provider page, independent of the timeline cache. Each calendar is
    /// visited separately; the UI labels that order instead of claiming a global date sort.
    func search(_ query: CalendarSearchQuery, after cursor: CalendarSearchCursor? = nil) async throws -> SearchPage {
        guard query.isValid else { return SearchPage(events: [], calendarTitle: nil, next: nil) }
        await restoreIfNeeded()
        await loadCalendarsIfStale()
        try Task.checkCancellation()
        guard isConnected, !hasDegradedSources else { throw GoogleCalendarError.eventUnavailable }
        let ids = calendars.filter { calendar in
            !calendar.isDeleted && !calendar.isHidden && !query.excludedCalendarIDs.contains(Self.calendarInfoID(calendar.id))
                && query.filter.terms.filter { $0.field == "calendar" }.allSatisfy { term in term.op == "not" ? calendar.id != term.value : calendar.id == term.value }
        }.map(\.id).sorted()
        if let cursor {
            guard cursor.query == query, cursor.calendarIDs == ids,
                  ids.indices.contains(cursor.calendarIndex) else { throw GoogleCalendarError.eventUnavailable }
        }
        let index = cursor?.calendarIndex ?? 0
        guard ids.indices.contains(index) else { return SearchPage(events: [], calendarTitle: nil, next: nil) }
        let id = ids[index]
        guard let url = query.googleURL(calendarID: id, pageToken: cursor?.pageToken) else {
            throw GoogleCalendarError.malformedResponse
        }
        let data = try await send(url: url, method: "GET", body: nil, account: nil)
        let page = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(GoogleEventsResponse.self, from: data)
        }.value
        try Task.checkCancellation()
        guard (page.items?.count ?? 0) <= 50,
              page.nextPageToken == nil || (page.nextPageToken != cursor?.pageToken && page.nextPageToken != "") else {
            throw GoogleCalendarError.malformedResponse
        }
        let next: CalendarSearchCursor?
        if let token = page.nextPageToken {
            next = CalendarSearchCursor(query: query, calendarIDs: ids, calendarIndex: index, pageToken: token)
        } else if index + 1 < ids.count {
            next = CalendarSearchCursor(query: query, calendarIDs: ids, calendarIndex: index + 1, pageToken: nil)
        } else { next = nil }
        return SearchPage(events: (page.items ?? []).filter { event in
            guard event.status != "cancelled" else { return false }
            return query.filter.terms.allSatisfy { term in
                switch term.field {
                case "text": return ([event.summary, event.location, event.description].compactMap { $0 }.joined(separator: "\n") as NSString).localizedCaseInsensitiveContains(term.value)
                case "status":
                    let status = event.attendees?.first { $0.selfAttendee == true }?.responseStatus ?? "accepted"
                    return term.op == "not" ? status != term.value : status == term.value
                case "allDay": return (event.start?.date != nil) == (term.value == "true")
                case "kind": return event.attendees?.contains { $0.selfAttendee != true } == true
                case "person": return event.attendees?.contains { (($0.displayName ?? "") as NSString).localizedCaseInsensitiveContains(term.value) || (($0.email ?? "") as NSString).localizedCaseInsensitiveContains(term.value) } == true
                default: return true
                }
            }
        }.compactMap {
            calendarEvent($0, calendarID: id)
        }, calendarTitle: calendars.first { $0.id == id }?.displayTitle, next: next)
    }
}
