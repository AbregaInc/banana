#if !BANANA_PUBLIC
import Foundation

/// A page plan must be computed and applied against the same index transaction.
/// Deletions still require the removal hold policy; this value never authorizes a purge.
struct MailHistoryPlan: Equatable, Sendable {
    var createStubs: [NewStub] = []
    var setLabels: [LabelChange] = []
    var delete: [String] = []
    var fetch: [String] = []
    var echoes: [EchoedIntent] = []
    var unknownLabels: Set<String> = []
}

enum MailHistoryRules {
    enum Failure: Error { case incomplete, unordered, conflictingLabels }

    /// Initial implementation for the live source's `everything` retention policy.
    /// Delta membership never makes an unknown message's complete label set known.
    static func plan(_ records: [GmailHistoryRecord], account: String,
                     known: (String) -> StoredMessageState?, knownLabel: (String) -> Bool,
                     tombstoned: (String) -> Bool) throws -> MailHistoryPlan {
        var result = MailHistoryPlan()
        var stubs: [String: NewStub] = [:]
        var deleted = Set<String>()
        var versions: [String: UInt64] = [:]
        var previous: UInt64 = 0
        func id(_ change: GmailHistoryChange) throws -> String {
            guard let id = change.message?.id, !id.isEmpty else { throw Failure.incomplete }
            return id
        }
        func discover(_ change: GmailHistoryChange, id: String, at version: UInt64) throws {
            guard let thread = change.message?.threadId, !thread.isEmpty else { throw Failure.incomplete }
            if let existing = stubs[id], existing.threadID != thread { throw Failure.incomplete }
            stubs[id] = NewStub(gmailID: id, threadID: thread, fetchClass: 2, listRank: 0, historyID: version)
        }
        for record in records {
            guard let version = record.id, version > 0 else { throw Failure.incomplete }
            guard version > previous else { throw Failure.unordered }
            previous = version
            guard !(record.messagesAdded ?? []).isEmpty || !(record.messagesDeleted ?? []).isEmpty ||
                  !(record.labelsAdded ?? []).isEmpty || !(record.labelsRemoved ?? []).isEmpty else {
                throw Failure.incomplete
            }
            for change in record.messagesAdded ?? [] {
                let message = try id(change)
                guard known(message) == nil, !tombstoned(message), !deleted.contains(message) else { continue }
                try discover(change, id: message, at: version)
            }
            var deltas: [String: LabelChange] = [:]
            for (changes, adding) in [(record.labelsAdded ?? [], true), (record.labelsRemoved ?? [], false)] {
                for change in changes {
                    let message = try id(change)
                    guard let labels = change.labelIds, !labels.isEmpty,
                          labels.allSatisfy({ !$0.isEmpty }) else { throw Failure.incomplete }
                    guard !tombstoned(message), !deleted.contains(message) else { continue }
                    guard let state = known(message) else {
                        try discover(change, id: message, at: version)
                        continue
                    }
                    guard state.vis != 4, version > (versions[message] ?? state.historyID ?? 0) else { continue }
                    var delta = deltas[message] ?? LabelChange(messageID: message, add: [], remove: [], recordID: version)
                    if adding { delta.add.formUnion(labels) } else { delta.remove.formUnion(labels) }
                    guard delta.add.isDisjoint(with: delta.remove) else { throw Failure.conflictingLabels }
                    deltas[message] = delta
                }
            }
            // Both sides of one record compare against its starting history position.
            for message in deltas.keys.sorted() {
                let delta = deltas[message]!
                versions[message] = version
                result.setLabels.append(delta)
                for (labels, want) in [(delta.add, true), (delta.remove, false)] {
                    for label in labels.sorted() {
                        if !knownLabel(label) { result.unknownLabels.insert(label) }
                        result.echoes.append(EchoedIntent(account: account, messageID: message,
                            labelID: label, want: want, recordID: version))
                    }
                }
            }
            for change in record.messagesDeleted ?? [] {
                let message = try id(change)
                if let state = known(message) {
                    guard state.vis != 4, version > (state.historyID ?? 0), !tombstoned(message) else { continue }
                } else if stubs[message] == nil { continue }
                deleted.insert(message)
                stubs[message] = nil
            }
        }
        result.createStubs = stubs.values.sorted { $0.gmailID < $1.gmailID }
        result.fetch = result.createStubs.map(\.gmailID)
        result.delete = deleted.filter { known($0) != nil }.sorted()
        result.setLabels.removeAll { deleted.contains($0.messageID) }
        result.echoes.removeAll { deleted.contains($0.messageID) }
        result.unknownLabels = Set(result.setLabels.flatMap { $0.add.union($0.remove) }.filter { !knownLabel($0) })
        return result
    }
}

#endif
