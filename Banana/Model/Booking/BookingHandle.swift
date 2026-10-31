import Foundation

/// The booking link's handle (docs/design/BOOKING.md §4): `book.bananatheapp.com/<handle>`, one per
/// account. The rules are the service's (`handleProblem`, `handleIdeas` in
/// `Service/src/booking/types.js`), here so a typed handle is checked at once and a suggestion shows
/// before the service answers. The service has the last word: it alone knows what is taken.
enum BookingHandle {
    enum Problem: String, Equatable, Sendable {
        case invalid, reserved, taken
    }

    /// The service's reserved words (types.js `RESERVED`).
    static let reserved: Set<String> = [
        "m", "b", "v1", "v2", "v3", "assets", "privacy", "support", "api", "book", "booking", "www", "mail", "admin", "help", "about",
        "terms", "legal", "security", "status", "health", "login", "signin", "signup", "logout", "settings", "account", "accounts",
        "guest", "guests", "manage", "cancel", "connect", "code", "forget", "undo", "static", "public", "fonts", "img", "css", "js",
        "app", "apps", "banana", "bananatheapp", "beta", "test", "root", "null", "undefined", "new", "edit", "me", "you", "team",
        "teams", "blog", "docs", "home", "index", "robots", "sitemap", "favicon", "well-known",
    ]

    /// Why a handle can't be used, or nil when it can (`[a-z0-9-]{3,30}`, no dash at either end or
    /// twice in a row, not reserved).
    static func problem(_ handle: String) -> Problem? {
        let allowed = handle.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        guard (3...30).contains(handle.count), allowed, !handle.hasPrefix("-"), !handle.hasSuffix("-"),
              !handle.contains("--") else { return .invalid }
        return reserved.contains(handle) ? .reserved : nil
    }

    /// What a person typed, as a handle: trimmed, lower-cased, spaces as dashes.
    static func normalised(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Handles to suggest from a name and an email, best first: "Noor Haddad" → noor,
    /// noor-haddad, noorhaddad, noorh; then the email's local part.
    static func ideas(name: String?, email: String?) -> [String] {
        let words = plain(name ?? "").split { !isPlainAlnum($0) }.map(String.init)
        let local = runsToDashes(plain(String((email ?? "").split(separator: "@").first ?? "")))
        var out: [String] = []
        if let first = words.first {
            out += [first, words.joined(separator: "-"), words.joined()]
            if words.count > 1, let last = words.last {
                out += [first + String(last.prefix(1)), "\(first)-\(last)"]
            }
        }
        if !local.isEmpty { out.append(local) }
        var seen = Set<String>()
        return out.map { trimTrailingDashes(String($0.prefix(30))) }
            .filter { problem($0) == nil && seen.insert($0).inserted }
    }

    /// The link for a handle under the booking site's address (`https://book.bananatheapp.com`).
    static func link(base: String, handle: String) -> URL? {
        URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/\(handle)")
    }

    /// A link as shown: no scheme, no trailing slash.
    static func display(_ url: URL) -> String {
        var text = url.absoluteString
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    // MARK: - Plumbing

    /// Lower-case ASCII, accents taken off (NFKD less its marks, as the service does).
    private static func plain(_ text: String) -> String {
        String(String.UnicodeScalarView(text.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) })).lowercased()
    }

    private static func isPlainAlnum(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && c.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    private static func runsToDashes(_ text: String) -> String {
        var out = "", dash = false
        for c in text {
            if isPlainAlnum(c) {
                if dash, !out.isEmpty { out.append("-") }
                out.append(c)
                dash = false
            } else {
                dash = true
            }
        }
        return out
    }

    private static func trimTrailingDashes(_ text: String) -> String {
        var text = text
        while text.hasSuffix("-") { text.removeLast() }
        return text
    }
}
