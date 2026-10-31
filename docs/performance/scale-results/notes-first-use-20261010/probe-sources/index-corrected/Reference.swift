import Foundation
import GRDB

/// Durable notes plus indexed browse pages. Search keeps Foundation's localized substring
/// semantics, but runs on the database queue and decodes only the requested page.
final class OriginalNoteRepository: @unchecked Sendable {
    private let database: DatabaseQueue
    func releaseProbeMemory() { database.releaseMemory() }
    struct Page: Sendable {
        let rows: [VoiceNote]
        let total: Int
    }

    init(url: URL, legacyURL: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = -2048")
            db.add(function: DatabaseFunction("localizedContains", argumentCount: 2, pure: false) { values in
                // Blob arguments preserve embedded NULs through SQLite/GRDB's C-string bridge.
                guard let textData = Data.fromDatabaseValue(values[0]),
                      let queryData = Data.fromDatabaseValue(values[1]),
                      let text = String(data: textData, encoding: .utf8),
                      let query = String(data: queryData, encoding: .utf8) else { return false }
                // Use Foundation's Boolean API directly. The Swift range bridge can
                // trap on an ignored trailing character (for example "needle\0").
                return (text as NSString).localizedCaseInsensitiveContains(query)
            })
        }
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("paged-notes-v1") { db in
            try db.execute(sql: """
                CREATE TABLE noteState (key TEXT PRIMARY KEY);
                CREATE TABLE notes (id TEXT PRIMARY KEY, created DOUBLE NOT NULL, archived INTEGER NOT NULL,
                    updated DOUBLE NOT NULL, episode TEXT, pending INTEGER NOT NULL, missingExcerpt INTEGER NOT NULL,
                    transcript TEXT, episodeTitle TEXT, podcastTitle TEXT, excerpt TEXT,
                    searchASCII INTEGER NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX notesBrowse ON notes(archived, created DESC, id);
                CREATE INDEX notesEpisode ON notes(episode, missingExcerpt);
                CREATE INDEX notesPending ON notes(pending);
                """)
        }
        try migrator.migrate(database)
        let imported = try database.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM noteState WHERE key = 'imported')")! }
        if !imported {
            try database.write { db in
                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    try JSONRecordStream.forEach(at: legacyURL) { data in
                        try Self.upsert(JSONDecoder().decode(VoiceNote.self, from: data), db: db)
                    }
                }
                try db.execute(sql: "INSERT INTO noteState VALUES ('imported')")
            }
        }
    }

    private static func upsert(_ note: VoiceNote, db: Database) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ascii = [note.transcript, note.context?.episodeTitle, note.context?.podcastTitle,
                     note.context?.transcriptExcerpt].compactMap { $0 }.allSatisfy(Self.isPrintableASCII)
        try db.execute(sql: """
            INSERT INTO notes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET created=excluded.created, archived=excluded.archived,
            updated=excluded.updated, episode=excluded.episode, pending=excluded.pending,
            missingExcerpt=excluded.missingExcerpt, transcript=excluded.transcript,
            episodeTitle=excluded.episodeTitle, podcastTitle=excluded.podcastTitle,
            excerpt=excluded.excerpt, searchASCII=excluded.searchASCII, payload=excluded.payload
            WHERE excluded.updated >= notes.updated AND excluded.payload != notes.payload
            """, arguments: [note.id.uuidString, note.createdAt.timeIntervalSinceReferenceDate,
                               note.archivedAt != nil, note.syncDate.timeIntervalSinceReferenceDate,
                               note.context?.episodeID, note.status == .pendingTranscription,
                               note.context?.transcriptExcerpt?.isEmpty != false,
                               note.transcript.map { Data($0.utf8) },
                               note.context?.episodeTitle.map { Data($0.utf8) },
                               note.context?.podcastTitle.map { Data($0.utf8) },
                               note.context?.transcriptExcerpt.map { Data($0.utf8) }, ascii, try encoder.encode(note)])
    }

    @discardableResult func upsert(_ notes: [VoiceNote]) throws -> Bool {
        try apply(notes)
    }

    @discardableResult func apply(_ notes: [VoiceNote], removing ids: [UUID] = []) throws -> Bool {
        try database.write { db in
            var changed = false
            for id in ids {
                try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id.uuidString])
                changed = changed || db.changesCount > 0
            }
            for note in notes { try Self.upsert(note, db: db); changed = changed || db.changesCount > 0 }
            return changed
        }
    }

    @discardableResult func remove(_ id: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id.uuidString])
            return db.changesCount > 0
        }
    }

    func note(_ id: UUID) throws -> VoiceNote? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM notes WHERE id = ?", arguments: [id.uuidString])
                .map { try JSONDecoder().decode(VoiceNote.self, from: $0) }
        }
    }

    func count(archived: Bool? = nil) throws -> Int {
        try database.read { db in
            if let archived { return try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE archived = ?", arguments: [archived])! }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM notes")!
        }
    }

    func ids(pending: Bool = false, missingExcerptFor episode: String? = nil) throws -> [UUID] {
        try database.read { db in
            let clause = episode != nil ? " WHERE episode = ? AND missingExcerpt = 1" : pending ? " WHERE pending = 1" : ""
            var args: StatementArguments = []
            if let episode { args = [episode] }
            return try String.fetchAll(db, sql: "SELECT id FROM notes\(clause) ORDER BY created DESC, id", arguments: args)
                .compactMap(UUID.init(uuidString:))
        }
    }

    func missingEpisodeIDs() throws -> [String] {
        try database.read { try String.fetchAll($0, sql: "SELECT DISTINCT episode FROM notes WHERE missingExcerpt = 1 AND episode IS NOT NULL") }
    }

    func page(search: String, archived: Bool, offset: Int = 0, limit: Int = 100) throws -> Page {
        try database.read { db in
            var clause = "archived = ?"
            var arguments: StatementArguments = [archived]
            if !search.isEmpty {
                // For printable ASCII only, SQLite can reject obvious nonmatches without
                // bridging every field through Foundation. Unicode/control-containing rows
                // always reach the original localized predicate; this is only a prefilter.
                if Self.isPrintableASCII(search) {
                    clause += " AND (searchASCII = 0 OR instr(lower(coalesce(transcript, '')), ?) > 0 OR instr(lower(coalesce(episodeTitle, '')), ?) > 0 OR instr(lower(coalesce(podcastTitle, '')), ?) > 0 OR instr(lower(coalesce(excerpt, '')), ?) > 0)"
                    let folded = search.lowercased()
                    arguments += [folded, folded, folded, folded]
                }
                clause += " AND (localizedContains(CAST(transcript AS BLOB), ?) OR localizedContains(CAST(episodeTitle AS BLOB), ?) OR localizedContains(CAST(podcastTitle AS BLOB), ?) OR localizedContains(CAST(excerpt AS BLOB), ?))"
                let bytes = Data(search.utf8)
                arguments += [bytes, bytes, bytes, bytes]
            }
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE \(clause)", arguments: arguments)!
            arguments += [max(0, limit), max(0, offset)]
            let rows = try Data.fetchAll(db, sql: "SELECT payload FROM notes WHERE \(clause) ORDER BY created DESC, id LIMIT ? OFFSET ?", arguments: arguments)
                .map { try JSONDecoder().decode(VoiceNote.self, from: $0) }
            return Page(rows: rows, total: total)
        }
    }

    private static func isPrintableASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { (32...126).contains($0) }
    }

    /// For the existing cloud seed/export contract only, never used by a screen.
    func all() throws -> [VoiceNote] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM notes ORDER BY created DESC, id")
                .map { try JSONDecoder().decode(VoiceNote.self, from: $0) }
        }
    }

    enum MigrationError: LocalizedError {
        case unreadableRecords
        var errorDescription: String? { "Some saved notes could not be read. The original notes file has been preserved." }
    }
}
