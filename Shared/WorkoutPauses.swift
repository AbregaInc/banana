import Foundation

/// A stretch of a workout that was paused: seconds since the session's start, by the clock.
struct FitnessPause: Codable, Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var duration: TimeInterval { max(0, end - start) }
}

/// The rules of a paused workout, shared by the Watch that records it and the devices that show
/// it. A pause takes its stretch out of the workout's time: the clock on the Watch stops, nothing
/// is recorded, and the time shown afterwards (and in Apple Health) leaves it out. The samples
/// keep their real clock times, so a pause is a gap in the charts, not a splice.
enum WorkoutPauses {
    static func pausedSeconds(_ pauses: [FitnessPause]) -> TimeInterval {
        pauses.reduce(0) { $0 + $1.duration }
    }

    /// Time spent working out by `wall` seconds after the start: the clock time less every
    /// finished pause, and frozen at the moment an open pause began.
    static func activeElapsed(wall: TimeInterval, pauses: [FitnessPause], openSince: TimeInterval?) -> TimeInterval {
        let upTo = min(wall, openSince ?? wall)
        let paused = pauses.reduce(0.0) { $0 + max(0, min($1.end, upTo) - min($1.start, upTo)) }
        return max(0, upTo - paused)
    }

    /// The pauses as saved with the workout: an open one closed where the workout ended, each
    /// kept inside the workout, in order, overlapping ones joined, empty ones dropped.
    static func closed(_ pauses: [FitnessPause], openSince: TimeInterval?, at end: TimeInterval) -> [FitnessPause] {
        var all = pauses
        if let openSince { all.append(FitnessPause(start: openSince, end: end)) }
        let clipped = all
            .map { FitnessPause(start: max(0, min($0.start, end)), end: max(0, min($0.end, end))) }
            .filter { $0.duration > 0.5 }
            .sorted { $0.start < $1.start }
        var joined: [FitnessPause] = []
        for pause in clipped {
            if let last = joined.last, pause.start <= last.end {
                joined[joined.count - 1].end = max(last.end, pause.end)
            } else {
                joined.append(pause)
            }
        }
        return joined
    }

    /// After a trim to `startOffset...endOffset`: what's left of each pause inside the kept
    /// stretch, counted from its new start.
    static func kept(_ pauses: [FitnessPause], startOffset: TimeInterval, endOffset: TimeInterval) -> [FitnessPause] {
        closed(pauses.compactMap { pause in
            let start = max(pause.start, startOffset), end = min(pause.end, endOffset)
            return end > start ? FitnessPause(start: start - startOffset, end: end - startOffset) : nil
        }, openSince: nil, at: max(0, endOffset - startOffset))
    }

    /// As the Watch sends them with a workout's file: start, end, start, end…
    static func flat(_ pauses: [FitnessPause]) -> [Double] {
        pauses.flatMap { [$0.start, $0.end] }
    }

    static func fromFlat(_ values: [Double]) -> [FitnessPause] {
        stride(from: 0, to: values.count - 1, by: 2).compactMap { index in
            values[index + 1] > values[index] ? FitnessPause(start: values[index], end: values[index + 1]) : nil
        }
    }
}
