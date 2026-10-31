#if !BANANA_PUBLIC
import Foundation
import GRDB

struct GmailPageScope: Equatable, Sendable {
    var account: String
    var labels: [String] = []
    var query: String? = nil
    var includeSpamTrash = false
}
struct GmailPageCursor: Equatable, Sendable {
    var scope: GmailPageScope
    var token: String
    var historyFloor: UInt64
}
struct GmailLoadedPage: Sendable {
    var next: GmailPageCursor?
    var messages: Int
    var change: MailStoreChange
}

/// Bounded enumeration/import building block. It does not claim the mailbox is in
/// sync or advance the history checkpoint: a complete enumeration plus history replay
/// is required for that. UI continuations are returned only after all commits succeed.
actor GmailPageLoader {
    typealias Token = @Sendable (String) async throws -> String
    private let api: any GmailAPI
    private let writer: MailWriter
    private let token: Token
    enum Failure: Error { case invalidScope, wrongAccount, malformed, invalidCursor }

    init(api: any GmailAPI, writer: MailWriter, token: @escaping Token) {
        self.api = api; self.writer = writer; self.token = token
    }

    func load(_ requested: GmailPageScope, after cursor: GmailPageCursor? = nil) async throws -> GmailLoadedPage {
        var scope = requested
        scope.account = scope.account.lowercased()
        scope.labels = Array(Set(scope.labels)).sorted()
        guard MailAddressRules.isValid(scope.account) else { throw Failure.invalidScope }
        if let cursor, cursor.scope != scope { throw Failure.invalidCursor }
        try Task.checkCancellation()
        let accessToken = try await token(scope.account)
        let floor: UInt64
        var total: Int?
        if let cursor { floor = cursor.historyFloor }
        else {
            let profile = try await api.profile(token: accessToken)
            guard profile.emailAddress?.lowercased() == scope.account else { throw Failure.wrongAccount }
            guard let history = profile.historyId else { throw Failure.malformed }
            floor = history; total = profile.messagesTotal
        }
        let page = try await api.listMessages(token: accessToken, labelIDs: scope.labels, query: scope.query,
            includeSpamTrash: scope.includeSpamTrash, pageToken: cursor?.token, maxResults: 50)
        let listed = page.messages ?? []
        guard listed.count <= 50 else { throw Failure.malformed }
        if let next = page.nextPageToken, next.isEmpty || next == cursor?.token { throw Failure.invalidCursor }
        var seen = Set<String>(), references: [GmailMessageRef] = []
        for reference in listed {
            guard let id = reference.id, !id.isEmpty else { throw Failure.malformed }
            if seen.insert(id).inserted { references.append(reference) }
        }
        let api = self.api
        // Four requests in flight; a page never spawns one task per retained message.
        let values = try await withThrowingTaskGroup(of: (Int, GmailMessage).self) { group in
            func add(_ index: Int) {
                let reference = references[index]
                group.addTask {
                    try Task.checkCancellation()
                    let value = try await api.message(token: accessToken, id: reference.id!, format: .header)
                    guard value.id == reference.id, let thread = value.threadId, !thread.isEmpty,
                          reference.threadId == nil || reference.threadId == thread else { throw Failure.malformed }
                    return (index, value)
                }
            }
            var next = 0
            while next < min(4, references.count) { add(next); next += 1 }
            var result: [(Int, GmailMessage)] = []
            while let value = try await group.next() {
                result.append(value)
                if next < references.count { add(next); next += 1 }
            }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation()
        let fetched = values.map { FetchedMessage(wire: $0, floor: floor, headers: MessageHeaders(payload: $0.payload), structure: nil) }
        var change = MailStoreChange()
        for offset in stride(from: 0, to: fetched.count, by: 20) {
            try Task.checkCancellation()
            let batch = Array(fetched[offset..<min(offset + 20, fetched.count)])
            let account = scope.account
            let committed = try await writer.transact { db in
                var change = MailStoreChange()
                for message in batch {
                    change.formUnion(try MailMessageImporter.apply(message, account: account, myAddresses: [account], in: db))
                }
                return change
            }
            change.formUnion(committed)
        }
        try Task.checkCancellation()
        if let total {
            let account = scope.account
            _ = try await writer.transact { db in
                try db.execute(sql: "INSERT INTO account(email,profile_total) VALUES (?,?) ON CONFLICT(email) DO UPDATE SET profile_total=excluded.profile_total",
                               arguments: [account, total])
                return MailStoreChange()
            }
        }
        return GmailLoadedPage(next: page.nextPageToken.map { GmailPageCursor(scope: scope, token: $0, historyFloor: floor) },
                               messages: fetched.count, change: change)
    }
}

#endif
