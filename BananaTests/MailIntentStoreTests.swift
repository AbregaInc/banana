import XCTest

final class MailIntentStoreTests: XCTestCase {
    private func setup() async throws -> (MailDirectories, MailIntentStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-intent-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached {
            let directories = try MailDirectories(root: root)
            return (directories, try MailIntentStore(directories: directories))
        }.value
    }
    private func assertion(_ message: String, want: Bool = true, account: String = "a@example.com") -> Assertion {
        Assertion(account: account, messageID: message, labelRef: "STARRED", want: want, origin: .person)
    }
    private func key(_ seq: Int64) -> SentKey {
        SentKey(account: "a@example.com", messageID: "m", labelRef: "STARRED", sentSeq: seq)
    }

    func testVerifiedRemovalClearsOnlyItsMessagesAndSurvivesRestart() async throws {
        let (directories, store) = try await setup()
        _ = try await store.record(.star(true), assertions: [assertion("gone"), assertion("stay"),
            assertion("gone", account: "b@example.com")], conversations: 3, at: 1)
        try await store.discardForVerifiedRemoval(account: "a@example.com", messages: ["gone"])
        try await store.discardForVerifiedRemoval(account: "a@example.com", messages: ["gone"])
        let reopened = try await Task.detached { try MailIntentStore(directories: directories) }.value
        let remaining = try await reopened.assertions()
        XCTAssertEqual(Set(remaining.map { $0.assertion.account + ":" + $0.assertion.messageID }),
            ["a@example.com:stay", "b@example.com:gone"])
        XCTAssertEqual(Set(remaining.map(\.groupSeq)).count, 1)
    }

    func testStagedBulkCommitAndInverseAreAtomicAcrossRestart() async throws {
        let (directories, store) = try await setup()
        let stage = UUID().uuidString
        let total = 1103
        for offset in stride(from: 0, to: total, by: 97) {
            let values = (offset..<min(offset + 97, total)).map { n in
                MailIntentStore.StagedAssertion(thread: "t", assertion: assertion("m\(n)",
                    account: n.isMultiple(of: 2) ? "a@example.com" : "b@example.com"), previous: false)
            }
            try await store.appendStage(stage, values: values)
        }
        let invisible = try await store.assertions()
        XCTAssertTrue(invisible.isEmpty, "Uncommitted preparation cannot be delivered")
        let count = try await store.commitStage(stage, change: .star(true), sequence: 1, at: 1)
        XCTAssertEqual(count, 2)
        let reopened = try await Task.detached { try MailIntentStore(directories: directories) }.value
        let undone = try await reopened.commitStoredInverse(1, change: .star(true), sequence: 2, at: 2)
        XCTAssertEqual(undone, 2)
        var cursor: MailIntentStore.Cursor?, messages = Set<String>(), observed = 0
        while true {
            let page = try await reopened.assertions(after: cursor)
            guard let last = page.last else { break }
            XCTAssertTrue(page.allSatisfy { !$0.assertion.want && $0.seq == 2 && $0.state == .pending })
            messages.formUnion(page.map { $0.assertion.messageID })
            observed += page.count
            cursor = MailIntentStore.Cursor(last)
        }
        XCTAssertEqual(observed, total)
        XCTAssertEqual(messages.count, total)
        do {
            _ = try await reopened.commitStoredInverse(1, change: .star(true), sequence: 3, at: 3)
            XCTFail("An inverse must not be applied twice")
        } catch { XCTAssertTrue(error is MailIntentStore.Failure) }
    }

    func testFailedStageCommitLeavesPriorIntentAndInverseRetryable() async throws {
        let (_, store) = try await setup()
        _ = try await store.record(.star(false), account: "a@example.com", assertions: [assertion("m", want: false)], conversations: 1, at: 1)
        let stage = UUID().uuidString
        try await store.appendStage(stage, values: [.init(thread: "t", assertion: assertion("m"), previous: false)])
        do {
            _ = try await store.commitStage(stage, change: .star(true), sequence: 1, at: 2)
            XCTFail("Reused receipt accepted")
        } catch { XCTAssertTrue(error is MailIntentStore.Failure) }
        let prior = try await store.assertions()
        XCTAssertEqual(prior.first?.assertion.want, false)
        XCTAssertEqual(prior.first?.seq, 1)
        let count = try await store.commitStage(stage, change: .star(true), sequence: 2, at: 2)
        XCTAssertEqual(count, 1)
        do {
            _ = try await store.commitStoredInverse(2, change: .star(true), sequence: 2, at: 3)
            XCTFail("Inverse receipt collision accepted")
        } catch { XCTAssertTrue(error is MailIntentStore.Failure) }
        let undoCount = try await store.commitStoredInverse(2, change: .star(true), sequence: 3, at: 3)
        XCTAssertEqual(undoCount, 1)
        let final = try await store.assertions()
        XCTAssertEqual(final.first?.assertion.want, false)
        XCTAssertEqual(final.first?.seq, 3)
    }

