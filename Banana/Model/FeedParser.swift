import Foundation

/// The parsed result of a podcast RSS feed.
struct ParsedFeed {
    var title: String
    var author: String?
    var artworkURL: URL?
    var episodes: [Episode]
}

enum FeedError: LocalizedError {
    case network(String)
    case notXML
    case noEpisodes

    var errorDescription: String? {
        switch self {
        case .network(let m): return "Couldn't load the feed: \(m)"
        case .notXML: return "That URL didn't return a valid podcast feed."
        case .noEpisodes: return "That feed has no playable episodes."
        }
    }
}

/// Fetches and parses a podcast RSS feed using Foundation's `XMLParser`.
enum FeedParser {

    /// A conditional fetch's outcome. `unchanged` = the server said 304: nothing was transferred
    /// beyond headers, nothing needs re-parsing, and the caller should NOT rewrite its catalogue.
    enum FeedResult {
        case unchanged
        case fresh(ParsedFeed, etag: String?, lastModified: String?)
    }

    /// Download + parse a feed URL off the main thread. Pass the validators from the last fetch
    /// and unchanged feeds cost one request/response pair instead of a full RSS download, a full
    /// XML parse, a wholesale episode-array replace, and a multi-MB catalogue rewrite.
    static func load(_ url: URL, etag: String? = nil, lastModified: String? = nil,
                     session: URLSession = .shared) async throws -> FeedResult {
        let data: Data
        let response: URLResponse
        do {
            var request = URLRequest(url: url)
            request.setValue("Banana/1.0", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData   // WE do the validation, explicitly
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedError.network(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304 { return .unchanged }
        if let http, !(200..<300).contains(http.statusCode) {
            throw FeedError.network("The server returned HTTP \(http.statusCode). Try again later.")
        }
        let feed = try await Task.detached(priority: .userInitiated) {
            try parse(data)
        }.value
        return .fresh(feed,
                      etag: http?.value(forHTTPHeaderField: "ETag"),
                      lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
    }

    /// Synchronous parse — run off-main via `Task.detached`.
    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = RSSDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw FeedError.notXML }
        guard !delegate.episodes.isEmpty else { throw FeedError.noEpisodes }
        return ParsedFeed(
            title: delegate.channelTitle.trimmed.isEmpty ? "Untitled Podcast" : delegate.channelTitle.trimmed,
            author: delegate.channelAuthor.trimmed.nilIfEmpty,
            artworkURL: delegate.channelImageURL.flatMap(URL.init(string:)),
            episodes: delegate.episodes
        )
    }
}

/// XMLParser delegate that accumulates channel + item data.
private final class RSSDelegate: NSObject, XMLParserDelegate {
    // Channel-level
    var channelTitle = ""
    var channelAuthor = ""
    var channelImageURL: String?

    var episodes: [Episode] = []

    // Parsing state
    private var element = ""
    private var text = ""
    private var insideItem = false
    private var insideImage = false   // channel <image> block

    // Current item
    private var itemTitle = ""
    private var itemAudioURL: String?
    private var itemGUID: String?
    private var itemPubDate: String?
    private var itemDuration: String?
    private var itemSeason: String?
    private var itemEpisode: String?
    private var itemSummary = ""
    private var itemImageURL: String?
    private var itemTranscripts: [EpisodeTranscriptSource] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        element = elementName
        text = ""

        // The namespace spec explicitly permits prefixes other than `podcast`. XMLParser keeps
        // the feed's literal prefix unless namespace processing is enabled, so matching only
        // `podcast:transcript` silently missed otherwise-valid publisher transcripts.
        if elementName == "transcript" || elementName.hasSuffix(":transcript") {
            if let rawURL = attributeDict["url"], let url = URL(string: rawURL) {
                let source = EpisodeTranscriptSource(
                    url: url,
                    type: attributeDict["type"],
                    language: attributeDict["language"]
                )
                if Self.transcriptRank(source.type, url: rawURL) < Int.max,
                   !itemTranscripts.contains(source) {
                    itemTranscripts.append(source)
                }
            }
            return
        }

        switch elementName {
        case "item":
            insideItem = true
            itemTitle = ""; itemAudioURL = nil; itemGUID = nil
            itemPubDate = nil; itemDuration = nil; itemSeason = nil
            itemEpisode = nil; itemSummary = ""; itemImageURL = nil
            itemTranscripts = []
        case "image":
            insideImage = true
        case "enclosure":
            if let url = attributeDict["url"],
               (attributeDict["type"]?.hasPrefix("audio") ?? true) {
                itemAudioURL = url
            }
        case "itunes:image":
            if let href = attributeDict["href"] {
                if insideItem { itemImageURL = href } else { channelImageURL = channelImageURL ?? href }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmed

        if insideItem {
            switch elementName {
            case "title": itemTitle = value
            case "guid": itemGUID = value
            case "pubDate": itemPubDate = value
            case "itunes:duration": itemDuration = value
            case "itunes:season": itemSeason = value
            case "itunes:episode": itemEpisode = value
            case "description", "itunes:summary":
                if itemSummary.isEmpty { itemSummary = value }
            case "item":
                finishItem()
                insideItem = false
            default: break
            }
        } else {
            switch elementName {
            case "title": if channelTitle.isEmpty { channelTitle = value }
            case "itunes:author": if channelAuthor.isEmpty { channelAuthor = value }
            case "url": if insideImage, channelImageURL == nil { channelImageURL = value }
            case "image": insideImage = false
            default: break
            }
        }
        text = ""
    }

    private func finishItem() {
        guard let urlString = itemAudioURL, let audioURL = URL(string: urlString) else { return }
        let id = (itemGUID?.nilIfEmpty) ?? urlString
        let transcripts = itemTranscripts.sorted {
            Self.transcriptRank($0.type, url: $0.url.absoluteString)
                < Self.transcriptRank($1.type, url: $1.url.absoluteString)
        }
        let episode = Episode(
            id: id,
            title: itemTitle.nilIfEmpty ?? "Untitled Episode",
            audioURL: audioURL,
            pubDate: itemPubDate.flatMap(DateParsing.rfc822),
            duration: itemDuration.flatMap(DateParsing.duration),
            season: itemSeason.flatMap { Int($0) },
            episodeNumber: itemEpisode.flatMap { Int($0) },
            summary: itemSummary.nilIfEmpty,
            transcriptURL: transcripts.first?.url,
            transcriptSources: transcripts
        )
        episodes.append(episode)
    }

    /// Preference among timestamped Podcasting 2.0 formats. JSON can preserve structured speaker
    /// and segment timing, while VTT/SRT are still retained as fallbacks if a publisher's JSON URL
    /// is stale or malformed.
    static func transcriptRank(_ type: String?, url: String) -> Int {
        let t = (type ?? "").lowercased()
        let u = url.lowercased()
        if t.contains("json") || u.hasSuffix(".json") { return 0 }
        if t.contains("vtt") || u.hasSuffix(".vtt") { return 1 }
        if t.contains("srt") || t.contains("subrip") || u.hasSuffix(".srt") { return 2 }
        return Int.max   // untimed HTML/plain text cannot drive word-following playback honestly
    }
}

// MARK: - Parsing helpers

private enum DateParsing {
    static let formatters: [DateFormatter] = {
        let patterns = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z",
        ]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = pattern
            return f
        }
    }()

    static func rfc822(_ string: String) -> Date? {
        let trimmed = string.trimmed
        for f in formatters {
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    /// itunes:duration may be seconds ("3600") or "HH:MM:SS" / "MM:SS".
    static func duration(_ string: String) -> Double? {
        let trimmed = string.trimmed
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":").map { Double($0) ?? 0 }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        return Double(trimmed)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
