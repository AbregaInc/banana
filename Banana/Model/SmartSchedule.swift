import Foundation

/// How days without any qualifying meeting are handled.
enum WeekendMode: String, Codable, CaseIterable, Identifiable {
    case hold        // wake at the anchor even on meeting-free days (steadiest rhythm)
    case sleepIn     // no alarm on meeting-free days
    case later       // wake later by `offDayShiftMinutes` on meeting-free days

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hold: return "Hold the same wake"
        case .sleepIn: return "Let me sleep in"
        case .later: return "A bit later"
        }
    }
}

/// User-tunable smart-schedule settings, persisted.
struct SmartScheduleSettings: Codable, Equatable {
    var enabled = false
    var sleepTargetMinutes = 8 * 60      // desired time asleep
    var fallAsleepMinutes = 30           // latency added on top when computing bedtime
    var prepBufferMinutes = 60           // wake this long before the first meeting
    var earliestWakeMinutes = 5 * 60 + 30 // floor: never wake before this (5:30)
    var defaultWakeMinutes = 6 * 60 + 30 // fallback when there are no meetings at all
    var weekendMode: WeekendMode = .hold
    var offDayShiftMinutes = 60
    var bedtimeRemindersEnabled = true
    var windDownEnabled = true
    var excludedCalendarIDs: Set<String> = []   // calendars that do NOT count as "meetings"
    /// Raw Google calendar ids whose events stay visible but never notify in Banana.
    var mutedCalendarIDs: Set<String> = []
    /// Calendars you own that availability busy blocks must NOT be written to — still read
    /// normally.
    var writeBackExcludedCalendarIDs: Set<String> = []
    /// Calendars you can edit but don't own that DO receive busy blocks. Someone else's calendar
    /// is opt-in: every block written to it notifies everyone it is shared with. Google calendar
    /// ids, which are the same on every device, so this syncs as it is.
    var writeBackSharedCalendarIDs: Set<String> = []
    /// Calendars you own whose all-day events are hidden, and other people's or subscribed ones
    /// whose all-day events are shown (`AllDayEvents`). Raw Google calendar ids, the same on
    /// every device, so these sync as they are.
    var allDayHiddenCalendarIDs: Set<String> = []
    var allDayShownCalendarIDs: Set<String> = []
    /// All-day events hidden by title, and whether Google's contact birthdays show
    /// (`AllDayEvents.Choice`).
    var allDayHiddenTitles: Set<String> = []
    var showsBirthdays = true

    /// Colours you've chosen for calendars in Banana (Settings › Calendar colours), by calendar
    /// info id. Banana-only — Google keeps its own.
    var calendarColorChoices: [String: String] = [:]

    var allDayChoice: AllDayEvents.Choice {
        AllDayEvents.Choice(hidden: allDayHiddenCalendarIDs, shown: allDayShownCalendarIDs,
                            hiddenTitles: allDayHiddenTitles, showsBirthdays: showsBirthdays)
    }
    /// Whether scheduled tasks reserve real calendar time. Off = tasks appear on the Banana
    /// timeline only; no busy blocks are written for them (meeting mirroring is unaffected).
    var reserveTaskTime = true
    /// Busy blocks on or off: one setting for every device, each of which writes and reconciles.
    /// Nil until a device that has been set up says — a fresh device adopts it rather than
    /// seeding "off" over everyone else's "on".
    var writeBackEnabled: Bool?
    /// The calendar where scheduled tasks keep their title — a Google calendar info id, the same
    /// on every device.
    var writeBackCalendarID: String?
    /// Weekday that begins the week in week views, stats windows, and date pickers.
    /// Calendar numbering: 1 = Sunday, 2 = Monday … 7 = Saturday. Deliberately independent
    /// of device locale so every device agrees; Monday by default.
    var weekStartWeekday = 2
    /// Whether the Notes list shows the Archived section while browsing. Synced so flipping
    /// it on one device reveals the same notes everywhere. Search always includes archived
    /// notes regardless — archiving must never make a note unfindable.
    var showArchivedNotes = false

    // Health-adaptive wake: on free days only, sleep in later (≤45m) when carrying
    // sleep debt or poor recovery, and pull bedtime earlier to catch up.
    var healthAdaptive = true

