import Foundation

enum TravelBlockPolicy {
    private static let increment: TimeInterval = 5 * 60

    /// Calendar protection must not disappear merely because the reverse MapKit request fails.
    /// Prefer the live route; for a return trip, the already-resolved outbound duration is a
    /// bounded local fallback. If neither exists, do not fabricate a trip.
    static func blockDuration(
        routeSeconds: TimeInterval?,
        fallbackMinutes: Int?
    ) -> TimeInterval? {
        let fallback = fallbackMinutes.flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil }
        guard let duration = routeSeconds.flatMap({ $0.isFinite && $0 > 0 ? $0 : nil }) ?? fallback
        else { return nil }
        return max(increment, ceil(duration / increment) * increment)
    }

    static func returnHomeInterval(
        departingAt departure: Date,
        routeSeconds: TimeInterval?,
        fallbackMinutes: Int?
    ) -> DateInterval? {
        guard let duration = blockDuration(
            routeSeconds: routeSeconds,
            fallbackMinutes: fallbackMinutes
        ) else { return nil }
        return DateInterval(start: departure, duration: duration)
    }

    /// A failed route lookup is not evidence that the person stayed away from home. When a
    /// prior synced outbound block gives us a bounded duration, retain the return reservation;
    /// only a successful route comparison may decide that the gap is too short to go home.
    /// A meaningful period at home, without which going there and back is not a trip home — it is
    /// a round trip for nothing. Shared with `SmartScheduleStore`'s routed decision so both paths
    /// agree on what "long enough to go home" means.
    static let minimumHomeDwell: TimeInterval = 45 * 60

    /// Whether to reserve a trip home after a meeting.
    ///
    /// - Parameters:
    ///   - routedDecision: the answer from a real route, when one could be computed.
    ///   - fallbackMinutes: the outbound duration, used to estimate the homeward one.
    ///   - gapToNext: time until the next physical meeting, or nil when this is the day's last.
    ///
    /// The fallback used to ask only whether the outbound trip took any time at all. That is the
    /// wrong question: it says nothing about whether there is ROOM to go home, so two meetings a
    /// few minutes and a few hundred feet apart got a full trip home reserved between them — drawn
    /// on the grid as a "Travel home" band immediately followed by a walk back.
    static func shouldReserveReturnHome(
        routedDecision: Bool?,
        fallbackMinutes: Int?,
        gapToNext: TimeInterval?
    ) -> Bool {
        if let routedDecision { return routedDecision }
        guard let minutes = fallbackMinutes, minutes > 0 else { return false }
        // The day's last physical place always ends at home.
        guard let gapToNext else { return true }
        // Without a route the outbound duration is the only estimate available for the homeward
        // one, so require room for both plus time actually spent at home.
        let eachWay = TimeInterval(minutes * 60)
        return gapToNext >= eachWay * 2 + minimumHomeDwell
    }

    /// Whether a "Travel home" block ALREADY on the calendar still describes a real trip.
    ///
    /// These are read back and drawn regardless of whether write-back is on, and regardless of
    /// what the generator currently wants — they are how a second device sees travel it did not
    /// calculate. That makes them the one path a stale reservation can survive on forever: a trip
    /// home written before the next meeting existed keeps being rendered even once the calendar
    /// says you go straight from one place to the next.
    ///
    /// Judged with the same rule as a fresh reservation, using the block's own length as the
    /// estimate for each leg, so a device with no route data reaches the same answer.
    static func syncedReturnHomeIsStillValid(
        blockStart: Date,
        blockEnd: Date,
        nextMeetingStart: Date?
    ) -> Bool {
        let minutes = max(1, Int(blockEnd.timeIntervalSince(blockStart) / 60))
        return shouldReserveReturnHome(
            routedDecision: nil,
            fallbackMinutes: minutes,
            gapToNext: nextMeetingStart.map { $0.timeIntervalSince(blockStart) }
        )
    }
}
