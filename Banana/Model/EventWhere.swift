import Foundation

/// What a "where" typed into one field is: a place for Maps, or a video call's link.
enum EventWhere {
    /// The link, when the text is one: a URL, or a bare host with a path or a known meeting host
    /// ("meet.google.com/abc-defg-hij", "zoom.us/j/123", "teams.microsoft.com/l/…"). A place
    /// ("Taco Bell", "12 Main St.") never is: it has spaces, or no host shape.
    static func link(in text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
            guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
            return value
        }
        let host = value.split(separator: "/", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        guard host.contains("."), host.range(of: #"^[a-z0-9.-]+\.[a-z]{2,}$"#, options: .regularExpression) != nil else { return nil }
        let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "facetime.apple.com"]
        if value.contains("/") || meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return value }
        return nil
    }
}