    // Travel time
    var accountForTravel = false
    var transitMode: TransitMode = .drive
    var homeLatitude: Double?
    var homeLongitude: Double?
    var homeLabel: String?
    var leaveByAlerts = true
    /// Places you confirmed for vague calendar locations ("Chelsea" → your gym). See SavedPlace.
    var savedPlaces: [SavedPlace] = []
    /// Walk any trip shorter than `walkShortTripMeters`, whatever the default mode.
    var walkShortTrips = true
    var walkShortTripMeters = 1300
    /// Learn real trip times from the phone's visits and motion (off until turned on; asks for
    /// "Always" location and Motion). Only the summary below syncs — never the visits.
    var learnFromTrips = false
    var learnedTravel = LearnedTravel()
    /// On baby duty at night: a longer trip out of bed is guessed as the baby rather than "up for
    /// a while". Synced, so the Mac's Sleep page guesses the same way.
    var babyDutyAtNight = false
    /// What you said night wake-ups were: `SleepNights.labelKey` → `NightWakeKind` raw value.
    /// Synced, so a correction on either device teaches both; kept for 60 days.
    var nightWakeLabels: [String: String] = [:]
    // Calendar availability is a separate product promise from smart wake/alerts. It remains on
    // even when Smart Schedule is off; a provider-backed calendar carries the blocks to every
    // device that uses the same account.
    var blockTravelTime = true

    // Commute: a "leave now" nudge before EVERY located meeting (multi-hop), travel-aware.
    var commuteAlerts = false
    var commuteBufferMinutes = 5        // heads-up before you must leave
    var workLatitude: Double?
    var workLongitude: Double?
    var workLabel: String?

    var hasHome: Bool { homeLatitude != nil && homeLongitude != nil }
    var hasWork: Bool { workLatitude != nil && workLongitude != nil }
}

extension SmartScheduleSettings {
    /// Tolerant decoder: missing keys keep their defaults, so adding a field in a
    /// later version never invalidates saved settings (which would silently reset
    /// Smart Schedule to off).
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        sleepTargetMinutes = try c.decodeIfPresent(Int.self, forKey: .sleepTargetMinutes) ?? sleepTargetMinutes
        fallAsleepMinutes = try c.decodeIfPresent(Int.self, forKey: .fallAsleepMinutes) ?? fallAsleepMinutes
        prepBufferMinutes = try c.decodeIfPresent(Int.self, forKey: .prepBufferMinutes) ?? prepBufferMinutes
        earliestWakeMinutes = try c.decodeIfPresent(Int.self, forKey: .earliestWakeMinutes) ?? earliestWakeMinutes
        defaultWakeMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultWakeMinutes) ?? defaultWakeMinutes
        weekendMode = try c.decodeIfPresent(WeekendMode.self, forKey: .weekendMode) ?? weekendMode
        offDayShiftMinutes = try c.decodeIfPresent(Int.self, forKey: .offDayShiftMinutes) ?? offDayShiftMinutes
        bedtimeRemindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .bedtimeRemindersEnabled) ?? bedtimeRemindersEnabled
        windDownEnabled = try c.decodeIfPresent(Bool.self, forKey: .windDownEnabled) ?? windDownEnabled
        excludedCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .excludedCalendarIDs) ?? excludedCalendarIDs
        mutedCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .mutedCalendarIDs) ?? mutedCalendarIDs
        writeBackExcludedCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .writeBackExcludedCalendarIDs) ?? writeBackExcludedCalendarIDs
        reserveTaskTime = try c.decodeIfPresent(Bool.self, forKey: .reserveTaskTime) ?? reserveTaskTime
        writeBackEnabled = try c.decodeIfPresent(Bool.self, forKey: .writeBackEnabled)
        writeBackCalendarID = try c.decodeIfPresent(String.self, forKey: .writeBackCalendarID)
        writeBackSharedCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .writeBackSharedCalendarIDs) ?? writeBackSharedCalendarIDs
        allDayHiddenCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .allDayHiddenCalendarIDs) ?? allDayHiddenCalendarIDs
        allDayShownCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .allDayShownCalendarIDs) ?? allDayShownCalendarIDs
        calendarColorChoices = try c.decodeIfPresent([String: String].self, forKey: .calendarColorChoices) ?? calendarColorChoices
        allDayHiddenTitles = try c.decodeIfPresent(Set<String>.self, forKey: .allDayHiddenTitles) ?? allDayHiddenTitles
        showsBirthdays = try c.decodeIfPresent(Bool.self, forKey: .showsBirthdays) ?? showsBirthdays
        weekStartWeekday = try c.decodeIfPresent(Int.self, forKey: .weekStartWeekday) ?? weekStartWeekday
        showArchivedNotes = try c.decodeIfPresent(Bool.self, forKey: .showArchivedNotes) ?? showArchivedNotes
        healthAdaptive = try c.decodeIfPresent(Bool.self, forKey: .healthAdaptive) ?? healthAdaptive
        accountForTravel = try c.decodeIfPresent(Bool.self, forKey: .accountForTravel) ?? accountForTravel
        transitMode = try c.decodeIfPresent(TransitMode.self, forKey: .transitMode) ?? transitMode
        homeLatitude = try c.decodeIfPresent(Double.self, forKey: .homeLatitude) ?? homeLatitude
        homeLongitude = try c.decodeIfPresent(Double.self, forKey: .homeLongitude) ?? homeLongitude
        homeLabel = try c.decodeIfPresent(String.self, forKey: .homeLabel) ?? homeLabel
        leaveByAlerts = try c.decodeIfPresent(Bool.self, forKey: .leaveByAlerts) ?? leaveByAlerts
        // A malformed place list must not reset every other setting.
        savedPlaces = (try? c.decodeIfPresent([SavedPlace].self, forKey: .savedPlaces)) ?? savedPlaces
        walkShortTrips = try c.decodeIfPresent(Bool.self, forKey: .walkShortTrips) ?? walkShortTrips
        walkShortTripMeters = try c.decodeIfPresent(Int.self, forKey: .walkShortTripMeters) ?? walkShortTripMeters
        learnFromTrips = try c.decodeIfPresent(Bool.self, forKey: .learnFromTrips) ?? learnFromTrips
        learnedTravel = (try? c.decodeIfPresent(LearnedTravel.self, forKey: .learnedTravel)) ?? learnedTravel
        babyDutyAtNight = try c.decodeIfPresent(Bool.self, forKey: .babyDutyAtNight) ?? babyDutyAtNight
        nightWakeLabels = (try? c.decodeIfPresent([String: String].self, forKey: .nightWakeLabels)) ?? nightWakeLabels
        blockTravelTime = try c.decodeIfPresent(Bool.self, forKey: .blockTravelTime) ?? blockTravelTime
        commuteAlerts = try c.decodeIfPresent(Bool.self, forKey: .commuteAlerts) ?? commuteAlerts
        commuteBufferMinutes = try c.decodeIfPresent(Int.self, forKey: .commuteBufferMinutes) ?? commuteBufferMinutes
        workLatitude = try c.decodeIfPresent(Double.self, forKey: .workLatitude) ?? workLatitude
        workLongitude = try c.decodeIfPresent(Double.self, forKey: .workLongitude) ?? workLongitude
        workLabel = try c.decodeIfPresent(String.self, forKey: .workLabel) ?? workLabel
    }
}

