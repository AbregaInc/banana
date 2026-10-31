import Foundation
import SwiftUI
import CoreLocation
import MapKit
#if os(macOS)
import AppKit
#endif

/// Owns smart-schedule settings and drives the whole flow: read the calendar,
/// compute the plan, and schedule the wake alarm(s) + bedtime notifications.
/// When enabled it "owns" the alarm — manual slots are suspended.
@MainActor
final class SmartScheduleStore: ObservableObject {
    /// Fallback for a headless background launch, where `BananaApp`'s `@StateObject` never gets
    /// built and `OccurrenceStore.shared.smart` is never wired (the root view's `.task` that does
    /// that wiring doesn't run — same lesson `WakeCoordinator` and `RoutineStore.shared` already
    /// encode for their own singletons). `settings` — the only state `calendarTravelOccurrences`
    /// actually reads — is persisted to `UserDefaults` in `init()` below, so a freshly-built
    /// instance here reflects whatever was last saved from the real (foreground) store, same as
    /// `RoutineStore.shared` does for routines. Not used by the normal foreground path, where
    /// `OccurrenceStore.shared.smart` is already the live, wired instance.
    static let shared = SmartScheduleStore()

    @Published var settings: SmartScheduleSettings {
        didSet {
            Calendar.appFirstWeekday = settings.weekStartWeekday
            persist()
            scheduleApply()
            if settings.mutedCalendarIDs != oldValue.mutedCalendarIDs
                || settings.excludedCalendarIDs != oldValue.excludedCalendarIDs {
                OccurrenceStore.shared.calendarNotificationSettingsChanged()
            }
            if settings.blockTravelTime != oldValue.blockTravelTime
                || settings.transitMode != oldValue.transitMode
                || settings.savedPlaces != oldValue.savedPlaces
                || settings.walkShortTrips != oldValue.walkShortTrips
                || settings.walkShortTripMeters != oldValue.walkShortTripMeters
                || settings.learnFromTrips != oldValue.learnFromTrips
                || settings.learnedTravel != oldValue.learnedTravel
                || settings.homeLatitude != oldValue.homeLatitude
                || settings.homeLongitude != oldValue.homeLongitude
                || settings.workLatitude != oldValue.workLatitude
                || settings.workLongitude != oldValue.workLongitude
                || settings.mutedCalendarIDs != oldValue.mutedCalendarIDs
                || settings.excludedCalendarIDs != oldValue.excludedCalendarIDs
                || settings.writeBackExcludedCalendarIDs != oldValue.writeBackExcludedCalendarIDs
                || settings.writeBackSharedCalendarIDs != oldValue.writeBackSharedCalendarIDs
                || settings.allDayChoice != oldValue.allDayChoice
                || settings.reserveTaskTime != oldValue.reserveTaskTime
                || settings.writeBackEnabled != oldValue.writeBackEnabled
                || settings.writeBackCalendarID != oldValue.writeBackCalendarID {
                OccurrenceStore.shared.requestRecompute(reason: "travel availability settings")
            }
            if settings.calendarColorChoices != oldValue.calendarColorChoices { refreshCalendarColors() }
        }
    }
    @Published private(set) var plan: WakePlan?
    @Published var calendarAuthorized = false
    @Published var errorMessage: String?

    /// Today's full agenda + computed commute legs — for the merged Today day view.
    @Published private(set) var todayMeetings: [MeetingInfo] = []
    @Published private(set) var tomorrowMeetings: [MeetingInfo] = []
    @Published private(set) var commuteLegs: [NotificationService.CommuteLeg] = []
    @Published private(set) var flightLegs: [FlightLeg] = []

    /// Answer "where is this?" for a calendar location: remembered (and synced) for every event
    /// with the same location text, and every trip is re-timed at once.
    /// `mode` replaces the place's saved mode (nil = automatic); leave `replacingMode` false to
    /// keep whatever was saved, as a one-tap confirm does.
    func confirmPlace(_ locationText: String, name: String, address: String?,
                      coordinate: CLLocationCoordinate2D, mode: TransitMode? = nil,
                      replacingMode: Bool = false) {
        var places = settings.savedPlaces
        let keep = places.place(for: locationText)?.mode
        places.remember(SavedPlace(query: locationText, name: name, address: address,
                                   latitude: coordinate.latitude, longitude: coordinate.longitude,
                                   mode: replacingMode ? mode : keep))
        settings.savedPlaces = places
        Log.travel.notice("[travel] confirmed \(locationText, privacy: .public) → \(name, privacy: .public)")
    }

    /// Set how you get to a place. For a place that isn't a guess (an address, or an event with
    /// coordinates) it's saved at the spot the trip is timed to; a guess is confirmed first, in
    /// the picker, so choosing a mode can never quietly confirm the wrong Chelsea.
    func setMode(_ mode: TransitMode?, forPlace locationText: String, fallbackName: String,
                 coordinate: CLLocationCoordinate2D?) {
        var places = settings.savedPlaces
        if var place = places.place(for: locationText) {
            place.mode = mode
            places.remember(place)
        } else if let coordinate {
            places.remember(SavedPlace(query: locationText, name: fallbackName,
                                       latitude: coordinate.latitude, longitude: coordinate.longitude, mode: mode))
        } else {
            return
        }
        settings.savedPlaces = places
    }

    /// Where a location is currently timed to, for the picker to centre on and to save a mode
    /// against. Home when nothing better is known.
    var travelSearchCenter: CLLocationCoordinate2D? { homeCoordinate ?? workCoordinate }

    func placeCandidates(for locationText: String, eventTitle: String? = nil,
                         useModel: Bool = true) async -> [PlaceCandidate] {
        guard let center = travelSearchCenter else { return [] }
        return await travel.candidates(for: locationText, eventTitle: eventTitle, useModel: useModel, near: center)
    }

