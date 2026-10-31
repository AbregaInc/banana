import Foundation

enum RoutineOccurrenceOverride: Codable, Hashable, Sendable {
    case skip
    case reschedule(Date)
    case completed(at: Date, scheduledStart: Date?)

    static func settingCompleted(_ completed: Bool, at: Date, previous: Self?) -> Self? {
        let booked: Date?
        switch previous {
        case .reschedule(let date), .completed(_, .some(let date)): booked = date
        default: booked = nil
        }
        return completed ? .completed(at: at, scheduledStart: booked) : booked.map(Self.reschedule)
    }
}

enum WorkoutRoutineCompletion {
    static func updates(startedAt: Date, day: String, routineIDs: [UUID], overrides: [String: RoutineOccurrenceOverride]) -> [String: RoutineOccurrenceOverride] {
        var updates: [String: RoutineOccurrenceOverride] = [:]
        for routineID in routineIDs {
            let key = "\(routineID.uuidString)|main|\(day)"
            if case .completed? = overrides[key] { continue }
            let scheduledStart: Date?
            if case .reschedule(let moved)? = overrides[key] { scheduledStart = moved } else { scheduledStart = nil }
            updates[key] = .completed(at: startedAt, scheduledStart: scheduledStart)
        }
        return updates
    }
}