    func testAbandonedStageCleanupCannotEraseCommittedIntent() async throws {
        let (_, store) = try await setup()
        _ = try await store.record(.star(true), account: "a@example.com", assertions: [assertion("m")], conversations: 1, at: 1)
        try await store.appendStage("abandoned", values: [.init(thread: "other", assertion: assertion("other"), previous: false)])
        try await store.discardUncommittedStages()
        let count = try await store.commitStage("abandoned", change: .star(true), sequence: 2, at: 2)
        XCTAssertEqual(count, 0)
        let rows = try await store.assertions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.assertion.messageID, "m")
    }

    func testRefusedGroupsPageFromDiskAndRetryRemovesOnlySelectedGroup() async throws {
        let (directories, store) = try await setup()
        for n in 0..<53 {
            let message = "refused-\(n)"
            let seq = try await store.record(.star(true), account: "a@example.com", assertions: [assertion(message)], conversations: 1, at: 1)
            let sent = SentKey(account: "a@example.com", messageID: message, labelRef: "STARRED", sentSeq: seq)
            try await store.markInFlight([sent])
            try await store.refused([sent], failure: .accessMissing)
        }
        let reopened = try await Task.detached { try MailIntentStore(directories: directories) }.value
        let first = try await reopened.refused(limit: 50)
        XCTAssertEqual(first.count, 50)
        XCTAssertTrue(first.allSatisfy { $0.failure == .accessMissing && $0.account == "a@example.com" })
        let last = try XCTUnwrap(first.last)
        let second = try await reopened.refused(after: Int64(last.receipt.sequence), limit: 50)
        XCTAssertEqual(second.count, 3)
        XCTAssertTrue(Set(first.map { $0.receipt.sequence }).isDisjoint(with: second.map { $0.receipt.sequence }))
        try await reopened.retry(group: Int64(first[0].receipt.sequence))
        let remaining = try await reopened.refused(limit: 100)
        XCTAssertEqual(remaining.count, 52)
        XCTAssertFalse(remaining.contains { $0.receipt.sequence == first[0].receipt.sequence })
    }

    func testGroupPagingKeepsAllAssertionsAcrossAccounts() async throws {
        let (_, store) = try await setup()
        let assertions = (0..<1103).map { assertion("m\($0)", account: $0.isMultiple(of: 2) ? "a@example.com" : "b@example.com") }
        let seq = try await store.record(.star(true), assertions: assertions, conversations: 1103, at: 1)
        var cursor: MailIntentStore.Cursor?, messages = Set<String>(), count = 0
        while true {
            let page = try await store.assertions(group: seq, after: cursor)
            guard let last = page.last else { break }
            XCTAssertLessThanOrEqual(page.count, 500)
            count += page.count
            messages.formUnion(page.map { $0.assertion.messageID })
            cursor = MailIntentStore.Cursor(last)
        }
        XCTAssertEqual(count, 1103)
        XCTAssertEqual(messages.count, 1103)
    }

    func testLateDeliveryAndFailureCannotEraseNewerIntent() async throws {
        let (_, store) = try await setup()
        let first = try await store.record(.star(true), account: "a@example.com", assertions: [assertion("m")], conversations: 1, at: 1)
        try await store.markInFlight([key(first)])
        let second = try await store.record(.star(false), account: "a@example.com", assertions: [assertion("m", want: false)], conversations: 1, at: 2)
        XCTAssertGreaterThan(second, first)
        try await store.confirmed([key(first)])
        try await store.refused([key(first)], failure: .accessMissing)
        var rows = try await store.assertions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.seq, second)
        XCTAssertEqual(rows.first?.assertion.want, false)
        XCTAssertEqual(rows.first?.state, .pending)
        try await store.markInFlight([key(second)])
        try await store.confirmed([key(second)])
        rows = try await store.assertions()
        XCTAssertTrue(rows.isEmpty)
    }

    func testRestartPreservesRefusalAndRecoversInterruptedDelivery() async throws {
        let (directories, initial) = try await setup()
        let seq = try await initial.record(.star(true), account: "a@example.com", assertions: [assertion("m"), assertion("other")], conversations: 2, at: 1)
        let secondKey = SentKey(account: "a@example.com", messageID: "other", labelRef: "STARRED", sentSeq: seq)
        try await initial.markInFlight([key(seq), secondKey])
        try await initial.refused([key(seq)], failure: .notAllowedByAdmin)
        // A separate newly opened reader must see committed data, without relying on RAM state.
        let reopened = try await Task.detached { try MailIntentStore(directories: directories) }.value
        try await reopened.recoverInterruptedDelivery()
        var rows = try await reopened.assertions()
        XCTAssertEqual(rows.first { $0.assertion.messageID == "m" }?.failure, .notAllowedByAdmin)
        XCTAssertEqual(rows.first { $0.assertion.messageID == "m" }?.state, .refused)
        XCTAssertEqual(rows.first { $0.assertion.messageID == "other" }?.state, .pending)
        try await reopened.retry(group: seq)
        rows = try await reopened.assertions()
        XCTAssertTrue(rows.allSatisfy { $0.state == .pending && $0.failure == nil })
        // Cache deletion cannot remove durable user intent.
        try FileManager.default.removeItem(at: directories.cache)
        rows = try await reopened.assertions()
        XCTAssertEqual(rows.count, 2)
    }

    func testKeysetPagingDoesNotLoseLargeGroups() async throws {
        let (_, store) = try await setup()
        _ = try await store.record(.star(true), account: "a@example.com", assertions: (0..<1203).map { assertion("m\($0)") }, conversations: 1203, at: 1)
        var cursor: MailIntentStore.Cursor?, ids = Set<String>(), count = 0
        while true {
            let page = try await store.assertions(after: cursor, limit: 47)
            guard let last = page.last else { break }
            count += page.count; ids.formUnion(page.map { $0.assertion.messageID })
            cursor = MailIntentStore.Cursor(last)
        }
        XCTAssertEqual(count, 1203); XCTAssertEqual(ids.count, 1203)
    }

    func testInvalidAccountGroupDoesNotPartiallyPersist() async throws {
        let (_, store) = try await setup()
        do {
            _ = try await store.record(.star(true), account: "a@example.com", assertions: [assertion("m"), assertion("foreign", account: "b@example.com")], conversations: 2, at: 1)
            XCTFail("Mixed account group accepted")
        } catch { XCTAssertTrue(error is MailIntentStore.Failure) }
        let rows = try await store.assertions()
        XCTAssertTrue(rows.isEmpty)
        let seq = try await store.record(.star(true), account: "a@example.com", assertions: [assertion("m")], conversations: 1, at: 2)
        XCTAssertEqual(seq, 1)
    }

    func testProposedReceiptSurvivesRestartAndCannotBeReused() async throws {
        let (directories, store) = try await setup()
        let first = try await store.nextSequence()
        XCTAssertEqual(first, 1)
        // Failed/no-op commands may leave gaps in the UI's receipt sequence.
        let committed = try await store.record(.star(true), account: "a@example.com",
            assertions: [assertion("m")], conversations: 1, at: 1, sequence: 7)
        XCTAssertEqual(committed, 7)
        do {
            _ = try await store.record(.star(false), account: "a@example.com",
                assertions: [assertion("m", want: false)], conversations: 1, at: 2, sequence: 7)
            XCTFail("A stale allocator reused a receipt")
        } catch { XCTAssertTrue(error is MailIntentStore.Failure) }
        let reopened = try await Task.detached { try MailIntentStore(directories: directories) }.value
        let next = try await reopened.nextSequence()
        XCTAssertEqual(next, 8)
        let rows = try await reopened.assertions()
        XCTAssertEqual(rows.first?.seq, 7)
        XCTAssertEqual(rows.first?.assertion.want, true)
    }

    func testUnifiedActionCommitsAndRetriesBothAccountsUnderOneReceipt() async throws {
        let (_, store) = try await setup()
        let values = [assertion("m"), assertion("m", account: "b@example.com")]
        let sequence = try await store.record(.star(true), assertions: values,
            conversations: 2, at: 1, sequence: 4)
        let keys = values.map { SentKey(account: $0.account, messageID: $0.messageID,
            labelRef: $0.labelRef, sentSeq: sequence) }
        try await store.markInFlight(keys)
        try await store.refused(keys, failure: .accessMissing)
        try await store.retry(group: sequence)
        let rows = try await store.assertions()
        XCTAssertEqual(Set(rows.map { $0.assertion.account }), ["a@example.com", "b@example.com"])
        XCTAssertTrue(rows.allSatisfy { $0.groupSeq == sequence && $0.state == .pending })
        do {
            _ = try await store.record(.star(false), assertions: [assertion("m", want: false), assertion("bad", account: "UPPER@example.com")], conversations: 2, at: 2, sequence: 5)
            XCTFail("An invalid member partially committed a unified action")
        } catch { XCTAssertTrue(error is MailIntentStore.Failure) }
        let unchanged = try await store.assertions()
        XCTAssertEqual(unchanged, rows)
        let next = try await store.nextSequence()
        XCTAssertEqual(next, 5)
    }
}
