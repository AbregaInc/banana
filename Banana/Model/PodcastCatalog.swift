import Foundation
import GRDB
import os

extension CodingUserInfoKey {
    static let podcastMetadataOnly = CodingUserInfoKey(rawValue: "podcastMetadataOnly")!
}

/// SQLite owns episode bodies; Podcast values carry only a small immutable snapshot handle.
/// Reads are page-sized. Old handles remain valid across a feed refresh.
final class PodcastCatalog: @unchecked Sendable {
    let url: URL
    private let database: DatabaseQueue
    private let lock = NSLock()
    private struct WeakSnapshot { weak var value: EpisodeSnapshot? }
    private var handles: [String: WeakSnapshot] = [:]
    private var episodeCache: [String: (Episode, Int)] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0
    private static let registryLock = NSLock()
    private struct WeakCatalog { weak var value: PodcastCatalog? }
    private nonisolated(unsafe) static var registry: [String: WeakCatalog] = [:]

    static func open(at url: URL) throws -> PodcastCatalog {
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[url.path]?.value { return existing }
        let result = try PodcastCatalog(url: url)
        registry[url.path] = WeakCatalog(value: result)
        return result
    }

    private init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = -4096")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrations = DatabaseMigrator()
        migrations.registerMigration("paged-podcasts-v1") { db in
            try db.execute(sql: """
                CREATE TABLE catalogState (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE episodeSnapshots (id TEXT PRIMARY KEY, count INTEGER NOT NULL, latest DOUBLE);
                CREATE TABLE episodes (
                    snapshot TEXT NOT NULL REFERENCES episodeSnapshots(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL, id TEXT NOT NULL, date DOUBLE NOT NULL, payload BLOB NOT NULL,
                    PRIMARY KEY (snapshot, ordinal));
                CREATE INDEX episodeIdentity ON episodes(snapshot, id);
                CREATE INDEX episodeDate ON episodes(snapshot, date, ordinal);
                CREATE TABLE podcasts (id TEXT PRIMARY KEY, ordinal INTEGER NOT NULL,
                    snapshot TEXT NOT NULL REFERENCES episodeSnapshots(id), payload BLOB NOT NULL);
                """)
        }
        try migrations.migrate(database)
    }

    private static func stamp(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "absent" }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
    }

    /// Original JSON stays untouched. A replaced JSON (including an older cloud backup restore)
    /// is imported transactionally. A failed decode/import never replaces a working catalog.
    func load(legacyURL: URL, forceImport: Bool = false) throws -> [Podcast] {
        let stamp = try Self.stamp(legacyURL)
        let previous = try database.read { try String.fetchOne($0, sql: "SELECT value FROM catalogState WHERE key = 'legacyStamp'") }
        if previous == nil || (stamp != "absent" && (forceImport || previous != stamp)) {
            try database.write { db in
                try db.execute(sql: "DELETE FROM podcasts")
                var ordinal = 0
                let encoder = JSONEncoder()
                encoder.userInfo[.podcastMetadataOnly] = true
                if stamp != "absent" {
                    try JSONRecordStream.forEach(at: legacyURL) { data in
                        let value = try JSONDecoder().decode(Podcast.self, from: data)
                        let podcast = try stage(value, in: db)
                        try db.execute(sql: "INSERT INTO podcasts VALUES (?, ?, ?, ?)",
                                       arguments: [podcast.id.uuidString, ordinal, podcast.episodeSnapshot!.id, try encoder.encode(podcast)])
                        ordinal += 1
                    }
                }
                try db.execute(sql: "INSERT OR REPLACE INTO catalogState VALUES ('legacyStamp', ?)", arguments: [stamp])
            }
        }
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT p.payload, s.id, s.count, s.latest FROM podcasts p JOIN episodeSnapshots s ON p.snapshot = s.id ORDER BY p.ordinal").map { row in
                var podcast = try JSONDecoder().decode(Podcast.self, from: row["payload"])
                podcast.episodeSnapshot = snapshot(id: row["id"], count: row["count"], latest: row["latest"])
                return podcast
            }
        }
    }

    /// One transaction commits metadata and newly arrived episodes. Unchanged feeds keep their
    /// snapshots: changing playback settings never rewrites the rest of the episode catalog.
    func save(_ podcasts: [Podcast], legacyStamp: String? = nil) throws -> [Podcast] {
        let encoder = JSONEncoder()
        encoder.userInfo[.podcastMetadataOnly] = true
        let result = try database.write { db in
            try db.execute(sql: "DELETE FROM podcasts")
            var result: [Podcast] = []
            for (ordinal, value) in podcasts.enumerated() {
                let podcast = try stage(value, in: db)
                let handle = podcast.episodeSnapshot!
                try db.execute(sql: "INSERT INTO podcasts VALUES (?, ?, ?, ?)",
                               arguments: [podcast.id.uuidString, ordinal, handle.id, try encoder.encode(podcast)])
                result.append(podcast)
            }
            if let legacyStamp {
                try db.execute(sql: "INSERT OR REPLACE INTO catalogState VALUES ('legacyStamp', ?)", arguments: [legacyStamp])
            } else {
                try db.execute(sql: "INSERT OR IGNORE INTO catalogState VALUES ('legacyStamp', 'absent')")
            }
            return result
        }
        return result
    }

    /// Stage one arriving feed before the next is fetched, bounding refresh/fixture memory.
    func stage(_ value: Podcast) throws -> Podcast {
        try database.write { try stage(value, in: $0) }
    }

    private func stage(_ value: Podcast, in db: Database) throws -> Podcast {
        var podcast = value
        let handle: EpisodeSnapshot
        if let existing = value.episodeSnapshot, existing.store === self {
            handle = existing
        } else {
            let rows = try value.episodeSnapshot?.all() ?? value.episodes
            let id = UUID().uuidString
            let latest = rows.compactMap(\.pubDate).max()?.timeIntervalSinceReferenceDate
            try db.execute(sql: "INSERT INTO episodeSnapshots VALUES (?, ?, ?)", arguments: [id, rows.count, latest])
            let insert = try db.makeStatement(sql: "INSERT INTO episodes VALUES (?, ?, ?, ?, ?)")
            let episodeEncoder = JSONEncoder()
            for (index, episode) in rows.enumerated() {
                try insert.execute(arguments: [id, index, episode.id,
                    (episode.pubDate ?? .distantPast).timeIntervalSinceReferenceDate,
                    try episodeEncoder.encode(episode)])
            }
            handle = snapshot(id: id, count: rows.count, latest: latest)
        }
        podcast.episodes = []
        podcast.episodeSnapshot = handle
        return podcast
    }

    private func snapshot(id: String, count: Int, latest: Double?) -> EpisodeSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let existing = handles[id]?.value { return existing }
        let result = EpisodeSnapshot(store: self, id: id, count: count,
                                     latest: latest.map(Date.init(timeIntervalSinceReferenceDate:)))
        handles[id] = WeakSnapshot(value: result)
        return result
    }

    /// Collect only superseded snapshots without a live model handle. Current rows are pinned
    /// by the catalog table. Run after a commit; failure only leaves reclaimable disk space.
    func reclaimRetiredSnapshots() throws {
        try database.write { db in
            // Capture leases on the same serialized queue as stage/load. Otherwise a stage
            // between capturing this set and entering the transaction could be reclaimed.
            lock.lock()
            handles = handles.filter { $0.value.value != nil }
            let retained = Set(handles.keys)
            lock.unlock()
            let retired = try String.fetchAll(db, sql: "SELECT id FROM episodeSnapshots WHERE id NOT IN (SELECT snapshot FROM podcasts)")
            for id in retired where !retained.contains(id) {
                try db.execute(sql: "DELETE FROM episodeSnapshots WHERE id = ?", arguments: [id])
            }
        }
    }

    fileprivate func page(_ id: String, newest: Bool?, reverseTies: Bool, offset: Int, limit: Int) throws -> [Episode] {
        guard limit > 0 else { return [] }
        let order = newest.map { "date \($0 ? "DESC" : "ASC"), ordinal \(reverseTies ? "DESC" : "ASC")" } ?? "ordinal ASC"
        return try database.read { db in
            // Only the finite ordering variants form statement keys. Snapshot/page values stay
            // bound arguments; GRDB owns reuse on this serialized database connection.
            let request = SQLRequest<Data>(sql: "SELECT payload FROM episodes WHERE snapshot = ? ORDER BY \(order) LIMIT ? OFFSET ?",
                                           arguments: [id, limit, max(0, offset)], cached: true)
            return try Data.fetchAll(db, request).map { try JSONDecoder().decode(Episode.self, from: $0) }
        }
    }

    fileprivate func episode(_ id: String, in snapshot: String) throws -> Episode? {
        let key = snapshot + "|" + id
        lock.lock()
        let cached = episodeCache[key]?.0
        lock.unlock()
        if let cached { return cached }
        let data = try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM episodes WHERE snapshot = ? AND id = ? ORDER BY ordinal LIMIT 1", arguments: [snapshot, id])
        }
        guard let data else { return nil }
        let episode = try JSONDecoder().decode(Episode.self, from: data)
        let cost = max(512, data.count * 2)
        lock.lock(); defer { lock.unlock() }
        if episodeCache[key] == nil, cost <= 4 * 1024 * 1024 {
            while !cacheOrder.isEmpty && (cacheOrder.count >= 128 || cacheBytes + cost > 4 * 1024 * 1024) {
                let oldest = cacheOrder.removeFirst()
                cacheBytes -= episodeCache.removeValue(forKey: oldest)?.1 ?? 0
            }
            episodeCache[key] = (episode, cost)
            cacheBytes += cost
            cacheOrder.append(key)
        }
        return episode
    }

    fileprivate func ids(_ snapshot: String) throws -> Set<String> {
        try database.read { try Set(String.fetchAll($0, sql: "SELECT id FROM episodes WHERE snapshot = ?", arguments: [snapshot])) }
    }

    /// Exclude listened episodes before applying LIMIT, so a long listened prefix never
    /// consumes a browsing page. One JSON argument avoids SQLite's bind-variable limit.
    fileprivate func browseCount(_ snapshot: String, excludingJSON: String) throws -> Int {
        try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM episodes WHERE snapshot = ? AND id NOT IN (SELECT value FROM json_each(?))",
                             arguments: [snapshot, excludingJSON]) ?? 0
        }
    }

    fileprivate func browsePage(_ snapshot: String, newest: Bool, excludingJSON: String,
                                offset: Int, limit: Int) throws -> [Episode] {
        let order = newest ? "DESC" : "ASC"
        return try database.read { db in
            let request = SQLRequest<Data>(sql: "SELECT payload FROM episodes WHERE snapshot = ? AND id NOT IN (SELECT value FROM json_each(?)) ORDER BY date \(order), ordinal \(order) LIMIT ? OFFSET ?",
                                           arguments: [snapshot, excludingJSON, max(0, limit), max(0, offset)], cached: true)
            return try Data.fetchAll(db, request).map { try JSONDecoder().decode(Episode.self, from: $0) }
        }
    }

    fileprivate func orderedIDs(_ snapshot: String, newest: Bool) throws -> [String] {
        let direction = newest ? "DESC" : "ASC"
        return try database.read {
            try String.fetchAll($0, sql: "SELECT id FROM episodes WHERE snapshot = ? ORDER BY date \(direction), ordinal \(direction)", arguments: [snapshot])
        }
    }

    /// The backup remains the portable pre-SQLite format. Decode one feed at a time instead of
    /// materializing all episode objects together. Any read failure fails the entire backup.
    func backupJSON(legacyURL: URL) throws -> Data {
        let podcasts = try load(legacyURL: legacyURL)
        var data = Data("[".utf8)
        for (index, podcast) in podcasts.enumerated() {
            if index > 0 { data.append(0x2c) }
            try autoreleasepool { data.append(try JSONEncoder().encode(podcast)) }
        }
        data.append(0x5d)
        return data
    }


}

