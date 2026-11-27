import Foundation
import CoreGraphics

/// For each event, the greatest bottom of a different, earlier displayed event in its lane.
/// Equal displayed starts are simultaneous. Distinct source placements can share an ID.
enum CalendarTravelBandFloors {
    struct Input {
        let id: String
        let lane: Int
        let start: Date
        let bottom: CGFloat
    }

    static func make(_ rows: [Input]) -> [CGFloat?] {
        var result = [CGFloat?](repeating: nil, count: rows.count)
        for lane in Dictionary(grouping: rows.indices, by: { rows[$0].lane }).values {
            let order = lane.sorted { rows[$0].start < rows[$1].start }
            var highest: Input?, second: Input?
            var begin = 0
            while begin < order.count {
                let start = rows[order[begin]].start
                var end = begin + 1
                while end < order.count, rows[order[end]].start == start { end += 1 }
                for index in order[begin..<end] {
                    result[index] = rows[index].id == highest?.id ? second?.bottom : highest?.bottom
                }
                for index in order[begin..<end] {
                    let row = rows[index]
                    if highest == nil || row.bottom > highest!.bottom {
                        if row.id != highest?.id { second = highest }
                        highest = row
                    } else if row.id != highest?.id, second == nil || row.bottom > second!.bottom {
                        second = row
                    }
                }
                begin = end
            }
        }
        return result
    }
}
