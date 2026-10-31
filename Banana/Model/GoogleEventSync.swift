import Foundation

/// Incremental Google Calendar reads, as pure rules.
///
/// The first read of a calendar lists every event in the core window and ends with a sync
/// token; after that, a read sends the token and gets back only what changed — usually nothing,
/// in one small response instead of thousands of events. The rules that keep that honest:
///
/// - **When to start over.** A cached copy is only continued while it describes the same
///   window. The core window slides a day at a time, and events that were beyond its old end
///   were never listed, so a new day means a full read. So does a missing token, a day-old
///   copy, and Google answering 410 (token expired).
/// - **How to apply changes.** By event id: a cancelled item removes the event, anything else
///   replaces or adds it. Changes can be for events outside the window; they are kept and
///   sliced away on use, like any read.
/// - **What counts as a change.** Banana's own writes come back as changes too. Treating those
///   as news would re-run the whole plan (and the write-back pass) after every write it made —
///   so ids Banana wrote recently are ignored when deciding whether anything happened.
enum GoogleEventSync {

    /// One calendar's cached read, as kept in memory and on disk.
    struct Snapshot: Codable, Equatable {
        let start: Date
        let end: Date
        var fetchedAt: Date
        /// When this copy was last read in full; incremental reads never move it.
        var fullReadAt: Date
        var syncToken: String?
        var events: [GoogleEvent]

        func covers(_ from: Date, _ to: Date) -> Bool { start <= from && end >= to }

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.start == b.start && a.end == b.end && a.fetchedAt == b.fetchedAt
                && a.fullReadAt == b.fullReadAt && a.syncToken == b.syncToken
                && fingerprint(a.events) == fingerprint(b.events)
        }
    }

    /// Whether a copy reaches into `from..<to` at all — enough for it to stand in for a read that
    /// failed (see `GoogleCalendarService.lastKnownGood`).
    static func overlaps(_ snapshot: Snapshot, _ from: Date, _ to: Date) -> Bool {
        snapshot.start < to && snapshot.end > from
    }

    /// Whether an event on screen should stay through an incomplete read: its calendar has no data
    /// in this read (failed, no saved copy reaching today), it's still inside the window, and the
    /// read didn't already bring a newer copy of it.
    static func keepsThroughIncompleteRead(calendarID: String?, covered: Set<String>, excluded: Set<String> = [], replaced: Bool,
                                           start: Date, end: Date?, window: (start: Date, end: Date)) -> Bool {
        guard let calendarID, !excluded.contains(calendarID), !covered.contains(calendarID), !replaced else { return false }
        return (end ?? start) > window.start && start < window.end
    }

    /// Whether the calendar list should be loaded again: there is none, it's older than its
    /// lifetime — or an account's list couldn't be read last time, which is asked again after
    /// half a minute, not after the ten the whole list lasts. Until it is read, that account's
    /// calendars are in no read at all.
    static func calendarListIsStale(loadedAt: Date?, isEmpty: Bool, someUnreadable: Bool, now: Date,
                                    lifetime: TimeInterval = 10 * 60, retry: TimeInterval = 30) -> Bool {
        guard let loadedAt, !isEmpty else { return true }
        return now.timeIntervalSince(loadedAt) > (someUnreadable ? retry : lifetime)
    }

    /// Longest a copy is continued incrementally before being read in full again anyway.
    static let fullReadLifetime: TimeInterval = 24 * 3600

    /// Whether `snapshot` can be brought up to date with its token, or must be read in full.
    static func canContinue(_ snapshot: Snapshot?, window: (start: Date, end: Date), now: Date) -> Bool {
        guard let snapshot, snapshot.syncToken?.isEmpty == false else { return false }
        return snapshot.start == window.start && snapshot.end == window.end
            && now.timeIntervalSince(snapshot.fullReadAt) < fullReadLifetime
            && now >= snapshot.fullReadAt
    }

    /// Apply an incremental read to the cached events.
    static func apply(_ changes: [GoogleEvent], to events: [GoogleEvent]) -> [GoogleEvent] {
        guard !changes.isEmpty else { return events }
        var byID: [String: GoogleEvent] = [:]
        var order: [String] = []
        var anonymous: [GoogleEvent] = []
        for event in events {
            guard let id = event.id else { anonymous.append(event); continue }
            if byID[id] == nil { order.append(id) }
            byID[id] = event
        }
        for change in changes {
            guard let id = change.id else { continue }
            if change.status == "cancelled" {
                byID[id] = nil
            } else {
                if byID[id] == nil { order.append(id) }
                byID[id] = change
            }
        }
        return anonymous + order.compactMap { byID[$0] }
    }

    /// Ids whose content differs between two reads (added, removed or modified).
    static func changedIDs(from old: [GoogleEvent], to new: [GoogleEvent]) -> Set<String> {
        let before = fingerprint(old)
        let after = fingerprint(new)
        var changed = Set<String>()
        for (id, stamp) in after where before[id] != stamp { changed.insert(id) }
        for id in before.keys where after[id] == nil { changed.insert(id) }
        return changed
    }

    /// Whether any of `ids` is something other than an echo of Banana's own recent writes.
    static func containsNews(_ ids: Set<String>, ownWrites: [String: Date], now: Date,
                             echoWindow: TimeInterval = 10 * 60) -> Bool {
        ids.contains { id in
            guard let wroteAt = GoogleOwnWrites.writtenAt(id, in: ownWrites) else { return true }
            return now.timeIntervalSince(wroteAt) > echoWindow
        }
    }

    /// Ids an incremental page reports, cancelled ones included.
    static func ids(in changes: [GoogleEvent]) -> Set<String> {
        Set(changes.compactMap(\.id))
    }

    /// Drop own-write records old enough that a change to that id is news again.
    static func pruned(_ ownWrites: [String: Date], now: Date,
                       echoWindow: TimeInterval = 10 * 60) -> [String: Date] {
        ownWrites.filter { now.timeIntervalSince($0.value) <= echoWindow }
    }

    private static func fingerprint(_ events: [GoogleEvent]) -> [String: String] {
        var result: [String: String] = [:]
        for event in events {
            guard let id = event.id else { continue }
            // `updated` moves on every server-side edit; the rest guards the rare copy without it.
            result[id] = [event.updated, event.status, event.start?.dateTime ?? event.start?.date,
                          event.end?.dateTime ?? event.end?.date, event.summary]
                .map { $0 ?? "" }.joined(separator: "|")
        }
        return result
    }
}