final class EpisodeSnapshot: @unchecked Sendable, Hashable {
    let store: PodcastCatalog
    let id: String
    let count: Int
    let latest: Date?
    fileprivate init(store: PodcastCatalog, id: String, count: Int, latest: Date?) {
        self.store = store; self.id = id; self.count = count; self.latest = latest
    }
    static func == (lhs: EpisodeSnapshot, rhs: EpisodeSnapshot) -> Bool { lhs.id == rhs.id && lhs.store.url == rhs.store.url }
    func hash(into hasher: inout Hasher) { hasher.combine(store.url); hasher.combine(id) }
    func page(newest: Bool? = nil, reverseTies: Bool = false, offset: Int = 0, limit: Int = 100) throws -> [Episode] {
        try store.page(id, newest: newest, reverseTies: reverseTies, offset: offset, limit: limit)
    }
    func episode(_ episodeID: String) throws -> Episode? { try store.episode(episodeID, in: id) }
    func ids() throws -> Set<String> { try store.ids(id) }
    func orderedIDs(newest: Bool) throws -> [String] { try store.orderedIDs(id, newest: newest) }
    func browseCount(excludingJSON: String) throws -> Int { try store.browseCount(id, excludingJSON: excludingJSON) }
    func browsePage(newest: Bool, excludingJSON: String, offset: Int, limit: Int) throws -> [Episode] {
        try store.browsePage(id, newest: newest, excludingJSON: excludingJSON, offset: offset, limit: limit)
    }
    func all() throws -> [Episode] { try page(limit: count) }
}
