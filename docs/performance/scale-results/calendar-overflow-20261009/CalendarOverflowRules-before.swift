import Foundation

/// A display-only grouping. The caller supplies IDs omitted by its lane cap;
/// every omitted event must remain reachable through one of these groups.
enum CalendarOverflowRules {
    struct Item {
        let id: String
        let start: Date
        let end: Date
        let title: String
    }
    struct Group {
        let start: Date
        let hidden: Int
        let itemIDs: [String]
    }
    static func groups(_ items: [Item], hiddenIDs: Set<String>, visibleLaneLimit: Int = 3,
                       calendar: Calendar = .current) -> [Group] {
        let byStart = Dictionary(grouping: items) {
            calendar.date(bySetting: .second, value: 0, of: $0.start) ?? $0.start
        }
        return byStart.filter { $0.value.count > visibleLaneLimit }.map { start, items in
            Group(start:start,hidden:items.count-visibleLaneLimit,itemIDs:items.sorted { $0.title < $1.title }.map(\.id))
        }.sorted { $0.start < $1.start }
    }
}
