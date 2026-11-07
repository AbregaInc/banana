import Foundation

/// What one write-back pass does to Banana's Busy copies on one Google calendar: which wanted
/// copies are created, which owned copies are rewritten, which extra copies of a wanted block go,
/// and which owned copies are no longer wanted.
///
/// One planner for the pass that writes (`CalendarWriteBack.reconcile`) and for the preview the
/// first run shows before anyone says yes (`CalendarWriteBack.previewCopies`). The numbers on the
/// consent screen are this plan's, never a count made up beside it (a calendar was once flooded
/// with hundreds of copies nobody had been shown).
enum BusyCopyPlanner {
    /// A copy the pass wants on this calendar.
    struct Desired: Equatable {
        let appItemID: String
        /// The ledger's key for this copy on this calendar.
        let ledgerKey: String
        /// A stable fingerprint of what would be written (title, times, calendar).
        let fingerprint: Int
    }

    /// A copy Google says Banana owns on this calendar.
    struct Owned: Equatable {
        let eventID: String
        let etag: String
        let end: Date
    }

    /// What this device last wrote for a ledger key.
    struct Recorded: Equatable {
        let eventID: String
        let fingerprint: Int
        let etag: String?
    }

    enum Write: Equatable {
        /// `desired[index]` is not on the calendar: create it.
        case create(index: Int)
        /// `desired[index]` is there as `eventID` but differs from what was last written.
        case update(index: Int, eventID: String, etag: String?)
    }

    struct CalendarPlan: Equatable {
        var writes: [Write] = []
        /// Extra copies of a wanted block (two devices wrote it at once): every device keeps the
        /// same one (`BusyBlockDuplicates.copyToKeep`) and removes the rest.
        var duplicates: [Owned] = []
        /// Owned copies of blocks no longer wanted, current or future only, by app item.
        /// Removing them still waits for `BlockRemovalGate` and `MassRemovalGuard`.
        var unwanted: [String: [Owned]] = [:]

        var creates: Int { writes.filter { if case .create = $0 { true } else { false } }.count }
        var updates: Int { writes.count - creates }
        var removals: Int { duplicates.count + unwanted.values.reduce(0) { $0 + $1.count } }
    }

    static func plan(desired: [Desired], owned: [String: [Owned]], recorded: [String: Recorded],
                     now: Date) -> CalendarPlan {
        var plan = CalendarPlan()
        var stillWanted = Set<String>()
        for (index, block) in desired.enumerated() {
            stillWanted.insert(block.appItemID)
            let copies = owned[block.appItemID] ?? []
            let keep = BusyBlockDuplicates.copyToKeep(copies.map(\.eventID))
            plan.duplicates += copies.filter { $0.eventID != keep }
            guard let keep else {
                plan.writes.append(.create(index: index))
                continue
            }
            let etag = copies.first { $0.eventID == keep }?.etag
            let last = recorded[block.ledgerKey]
            if last?.fingerprint == block.fingerprint, last?.eventID == keep, last?.etag == etag { continue }
            plan.writes.append(.update(index: index, eventID: keep, etag: etag))
        }
        for (itemID, copies) in owned where !stillWanted.contains(itemID) {
            // A block that is over protects nothing and costs nothing; removing it is churn.
            let current = copies.filter { $0.end > now }
            if !current.isEmpty { plan.unwanted[itemID] = current }
        }
        return plan
    }
}

/// The consent screen's numbers: the plan for every calendar Banana would write to, summed, with
/// the names on both ends and the dates the copies cover.
struct BusyCopyPreview: Equatable {
    struct Destination: Equatable, Identifiable {
        let id: String
        let title: String
        var creates = 0
        var updates = 0
        var removals = 0
    }

    var destinations: [Destination]
    /// The calendars the copies come from, by name.
    var sources: [String]
    /// First and last moment a created or rewritten copy covers.
    var start: Date?
    var end: Date?

    var creates: Int { destinations.reduce(0) { $0 + $1.creates } }
    var updates: Int { destinations.reduce(0) { $0 + $1.updates } }
    var removals: Int { destinations.reduce(0) { $0 + $1.removals } }
    /// Destinations that would change, by name.
    var changing: [Destination] { destinations.filter { $0.creates + $0.updates + $0.removals > 0 } }

    /// Whether a yes would still do what this preview showed: the same calendars, the same
    /// counts. Anything else is shown again before it is applied.
    func agrees(with fresh: BusyCopyPreview) -> Bool {
        destinations == fresh.destinations && creates == fresh.creates
    }
}
