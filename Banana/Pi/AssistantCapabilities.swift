#if BANANA_AI
import Foundation

/// Application capabilities. Pi owns tool admission, argument validation and replay policy.
@MainActor
enum AssistantCapabilities {
    static func freeTime(_ args: [String: Any], now: Date = Date()) async throws -> String {
        let calendar = Calendar.app
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: 30, to: today) else {
            throw AssistantFailure(message: "The calendar date couldn’t be resolved.")
        }
        let date = try (args["date"] as? String).map { requested in
            try AssistantFreeTime.weekday(requested, after: now, calendar: calendar)
                ?? AssistantNutrition.date(AssistantLocalDay.key(requested, now: now, calendar: calendar), calendar: calendar)
        }
        let days = try AssistantFreeTime.days(date: date, period: args["period"] as? String,
                                              now: now, horizon: horizon, calendar: calendar)
        let duration = args["durationMinutes"] as? Int ?? 30
        let limit = args["limit"] as? Int ?? 8
        guard (1...720).contains(duration), (1...8).contains(limit) else {
            throw AssistantFailure(message: "Choose a duration of 1 to 720 minutes and up to eight openings.")
        }
        let windows = try days.compactMap { day -> DateInterval? in
            if args["weekdaysOnly"] as? Bool == true && calendar.isDateInWeekend(day) { return nil }
            let start = try AssistantFreeTime.time(args["after"] as? String ?? "09:00", day: day, calendar: calendar)
            let end = try AssistantFreeTime.time(args["before"] as? String ?? "17:00", day: day, calendar: calendar)
            guard start < end else { throw AssistantFailure(message: "Choose an increasing time window.") }
            return max(start, now) < end ? DateInterval(start: max(start, now), end: end) : nil
        }
        guard let first = windows.first, let last = windows.last else {
            throw AssistantFailure(message: "That time window has already ended.")
        }
        let busy = try await calendarBusy(from: first.start, to: last.end)
        let free = windows.flatMap { AssistantFreeTime.slots(in: $0, busy: busy, minimum: TimeInterval(duration * 60)) }
        let ordered = args["longestFirst"] as? Bool == true ? free.sorted {
            $0.duration == $1.duration ? $0.start < $1.start : $0.duration > $1.duration
        } : free
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        format.dateFormat = "HH:mm"
        let key = { AssistantNutrition.key($0, calendar: calendar) }
        let result: [String: Any] = [
            "date": key(first.start), "through": key(last.end), "timeZone": calendar.timeZone.identifier,
            "minimumMinutes": duration, "coverage": "Included Google calendars, busy events only",
            "windows": ordered.prefix(limit).map { ["date": key($0.start), "start": format.string(from: $0.start),
                                                "end": format.string(from: $0.end)] },
            "hasMore": free.count > limit,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }

