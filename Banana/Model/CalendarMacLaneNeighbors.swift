import Foundation

/// The Mac grid joins an event to the next original start in its lane, but leaves enough room
/// for the earliest *displayed* start of any later event. An optimistic move can reorder those
/// displayed starts. Results follow placement order, including repeated occurrence IDs.
enum CalendarMacLaneNeighbors {
    struct Input {
        let lane: Int
        let start: Date
        let end: Date
        let displayedStart: Date
    }

    struct Result: Equatable {
        let visualEnd: Date
        let nextDisplayedStart: Date?
    }

    static func make(_ inputs: [Input]) -> [Result] {
        var result = inputs.map { Result(visualEnd: $0.end, nextDisplayedStart: nil) }
        for lane in Dictionary(grouping: inputs.indices, by: { inputs[$0].lane }).values {
            let order = lane.sorted { inputs[$0].start < inputs[$1].start }
            var nextDisplayedStart: Date?
            var end = order.count
            while end > 0 {
                var begin = end - 1
                let start = inputs[order[begin]].start
                while begin > 0, inputs[order[begin - 1]].start == start { begin -= 1 }
                let group = order[begin..<end]
                for index in group {
                    let originalEnd = inputs[index].end
                    var low = 0, high = order.count
                    while low < high {
                        let mid = low + (high - low) / 2
                        if inputs[order[mid]].start < originalEnd { low = mid + 1 } else { high = mid }
                    }
                    let next = low < order.count ? inputs[order[low]].start : nil
                    let visualEnd = next.flatMap { $0.timeIntervalSince(originalEnd) <= 300 ? $0 : nil } ?? originalEnd
                    result[index] = Result(visualEnd: visualEnd, nextDisplayedStart: nextDisplayedStart)
                }
                for index in group {
                    let displayed = inputs[index].displayedStart
                    nextDisplayedStart = min(nextDisplayedStart ?? displayed, displayed)
                }
                end = begin
            }
        }
        return result
    }
}
