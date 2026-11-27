import XCTest
import GRDB

@MainActor final class MailLiveSourceTests: XCTestCase {
    private final class Access: MailAccountAccess {
        var connectedAccountIDs = ["a@example.com"]
        var grant = MailGrant.none
        func mailGrant(accountID: String) -> MailGrant { grant }
        func mailAccessToken(accountID: String) async throws -> MailAccessToken {
            guard grant == .granted else { throw MailAccessError.notGranted }
            return MailAccessToken(value: "fixture", scopes: [MailScopes.gmailModify])
        }
        func dropMailAccessToken(accountID: String) {}
        func requestMailAccess(accountID: String) async -> MailAccessOutcome { grant = .granted; return .granted }
        func cancelMailTokenRequests() {}
    }
    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-live-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    private actor PushFeed: MailCloudFeedSource {
        private(set) var requests: [String] = []
        var failing: String?
        private var active: [String: Int] = [:]
        private(set) var maxConcurrentPerAccount = 0
        private let holdAccount: String?
        private let gate = AsyncStream<Void>.makeStream()
        private let onHeld: (@Sendable () -> Void)?
        func release() { gate.continuation.finish() }
        func recover() { failing = nil }
        let delay: Duration
        init(failing: String? = nil, delay: Duration = .zero, holdAccount: String? = nil,
             onHeld: (@Sendable () -> Void)? = nil) {
            self.onHeld = onHeld
            self.holdAccount = holdAccount
            self.failing = failing
            self.delay = delay
        }
        func page(account: String, after: String?, limit: Int, fresh: Bool) async throws -> MailCloudFeedPage {
            requests.append(account)
            active[account, default: 0] += 1
            maxConcurrentPerAccount = max(maxConcurrentPerAccount, active[account, default: 0])
            defer { active[account, default: 0] -= 1 }
            if account == holdAccount {
                onHeld?()
                for await _ in gate.stream {}
            }
            try await Task.sleep(for: delay)
            if account == failing { throw URLError(.timedOut) }
            return MailCloudFeedPage(epoch: "v1", cursor: "1", more: false, complete: true, entries: [])
        }
        func check(account: String, ids: [String]) async throws {}
    }

    private func pushSource(_ feed: PushFeed, clock: any MailClock = SystemMailClock()) async throws -> (MailLiveSource, MailStores) {
        let stores = try await stores()
        let access = Access()
        access.grant = .granted
        access.connectedAccountIDs = ["a@example.com", "b@example.com"]
        let source = MailLiveSource(stores: stores, access: access, api: GmailPageLoaderTests.Provider(count: 0),
                                    cloudFeed: feed, clock: clock)
        let intent = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        try await source.prepareActions(intent: intent)
        return (source, stores)
    }

    func testRepeatedPushesBackOffFailedFeedAndKeepHealthyAccountCurrent() async throws {
        let feed = PushFeed(failing: "a@example.com")
        let clock = ManualMailClock(start: Date())
        let (source, stores) = try await pushSource(feed, clock: clock)
        for _ in 0..<4 {
            let gotThrough = await source.catchUpFromPush(budget: .seconds(2))
            XCTAssertTrue(gotThrough)
        }
        let calls = await feed.requests
        XCTAssertEqual(calls.filter { $0 == "a@example.com" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "b@example.com" }.count, 4)
        await feed.recover()
        clock.advance(by: 5)
        _ = await source.catchUpFromPush(budget: .seconds(2))
        let cursor = try await stores.index.read { try MailCloudFeedIndex.state(account: "a@example.com", in: $0)?.cursor }
        XCTAssertEqual(cursor, "1")
        XCTAssertEqual(source.accounts.first?.health, .live)
    }