    static func checkCalendarInterval(_ args: [String: Any], now: Date = .now) async throws -> String {
        guard let from = args["start"] as? String, let to = args["end"] as? String,
              let start = AssistantFreeTime.absoluteTime(from), let end = AssistantFreeTime.absoluteTime(to),
              validInterval(start, end, now: now) else {
            throw AssistantFailure(message: "Choose a future time range of up to 12 hours within the next 30 days.")
        }
        let busy = try await calendarBusy(from: start, to: end)
        let conflict = busy.contains { $0.start < end && $0.end > start }
        let local = DateIntervalFormatter()
        local.dateStyle = .medium
        local.timeStyle = .short
        local.timeZone = .current
        let label = local.string(from: start, to: end)
        let status = conflict ? "You have a conflict" : "You’re free"
        let answer = "\(status) on your included Google calendars for \(label) (\(TimeZone.current.identifier))."
        let result = CalendarIntervalResult(available: !conflict, answer: answer, start: from, end: to)
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    private struct CalendarIntervalResult: Encodable {
        let available: Bool
        let answer: String
        let start: String
        let end: String
    }

    private static func validInterval(_ start: Date, _ end: Date, now: Date) -> Bool {
        start >= now && start.timeIntervalSince(now) < 30 * 86_400 &&
            end > start && end.timeIntervalSince(start) <= 12 * 3_600
    }

    static func composerIntervalAvailable(from start: Date, to end: Date, account: String, now: Date = .now) async throws -> Bool {
        guard !account.isEmpty else { throw AssistantFailure(message: "Select a calendar account before checking this time.") }
        // The correspondent gave both endpoints. Checking this one bounded
        // interval does not scan the intervening days in the planning horizon.
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              start >= now, end > start, end.timeIntervalSince(start) <= 12 * 3600 else {
            throw AssistantFailure(message: "Check a future time window of up to 12 hours before replying.")
        }
        let busy = try await calendarBusy(from: start, to: end, account: account)
        let service = GoogleCalendarService.shared
        guard service.accounts.contains(where: { $0.id == account }), !service.accountsNeedingReconnect.contains(account) else {
            throw composerCoverageFailure(account: account)
        }
        return !busy.contains { $0.start < end && $0.end > start }
    }

    private static func composerCoverageFailure(account: String) -> AssistantFailure {
        let service = GoogleCalendarService.shared
        if service.accountsNeedingReconnect.contains(account) {
            return AssistantFailure(message: "Reconnect this calendar account before checking the proposed time.")
        }
        guard service.accounts.contains(where: { $0.id == account }) else {
            return AssistantFailure(message: "This calendar account is unavailable. Check the proposed time before replying.")
        }
        return AssistantFailure(message: "Banana couldn’t verify the entire time window on this account’s included calendars. Check the proposed time before replying.")
    }

    private static func calendarBusy(from start: Date, to end: Date, account: String? = nil) async throws -> [DateInterval] {
        let settings = SmartScheduleStore.shared.settings
        let read = await GoogleCalendarService.shared.windowFetch(from: start, to: end,
            excluding: settings.excludedCalendarIDs, allDay: settings.allDayChoice, account: account)
        try Task.checkCancellation()
        guard read.isComplete, !read.covered.isEmpty else {
            if let account { throw composerCoverageFailure(account: account) }
            throw AssistantFailure(message: "Some included Google calendars couldn’t be checked. Open Plan to check the connections before choosing a time.")
        }
        return read.window.busyIntervals.compactMap { value in
            value.start < value.end ? DateInterval(start: value.start, end: value.end) : nil
        }
    }

    static func execute(_ request: String) async throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
              let name = value["name"] as? String, let arguments = value["arguments"] as? [String: Any] else {
            throw AssistantFailure(message: "The assistant sent an invalid app action.")
        }
        let result: Any
        switch name {
        case "list_notes":
            let limit = arguments["limit"] as? Int ?? 5
            guard (1...10).contains(limit) else { throw AssistantFailure(message: "Request between one and ten notes.") }
            let notes = await VoiceNoteStore.shared.searchResults("", limit: limit + 1)
            result = ["notes": notes.prefix(limit).map { note in
                ["id": note.id.uuidString, "text": String((note.transcript ?? "").prefix(160)),
                 "createdAt": note.createdAt.ISO8601Format()]
            }, "hasMore": notes.count > limit] as [String: Any]
        case "read_note":
            guard let raw = arguments["id"] as? String, let id = UUID(uuidString: raw),
                  let note = VoiceNoteStore.shared.note(id) else {
                throw AssistantFailure(message: "That note could not be found.")
            }
            let text = note.transcript ?? ""
            result = ["id": id.uuidString, "text": String(text.prefix(2400)), "truncated": text.count > 2400] as [String: Any]
        case "create_note":
            guard let text = arguments["text"] as? String, let operation = value["operationId"] as? String,
                  let id = UUID(uuidString: operation) else { throw AssistantFailure(message: "The note action is invalid.") }
            try VoiceNoteStore.shared.addAssistantNote(id: id, text: text)
            result = ["id": id.uuidString, "saved": true] as [String: Any]
        case "day_plan":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            let requested = arguments["date"] as? String ?? "today"
            let text = AssistantLocalDay.key(requested)
            guard let day = formatter.date(from: text), formatter.string(from: day) == text else {
                throw AssistantFailure(message: "Use a date in YYYY-MM-DD format.")
            }
            let store = OccurrenceStore.shared
            guard let computed = store.lastComputed else {
                throw AssistantFailure(message: "The day plan has not loaded yet. Open Plan and try again.")
            }
            let today = Calendar.current.startOfDay(for: Date())
            guard let end = Calendar.current.date(byAdding: .day, value: store.horizonDays, to: today), day >= today, day < end else {
                throw AssistantFailure(message: "The available day plan covers today and the next \(store.horizonDays - 1) days.")
            }
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day)!
            // Include events that started yesterday and continue into this day (overnight
            // flights, shifts), using the same interval rules as the calendar grid.
            let items = store.planningWindow(from: day, to: dayEnd)
            result = ["date": text, "timeZone": TimeZone.current.identifier, "items": items.prefix(20).map { item in
                ["title": item.title, "start": item.start.ISO8601Format(), "end": item.end?.ISO8601Format() ?? "",
                 "kind": item.behavior.rawValue, "hasScheduledTime": item.hasScheduledTime,
                 "startTimeZone": item.meeting?.startTimeZone ?? "", "endTimeZone": item.meeting?.endTimeZone ?? ""] as [String: Any]
            }, "hasMore": items.count > 20, "updatedAt": computed.ISO8601Format(),
                "sampleData": AppSupport.isPiSampleWorkspace] as [String: Any]
        default: throw AssistantFailure(message: "That app action is not supported.")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }
}

#endif
