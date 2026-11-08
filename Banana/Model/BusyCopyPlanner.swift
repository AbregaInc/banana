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
        /// What the copy says once written, as Google stores it (`GoogleBusyBlocks.content`).
        var content: String? = nil
    }

    /// A copy Google says Banana owns on this calendar.
    struct Owned: Equatable {
        let eventID: String
        let etag: String
        let end: Date
        /// What the copy says on the server now, in the same terms as `Desired.content`. Nil when
        /// unknown: then only this device's own record can show it is unchanged.
        var content: String? = nil
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

    /// A wanted copy that already says what this pass would write, whoever wrote it.
    struct Match: Equatable {
        let index: Int
        let eventID: String
        let etag: String
    }

    struct CalendarPlan: Equatable {
        var writes: [Write] = []
        /// Copies already as wanted: nothing is written, the ledger only learns their version.
        var matches: [Match] = []
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
            let copy = copies.first { $0.eventID == keep }
            let etag = copy?.etag
            // What the server holds decides, not who wrote it: a copy another device wrote with the
            // same content is left alone. Comparing versions instead had every device rewrite
            // whatever another had just written, each write changing the version again — forever,
            // as long as two devices were running.
            if let have = copy?.content, let want = block.content {
                if have == want {
                    if let etag { plan.matches.append(Match(index: index, eventID: keep, etag: etag)) }
                    continue
                }
                plan.writes.append(.update(index: index, eventID: keep, etag: etag))
                continue
            }
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

/// Writes the service refused as a conflict ("an earlier operation on this item is still
/// unresolved", "ownership changed"), held back until something could have changed the answer.
///
/// A refusal is not cleared by asking again: one iPad sent the same few dozen refused writes on
/// every pass, about twelve seconds of requests each time, every time any calendar changed. The
/// same write is tried again once the copy on the server has changed, the write itself has changed,
/// or `quiet` has passed.
struct BusyCopyRefusals {
    static let quiet: TimeInterval = 30 * 60

    private struct Refusal {
        let fingerprint: Int
        let etag: String?
        let at: Date
    }

    private var refused: [String: Refusal] = [:]

    /// Whether to skip writing `fingerprint` over the copy at `etag` (nil: no copy yet) now.
    func holds(_ key: String, fingerprint: Int, etag: String?, now: Date) -> Bool {
        guard let refusal = refused[key] else { return false }
        return refusal.fingerprint == fingerprint && refusal.etag == etag
            && now.timeIntervalSince(refusal.at) < Self.quiet
    }

    mutating func refuse(_ key: String, fingerprint: Int, etag: String?, now: Date) {
        refused[key] = Refusal(fingerprint: fingerprint, etag: etag, at: now)
    }

    mutating func clear(_ key: String) {
        refused[key] = nil
    }

    /// Statuses that are an answer about this write, not a passing failure.
    static func isRefusal(status: Int) -> Bool {
        status == 409 || status == 428
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
