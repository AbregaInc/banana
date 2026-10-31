import Foundation

/// The publisher-transcript path, pure Foundation so it can be tested on its own: a bounded fetch of
/// the URL a feed advertised, and the WebVTT / SRT / Podcasting 2.0 JSON parsers.
///
/// A feed is an untrusted publisher. Before the audit of 26 Oct 2026 the fetch read any URL scheme
/// whole with no size, time or status bound, and the cue parser stripped tags with a backtracking
/// regex that went quadratic on a run of `<`. Every bound lives here now.
enum FeedTranscriptParser {

    /// A real transcript is well under a megabyte; eight is the most read before giving up.
    static let mostBytes = 8 * 1024 * 1024
    /// Wall-clock bound on one fetch, connection and body together.
    static let timeout: Duration = .seconds(45)

    /// Only web URLs are fetched: a feed must not point the app at `file:` or `data:`.
    static func allowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// The body, or nil when the URL is not a web URL, the response is not 2xx, the body is larger
    /// than `mostBytes` (declared or streamed), or `timeout` passes.
    static func fetch(_ url: URL, session: URLSession = .shared, timeout: Duration = timeout) async -> Data? {
        guard allowed(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask { await read(request, session: session) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func read(_ request: URLRequest, session: URLSession) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Int64(mostBytes) else { return nil }
        var data = Data()
        data.reserveCapacity(Int(max(0, http.expectedContentLength)))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > mostBytes { return nil }
            }
        } catch { return nil }
        return data
    }

    // MARK: - Timed text (WebVTT / SRT)

    struct Cue: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var speaker: String?
    }

    /// Parse WebVTT or SRT into cues. Tolerant of `.` and `,` decimal separators, optional cue
    /// numbers and the WEBVTT header.
    static func parseTimedText(_ raw: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !lines.isEmpty else { continue }
            if lines[0].uppercased().hasPrefix("WEBVTT") { lines.removeFirst() }
            if lines.isEmpty { continue }
            if Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil { lines.removeFirst() }   // SRT index
            guard let timingLine = lines.first, timingLine.contains("-->") else { continue }
            let parts = timingLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]), let end = parseTimestamp(parts[1]) else { continue }
            let taggedBody = lines.dropFirst().joined(separator: " ")
            let speaker = voiceName(in: taggedBody)
            let body = stripTags(taggedBody).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body, speaker: speaker)) }
        }
        return cues
    }

    /// Drops every `<…>` span in one pass. A `<` with no closing `>` is kept as text, as a
    /// browser's cue parser keeps it; the cost is linear in the body whatever the body is.
    static func stripTags(_ text: String) -> String {
        // On UTF-8 bytes: `<` and `>` are ASCII and never occur inside a multi-byte sequence.
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var tagStart: Int? = nil     // index of the `<` of the tag being read
        for (i, b) in bytes.enumerated() {
            if let start = tagStart {
                if b == UInt8(ascii: ">") { tagStart = nil }
                else if b == UInt8(ascii: "<") { out.append(contentsOf: bytes[start..<i]); tagStart = i }
            } else if b == UInt8(ascii: "<") {
                tagStart = i
            } else {
                out.append(b)
            }
        }
        if let start = tagStart { out.append(contentsOf: bytes[start...]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The speaker of a `<v Name>` or `<v.class Name>` tag opening the cue, if any.
    static func voiceName(in text: String) -> String? {
        var scalars = text.unicodeScalars[...]
        while let first = scalars.first, first.properties.isWhitespace { scalars = scalars.dropFirst() }
        guard scalars.first == "<" else { return nil }
        scalars = scalars.dropFirst()
        guard scalars.first == "v" else { return nil }
        scalars = scalars.dropFirst()
        if scalars.first == "." {    // a class list, up to the first space
            while let c = scalars.first, c != ">", !c.properties.isWhitespace { scalars = scalars.dropFirst() }
        }
        guard let c = scalars.first, c.properties.isWhitespace else { return nil }
        while let c = scalars.first, c.properties.isWhitespace { scalars = scalars.dropFirst() }
        guard let close = scalars.firstIndex(of: ">") else { return nil }
        let name = String(String.UnicodeScalarView(scalars[scalars.startIndex..<close]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        let comps = cleaned.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard !comps.isEmpty else { return nil }
        let nums = comps.compactMap { Double($0) }
        guard nums.count == comps.count else { return nil }
        switch nums.count {
        case 3: return nums[0] * 3600 + nums[1] * 60 + nums[2]
        case 2: return nums[0] * 60 + nums[1]
        case 1: return nums[0]
        default: return nil
        }
    }

    /// Split a cue into words, distributing its time span proportional to word length.
    static func interpolateWords(
        in cue: (start: TimeInterval, end: TimeInterval, text: String), speaker: Int? = nil
    ) -> [TranscriptWord] {
        let tokens = cue.text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let span = max(0, cue.end - cue.start)
        let totalChars = max(1, tokens.reduce(0) { $0 + $1.count })
        var out: [TranscriptWord] = []
        var t = cue.start
        for token in tokens {
            let dur = span * Double(token.count) / Double(totalChars)
            out.append(TranscriptWord(text: token, start: t, end: t + dur, speaker: speaker))
            t += dur
        }
        return out
    }
}
