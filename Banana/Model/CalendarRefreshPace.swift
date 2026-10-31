import Foundation

/// How often a device asks Google whether the calendars changed, and what a look made away from
/// the front does with the answer. Pure, for tests.
///
/// The ask is one small request per calendar (`GoogleCalendarService.hasChanges`). The full pass
/// (travel times, the busy blocks written back, the wake alarm) runs when something changed, or
/// when the last one is old enough that time alone has moved things.
///
/// What this can't decide: when iOS runs an app that isn't open. The interval is the least gap
/// asked of iOS for its background refresh, which iOS grants as it sees fit (on the iPad, six
/// runs in the five days to 6 Oct 2026 with the gap at two hours) and not at all in Low Power
/// Mode. What does keep to it: any device with Banana in front, a Mac with Banana running, and a
/// phone playing audio.
enum CalendarRefreshPace {
    /// In front of someone.
    static let inFront: TimeInterval = 2 * 60
    /// Running, not in front: a Mac behind other windows, a phone playing in a pocket. Also the
    /// least gap asked of iOS for the background refresh.
    static let away: TimeInterval = 5 * 60
    /// Away, in Low Power Mode.
    static let awayInLowPower: TimeInterval = 25 * 60
    /// With nothing changed on the calendars, how old the last full pass may get before a look
    /// runs one anyway: travel times and the days the plan covers move by themselves.
    static let fullPassAge: TimeInterval = 2 * 3_600

    static func interval(inFront: Bool, lowPower: Bool) -> TimeInterval {
        if inFront { return Self.inFront }
        return lowPower ? awayInLowPower : away
    }

    /// How long until the next ask is due; 0 when it is.
    static func remaining(last: Date?, now: Date, inFront: Bool, lowPower: Bool) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, interval(inFront: inFront, lowPower: lowPower) - now.timeIntervalSince(last))
    }

    enum Look: Equatable { case nothing, fullPass }

    /// After a look made away from the front.
    /// - Parameter changed: nil when the calendars couldn't be read (offline): nothing to plan from.
    static func afterLook(changed: Bool?, lastFullPass: Date?, now: Date) -> Look {
        guard let changed else { return .nothing }
        if changed { return .fullPass }
        guard let lastFullPass else { return .fullPass }
        return now.timeIntervalSince(lastFullPass) >= fullPassAge ? .fullPass : .nothing
    }

    /// What a poll has already been told. Google's reads count the ones that found someone else's
    /// change (`GoogleCalendarService.newsSerial`); a poll that remembers the count it last saw is
    /// told of each change once.
    ///
    /// The poll used to ask "any change since my last question?" by the clock, and the read that
    /// finds a change starts a moment after the question that asked for it: so the next question
    /// was told of the same change again, and every change someone made was planned for twice
    /// (seen on the phone on 8 Oct 2026: a full pass at 23:46 for a change, and another at 23:51
    /// for nothing).
    struct Seen: Equatable {
        private(set) var serial = 0
        mutating func isNews(_ current: Int) -> Bool {
            defer { serial = current }
            return current != serial
        }
    }

    /// When the timeline last finished a full pass, write-back included (`OccurrenceStore`).
    static let lastFullPassKey = "calendarLastFullPassAt"
}
