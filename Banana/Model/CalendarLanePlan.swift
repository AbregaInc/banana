import Foundation

/// Width-independent overlap layout. Input indices address the immutable day snapshot, so a
/// plan cannot accidentally retain stale titles, completion state or pending-write state.
/// Production keeps the result with that snapshot, never in a process-wide ID-only cache.
enum CalendarLanePlan {
    struct Interval: Sendable {
        let id: String
        let start: Date
        let end: Date
    }
    struct Placement: Equatable, Sendable {
        let index: Int
        let lane: Int
        var laneCount: Int
        var laneSpan: Int = 1
    }

    /// Preserve the calendar's displayed-minute convention, including the strict boundary:
    /// a 59-second overlap shares a lane; a 60-second overlap does not.
    static func make(_ intervals: [Interval]) -> [Placement] {
        let sorted = intervals.indices.sorted {
            let a = intervals[$0], b = intervals[$1]
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.id < b.id
        }
        var result: [Placement] = []
        result.reserveCapacity(intervals.count)
        var laneEnds: [Date] = []
        var clusterStart = 0
        var clusterEnd = Date.distantPast
        func finishCluster() {
            let cluster = clusterStart..<result.count
            var lanes = Array(repeating: [(start: Date, maxEnd: Date)](), count: laneEnds.count)
            for index in cluster {
                let placement = result[index], item = intervals[placement.index]
                let previous = lanes[placement.lane].last?.maxEnd ?? .distantPast
                lanes[placement.lane].append((item.start, max(previous, item.end)))
            }
            for index in cluster {
                result[index].laneCount = laneEnds.count
                let placement = result[index], item = intervals[placement.index]
                // A lane's prefix maximum answers whether any interval overlaps, including
                // short/nested inputs, without rescanning the entire overlap cluster.
                for lane in (placement.lane + 1)..<laneEnds.count {
                    let candidates = lanes[lane]
                    var low = 0, high = candidates.count
                    while low < high {
                        let middle = (low + high) / 2
                        if item.end.timeIntervalSince(candidates[middle].start) >= 60 { low = middle + 1 }
                        else { high = middle }
                    }
                    if low > 0, candidates[low - 1].maxEnd.timeIntervalSince(item.start) >= 60 { break }
                    result[index].laneSpan += 1
                }
            }
        }
        for index in sorted {
            let item = intervals[index]
            if !laneEnds.isEmpty, clusterEnd.timeIntervalSince(item.start) < 60 {
                finishCluster()
                clusterStart = result.count
                laneEnds.removeAll(keepingCapacity: true)
                clusterEnd = .distantPast
            }
            let lane = laneEnds.firstIndex { $0.timeIntervalSince(item.start) < 60 } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(item.end) }
            else { laneEnds[lane] = item.end }
            result.append(Placement(index: index, lane: lane, laneCount: 1))
            clusterEnd = max(clusterEnd, item.end)
        }
        finishCluster()
        return result
    }
}
