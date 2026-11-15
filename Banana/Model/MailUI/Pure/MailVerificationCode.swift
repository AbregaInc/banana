#if !BANANA_PUBLIC
import Foundation

/// A local reading aid, never a claim that a code is valid or that its sender is trusted.
/// Apple's oneTimeCode content type is for entry fields; DataDetector has no email OTP entity.
/// Work on prepared visible text off the main actor, without HTML, URLs, images or model calls.
struct MailVerificationCode: Equatable, Sendable {
    var message: MailMessageID
    var value: String

    static let maximumCharacters = 16_384
    static let maximumBlocks = 256
    static let maximumRuns = 2_048
    private static let label = #"(?<![A-Za-z])(?:one[ -]?time(?:[ -]+(?:verification|security))?[ -]+(?:code|password|passcode)|(?:verification|security|authentication|log[ -]?in|sign[ -]?in|password[ -]+reset|two[ -]?factor|2fa)[ -]+(?:code|passcode)|otp|passcode)(?![A-Za-z])"#
    private static let token = #"(?<![A-Za-z0-9])(?:[0-9]{3}[ \t-][0-9]{3}|[0-9]{4}[ \t-][0-9]{4}|[0-9]{2}(?:[ \t-][0-9]{2}){2}|[0-9](?:[ \t][0-9]){3,7}|[0-9]{4,8}|[A-Za-z0-9]{3,5}-[A-Za-z0-9]{3,5}|[A-Za-z0-9]{6,10})(?![A-Za-z0-9]|[./:\-][0-9])"#
    private static let labelPattern = try? NSRegularExpression(pattern: label, options: .caseInsensitive)
    private static let afterLabel = try? NSRegularExpression(
        pattern: label + #"(?:\s+is)?[\s:=–—\-\"“”'\[\]()]{0,24}("# + token + #")"#, options: .caseInsensitive)
    private static let beforeLabel = try? NSRegularExpression(
        pattern: #"("# + token + #")[\s:=–—\-\"“”'\[\]()]{0,12}(?:is\s+)?(?:your\s+|the\s+)?"# + label, options: .caseInsensitive)
    private static let subjectCode = try? NSRegularExpression(
        pattern: #"(?:^|[\r\n])(?:your\s+)?code(?:\s+is)?[\s:=–—\-\"“”'\[\]()]{0,24}("# + token + #")"#, options: .caseInsensitive)
    private static let standalone = try? NSRegularExpression(pattern: #"^\s*("# + token + #")\s*$"#)

    static func extract(subject: String, body: MailBody, allowSubjectCode: Bool = true) -> String? {
        let subject = String(subject.prefix(512))
        let prefix = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.hasPrefix("fwd:"), !prefix.hasPrefix("fw:") else { return nil }
        var lines: [String] = [], remaining = maximumCharacters - subject.count, remainingRuns = maximumRuns
        let plain: MailText?, quoteStart: Int?
        switch body {
        case .notOnDevice: plain = nil; quoteStart = nil
        case .text(let text, let start, _): plain = text; quoteStart = start
        case .designed(_, _, _, let text, _): plain = text; quoteStart = nil
        }
        if let plain {
            for (index, block) in plain.blocks.prefix(maximumBlocks).enumerated() {
                if let quoteStart, index >= quoteStart { break }
                if case .quote = block.kind { break }
                switch block.kind {
                case .picture, .fineprint, .rule: continue
                default: break
                }
                guard remaining > 0, remainingRuns > 0 else { break }
                var line = ""
                for run in block.runs.prefix(remainingRuns) {
                    guard remaining > 0 else { break }
                    let part = String(run.text.prefix(remaining))
                    line += part; remaining -= part.count; remainingRuns -= 1
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                if trimmed.hasPrefix(">") || lower.hasPrefix("-----original message") || lower.hasPrefix("begin forwarded message") || (lower.hasPrefix("on ") && lower.hasSuffix("wrote:")) { break }
                lines.append(line)
                remaining -= 1
            }
        }
        let text = (allowSubjectCode ? subject + "\n" : "") + lines.joined(separator: "\n")
        var candidates = Set<String>()
        for pattern in [afterLabel, beforeLabel].compactMap({ $0 }) {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text), let code = normalized(String(text[range])) { candidates.insert(code) }
            }
        }
        // Some messages label only the subject and put the code on its own line. Do not
        // turn four-digit account tails, dates, order references or footer numbers into codes.
        if labelPattern?.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil {
            let visible = lines.joined(separator: "\n")
            if let subjectCode {
                for match in subjectCode.matches(in: visible, range: NSRange(visible.startIndex..., in: visible)) {
                    if let range = Range(match.range(at: 1), in: visible), let code = normalized(String(visible[range])) { candidates.insert(code) }
                }
            }
            for line in lines.prefix(12) {
                for piece in line.split(separator: "\n") {
                    let value = String(piece)
                    guard let match = standalone?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                          let range = Range(match.range(at: 1), in: value), let code = normalized(String(value[range])) else { continue }
                    if code.count == 6 || (code.contains(where: { $0.isLetter }) && code.contains(where: { $0.isNumber })) { candidates.insert(code) }
                }
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func normalized(_ token: String) -> String? {
        let digits = token.filter { $0 >= "0" && $0 <= "9" }
        let compact = token.filter { !$0.isWhitespace && $0 != "-" }
        if digits.count == compact.count {
            guard (4...8).contains(digits.count), !token.contains("/"), !token.contains(":"),
                  !(token.count == 10 && token.dropFirst(4).first == "-" && token.dropFirst(7).first == "-") else { return nil }
            return digits
        }
        guard (6...10).contains(compact.count), compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              (!digits.isEmpty || (token.split(separator: "-").map(\.count) == [4, 4] && token == token.uppercased())) else { return nil }
        return token.filter { !$0.isWhitespace }
    }
}
#endif