/// Preferred mode of transit for travel-time estimates.
enum TransitMode: String, Codable, CaseIterable, Identifiable {
    case drive, transit, walk

    var id: String { rawValue }
    var label: String {
        switch self {
        case .drive: return "Drive"
        case .transit: return "Transit"
        case .walk: return "Walk"
        }
    }
    var systemImage: String {
        switch self {
        case .drive: return "car.fill"
        case .transit: return "tram.fill"
        case .walk: return "figure.walk"
        }
    }
}

/// The computed plan for the look-ahead window.
struct WakePlan: Codable, Equatable {
    struct Day: Codable, Equatable, Identifiable {
        var id: Date { date }
        var date: Date          // start of the calendar day
        var weekday: Int        // 1 = Sunday … 7 = Saturday (Calendar.component)
        var firstMeeting: Date? // earliest qualifying event that morning, if any
        var wake: Date?         // scheduled wake that morning (nil = no alarm)
        var bedtime: Date?      // bedtime the PREVIOUS night to hit `wake`
    }

    var anchorMinutes: Int?     // minutes-of-day of the weekly wake anchor
    var days: [Day]
    var explanation: String

    /// Grouped repeating-alarm entries: one wake time → the weekdays it applies to.
    /// One wake per weekday (nearest occurrence wins), so the look-ahead window can be
    /// longer than 7 days without producing duplicate weekday alarms.
    var alarmEntries: [(minutes: Int, weekdays: [Int])] {
        var minuteForWeekday: [Int: Int] = [:]
        for day in days {                                    // days are in chronological order
            guard let wake = day.wake, minuteForWeekday[day.weekday] == nil else { continue }
            minuteForWeekday[day.weekday] = Calendar.current.component(.hour, from: wake) * 60
                + Calendar.current.component(.minute, from: wake)
        }
        var byMinute: [Int: [Int]] = [:]
        for (weekday, minute) in minuteForWeekday { byMinute[minute, default: []].append(weekday) }
        return byMinute
            .sorted { $0.key < $1.key }
            .map { (minutes: $0.key, weekdays: $0.value.sorted()) }
    }
}

extension Calendar {
    /// The system calendar with the user's configured week start applied. Use this wherever a
    /// week boundary is user-visible (week views, weekly stats buckets, graphical date pickers).
    /// SmartScheduleStore keeps `appFirstWeekday` in sync with the synced setting, so this
    /// stays correct across devices without threading the store through model code.
    static var app: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = appFirstWeekday
        return cal
    }

    /// Backing weekday for `Calendar.app` (1 = Sunday … 7 = Saturday). Written only by
    /// SmartScheduleStore on the main actor; reads from other contexts see a torn value at
    /// worst one frame stale, which is harmless for week-grid math.
    nonisolated(unsafe) static var appFirstWeekday = 2
}
