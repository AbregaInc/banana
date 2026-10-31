import Foundation

/// Wall-clock countdown: view redraws and workout pauses must not slow down a rest interval.
enum WorkoutRestTimer {
    static func remaining(until deadline: Date?, now: Date = Date()) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
}
