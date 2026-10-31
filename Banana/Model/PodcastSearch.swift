import Foundation

/// A search hit from the iTunes podcast directory.
struct PodcastSearchResult: Identifiable, Hashable {
    let id: Int          // iTunes collectionId
    let title: String
    let author: String
    let feedURL: URL
    let artworkURL: URL?
}

/// Searches Apple's public iTunes podcast directory. No auth required; each
/// result includes the show's real RSS `feedUrl`, which we can subscribe to.
enum PodcastSearch {
    private struct Response: Decodable { let results: [Item] }
    private struct Item: Decodable {
        let collectionId: Int?
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let artworkUrl100: String?
    }

    static func search(_ term: String) async throws -> [PodcastSearchResult] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = comps.url else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(Response.self, from: data)

        return response.results.compactMap { item in
            guard let id = item.collectionId,
                  let feed = item.feedUrl.flatMap(URL.init(string:)) else { return nil }
            return PodcastSearchResult(
                id: id,
                title: item.collectionName ?? "Untitled Podcast",
                author: item.artistName ?? "",
                feedURL: feed,
                artworkURL: (item.artworkUrl600 ?? item.artworkUrl100).flatMap(URL.init(string:))
            )
        }
    }
}
