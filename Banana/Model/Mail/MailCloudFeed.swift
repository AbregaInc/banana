#if !BANANA_PUBLIC
import Foundation

/// One page of Banana Cloud's shared mailbox feed (MAIL-CLOUD-SYNC §4). Each entry is a message's
/// latest state as the cloud has it — its label set exact, `history` the Gmail position that set
/// reflects — or a deletion Gmail stated. Each message appears once, at its newest state.
struct MailCloudFeedPage: Decodable, Equatable, Sendable {
    struct Entry: Decodable, Equatable, Sendable {
        var id: String
        var thread: String?
        var history: String
        var date: Int64?
        var labels: [String]?
        var deleted: Bool?
    }
    var epoch: String
    var cursor: String
    var more: Bool
    var complete: Bool
    var entries: [Entry]
}

enum MailCloudFeedError: Error, Equatable, Sendable {
    /// The service has no feed for this account (one not yet upgraded): the Gmail path stays.
    case unavailable
    /// The cursor is older than what the feed keeps: start again from zero.
    case expired
}

/// The feed and the catch-up check, one request each. Retries and state belong above this.
protocol MailCloudFeedSource: Sendable {
    func page(account: String, after: String?, limit: Int, fresh: Bool) async throws -> MailCloudFeedPage
    /// Names ids this device holds that the feed never did; the answers arrive through the feed.
    func check(account: String, ids: [String]) async throws
}

#endif
