import Foundation

/// Application capabilities. Pi owns tool admission, argument validation and replay policy.
@MainActor
enum AssistantCapabilities {
    static func execute(_ request: String) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
              let name = value["name"] as? String, let arguments = value["arguments"] as? [String: Any] else {
            throw AssistantFailure(message: "The assistant sent an invalid app action.")
        }
        let result: Any
        switch name {
        case "list_notes":
            let limit = arguments["limit"] as? Int ?? 5
            guard (1...10).contains(limit) else { throw AssistantFailure(message: "Request between one and ten notes.") }
            let notes = VoiceNoteStore.shared.matchingNotes(search: "", archived: false)
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
