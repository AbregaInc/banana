import Foundation
import UserNotifications

/// Schedules bedtime + wind-down reminders as local notifications, refreshed
/// each time the plan is recomputed.
enum NotificationService {
    static func requestAuthorization() async -> Bool {
        #if DEBUG
        // Deterministic screenshot routes cannot have a system authorization alert covering
        // the screen. Ordinary Debug launches still exercise the real permission flow.
        if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
            return true
        }
        #endif
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            Log.wake.notice("[notifications] request → \(granted ? "granted" : "not granted", privacy: .public)")
            return granted
        } catch {
            // Logged, not swallowed: "Connect did nothing" on the Mac was undiagnosable without it.
            Log.wake.notice("[notifications] request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Reschedule-only-on-change
    //
    // Each scheduler used to do getPending → remove-ours → re-add-all on EVERY recompute — a
    // notification-daemon round-trip churn of ~20 requests per calendar change even when the
    // desired set was identical. Fingerprint the desired FUTURE set instead and skip the whole
    // pass when it matches the last one scheduled. Process-lifetime memory: the first call after
    // a relaunch always reschedules, which also self-heals any daemon-side drift. (Entries aging
    // into the past change the fingerprint, so fired leftovers still get swept naturally.)
    // Main-actor isolated: the schedulers are nonisolated async, so their bodies run on the
    // pool — and main-actor reentrancy means two can genuinely overlap (a recompute suspended
    // at an await while the settings toggle fires the disabled-path reschedule). One shared
    // mutable dictionary touched from two pool threads is a data race; the await at each check
    // serializes it instead.
    @MainActor private static var lastFingerprints: [String: Int] = [:]

    @MainActor private static func alreadyScheduled(_ key: String, _ fingerprint: Int) -> Bool {
        if lastFingerprints[key] == fingerprint { return true }
        lastFingerprints[key] = fingerprint
        return false
    }

    private static func combine(_ hasher: inout Hasher, _ date: Date) {
        hasher.combine(Int(date.timeIntervalSince1970 / 60))   // minute precision, like the triggers
    }

    static func scheduleBedtimes(_ plan: WakePlan, settings: SmartScheduleSettings) async {
        let center = UNUserNotificationCenter.current()
        let now = Date()

        var hasher = Hasher()
        hasher.combine(settings.bedtimeRemindersEnabled)
        hasher.combine(settings.windDownEnabled)
        if settings.bedtimeRemindersEnabled {
            for day in plan.days {
                guard let bedtime = day.bedtime, let wake = day.wake, bedtime > now else { continue }
                combine(&hasher, day.date); combine(&hasher, bedtime); combine(&hasher, wake)
            }
        }
        if await alreadyScheduled("bed", hasher.finalize()) { return }

        // Clear our previously-scheduled bedtime/wind-down notifications.
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter {
            $0.hasPrefix("banana.bed.") || $0.hasPrefix("banana.wind.")
                || $0.hasPrefix("quarters.bed.") || $0.hasPrefix("quarters.wind.")
        }
        NotificationWrites.removePending(ours)

        guard settings.bedtimeRemindersEnabled else { return }

        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.timeStyle = .short; formatter.dateStyle = .none

        for day in plan.days {
            guard let bedtime = day.bedtime, let wake = day.wake, bedtime > now else { continue }
            let wakeStr = formatter.string(from: wake)
            let key = String(Int(day.date.timeIntervalSince1970))

            add(center, id: "banana.bed.\(key)",
                title: "Time for bed",
                body: "Head to bed now to hit your \(wakeStr) wake.",
                at: bedtime, cal: cal)

            if settings.windDownEnabled,
               let windDown = cal.date(byAdding: .minute, value: -30, to: bedtime), windDown > now {
                add(center, id: "banana.wind.\(key)",
                    title: "Wind down",
                    body: "Start winding down — bed in 30 minutes for your \(wakeStr) wake.",
                    at: windDown, cal: cal)
            }
        }
    }

    /// Notify when it's time to leave for the first in-person meeting, using the
    /// travel ETA already computed for the wake plan.
    static func scheduleLeaveByAlerts(meetings: [Date: MeetingInfo], travelMinutes: [Date: Int],
                                      mode: TransitMode, enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let now = Date()

        var hasher = Hasher()
        hasher.combine(enabled)
        if enabled {
            hasher.combine(mode)
            for (day, info) in meetings.sorted(by: { $0.key < $1.key }) {
                guard info.hasPhysicalLocation, let travel = travelMinutes[day], travel > 0,
                      info.start > now else { continue }
                combine(&hasher, day); combine(&hasher, info.start); hasher.combine(travel)
                hasher.combine(info.title)   // the body renders it — a rename must reschedule
            }
        }
        if await alreadyScheduled("leave", hasher.finalize()) { return }

        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter {
            $0.hasPrefix("banana.leave.") || $0.hasPrefix("quarters.leave.")
        }
        NotificationWrites.removePending(ours)
        guard enabled else { return }

        let cal = Calendar.current
        let time = DateFormatter(); time.timeStyle = .short; time.dateStyle = .none
        let verb = mode == .walk ? "walk" : (mode == .transit ? "trip" : "drive")

        for (day, info) in meetings {
            guard info.hasPhysicalLocation, let travel = travelMinutes[day], travel > 0 else { continue }
            // Fire 5 minutes before you actually need to leave.
            guard let alertAt = cal.date(byAdding: .minute, value: -(travel + 5), to: info.start), alertAt > now else { continue }
            let leaveBy = cal.date(byAdding: .minute, value: -travel, to: info.start) ?? info.start
            add(center, id: "banana.leave.\(Int(day.timeIntervalSince1970))",
                title: "Leave soon",
                body: "~\(travel) min \(verb) to \(info.title) at \(time.string(from: info.start)). Leave by \(time.string(from: leaveBy)).",
                at: alertAt, cal: cal)
        }
    }

    struct CommuteLeg: Equatable {
        let title: String
        let start: Date
        let leaveBy: Date
        let travelMinutes: Int
        /// Mode, place and how sure — what the block and the nudge say about this trip.
        var detail: TravelLegDetail? = nil
        /// Rain forecast between leaving and getting home, if any. Rendered into the body so the
        /// nudge answers "do I need a coat?" at the one moment you can still act on it — you are
        /// about to walk out of the door.
        var rain: WeatherStore.RainOutlook? = nil
    }

    /// Multi-hop commute: a "leave now" nudge before EVERY located meeting today,
    /// firing `bufferMinutes` before you actually need to leave.
    static func scheduleCommuteAlerts(_ legs: [CommuteLeg], bufferMinutes: Int, mode: TransitMode, enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let now = Date()

        var hasher = Hasher()
        hasher.combine(enabled)
        if enabled {
            hasher.combine(mode); hasher.combine(bufferMinutes)
            for leg in legs where leg.leaveBy > now {
                combine(&hasher, leg.start); combine(&hasher, leg.leaveBy); hasher.combine(leg.travelMinutes)
                hasher.combine(leg.detail?.mode)
                hasher.combine(leg.title)   // the body renders it — a rename must reschedule
                hasher.combine(leg.rain?.peakChance)   // ditto: a changed forecast must reschedule
            }
        }
        if await alreadyScheduled("commute", hasher.finalize()) { return }

        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter {
            $0.hasPrefix("banana.commute.") || $0.hasPrefix("quarters.commute.")
        }
        NotificationWrites.removePending(ours)
        guard enabled else { return }

        let cal = Calendar.current
        let time = DateFormatter(); time.timeStyle = .short; time.dateStyle = .none
        func verb(_ mode: TransitMode) -> String { mode == .walk ? "walk" : (mode == .transit ? "trip" : "drive") }

        for (i, leg) in legs.enumerated() {
            guard let alertAt = cal.date(byAdding: .minute, value: -bufferMinutes, to: leg.leaveBy), alertAt > now else { continue }
            // Each trip's own mode: the gym round the corner is a walk even on a transit default.
            var body = "\(leg.travelMinutes) min \(verb(leg.detail?.mode ?? mode)) to \(leg.title) at \(time.string(from: leg.start)) — leave by \(time.string(from: leg.leaveBy))."
            if let rain = leg.rain {
                // Named as a chance, not a certainty, and anchored to a time — "60% rain from
                // 4 PM" is actionable in a way that a bare umbrella emoji never is.
                body += " ☔️ \(rain.peakChance)% \(rain.condition.lowercased()) from \(time.string(from: rain.startsAt)) — take a coat."
            }
            add(center, id: "banana.commute.\(Int(leg.start.timeIntervalSince1970))-\(i)",
                title: "Time to head out",
                body: body,
                at: alertAt, cal: cal)
        }
    }

    /// "Starting soon" alerts for calendar events.
    ///
    /// Banana announces every event it is asked to, without regard for what any other calendar
    /// app might also do — see `EventAlertPlan` for why guessing at that was wrong. Someone who
    /// does not want two notifications turns the other app's off, in that app.
    /// - Parameter quiet: `calendarId|eventId` of the events the person skipped, which ring nowhere.
    static func scheduleEventAlerts(_ candidates: [EventAlertPlan.Candidate],
                                    leads: [Int],
                                    quiet: [String] = [],
                                    now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        // The service's alerts and this device's own share ids (docs/design/EVENT-ALERTS.md): one
        // the service has already delivered here isn't scheduled again.
        let delivered = await EventAlerts.deliveredIDs()
        let items = EventAlertPlan.items(from: candidates, leads: leads, now: now)
            .filter { !delivered.contains(Self.eventAlertID($0)) }
        // The service words its alerts with the same lead times.
        await BananaAccount.shared.alertSettingsChanged(leads: leads)

        var hasher = Hasher()
        for lead in leads { hasher.combine(lead) }
        for item in items {
            hasher.combine(item.id)
            combine(&hasher, item.fireAt)
            hasher.combine(item.title)   // the body renders it — a rename must reschedule
        }
        if await alreadyScheduled("event", hasher.finalize()) {
            await BananaAccount.shared.reportHeldAlerts(await EventAlerts.heldIDs(), quiet: quiet)
            return
        }

        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(EventAlerts.localPrefix) }
        NotificationWrites.removePending(ours)

        let cal = Calendar.current
        let time = DateFormatter(); time.timeStyle = .short; time.dateStyle = .none
        for item in items {
            add(center, id: EventAlerts.localPrefix + Self.eventAlertID(item),
                title: item.title,
                body: EventAlertPlan.body(for: item, now: item.fireAt, formatter: time),
                at: item.fireAt, cal: cal)
        }
        // What this device now holds: the service won't push those to it.
        await BananaAccount.shared.reportHeldAlerts(items.map(Self.eventAlertID), quiet: quiet)
    }

    /// The shared id of a planned alert (`calendarId|eventId|lead`), or the plan's own id for an
    /// event that isn't Google's.
    static func eventAlertID(_ item: EventAlertPlan.Item) -> String { BananaService.alertID(planItemID: item.id) }

    private static func add(_ center: UNUserNotificationCenter, id: String, title: String, body: String,
                            at date: Date, cal: Calendar) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Every one of these is about a moment — leave now, the meeting is starting, time for bed
        // — and is worthless after it. Time Sensitive lets them through a Focus and keeps them on
        // the Lock Screen longer; it needs the matching entitlement or it is quietly dropped.
        content.interruptionLevel = .timeSensitive
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        NotificationWrites.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
