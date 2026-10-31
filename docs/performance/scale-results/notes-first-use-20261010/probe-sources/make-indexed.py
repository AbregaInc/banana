from pathlib import Path
root=Path('.build/notes-first-use-20261010')
s=Path('Banana/Model/NoteRepository.swift').read_text().replace('final class NoteRepository:', 'final class IndexedNoteRepository:')
needle='    func page(search: String, archived: Bool, offset: Int = 0, limit: Int = 100) throws -> Page {'
addition='''    func prepareProbeIndex() throws {
        try database.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE probeSearch USING fts5(transcript, episodeTitle, podcastTitle, excerpt, content='notes', content_rowid='rowid', tokenize='trigram')")
            try db.execute(sql: "INSERT INTO probeSearch(probeSearch) VALUES('rebuild')")
            try db.execute(sql: "CREATE INDEX probeNonASCII ON notes(searchASCII)")
            try db.execute(sql: "CREATE VIRTUAL TABLE probeVocabulary USING fts5vocab(probeSearch, row)")
        }
    }
    func releaseProbeMemory() { database.releaseMemory() }
'''
s=s.replace(needle,addition+needle)
needle='''            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE \\(clause)", arguments: arguments)!'''
replacement='''            if search.utf8.count >= 3 && Self.isPrintableASCII(search) {
                let gram = String(search.lowercased().prefix(3))
                let frequency = try Int.fetchOne(db, sql: "SELECT doc FROM probeVocabulary WHERE term = ?", arguments: [gram]) ?? 0
                let population = try Int.fetchOne(db, sql: "SELECT count(*) FROM notes")!
                if frequency <= population / 4 {
                    clause = "rowid IN (SELECT rowid FROM probeSearch WHERE probeSearch MATCH ? UNION SELECT rowid FROM notes WHERE searchASCII = 0) AND " + clause
                    var indexedArguments: StatementArguments = ["\\\"" + search.replacingOccurrences(of: "\\\"", with: "\\\"\\\"") + "\\\""]
                    indexedArguments += arguments
                    arguments = indexedArguments
                }
            }
'''+needle
assert needle in s;s=s.replace(needle,replacement);(root/'IndexedNoteRepository.swift').write_text(s)
