import Foundation

/// Bringing a cached display window up to date from a fresher read that covered only part of it.
///
/// The Day and Week grids draw from windows cached per range, and the timeline's own read of
/// Google is newer whenever it runs. Within the days that read covered, its copy replaces the
/// window's; outside them the window keeps what it had. Pure, so the rule is tested
/// (`PlanningWindowSliceTests`).
enum PlanningWindowSlice {
    /// `cached` with everything that touches `lo..<hi` swapped for `fresh`'s items there.
    /// An item with no end counts as a moment; one that straddles the edge belongs to the read.
    static func replacing<Item>(_ cached: [Item], with fresh: [Item], from lo: Date, to hi: Date,
                                span: (Item) -> (start: Date, end: Date?)) -> [Item] {
        func touches(_ item: Item) -> Bool {
            let (start, end) = span(item)
            return start < hi && max(end ?? start, start.addingTimeInterval(1)) > lo
        }
        return cached.filter { !touches($0) } + fresh.filter { touches($0) }
    }

    /// A read that couldn't reach every calendar says nothing about the ones it missed, so what
    /// is already shown from those calendars stays — the rule the timeline follows
    /// (`GoogleEventSync.keepsThroughIncompleteRead`), which the windows didn't. An iPad whose
    /// sign-in stalled for two accounts rebuilt its week from the rest: their events were on its
    /// timeline and gone from its calendar, back for a moment whenever something else redrew it.
    ///
    /// `fresh` plus, when the read was incomplete, everything in `known` (the window as it was,
    /// and the timeline) from a calendar the read didn't cover that lies in `lo..<hi`, each once.
    static func keepingUncovered<Item>(_ fresh: [Item], known: [Item], complete: Bool, covered: Set<String>,
                                       from lo: Date, to hi: Date,
                                       calendarID: (Item) -> String?, id: (Item) -> String?,
                                       span: (Item) -> (start: Date, end: Date?)) -> [Item] {
        guard !complete else { return fresh }
        var seen = Set(fresh.compactMap(id))
        var kept: [Item] = []
        for item in known {
            guard let calendar = calendarID(item), !covered.contains(calendar) else { continue }
            let (start, end) = span(item)
            guard (end ?? start) > lo, start < hi else { continue }
            if let key = id(item), !seen.insert(key).inserted { continue }
            kept.append(item)
        }
        return fresh + kept
    }
}
