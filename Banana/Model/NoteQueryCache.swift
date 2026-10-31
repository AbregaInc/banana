import Foundation

/// At most four result arrays: active/archived browsing and the current search. Owners invalidate
/// on every content mutation. Locale changes also invalidate, preserving localized search behavior.
final class NoteQueryCache {
    private struct Key: Hashable { let search: String; let archived: Bool; var filter: LiveFilter?; var day: Date? }
    private var results: [Key: [VoiceNote]] = [:]
    private var search = ""
    private var locale = Locale.current.identifier

    func invalidate() { results.removeAll(keepingCapacity: true) }

    func matching(_ notes: [VoiceNote], search query: String, archived: Bool, filter: LiveFilter? = nil) -> [VoiceNote] {
        if locale != Locale.current.identifier {
            locale = Locale.current.identifier
            invalidate()
        }
        if !query.isEmpty && query != search {
            results = results.filter { $0.key.search.isEmpty }
            search = query
        }
        let key = Key(search: query, archived: archived, filter: filter, day: filter?.interval()?.start)
        if results.count >= 4 && results[key] == nil { results.removeAll(keepingCapacity: true) }
        if let result = results[key] { return result }
        let match = filter?.predicate()
        let result = notes.filter { note in
            guard (note.archivedAt != nil) == archived else { return false }
            if let value = filter?.value("archived"), (value == "true") != archived { return false }
            if filter?.isEmpty == true { return true }
            if let match {
                let text = [note.transcript, note.context?.episodeTitle, note.context?.podcastTitle, note.context?.transcriptExcerpt].compactMap { $0 }.joined(separator: "\n")
                return match(note.createdAt, text, nil, nil)
            }
            guard !query.isEmpty else { return true }
            return note.transcript.map { ($0 as NSString).localizedCaseInsensitiveContains(query) } == true
                || note.context?.episodeTitle.map { ($0 as NSString).localizedCaseInsensitiveContains(query) } == true
                || note.context?.podcastTitle.map { ($0 as NSString).localizedCaseInsensitiveContains(query) } == true
                || note.context?.transcriptExcerpt.map { ($0 as NSString).localizedCaseInsensitiveContains(query) } == true
        }
        results[key] = result
        return result
    }
}
