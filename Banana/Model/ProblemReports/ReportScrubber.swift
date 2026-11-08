import Foundation

/// Takes the person's own words out of log lines before they leave the device: event and task
/// titles, episode names, email subjects, addresses, links, long numbers and tokens. What stays is
/// the log's own vocabulary and its readings ("🌀 STORM: occurrences↻ at 154/s cpu=92%").
///
/// Two layers. Lines that name something of the person's mark it where they are written
/// (`PlaybackDiagnostics.personal(_:)`, invisible in the local log); those marks go first. Then
/// what can be recognised whatever wrote it: anything quoted, addresses, links, digits that could
/// be a phone or an account, long tokens. Pure, for tests.
enum ReportScrubber {
    /// Stands for what was taken out.
    static let hidden = "‹›"

    /// The marks `PlaybackDiagnostics.personal(_:)` puts around a personal value: FIRST STRONG
    /// ISOLATE and POP DIRECTIONAL ISOLATE, which draw nothing in a log reader.
    static let open: Character = "\u{2068}"
    static let close: Character = "\u{2069}"

    static func mark(_ value: String) -> String {
        // A value that itself holds a mark can't end the span early.
        let clean = value.replacingOccurrences(of: String(open), with: "").replacingOccurrences(of: String(close), with: "")
        return "\(open)\(clean)\(close)"
    }

    private static let patterns: [NSRegularExpression] = [
        // Anything quoted, in straight or curly quotes: titles, subjects, search words.
        #""[^"\n]*""#,
        #"“[^”\n]*”"#,
        #"‘[^’\n]*’"#,
        #"«[^»\n]*»"#,
        // Addresses.
        #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
        // Links: the host stays (which service failed is useful), the path and query go.
        #"(?<=[a-z]://)[^/\s]+(/[^\s]*)"#,
        // Long hex and base64-ish runs: tokens, push tokens, message ids.
        #"\b[A-Fa-f0-9]{24,}\b"#,
        #"\b[A-Za-z0-9_\-]{40,}\b"#,
        // Phone numbers and account numbers: seven or more digits, maybe with separators.
        #"(?<![\d.])\+?\d(?:[\d \-().]{5,}\d)(?![\d.])"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// One line, scrubbed.
    static func scrub(_ line: String) -> String {
        var text = removeMarked(line)
        for (index, pattern) in patterns.enumerated() {
            let range = NSRange(text.startIndex..., in: text)
            if index == 5 {
                // Keep the scheme and host, drop the path (capture group 1).
                var out = text
                for match in pattern.matches(in: text, range: range).reversed() {
                    if let path = Range(match.range(at: 1), in: text) { out.replaceSubrange(path, with: "/" + hidden) }
                }
                text = out
                continue
            }
            if index == patterns.count - 1 {
                var out = text
                for match in pattern.matches(in: text, range: range).reversed() {
                    guard let found = Range(match.range, in: text), looksLikeAPhoneOrAccount(text, found) else { continue }
                    out.replaceSubrange(found, with: hidden)
                }
                text = out
                continue
            }
            text = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: hidden)
        }
        return text
    }

    /// Seven digits or more that aren't a reading (`syscalls=1234567`), a time (`10:00:00`) or a
    /// date (`2026-11-08`): with separators or a "+" they read as a phone; ten or more in a row as
    /// an account or card number.
    private static func looksLikeAPhoneOrAccount(_ text: String, _ range: Range<String.Index>) -> Bool {
        let match = text[range]
        let digits = match.filter(\.isNumber).count
        guard digits >= 7 else { return false }
        if range.lowerBound > text.startIndex, ["=", ":"].contains(text[text.index(before: range.lowerBound)]) { return false }
        if match.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return false }
        let separated = match.contains { " -().".contains($0) }
        return separated || match.hasPrefix("+") || digits >= 10
    }

    /// Lines, scrubbed, newest last, at most `limit` of them.
    static func scrub(lines: [String], limit: Int = 200) -> [String] {
        lines.suffix(limit).map(scrub)
    }

    /// Spans between the marks, gone. An open mark with no close takes the rest of the line.
    private static func removeMarked(_ line: String) -> String {
        guard line.contains(open) || line.contains(close) else { return line }
        var out = ""
        var inside = false
        for character in line {
            if character == open { if !inside { out += hidden }; inside = true; continue }
            if character == close { inside = false; continue }
            if !inside { out.append(character) }
        }
        return out
    }
}
