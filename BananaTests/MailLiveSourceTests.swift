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
        func forgetMailAccess(accountID: String) async throws { grant = .none }
        func cancelMailTokenRequests() {}
    }
    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-live-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    private func actionSource(deliveryAPI: (any GmailAPI)? = nil) async throws -> (MailStores, MailIntentStore, MailLiveSource, MailRow) {
        let stores = try await stores()
        let intent = try await Task.detached { try MailIntentStore(directories: stores.directories) }.value
        let wire = GmailMessage(id: "m", threadId: "t", labelIds: ["INBOX"], historyId: 1, internalDate: 1000,
            payload: GmailPart(headers: [GmailHeader(name: "Subject", value: "Action")]))
        _ = try await MailWriter(stores: stores, sink: nil).transact {
            try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload), structure: nil), account: "a@example.com", myAddresses: ["a@example.com"], in: $0)
        }
        let access = Access()
        if deliveryAPI != nil { access.grant = .granted }
        let source = MailLiveSource(stores: stores, access: access, api: deliveryAPI ?? GmailPageLoaderTests.Provider(count: 0), deliveryAllowed: { _ in deliveryAPI != nil })
        try await source.prepareActions(intent: intent)
        let rows = try await MailIndexReader(stores: stores).page(PageRequest(view: .unified(.inbox), account: nil, filters: [], before: nil, limit: 50))
        let row = MailRowMapper.row(try XCTUnwrap(rows.first), labels: [], reason: nil, in: MailScope(place: .mailbox(.inbox)))
        return (stores, intent, source, row)
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
        let draft = await source.newDraft(.new(account: "a@example.com"))
        let changed = await source.changeIdentity(of: draft.id, to: "A@example.com")
        XCTAssertEqual(changed?.from.address, "a@example.com")
        XCTAssertNil(changed?.signature)
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

    func testReactivationWhileCancelledDeliveryUnwindsResumesPendingIntent() async throws {
        let api = GmailIntentDeliveryTests.Provider()
        await api.configure(onWrite: { try await Task.sleep(for: .seconds(30)) })
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
        await api.configure()
        // No suspension between hiding and reopening: the cancelled task is still owned.
        source.setVisible(false)
        source.setVisible(true)
        var confirmed = false
        for _ in 0..<400 {
            let pending = try await intent.assertions()
            if pending.isEmpty { confirmed = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(confirmed)
        let writes = await api.writes
        XCTAssertEqual(writes, 2, "Reactivation must wake delivery after cancellation releases its claim")
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
    func testConsentDrivesControlledProviderToObservedList() async throws {
        let stores = try await stores(), access = Access(), api = GmailPageLoaderTests.Provider(count: 3)
        let source = MailLiveSource(stores: stores, access: access, api: api)
        XCTAssertEqual(source.accounts.first?.state, .needsAccess(.notAllowedHere))
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
