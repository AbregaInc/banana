#if !BANANA_PUBLIC
import Foundation

/// Account-local accounting for positive deletion evidence, never listing absence.
enum MailRemovalRules {
    struct Hour: Codable, Equatable, Sendable {
        var hour: Int64
        var count: Int
    }
    struct Decision: Equatable, Sendable {
        var hold: Bool
        var history: [Hour]
    }
    enum Failure: Error { case invalidCounts }

    static func decide(removals: Int, cachedMessages: Int, previous: [Hour],
                       hasUnresolvedHold: Bool, nowMS: Int64) throws -> Decision {
        guard removals >= 0, cachedMessages >= 0, removals <= cachedMessages, nowMS >= 0 else {
            throw Failure.invalidCounts
        }
        let current = nowMS / 3_600_000
        var hours: [Int64: Int] = [:]
        for entry in previous {
            guard entry.hour >= 0, entry.count >= 0 else { throw Failure.invalidCounts }
            // Retain the boundary hour conservatively: part of it can still be less
            // than 24 hours old. Future buckets survive a backwards wall-clock jump.
            guard entry.hour >= current - 24 else { continue }
            let (count, overflow) = hours[entry.hour, default: 0].addingReportingOverflow(entry.count)
            guard !overflow else { throw Failure.invalidCounts }
            hours[entry.hour] = count
        }
        var total = removals
        for count in hours.values {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { throw Failure.invalidCounts }
            total = next
        }
        let hold = hasUnresolvedHold || (total >= 20 && total > cachedMessages / 3)
        if !hold && removals > 0 {
            let (count, overflow) = hours[current, default: 0].addingReportingOverflow(removals)
            guard !overflow else { throw Failure.invalidCounts }
            hours[current] = count
        }
        return Decision(hold: hold, history: hours.filter { $0.value > 0 }
            .map { Hour(hour: $0.key, count: $0.value) }.sorted { $0.hour < $1.hour })
    }
}

#endif
