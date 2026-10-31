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
    static func groups(_ items: [Item], hiddenIDs: Set<String>,
                       calendar: Calendar = .current) -> [Group] {
        guard !hiddenIDs.isEmpty else { return [] }
        let sorted = items.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id < $1.id
        }
        var result: [Group] = []
        var cluster: [Item] = []
        var clusterEnd = Date.distantPast
        func appendCluster() {
            let hidden = cluster.filter { hiddenIDs.contains($0.id) }
            guard let first = hidden.first else { return }
            let start = calendar.date(bySetting: .second, value: 0, of: first.start) ?? first.start
            result.append(Group(start: start, hidden: hidden.count, itemIDs: cluster.map(\.id)))
        }
        for item in sorted {
            // Match CalendarLaneAllocator's displayed-minute overlap rule.
            if !cluster.isEmpty, clusterEnd.timeIntervalSince(item.start) < 60 {
                appendCluster()
                cluster.removeAll(keepingCapacity: true)
                clusterEnd = .distantPast
            }
            cluster.append(item)
            clusterEnd = max(clusterEnd, item.end)
        }
        appendCluster()
        return result
    }
}
