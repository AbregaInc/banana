#if !BANANA_PUBLIC
import Foundation

/// Local precious intent, Gmail-owned content, service-serialized provider operations.
/// All database work uses the existing GRDB writer off the main actor.
actor MailDraftDriver {
    enum Failure: Error { case notFound, changed, notEditable, unsupportedSchedule, attachmentsNotReady }
    let scope: String
    private let store: MailIntentStore
    private let api: any GmailDraftAPI
    private let token: @Sendable (String) async throws -> String
    private let allowed: @Sendable (String) async -> Bool
    private let compose: @Sendable (MailDraftRecord.Snapshot) throws -> GmailDraftComposition
    private let changed: @Sendable (MailDraftRecord) -> Void
    private var running = Set<MailDraftID>()
    init(scope: String, store: MailIntentStore, api: any GmailDraftAPI,
         token: @escaping @Sendable (String) async throws -> String,
         allowed: @escaping @Sendable (String) async -> Bool,
         compose: @escaping @Sendable (MailDraftRecord.Snapshot) throws -> GmailDraftComposition,
         changed: @escaping @Sendable (MailDraftRecord) -> Void = { _ in }) {
        self.scope = scope; self.store = store; self.api = api; self.token = token
        self.allowed = allowed; self.compose = compose; self.changed = changed
    }
    func record(_ id: MailDraftID) async throws -> MailDraftRecord? { try await store.draftRecord(scope: scope, id: id) }
    func create(_ draft: MailDraft, inReplyTo: String? = nil, forwardMessageID: String? = nil) async throws {
        var value = MailDraftRecord(scope: scope, snapshot: .init(draft))
        value.snapshot.inReplyTo = inReplyTo
        value.snapshot.forwardMessageID = forwardMessageID
        guard try await store.putDraftRecord(value, expectedGeneration: nil) else { throw Failure.changed }
        changed(value)
    }
    @discardableResult private func mutate(_ id: MailDraftID, _ update: (inout MailDraftRecord) throws -> Void) async throws -> MailDraftRecord {
        for _ in 0..<20 {
            guard var value = try await record(id) else { throw Failure.notFound }
            let generation = value.generation
            try update(&value)
            if try await store.putDraftRecord(value, expectedGeneration: generation) {
                value.generation = generation + 1; changed(value); return value
            }
        }
        throw Failure.changed
    }
    func pendingRecords(after: String = "") async throws -> [MailDraftRecord] {
        try await store.pendingDraftRecords(scope: scope, after: after)
    }
    func forConversation(_ conversation: MailConversationID) async throws -> MailDraftRecord? {
        try await store.draftForConversation(scope: scope, conversation: conversation)
    }
    func page(account: String?, outbox: Bool, before: MailOrderKey?, limit: Int) async throws -> [MailDraftRecord] {
        try await store.draftPage(scope: scope, account: account, outbox: outbox, before: before, limit: limit)
    }
    func hasPendingSends() async throws -> Bool { try await store.hasPendingDraftSends(scope: scope) }
    func records(after: String = "") async throws -> [MailDraftRecord] {
        try await store.draftRecords(scope: scope, after: after)
    }
    /// Fetch one bounded provider page. A partial listing never proves a draft was deleted.
    func syncPage(account: String, pageToken: String? = nil, scan: String? = nil) async throws -> String? {
        guard await allowed(account) else { return nil }
        let reference = try await token(account)
        let page = try await api.drafts(token: reference, pageToken: pageToken)
        for item in page.drafts ?? [] {
            try Task.checkCancellation()
            guard await allowed(account) else { return nil }
            guard let remoteID = item.id, let messageID = item.message?.id else { continue }
            let existing = try await store.draftRecord(scope: scope, account: account, remoteID: remoteID)
            if let scan { try await store.markDraftSeen(scope: scope, account: account, remoteID: remoteID, scan: scan) }
            if existing?.remote?.message.id == messageID { continue }
            // Our in-flight update can already be visible in Gmail. Its receipt must settle first.
            if existing?.pending != nil { continue }
            let wire = try await api.draft(token: reference, id: remoteID)
            guard wire.id == remoteID, await allowed(account) else { continue }
            try await importDraft(wire, account: account)
            if let scan { try await store.markDraftSeen(scope: scope, account: account, remoteID: remoteID, scan: scan) }
        }
        return page.nextPageToken
    }
    /// Only called after every listing page succeeded. Absence from the listing alone is
    /// insufficient: a structured provider not-found response must confirm each disappearance.
    func finishScan(account: String, scan: String) async throws {
        guard await allowed(account) else { return }
        let reference = try await token(account)
        var cursor = ""
        repeat {
            try Task.checkCancellation()
            guard await allowed(account) else { return }
            let records = try await store.unseenDraftRecords(scope: scope, account: account, scan: scan, after: cursor)
            guard let last = records.last else { return }
            for record in records {
                guard record.pending == nil, let remote = record.remote else { continue }
                do {
                    let wire = try await api.draft(token: reference, id: remote.id)
                    guard await allowed(account) else { return }
                    try await importDraft(wire, account: account)
                    try await store.markDraftSeen(scope: scope, account: account, remoteID: remote.id, scan: scan)
                } catch GmailError.notFound {
                    guard await allowed(account) else { return }
                    _ = try await mutate(record.snapshot.id) { current in
                        guard current.pending == nil, current.remote == record.remote else { throw Failure.changed }
                        if current.needsDelivery || current.conflict { current.conflict = true }
                        else { current.state = .deleted }
                    }
                }
            }
            cursor = last.snapshot.id.raw
        } while true
    }
    func importDraft(_ wire: GmailDraftValue, account: String, replacingConflict: Int? = nil) async throws {
        guard let messageID = wire.message.id, let payload = wire.message.payload else { throw Failure.notFound }
        let existing = try await store.draftRecord(scope: scope, account: account, remoteID: wire.id)
        if let replacingConflict, existing?.generation != replacingConflict { throw Failure.changed }
        guard existing?.pending == nil || (replacingConflict != nil && existing?.state == .failed && existing?.conflict == true) else { return }
        if let existing, replacingConflict == nil && (existing.needsDelivery || existing.conflict) {
            if existing.remote?.message.id != messageID {
                _ = try await mutate(existing.snapshot.id) { value in
                    guard value.pending == nil else { throw Failure.changed }
                    value.conflict = true
                }
            }
            return
        }
        let headers = MessageHeaders(payload: payload), extracted = MIMEStructure.extract(payload)
        // Do not turn an unavailable MIME body into an apparently empty editable draft.
        guard extracted.structure.cut == nil, extracted.missingBodyPartIDs.isEmpty, !extracted.bodyTooLarge, !extracted.malformedBody else { throw Failure.notEditable }
        let prepared = try MailHTMLPreparer.prepare(plain: extracted.plain, html: extracted.html)
        func people(_ name: String) -> [MailPerson] {
            headers.addresses(name).mailboxes.map {
                MailPerson(name: MailAddressRules.displayName($0.name, address: $0.address), address: $0.address,
                    isMe: $0.key == account.lowercased(), isKnown: false, fromTheirMail: false)
            }
        }
        let id = existing?.snapshot.id ?? MailDraftID(raw: UUID().uuidString.lowercased())
        let from = headers.sender
        let draft = MailDraft(id: id, conversation: .init(account: account, thread: wire.message.threadId ?? "draft:" + wire.id),
            account: account, isReply: headers.value("In-Reply-To") != nil, isForward: false,
            from: .init(account: account, address: from?.address ?? account, name: from?.name, isDefault: from?.key == account.lowercased(), hasSignature: false),
            to: people("To"), cc: people("Cc"), bcc: people("Bcc"), subject: headers.subject ?? "", body: prepared.text,
            signature: nil, quote: nil, attachments: extracted.structure.attachments.map {
                MailDraftAttachment(id: $0.partID, name: $0.name, bytes: $0.size ?? 0, file: nil, isExecutable: false)
            }, format: .foreign, schedule: nil, remindIfNoReply: nil, delivery: nil,
            encodedBytes: wire.message.sizeEstimate ?? 0, editedAt: Date(timeIntervalSince1970: Double(wire.message.internalDate ?? 0) / 1000))
        var value = MailDraftRecord(scope: scope, snapshot: .init(draft))
        value.snapshot.inReplyTo = headers.value("In-Reply-To")
        value.snapshot.editToken = UUID().uuidString.lowercased()
        value.remote = .init(id: wire.id, message: .init(id: messageID, threadId: wire.message.threadId))
        value.acknowledgedRevision = value.revision
        guard try await store.putDraftRecord(value, expectedGeneration: existing?.generation) else { throw Failure.changed }
        value.generation = (existing?.generation ?? -1) + 1
        changed(value)
    }
    func resolveConflict(_ id: MailDraftID, keepMine: Bool) async throws {
        guard let before = try await record(id), before.conflict, let remote = before.remote,
              before.pending == nil || before.state == .failed,
              await allowed(before.snapshot.account) else { throw Failure.notEditable }
        let reference = try await token(before.snapshot.account)
        let fetched: GmailDraftValue?
        do { fetched = try await api.draft(token: reference, id: remote.id) }
        catch GmailError.notFound { fetched = nil }
        guard await allowed(before.snapshot.account) else { throw Failure.changed }
        guard let latest = fetched else {
            _ = try await mutate(id) { value in
                guard value.generation == before.generation else { throw Failure.changed }
                value.pending = nil; value.pendingRevision = nil; value.pendingFiles = nil; value.conflict = false
                value.sendAt = nil; value.wantsDelete = false
                if keepMine {
                    value.remote = nil; value.acknowledgedRevision = 0; value.revision += 1; value.state = .editing
                } else { value.state = .deleted }
            }
            return
        }
        guard latest.id == remote.id, let version = latest.message.id else { throw Failure.changed }
        guard try await record(id)?.generation == before.generation else { throw Failure.changed }
        if !keepMine {
            try await importDraft(latest, account: before.snapshot.account, replacingConflict: before.generation)
            return
        }
        _ = try await mutate(id) { value in
            guard value.generation == before.generation else { throw Failure.changed }
            value.remote = .init(id: remote.id, message: .init(id: version, threadId: latest.message.threadId))
            value.pending = nil; value.pendingRevision = nil; value.pendingFiles = nil; value.conflict = false
            value.state = .editing; value.sendAt = nil; value.wantsDelete = false
            value.revision += 1
        }
    }
    func save(_ draft: MailDraft) async throws {
        if try await record(draft.id) == nil { try await create(draft); return }
        _ = try await mutate(draft.id) { value in
            guard value.state == .editing || value.state == .failed || (value.pending?.action != .send && value.state == .uncertain) else { throw Failure.notEditable }
            if value.state == .failed {
                // Only a terminal provider refusal enters failed; unknown operations retain identity.
                value.pending = nil; value.pendingRevision = nil; value.pendingFiles = nil; value.state = .editing; value.sendAt = nil
            }
            guard value.snapshot.account == draft.account else { throw Failure.changed }
            var incoming = MailDraftRecord.Snapshot(draft)
            incoming.inReplyTo = value.snapshot.inReplyTo
            incoming.forwardMessageID = value.snapshot.forwardMessageID
            incoming.attachments = incoming.attachments.map { attachment in
                guard attachment.file == nil, let stored = value.snapshot.attachments.first(where: { $0.id == attachment.id }), stored.file != nil else { return attachment }
                return stored
            }
            var comparable = incoming
            comparable.editedAt = value.snapshot.editedAt
            comparable.encodedBytes = value.snapshot.encodedBytes
            if comparable == value.snapshot { return }
            if draft.editToken != (value.snapshot.editToken ?? "local") { value.conflict = true }
            if value.snapshot.format == .foreign && !value.conflict { throw Failure.notEditable }
            value.snapshot = incoming; value.revision += 1

        }
    }
    func rewriteAsText(_ id: MailDraftID) async throws -> MailDraft {
        guard let before = try await record(id), before.state == .editing, !before.conflict,
              before.pending == nil, before.snapshot.format == .foreign, let remote = before.remote,
              await allowed(before.snapshot.account) else { throw Failure.notEditable }
        let reference = try await token(before.snapshot.account)
        let wire = try await api.draft(token: reference, id: remote.id)
        guard wire.id == remote.id, wire.message.id == remote.message.id else {
            _ = try await mutate(id) { $0.conflict = true }
            throw Failure.changed
        }
        var files: [MailDraftAttachment] = []
        if !before.snapshot.attachments.isEmpty {
            guard let downloadAPI = api as? any GmailAPI else { throw Failure.attachmentsNotReady }
            files = try await MailDraftFiles.download(wire.message, token: reference, api: downloadAPI, directory: store.attachmentDirectory)
        }
        do {
            guard await allowed(before.snapshot.account) else { throw Failure.notEditable }
            let saved = try await mutate(id) { value in
                guard value.generation == before.generation else { throw Failure.changed }
                value.snapshot.format = .banana; value.snapshot.attachments = files; value.revision += 1
            }
            return saved.snapshot.value
        } catch {
            for file in files { if let url = file.file { try? FileManager.default.removeItem(at: url) } }
            throw error
        }
    }
    func addAttachment(_ url: URL, to id: MailDraftID) async throws -> MailDraftAttachment {
        guard let record = try await record(id), record.state == .editing, record.snapshot.format == .banana else { throw Failure.notEditable }
        let file = try MailDraftFiles.keep(url, directory: store.attachmentDirectory)
        do {
            _ = try await mutate(id) { value in
                guard value.state == .editing, value.snapshot.format == .banana else { throw Failure.notEditable }
                guard value.snapshot.attachments.reduce(0, { $0 + $1.bytes }) + file.bytes <= MailDraftFiles.maximumBytes else { throw Failure.attachmentsNotReady }
                value.snapshot.attachments.append(file); value.revision += 1
            }
            return file
        } catch {
            if let file = file.file { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }
    func removeAttachment(_ attachment: String, from id: MailDraftID) async throws {
        _ = try await mutate(id) { value in
            guard value.state == .editing, value.snapshot.format == .banana else { throw Failure.notEditable }
            value.snapshot.attachments.removeAll { $0.id == attachment }; value.revision += 1
        }
        // An older in-flight operation may still need this immutable file. Cleanup follows its receipt.
    }
    private func materializeForwardFiles(_ before: MailDraftRecord) async throws -> MailDraftRecord {
        let missing = Set(before.snapshot.attachments.filter { $0.file == nil }.map(\.id))
        guard !missing.isEmpty, let messageID = before.snapshot.forwardMessageID else { return before }
        guard let downloadAPI = api as? any GmailAPI, await allowed(before.snapshot.account) else { throw Failure.attachmentsNotReady }
        let reference = try await token(before.snapshot.account)
        let message = try await downloadAPI.message(token: reference, id: messageID, format: .full)
        guard message.id == messageID else { throw Failure.changed }
        let files = try await MailDraftFiles.download(message, token: reference, api: downloadAPI,
            directory: store.attachmentDirectory, selected: missing)
        do {
            guard Set(files.map(\.id)) == missing, await allowed(before.snapshot.account) else { throw Failure.attachmentsNotReady }
            return try await mutate(before.snapshot.id) { value in
                guard [.editing, .held].contains(value.state), value.pending == nil,
                      value.snapshot.forwardMessageID == messageID else { throw Failure.changed }
                value.snapshot.attachments = value.snapshot.attachments.map { original in
                    original.file == nil ? (files.first { $0.id == original.id } ?? original) : original
                }
                value.revision += 1
            }
        } catch {
            for file in files { if let url = file.file { try? FileManager.default.removeItem(at: url) } }
            throw error
        }
    }
    private func uploadParts(_ value: MailDraftRecord, token: String) async throws {
        guard let operation = value.pending, let attachments = operation.content?.attachments, !attachments.isEmpty else { return }
        guard let files = value.pendingFiles, files.count == attachments.count else { throw Failure.attachmentsNotReady }
        for (file, description) in zip(files, attachments) {
            guard let url = file.file else { throw Failure.attachmentsNotReady }
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            var bytes = 0
            for hash in description.chunks {
                try Task.checkCancellation()
                guard await allowed(value.snapshot.account), let data = try MailDraftFiles.readChunk(input),
                      MailDraftFiles.hash(data) == hash else { throw Failure.changed }
                bytes += data.count
                try await api.uploadDraftPart(token: token, operationID: operation.operationID, hash: hash, data: data)
            }
            guard bytes == description.bytes, (try input.read(upToCount: 1))?.isEmpty != false else { throw Failure.changed }
        }
    }
    func queueSend(_ id: MailDraftID, options: MailSendOptions, now: Date = Date(), expectedEditToken: String? = nil) async throws {
        guard options.at == nil else { throw Failure.unsupportedSchedule }
        _ = try await mutate(id) { value in
            guard value.state == .editing, !value.conflict else { throw Failure.notEditable }
            if let expectedEditToken, expectedEditToken != (value.snapshot.editToken ?? "local") { throw Failure.changed }
            guard value.snapshot.forwardMessageID != nil || value.snapshot.attachments.allSatisfy({ $0.file != nil }) || (value.remote != nil && value.revision == value.acknowledgedRevision) else { throw Failure.attachmentsNotReady }
            value.state = .held; value.thenDone = options.thenDone; value.sendAt = now.addingTimeInterval(max(0, options.hold ?? 10))
        }
    }
    func cancelSend(_ id: MailDraftID) async throws -> Bool {
        do {
            _ = try await mutate(id) { value in
                guard value.state == .held, value.pending?.action != .send else { throw Failure.notEditable }
                value.state = .editing; value.sendAt = nil
            }; return true
        } catch Failure.notEditable { return false }
    }
    func discard(_ id: MailDraftID) async throws {
        _ = try await mutate(id) { value in
            guard value.state == .editing, value.pending?.action != .send else { throw Failure.notEditable }
            value.wantsDelete = true
            if value.remote == nil && value.pending == nil { value.state = .deleted }
        }
    }
    func restore(_ id: MailDraftID) async throws {
        _ = try await mutate(id) { value in
            guard value.pending?.action != .delete, value.pending?.action != .send else { throw Failure.notEditable }
            if value.state == .deleted { value.remote = nil; value.acknowledgedRevision = 0; value.revision += 1; value.state = .editing }
            value.wantsDelete = false
        }
    }
    func retry(_ id: MailDraftID) async throws {
        if let value = try await record(id), value.state == .failed, !value.conflict {
            _ = try await mutate(id) { current in
                guard current.state == .failed, !current.conflict else { throw Failure.changed }
                current.state = current.pending?.action == .send ? .held : .editing
                current.sendAt = current.state == .held ? Date() : nil
                current.pending = nil; current.pendingRevision = nil; current.pendingFiles = nil; current.deliveryFailed = nil
            }
        }
        try await flush(id)
    }
    /// Retry always uses the saved operation identity. It cannot turn an ambiguous send into a new send.
    func flush(_ id: MailDraftID, now: Date = Date()) async throws {
        guard running.insert(id).inserted else { return }
        defer { running.remove(id) }
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard var value = try await record(id), ![.sent, .deleted, .failed].contains(value.state), !value.conflict else { return }
            guard await allowed(value.snapshot.account) else { return }
            if value.pending == nil {
                let action: GmailDraftMutation.Action
                if value.wantsDelete, value.remote != nil { action = .delete }
                else if value.acknowledgedRevision < value.revision { action = value.remote == nil ? .create : .update }
                else if value.state == .held, let sendAt = value.sendAt, sendAt <= now { action = .send }
                else { return }
                if action == .create || action == .update {
                    do { value = try await materializeForwardFiles(value) }
                    catch { _ = try await mutate(id) { $0.deliveryFailed = true }; throw error }
                    guard !value.conflict, value.pending == nil else { return }
                    if value.wantsDelete || ![.editing, .held].contains(value.state) { continue }
                    if (action == .create) != (value.remote == nil) { continue }
                }
                var content = (action == .create || action == .update) ? try compose(value.snapshot) : nil
                if content != nil { content?.attachments = try value.snapshot.attachments.map(MailDraftFiles.describe) }
                let operation = GmailDraftMutation(operationID: UUID().uuidString.lowercased(), email: value.snapshot.account,
                    action: action, id: value.remote?.id, expectedMessageID: value.remote?.message.id, content: content)
                let generation = value.generation
                value.pending = operation; value.pendingRevision = value.revision
                value.pendingFiles = content == nil ? nil : value.snapshot.attachments
                if action == .send { value.state = .sending }
                guard try await store.putDraftRecord(value, expectedGeneration: generation) else { continue }
                value.generation += 1; changed(value)
            }
            guard let pending = value.pending else { return }
            do {
                let reference = try await token(value.snapshot.account)
                guard await allowed(value.snapshot.account) else { return }
                try await uploadParts(value, token: reference)
                let data = try await api.mutateDraft(token: reference, request: pending)
                struct Sent: Decodable { var id: String; var threadId: String? }
                let sent = pending.action == .send ? try JSONDecoder().decode(Sent.self, from: data) : nil
                let remote: GmailDraftReference? = [.create, .update].contains(pending.action)
                    ? try JSONDecoder().decode(GmailDraftReference.self, from: data) : nil
                _ = try await mutate(id) { current in
                    guard current.pending?.operationID == pending.operationID else { throw Failure.changed }
                    if let remote { current.remote = remote; current.acknowledgedRevision = current.pendingRevision ?? 0 }
                    current.pending = nil; current.pendingRevision = nil; current.pendingFiles = nil; current.deliveryFailed = nil
                    if pending.action == .send {
                        current.state = .sent
                        if let thread = sent?.threadId { current.snapshot.conversation = MailConversationID(account: current.snapshot.account, thread: thread) }
                    }
                    else if pending.action == .delete { current.state = .deleted }
                    else if current.state == .uncertain { current.state = .editing }
                }
            } catch {
                _ = try await mutate(id) { current in
                    guard current.pending?.operationID == pending.operationID else { throw Failure.changed }
                    current.deliveryFailed = true
                    if let refusal = error as? GmailDraftRejection, refusal.terminal {
                        current.state = .failed; current.conflict = refusal.status == 409
                    } else if pending.action == .send { current.state = .uncertain }
                    // Keep the exact request and current editor snapshot, including newer edits.
                }
                throw error
            }
        }
    }
}
#endif
