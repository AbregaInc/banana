import Foundation

/// Items whose removal waits on an Undo (`ToastCenter.hiddenIDs`) — a deleted event, a declined
/// invitation — are left out of what's drawn until the change is sent or undone. Pure, for tests.
///
/// An entry is an item's own id, or a whole series (`seriesToken`): deleting every event of a
/// repeating one, or this one and the rest, takes all of them off the day at once — not just the
/// occurrence the delete was made from.
enum PendingRemovals {
    private static let seriesPrefix = "series|"

    /// `items` without those waiting to be removed.
    static func visible<T>(_ items: [T], id: (T) -> String?, hiding hidden: Set<String>) -> [T] {
        guard !hidden.isEmpty else { return items }
        return items.filter { item in id(item).map { !hidden.contains($0) } ?? true }
    }

    /// `items` without those waiting to be removed, a series' occurrences included.
    static func visible<T>(_ items: [T], id: (T) -> String?, start: (T) -> Date, hiding hidden: Set<String>) -> [T] {
        guard !hidden.isEmpty else { return items }
        return items.filter { !isHidden(eventID: id($0), start: start($0), hidden: hidden) }
    }

    /// The entry that hides every occurrence of the series `eventInfoID` belongs to — from
    /// `from` on when given (\"this and following\"), else all of it. Nil for an id that isn't a
    /// Google event's.
    static func seriesToken(eventInfoID: String, from cutoff: Date?) -> String? {
        guard let route = GoogleCalendarIDs.rawEventRoute(from: eventInfoID) else { return nil }
        let master = masterID(route.eventID)
        let from = cutoff.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return [seriesPrefix + route.calendarID, master, from].joined(separator: "|")
    }

    static func isHidden(eventID: String?, start: Date, hidden: Set<String>) -> Bool {
        guard let eventID, !hidden.isEmpty else { return false }
        if hidden.contains(eventID) { return true }
        let series = hidden.filter { $0.hasPrefix(seriesPrefix) }
        guard !series.isEmpty, let route = GoogleCalendarIDs.rawEventRoute(from: eventID) else { return false }
        let master = masterID(route.eventID)
        return series.contains { token in
            let parts = token.dropFirst(seriesPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == Substring(route.calendarID), parts[1] == Substring(master) else {
                return false
            }
            guard let from = Double(parts[2]) else { return true }
            return start.timeIntervalSince1970 >= from - 1
        }
    }

    /// A Google occurrence's id is its series' id, \"_\", and its start.
    private static func masterID(_ eventID: String) -> String {
        eventID.split(separator: "_", maxSplits: 1).first.map(String.init) ?? eventID
    }
}

extension CalendarEditSpan {
    /// What to take off the day while a delete of this span waits on its Undo: the one event, or
    /// its series from it on, or all of its series.
    func hiding(_ eventInfoID: String, start: Date) -> String {
        switch self {
        case .thisEvent: return eventInfoID
        case .futureEvents: return PendingRemovals.seriesToken(eventInfoID: eventInfoID, from: start) ?? eventInfoID
        case .allEvents: return PendingRemovals.seriesToken(eventInfoID: eventInfoID, from: nil) ?? eventInfoID
        }
    }
}

/// What a delete took out of a list, and where from, so Undo can put it back exactly: the same
/// item (its id and everything in it) at the same place. Pure, for tests.
struct Removed<Item> {
    let item: Item
    let index: Int
}

extension Array {
    /// Takes out the first item that matches, remembering where it was.
    mutating func take(where matches: (Element) -> Bool) -> Removed<Element>? {
        guard let index = firstIndex(where: matches) else { return nil }
        return Removed(item: remove(at: index), index: index)
    }
}

extension Array where Element: Identifiable {
    /// Puts back what `take` took, where it was. A copy with its id that arrived meanwhile
    /// (from another device) is replaced, not doubled.
    mutating func putBack(_ removed: Removed<Element>) {
        removeAll { $0.id == removed.item.id }
        insert(removed.item, at: Swift.min(Swift.max(removed.index, 0), count))
    }
}