    /// Calendar read for the Today + Tomorrow views (no travel calls).
    func refreshAgenda() async {
        let google = GoogleCalendarService.shared
        await google.restoreIfNeeded()
        let authorized = google.isConnected
        if calendarAuthorized != authorized { calendarAuthorized = authorized }
        guard calendarAuthorized else {
            if !todayMeetings.isEmpty { todayMeetings = [] }
            if !tomorrowMeetings.isEmpty { tomorrowMeetings = [] }
            return
        }
        let excluded = settings.excludedCalendarIDs
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 2, to: start) else { return }
        let merged = await google.meetings(from: start, to: end, excluding: excluded)
        let today = merged.filter { cal.isDate($0.start, inSameDayAs: start) }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let nextDay = merged.filter { cal.isDate($0.start, inSameDayAs: tomorrow) }
        if !Self.sameMeetings(todayMeetings, today) { todayMeetings = today }
        if !Self.sameMeetings(tomorrowMeetings, nextDay) { tomorrowMeetings = nextDay }
        refreshCalendarColors()
    }

    private static func sameMeetings(_ lhs: [MeetingInfo], _ rhs: [MeetingInfo]) -> Bool {
        guard lhs.count == rhs.count,
              let left = try? JSONEncoder().encode(lhs),
              let right = try? JSONEncoder().encode(rhs) else { return false }
        return left == right
    }

    /// The planned wake + bedtime for a given day, from the computed plan.
    func planDay(for date: Date) -> WakePlan.Day? {
        plan?.days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    /// Pull-to-refresh: nudge the calendar accounts to sync, re-read immediately, then
    /// read once after a beat so a fast server sync shows up.
    func refreshCalendar() async {
        GoogleCalendarService.shared.invalidateEventCache()
        await GoogleCalendarService.shared.refresh()
        try? await Task.sleep(for: .seconds(1.2))
        if settings.enabled {
            // recompute already refreshes the agenda. The old path fetched Today/Tomorrow here,
            // fetched them again after the delay, then recompute fetched them a third time.
            await recompute()
        } else {
            await refreshAgenda()
        }
    }

    var writableEventCalendars: [CalendarSourceInfo] {
        GoogleCalendarService.shared.writableCalendarInfos
    }

    /// Does this meeting repeat? The week grids ask before committing a drag, so a recurring
    /// event can offer this-one-vs-all-future rather than silently picking one.
    func meetingRecurs(_ meeting: MeetingInfo) -> Bool {
        meeting.isRecurring
    }

    /// Drag-to-move on the week grid: same event, same duration, new start.
    @discardableResult
    func moveMeeting(_ meeting: MeetingInfo, to newStart: Date,
                     span: CalendarEditSpan = .thisEvent) async -> String? {
        guard GoogleCalendarService.isGoogleEventInfoID(meeting.eventID) else {
            return "That event is no longer in your calendar."
        }
        // Drag offers occurrence/entire series. The existing multi-request following
        // edit remains separate until it has its own durable transaction representation.
        if span == .futureEvents {
            do { try await GoogleCalendarService.shared.moveEvent(meeting, to: newStart, scope: span.googleScope) }
            catch { return error.localizedDescription }
        } else {
            let intent = CalendarMoveIntent(eventID: meeting.eventID!, title: meeting.title,
                originalStart: meeting.start, originalEnd: meeting.end, destination: newStart,
                scope: span == .allEvents ? .series : .occurrence)
            if let failure = await performMoveIntent(intent) { return failure }
        }
        await refreshAgenda()
        OccurrenceStore.shared.requestRecompute(reason: "Google Calendar event moved")
        return nil
    }

    private func performMoveIntent(_ intent: CalendarMoveIntent) async -> String? {
        await CalendarMoveRecoveryStore.shared.perform(intent,
            prepare: { try await GoogleCalendarService.shared.prepareMove($0) },
            apply: { try await GoogleCalendarService.shared.applyPreparedMove($0) })
    }

    func retryMoveIntent(_ intent: CalendarMoveIntent) async {
        guard await performMoveIntent(intent) == nil else { return }
        await refreshAgenda()
        await OccurrenceStore.shared.recompute(reason: "pending calendar move recovered")
    }

    /// Delete an event from its calendar. Returns an error message, or nil on success.
    @discardableResult
    func deleteMeeting(_ meeting: MeetingInfo, span: CalendarEditSpan = .thisEvent) async -> String? {
        guard let eventID = meeting.eventID, GoogleCalendarService.isGoogleEventInfoID(eventID) else {
            return "That event is no longer in your calendar."
        }
        do {
            try await GoogleCalendarService.shared.deleteEvent(eventInfoID: eventID, scope: span.googleScope)
        } catch {
            return error.localizedDescription
        }
        await refreshAgenda()
        // Awaited: the event is only shown again (its Undo window closing) once the day has been
        // rebuilt without it — a recompute merely requested let it flash back for a moment.
        await OccurrenceStore.shared.recompute(reason: "Google Calendar event deleted")
        return nil
    }

    /// One save from the event editor.
    struct EventEdit {
        var original: GoogleCalendarEvent
        var edited: GoogleCalendarEvent
        var destinationCalendarID: String
        var scope: GoogleCalendarEventScope
        var recurrence: GoogleRecurrenceChange
        var fieldsChanged: Bool
        /// Guests added or taken off.
        var guests = GoogleGuestChange()
        /// "Saved “Standup”", "“Standup” now repeats every week on Mon, Wed and Fri".
        var message: String
    }

    /// Save an edit the way the grid saves a drag: the editor has closed, the event is drawn as
    /// edited at once (`OccurrenceStore.beginEventEdit`), Google is written in the background,
    /// and then a toast — with Undo where it can be undone, or Retry when the save failed.
    func saveEventEdit(_ edit: EventEdit) {
        Telemetry.shared.record(.feature(.eventEdited))
        let occurrences = OccurrenceStore.shared
        occurrences.beginEventEdit(PendingEventEdit(
            eventID: edit.edited.id, title: edit.edited.title, start: edit.edited.start,
            end: edit.edited.end, location: edit.edited.location))
        Task { @MainActor in
            do {
                let outcome = try await GoogleCalendarService.shared.updateEvent(
                    edit.edited,
                    destinationCalendarInfoID: edit.destinationCalendarID,
                    scope: edit.scope,
                    recurrence: edit.recurrence,
                    fieldsChanged: edit.fieldsChanged,
                    guests: edit.guests)
                // The next read asks Google again: the guest list isn't Banana's to guess at.
                if !edit.guests.isEmpty { GoogleCalendarService.shared.invalidateEventCache() }
                await refreshAgenda()
                await occurrences.recompute(reason: "calendar event edited")
                occurrences.endEventEdit(edit.edited.id)
                await ToastCenter.shared.offerUndo(edit.message, undo: undo(edit, outcome: outcome))
            } catch {
                occurrences.endEventEdit(edit.edited.id)
                let title = edit.edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
                await ToastCenter.shared.offerRetry(
                    "Couldn\u{2019}t save \u{201C}\(title)\u{201D}: \(error.localizedDescription)") {
                    self.saveEventEdit(edit)
                }
            }
        }
    }

    /// How to take a save back, or nil where that isn't safe: a move to another calendar (the
    /// event has a new address), and a time change to a whole series (its occurrences have new
    /// ids, so the one opened can't be found to put back).
    private func undo(_ edit: EventEdit, outcome: GoogleEventEditOutcome) -> (() async -> String?)? {
        // An invitation that has gone out can't be taken back quietly, and nor can telling
        // someone they're off the event: a guest change is put right by editing the guests again.
        guard edit.guests.isEmpty else { return nil }
        let google = GoogleCalendarService.shared
        let refresh: () async -> Void = { [weak self] in
            await self?.refreshAgenda()
            await OccurrenceStore.shared.recompute(reason: "calendar edit undone")
        }
        if outcome.newSeriesInfoID != nil {
            return {
                do { try await google.undoFollowing(outcome) } catch { return error.localizedDescription }
                await refresh()
                return nil
            }
        }
        guard edit.destinationCalendarID == edit.original.calendarInfoID else { return nil }
        switch edit.recurrence {
        case .setRule, .endAfterOccurrence:
            if edit.original.isRecurring {
                // The series' lines back; its other fields only when this occurrence alone changed.
                guard !edit.fieldsChanged || edit.recurrence == .endAfterOccurrence else { return nil }
                return {
                    do {
                        try await google.restoreRecurrence(outcome)
                        if edit.fieldsChanged {
                            try await google.updateEvent(edit.original.undoing(edit.edited), scope: .occurrence, checkUnchanged: false)
                        }
                    } catch { return error.localizedDescription }
                    await refresh()
                    return nil
                }
            }
            // A single event made into a series a moment ago: back to a single event, as it was.
            return {
                do {
                    try await google.updateEvent(edit.original.undoing(edit.edited), recurrence: .restore([]), checkUnchanged: false)
                } catch { return error.localizedDescription }
                await refresh()
                return nil
            }
        case .unchanged, .restore:
            guard edit.scope == .occurrence || !edit.original.isRecurring else { return nil }
            return {
                do {
                    try await google.updateEvent(edit.original.undoing(edit.edited), scope: .occurrence, checkUnchanged: false)
                } catch { return error.localizedDescription }
                await refresh()
                return nil
            }
        }
    }

    #if DEBUG
    /// Replace today's agenda outright, for previews that need specific meetings.
    func injectTodayMeetingsForPreview(_ meetings: [MeetingInfo]) {
        todayMeetings = meetings
    }

    /// `--event-states-sample`: give the sample agenda one of each invitation state and a meeting
    /// merged from three calendars, so the grid treatments can be screenshotted.
    func injectEventStateSamples() {
        calendarColorHex = ["google:work": "#1A73E8", "google:home": "#33B679", "google:side": "#F4511E"]
        todayMeetings = todayMeetings.enumerated().map { index, meeting in
            var meeting = meeting
            if meeting.end == nil { meeting.end = meeting.start.addingTimeInterval(60 * 60) }
            meeting.calendarID = "google:work"
            switch index {
            case 0: meeting.myResponse = .tentative; meeting.title = "Team standup (maybe)"
            case 1: meeting.myResponse = .needsAction; meeting.title = "Client review (not answered)"
            default:
                meeting.othersAllDeclined = true
                meeting.alsoOnCalendarIDs = ["google:home", "google:side"]
                meeting.title = "Site walkthrough (3 calendars, others declined)"
            }
            return meeting
        }
    }

    /// `--trip-sample`: a flight to Berlin this week and home next week, for the time-zone column.
    func injectTripSample() {
        let now = Date()
        func at(_ days: Int, _ hour: Int) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
            return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        flightLegs = [
            FlightLeg(flightStart: at(-1, 18), destCode: "BER", arriveAt: at(0, 2), boardingAt: nil,
                      leaveBy: nil, toAirportMin: nil, bufferMin: 0, international: true, toStayMin: nil, stayName: nil),
            FlightLeg(flightStart: at(6, 10), destCode: "JFK", arriveAt: at(6, 13), boardingAt: nil,
                      leaveBy: nil, toAirportMin: nil, bufferMin: 0, international: true, toStayMin: nil, stayName: nil),
        ]
    }

    /// Sample agenda + commute legs for layout verification (no calendar needed).
    func injectSampleAgenda(anchoredToBusinessHours: Bool = false) {
        let cal = Calendar.current, now = Date()
        // Keep the preview useful at any capture hour. Fixed 9/11/4 events made an evening
        // screenshot look like an empty day because every sample had already folded into the
        // completed section. Quarter-hour rounding keeps the labels calm and repeatable while
        // ensuring there is always a real "up next."
        func offset(_ minutes: Int) -> Date {
            let shifted = now.addingTimeInterval(Double(minutes * 60))
            let minute = cal.component(.minute, from: shifted)
            return cal.date(byAdding: .minute, value: -(minute % 15), to: shifted) ?? shifted
        }
        func todayAt(_ hour: Int, _ minute: Int) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        // The travel sample needs trips still ahead: bands are only drawn before a meeting to come.
        let anchored = anchoredToBusinessHours && !ProcessInfo.processInfo.arguments.contains("--travel-sample")
        let standup = anchored ? todayAt(9, 0) : offset(-75)
        let review = anchored ? todayAt(11, 0) : offset(45)
        let walkthrough = anchored ? todayAt(15, 30) : offset(225)
        todayMeetings = [
            MeetingInfo(start: standup, coordinate: nil, address: nil, isVirtual: true, title: "Team standup"),
            MeetingInfo(start: review, coordinate: .init(latitude: 37.789, longitude: -122.401), address: "500 Howard St", isVirtual: false, title: "Client review"),
            MeetingInfo(start: walkthrough, coordinate: .init(latitude: 37.776, longitude: -122.417), address: "1 Dr Carlton B Goodlett Pl", isVirtual: false, title: "Site walkthrough"),
        ]
        commuteLegs = [
            .init(title: "Client review", start: review, leaveBy: review.addingTimeInterval(-22 * 60), travelMinutes: 22),
            .init(title: "Site walkthrough", start: walkthrough, leaveBy: walkthrough.addingTimeInterval(-18 * 60), travelMinutes: 18),
        ]
        // `--travel-sample`: one trip to a confirmed address and one to a guessed place, for
        // checking what the bands, Today and the inspector say about each.
        if ProcessInfo.processInfo.arguments.contains("--travel-sample") {
            todayMeetings[2] = MeetingInfo(start: walkthrough, coordinate: nil, address: "Chelsea",
                                           isVirtual: false, title: "Lap Swim")
            commuteLegs = [
                .init(title: "Client review", start: review, leaveBy: review.addingTimeInterval(-25 * 60),
                      travelMinutes: 25,
                      detail: TravelLegDetail(mode: .transit, minutes: 22, placeName: "500 Howard St",
                                              query: "500 Howard St", confidence: .address,
                                              latitude: 37.789, longitude: -122.401)),
                .init(title: "Lap Swim", start: walkthrough, leaveBy: walkthrough.addingTimeInterval(-10 * 60),
                      travelMinutes: 10,
                      detail: TravelLegDetail(mode: .walk, minutes: 7, placeName: "Chelsea", query: "Chelsea",
                                              confidence: .guessed, latitude: 40.7465, longitude: -74.0014)),
            ]
        }
        let tmw = cal.date(byAdding: .day, value: 1, to: now) ?? now
        func atT(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: tmw) ?? tmw }
        tomorrowMeetings = [
            MeetingInfo(start: atT(9, 30), coordinate: nil, address: nil, isVirtual: true, title: "Design sync", eventID: nil),
            MeetingInfo(start: atT(13, 0), coordinate: .init(latitude: 37.79, longitude: -122.40), address: "Blue Bottle, 66 Mint St", isVirtual: false, title: "Lunch w/ Sam", eventID: nil),
            MeetingInfo(start: atT(15, 30), coordinate: nil, address: nil, isVirtual: true, title: "Board prep", eventID: nil),
        ]
        if Self.isStoreCapture { injectStoreCaptureAgenda() }
    }

    /// `--store-capture`: the launch is a marketing capture (`tools/app-store/generate.py`).
    nonisolated static var isStoreCapture: Bool { ProcessInfo.processInfo.arguments.contains("--store-capture") }

    private static let storeCalendars = (work: "google:store-work", home: "google:store-home", side: "google:store-side")

    private func storeMeeting(_ day: Date, _ hour: Int, _ minute: Int, minutes: Int, _ title: String, _ calendar: String,
                              address: String? = nil, coordinate: CLLocationCoordinate2D? = nil) -> MeetingInfo {
        let start = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        var meeting = MeetingInfo(start: start, end: start.addingTimeInterval(Double(minutes) * 60), coordinate: coordinate,
                                  address: address, isVirtual: address == nil, title: title,
                                  eventID: "store-\(Occurrence.dayKey(day))-\(title)")
        meeting.calendarID = calendar
        return meeting
    }

    /// The day a marketing capture shows: the same at any hour of the run (the default sample
    /// follows the clock, so a morning run photographed a different day from an afternoon one),
    /// each event on a calendar with a colour of its own, and none of the layout tests' props.
    private func injectStoreCaptureAgenda() {
        let now = Date(), cal = Calendar.current
        let c = Self.storeCalendars
        calendarColorHex = [c.work: "#1A73E8", c.home: "#33B679", c.side: "#8E24AA"]
        let review = cal.date(bySettingHour: 11, minute: 0, second: 0, of: now) ?? now
        let walkthrough = cal.date(bySettingHour: 15, minute: 30, second: 0, of: now) ?? now
        todayMeetings = [
            storeMeeting(now, 9, 0, minutes: 30, "Team standup", c.work),
            storeMeeting(now, 11, 0, minutes: 60, "Client review", c.work, address: "500 Howard St",
                         coordinate: .init(latitude: 37.789, longitude: -122.401)),
            storeMeeting(now, 12, 30, minutes: 45, "Lunch with Sam", c.home),
            storeMeeting(now, 15, 30, minutes: 60, "Site walkthrough", c.work, address: "1 Dr Carlton B Goodlett Pl",
                         coordinate: .init(latitude: 37.776, longitude: -122.417)),
            storeMeeting(now, 18, 30, minutes: 60, "Yoga", c.side),
        ]
        commuteLegs = [
            .init(title: "Client review", start: review, leaveBy: review.addingTimeInterval(-22 * 60), travelMinutes: 22),
            .init(title: "Site walkthrough", start: walkthrough, leaveBy: walkthrough.addingTimeInterval(-18 * 60), travelMinutes: 18),
        ]
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        tomorrowMeetings = [
            storeMeeting(tomorrow, 9, 30, minutes: 45, "Design sync", c.work),
            storeMeeting(tomorrow, 13, 0, minutes: 60, "Dentist", c.home),
            storeMeeting(tomorrow, 15, 30, minutes: 60, "Board prep", c.work),
        ]
    }

    /// The rest of the week around today, for the week views in a marketing capture. Empty for
    /// any other launch.
    func storeCaptureOtherDays() -> [MeetingInfo] {
        guard Self.isStoreCapture else { return [] }
        let now = Date(), cal = Calendar.current
        let c = Self.storeCalendars
        let plans: [[(Int, Int, Int, String, String)]] = [
            [(10, 0, 60, "Roadmap review", c.work), (14, 0, 45, "1:1 with Priya", c.work), (18, 0, 60, "Run club", c.side)],
            [(9, 0, 30, "Team standup", c.work), (11, 30, 60, "Hiring sync", c.work), (16, 0, 30, "School pickup", c.home)],
            [(9, 0, 30, "Team standup", c.work), (13, 0, 90, "Workshop", c.work), (19, 0, 90, "Dinner with friends", c.home)],
        ]
        var meetings: [MeetingInfo] = []
        for offset in [-4, -3, -2, -1, 2, 3, 4] {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekday = cal.component(.weekday, from: day)
            if weekday == 1 || weekday == 7 {
                // A weekend: one thing, not a working day.
                meetings.append(storeMeeting(day, 10, 30, minutes: 90, weekday == 7 ? "Farmers market" : "Long run", c.side))
                continue
            }
            for (hour, minute, length, title, calendar) in plans[abs(offset) % plans.count] {
                meetings.append(storeMeeting(day, hour, minute, minutes: length, title, calendar))
            }
        }
        return meetings
    }
    #endif

    weak var alarms: AlarmStore?
    weak var health: HealthKitStore?

    /// Human-readable current adjustment (for the settings screen).
    @Published private(set) var healthNote: String?

    private let travel = TravelService()
    private let defaults = UserDefaults.standard
    private let key = "smartScheduleSettings"
    private let cloud = LegacyKVS.shared
    private static let cloudSettingsKey = "smartScheduleSettings.v1"
    private static let cloudWakePlanKey = "smartWakePlan.v1"
    private static let settingsUpdatedAtKey = "smartScheduleSettingsUpdatedAt.v1"
    private var applyingRemoteSettings = false
    private var settingsUpdatedAt = Date.distantPast
    private var cloudObserver: NSObjectProtocol?
    private var remoteWakePlan: WakePlan?
    private var remoteExcludedCalendars: Set<CalendarIdentity>?
    private var remoteWriteBackExcludedCalendars: Set<CalendarIdentity>?
    private var changeObserver: NSObjectProtocol?
    private var settingsApplyTask: Task<Void, Never>?

    /// EventKit calendar identifiers are local to one event store. Sync the human-stable account
    /// + calendar names and resolve them back to local identifiers on the receiving device.
    struct CalendarIdentity: Codable, Hashable {
        let sourceTitle: String
        let calendarTitle: String
    }

    struct CloudSettingsSnapshot: Codable, Equatable {
        let updatedAt: Date
        let settings: SmartScheduleSettings
        let excludedCalendars: Set<CalendarIdentity>
        /// Optional for snapshots written before write-back destinations became portable.
        let writeBackExcludedCalendars: Set<CalendarIdentity>?
        /// True when the calendar ids inside `settings` are Google ids — the same on every device
        /// — so they can be adopted as they are. Absent from snapshots written by builds that
        /// still used Apple Calendar, whose ids meant nothing elsewhere.
        var calendarIDsAreGoogle: Bool? = nil
    }

    /// The phone owns the wake plan because it is the only platform with AlarmKit and HealthKit.
    /// Macs consume this compact derived result instead of independently guessing without health.
    struct CloudWakePlanSnapshot: Codable, Equatable {
        let generatedAt: Date
        let timeZoneIdentifier: String
        let plan: WakePlan
    }

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SmartScheduleSettings.self, from: data) {
            settings = decoded
        } else {
            settings = SmartScheduleSettings()
        }
        Calendar.appFirstWeekday = settings.weekStartWeekday
        settingsUpdatedAt = defaults.object(forKey: Self.settingsUpdatedAtKey) as? Date ?? .distantPast
        calendarAuthorized = GoogleCalendarService.shared.isConnected
        calendarColorHex = defaults.dictionary(forKey: Self.calendarColorsKey) as? [String: String] ?? [:]
        refreshCalendarColors()
        observeCalendarChanges()

        observeCloudSchedule()
        LaunchClock.mark("smart.init")
    }

    var isEnabled: Bool { settings.enabled }

    /// The calendar list, cached, because this is read from view bodies — SmartScheduleView's calendarsSection puts it straight in a
    /// ForEach, so every render of that screen was paying for a fetch.
    @Published private(set) var availableCalendars: [CalendarSourceInfo] = []

    /// Source-calendar colours, keyed by calendar id: each calendar its own
    /// (`CalendarColorAssignment`), Google's where it doesn't collide. Cached because a grid asks per block, per render — the Week view
    /// draws hundreds.
    /// Each calendar's colour, by calendar id. Saved, so a launch draws events in their colours from
    /// the first frame — it used to start empty and fill in only once the calendar list came back
    /// from Google, so every event was grey for the first seconds and then changed colour.
    @Published private(set) var calendarColorHex: [String: String] = [:] {
        didSet { defaults.set(calendarColorHex, forKey: Self.calendarColorsKey) }
    }
    private static let calendarColorsKey = "calendarColorHexCache"   // dot-free: see the AppStorage storm
    #if DEBUG
    func injectPreviewCalendarColors(_ colors: [String: String]) { calendarColorHex = colors }
    #endif

    /// The colour a calendar is shown in: its own in Banana, else what Google says.
    func shownColor(_ calendarID: String?, google: String?) -> String? {
        calendarID.flatMap { calendarColorHex[$0] } ?? google
    }

    /// One calendar-list read, two products: the list and the id→colour map.
    func refreshCalendarColors() {
        let list = GoogleCalendarService.shared.allCalendarInfos
        if list.map(\.id) != availableCalendars.map(\.id) { migrateCalendarExclusionsToGoogle(list) }
        guard !list.isEmpty || calendarAuthorized else {
            // Nothing loaded yet at launch isn't "no calendars": keep the saved colours until the
            // accounts have been restored and there really is nothing connected.
            guard GoogleCalendarService.shared.restorationFinished else { return }
            if !calendarColorHex.isEmpty { calendarColorHex = [:] }
            if !availableCalendars.isEmpty { availableCalendars = [] }
            return
        }
        // Connected but the list isn't loaded (it isn't saved, and loading it at launch can fail
        // or take a while): that's "not known yet". Wiping here is what turned every event grey
        // at launch until the list came back.
        guard !list.isEmpty else { return }
        if list.map(\.id) != availableCalendars.map(\.id) { availableCalendars = list }
        // Every calendar its own colour: Google's unless another already has it (`CalendarColorAssignment`).
        let loaded = CalendarColorAssignment.assign(
            list.map { .init(id: $0.id, googleHex: $0.colorHex, isPrimary: $0.isDefault,
                             account: $0.sourceTitle, title: $0.title) },
            chosen: settings.calendarColorChoices)
        // A complete list replaces the colours (a removed calendar loses its colour); a partial one
        // — an account whose list couldn't be read — updates what it has and keeps the rest.
        let map = GoogleCalendarService.shared.calendarListIsComplete
            ? loaded
            : calendarColorHex.merging(loaded) { _, fresh in fresh }
        guard map != calendarColorHex else { return }
        if map.count < calendarColorHex.count {
            PlaybackDiagnostics.shared.log("calendar colours",
                                           "\(calendarColorHex.count) → \(map.count) after a complete calendar list")
        }
        calendarColorHex = map
    }

    /// Carry calendar exclusions made against Apple Calendar over to the same calendars in
    /// Google, for both lists: calendars that don't count as meetings, and calendars that don't
    /// receive busy blocks.
    ///
    /// Additive only — it can exclude more, never less. An exclusion that stops applying is how
    /// busy blocks end up on a shared calendar and notify everyone on it, so every source of an
    /// exclusion is honoured: Apple Calendar ids this device can still name, the names write-back
    /// recorded, and the names another device synced. What matches nothing yet (its account is not
    /// connected) is kept and tried again whenever the calendar list changes.
    private func migrateCalendarExclusionsToGoogle(_ list: [CalendarSourceInfo]) {
        // A probe launch reads; it must not rewrite synced settings as a side effect.
        guard !CalendarWriteBack.isDiagnosticLaunch else { return }
        let candidates = GoogleCalendarService.shared.matchableCalendars
        guard !candidates.isEmpty else { return }
        typealias Identity = WriteBackDestinations.Identity

        // Apple Calendar ids left in either list can no longer be named — Banana no longer reads
        // Apple Calendar — so they stay, inert; the name-based sources below do the work.
        func migrate(_ ids: Set<String>, remote: Set<CalendarIdentity>?) -> Set<String> {
            var result = ids
            let remoteIdentities = Set((remote ?? []).map {
                Identity(sourceTitle: $0.sourceTitle, calendarTitle: $0.calendarTitle)
            })
            result.formUnion(WriteBackDestinations.excluded(candidates, ids: [], identities: remoteIdentities))
            return result
        }

        let read = migrate(settings.excludedCalendarIDs, remote: remoteExcludedCalendars)
        var write = migrate(settings.writeBackExcludedCalendarIDs, remote: remoteWriteBackExcludedCalendars)
        write.formUnion(CalendarWriteBack.shared.consumeLegacyExclusionIdentities(
            GoogleCalendarService.shared.writeBackCandidates))
        // Remote identities are applied once; afterwards the ids are the selection and the person's
        // own toggles decide.
        remoteExcludedCalendars = nil
        remoteWriteBackExcludedCalendars = nil
        guard read != settings.excludedCalendarIDs || write != settings.writeBackExcludedCalendarIDs else { return }
        Log.sync.notice("calendar exclusions carried to Google: read \(self.settings.excludedCalendarIDs.count, privacy: .public)→\(read.count, privacy: .public), write-back \(self.settings.writeBackExcludedCalendarIDs.count, privacy: .public)→\(write.count, privacy: .public)")
        var updated = settings
        updated.excludedCalendarIDs = read
        updated.writeBackExcludedCalendarIDs = write
        settings = updated
    }

    // MARK: - Permissions

    /// A Google account can be connected or disconnected while Banana is running (or on another
    /// device). Keep the observable flag in sync so views never turn a missing connection into a
    /// fake empty agenda.
    func refreshCalendarAuthorization() async {
        await GoogleCalendarService.shared.restoreIfNeeded()
        calendarAuthorized = GoogleCalendarService.shared.isConnected
        refreshCalendarColors()
        CalendarWriteBack.shared.refreshCalendars()
        applyRemoteCalendarExclusionsIfPossible()
        if calendarAuthorized {
            await refreshAgenda()
        } else {
            todayMeetings = []
            tomorrowMeetings = []
        }
        OccurrenceStore.shared.calendarSourceDidChange()
    }

    /// Cheap re-read for the foreground path: the connection check is local, but the
    /// work that follows a *change* (agenda refresh, write-back reconcile) is not. Only pay it
    /// when the answer actually moved.
    ///
    /// This exists because `calendarAuthorized` is a cached copy of a value that other parts of
    /// the app can change behind its back. Onboarding grants calendar through OnboardingStore's
    /// own EKEventStore, which never touched this flag — so a freshly-granted permission left
    /// Today insisting "Calendar isn't connected" until you happened to open Settings.
    func syncCalendarAuthorization() async {
        await GoogleCalendarService.shared.restoreIfNeeded()
        let current = GoogleCalendarService.shared.isConnected
        guard current != calendarAuthorized else { return }
        await refreshCalendarAuthorization()
    }

    /// "Connect Calendar": the calendar is Google, so this is Google's sign-in.
    func requestCalendarAccess() async {
        if !GoogleCalendarService.shared.isConnected {
            await GoogleCalendarService.shared.connect()
        }
        calendarAuthorized = GoogleCalendarService.shared.isConnected
        refreshCalendarColors()
        CalendarWriteBack.shared.refreshCalendars()
        if calendarAuthorized {
            await refreshAgenda()
            await apply()
        } else {
            todayMeetings = []
            tomorrowMeetings = []
        }
    }

    // MARK: - Orchestration

    private func scheduleApply() {
        settingsApplyTask?.cancel()
        settingsApplyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.apply()
        }
    }

    /// Recompute + reschedule for the current settings. Idempotent.
    func apply() async {
        guard let alarms else { return }
        if settings.enabled {
            _ = await NotificationService.requestAuthorization()
            alarms.suspendManual()
            await recompute()
        } else {
            alarms.cancelSmartWakes()
            await NotificationService.scheduleBedtimes(WakePlan(anchorMinutes: nil, days: [], explanation: ""),
                                                       settings: {
                                                           var s = settings; s.bedtimeRemindersEnabled = false; return s
                                                       }())
            await alarms.resumeManual()
            plan = nil
        }
    }

    /// When the plan was last fully recomputed — the foreground path is staleness-guarded, so
    /// rapid app switches don't each pay agenda fetches + travel ETAs + notification passes.
    private var lastRecompute: Date?
    private var recomputeTask: Task<Void, Never>?
    private var recomputeAgain = false

    /// Foreground/refresh entry point: skip when fresh. A pending EventKit change bypasses the age
    /// guard, including one whose debounce settled while Banana was backgrounded.
    func recomputeIfStale(maxAge: TimeInterval = 60) async {
        if let recomputeTask {
            await recomputeTask.value
            if calendarChangePending { await processPendingCalendarChange() }
            return
        }
        if calendarChangePending {
            await processPendingCalendarChange()
            return
        }
        if let last = lastRecompute, Date().timeIntervalSince(last) < maxAge { return }
        await recompute()
    }

    /// Refresh the plan and (re)schedule alarms + notifications.
    func recompute() async {
        recomputeAgain = true
        if let recomputeTask {
            await recomputeTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainRecomputeRequests()
        }
        recomputeTask = task
        await task.value
    }

    private func drainRecomputeRequests() async {
        while recomputeAgain {
            recomputeAgain = false
            await performRecompute()
        }
        recomputeTask = nil
    }

    /// From the background calendar refresh: the wake plan alone, recomputed from the calendar as
    /// it is now, so the pass that follows can move the alarm (`WakeFollow`). No notifications,
    /// commute legs or flights: those are the foreground's.
    func refreshWakePlanInBackground() async {
        await performRecompute(wakePlanOnly: true)
    }

    private func performRecompute(wakePlanOnly: Bool = false) async {
        guard settings.enabled else { return }
        await GoogleCalendarService.shared.restoreIfNeeded()
        let authorized = GoogleCalendarService.shared.isConnected
        if calendarAuthorized != authorized { calendarAuthorized = authorized }
        guard calendarAuthorized else { return }
        let sp = Signpost.begin("smartRecompute")
        var completedFullPass = false
        defer {
            Signpost.end(sp)
            if completedFullPass { lastRecompute = Date() }
        }
        await refreshAgenda()
        let excluded = settings.excludedCalendarIDs
        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: Date())
        let windowEnd = cal.date(byAdding: .day, value: 8, to: windowStart) ?? windowStart
        let direct = await GoogleCalendarService.shared.meetings(
            from: windowStart,
            to: windowEnd,
            excluding: excluded
        )
        #if os(iOS)
        guard wakePlanOnly || AppVisibility.shared.isActive else { return }
        #endif
        let meetings = CalendarAgenda.firstMeetings(direct, now: Date(), calendar: cal)
        let times = meetings.mapValues { $0.start }

        // Travel-adjusted wake: subtract the ETA to arrive at each meeting on time.
        var travelMinutes: [Date: Int] = [:]
        if settings.accountForTravel, let home = homeCoordinate {
            for (day, info) in meetings where info.hasPhysicalLocation {
                #if os(iOS)
                guard wakePlanOnly || AppVisibility.shared.isActive else { return }
                #endif
                if let seconds = await travel.travelTime(to: info, from: home, settings: settings) {
                    travelMinutes[day] = Int((seconds / 60).rounded())
                }
            }
        }

        let adj = healthAdjustment()
        let localPlan = SmartScheduler.plan(settings: settings, firstMeetings: times,
                                            travelMinutes: travelMinutes,
                                            healthWakeShift: adj.wakeShift,
                                            healthBedtimeEarlier: adj.bedtimeEarlier,
                                            days: 8)   // today + a full week ahead
        // The phone computes the plan that rings and publishes it. An iPad or a Mac can calculate
        // a useful offline fallback from the calendar, but not the phone's HealthKit adjustment:
        // while the phone-authored plan covers today, render that exact plan so every device
        // shows the schedule that will actually ring — and never publishes its own over it.
        let computed: WakePlan
        if DeviceRole.current.isHub {
            computed = localPlan
            publishWakePlanIfChanged(computed)
        } else {
            computed = usableRemoteWakePlan() ?? localPlan
        }
        // Only a plan whose WAKE TIMES moved needs the occurrence timeline re-derived (that's
        // what the earliestMeeting cues consume). Unconditionally requesting one meant every
        // foreground ran TWO full recomputes — Today's staleness refresh plus this echo — for a
        // plan that almost never changed in between.
        let wakesChanged = computed.days.map(\.wake) != (plan?.days.map(\.wake) ?? [])
        if plan != computed { plan = computed }
        // The background refresh runs its own pass over the timeline straight after this.
        guard !wakePlanOnly else { return }
        if wakesChanged {
            OccurrenceStore.shared.requestRecompute(reason: "plan wake times changed")
        }
        await NotificationService.scheduleBedtimes(computed, settings: settings)
        await NotificationService.scheduleLeaveByAlerts(
            meetings: meetings.filter { EventAlertPlan.allows(calendarID: $0.value.calendarID,
                alsoOn: $0.value.alsoOnCalendarIDs, muted: settings.mutedCalendarIDs) },
            travelMinutes: travelMinutes, mode: settings.transitMode,
            enabled: settings.accountForTravel && settings.hasHome && settings.leaveByAlerts && !settings.commuteAlerts)

        #if os(iOS)
        guard AppVisibility.shared.isActive else { return }
        #endif
        await scheduleCommute()
        #if os(iOS)
        guard AppVisibility.shared.isActive else { return }
        #endif
        await computeFlightLegs()
        completedFullPass = true
    }

    /// Ground legs that bracket each upcoming flight — the part regular commute logic misses because
    /// a flight's location is only the DEPARTURE airport and the hotel is an all-day event. Produces
    /// home → departure airport (leave-by from an explicitly reported boarding time when the event
    /// contains one, otherwise from the scheduled departure) and arrival airport → hotel.
    /// Surfaced on the flight row (see TodayView.flightLeg).
    struct FlightLeg: Equatable {
        let flightStart: Date
        let destCode: String
        let arriveAt: Date        // landing instant — for "88° on landing"
        let boardingAt: Date?     // nil means the source never supplied it; never guessed
        let leaveBy: Date?
        let toAirportMin: Int?
        let bufferMin: Int
        let international: Bool
        let toStayMin: Int?
        let stayName: String?
    }

    /// Turn calculated ground travel into real busy occurrences. They flow through the existing
    /// cross-calendar reconciler, which writes one provider-synced event per uncovered calendar,
    /// adopts the same marker after reinstall/on another device, and reuses Reclaim-style holds.
    func calendarTravelOccurrences(
        meetings: [MeetingInfo],
        travelEvents: [TravelEvent],
        fallingBackTo syncedBlocks: [CalendarSyncedTravelBlock] = []
    ) async -> [Occurrence] {
        guard settings.blockTravelTime else { return [] }

        let regularLegs = await computedCommuteLegs(
            for: meetings,
            travelEvents: travelEvents
        )
        let flights = await resolvedFlightLegs(from: travelEvents)
        // Was clamped to today, which silently discarded the rest of the horizon the moment
        // write-back was on — the same starvation as scheduleCommute, from the other direction.
        // Both writers now publish the full set; only notification scheduling filters to today.
        if commuteLegs != regularLegs { commuteLegs = regularLegs }
        if flightLegs != flights { flightLegs = flights }
        // A place that's only a guess will be asked about on Today; have Apple Intelligence read
        // the event now, so the picker's suggestions are ready when it is.
        for leg in regularLegs where leg.detail?.needsConfirming == true {
            if let query = leg.detail?.query, settings.savedPlaces.place(for: query) == nil {
                PlaceHintModel.prefetch(title: leg.title, location: query)
            }
        }

        var blocks = regularLegs.map { leg in
            travelOccurrence(
                kind: "meeting",
                identity: "\(leg.title)|\(leg.start.timeIntervalSinceReferenceDate)",
                title: "Travel to \(leg.title)",
                start: leg.leaveBy,
                end: leg.start,
                icon: (leg.detail?.mode ?? settings.transitMode).systemImage,
                detail: leg.detail
            )
        }
        // A commute is not complete at the meeting door. Reserve the real trip home after the
        // final in-person stop of each day as well, so the calendar does not offer that time to
        // another meeting or task. A resolved outbound leg supplies a bounded fallback if the
        // reverse MapKit request fails, so a transient network error cannot reopen the calendar.
        let returnHome = await returnHomeTravelOccurrences(
            from: meetings,
            outboundLegs: regularLegs,
            syncedBlocks: syncedBlocks
        )
        blocks.append(contentsOf: returnHome.blocks)
        for leg in flights {
            if let leaveBy = leg.leaveBy, leaveBy < leg.flightStart {
                blocks.append(travelOccurrence(
                    kind: "airport",
                    identity: "\(leg.destCode)|\(leg.flightStart.timeIntervalSinceReferenceDate)",
                    title: "Travel to \(leg.destCode) flight",
                    start: roundedDown(leaveBy, interval: 5 * 60),
                    end: leg.flightStart,
                    icon: "airplane.departure"
                ))
            }
            if let minutes = leg.toStayMin, minutes > 0 {
                let blockedMinutes = max(5, Int(ceil(Double(minutes) / 5)) * 5)
                blocks.append(travelOccurrence(
                    kind: "arrival",
                    identity: "\(leg.destCode)|\(leg.flightStart.timeIntervalSinceReferenceDate)",
                    title: "Travel to \(leg.stayName ?? "destination")",
                    start: leg.arriveAt,
                    end: leg.arriveAt.addingTimeInterval(Double(blockedMinutes * 60)),
                    icon: "airplane.arrival"
                ))
            }
        }

        // Routing is a network service. If it is temporarily unavailable, retain a synced block
        // whose boundary still matches a current meeting/flight rather than deleting protection
        // during an offline refresh. Deleted or moved source events no longer match and are pruned.
        let meetingStarts = meetings.map(\.start)
        let meetingEnds = meetings.compactMap(\.end)
        // Parse each travel event once and reuse it for both start/end lists, instead of the two
        // separate compactMaps re-parsing the same event back-to-back.
        let flightEvents = travelEvents.filter {
            FlightParser.parse(title: $0.title, location: $0.location, notes: $0.notes) != nil
        }
        let flightStarts = flightEvents.map(\.start)
        let flightEnds = flightEvents.map(\.end)
        let generatedIDs = Set(blocks.map(\.id))
        for block in syncedBlocks where !generatedIDs.contains(block.appItemID) {
            // A trip home we have just decided against must not be kept alive by the retention
            // rule below. It starts at a real meeting's end, so it looks anchored forever — which
            // is how a block written before the gap was checked survived every later refresh.
            if returnHome.declinedDepartures.contains(where: {
                abs($0.timeIntervalSince(block.start)) < 60
            }) {
                Log.travel.debug("[travel] pruned stale block \(block.title, privacy: .public) at \(block.start.timeIntervalSince1970, privacy: .public)")
                continue
            }
            let stillAnchored = (meetingStarts + flightStarts).contains {
                abs($0.timeIntervalSince(block.end)) < 60
            } || flightEnds.contains {
                abs($0.timeIntervalSince(block.start)) < 60
            } || meetingEnds.contains {
                abs($0.timeIntervalSince(block.start)) < 60
            }
            guard stillAnchored else { continue }
            // Retention exists for ONE case: routing was unavailable this pass, so a block we
            // cannot currently recompute is kept rather than dropping protection during a network
            // blip. It must not keep a second copy alive when routing DID succeed.
            //
            // A block's identity is its kind plus the meeting and departure it was cut from, so it
            // changes whenever any of those change — a meeting moved by a minute, an identity
            // scheme revised. The old block is then anchored to the same meeting boundary as the
            // freshly generated one, passes `stillAnchored` forever, and is published as desired
            // alongside it. The calendar ends up with two overlapping travel blocks, and deleting
            // the stale one by hand does nothing because write-back immediately writes it back.
            let supersededByFreshBlock = blocks.contains { fresh in
                abs(fresh.start.timeIntervalSince(block.start)) < 60
                    || abs(fresh.resolvedEnd.timeIntervalSince(block.end)) < 60
            }
            guard !supersededByFreshBlock else {
                Log.travel.debug("[travel] dropped superseded block \(block.title, privacy: .public) at \(block.start.timeIntervalSince1970, privacy: .public)")
                continue
            }
            Log.travel.debug("[travel] retained block \(block.title, privacy: .public) at \(block.start.timeIntervalSince1970, privacy: .public)")
            blocks.append(Occurrence(
                id: block.appItemID,
                seriesID: nil, slotID: nil,
                source: .derived, behavior: .block,
                schedule: OccurrenceSchedule(mode: .derived, moveable: false),
                writePolicy: .busy,
                title: block.title, icon: "car.fill", tint: .orange,
                start: block.start, end: block.end, hasScheduledTime: true
            ))
        }
        return blocks.filter { $0.resolvedEnd > $0.start }.sorted { $0.start < $1.start }
    }

    private func computedCommuteLegs(
        for meetings: [MeetingInfo],
        travelEvents: [TravelEvent]
    ) async -> [NotificationService.CommuteLeg] {
        let now = Date()
        let cal = Calendar.current
        let lodging: [(range: ClosedRange<Date>, coordinate: CLLocationCoordinate2D)] = travelEvents.compactMap {
            guard ($0.isAllDay || $0.end.timeIntervalSince($0.start) > 20 * 3_600),
                  let coordinate = $0.coordinate else { return nil }
            return ($0.start...max($0.start, $0.end), coordinate)
        }
        let arrivals: [(date: Date, coordinate: CLLocationCoordinate2D)] = travelEvents.compactMap {
            guard let flight = FlightParser.parse(title: $0.title, location: $0.location, notes: $0.notes)
            else { return nil }
            let airport = flight.destination.coordinate
            let coordinate: CLLocationCoordinate2D
            if let home = homeCoordinate, near(airport, home) {
                coordinate = home
            } else {
                coordinate = lodging.first { near(airport, $0.coordinate) }?.coordinate ?? airport
            }
            return ($0.end, coordinate)
        }.sorted { $0.date < $1.date }

        let grouped = Dictionary(grouping: meetings.filter { $0.start > now }) {
            cal.startOfDay(for: $0.start)
        }
        var legs: [NotificationService.CommuteLeg] = []
        for day in grouped.keys.sorted() {
            let dayMeetings = (grouped[day] ?? []).sorted { $0.start < $1.start }
            var origin = arrivals.last(where: { $0.date <= day })?.coordinate
                ?? lodging.first(where: { $0.range.contains(day) })?.coordinate
                ?? homeCoordinate
                ?? workCoordinate
            var previousPhysicalEnd: Date?
            var previousSavedMode: TransitMode?

            for meeting in dayMeetings {
                if let arrived = arrivals.last(where: { $0.date <= meeting.start && $0.date >= day }) {
                    origin = arrived.coordinate
                }
                // Flights get a dedicated leave-by block that includes the airport buffer; a
                // normal point-to-point ETA would incorrectly leave that waiting time bookable.
                if FlightParser.parse(title: meeting.title, location: meeting.address, notes: nil) != nil {
                    continue
                }
                guard meeting.hasPhysicalLocation else { continue }
                guard let previousOrigin = origin else {
                    // Even without Home, a structured first destination can anchor the next leg.
                    origin = meeting.coordinate
                    continue
                }
                // A long gap is not time spent waiting at the prior appointment. If there is
                // enough time to get home, actually be home, then leave for the next place,
                // the next outbound leg must use Home as its origin.
                // Same saved mode as `returnHomeTravelOccurrences` passes, so the two agree on
                // whether this gap is a trip home.
                if let previousPhysicalEnd,
                   await shouldReturnHome(
                    from: previousOrigin, departingAt: previousPhysicalEnd, before: meeting,
                    savedMode: previousSavedMode) == true {
                    origin = homeCoordinate
                }
                guard let routeOrigin = origin else { continue }
                guard let estimate = await travel.estimate(
                    to: meeting,
                    from: routeOrigin,
                    settings: settings
                ) else {
                    origin = meeting.coordinate ?? origin
                    continue
                }
                // Round upward to five minutes: defend enough time and avoid calendar/network churn
                // when traffic changes an ETA by a few seconds between devices.
                guard let seconds = TravelBlockPolicy.blockDuration(
                    routeSeconds: estimate.duration,
                    fallbackMinutes: nil
                ) else { continue }
                // The minutes shown are the minutes reserved, so "Leave by 2:35 · 10 min" adds up.
                var detail = estimate.detail
                detail.minutes = Int(seconds / 60)
                legs.append(.init(
                    title: meeting.title,
                    start: meeting.start,
                    leaveBy: meeting.start.addingTimeInterval(-seconds),
                    travelMinutes: Int(seconds / 60),
                    detail: detail
                ))
                origin = estimate.destination
                previousPhysicalEnd = meeting.end ?? meeting.start
                previousSavedMode = settings.savedPlaces.place(for: meeting.address)?.mode
            }
        }
        return legs
    }

    /// Do not pretend a multi-hour gap is spent at the prior address. We reserve a return home
    /// only when there is a meaningful period at home after both real routes; short gaps retain
    /// the direct place-to-place route instead.
    private static var minimumHomeDwell: TimeInterval { TravelBlockPolicy.minimumHomeDwell }
    private func shouldReturnHome(
        from origin: CLLocationCoordinate2D, departingAt: Date, before next: MeetingInfo,
        savedMode: TransitMode? = nil
    ) async -> Bool? {
        guard let home = homeCoordinate, next.hasPhysicalLocation else { return nil }
        let mode = homewardMode(from: origin, savedMode: savedMode)
        guard let homeward = await travel.groundTime(
                from: origin, to: home, arriveBy: nil, departAt: departingAt, mode: mode),
              let outbound = await travel.estimate(
                to: next, from: home, settings: settings)?.duration
        else { return nil }
        return next.start.timeIntervalSince(departingAt)
            >= homeward + outbound + Self.minimumHomeDwell
    }

    /// One actual return-home block after the day's final physical meeting. Address-only events
    /// use the same cached geocoder as outbound commutes. Prefer a fresh homeward route; if that
    /// request fails, reuse the matching outbound duration rather than dropping known protection.
    /// - Returns: the blocks to reserve, plus the departure times where we evaluated a trip home
    ///   and decided against one. The caller needs the second list to prune a block written by an
    ///   earlier run: a stale "Travel home" still sitting on the calendar is anchored to a real
    ///   meeting end, so the retention rule would otherwise resurrect it forever.
    private func returnHomeTravelOccurrences(
        from meetings: [MeetingInfo],
        outboundLegs: [NotificationService.CommuteLeg],
        syncedBlocks: [CalendarSyncedTravelBlock]
    ) async -> (blocks: [Occurrence], declinedDepartures: [Date]) {
        guard let home = homeCoordinate else { return ([], []) }
        let calendar = Calendar.current
        let now = Date()
        var blocks: [Occurrence] = []
        var declined: [Date] = []
        let grouped = Dictionary(grouping: meetings.filter {
            $0.hasPhysicalLocation && ($0.end ?? $0.start) > now
        }, by: { calendar.startOfDay(for: $0.start) })
        for dayMeetings in grouped.values {
            let ordered = dayMeetings.sorted { $0.start < $1.start }
            for (index, meeting) in ordered.enumerated() {
                let next = ordered.dropFirst(index + 1).first
                let departure = meeting.end ?? meeting.start
                // The same place the trip there resolved to (a confirmed place wins), so both
                // legs agree on where you are.
                let place = await travel.resolvePlace(for: meeting, near: home, saved: settings.savedPlaces)
                let origin = place?.coordinate
                let outboundMinutes = outboundLegs.first {
                    $0.title == meeting.title
                        && abs($0.start.timeIntervalSince(meeting.start)) < 60
                }?.travelMinutes ?? syncedBlocks.first {
                    $0.title != "Travel home"
                        && $0.start < $0.end
                        && abs($0.end.timeIntervalSince(meeting.start)) < 60
                }.map {
                    max(1, Int(ceil($0.end.timeIntervalSince($0.start) / 60)))
                }
                let shouldBlock: Bool
                var routedForLog: Bool?
                if let next {
                    let routedDecision: Bool?
                    if let origin {
                        routedDecision = await shouldReturnHome(
                            from: origin, departingAt: departure, before: next,
                            savedMode: place?.savedMode)
                    } else {
                        routedDecision = nil
                    }
                    routedForLog = routedDecision
                    shouldBlock = TravelBlockPolicy.shouldReserveReturnHome(
                        routedDecision: routedDecision,
                        fallbackMinutes: outboundMinutes,
                        gapToNext: next.start.timeIntervalSince(departure)
                    )
                } else {
                    shouldBlock = true   // the day's final physical place always ends at home
                }
                Log.travel.debug("[travel] \(meeting.title, privacy: .public) end=\(departure.timeIntervalSince1970, privacy: .public) next=\(next?.title ?? "none", privacy: .public) gap=\(next.map { $0.start.timeIntervalSince(departure) } ?? -1, privacy: .public) routed=\(routedForLog == nil ? "nil" : String(describing: routedForLog!), privacy: .public) fallback=\(outboundMinutes ?? -1, privacy: .public) reserve=\(shouldBlock, privacy: .public)")
                guard shouldBlock else {
                    // Only a decision made WITH a following meeting is confident enough to prune
                    // an existing block. With no next meeting we always reserve, so this is only
                    // reached when the gap was genuinely evaluated.
                    if next != nil { declined.append(departure) }
                    continue
                }
                // Timed from when you leave: the evening train home is not the morning one.
                let mode = origin.map { homewardMode(from: $0, savedMode: place?.savedMode) } ?? settings.transitMode
                let routedSeconds: TimeInterval?
                if let origin {
                    routedSeconds = await travel.groundTime(
                        from: origin, to: home, arriveBy: nil, departAt: departure, mode: mode)
                } else {
                    routedSeconds = nil
                }
                guard let interval = TravelBlockPolicy.returnHomeInterval(
                    departingAt: departure,
                    routeSeconds: routedSeconds,
                    fallbackMinutes: outboundMinutes
                )
                else { continue }
                let identity = "\(meeting.eventID ?? meeting.id)|\(departure.timeIntervalSinceReferenceDate)"
                let detail = TravelLegDetail(
                    mode: mode,
                    minutes: Int(interval.duration / 60),   // what's reserved, as the band shows
                    placeName: "Home", query: nil, confidence: .exact)
                blocks.append(travelOccurrence(
                    kind: "return-home", identity: identity, title: "Travel home",
                    start: interval.start, end: interval.end,
                    icon: mode.systemImage, detail: detail
                ))
            }
        }
        return (blocks, declined)
    }

    /// The mode for a trip home from `origin`: the place's saved mode, a walk if home is close,
    /// else the default — the same rule as the trip there.
    private func homewardMode(from origin: CLLocationCoordinate2D, savedMode: TransitMode?) -> TransitMode {
        let metres = homeCoordinate.map {
            CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
        }
        return TravelModePolicy.mode(savedMode: savedMode, distanceMeters: metres, settings: settings)
    }

    /// `title` and the id derived from `kind`/`identity` are what the calendar write-back keys
    /// on; `detail` is display only, so a better place or mode never renames or recreates an
    /// event on anyone's calendar.
    private func travelOccurrence(
        kind: String,
        identity: String,
        title: String,
        start: Date,
        end: Date,
        icon: String,
        detail: TravelLegDetail? = nil
    ) -> Occurrence {
        var occurrence = Occurrence(
            id: "travel-\(stableHash("\(kind)|\(identity)"))",
            seriesID: nil, slotID: nil,
            source: .derived, behavior: .block,
            schedule: OccurrenceSchedule(mode: .derived, moveable: false),
            writePolicy: .busy,
            title: title, icon: icon, tint: .orange,
            start: start, end: end, hasScheduledTime: true
        )
        occurrence.travel = detail
        return occurrence
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func roundedDown(_ date: Date, interval: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate:
            floor(date.timeIntervalSinceReferenceDate / interval) * interval)
    }

    private func near(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        AirportTable.haversineKm(a.latitude, a.longitude, b.latitude, b.longitude) < 100
    }

    private func computeFlightLegs() async {
        guard calendarAuthorized else {
            if !flightLegs.isEmpty { flightLegs = [] }
            return
        }
        let excluded = settings.excludedCalendarIDs
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) ?? Date()
        let end = cal.date(byAdding: .day, value: 8, to: cal.startOfDay(for: Date())) ?? Date()
        let events = await GoogleCalendarService.shared.windowFetch(
            from: start, to: end, excluding: excluded).window.travelEvents
        let resolved = await resolvedFlightLegs(from: events)
        if flightLegs != resolved { flightLegs = resolved }
    }

    private func resolvedFlightLegs(from events: [TravelEvent]) async -> [FlightLeg] {
        // Lodging spans (all-day / multi-day located events) — the arrival anchor.
        let lodging: [(range: ClosedRange<Date>, coord: CLLocationCoordinate2D, name: String)] = events.compactMap {
            guard $0.isAllDay || $0.end.timeIntervalSince($0.start) > 20 * 3600, let c = $0.coordinate else { return nil }
            return ($0.start...max($0.start, $0.end), c, Self.tidyStayName($0.title))
        }

        let home = homeCoordinate
        // Force DRIVING for airport ground legs: you drive/ride to an airport (luggage, timing), and
        // Apple has driving routes everywhere — transit ETAs are missing in many cities (Miami), which
        // is why those legs came back empty under a transit preference and fell to the estimate.
        let mode: TransitMode = .drive
        // "The same place" for anchoring a flight to home / a hotel — a metro radius.
        func near(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
            AirportTable.haversineKm(a.latitude, a.longitude, b.latitude, b.longitude) < 100
        }
        func stayNear(_ airport: CLLocationCoordinate2D) -> (coord: CLLocationCoordinate2D, name: String)? {
            lodging.first { near(airport, $0.coord) }.map { ($0.coord, $0.name) }
        }
        // Metro-scale ground time: MapKit routing, or a straight-line estimate when routing/transit
        // is unavailable (Apple has no transit ETAs for some cities — that's why the Miami legs came
        // back empty). Returns nil for a >150 km gap, meaning we mis-anchored the leg.
        func legMinutes(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, arriveBy: Date?) async -> (min: Int, sec: TimeInterval)? {
            let km = AirportTable.haversineKm(a.latitude, a.longitude, b.latitude, b.longitude)
            guard km < 150 else { return nil }
            if let sec = await travel.groundTime(from: a, to: b, arriveBy: arriveBy, mode: mode), sec < 6 * 3600 {
                return (Int((sec / 60).rounded()), sec)
            }
            // Offline last resort only (driving routes exist everywhere, so this rarely fires now):
            // a ~40 km/h city-driving estimate.
            let sec = km / 40.0 * 3600
            return (max(5, Int((sec / 60).rounded())), sec)
        }

        // Parse + dedup flights, preferring the copy with a departure coordinate / parsed origin
        // (the airline copy) over the Google-auto copy that has neither — otherwise we'd keep the
        // poorer copy and lose the departure leg, which needs the origin airport.
        var flights: [(e: TravelEvent, f: FlightParser.Result)] = []
        for e in events {
            guard let f = FlightParser.parse(title: e.title, location: e.location, notes: e.notes) else { continue }
            if let i = flights.firstIndex(where: { abs($0.e.start.timeIntervalSince(e.start)) < 120 && $0.f.destination.code == f.destination.code }) {
                let existingRich = flights[i].e.coordinate != nil || flights[i].f.origin != nil
                let newRich = e.coordinate != nil || f.origin != nil
                if newRich && !existingRich { flights[i] = (e, f) }
            } else {
                flights.append((e, f))
            }
        }

        var legs: [FlightLeg] = []
        for (e, f) in flights {
            let intl = f.origin.map { $0.country != f.destination.country } ?? false
            let boardingAt = FlightParser.boardingTime(title: e.title, location: e.location, notes: e.notes,
                                                       departure: e.start, timeZone: e.timeZone)
            // Once boarding is known, the policy is stated in boarding terms: reach the airport
            // 60 min before boarding domestically / 90 min internationally. When the source omits
            // boarding, preserve the conservative departure fallback (90 / 120 min). The fallback
            // remains visibly source-less because `boardingAt` stays nil.
            let buffer = boardingAt == nil ? (intl ? 120 : 90) : (intl ? 90 : 60)
            let airportArrivalTarget = (boardingAt ?? e.start).addingTimeInterval(-Double(buffer * 60))
            let depAirport = e.coordinate ?? f.origin?.coordinate   // the flight's own coord IS the origin airport
            let arrAirport = f.destination.coordinate

            // Depart FROM wherever you are before the flight: home if the departure airport is near
            // home (the outbound), otherwise the hotel near it (the return). NOT always home — that
            // computed a 32-hour Manhattan→Miami "drive" for the return leg.
            var leaveBy: Date?, toAirportMin: Int?
            if let depAirport {
                let origin: CLLocationCoordinate2D? = (home.map { near(depAirport, $0) } == true) ? home
                    : (stayNear(depAirport)?.coord ?? home)
                if let origin, let leg = await legMinutes(from: origin, to: depAirport,
                                                          arriveBy: airportArrivalTarget) {
                    toAirportMin = leg.min
                    leaveBy = airportArrivalTarget.addingTimeInterval(-leg.sec)
                }
            }

            // Arrive TO wherever you're going: home if the arrival airport is near home (the return),
            // otherwise the hotel near it (the outbound).
            var toStayMin: Int?, stayName: String?
            let dest: (coord: CLLocationCoordinate2D, name: String)? = (home.map { near(arrAirport, $0) } == true)
                ? home.map { ($0, "home") } : stayNear(arrAirport)
            if let dest, let leg = await legMinutes(from: arrAirport, to: dest.coord, arriveBy: e.end) {
                toStayMin = leg.min; stayName = dest.name   // bias traffic for the landing time, not "now"
            }

            legs.append(FlightLeg(flightStart: e.start, destCode: f.destination.code, arriveAt: e.end,
                                  boardingAt: boardingAt,
                                  leaveBy: leaveBy, toAirportMin: toAirportMin, bufferMin: buffer,
                                  international: intl, toStayMin: toStayMin, stayName: stayName))
        }
        return legs
    }

    private static func tidyStayName(_ title: String) -> String {
        var s = title
        for p in ["Stay: ", "Stay at ", "Stay - ", "Hotel: "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        return s
    }

    /// Multi-hop commute: a "leave now" nudge before every located meeting, travel-computed
    /// from the previous meeting's location (or home/work).
    ///
    /// Computed across `commuteHorizonDays` so Week and Tomorrow can show a leave-by; only
    /// TODAY's legs are turned into notifications. Those are two different jobs that shared one
    /// today-only input, and the display side lost. Widening is affordable because
    /// TravelService caches both geocodes and routes (keyed by origin→destination→arrival
    /// quarter-hour, 1h TTL), so a recompute re-walks the week without re-hitting the network.
    private static let commuteHorizonDays = 8
    private func scheduleCommute() async {
        guard settings.commuteAlerts || settings.blockTravelTime else {
            if !commuteLegs.isEmpty { commuteLegs = [] }
            await NotificationService.scheduleCommuteAlerts([], bufferMinutes: 0, mode: settings.transitMode, enabled: false)
            return
        }
        let excluded = settings.excludedCalendarIDs
        let horizonStart = Calendar.current.startOfDay(for: Date())
        let horizonEnd = Calendar.current.date(
            byAdding: .day, value: Self.commuteHorizonDays, to: horizonStart) ?? horizonStart
        let now = Date()
        let meetings = await GoogleCalendarService.shared.meetings(
            from: now, to: horizonEnd, excluding: excluded
        ).filter { $0.start >= now && $0.hasPhysicalLocation }
        var legs = await computedCommuteLegs(for: meetings, travelEvents: [])

        // "Before you're home" = the end of the last located thing TODAY, plus the ride back.
        // Every one of today's legs shares that one horizon on purpose: the coat decision is made
        // once, on the way out of the door, so a 9am nudge has to know about 5pm rain. A video
        // call doesn't keep you out in it, so only located meetings count.
        //
        // Scoped to today deliberately. `rainOutlook` reads the current-location hourly forecast,
        // which only covers today — over the full horizon the last end would be next week and
        // every future leg would get today's rain stapled to it.
        let cal = Calendar.current
        let todayEnds = meetings
            .filter { cal.isDateInToday($0.start) && $0.hasPhysicalLocation }
            .compactMap { $0.end ?? $0.start }
        if let lastEnd = todayEnds.max() {
            let todayLegs = legs.filter { cal.isDateInToday($0.start) }
            let rideHome = TimeInterval((todayLegs.last?.travelMinutes ?? 0) * 60)
            let homeBy = lastEnd.addingTimeInterval(rideHome)
            legs = legs.map { leg in
                guard cal.isDateInToday(leg.start), homeBy > leg.leaveBy else { return leg }
                var leg = leg
                leg.rain = WeatherStore.shared.rainOutlook(from: leg.leaveBy, to: homeBy)
                return leg
            }
        }

        // The UI gets the whole horizon; notifications stay today-only. Scheduling leave-now
        // alerts a week out would be noise, and the two consumers wanting different windows is
        // exactly why the display side was starved in the first place.
        if commuteLegs != legs { commuteLegs = legs }
        await NotificationService.scheduleCommuteAlerts(
            legs.filter { leg in
                cal.isDateInToday(leg.start) && meetings.contains { meeting in
                    meeting.start == leg.start && meeting.title == leg.title
                        && EventAlertPlan.allows(calendarID: meeting.calendarID,
                                                 alsoOn: meeting.alsoOnCalendarIDs,
                                                 muted: settings.mutedCalendarIDs)
                }
            },
            bufferMinutes: settings.commuteBufferMinutes,
            mode: settings.transitMode,
            enabled: settings.commuteAlerts)
    }

    var workCoordinate: CLLocationCoordinate2D? {
        guard let lat = settings.workLatitude, let lon = settings.workLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Health-adaptive wake

    /// Trailing sleep debt + recovery → how much to sleep in on free days and how
    /// much earlier to go to bed. Trailing means (7-day) keep it stable day-to-day.
    private func healthAdjustment() -> (wakeShift: Int, bedtimeEarlier: Int) {
        guard settings.healthAdaptive, let health else {
            if healthNote != nil { healthNote = nil }
            return (0, 0)
        }

        let sleep = health.trends.sleepHours.map(\.value)
        guard sleep.count >= 3 else {
            if healthNote != nil { healthNote = nil }
            return (0, 0)
        }

        let recent = Array(sleep.suffix(7))
        let avgSleep = recent.reduce(0, +) / Double(recent.count)
        let targetH = Double(settings.sleepTargetMinutes) / 60
        let deficitH = max(0, targetH - avgSleep)              // hours short per night
        let recovery = recoveryPenalty()                       // 0...1

        var wakeShift = Int((deficitH * 30).rounded()) + Int((recovery * 15).rounded())
        wakeShift = min(45, wakeShift)
        let bedtimeEarlier = min(30, Int((deficitH * 20).rounded()))

        if wakeShift > 0 || bedtimeEarlier > 0 {
            var parts: [String] = []
            if deficitH >= 0.1 { parts.append(String(format: "%.1fh sleep debt", deficitH)) }
            if recovery > 0.15 { parts.append("low recovery") }
            let note = "+\(wakeShift)m on free days · bed \(bedtimeEarlier)m earlier"
                + (parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))")
            if healthNote != note { healthNote = note }
        } else {
            let note = "Well rested — no change"
            if healthNote != note { healthNote = note }
        }
        return (wakeShift, bedtimeEarlier)
    }

    private func recoveryPenalty() -> Double {
        guard let health else { return 0 }
        func mean(_ a: ArraySlice<Double>) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        var penalty = 0.0, signals = 0

        // The last month is the baseline — the series holds two years now, for Trends.
        let hrv = health.trends.hrv.suffix(30).map(\.value)
        if hrv.count >= 5 {
            let base = mean(hrv[...]), recent = mean(hrv.suffix(3))
            if base > 0 { penalty += max(0, (base - recent) / base); signals += 1 }   // HRV down = worse
        }
        let rhr = health.trends.restingHR.suffix(30).map(\.value)
        if rhr.count >= 5 {
            let base = mean(rhr[...]), recent = mean(rhr.suffix(3))
            if base > 0 { penalty += max(0, (recent - base) / base); signals += 1 }   // resting HR up = worse
        }
        guard signals > 0 else { return 0 }
        return min(1, (penalty / Double(signals)) * 4)   // small % deviations matter for HRV/RHR
    }

    // MARK: - Home location

    var homeCoordinate: CLLocationCoordinate2D? {
        guard let lat = settings.homeLatitude, let lon = settings.homeLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func setHome(latitude: Double, longitude: Double, label: String) {
        var s = settings
        s.homeLatitude = latitude
        s.homeLongitude = longitude
        s.homeLabel = label
        settings = s   // single didSet → persist + recompute
    }
    func setWork(latitude: Double, longitude: Double, label: String) {
        var s = settings
        s.workLatitude = latitude
        s.workLongitude = longitude
        s.workLabel = label
        settings = s
    }

    @discardableResult
    func useCurrentLocation(for kind: LocationKind = .home) async -> Bool {
        guard let loc = await OneShotLocation().current() else {
            errorMessage = "Couldn't get your current location. Set it by searching instead."
            return false
        }
        var label = "Current location"
        if let request = MKReverseGeocodingRequest(location: loc),
           let items = try? await request.mapItems, let name = items.first?.name {
            label = name
        }
        switch kind {
        case .home: setHome(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, label: label)
        case .work: setWork(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, label: label)
        }
        return true
    }

    // MARK: - Calendar change observing

    /// The in-flight debounce for calendar-change handling, so a sync burst collapses to one pass.
    private var calendarChangeDebounce: Task<Void, Never>?
    /// Set as soon as a calendar change is detected (the Google change poll). If the app is backgrounded when the
    /// debounce settles, foreground recomputeIfStale consumes this even when its age guard is fresh.
    private var calendarChangePending = false

    /// Google has no change notification an app can receive, so Banana asks whether anything
    /// changed, one small request per calendar, and only then runs the full refresh. This is what
    /// Apple Calendar's `EKEventStoreChanged` used to provide, and why a Mac left open picks up a
    /// meeting added on the phone.
    ///
    /// How often is `CalendarRefreshPace`: every two minutes in front of someone, every five when
    /// not (a Mac behind other windows or with none; a phone playing in a pocket), every
    /// twenty-five when not and in Low Power Mode. A suspended phone asks nothing: there, iOS's
    /// background refresh is the only way in (`CalendarWriteBackRefresh`).
    private func observeCalendarChanges() {
        googleChangePoll?.cancel()
        googleChangePoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let inFront = Self.isInFront
                let wait = CalendarRefreshPace.remaining(
                    last: self.lastCalendarAsk, now: Date(), inFront: inFront,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                guard wait == 0, self.calendarAuthorized, inFront || Self.mayAskWhileAway else {
                    // A minute at most, so coming to the front, or Low Power Mode going off, is
                    // acted on within one.
                    try? await Task.sleep(for: .seconds(wait > 0 ? min(wait, 60) : 60))
                    continue
                }
                #if os(iOS)
                if !inFront {
                    // Playing, not in front: the same bounded look iOS's background refresh
                    // makes, which writes back without the foreground's cascade.
                    self.lastCalendarAsk = Date()   // also when a look is already under way
                    await CalendarWriteBackRefresh.look(reason: "while playing")
                    // And the data platform's pass and the move's next step (at most every five
                    // minutes): overnight, playing, this is what keeps the move going.
                    SpaceSyncLaunch.stepWhileAway()
                    continue
                }
                #endif
                guard let changed = await self.askWhetherCalendarsChanged() else { continue }
                if changed {
                    GoogleCalendarService.shared.invalidateEventCache()
                    self.calendarStoreChanged()
                }
            }
        }
    }

    /// The Banana service says a Google calendar changed (a push, `BananaService.isCalendarPush`):
    /// ask now rather than at the loop's next turn. Away from the front on a phone, the bounded
    /// look the background refresh makes; otherwise what the loop does.
    func calendarChangedElsewhere() async {
        #if os(iOS)
        if !Self.isInFront {
            await CalendarWriteBackRefresh.look(reason: "push")
            return
        }
        #endif
        guard calendarAuthorized else { return }
        let changed = await askWhetherCalendarsChanged()
        PlaybackDiagnostics.shared.log("☁️ push", changed == nil ? "calendars not read" : changed == true ? "changes found" : "nothing new here")
        if changed == true {
            GoogleCalendarService.shared.invalidateEventCache()
            // One change, already read: no burst to wait out.
            calendarStoreChanged(after: CalendarChangeEchoPolicy.pushDebounce)
        }
    }

    private var googleChangePoll: Task<Void, Never>?
    /// When Google was last asked, by the loop above or a look made away from the front.
    private var lastCalendarAsk = Date()
    /// The changes this device has already been told of, and acted on.
    private var seenCalendarNews = CalendarRefreshPace.Seen()

    /// Ask Google whether the included calendars changed since the last ask, other than by
    /// Banana's own writes. Each change is answered "yes" once. Nil when they couldn't be read.
    func askWhetherCalendarsChanged() async -> Bool? {
        lastCalendarAsk = Date()
        guard let serial = await GoogleCalendarService.shared.newsSerialAfterRefreshing(
            excluding: settings.excludedCalendarIDs) else { return nil }
        return seenCalendarNews.isNews(serial)
    }

    /// In front of someone: the scene on a phone or iPad, the active app on a Mac.
    private static var isInFront: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        AppVisibility.shared.isActive
        #endif
    }

    /// Away from the front, whether this process has any business asking. A Mac app runs behind
    /// other windows as a matter of course. A phone's runs there only while it plays (or for the
    /// few seconds of some other wake, which is no time to start a calendar pass).
    private static var mayAskWhileAway: Bool {
        #if os(macOS)
        true
        #else
        WakeCoordinator.shared.player.isPlaying
        #endif
    }

    /// Debounced, trailing-edge. A single CalDAV/Exchange sync emits several EKEventStoreChanged
    /// notifications back-to-back, and each un-debounced pass cost the full cascade: the windowed
    /// EventKit fetch, a Reminders fetch, travel ETAs (network) per located meeting, an AlarmKit
    /// re-arm, and three notification-center rebuilds. Five seconds of settling turns a burst
    /// into exactly one pass — nothing here is latency-sensitive at human timescales.
    ///
    /// A self-authored echo uses a longer delay, but still reaches this path: EventKit cannot tell
    /// us whether a real Calendar edit happened concurrently. A change received in background
    /// remains pending until the next foreground even when the ordinary staleness age is fresh.
    private func calendarStoreChanged(
        after delay: TimeInterval = CalendarChangeEchoPolicy.ordinaryDebounce
    ) {
        calendarChangePending = true
        calendarChangeDebounce?.cancel()
        calendarChangeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // Provider traffic can continue while an audio app is backgrounded. Defer this full
            // calendar/travel/write-back cascade until foreground; it must never lag the phone
            // while no calendar UI is visible.
            guard AppVisibility.shared.isActive else { return }
            await self?.processPendingCalendarChange()
        }
    }

    private func processPendingCalendarChange() async {
        guard calendarChangePending else { return }
        calendarChangePending = false
        // A calendar added, removed or recoloured shows up here. Without this the cached catalogue
        // keeps serving the old list and the grid keeps drawing the old colours.
        refreshCalendarColors()
        if settings.enabled {
            await recompute()
        } else {
            await refreshAgenda()
        }
        // The occurrence timeline draws meetings from its own materialization, not todayMeetings.
        // Always re-derive it after an external edit, including a change deferred from background.
        OccurrenceStore.shared.requestRecompute(reason: "calendar changed")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
        CloudBackup.shared.schedule()
        guard !applyingRemoteSettings else { return }
        settingsUpdatedAt = Date()
        defaults.set(settingsUpdatedAt, forKey: Self.settingsUpdatedAtKey)
        publishSettings()
    }

    // MARK: - Cross-device planner state

    /// Smart Schedule was previously local UserDefaults while the UI implied one shared planner:
    /// the phone moved Wake from its calendar/health plan and the Mac always drew the 6:30 fallback.
    /// KVS is the right scale here (one small settings blob + eight compact plan days), reacts to
    /// pushes, and costs no always-on server or polling.
    private func observeCloudSchedule() {
        cloudObserver = LegacyKVS.observeExternalChanges(tier: .personal) { [weak self] in
            self?.applyCloudSchedule()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cloud.synchronize()
            self.applyCloudSchedule()
            // Upgrade an existing phone install: it already has the user's real settings, whereas
            // a newly installed iPad or Mac may only have defaults — and often hasn't downloaded
            // the cloud value yet, so seeding there would publish defaults as the newest settings
            // and switch Smart Schedule off on the phone. Only the phone seeds, and only when no
            // cloud value exists.
            if DeviceRole.current.isHub, self.cloud.data(forKey: Self.cloudSettingsKey) == nil {
                self.settingsUpdatedAt = Date()
                self.defaults.set(self.settingsUpdatedAt, forKey: Self.settingsUpdatedAtKey)
                self.publishSettings()
            }
        }
    }

    /// Fast path for settings propagation: KVS is minutes-slow and needs iCloud entitlements
    /// (which local Mac builds lack), so every publish also goes out over the local peer
    /// channel, where devices on the same Wi-Fi converge in seconds.
    var onSettingsBroadcast: ((Data) -> Void)?

    /// Push the current snapshot into the peer layer so freshly connecting devices receive
    /// it even before the next settings change. Call once after wiring.
    func primePeerSettings() {
        guard let data = portableSettingsSnapshotData() else { return }

        // One-time schema enrichment for an already-synced setting: the timestamp stays the
        // same, but a device that can resolve its local write-back IDs adds portable identities.
        // Only replace the matching legacy KVS value, never a newer device's snapshot.
        if let portable = try? JSONDecoder().decode(CloudSettingsSnapshot.self, from: data),
           portable.writeBackExcludedCalendars != nil,
           let storedData = cloud.data(forKey: Self.cloudSettingsKey),
           let stored = try? JSONDecoder().decode(CloudSettingsSnapshot.self, from: storedData),
           stored.updatedAt == portable.updatedAt,
           stored.writeBackExcludedCalendars == nil {
            cloud.set(data, forKey: Self.cloudSettingsKey)
            cloud.synchronize()
        }
        onSettingsBroadcast?(data)
    }

    private func portableSettingsSnapshotData() -> Data? {
        var portable = settings
        // Apple Calendar ids are local to one device's event store and are stripped; Google
        // calendar ids are the same everywhere and travel as they are.
        portable.excludedCalendarIDs = settings.excludedCalendarIDs.filter(GoogleCalendarIDs.isCalendarInfoID)
        // `uniqueKeysWithValues` TRAPS on a duplicate key, and duplicates are reachable: the same
        // Google calendar appears in the calendar list of every account it is shared with, so
        // "Holidays in United States" arrives once per account with one id. Settling on the first
        // is correct — they are the same calendar — and a settings write must never be able to
        // kill the app over what a calendar list happened to contain.
        let calendars = Dictionary(availableCalendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let excluded = Set(settings.excludedCalendarIDs.compactMap { id -> CalendarIdentity? in
            guard let info = calendars[id] else { return nil }
            return CalendarIdentity(sourceTitle: info.sourceTitle, calendarTitle: info.title)
        })
        let writeBackExcluded = portableWriteBackExclusions()
        let snapshot = CloudSettingsSnapshot(
            updatedAt: settingsUpdatedAt,
            settings: portable,
            excludedCalendars: excluded,
            writeBackExcludedCalendars: writeBackExcluded,
            calendarIDsAreGoogle: true
        )
        return try? JSONEncoder().encode(snapshot)
    }

    /// `nil` means this device cannot safely translate every stored EventKit ID and must not
    /// overwrite another device's selection. An empty set is a real selection: all calendars on.
    private func portableWriteBackExclusions() -> Set<CalendarIdentity>? {
        // Same trap as above: write-back destinations now include Google calendars, and a shared
        // calendar reaches this list once per account it is shared with.
        let calendars = Dictionary(CalendarWriteBack.shared.writableCalendars.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var identities = Set<CalendarIdentity>()
        for id in settings.writeBackExcludedCalendarIDs {
            guard let info = calendars[id] else { return nil }
            identities.insert(CalendarIdentity(
                sourceTitle: info.sourceTitle,
                calendarTitle: info.title
            ))
        }
        return identities
    }

    private func publishSettings() {
        guard let data = portableSettingsSnapshotData() else { return }
        cloud.set(data, forKey: Self.cloudSettingsKey)
        cloud.synchronize()
        onSettingsBroadcast?(data)
        SyncReport.changed(Self.syncSettingsType, [Self.syncSettingsID])
        Log.sync.notice(
            "smart schedule settings published; enabled=\(self.settings.enabled) exclusions=\(self.settings.excludedCalendarIDs.count) writeBackExclusions=\(self.settings.writeBackExcludedCalendarIDs.count)"
        )
    }

    /// Adopt a settings snapshot that arrived over the local peer channel. Identical
    /// last-writer-wins rules as the KVS path. The sole equal-timestamp exception adds the
    /// portable write-back identities absent from legacy snapshots.
    func adoptSettingsSnapshot(_ data: Data) {
        guard let snapshot = try? JSONDecoder().decode(CloudSettingsSnapshot.self, from: data) else { return }
        adopt(snapshot, source: "peer")
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `SettingsAdapters`)

    static let syncSettingsType = "core.smartSettings"
    static let syncSettingsID = "smart-settings"
    static let syncWakePlanType = "core.wakePlan"
    static let syncWakePlanID = "wakePlan"

    /// Another account signed in on this device and the person said to clear it first
    /// (docs/design/DATA-PLATFORM.md §2): Smart Schedule's settings back to a new install's, and
    /// the phone's wake plan forgotten. This device only: nothing is reported or published, and
    /// iCloud's key-value store isn't written.
    func resetForAccountChange() {
        applyingRemoteSettings = true
        settings = SmartScheduleSettings()
        applyingRemoteSettings = false
        settingsUpdatedAt = .distantPast
        defaults.removeObject(forKey: Self.settingsUpdatedAtKey)
        remoteExcludedCalendars = nil
        remoteWriteBackExcludedCalendars = nil
        remoteWakePlan = nil
    }

    /// The settings as they go to other devices (the same snapshot iCloud and the peer channel get).
    var syncSettingsSnapshot: CloudSettingsSnapshot? {
        portableSettingsSnapshotData().flatMap { try? JSONDecoder().decode(CloudSettingsSnapshot.self, from: $0) }
    }

    var syncSettingsUpdatedAt: Date? { settingsUpdatedAt == .distantPast ? nil : settingsUpdatedAt }

    /// Another device's settings, by the same rule as iCloud's and the peer channel's (the later
    /// one stands). False when this device's are later.
    func adoptSyncedSettings(_ snapshot: CloudSettingsSnapshot) -> Bool {
        guard snapshot.updatedAt >= settingsUpdatedAt else { return false }
        adopt(snapshot, source: "space")
        return true
    }

    /// The wake plan the phone last published.
    var syncWakePlan: CloudWakePlanSnapshot? {
        cloud.data(forKey: Self.cloudWakePlanKey).flatMap { try? JSONDecoder().decode(CloudWakePlanSnapshot.self, from: $0) }
    }

    /// The phone's wake plan, on an iPad or the Mac: kept as iCloud's was, and used when it's for
    /// this time zone.
    func adoptSyncedWakePlan(_ snapshot: CloudWakePlanSnapshot) {
        guard !DeviceRole.current.isHub, let data = try? JSONEncoder().encode(snapshot) else { return }
        cloud.set(data, forKey: Self.cloudWakePlanKey)   // this device's own copy once it no longer writes iCloud
        adoptWakePlan(snapshot)
    }

    private func adoptWakePlan(_ snapshot: CloudWakePlanSnapshot) {
        guard snapshot.timeZoneIdentifier == TimeZone.current.identifier else { return }
        let changed = remoteWakePlan != snapshot.plan
        remoteWakePlan = snapshot.plan
        if settings.enabled, changed {
            plan = snapshot.plan
            Log.sync.notice("phone wake plan adopted; days=\(snapshot.plan.days.count)")
            OccurrenceStore.shared.requestRecompute(reason: "phone wake plan changed")
        }
    }

    /// The single adoption path for remote settings snapshots — KVS and peer channel both
    /// land here; only a newer snapshot or a safe schema enrichment is applied.
    private func adopt(_ snapshot: CloudSettingsSnapshot, source: String) {
        let isNewer = snapshot.updatedAt > settingsUpdatedAt
        let addsWriteBackIdentity = snapshot.updatedAt == settingsUpdatedAt
            && remoteWriteBackExcludedCalendars == nil
            && snapshot.writeBackExcludedCalendars != nil
        guard isNewer || addsWriteBackIdentity else { return }
        defer {
            if source != "space" {
                // Another device's settings by another road: a late arrival for the data platform.
                LegacyCloud.applyingFromCloud { SyncReport.changed(Self.syncSettingsType, [Self.syncSettingsID]) }
            }
        }

        // Portable Google IDs are authoritative. Legacy names can be stale after a cloud
        // toggle; migrating them again would silently turn a re-enabled calendar back off.
        remoteExcludedCalendars = snapshot.calendarIDsAreGoogle == true ? nil : snapshot.excludedCalendars
        if let identities = snapshot.writeBackExcludedCalendars {
            remoteWriteBackExcludedCalendars = identities
        }
        var adopted = snapshot.settings
        if snapshot.calendarIDsAreGoogle == true {
            // Google ids name the same calendar everywhere: the sender's selection is the
            // selection. Apple Calendar ids this device still holds (not yet carried over) stay.
            adopted.excludedCalendarIDs = snapshot.settings.excludedCalendarIDs
                .union(settings.excludedCalendarIDs.filter { !GoogleCalendarIDs.isCalendarInfoID($0) })
            adopted.writeBackExcludedCalendarIDs = snapshot.settings.writeBackExcludedCalendarIDs
                .union(settings.writeBackExcludedCalendarIDs.filter { !GoogleCalendarIDs.isCalendarInfoID($0) })
        } else {
            // A device still on Apple Calendar: its ids are its own and its names are resolved
            // here. Merged, never replaced — its view of the calendars is older and smaller than
            // Google's, and replacing would drop exclusions it has never heard of.
            adopted.excludedCalendarIDs = settings.excludedCalendarIDs
                .union(localCalendarIDs(for: snapshot.excludedCalendars) ?? [])
            adopted.writeBackExcludedCalendarIDs = settings.writeBackExcludedCalendarIDs
                .union(snapshot.writeBackExcludedCalendars.flatMap(localWriteBackCalendarIDs(for:)) ?? [])
            // It has no idea which shared calendars were turned on here.
            adopted.writeBackSharedCalendarIDs = settings.writeBackSharedCalendarIDs
        }
        settingsUpdatedAt = snapshot.updatedAt
        defaults.set(settingsUpdatedAt, forKey: Self.settingsUpdatedAtKey)
        applyingRemoteSettings = true
        settings = adopted
        applyingRemoteSettings = false
        Log.sync.notice(
            "smart schedule settings adopted via \(source, privacy: .public); enabled=\(adopted.enabled) exclusions=\(adopted.excludedCalendarIDs.count) writeBackExclusions=\(adopted.writeBackExcludedCalendarIDs.count)"
        )
    }

    private func applyCloudSchedule() {
        if let data = cloud.data(forKey: Self.cloudSettingsKey),
           let snapshot = try? JSONDecoder().decode(CloudSettingsSnapshot.self, from: data) {
            adopt(snapshot, source: "kvs")
        }

        // Everywhere but the phone, which is where this plan comes from.
        guard !DeviceRole.current.isHub,
              let data = cloud.data(forKey: Self.cloudWakePlanKey),
              let snapshot = try? JSONDecoder().decode(CloudWakePlanSnapshot.self, from: data)
        else { return }
        adoptWakePlan(snapshot)
    }

    /// Apply exclusions another device synced by name, once there are calendars to match them
    /// against. Additive — see `migrateCalendarExclusionsToGoogle`.
    private func applyRemoteCalendarExclusionsIfPossible() {
        migrateCalendarExclusionsToGoogle(availableCalendars)
    }

    private func localCalendarIDs(for identities: Set<CalendarIdentity>) -> Set<String>? {
        resolveCalendarIDs(
            for: identities,
            candidates: availableCalendars.map {
                ($0.id, CalendarIdentity(sourceTitle: $0.sourceTitle, calendarTitle: $0.title))
            }
        )
    }

    private func localWriteBackCalendarIDs(for identities: Set<CalendarIdentity>) -> Set<String>? {
        resolveCalendarIDs(
            for: identities,
            candidates: CalendarWriteBack.shared.writableCalendars.map {
                ($0.id, CalendarIdentity(sourceTitle: $0.sourceTitle, calendarTitle: $0.title))
            }
        )
    }

    /// EventKit source labels are display names, not stable account identifiers: the same
    /// account is currently “Bbaker” on iOS and “bbaker@gmail.example” on macOS. Prefer an
    /// exact identity, then a compatible account label, then a title only when it is unique.
    /// Returning nil for ambiguity is deliberate — an empty set means “turn every calendar on.”
    private func resolveCalendarIDs(
        for identities: Set<CalendarIdentity>,
        candidates: [(id: String, identity: CalendarIdentity)]
    ) -> Set<String>? {
        var resolved = Set<String>()
        for identity in identities {
            let exact = candidates.filter { $0.identity == identity }
            if exact.count == 1 {
                resolved.insert(exact[0].id)
                continue
            }

            let compatible = candidates.filter {
                sameCalendarTitle($0.identity.calendarTitle, identity.calendarTitle)
                    && compatibleSourceTitle($0.identity.sourceTitle, identity.sourceTitle)
            }
            if compatible.count == 1 {
                resolved.insert(compatible[0].id)
                continue
            }

            let titleOnly = candidates.filter {
                sameCalendarTitle($0.identity.calendarTitle, identity.calendarTitle)
            }
            guard titleOnly.count == 1 else { return nil }
            resolved.insert(titleOnly[0].id)
        }
        return resolved
    }

    private func sameCalendarTitle(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }

    private func compatibleSourceTitle(_ lhs: String, _ rhs: String) -> Bool {
        let lhsLabels = sourceLabels(lhs)
        let rhsLabels = sourceLabels(rhs)
        return !lhsLabels.isDisjoint(with: rhsLabels)
    }

    private func sourceLabels(_ value: String) -> Set<String> {
        var full = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !full.isEmpty else { return [] }
        // Banana's own label for a Google account is "Google · address"; Apple's was the address
        // (Mac) or its local part (iPhone). Compare the address.
        if full.hasPrefix("google · ") { full = String(full.dropFirst("google · ".count)) }
        var labels: Set<String> = [full]
        if let at = full.firstIndex(of: "@"), at != full.startIndex {
            labels.insert(String(full[..<at]))
        }
        return labels
    }

    private func publishWakePlanIfChanged(_ plan: WakePlan) {
        if let data = cloud.data(forKey: Self.cloudWakePlanKey),
           let existing = try? JSONDecoder().decode(CloudWakePlanSnapshot.self, from: data),
           existing.timeZoneIdentifier == TimeZone.current.identifier,
           existing.plan == plan {
            return
        }
        let snapshot = CloudWakePlanSnapshot(
            generatedAt: Date(),
            timeZoneIdentifier: TimeZone.current.identifier,
            plan: plan
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        cloud.set(data, forKey: Self.cloudWakePlanKey)
        cloud.synchronize()
        SyncReport.changed(Self.syncWakePlanType, [Self.syncWakePlanID])
        Log.sync.notice("phone wake plan published; days=\(plan.days.count)")
    }

    private func usableRemoteWakePlan(now: Date = Date()) -> WakePlan? {
        guard let remoteWakePlan,
              remoteWakePlan.days.contains(where: {
                  Calendar.current.isDate($0.date, inSameDayAs: now)
              })
        else { return nil }
        return remoteWakePlan
    }
}

/// The grid's undoable edits, bound to the store that performs them.
extension ToastCenter {
    func deferDelete(_ meeting: MeetingInfo, span: CalendarEditSpan, smart: SmartScheduleStore) {
        guard let eventID = meeting.eventID else { return }
        Task {
            await deferDelete(eventID: eventID, hiding: span.hiding(eventID, start: meeting.start),
                              title: meeting.title, span: span) {
                await smart.deleteMeeting(meeting, span: span)
            }
        }
    }

    func offerMoveUndo(_ meeting: MeetingInfo, from oldStart: Date, to newStart: Date,
                       span: CalendarEditSpan, smart: SmartScheduleStore) {
        var moved = meeting
        moved.start = newStart
        moved.end = meeting.end.map { newStart.addingTimeInterval($0.timeIntervalSince(meeting.start)) }
        Task {
            await offerMoveUndo(title: meeting.title, to: newStart, span: span) {
                await smart.moveMeeting(moved, to: oldStart, span: .thisEvent)
            }
        }
    }
}


extension CalendarMoveRecoveryStore {
    static let shared: CalendarMoveRecoveryStore = {
        #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--stress-days"),
           let flag = arguments.firstIndex(of: "--calendar-recovery-fixture"), flag + 1 < arguments.count,
           let id = UUID(uuidString: arguments[flag + 1]) {
            // Only the journal survives this audit relaunch; all other fixture stores retain
            // their normal per-process isolation. No user calendar or normal app data is used.
            return CalendarMoveRecoveryStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("CalendarMoveRecoveryFixture-\(id.uuidString)", isDirectory: true))
        }
        #endif
        return CalendarMoveRecoveryStore(directory: AppSupport.directory)
    }()
}
