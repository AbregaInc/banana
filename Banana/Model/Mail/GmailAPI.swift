#if !BANANA_PUBLIC
import Foundation

/// Each method is one request. Retry, durable intent and sync checkpoints belong above this boundary.
protocol GmailAPI: Sendable {
    func profile(token: String) async throws -> GmailProfile
    func labels(token: String) async throws -> [GmailLabel]
    func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool,
                      pageToken: String?, maxResults: Int) async throws -> GmailIDPage
    func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage
    /// Direct reads normalize omitted labels to []; malformed label arrays throw.
    /// History messages deliberately keep omitted labels unknown.
    func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage
    func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread
    func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody
    func modify(token: String, id: String, add: [String], remove: [String]) async throws
    func trash(token: String, id: String) async throws
    func untrash(token: String, id: String) async throws
}

enum GmailError: Error, Equatable, Sendable {
    case neverLeft, unknownOutcome, unauthorized, scopeMissing, apiDisabled, domainPolicy
    case limited(GmailLimit, retryAfter: TimeInterval?)
    case notFound, conflict, refused(GmailReason), server(Int), unexplained(Int), malformed
    case networkDisabled, responseTooLarge
}
enum GmailLimit: Equatable, Sendable { case user, project, concurrent, bandwidth, sending }
enum GmailReason: String, Sendable { case invalidArgument, failedPrecondition, tooLarge, invalidTo, labelLimit, other }

enum GmailHTTPRules {
    /// Only a structured provider rejection can establish absence. Proxy HTML 404 is not deletion evidence.
    static func failure(status: Int, data: Data, retryAfter: TimeInterval?) -> GmailError {
        struct Envelope: Decodable {
            struct Detail: Decodable {
                struct Reason: Decodable { let reason: String? }
                let status: String?
                let errors: [Reason]?
                let details: [Reason]?
            }
            let error: Detail
        }
        let detail = try? JSONDecoder().decode(Envelope.self, from: data).error
        let reasons = Set((detail?.errors ?? []).compactMap(\.reason) + (detail?.details ?? []).compactMap(\.reason))
        if status == 401 { return .unauthorized }
        if status >= 500 { return .server(status) }
        if status == 429 { return .limited(.user, retryAfter: retryAfter) }
        if status == 403 {
            if reasons.contains("insufficientPermissions") || reasons.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || detail?.status == "ACCESS_TOKEN_SCOPE_INSUFFICIENT" { return .scopeMissing }
            if reasons.contains("accessNotConfigured") || reasons.contains("SERVICE_DISABLED") || detail?.status == "SERVICE_DISABLED" { return .apiDisabled }
            if reasons.contains("domainPolicy") { return .domainPolicy }
            if reasons.contains("userRateLimitExceeded") { return .limited(.user, retryAfter: retryAfter) }
            if reasons.contains("rateLimitExceeded") || reasons.contains("dailyLimitExceeded") { return .limited(.project, retryAfter: retryAfter) }
        }
        guard let detail else { return .unexplained(status) }
        if status == 404 && (reasons.contains("notFound") || detail.status == "NOT_FOUND") { return .notFound }
        if status == 409 { return .conflict }
        let reason = reasons.compactMap(GmailReason.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }.first ?? .other
        return .refused(reason)
    }

    static func transport(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        guard let error = error as? URLError else { return GmailError.unknownOutcome }
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff:
            return GmailError.neverLeft
        default: return GmailError.unknownOutcome
        }
    }
}

#endif
