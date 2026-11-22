import Foundation

/// The links Banana opens, or makes tappable, from text it didn't write: an invitation's notes and
/// location, a podcast's show notes, a model's reply. Web and mail only, with an address, and
/// nothing unprintable: never `javascript:`, `file:`, another app's URL scheme or a system page.
enum LinkPolicy {
    static let schemes: Set<String> = ["http", "https", "mailto"]

    /// The link when it may be opened; nil otherwise (its words stay plain text).
    static func allowed(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        let text = url.absoluteString
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.properties.isWhitespace })
        else { return nil }
        if scheme == "mailto" { return text.count > "mailto:".count ? url : nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// A web link only (what a Join button may open).
    static func web(_ url: URL?) -> URL? {
        guard let url = allowed(url), url.scheme?.lowercased() != "mailto" else { return nil }
        return url
    }

    /// The text with every link that isn't allowed turned back into plain words.
    static func filtered(_ text: AttributedString) -> AttributedString {
        var out = text
        for run in text.runs where run.link != nil && allowed(run.link) == nil { out[run.range].link = nil }
        return out
    }
}
