#if !BANANA_PUBLIC
import Foundation

/// Local reading aid over prepared visible text, never an attestation of sender or validity.
/// Bounded and run off the main actor; no HTML, remote fetch, model call or persisted code cache.
struct MailVerificationCode: Equatable, Sendable {
    var message: MailMessageID
    var value: String
    static let maximumCharacters = 16_384
    static let maximumBlocks = 256
    static let maximumRuns = 2_048

    private struct Line { var text: String; var plain: Bool }
    private static let label = #"(?<![A-Za-z])(?:one[ -]?time(?:[ -]+(?:verification|security))?[ -]+(?:code|password|passcode|pin)|(?:verification|security|authentication|log[ -]?in|sign[ -]?in|password[ -]+reset|two[ -]?factor|2fa)[ -]+(?:code|passcode)|otp(?:[ -]+code)?)(?![A-Za-z])"#
    private static let token = #"(?<![A-Za-z0-9])(?:[0-9]{3}[ \t-][0-9]{3}|[0-9]{4}[ \t-][0-9]{4}|[0-9]{2}(?:[ \t-][0-9]{2}){2}|[A-Za-z0-9](?:[ \t|]+[A-Za-z0-9]){3,9}|[A-Za-z]-[0-9]{4,10}|[A-Za-z0-9]{3,5}-[A-Za-z0-9]{3,5}|[A-Za-z0-9]{4,10})(?![A-Za-z0-9]|[./:\-][0-9])"#
    private static func regex(_ pattern: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) }
    private static let labelPattern = regex(label)
    private static let afterLabel = regex(label + #"(?:\s+is)?[\s:=–—\-\"“”'\[\]()]{0,24}("# + token + #")"#)
    private static let beforeLabel = regex(#"("# + token + #")\s+is\s+(?:your\s+|the\s+)"# + label)
    private static let standalone = regex(#"^\s*("# + token + #")\s*$"#)
    private static let action = regex(#"\b(?:log[ -]?in|logging[ -]?in|sign[ -]?in|signing[ -]?in|authenticat\w*|confirm(?:ing|ed)?\s+(?:your\s+|this\s+|the\s+)?(?:email|account|identity|sign[ -]?in)|verif(?:y|ying)\s+(?:your\s+|this\s+|the\s+)?(?:email|account|identity)|reset\s+(?:your\s+|the\s+)?password|activate\s+(?:your\s+|the\s+)?account|code.{0,100}(?:verification|authentication|verify|log[ -]?in|access.{0,30}account))\b"#)
    private static let meeting = regex(#"\b(?:meeting|conference|webinar)\s+(?:id|passcode|password)\b|\bjoin\s+(?:(?:the|a)\s+)?(?:meeting|conference|webinar)\b"#)
    private static let instruction = regex(#"\b(?:code|pin|passcode)\b"#)
    private static let otherRole = regex(#"\b(?:promo|referral|coupon|discount|sale|offer|voucher|donation|booking|reservation|order|invoice|shipping|tracking|reference|purchase|reward|redemption|perk|deal|ticket)s?\b"#)
    private static let genericAfter = regex(#"^\s*(?:(?:your(?:\s+[^\s:]{1,24}){0,3}\s+)?(?:code|passcode|pin)(?:\s+is)?|(?:confirmation|activation|launch)\s+code)[\s:=–—\-]{0,24}("# + token + #")[.!\s]*$"#)
    private static let instructedCode = regex(#"\b(?:your\s+(?:temporary\s+)?code|(?:following|activation)\s+code)(?:\s+is)?\s*:\s*("# + token + #")"#)
    private static let enterCode = regex(#"\b(?:enter|use)\b[^\n:]{0,120}\bcode\b[^\n:]{0,80}:\s*("# + token + #")"#)
    private static let genericBefore = regex(#"^\s*("# + token + #")\s+is\s+your\s+[^\n]{0,64}\b(?:code|pin|passcode)[.!\s]*$"#)

    private static func has(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
        pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func extract(subject: String, body: MailBody, allowSubjectCode: Bool = true) -> String? {
        let subject = String(subject.prefix(512))
        let prefix = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.hasPrefix("fwd:"), !prefix.hasPrefix("fw:") else { return nil }
        let plain: MailText?, quoteStart: Int?
        switch body {
        case .notOnDevice: plain = nil; quoteStart = nil
        case .text(let text, let start, _): plain = text; quoteStart = start
        case .designed(_, _, _, let text, _): plain = text; quoteStart = nil
        }
        var lines: [Line] = [], remaining = maximumCharacters - subject.count, runs = maximumRuns, stopped = false
        func append(_ text: String, plain: Bool) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines), lower = value.lowercased()
            if value.hasPrefix(">") || lower.hasPrefix("-----original message") || lower.hasPrefix("begin forwarded message") || (lower.hasPrefix("on ") && lower.hasSuffix("wrote:")) { stopped = true; return }
            if !value.isEmpty { lines.append(Line(text: value, plain: plain)) }
        }
        if let plain {
            for (index, block) in plain.blocks.prefix(maximumBlocks).enumerated() {
                guard remaining > 0, runs > 0, !stopped else { break }
                if let quoteStart, index >= quoteStart { break }
                if case .quote = block.kind { break }
                switch block.kind { case .picture, .rule: continue; default: break }
                var current = "", hasPlain = false
                for run in block.runs.prefix(runs) {
                    guard remaining > 0, !stopped else { break }
                    let part = String(run.text.prefix(remaining)); remaining -= part.count; runs -= 1
                    for (partIndex, piece) in part.components(separatedBy: .newlines).enumerated() {
                        if partIndex > 0 { append(current, plain: hasPlain); current = ""; hasPlain = false }
                        guard !stopped else { break }
                        current += piece
                        if run.link == nil && !piece.trimmingCharacters(in: .whitespaces).isEmpty { hasPlain = true }
                    }
                }
                if !stopped { append(current, plain: hasPlain) }
                remaining -= 1
            }
        }
        // Link-only actions (e.g. a VERIFY button) are not code payloads.
        let own = lines.map { $0.plain ? $0.text : "\u{FFFC}" }.joined(separator: "\n")
        let text = (allowSubjectCode ? subject + "\n" : "") + own
        let strongSubject = has(labelPattern, subject)
        let strongContext = strongSubject || has(labelPattern, own)
        let authContext = strongContext || has(action, subject) || has(action, own)
        if !strongContext && has(meeting, own) { return nil }
        var candidates: [String: Set<String>] = [:]
        func add(_ raw: String, letters: Bool = false, anyCase: Bool = false) {
            guard let value = normalized(raw, letters: letters, anyCase: anyCase) else { return }
            let parts = value.split(separator: "-")
            let key: String
            if parts.count == 2, parts[0].count == 1, parts[0].allSatisfy(\.isLetter), parts[1].allSatisfy(\.isNumber) { key = String(parts[1]) }
            else { key = value }
            candidates[key, default: []].insert(value)
        }
        for pattern in [afterLabel, beforeLabel].compactMap({ $0 }) {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { add(String(text[range])) }
            }
        }
        if authContext && (!has(meeting, own) || strongSubject) && (strongContext || !has(otherRole, subject)) {
            if allowSubjectCode, strongSubject || !has(otherRole, subject) {
                for pattern in [genericAfter, genericBefore].compactMap({ $0 }) {
                    if let match = pattern.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)), let range = Range(match.range(at: 1), in: subject) { add(String(subject[range]), letters: true, anyCase: true) }
                }
            }
            for (index, line) in lines.enumerated() where line.plain {
                let preceding = index > 0 ? lines[index - 1].text : ""
                let anchored = has(instruction, preceding) && !has(otherRole, preceding)
                if let match = standalone?.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)), let range = Range(match.range(at: 1), in: line.text) {
                    let raw = String(line.text[range])
                    if anchored || (strongSubject && index < 4 && raw.filter(\.isNumber).count == 6) { add(raw, letters: anchored) }
                }
                if !has(otherRole, line.text) {
                    for pattern in [genericAfter, genericBefore, instructedCode, enterCode].compactMap({ $0 }) {
                        if let match = pattern.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)), let range = Range(match.range(at: 1), in: line.text) { add(String(line.text[range])) }
                    }
                }
            }
        }
        guard candidates.count == 1, let values = candidates.values.first else { return nil }
        // A plain numeric representation corroborates a prefixed form of that same code.
        if let numeric = values.first(where: { $0.allSatisfy(\.isNumber) }) { return numeric }
        return values.count == 1 ? values.first : nil
    }

    private static func normalized(_ token: String, letters: Bool, anyCase: Bool) -> String? {
        let compact = token.filter { !$0.isWhitespace && $0 != "|" }
        let digits = compact.filter(\.isNumber), bare = compact.filter { $0 != "-" }
        if digits.count == bare.count {
            guard (4...10).contains(digits.count), !(compact.count == 10 && compact.dropFirst(4).first == "-" && compact.dropFirst(7).first == "-") else { return nil }
            return digits
        }
        let parts = compact.split(separator: "-")
        if parts.count == 2, parts[0].count == 1, parts[0].allSatisfy(\.isLetter), (4...10).contains(parts[1].count), parts[1].allSatisfy(\.isNumber) { return compact }
        guard (4...10).contains(bare.count), bare.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        if digits.isEmpty {
            let grouped = parts.map(\.count) == [4, 4] && compact == compact.uppercased()
            guard grouped || (letters && (4...8).contains(bare.count) && (anyCase || compact == compact.uppercased())) else { return nil }
        }
        return compact
    }
}
#endif