/// The per-calendar sync snapshots on disk, so a launch continues from the last read instead of
/// listing every calendar from scratch.
enum GoogleEventDiskCache {
    static var directory: URL {
        AppSupport.directory.appendingPathComponent("GoogleEventCache", isDirectory: true)
    }

    static func url(forCalendarID id: String, in directory: URL = directory) -> URL {
        // Calendar ids are email-like and may contain characters a file name can't; hex keeps
        // them unique and reversible without a lookup table.
        let name = id.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    static func load(calendarID: String, in directory: URL = directory) -> GoogleEventSync.Snapshot? {
        guard let data = try? Data(contentsOf: url(forCalendarID: calendarID, in: directory)) else { return nil }
        return try? JSONDecoder().decode(GoogleEventSync.Snapshot.self, from: data)
    }

    static func save(_ snapshot: GoogleEventSync.Snapshot, calendarID: String, in directory: URL = directory) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url(forCalendarID: calendarID, in: directory), options: .atomic)
        } catch {
            // A cache that fails to save only costs the next launch a full read.
        }
    }

    /// Remove every snapshot whose calendar is not in `keep` (disconnected account, deleted
    /// calendar), so nothing is served for a calendar Banana can no longer see.
    static func prune(keeping keep: Set<String>, in directory: URL = directory) {
        let wanted = Set(keep.map { url(forCalendarID: $0, in: directory).lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasSuffix(".json") && !wanted.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
