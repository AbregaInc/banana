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
        /// The source events it stands for (`GoogleBusyBlocks.sourceKey`).
        var sources: Set<String> = []
        /// What the copy is derived from (`GoogleBusyBlocks.inputsHash`), stamped on it when
        /// written: the source event and its times, the place, the trip's origin and mode — never
        /// the computed minutes. Nil: a planner run that doesn't stamp.
        var inputs: String? = nil
        /// A travel block: its times come from a route estimate that moves with traffic, so a
        /// copy with the same inputs is only refreshed by `CopyRefresh`'s rule.
        var refreshable = false
        var start: Date? = nil
        var end: Date? = nil
    }

    /// A copy Google says Banana owns on this calendar.
    struct Owned: Equatable {
        let eventID: String
        let etag: String
        let end: Date
        /// What the copy says on the server now, in the same terms as `Desired.content`. Nil when
        /// unknown: then only this device's own record can show it is unchanged.
        var content: String? = nil
        var start: Date? = nil
        /// The sources it names on the server; empty on a copy written before copies named them.
        var sources: Set<String> = []
        /// The inputs stamp it carries; nil on a copy written before copies were stamped.
        var inputs: String? = nil
        /// Google's own `updated` time for it: the server's clock, so devices' clocks don't matter.
        var updated: Date? = nil
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
        /// Travel blocks left as another pass (any device, this one included) wrote them, though
        /// this pass's estimate differs a little: `CopyRefresh` says they're fine.
        var held: [Match] = []
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
                // Says the same and names at least one of its sources: as wanted. A copy that names
                // none (written before copies named them) is rewritten once, so its readers can
                // trace it. Overlap rather than equality: two devices that see slightly different
                // sources must not rewrite each other's copy forever.
                let traced = block.sources.isEmpty || !(copy?.sources ?? []).isDisjoint(with: block.sources)
                if have == want, traced {
                    if let etag { plan.matches.append(Match(index: index, eventID: keep, etag: etag)) }
                    continue
                }
                if let copy, traced, CopyRefresh.leaves(copy, as: block, now: now) {
                    if let etag { plan.held.append(Match(index: index, eventID: keep, etag: etag)) }
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

/// When a travel block that already exists is left as it is, though this pass would write it a
/// little differently. Every device plans travel from its own route estimate, and estimates differ
/// by a few minutes from device to device and from minute to minute. Rewriting on every difference
/// had two devices rewrite each other's blocks every few seconds, each write waking the others.
///
/// - What the block is derived from changed (`inputs`: the meeting moved, the place or the origin
///   changed): write now, whoever wrote it. A stale block must never stay.
/// - Same inputs, only the computed times differ: leave it while it is younger than
///   `travelRefreshHold` by Google's `updated` (the server's clock), and after that unless an edge
///   moves by `refreshThreshold` or more. Traffic still updates a block, just not every minute.
/// - A block from a build that didn't stamp: left when only its times differ, by less than the
///   threshold (adopted; it is stamped at its next real update), written otherwise.
///
/// Busy copies of events and task blocks are never `refreshable`: any difference is written.
enum CopyRefresh {
    static let travelRefreshHold: TimeInterval = 60 * 60
    static let refreshThreshold: TimeInterval = 5 * 60

    static func leaves(_ copy: BusyCopyPlanner.Owned, as block: BusyCopyPlanner.Desired, now: Date) -> Bool {
        guard block.refreshable, let start = block.start, let end = block.end,
              let haveStart = copy.start, let want = block.content, let have = copy.content,
              sameExceptTimes(have, want) else { return false }
        let moved = max(abs(haveStart.timeIntervalSince(start)), abs(copy.end.timeIntervalSince(end)))
        guard let stamped = copy.inputs else {
            // Unstamped: nothing says what it was derived from, so only its times can.
            return moved < refreshThreshold
        }
        guard stamped == block.inputs else { return false }
        if let updated = copy.updated {
            let age = now.timeIntervalSince(updated)
            if age < travelRefreshHold { return true }
        }
        return moved < refreshThreshold
    }

    /// Whether two `GoogleBusyBlocks.content` strings agree on everything but the times.
    private static func sameExceptTimes(_ a: String, _ b: String) -> Bool {
        // Title and form, the first two fields; no splitting, this runs for every differing copy.
        func head(_ s: String) -> Substring? {
            guard let first = s.firstIndex(of: "\u{1F}"),
                  let second = s[s.index(after: first)...].firstIndex(of: "\u{1F}") else { return nil }
            return s[..<second]
        }
        guard let x = head(a), let y = head(b) else { return false }
        return x == y
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