    func testOverlappingPushesServeHealthyAccountWhileFailedAccountIsWaiting() async throws {
        let failedID = "a@example.com"
        let healthyID = "b@example.com"
        let entered = expectation(description: "First feed request reached the provider")
        let feed = PushFeed(failing: failedID, holdAccount: failedID) { entered.fulfill() }
        let (source, stores) = try await pushSource(feed)
        let first = Task { await source.catchUpFromPush(budget: .seconds(15), includeContent: false) }
        await fulfillment(of: [entered], timeout: 5)
        let overlap = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { await source.catchUpFromPush(budget: .seconds(2), includeContent: false) }
            }
            var completed = 0
            for await ok in group where ok { completed += 1 }
            return completed
        }
        let during = await feed.requests
        await feed.release()
        let finished = await first.value
        XCTAssertTrue(finished)
        XCTAssertEqual(overlap, 8)
        XCTAssertEqual(during.filter { $0 == failedID }.count, 1)
        XCTAssertTrue(during.contains(healthyID), "The other account progresses before the slow response arrives")
        for _ in 0..<8 { _ = await source.catchUpFromPush(budget: .seconds(2), includeContent: false) }
        let final = await feed.requests
        let peak = await feed.maxConcurrentPerAccount
        XCTAssertEqual(final.filter { $0 == failedID }.count, 1, "All later pushes respect the installed retry deadline")
        XCTAssertEqual(peak, 1)
        let cursor = try await stores.index.read { try MailCloudFeedIndex.state(account: healthyID, in: $0)?.cursor }
        XCTAssertEqual(cursor, "1")
        let counts = XCTAttachment(string: "overlappingTriggers=8 subsequentTriggers=8 blockedRequests=1 healthyRequests=\(final.filter { $0 == healthyID }.count) peakPerAccount=\(peak)")
        counts.name = "Mail overlapping push work"
        counts.lifetime = .keepAlways
        add(counts)
    }

    // Needs MailSession (Mail UI models), which tools/mail-index-tests, the engine-only harness,
    // does not compile. The app's BananaTests runs it.
    #if !MAIL_ENGINE_HARNESS
    func testOffscreenSessionPullsOnceWithoutStartingForegroundPolling() async throws {
        for reference in [true, false] {
            let feed = PushFeed()
            let clock = ManualMailClock(start: Date())
            let (_, _, source, row) = try await actionSource(deliveryAPI: GmailIntentDeliveryTests.Provider(),
                                                             feed: feed, clock: clock)
            // The former session initializer also activated the foreground engine.
            if reference { source.activate() }
            let session = MailSession(source: source, now: clock.now, deviceName: "Test", present: { _, _ in })
            defer { source.setVisible(false) }
            // A shell read remains available without a Mail screen.
            let local = expectation(description: "Read the existing inbox row")
            var delivered = false
            let token = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 5) { page in
                if !delivered && page.rows.contains(where: { $0.id == row.id }) {
                    delivered = true
                    local.fulfill()
                }
            }
            await fulfillment(of: [local], timeout: 5)
            token.cancel()
            func waitForScheduledPoll() async throws {
                let deadline = ContinuousClock.now + .seconds(5)
                while clock.pendingSleeps.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
                _ = try XCTUnwrap(clock.pendingSleeps.first)
            }
            if reference { try await waitForScheduledPoll() }
            let before = await feed.requests.count
            let pulled = await source.catchUpFromPush(budget: .seconds(2), includeContent: false)
            XCTAssertTrue(pulled)
            let afterPush = await feed.requests.count
            XCTAssertEqual(afterPush, before + 1)
            for _ in 0..<4 {
                if reference { try await waitForScheduledPoll() }
                clock.advance(by: 30)
            }
            if reference { try await waitForScheduledPoll() }
            let afterIdle = await feed.requests.count
            XCTAssertEqual(before, reference ? 1 : 0)
            XCTAssertEqual(afterIdle - afterPush, reference ? 4 : 0)
            if !reference { XCTAssertTrue(clock.pendingSleeps.isEmpty) }
            session.enter()
            try await waitForScheduledPoll()
            let onScreen = await feed.requests.count
            XCTAssertEqual(onScreen, afterIdle + (reference ? 0 : 1))
            session.leave()
            let evidence = XCTAttachment(string: "reference=\(reference) beforePush=\(before) afterPush=\(afterPush) after120Seconds=\(afterIdle) afterOpeningMail=\(onScreen)")
            evidence.name = "Foreground Mail ownership"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
    }
    #endif

    func testFifteenMinutesOfOfflinePushesKeepTheWriteUntilRecovery() async throws {
        let offline = "a@example.com", healthy = "b@example.com"
        let api = GmailIntentDeliveryTests.Provider()
        let feed = PushFeed(failing: offline)
        let clock = ManualMailClock(start: Date())
        let (stores, intent, source, row) = try await actionSource(deliveryAPI: api, feed: feed,
            clock: clock, accounts: [offline, healthy])
        let saved = expectation(description: "Optimistic star has a durable receipt")
        let receiptObservation = source.observeEvents { event in
            if case .applied = event { saved.fulfill() }
        }
        let receipt = source.apply(.star(true), to: .asShown([row]))
        await fulfillment(of: [saved], timeout: 5)
        receiptObservation.cancel()
        for step in 0...180 {
            if step > 0 { clock.advance(by: 5) }
            let healthyPass = await source.catchUpFromPush(budget: .seconds(2), includeContent: false)
            XCTAssertTrue(healthyPass)
        }
        let requests = await feed.requests
        XCTAssertEqual(requests.filter { $0 == offline }.count, 8)
        XCTAssertEqual(requests.filter { $0 == healthy }.count, 181)
        // Delivery does not wait for Mail to be shown: the star reached Gmail during the outage,
        // once, while the failing feed kept backing off.
        var waiting = try await intent.assertions()
        let deliveredBy = ContinuousClock.now + .seconds(5)
        while !waiting.isEmpty && ContinuousClock.now < deliveredBy {
            try await Task.sleep(for: .milliseconds(5))
            waiting = try await intent.assertions()
        }
        XCTAssertTrue(waiting.isEmpty, "Receipt \(receipt.sequence) still waiting")
        let idleWrites = await api.writes
        XCTAssertEqual(idleWrites, 1)
        let healthyCursor = try await stores.index.read { try MailCloudFeedIndex.state(account: healthy, in: $0)?.cursor }
        XCTAssertEqual(healthyCursor, "1")
        await feed.recover()
        clock.advance(by: 15) // The next eligible time after the 615-second attempt.
        _ = await source.catchUpFromPush(budget: .seconds(2), includeContent: false)
        let recoveredCursor = try await stores.index.read { try MailCloudFeedIndex.state(account: offline, in: $0)?.cursor }
        XCTAssertEqual(recoveredCursor, "1")
        // Recreate the live source before delivery, as after returning to Mail in a new process.
        let access = Access()
        access.grant = .granted
        let reopenedIntent = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        let reopened = MailLiveSource(stores: stores, access: access, api: api, cloudFeed: feed, deliveryAllowed: { _ in true })
        try await reopened.prepareActions(intent: reopenedIntent)
        reopened.activate()
        defer { reopened.setVisible(false) }
        let deadline = ContinuousClock.now + .seconds(5)
        var pending = try await reopenedIntent.assertions()
        while !pending.isEmpty && ContinuousClock.now < deadline {
            await Task.yield()
            pending = try await reopenedIntent.assertions()
        }
        XCTAssertTrue(pending.isEmpty)
        let after = try await MailIndexReader(stores: stores).page(PageRequest(view: .unified(.inbox), account: nil,
            filters: [], before: nil, limit: 50))
        XCTAssertEqual(after.first?.flags.contains(.starred), true)
        let recoveredWrites = await api.writes
        XCTAssertEqual(recoveredWrites, 1)
    }

    func testExpiredPushStopsFeedAndNextWindowReachesTheOtherAccount() async throws {
        let feed = PushFeed(delay: .milliseconds(300))
        let (source, _) = try await pushSource(feed)
        let first = await source.catchUpFromPush(budget: .milliseconds(50))
        XCTAssertFalse(first)
        let expired = await feed.requests
        XCTAssertEqual(expired, ["a@example.com"])
        _ = await source.catchUpFromPush(budget: .seconds(2))
        let calls = await feed.requests
        XCTAssertEqual(Array(calls.dropFirst()), ["b@example.com", "a@example.com"])
    }

    private func actionSource(deliveryAPI: (any GmailAPI)? = nil, senderPolicyAPI: (any MailSenderPolicyAPI)? = nil,
                              feed: PushFeed? = nil, clock: any MailClock = SystemMailClock(),
                              accounts: [String] = ["a@example.com"]) async throws -> (MailStores, MailIntentStore, MailLiveSource, MailRow) {
        let stores = try await stores()
        let intent = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        let wire = GmailMessage(id: "m", threadId: "t", labelIds: ["INBOX"], historyId: 1, internalDate: 1000,
            payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Action")]))
        _ = try await MailWriter(stores: stores, sink: nil).transact {
            try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload), structure: nil), account: "a@example.com", myAddresses: ["a@example.com"], in: $0)
        }
        let access = Access()
        if deliveryAPI != nil { access.grant = .granted }
        access.connectedAccountIDs = accounts
        let source = MailLiveSource(stores: stores, access: access, api: deliveryAPI ?? GmailPageLoaderTests.Provider(count: 0),
                                    cloudFeed: feed, senderPolicyAPI: senderPolicyAPI, clock: clock,
                                    deliveryAllowed: { _ in deliveryAPI != nil })
        try await source.prepareActions(intent: intent)
        let rows = try await MailIndexReader(stores: stores).page(PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 50))
        let row = MailRowMapper.row(try XCTUnwrap(rows.first), labels: [], reason: nil, in: MailScope(place: .mailbox(.inbox)))
        return (stores, intent, source, row)
    }

    func testHeaderProgressTracksEligibleAccountsOnlyWhileObserved() async throws {
        let (stores, _, _, _) = try await actionSource()
        let access = Access(); access.grant = .granted
        let source = MailLiveSource(stores: stores, access: access, api: GmailPageLoaderTests.Provider(count: 0))
        let progress = try XCTUnwrap(source.syncProgress)
        func ready(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
            return predicate()
        }
        let first = progress.observe()
        let queued = await ready { progress.value.pending == 1 }
        XCTAssertTrue(queued, "The live source counts its persisted eligible content queue")
        XCTAssertTrue(progress.value.checking)
        XCTAssertNil(progress.value.fraction, "Discovery has not finished")
        first.cancel()
        let stopped = await ready { progress.observers == 0 }
        XCTAssertTrue(stopped)
        access.grant = .none; source.accessChanged()
        XCTAssertEqual(progress.value.pending, 1, "No header: policy changes do not publish progress")
        let second = progress.observe()
        defer { second.cancel() }
        let idle = await ready { !progress.value.isVisible }
        XCTAssertTrue(idle, "A remounted header drops work for accounts without access")
        XCTAssertEqual(progress.value.pending, 0)
    }

    private struct PolicySnapshotAPI: MailSenderPolicyAPI {
        let blocked: Bool
        let revision: Int
        func read(account: String, sender: String) async throws -> MailSenderPolicyRemote {
            .init(blocked: blocked, revision: revision, operation: "33333333-3333-3333-3333-333333333333")
        }
        func write(account: String, sender: String, blocked: Bool, revision: Int, operation: String) async throws -> MailSenderPolicyRemote {
            XCTFail("Refreshing sender state must not write a provider rule")
            throw GmailError.neverLeft
        }
    }
    private func policyReady(_ intent: MailIntentStore, status: MailSenderPolicyStatus, revision: Int, blocked: Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let record = try await intent.senderPolicy(account: "a@example.com", sender: "offers@shop.example")
            if record?.remote?.revision == revision, status.blocked == blocked,
               status.failed == !blocked, status.desiredBlocked, !status.pending { return true }
            await Task.yield()
        }
        return false
    }
    func testRefreshingAFailedSenderIntentKeepsRetryUntilTheDesiredEffectIsConfirmed() async throws {
        for blocked in [false, true] {
            let (stores, intent, source, _) = try await actionSource(senderPolicyAPI: PolicySnapshotAPI(blocked: blocked, revision: 19))
            try await intent.queueSenderPolicy(account: "a@example.com", sender: "offers@shop.example", blocked: true)
            let queued = try await intent.senderPolicy(account: "a@example.com", sender: "offers@shop.example")
            let record = try XCTUnwrap(queued)
            try await intent.settleSenderPolicy(record, remote: .init(blocked: false, revision: 1, operation: nil), failed: true)
            let status = source.senderPolicyStatus(account: "a@example.com", sender: "offers@shop.example")
            let ready = try await policyReady(intent, status: status, revision: 19, blocked: blocked)
            XCTAssertTrue(ready, "A current-state read must preserve an unmet intent and settle a confirmed matching effect")
            let saved = try await intent.senderPolicy(account: "a@example.com", sender: "offers@shop.example")
            XCTAssertEqual(saved?.failed, !blocked)
            if !blocked {
                let reopened = MailLiveSource(stores: stores, access: Access(), api: GmailPageLoaderTests.Provider(count: 0),
                    senderPolicyAPI: PolicySnapshotAPI(blocked: false, revision: 20))
                try await reopened.prepareActions(intent: intent)
                let again = reopened.senderPolicyStatus(account: "a@example.com", sender: "offers@shop.example")
                let retained = try await policyReady(intent, status: again, revision: 20, blocked: false)
                XCTAssertTrue(retained, "Retry remains visible after the source is recreated")
            }
        }
    }

    private struct DraftProvider: GmailDraftAPI {
        func drafts(token: String, pageToken: String?) async throws -> GmailDraftPage { throw GmailError.networkDisabled }
        func draft(token: String, id: String) async throws -> GmailDraftValue { throw GmailError.networkDisabled }
        func mutateDraft(token: String, request: GmailDraftMutation) async throws -> Data { throw GmailError.networkDisabled }
    }
    private func prepareDrafts(_ source: MailLiveSource, _ intent: MailIntentStore) async throws {
        try await source.prepareDrafts(intent: intent, scope: "test-account", api: DraftProvider(), contextAllowed: { true }, compose: { snapshot in
            GmailDraftComposition(from: .init(address: snapshot.account), to: [], cc: [], bcc: [], subject: snapshot.subject,
                plain: snapshot.subject, html: "", attachments: [], inReplyTo: nil, references: nil, threadID: nil)
        })
    }
    private func outgoingRecord(state: MailDraftRecord.State, conversation: MailConversationID) -> MailDraftRecord {
        let draft = MailDraft(id: MailDraftID(raw: "queued-reply"), conversation: conversation,
            account: conversation.account, isReply: true, isForward: false,
            from: .init(account: conversation.account, address: conversation.account, name: "Noor", isDefault: true, hasSignature: false),
            to: [MailPerson(name: "Sam", address: "sam@plan.example", isMe: false, isKnown: true, fromTheirMail: true)], cc: [], bcc: [],
            subject: "Re: Action", body: MailPlainText.text("The latest resumed reply"), signature: nil, quote: nil,
            attachments: [], format: .banana, schedule: nil, remindIfNoReply: nil, delivery: nil, encodedBytes: 0, editedAt: Date())
        var record = MailDraftRecord(scope: "test-account", snapshot: .init(draft))
        record.state = state; record.sendAt = Date().addingTimeInterval(600)
        return record
    }

    func testReplyUsesCachedHeadersAlongsideAnImportedDraft() async throws {
        let (stores, intent, source, row) = try await actionSource()
        let sender = "noor@plan.example"
        let message = MailMessageID(account: row.id.account, message: "received")
        let wire = GmailMessage(id: message.message, threadId: row.id.thread, labelIds: ["INBOX"],
            historyId: 2, internalDate: 2_000, payload: GmailPart(headers: [
                GmailHeader(name: "From", value: sender),
                GmailHeader(name: "To", value: row.id.account),
                GmailHeader(name: "Message-ID", value: "<received@plan.example>"),
                GmailHeader(name: "Subject", value: "Action"),
            ]))
        _ = try await MailWriter(stores: stores, sink: nil).transact {
            try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 2, headers: MessageHeaders(payload: wire.payload), structure: nil),
                                          account: row.id.account, myAddresses: [row.id.account], in: $0)
        }
        var imported = outgoingRecord(state: .editing, conversation: row.id)
        imported.snapshot.format = .foreign
        imported.snapshot.inReplyTo = "<received@plan.example>"
        imported.acknowledgedRevision = imported.revision
        let inserted = try await intent.putDraftRecord(imported, expectedGeneration: nil)
        XCTAssertTrue(inserted)
        try await prepareDrafts(source, intent)

        // The original has cached headers only, and the provider cannot supply its body.
        let reply = await source.newDraft(.reply(to: message))
        XCTAssertNotEqual(reply.id, imported.snapshot.id)
        XCTAssertEqual(reply.format, .banana)
        XCTAssertEqual(reply.conversation, row.id)
        XCTAssertEqual(reply.replyToMessage, message)
        XCTAssertEqual(reply.to.map(\.address), [sender])
        XCTAssertEqual(reply.signature, MailBodyHTML.bananaSignature)
        XCTAssertNil(reply.quote)
        let persisted = try await intent.draftRecord(scope: imported.scope, id: reply.id)
        XCTAssertEqual(persisted?.snapshot.inReplyTo, "<received@plan.example>")
        let reopened = await source.newDraft(.replyAll(to: message))
        XCTAssertEqual(reopened.id, reply.id)
        let retained = try await intent.draftRecord(scope: imported.scope, id: imported.snapshot.id)
        XCTAssertEqual(retained?.snapshot, imported.snapshot)
    }

    func testLiveUndoHoldShowsOutgoingContentWithoutADraftNoticeAndUndoRestoresDraft() async throws {
        let (_, intent, source, row) = try await actionSource()
        let record = outgoingRecord(state: .held, conversation: row.id)
        let inserted = try await intent.putDraftRecord(record, expectedGeneration: nil)
        XCTAssertTrue(inserted)
        try await prepareDrafts(source, intent)
        let loaded = await source.conversation(row.id)
        let conversation = try XCTUnwrap(loaded)
        XCTAssertNil(conversation.draft, "Sending is not an editable draft notice during Undo")
        let message = try XCTUnwrap(conversation.messages.first)
        XCTAssertTrue(message.isMine)
        XCTAssertNotNil(message.delivery)
        XCTAssertEqual(MailOutgoingDraft.draftID(message.id), record.snapshot.id)
        let body = await source.body(message.id)
        guard case .text(let text, _, _) = body else { return XCTFail("Outgoing body must already be local") }
        XCTAssertEqual(MailPlainText.string(text), "The latest resumed reply")
        let cancelled = await source.cancelSend(record.snapshot.id)
        XCTAssertTrue(cancelled)
        let restored = expectation(description: "Undo restores the draft marker")
        Task { @MainActor in
            for _ in 0..<100 {
                if await source.conversation(row.id)?.draft == record.snapshot.id { restored.fulfill(); return }
                await Task.yield()
            }
        }
        await fulfillment(of: [restored], timeout: 5)
        let again = await source.conversation(row.id)
        XCTAssertFalse(again?.messages.contains { MailOutgoingDraft.draftID($0.id) != nil } ?? true)
    }

    func testLiveScheduledSendRetainsScheduleActionsWithoutAnEditableDraftNotice() async throws {
        let (_, intent, source, row) = try await actionSource()
        var record = outgoingRecord(state: .held, conversation: row.id)
        let date = Date().addingTimeInterval(3600)
        record.snapshot.schedule = MailSchedule(at: date, onThisDevice: true, isLate: false)
        let inserted = try await intent.putDraftRecord(record, expectedGeneration: nil)
        XCTAssertTrue(inserted)
        try await prepareDrafts(source, intent)
        let conversation = await source.conversation(row.id)
        XCTAssertNil(conversation?.draft)
        let message = try XCTUnwrap(conversation?.messages.first)
        XCTAssertEqual(message.draft, record.snapshot.id)
        XCTAssertEqual(message.delivery, .scheduled(date))
    }

    func testLiveSendingAndUnconfirmedMessagesRemainOutgoingWithoutADraftNotice() async throws {
        for state in [MailDraftRecord.State.sending, .uncertain] {
            let (_, intent, source, row) = try await actionSource()
            let record = outgoingRecord(state: state, conversation: row.id)
            let inserted = try await intent.putDraftRecord(record, expectedGeneration: nil)
            XCTAssertTrue(inserted)
            try await prepareDrafts(source, intent)
            let loaded = await source.conversation(row.id)
            let conversation = try XCTUnwrap(loaded)
            XCTAssertNil(conversation.draft)
            let message = try XCTUnwrap(conversation.messages.first)
            XCTAssertEqual(message.delivery, state == .sending ? .sending : .checking)
            XCTAssertNil(message.draft)
        }
    }

    func testLiveConfirmedSendKeepsLocalContentUntilProviderBodyArrivesWithoutDuplicateHeaders() async throws {
        let (stores, intent, source, row) = try await actionSource()
        var record = outgoingRecord(state: .sent, conversation: row.id)
        record.sentMessage = MailMessageID(account: row.id.account, message: "provider-sent")
        let inserted = try await intent.putDraftRecord(record, expectedGeneration: nil)
        XCTAssertTrue(inserted)
        try await prepareDrafts(source, intent)
        let before = await source.conversation(row.id)
        XCTAssertEqual(before?.messages.count, 2)
        XCTAssertNil(before?.messages.first?.delivery, "Sent is shown only after provider confirmation")
        let wire = GmailMessage(id: "provider-sent", threadId: row.id.thread, labelIds: ["SENT"], historyId: 2, internalDate: 2000,
            payload: GmailPart(headers: [GmailHeader(name: "From", value: row.id.account), GmailHeader(name: "Subject", value: "Re: Action")]))
        _ = try await MailWriter(stores: stores, sink: nil).transact {
            try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 2, headers: MessageHeaders(payload: wire.payload), structure: nil),
                account: row.id.account, myAddresses: [row.id.account], in: $0)
        }
        let after = await source.conversation(row.id)
        XCTAssertEqual(after?.messages.count, 2, "A provider header cannot duplicate the still-visible outgoing body")
        XCTAssertNotNil(after?.messages.first.flatMap { MailOutgoingDraft.draftID($0.id) })
        var bodyWire = wire
        bodyWire.payload = GmailPart(partId: "0", mimeType: "text/plain", headers: wire.payload?.headers,
            body: GmailPartBody(data: Data("The latest resumed reply".utf8).base64EncodedString()))
        let blobs = MailBlobStore(stores: stores)
        try await blobs.put(bodyWire, account: row.id.account, extraction: MIMEStructure.extract(bodyWire.payload!), ftsRowID: 2, at: 2000)
        _ = try await blobs.prepare(account: row.id.account, messageID: "provider-sent", at: 2001)
        let handedOff = await source.conversation(row.id)
        XCTAssertEqual(handedOff?.messages.count, 2)
        XCTAssertFalse(handedOff?.messages.contains { MailOutgoingDraft.draftID($0.id) != nil } ?? true)
        XCTAssertTrue(handedOff?.messages.contains { $0.id == record.sentMessage } ?? false)
        let providerBody = await source.body(try XCTUnwrap(record.sentMessage))
        guard case .text(let text, _, _) = providerBody else { return XCTFail("Confirmed provider body must be usable") }
        XCTAssertEqual(MailPlainText.string(text), "The latest resumed reply")
    }

    /// The composer's To on a real account: the people in the index, not the empty not-yet default.
    func testLiveSuggestionsComeFromThePeopleInTheIndex() async throws {
        let (stores, _, source, _) = try await actionSource()
        let wire = GmailMessage(id: "from-jane", threadId: "tj", labelIds: ["INBOX"], historyId: 2, internalDate: 2000,
            payload: GmailPart(headers: [GmailHeader(name: "From", value: "Jane Park <jane@parkdesign.example>"),
                                         GmailHeader(name: "To", value: "a@example.com"), GmailHeader(name: "Subject", value: "Q3")]))
        _ = try await MailWriter(stores: stores, sink: nil).transact {
            try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 2, headers: MessageHeaders(payload: wire.payload), structure: nil),
                                          account: "a@example.com", myAddresses: ["a@example.com"], in: $0)
        }
        let found = await source.people(matching: "jan", limit: 5)
        XCTAssertEqual(found.map(\.address), ["jane@parkdesign.example"])
        XCTAssertTrue(found.first?.fromTheirMail == true, "only had mail from her: offered by address and marked")
        let mine = await source.people(matching: "a@", limit: 5)
        XCTAssertTrue(mine.isEmpty, "his own address is never suggested")
    }

    /// The From picker on a real account: the draft is told, and saved; another account's address
    /// is not a change it can make.
    func testLiveChangeOfFromIsSavedOnTheDraft() async throws {
        let (_, intent, source, _) = try await actionSource()
        try await prepareDrafts(source, intent)
        var draft = await source.newDraft(.new(account: "a@example.com"))
        XCTAssertEqual(draft.signature, MailBodyHTML.bananaSignature)
        XCTAssertTrue(draft.from.hasSignature)
        draft.signature = nil
        source.save(draft)
        let changed = await source.changeIdentity(of: draft.id, to: "A@example.com")
        XCTAssertEqual(changed?.from.address, "a@example.com")
        XCTAssertEqual(changed?.signature, MailBodyHTML.bananaSignature)
        let refused = await source.changeIdentity(of: draft.id, to: "someone@else.example")
        XCTAssertNil(refused, "another account's address is not this draft's to change to")
        let unknown = await source.changeIdentity(of: MailDraftID(raw: "missing"), to: "a@example.com")
        XCTAssertNil(unknown)
    }

    func testLiveComposerDraftIsDurableAndListedAfterReopening() async throws {
        let (stores, intent, source, _) = try await actionSource()
        try await prepareDrafts(source, intent)
        var draft = await source.newDraft(.new(account: "a@example.com"))
        let first = try await intent.draftRecord(scope: "test-account", id: draft.id)
        XCTAssertNotNil(first, "newDraft must commit before returning")
        draft.subject = "Kept across relaunch"; draft.editedAt = Date()
        let saved = expectation(description: "Saved draft appears in Drafts")
        var seen = false
        let observation = source.observeList(MailScope(place: .mailbox(.drafts)), limit: 10) { value in
            if !seen, value.rows.first?.subject == "Kept across relaunch" { seen = true; saved.fulfill() }
        }
        source.save(draft)
        await fulfillment(of: [saved], timeout: 5); observation.cancel()
        let reopened = MailLiveSource(stores: stores, access: Access(), api: GmailPageLoaderTests.Provider(count: 0))
        try await reopened.prepareActions(intent: intent); try await prepareDrafts(reopened, intent)
        let recovered = await reopened.draft(draft.id)
        XCTAssertEqual(recovered?.subject, "Kept across relaunch")
        let conversation = await reopened.conversation(draft.conversation)
        XCTAssertEqual(conversation?.draft, draft.id)
    }

    func testFailedEditorSaveCannotSendAnOlderPersistedDraft() async throws {
        let (_, intent, source, _) = try await actionSource()
        try await prepareDrafts(source, intent)
        var draft = await source.newDraft(.new(account: "a@example.com"))
        let originalID = draft.id
        // A stale editor from another account is refused by the durable store.
        draft.account = "different@plan.example"; draft.subject = "Unsaved edit"
        let refused = expectation(description: "Send refuses after save failure")
        let events = source.observeEvents { event in
            if case .notSaved = event { refused.fulfill() }
            if case .applied = event { XCTFail("An old saved draft must not be queued") }
        }
        source.save(draft)
        _ = source.send(originalID, .init(hold: 0, thenDone: false))
        await fulfillment(of: [refused], timeout: 5); events.cancel()
        let stored = try await intent.draftRecord(scope: "test-account", id: originalID)
        XCTAssertEqual(stored?.state, .editing); XCTAssertNil(stored?.sendAt)
        let retained = await source.draft(originalID)
        XCTAssertEqual(retained?.subject, "Unsaved edit")
    }

    func testCachedLabelDirectoryReachesLivePlacesAndMessageRows() async throws {
        let (stores, _, source, _) = try await actionSource()
        _ = try await MailWriter(stores: stores, sink: nil).transact { db in
            var change = try MailLabelCatalog.replace(MailLabelCatalogTests.systemLabels + [GmailLabel(id: "Label_7", name: "Projects", type: "user")], account: "a@example.com", in: db)
            let wire = GmailMessage(id: "m", threadId: "t", labelIds: ["INBOX", "Label_7"], historyId: 2)
            change.formUnion(try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 2, headers: MessageHeaders(payload: nil), structure: nil), account: "a@example.com", myAddresses: ["a@example.com"], in: db))
            return change
        }
        let placesReady = expectation(description: "Cached directory published")
        let rowsReady = expectation(description: "Row label name published")
        var sawPlaces = false, sawRows = false
        let places = source.observePlaces { value in
            if !sawPlaces, value.labels["a@example.com"]?.first?.ref.name == "Projects" {
                sawPlaces = true; placesReady.fulfill()
            }
        }
        let rows = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 50) { value in
            if !sawRows, value.rows.first?.labels.first?.name == "Projects" {
                sawRows = true; rowsReady.fulfill()
            }
        }
        source.checkNow()
        await fulfillment(of: [placesReady, rowsReady], timeout: 5)
        places.cancel(); rows.cancel()
    }

    // MARK: The Inbox's unread, for the shell's Mail badge

    func testCachedInboxShowsProviderDraftAndKeepsChronologicalOrder() async throws {
        let (stores, _, source, original) = try await actionSource()
        try await arrive(stores, id: "reply-draft", thread: original.id.thread, labels: ["DRAFT"], date: 2000)
        try await arrive(stores, id: "newer", thread: "newer", labels: ["INBOX"], date: 3000)
        try await arrive(stores, id: "newest-unread", thread: "newest-unread", labels: ["INBOX", "UNREAD"], date: 4000)
        try await arrive(stores, id: "older-unread", thread: "older-unread", labels: ["INBOX", "UNREAD"], date: 500)
        let done = expectation(description: "Retained Inbox publishes without a provider fetch")
        let scope = MailScope(place: .mailbox(.inbox))
        let observation = source.observeList(scope, limit: 10) { snapshot in
            XCTAssertEqual(snapshot.rows.map(\.id.thread), ["newest-unread", "newer", original.id.thread, "older-unread"])
            XCTAssertEqual(snapshot.rows.map(\.reason), [nil, nil, .draft(firstLine: ""), nil])
            XCTAssertEqual(snapshot.rows.map(\.isUnread), [true, false, false, true])
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        observation.cancel()
    }

    private func arrive(_ stores: MailStores, id: String, thread: String, labels: [String], date: Int64) async throws {
        let wire = GmailMessage(id: id, threadId: thread, labelIds: labels, historyId: 2, internalDate: date,
            payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Arrival")]))
        _ = try await MailWriter(stores: stores, sink: nil).transact {
            try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 2, headers: MessageHeaders(payload: wire.payload), structure: nil),
                                          account: "a@example.com", myAddresses: ["a@example.com"], in: $0)
        }
    }

    /// The live source publishes the unified Inbox's unread conversations with the places, and
    /// keeps them current: a new unread arrival, marking read and unread, archiving while unread.
    func testInboxUnreadFollowsArrivalReadUnreadAndArchive() async throws {
        let (stores, _, source, _) = try await actionSource()   // one read conversation
        var latest: MailPlaceCount?
        let places = source.observePlaces { latest = $0.mailboxCounts[.inbox] }
        func settle(_ unread: Int, _ why: String) async {
            for _ in 0..<80 where latest?.unread.value != unread { try? await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(latest?.unread.value, unread, why)
        }
        await settle(0, "a read conversation is not counted")
        XCTAssertEqual(latest?.total.value, 1)

        try await arrive(stores, id: "m2", thread: "t2", labels: ["INBOX", "UNREAD"], date: 2000)
        source.checkNow()
        await settle(1, "a new unread arrival")
        XCTAssertEqual(source.badges.value.unreadInFirstSplit, 1)
        XCTAssertEqual(MailBadgeCounts.mirrored(in: .standard)?.unreadInFirstSplit, 1, "the launch mirror")

        // As the screen acts: on the row as read from the Inbox.
        func shown() async throws -> MailTarget {
            let rows = try await MailIndexReader(stores: stores).page(PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 50))
            let row = try XCTUnwrap(rows.first { $0.thread == "t2" })
            return .asShown([MailRowMapper.row(row, labels: [], reason: nil, in: MailScope(place: .mailbox(.inbox)))])
        }
        source.apply(.read(true), to: try await shown())
        await settle(0, "marked read")
        source.apply(.read(false), to: try await shown())
        await settle(1, "marked unread")
        source.apply(.done, to: try await shown())
        await settle(0, "archived while unread: out of the Inbox")
        XCTAssertEqual(latest?.total.value, 1)
        places.cancel()
    }

    /// The launch's read-only count reads the same number, and makes nothing.
    func testTheLaunchCountReadsTheInboxReadOnly() async throws {
        let stores = try await stores()
        try await arrive(stores, id: "m1", thread: "t1", labels: ["INBOX", "UNREAD"], date: 1000)
        try await arrive(stores, id: "m2", thread: "t2", labels: ["INBOX"], date: 2000)
        let url = stores.directories.indexDatabase
        XCTAssertEqual(MailDirectories.indexDatabase(under: stores.directories.root), url)
        let unread = try await Task.detached {
            let queue = try MailStores.openIndexForCounting(at: url)
            let counts = try queue.read { try MailIndexReader.counts(PageRequest(view: .unified(.inbox), account: nil, filters: [],
                before: nil, limit: 1, allowedAccounts: ["a@example.com"]), in: $0) }
            return counts.unread
        }.value
        XCTAssertEqual(unread, 1)
        let missing = stores.directories.root.appendingPathComponent("nowhere.sqlite")
        let refused = await Task.detached { (try? MailStores.openIndexForCounting(at: missing)) == nil }.value
        XCTAssertTrue(refused, "read only: a missing store is not made")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    /// What the launch's count costs on a full Inbox, off the main thread: 2,000 conversations,
    /// half unread. Printed for the launch report; bounded loosely so a regression shows.
    func testTheLaunchCountOfALargeInboxIsQuick() async throws {
        let budget = CostBudget(self)
        let stores = try await stores()
        _ = try await MailWriter(stores: stores, sink: nil).transact { db in
            var changes = MailStoreChange()
            for n in 0..<2000 {
                let wire = GmailMessage(id: "big-\(n)", threadId: "big-\(n)", labelIds: n % 2 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"],
                    historyId: 1, internalDate: Int64(1000 + n), payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Big \(n)")]))
                changes.formUnion(try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload), structure: nil),
                    account: "a@example.com", myAddresses: ["a@example.com"], in: db))
            }
            return changes
        }
        let url = stores.directories.indexDatabase
        let (unread, ms) = try await Task.detached { () -> (Int, Double) in
            let began = Date()
            let queue = try MailStores.openIndexForCounting(at: url)
            let counts = try queue.read { try MailIndexReader.counts(PageRequest(view: .unified(.inbox), account: nil, filters: [],
                before: nil, limit: 1, allowedAccounts: ["a@example.com"]), in: $0) }
            return (counts.unread, Date().timeIntervalSince(began) * 1000)
        }.value
        print("mail-badge launch count: \(unread) unread of 2000 in \(Int(ms.rounded())) ms (open + count, read only)")
        XCTAssertEqual(unread, 1000)
        budget.expect(ms, below: 500)
        try budget.finish()
    }

    func testInboxCountCapsAtTenThousand() {
        let place = MailInboxCount.place(unread: 12_000, total: MailCount(value: 10_000, isAtLeast: true))
        XCTAssertEqual(place.unread, MailCount(value: 10_000, isAtLeast: true))
        XCTAssertEqual(MailInboxCount.place(unread: 3, total: MailCount(value: 9, isAtLeast: false)).unread,
                       MailCount(value: 3, isAtLeast: false))
    }

    func testActionSetupPublishesInitialRemovalStatusBeforeReturning() async throws {
        let (stores, intent, _, _) = try await actionSource()
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO held_removal(msg_pk,evidence,found_at) SELECT msg_pk,1,1 FROM message")
        }
        let reopened = MailLiveSource(stores: stores, access: Access(), api: GmailPageLoaderTests.Provider(count: 0))
        try await reopened.prepareActions(intent: intent)
        XCTAssertEqual(reopened.status.value.questions.count, 1,
                       "Initial recovery must publish retained review status before the source is handed to the UI")
    }

    func testRemovalNoticeReviewAndKeptStateUseLiveSource() async throws {
        let (stores, _, source, _) = try await actionSource()
        try await stores.index.write { db in
            try db.execute(sql: "INSERT INTO held_removal(msg_pk,evidence,found_at) SELECT msg_pk,1,1 FROM message")
        }
        try await source.loadRemovalStatus()
        XCTAssertEqual(source.status.value.questions.count, 1)
        let review = try await source.beginRemovalReview(account: "a@example.com")
        let page = try await source.removalReviewPage(review.id, after: nil)
        XCTAssertEqual(page.rows.map(\.subject), ["Action"])
        XCTAssertNil(page.next)
        try await source.applyRemovalAnswer(review.id, choice: .keepHere)
        XCTAssertTrue(source.status.value.questions.isEmpty)
        XCTAssertEqual(source.accounts.first?.keptAfterRemoval, 1)
        let rows = try await MailIndexReader(stores: stores).page(PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 50))
        let mapped = MailRowMapper.row(try XCTUnwrap(rows.first), labels: [], reason: nil, in: MailScope(place: .mailbox(.inbox)))
        XCTAssertEqual(mapped.reason, .keptAfterRemoval)
    }

    func testActiveLiveSourceStartsAndStopsMailboxSync() async throws {
        let api = GmailMailboxSyncTests.Provider()
        let (stores, _, source, _) = try await actionSource(deliveryAPI: api)
        source.activate()
        defer { source.setVisible(false) }
        var started = false
        for _ in 0..<200 {
            if try await stores.index.read({ try MailReconcileIndex.state(account: "a@example.com", in: $0) }) != nil {
                started = true; break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(started, "The normal live source must start reconciliation without an opt-in")
        source.setVisible(false)
        try await Task.sleep(for: .milliseconds(50))
        let before = await api.operations
        try await Task.sleep(for: .milliseconds(100))
        let after = await api.operations
        XCTAssertEqual(before, after, "Hiding Mail cancels background sync")
    }

    func testScopeActionAndUndoUseLiveSourceReceipts() async throws {
        let (_, intent, source, row) = try await actionSource()
        let saved = expectation(description: "Scope saved")
        let restored = expectation(description: "Scope undone")
        var original: UInt64 = 0
        let observation = source.observeEvents { event in
            if case .applied(let receipt, let count) = event {
                XCTAssertEqual(count, 1)
                if receipt.sequence == original { saved.fulfill() }
                else { restored.fulfill() }
            }
        }
        let receipt = source.apply(.star(true), to: .scope(MailScope(place: .mailbox(.inbox)), from: row.key))
        original = receipt.sequence
        await fulfillment(of: [saved], timeout: 5)
        let conversation = await source.conversation(row.id)
        XCTAssertEqual(conversation?.appliedThrough, receipt.sequence)
        let pending = try await intent.assertions()
        XCTAssertEqual(pending.first?.assertion.want, true)
        XCTAssertNotNil(source.undo(receipt))
        await fulfillment(of: [restored], timeout: 5)
        let inverse = try await intent.assertions()
        XCTAssertEqual(inverse.first?.assertion.want, false)
        observation.cancel()
    }

    func testMessageActionExcludesLaterReplyWithSameDate() async throws {
        let (stores, intent, source, _) = try await actionSource()
        let wire = GmailMessage(id: "later", threadId: "t", labelIds: ["INBOX"], historyId: 2, internalDate: 1000)
        _ = try await MailWriter(stores: stores, sink: nil).transact {
            try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 2, headers: MessageHeaders(payload: nil), structure: nil), account: "a@example.com", myAddresses: ["a@example.com"], in: $0)
        }
        let saved = expectation(description: "Message action saved")
        let observation = source.observeEvents { if case .applied = $0 { saved.fulfill() } }
        _ = source.apply(.done, to: .message(MailMessageID(account: "a@example.com", message: "m")))
        await fulfillment(of: [saved], timeout: 5)
        let assertions = try await intent.assertions()
        XCTAssertEqual(assertions.map { $0.assertion.messageID }, ["m"])
        XCTAssertEqual(assertions.first?.assertion.labelRef, "INBOX")
        XCTAssertEqual(assertions.first?.assertion.want, false)
        observation.cancel()
    }

    /// Leaving Mail, or leaving and coming back at once, does not interrupt a write already on
    /// its way to Gmail or send it twice.
    func testLeavingMailDoesNotInterruptDelivery() async throws {
        let api = GmailIntentDeliveryTests.Provider()
        await api.configure(onWrite: { try await Task.sleep(for: .milliseconds(300)) })
        let (_, intent, source, row) = try await actionSource(deliveryAPI: api)
        source.activate()
        defer { source.setVisible(false) }
        _ = source.apply(.star(true), to: .asShown([row]))
        var started = false
        for _ in 0..<400 {
            if await api.writes == 1 { started = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(started)
        source.setVisible(false)
        source.setVisible(true)
        source.setVisible(false)
        var confirmed = false
        for _ in 0..<400 {
            let pending = try await intent.assertions()
            if pending.isEmpty { confirmed = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(confirmed)
        let writes = await api.writes
        XCTAssertEqual(writes, 1, "The write in flight finishes; nothing is sent twice")
    }

    func testDeliveryRefusalIsVisibleAndRetryConfirmsProviderState() async throws {
        let api = GmailIntentDeliveryTests.Provider()
        await api.configure(error: .domainPolicy, applies: false)
        let (stores, intent, source, row) = try await actionSource(deliveryAPI: api)
        source.activate()
        defer { source.setVisible(false) }
        let refused = expectation(description: "Refusal published")
        let observation = source.observeEvents { event in
            if case .refused(_, .notAllowedByAdmin) = event { refused.fulfill() }
        }
        let receipt = source.apply(.star(true), to: .asShown([row]))
        await fulfillment(of: [refused], timeout: 5)
        var failures: [MailRefusedChange] = []
        for _ in 0..<200 {
            failures = source.status.value.refused
            if !failures.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(failures.first?.receipt.sequence, receipt.sequence)
        let reader = MailIndexReader(stores: stores)
        let request = PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 50)
        let refusedRows = try await reader.page(request)
        XCTAssertEqual(refusedRows.first?.flags.contains(.starred), false)
        await api.configure()
        source.retry(receipt)
        var confirmed = false
        for _ in 0..<400 {
            let pending = try await intent.assertions()
            let rows = try await reader.page(request)
            if pending.isEmpty && rows.first?.flags.contains(.starred) == true && rows.first?.pending == 0 {
                confirmed = true; break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(confirmed, "Retry must clear intent only after provider state reaches the index")
        let writes = await api.writes
        XCTAssertEqual(writes, 2)
        observation.cancel()
    }

    func testLiveActionPublishesDurableReceiptAndAcknowledgedSnapshot() async throws {
        let (_, intent, source, row) = try await actionSource()
        let applied = expectation(description: "Durable receipt")
        let visible = expectation(description: "Acknowledged starred snapshot")
        var sawVisible = false
        let events = source.observeEvents { event in
            if case .applied(let receipt, let count) = event {
                XCTAssertEqual(receipt.sequence, 1); XCTAssertEqual(count, 1); applied.fulfill()
            }
            if case .notSaved = event { XCTFail("Action was not saved") }
        }
        let list = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 50) { snapshot in
            if snapshot.appliedThrough == 1, snapshot.rows.first?.isStarred == true, !sawVisible {
                sawVisible = true; visible.fulfill()
            }
        }
        let receipt = source.apply(.star(true), to: .asShown([row]))
        XCTAssertEqual(receipt, MailReceipt(sequence: 1, count: 1))
        await fulfillment(of: [applied, visible], timeout: 5)
        let pending = try await intent.assertions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.seq, Int64(receipt.sequence))
        events.cancel(); list.cancel()
    }

    func testLiveProjectionFailureKeepsSavedIntentUntilExplicitRepair() async throws {
        let (stores, intent, source, row) = try await actionSource()
        try await stores.index.write { try $0.execute(sql: "CREATE TRIGGER fail_overlay BEFORE INSERT ON overlay BEGIN SELECT RAISE(ABORT,'injected failure'); END") }
        let applied = expectation(description: "Saved despite projection failure")
        let repaired = expectation(description: "Repaired acknowledged snapshot")
        var sawRepaired = false
        let events = source.observeEvents { event in
            if case .applied = event { applied.fulfill() }
            if case .notSaved = event { XCTFail("Durable intent must not be reported as lost") }
        }
        let list = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 50) { snapshot in
            if snapshot.appliedThrough == 1 {
                XCTAssertEqual(snapshot.rows.first?.isStarred, true)
                if !sawRepaired { sawRepaired = true; repaired.fulfill() }
            }
        }
        _ = source.apply(.star(true), to: .asShown([row]))
        await fulfillment(of: [applied], timeout: 5)
        let pending = try await intent.assertions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(source.status.value.store, .unavailable(.unavailable))
        try await stores.index.write { try $0.execute(sql: "DROP TRIGGER fail_overlay") }
        source.checkNow()
        await fulfillment(of: [repaired], timeout: 5)
        XCTAssertEqual(source.status.value.store, .ready)
        events.cancel(); list.cancel()
    }
    func testLiveIntentFailurePublishesFailureAndUnchangedAcknowledgedRows() async throws {
        let (stores, intent, source, row) = try await actionSource()
        let injection = try await Task.detached { try DatabaseQueue(path: stores.directories.intentDatabase.path) }.value
        try await injection.write { try $0.execute(sql: "CREATE TRIGGER fail_intent BEFORE INSERT ON label_intent BEGIN SELECT RAISE(ABORT,'injected failure'); END") }
        let failed = expectation(description: "Unsaved receipt")
        let unchanged = expectation(description: "Unchanged acknowledged rows")
        var sawUnchanged = false
        let events = source.observeEvents { event in
            if case .notSaved(let receipt, _) = event {
                XCTAssertEqual(receipt.sequence, 1); failed.fulfill()
            }
            if case .applied = event { XCTFail("An unsaved action cannot be acknowledged as applied") }
        }
        let list = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 50) { snapshot in
            if snapshot.appliedThrough == 1 {
                XCTAssertEqual(snapshot.rows.first?.isStarred, false)
                if !sawUnchanged { sawUnchanged = true; unchanged.fulfill() }
            }
        }
        _ = source.apply(.star(true), to: .asShown([row]))
        await fulfillment(of: [failed, unchanged], timeout: 5)
        let pending = try await intent.assertions()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(source.status.value.store, .cannotSave(.unavailable))
        events.cancel(); list.cancel()
    }
    func testUndoBeforeOriginalSaveFinishesPersistsInverseAndHasNoRedo() async throws {
        let (stores, intent, source, row) = try await actionSource()
        let restored = expectation(description: "Inverse acknowledged")
        var seen = false
        let list = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 50) { snapshot in
            if snapshot.appliedThrough == 2, !seen {
                XCTAssertEqual(snapshot.rows.first?.isStarred, false)
                seen = true; restored.fulfill()
            }
        }
        let original = source.apply(.star(true), to: .asShown([row]))
        let inverse = source.undo(original)
        XCTAssertEqual(inverse.sequence, 2)
        XCTAssertEqual(source.undo(original).count, 0, "Duplicate Undo cannot create another inverse")
        await fulfillment(of: [restored], timeout: 5)
        let pending = try await intent.assertions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.seq, 2)
        XCTAssertEqual(pending.first?.assertion.want, false)
        let reopened = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        let durable = try await reopened.assertions()
        XCTAssertEqual(durable, pending)
        XCTAssertEqual(source.undo(original).count, 0)
        XCTAssertEqual(source.undo(inverse).count, 0, "Undo is not redoable")
        list.cancel()
    }

    func testFailedUndoPreservesInverseForAnotherAttempt() async throws {
        let (stores, intent, source, row) = try await actionSource()
        let applied = expectation(description: "Original saved")
        let failed = expectation(description: "Inverse was not saved")
        let retried = expectation(description: "Inverse retry saved")
        let events = source.observeEvents { event in
            switch event {
            case .applied(let receipt, _) where receipt.sequence == 1: applied.fulfill()
            case .notSaved(let receipt, _) where receipt.sequence == 2: failed.fulfill()
            case .applied(let receipt, _) where receipt.sequence == 3: retried.fulfill()
            default: break
            }
        }
        let original = source.apply(.star(true), to: .asShown([row]))
        await fulfillment(of: [applied], timeout: 5)
        let injection = try await Task.detached { try DatabaseQueue(path: stores.directories.intentDatabase.path) }.value
        try await injection.write { try $0.execute(sql: "CREATE TRIGGER fail_inverse BEFORE INSERT ON label_intent WHEN new.seq=2 BEGIN SELECT RAISE(ABORT,'injected failure'); END") }
        XCTAssertEqual(source.undo(original).sequence, 2)
        await fulfillment(of: [failed], timeout: 5)
        let stillOriginal = try await intent.assertions()
        XCTAssertEqual(stillOriginal.first?.seq, 1)
        XCTAssertEqual(stillOriginal.first?.assertion.want, true)
        try await injection.write { try $0.execute(sql: "DROP TRIGGER fail_inverse") }
        XCTAssertEqual(source.undo(original).sequence, 3)
        await fulfillment(of: [retried], timeout: 5)
        let reversed = try await intent.assertions()
        XCTAssertEqual(reversed.first?.seq, 3)
        XCTAssertEqual(reversed.first?.assertion.want, false)
        events.cancel()
    }
    func testEligibilityRecoveryWhileVisibleImportsMailWithoutReentering() async throws {
        let stores = try await stores(), access = Access(), api = GmailPageLoaderTests.Provider(count: 3)
        let source = MailLiveSource(stores: stores, access: access, api: api)
        let arrived = expectation(description: "A recovered policy resumes the mounted Mail screen")
        var delivered = false
        let observation = source.observeList(MailScope(place: .mailbox(.inbox)), limit: 50) { snapshot in
            if snapshot.rows.count == 3, !delivered { delivered = true; arrived.fulfill() }
        }
        defer { observation.cancel(); source.setVisible(false) }
        source.activate() // Starts with no eligible grant, so no requests are started.
        XCTAssertEqual(source.accounts.first?.state, .notConnected)
        access.grant = .granted
        source.accessChanged()
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(source.accounts.first?.state, .connected)
        XCTAssertEqual(source.cachedFirstPage(MailScope(place: .mailbox(.inbox)))?.rows.count, 3)
        access.grant = .none
        source.accessChanged()
        XCTAssertEqual(source.accounts.first?.state, .notConnected)
        let requests = await api.requested
        source.setVisible(false)
        access.grant = .granted
        source.accessChanged()
        XCTAssertEqual(source.accounts.first?.state, .connected)
        let after = await api.requested
        XCTAssertEqual(after, requests, "A policy notification must not activate a hidden source")
    }

    func testConsentDrivesControlledProviderToObservedList() async throws {
        let stores = try await stores(), access = Access(), api = GmailPageLoaderTests.Provider(count: 3)
        let source = MailLiveSource(stores: stores, access: access, api: api)
        XCTAssertEqual(source.accounts.first?.state, .notConnected)
        let scope = MailScope(place: .mailbox(.inbox))
        let arrived = expectation(description: "Imported rows reached source observer")
        var delivered = false
        let observation = source.observeList(scope, limit: 50) { snapshot in
            if snapshot.rows.count == 3 && !delivered {
                delivered = true
                XCTAssertEqual(snapshot.rows.first?.subject, "Subject 2")
                arrived.fulfill()
            }
        }
        source.activate()
        let permission = await source.requestPermission(account: "a@example.com")
        XCTAssertEqual(permission, .granted)
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(source.cachedFirstPage(scope)?.rows.count, 3)
        XCTAssertEqual(source.accounts.first?.state, .connected)
        observation.cancel(); source.setVisible(false)
    }
    func testConversationObserverReceivesImportAndPreparedBody() async throws {
        let stores = try await stores(), access = Access(), api = GmailPageLoaderTests.Provider(count: 1)
        access.grant = .granted
        let source = MailLiveSource(stores: stores, access: access, api: api)
        let id = MailConversationID(account: "a@example.com", thread: "t0")
        let messageID = MailMessageID(account: id.account, message: "m0")
        let headers = expectation(description: "Observed imported conversation")
        let ready = expectation(description: "Observed prepared body state")
        var sawHeaders = false, sawReady = false
        let observation = source.observeConversation(id) { value in
            if value?.messages.first?.body == .notOnDevice && !sawHeaders {
                sawHeaders = true; headers.fulfill()
            }
            if value?.messages.first?.body == .text && !sawReady {
                sawReady = true; ready.fulfill()
            }
        }
        source.activate()
        await fulfillment(of: [headers], timeout: 5)
        let missing = await source.body(messageID)
        XCTAssertEqual(missing, .notOnDevice)
        let wire = GmailMessage(id: "m0", threadId: "t0", internalDate: 1000,
            payload: GmailPart(partId: "0", mimeType: "text/plain", headers: [], body: GmailPartBody(data: "SGVsbG8")))
        let blobs = MailBlobStore(stores: stores)
        try await blobs.put(wire, account: id.account, extraction: MIMEStructure.extract(wire.payload!), ftsRowID: 1, at: 1000)
        _ = try await blobs.prepare(account: id.account, messageID: messageID.message, at: 1001)
        source.checkNow() // The metadata commit must invalidate the observed conversation.
        await fulfillment(of: [ready], timeout: 5)
        let body = await source.body(messageID)
        guard case .text(let text, _, _) = body else { return XCTFail("Prepared body missing") }
        XCTAssertEqual(text.blocks.first?.runs.first?.text, "Hello")
        observation.cancel(); source.setVisible(false)
    }

    func testCalendarCopiesVerifyAfterTheBodyIsAvailable() async throws {
        let stores = try await stores(), access = Access(), api = GmailConversationLoaderTests.Provider()
        await api.calendarCopies()
        await api.holdCalendarAttachments()
        access.grant = .granted
        let source = MailLiveSource(stores: stores, access: access, api: api)
        let id = MailConversationID(account: "a@example.com", thread: "t1")
        let readable = expectation(description: "Body is usable before optional attachment verification")
        let verified = expectation(description: "Identical calendar copies become one chip")
        var sawBody = false, sawVerified = false
        let observation = source.observeConversation(id) { value in
            guard let message = value?.messages.first, message.body == .text else { return }
            if !sawBody, message.attachments.count == 2 { sawBody = true; readable.fulfill() }
            if !sawVerified, message.attachments.count == 1 { sawVerified = true; verified.fulfill() }
        }
        source.activate()
        await fulfillment(of: [readable], timeout: 5)
        await api.releaseCalendarAttachments()
        await fulfillment(of: [verified], timeout: 5)
        observation.cancel(); source.setVisible(false)
        let reads = await api.attachments
        XCTAssertEqual(reads, ["calendar-a", "calendar-b"])
    }

    func testReturningToMailResumesObservedConversationDownload() async throws {
        let stores = try await stores(), access = Access(), api = GmailConversationLoaderTests.Provider()
        access.grant = .granted
        let source = MailLiveSource(stores: stores, access: access, api: api)
        let id = MailConversationID(account: "a@example.com", thread: "t1")
        let ready = expectation(description: "Resumed conversation downloads and prepares body")
        var delivered = false
        let observation = source.observeConversation(id) { value in
            if value?.messages.first?.body == .text && !delivered {
                delivered = true; ready.fulfill()
            }
        }
        source.setVisible(false) // The reader survives while its queued download is cancelled.
        source.activate()
        await fulfillment(of: [ready], timeout: 5)
        let body = await source.body(MailMessageID(account: id.account, message: "m1"))
        guard case .text(let text, _, _) = body else {
            observation.cancel(); source.setVisible(false)
            return XCTFail("Returning reader never received its downloaded body")
        }
        XCTAssertEqual(text.blocks.first?.runs.first?.text, "Hello")
        observation.cancel(); source.setVisible(false)
    }

    func testLabelAccountWinsOverOuterAccountFilter() async throws {
        let stores = try await stores(), access = Access(), api = GmailPageLoaderTests.Provider(count: 1)
        access.grant = .granted
        let source = MailLiveSource(stores: stores, access: access, api: api)
        let arrived = expectation(description: "Label scoped row arrived")
        var delivered = false
        let observation = source.observeList(MailScope(place: .label(account: "a@example.com", id: "INBOX"), account: "b@example.com"), limit: 50) { snapshot in
            if snapshot.rows.count == 1 && !delivered { delivered = true; arrived.fulfill() }
        }
        source.activate()
        await fulfillment(of: [arrived], timeout: 5)
        observation.cancel(); source.setVisible(false)
    }
    func testDiskHistoryWindowsReachBeyondCapForInboxAndSearch() async throws {
        let stores = try await stores()
        let owner = "a@example.com"
        let count = MailTuning.listCap + 7
        _ = try await MailWriter(stores: stores, sink: nil).transact { db in
            var change = MailStoreChange()
            for index in 0..<count {
                let wire = GmailMessage(id: "m\(index)", threadId: "t\(index)", labelIds: ["INBOX"],
                    historyId: 1, internalDate: Int64(1000 + index),
                    payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "History \(index)")]))
                change.formUnion(try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1,
                    headers: MessageHeaders(payload: wire.payload), structure: nil),
                    account: owner, myAddresses: [owner], in: db))
            }
            return change
        }
        let source = MailLiveSource(stores: stores, access: Access(), api: GmailPageLoaderTests.Provider(count: 0))
        func snapshot(_ scope: MailScope, limit: Int) async throws -> MailListSnapshot {
            let done = expectation(description: "Disk history window")
            var result: MailListSnapshot?
            let observation = source.observeList(scope, limit: limit) { value in
                guard result == nil else { return }
                result = value; done.fulfill()
            }
            await fulfillment(of: [done], timeout: 5)
            observation.cancel()
            return try XCTUnwrap(result)
        }
        for place in [MailPlace.mailbox(.inbox), .search("History")] {
            var scope = MailScope(place: place, account: owner)
            let first = try await snapshot(scope, limit: MailTuning.listCap)
            XCTAssertEqual(first.rows.count, MailTuning.listCap)
            XCTAssertTrue(first.hasMore)
            scope.before = try XCTUnwrap(first.rows.last).key
            let next = try await snapshot(scope, limit: 100)
            XCTAssertEqual(next.rows.count, 7)
            XCTAssertFalse(next.hasMore)
            XCTAssertEqual(Set((first.rows + next.rows).map(\.id)).count, count)
            scope.before = try XCTUnwrap(next.rows.last).key
            let empty = try await snapshot(scope, limit: 100)
            XCTAssertTrue(empty.rows.isEmpty)
            XCTAssertFalse(empty.hasMore, "Whole-mailbox totals must not create endless older pages")
        }
    }

    func testUnlinkedCachedAccountsCannotFillUnifiedInboxOrSearchPages() async throws {
        let stores = try await stores(), access = Access()
        try await stores.index.write { db in
            for index in 0..<30 {
                let owner = index == 0 ? "a@example.com" : "old@plan.example"
                let wire = GmailMessage(id: "scope-\(index)", threadId: "scope-\(index)", labelIds: ["INBOX"],
                    historyId: 1, internalDate: Int64(1000 + index),
                    payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Needle \(index)")]))
                _ = try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1,
                    headers: MessageHeaders(payload: wire.payload), structure: nil), account: owner, myAddresses: [owner], in: db)
            }
        }
        let source = MailLiveSource(stores: stores, access: access, api: GmailPageLoaderTests.Provider(count: 0))
        for place in [MailPlace.mailbox(.inbox), .search("Needle")] {
            let done = expectation(description: "Only linked account reaches unified page")
            let observation = source.observeList(MailScope(place: place), limit: 1) { value in
                XCTAssertEqual(value.rows.map { $0.id.account }, ["a@example.com"])
                XCTAssertEqual(value.total.value, 1)
                if place == .mailbox(.inbox) { XCTAssertFalse(value.hasMore) }
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 5); observation.cancel()
        }
        let retained = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") }
        XCTAssertEqual(retained, 30, "Account scoping must not delete retained mail")
        access.connectedAccountIDs = []
        let scope = MailScope(place: .mailbox(.inbox))
        XCTAssertNil(source.cachedFirstPage(scope), "A cached page from the old identity cannot flash on screen")
        source.checkNow()
        let empty = expectation(description: "Explicit empty account set is empty")
        let observation = source.observeList(scope, limit: 1) { value in
            XCTAssertTrue(value.rows.isEmpty); XCTAssertEqual(value.total.value, 0); empty.fulfill()
        }
        await fulfillment(of: [empty], timeout: 5); observation.cancel(); source.setVisible(false)
    }

    func testEmptyLocalSearchDoesNotPretendInboxIsSearchResults() async throws {
        let source = MailLiveSource(stores: try await stores(), access: Access(), api: GmailPageLoaderTests.Provider(count: 1))
        let arrived = expectation(description: "Local search result")
        let observation = source.observeList(MailScope(place: .search("needle")), limit: 50) { snapshot in
            XCTAssertNil(snapshot.remote)
            XCTAssertTrue(snapshot.rows.isEmpty)
            arrived.fulfill()
        }
        await fulfillment(of: [arrived], timeout: 5)
        observation.cancel()
    }
}
