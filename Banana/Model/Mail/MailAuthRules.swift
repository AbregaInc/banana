#if !BANANA_PUBLIC
import Foundation

/// Which domain Gmail itself vouched for as the sender of a message (MAIL-ENGINE 10.6).
///
/// A `From` line is free to forge, so "always show pictures from this sender" cannot be keyed
/// on it. What cannot be forged by the sender is what Google wrote about the message when it
/// received it: Gmail adds an `Authentication-Results` header, saying whether the message's DMARC,
/// DKIM and SPF checks passed and for which domain. This reads that, and only that.
///
/// **Which header: the first `Authentication-Results` of the message, and only if it is
/// Gmail's.** Gmail writes its own on receipt, above everything the message arrived with. So the
/// reader does not look past another server's header for one that says `mx.google.com`: if the
/// first names any other server, Gmail wrote none and nothing is authenticated, whatever sits
/// below. Its authserv-id — the first word of its value, comments aside, compared without
/// regard to case — must be `mx.google.com`. It is unfolded before it is read. A second one,
/// whatever it says, is ignored. One that was **cut** (its value over the 16 KB a header value is
/// kept to) is not read at all: a sender can lengthen what Gmail writes there, and a result cut
/// away is unknown, not absent. `ARC-Authentication-Results` is another header and is never read.
///
/// **What no reading can tell:** a message that did not come through Gmail's own receiving
/// servers — imported, or put there by another program with access to his account — may have
/// no header of Gmail's, and then the first one is whatever its author wrote. Position is all
/// there is to go on. What such a forgery buys is pictures loading without being asked and a
/// one-click unsubscribe being offered, for a message somebody with access to his mailbox put
/// there; it is accepted, and said (10.6).
///
/// **What the authenticated domain is: the one Gmail vouched for *and* that speaks for the From
/// line.** A message can pass DKIM for its mailing service's domain and SPF for a bounce
/// domain, and neither is the sender he sees. So a result counts only if it is tied to the From
/// domain, and the results are read in this order, the first that counts winning:
///
/// 1. `dmarc=pass` whose `header.from` is the From domain, exactly. DMARC passing *is* Gmail
///    saying that DKIM or SPF passed for a domain aligned with the From line, and it does the
///    alignment with the public-suffix list, which Banana does not have. The answer is the From
///    domain.
/// 2. `dkim=pass`, for the signing domain: `header.d` if the result carries it, otherwise the
///    domain of `header.i` (what follows its last `@`). It counts when it is the From domain or
///    a parent of it on a dot boundary. Each `dkim=pass` result is tried, in order.
/// 3. `spf=pass`, for the domain of `smtp.mailfrom` (what follows its `@`, or the whole value),
///    under the same test.
///
/// **Both spellings of a DKIM result are read because which one Gmail writes is not verified**:
/// it is believed to write `header.i=@example.com` and not `header.d`, and reading only the
/// design's first text would have authenticated nobody and failed nothing. The read probe
/// records what Gmail writes (19.2, item 11); a test holds each form.
enum MailAuthRules {

    /// The authserv-id that is Gmail's own.
    static let googleServerID = "mx.google.com"

    /// The domain Gmail authenticated for a message whose headers are `headers`, in order, when
    /// it speaks for `fromDomain` (above); else nil.
    ///
    /// These are pairs, so what was cut is not known: a value of 16 KB or more is taken to have
    /// been, and the header is not read. `MessageHeaders` knows, and has its own overload.
    ///
    /// - Parameters:
    ///   - headers: every header, name and value, topmost first.
    ///   - fromDomain: the domain of the `From` address, in the ASCII form `MailAddress` gives.
    static func authenticatedDomain(headers: [(String, String)], fromDomain: String) -> String? {
        guard case .results(let results) = firstHeader(pairs: headers) else { return nil }
        return authenticatedDomain(results: results, fromDomain: fromDomain)
    }

    /// The same, from a message's headers.
    static func authenticatedDomain(headers: MessageHeaders, fromDomain: String) -> String? {
        guard case .results(let results) = firstHeader(of: headers) else { return nil }
        return authenticatedDomain(results: results, fromDomain: fromDomain)
    }

    /// Whether Gmail's own header, where it carries a `dmarc=` result of any verdict, names
    /// `domain` as its `header.from` — true when it carries none, or when Gmail wrote no header
    /// to read. False when a `dmarc=` result names another domain or none, and when the header
    /// is Gmail's and was cut (a result that cannot be read is not agreement). It is how
    /// `MessageHeaders.sender` learns that Gmail read the `From` line as someone else.
    static func dmarcAgrees(headers: MessageHeaders, with domain: String) -> Bool {
        switch firstHeader(of: headers) {
        case .absent:
            return true
        case .cut:
            return false
        case .results(let results):
            let want = normalizedDomain(domain)
            return results.filter { $0.method == "dmarc" }.allSatisfy { result in
                result.properties["header.from"].map(normalizedDomain) == want
            }
        }
    }

    // MARK: - Which header

    private enum First {
        /// The message has no `Authentication-Results`, or its first is another server's.
        case absent
        /// The first is Gmail's and was cut.
        case cut
        case results([Result])
    }

    private static func firstHeader(pairs: [(String, String)]) -> First {
        guard let first = pairs.first(where: { isAuthenticationResults($0.0) }) else { return .absent }
        return read(first.1, cut: first.1.utf8.count >= MessageHeaders.maxValueBytes)
    }

    private static func firstHeader(of headers: MessageHeaders) -> First {
        guard let first = headers.field("Authentication-Results") else { return .absent }
        return read(first.value, cut: first.wasCut)
    }

