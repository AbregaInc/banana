#if BANANA_MODULE_PODCASTS
import Foundation
import Combine

/// A stable query against an immutable feed snapshot. Preparation and reads run off the UI lane.
struct PodcastEpisodeQuery {
    private let snapshot: EpisodeSnapshot?
    private let newest: Bool
    private let excludingJSON: String
    private let memory: [Episode]
    let count: Int

    init(podcast: Podcast, includingListened: Bool,
         voiceOf: @Sendable (_ episodeID: String, _ narrator: String?) -> VoiceGender? = { _, _ in nil }) throws {
        snapshot = podcast.episodeSnapshot
        newest = podcast.direction == .newestFirst
        var excluded = includingListened ? Set<String>() : podcast.completed
        if podcast.hasVoiceFilter {
            var roster: Set<String> = []
            for offset in stride(from: 0, to: podcast.episodeCount, by: 100) {
                for episode in try podcast.episodePage(offset: offset) {
                    if let name = NarratorCredit.name(in: episode.summary) { roster.insert(name) }
                }
            }
            for offset in stride(from: 0, to: podcast.episodeCount, by: 100) {
                for episode in try podcast.episodePage(offset: offset) {
                    if podcast.isSkipped(episode, roster: roster, voiceOf: voiceOf) { excluded.insert(episode.id) }
                }
            }
        }
        excludingJSON = String(decoding: try JSONEncoder().encode(Array(excluded)), as: UTF8.self)
        if let snapshot {
            memory = []
            count = try snapshot.browseCount(excludingJSON: excludingJSON)
        } else {
            memory = podcast.ordered().filter { !excluded.contains($0.id) }
            count = memory.count
        }
    }

    func page(offset: Int, limit: Int) throws -> [Episode] {
        if let snapshot {
            return try snapshot.browsePage(newest: newest, excludingJSON: excludingJSON, offset: offset, limit: limit)
        }
        return Array(memory.dropFirst(max(0, offset)).prefix(max(0, limit)))
    }
}

/// The list has stable integer positions; only five decoded pages are kept. Native List owns
/// row reuse, rather than replacing the entire list on a Next tap or retaining every episode.
@MainActor
final class PodcastEpisodeBrowser: ObservableObject {
    nonisolated static let pageSize = 100
    nonisolated static let maximumPages = 5
    @Published private(set) var count = 0
    @Published private(set) var isLoading = true
    @Published private(set) var error: String?
    @Published private var revision = 0
    private var query: PodcastEpisodeQuery?
    private var pages: [Int: [Episode]] = [:]
    private var recency: [Int] = []
    private var pending: [Int: (id: UUID, task: Task<Void, Never>)] = [:]
    private var generation = 0
    private var focusedPage = 0
    private var feedID: UUID?
    private var configurationInFlight = false

    var retainedEpisodeCount: Int { pages.values.reduce(0) { $0 + $1.count } }
    func episode(at index: Int) -> Episode? {
        let page = index / Self.pageSize
        guard let rows = pages[page], rows.indices.contains(index % Self.pageSize) else { return nil }
        return rows[index % Self.pageSize]
    }

    func configure(podcast: Podcast, includingListened: Bool,
                   voiceOf: @escaping @Sendable (_ episodeID: String, _ narrator: String?) -> VoiceGender? = { _, _ in nil }) async {
        generation += 1
        let token = generation
        for request in pending.values { request.task.cancel() }
        pending.removeAll()
        let warm = feedID == podcast.id && query != nil
        if !warm {
            pages.removeAll(); recency.removeAll()
            query = nil; count = 0; focusedPage = 0
            isLoading = true
        }
        feedID = podcast.id
        configurationInFlight = true
        error = nil
        let requestedPage = focusedPage
        do {
            // Stage only the viewport and its neighbours. Keep the old bounded snapshot
            // visible until the replacement is ready, including across played/undo updates.
            let (query, prepared, focus) = try await Task.detached(priority: .userInitiated) {
                let query = try PodcastEpisodeQuery(podcast: podcast, includingListened: includingListened, voiceOf: voiceOf)
                let focus = min(requestedPage, max(0, (query.count - 1) / Self.pageSize))
                var prepared: [Int: [Episode]] = [:]
                for page in max(0, focus - 1)...min(focus + 1, max(0, (query.count - 1) / Self.pageSize)) {
                    prepared[page] = try query.page(offset: page * Self.pageSize, limit: Self.pageSize)
                }
                return (query, prepared, focus)
            }.value
            guard token == generation else { return }
            configurationInFlight = false
            guard !Task.isCancelled else { return }
            let latestFocus = focusedPage
            self.query = query
            pages = prepared; recency = prepared.keys.sorted()
            focusedPage = focus
            if count != query.count { count = query.count }
            if isLoading { isLoading = false }
            revision += 1
            if latestFocus != requestedPage, query.count > 0 {
                await reveal(min(latestFocus * Self.pageSize, query.count - 1))
            }
        } catch {
            guard token == generation else { return }
            configurationInFlight = false
            guard !Task.isCancelled else { return }
            if isLoading { isLoading = false }
            self.error = error.localizedDescription
        }
    }

    func reveal(_ index: Int) async {
        guard index >= 0, index < count else { return }
        let page = index / Self.pageSize
        focusedPage = page
        for key in Array(pending.keys) where abs(key - page) > 2 {
            pending.removeValue(forKey: key)?.task.cancel()
        }
        await load(page)
        // Prepare the following page before its first row is visible. Browsing backwards
        // reloads the prior page on demand; no retained history is truncated.
        if (page + 1) * Self.pageSize < count { await load(page + 1) }
    }

    private func load(_ page: Int) async {
        guard !configurationInFlight, abs(page - focusedPage) <= 2 else { return }
        if pages[page] != nil {
            recency.removeAll { $0 == page }; recency.append(page)
            return
        }
        if let request = pending[page] { await request.task.value; return }
        guard let query else { return }
        let token = generation
        let requestID = UUID()
        let task = Task { [weak self] in
            defer {
                if let self, token == generation, pending[page]?.id == requestID { pending.removeValue(forKey: page) }
            }
            do {
                let rows = try await Task.detached(priority: .userInitiated) {
                    try query.page(offset: page * Self.pageSize, limit: Self.pageSize)
                }.value
                guard let self, token == generation, !Task.isCancelled, abs(page - focusedPage) <= 2 else { return }
                pages[page] = rows
                recency.removeAll { $0 == page }; recency.append(page)
                while recency.count > Self.maximumPages { pages.removeValue(forKey: recency.removeFirst()) }
                error = nil; revision += 1
            } catch {
                guard let self, token == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        pending[page] = (requestID, task)
        await task.value
    }
}
#endif
