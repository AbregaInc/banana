import Foundation

/// How many instances of a repeating reminder were missed before the one it stands at now.
///
/// When a missed instance rolls over (`ReminderRollover`), Banana moves the reminder on to the
/// current one in Reminders without completing anything: so Reminders rings today's, and nothing
/// says yesterday's was done. Reminders then has no trace of the miss, so Banana keeps it, for
/// "Missed yesterday" on today's. By the reminder's stable id with its title as a second key (as
/// `ReminderAnchors`), on the day it stands at: a tick moves the reminder on and the count lapses.
/// In iCloud key-value storage, so the Mac says what the phone moved.
@MainActor
final class MissedRepeats {
    static let shared = MissedRepeats()

    private static let key = "missedRepeats.v1"
    private var store: LegacyKVS { .shared }

    /// Read afresh each time: the Mac's answer changes when the phone moves a reminder on.
    private var entries: [String: Ledger.Entry] {
        Ledger.decode(store.dictionary(forKey: Self.key) ?? UserDefaults.standard.dictionary(forKey: Self.key))
    }

    /// Missed before the instance on `day`, if any were.
    func count(externalID: String?, title: String, on day: Date) -> Int? {
        Ledger.count(entries, keys: Ledger.keys(externalID: externalID, title: title), on: day)
    }

    /// `count` missed before the instance due at `due`; nil forgets it (an Undo).
    func record(_ count: Int?, standingAt due: Date, externalID: String?, title: String, now: Date = Date()) {
        var next = Ledger.pruned(entries, now: now)
        let keys = Ledger.keys(externalID: externalID, title: title)
        for key in keys {
            next[key] = count.map { Ledger.Entry(due: due, count: $0) }
        }
        let plist = Ledger.encode(next)
        store.set(plist, forKey: Self.key)
        UserDefaults.standard.set(plist, forKey: Self.key)
        // One record per key on the data platform; entries pruned for their age are only gone here.
        if count == nil { SyncReport.deleted(Self.syncType, keys) } else { SyncReport.changed(Self.syncType, keys) }
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `KeyValueAdapters`)

    static let syncType = "plan.missedRepeat"

    /// An entry as it travels.
    struct SyncedEntry: Codable, Equatable {
        var due: Date
        var count: Int
    }

    var syncEntries: [String: SyncedEntry] { entries.mapValues { SyncedEntry(due: $0.due, count: $0.count) } }

    /// Other devices' entries (nil: forgotten there), kept the usual way.
    func applySynced(_ changes: [String: SyncedEntry?]) {
        var next = entries
        for (key, entry) in changes { next[key] = entry.map { Ledger.Entry(due: $0.due, count: $0.count) } }
        let plist = Ledger.encode(next)
        store.set(plist, forKey: Self.key)
        UserDefaults.standard.set(plist, forKey: Self.key)
    }

    /// The pure part, for tests.
    enum Ledger {
        struct Entry: Equatable {
            var due: Date
            var count: Int
        }

        static func keys(externalID: String?, title: String) -> [String] {
            [externalID.map { "id:" + $0 }, "title:" + title.lowercased()].compactMap { $0 }
        }

        /// The first key's count, when its entry stands on `day`.
        static func count(_ entries: [String: Entry], keys: [String], on day: Date,
                          calendar: Calendar = .current) -> Int? {
            for key in keys {
                guard let entry = entries[key] else { continue }
                return calendar.isDate(entry.due, inSameDayAs: day) ? entry.count : nil
            }
            return nil
        }

        /// Entries a few weeks past their day say nothing any more.
        static func pruned(_ entries: [String: Entry], now: Date) -> [String: Entry] {
            entries.filter { $0.value.due > now.addingTimeInterval(-40 * 86_400) }
        }

        static func encode(_ entries: [String: Entry]) -> [String: Any] {
            entries.mapValues { ["due": $0.due.timeIntervalSinceReferenceDate, "count": $0.count] }
        }

        /// Tolerant: one entry a newer build wrote can't cost the rest.
        static func decode(_ plist: [String: Any]?) -> [String: Entry] {
            var entries: [String: Entry] = [:]
            for (key, value) in plist ?? [:] {
                guard let fields = value as? [String: Any], let due = fields["due"] as? Double,
                      let count = fields["count"] as? Int else { continue }
                entries[key] = Entry(due: Date(timeIntervalSinceReferenceDate: due), count: count)
            }
            return entries
        }
    }
}