    private static func read(_ value: String, cut: Bool) -> First {
        // Whose it is shows in the first word, which a cut leaves whole. A value that is empty
        // *and* marked cut is a header Gmail sent with no value at all: it may have been Gmail's
        // own, it holds the first place, and it is unknown, not another server's.
        guard serverID(of: value) == googleServerID else { return cut && value.isEmpty ? .cut : .absent }
        return cut ? .cut : .results(parse(value))
    }

    private static func authenticatedDomain(results: [Result], fromDomain: String) -> String? {
        let from = normalizedDomain(fromDomain)
        guard !from.isEmpty else { return nil }

        // 1. DMARC says Gmail itself found the From domain aligned.
        for result in results where result.method == "dmarc" && result.verdict == "pass" {
            if let named = result.properties["header.from"], normalizedDomain(named) == from {
                return from
            }
        }
        // 2. A DKIM signature for the From domain or a parent of it.
        for result in results where result.method == "dkim" && result.verdict == "pass" {
            let signing = result.properties["header.d"]
                ?? result.properties["header.i"].flatMap { domainAfterLastAt($0) }
            if let signing {
                let domain = normalizedDomain(signing)
                if isAligned(domain, with: from) { return domain }
            }
        }
        // 3. An SPF pass for the bounce domain, under the same test.
        for result in results where result.method == "spf" && result.verdict == "pass" {
            if let mailFrom = result.properties["smtp.mailfrom"] {
                let domain = normalizedDomain(domainAfterLastAt(mailFrom) ?? mailFrom)
                if isAligned(domain, with: from) { return domain }
            }
        }
        return nil
    }

    /// What follows the last `@`; nil if there is none. The last, because the part before it is
    /// the sender's to write and Gmail may not have escaped it.
    private static func domainAfterLastAt(_ value: String) -> String? {
        value.lastIndex(of: "@").map { String(value[value.index(after: $0)...]) }
    }

    // MARK: - Reading the header

    private struct Result {
        let method: String
        let verdict: String
        /// `ptype.property` → value, both lower-cased in the key; the value as written, unquoted.
        let properties: [String: String]
    }

    private static func isAuthenticationResults(_ name: String) -> Bool {
        MessageHeaders.fold(name) == "authentication-results"
    }

    /// The first word of the value: the authserv-id, lower case. Comments before it are not
    /// part of it.
    private static func serverID(of value: String) -> String {
        let head = segments(of: value).first ?? ""
        let word = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        return word.lowercased()
    }

    /// The results after the authserv-id, in order, each a `method=verdict` and its properties.
    private static func parse(_ value: String) -> [Result] {
        var results: [Result] = []
        for segment in segments(of: value).dropFirst() {
            // `method = verdict`, properties as `ptype.property = value`: spaces around the
            // `=` are allowed, so take them out before cutting into words.
            let words = tightenEquals(segment).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = words.first, let equals = first.firstIndex(of: "=") else { continue }
            let method = first[..<equals].lowercased()
            let verdict = first[first.index(after: equals)...].lowercased()
            var properties: [String: String] = [:]
            for word in words.dropFirst() {
                guard let eq = word.firstIndex(of: "="), word.contains(".") else { continue }
                let key = word[..<eq].lowercased()
                // The first of each, as a verifier writes them in order of importance.
                if properties[key] == nil {
                    properties[key] = unquote(String(word[word.index(after: eq)...]))
                }
            }
            results.append(Result(method: method, verdict: verdict, properties: properties))
        }
        return results
    }

    /// The value cut at each `;` that is outside a comment and a quoted string, the comments
    /// taken out. One pass; a comment or a quote that never closes runs to the end, which can
    /// only drop what follows it, never add to it.
    private static func segments(of value: String) -> [String] {
        var segments: [String] = []
        var current = String.UnicodeScalarView()
        var depth = 0
        var inQuote = false
        var escaped = false
        for scalar in value.unicodeScalars {
            if escaped { escaped = false; if depth == 0 { current.append(scalar) }; continue }
            if scalar == "\\" { escaped = true; continue }
            if inQuote {
                if scalar == "\"" { inQuote = false }
                current.append(scalar)
                continue
            }
            switch scalar {
            case "(":
                depth += 1
            case ")" where depth > 0:
                depth -= 1
                if depth == 0 { current.append(" ") }
            case _ where depth > 0:
                break
            case "\"":
                inQuote = true
                current.append(scalar)
            case ";":
                segments.append(String(current))
                current = String.UnicodeScalarView()
            case "\r", "\n":
                current.append(" ")
            default:
                current.append(scalar)
            }
        }
        segments.append(String(current))
        return segments
    }

    /// `a = b` → `a=b`, outside quotes.
    private static func tightenEquals(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inQuote = false
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar == "\"" { inQuote.toggle() }
            if !inQuote, scalar == " " || scalar == "\t" {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                // A space is kept unless it sits next to an `=`.
                if scalar != "=", out.last != "=" { out.append(" ") }
                pendingSpace = false
            }
            out.append(scalar)
        }
        return String(out)
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast())
    }

    // MARK: - Domains

    /// Lower case, no trailing dot.
    private static func normalizedDomain(_ domain: String) -> String {
        var d = domain.trimmingCharacters(in: .whitespaces).lowercased()
        while d.hasSuffix(".") { d.removeLast() }
        return d
    }

    /// Whether `domain` is `from` or a parent of it on a dot boundary. A name with no dot is
    /// never a signing domain, and one with anything but letters, digits, hyphen, underscore
    /// and dots is not a domain.
    private static func isAligned(_ domain: String, with from: String) -> Bool {
        guard domain.contains("."), !domain.hasPrefix("."), !domain.contains("..") else { return false }
        for byte in domain.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
                continue
            default:
                return false
            }
        }
        return domain == from || from.hasSuffix("." + domain)
    }
}

#endif
