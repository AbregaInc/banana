#if DEBUG || MAIL_FIXTURES
import XCTest

/// The in-memory source (`MailFixtureSource`) behaves as the contract says a source does: a change
/// is applied to the one mailbox, every observer hears of it before the call returns, Undo puts
/// back exactly what that change changed, and a row that leaves the inbox leaves it.
@MainActor
final class MailFixtureSourceTests: XCTestCase {

    private let inbox = MailScope(place: .mailbox(.inbox))
    private let account = MailFixtureConversations.account

    private func id(_ key: String) -> MailConversationID {
        MailConversationID(account: account, thread: key)
    }

    private func rows(_ source: MailFixtureSource, _ scope: MailScope? = nil) -> [MailRow] {
        source.cachedFirstPage(scope ?? inbox).map(\.rows) ?? []
    }

    private func row(_ source: MailFixtureSource, _ key: String) -> MailRow? {
        // The whole inbox, not the first page.
        var found: MailRow?
        let observation = source.observeList(inbox, limit: 1_000) { found = $0.rows.first { $0.id == self.id(key) } }
        observation.cancel()
        return found
    }

    private func conversation(_ source: MailFixtureSource, _ key: String) async throws -> MailConversation {
        let found = await source.conversation(id(key))
        return try XCTUnwrap(found)
    }

    // MARK: The mailbox

    func testTheSampleInboxIsFortyConversationsNewestFirstWithUniqueKeys() {
        let source = MailFixtureSource()
        let all = source.cachedFirstPage(inbox)
        XCTAssertEqual(all?.total, MailCount(value: 40, isAtLeast: false))
        let shown = rows(source)
        XCTAssertEqual(shown.count, 40)
        XCTAssertEqual(Set(shown.map(\.id)).count, 40, "one row for each conversation")
        XCTAssertEqual(Set(shown.map(\.key)).count, 40, "no two rows share a place in the order")
        XCTAssertEqual(shown.map(\.key), shown.map(\.key).sorted(by: >), "a list is its rows in descending key order")
        XCTAssertEqual(shown.first?.id, id("q3"))
        XCTAssertTrue(shown.allSatisfy { $0.inInbox })
    }

    func testStressPagesMatchFullSortAndInvalidateAfterMutation() {
        let source = MailFixtureSource(samples: MailFixtureConversations.stress(days: 1))
        for scope in [inbox, MailScope(place: .mailbox(.starred)),
                      MailScope(place: .mailbox(.inbox), filters: [.unread])] {
            let expected = source.threads.values.map(\.row).filter { row in
                if scope.place == .mailbox(.starred) && !row.isStarred { return false }
                return !scope.filters.contains(.unread) || row.isUnread
            }.sorted { $0.key > $1.key }
            for limit in [0, 1, 50, 250, 3_000] {
                var snapshot: MailListSnapshot?
                let observation = source.observeList(scope, limit: limit) { snapshot = $0 }
                XCTAssertEqual(snapshot?.rows.map(\.id), Array(expected.prefix(limit)).map(\.id))
                XCTAssertEqual(snapshot?.total.value, expected.count)
                XCTAssertEqual(snapshot?.hasMore, expected.count > limit)
                observation.cancel()
            }
        }
        let before = source.cachedFirstPage(inbox)!
        let first = before.rows[0].id
        let receipt = source.apply(.done, to: .conversations([first]))
        XCTAssertEqual(source.cachedFirstPage(inbox)?.total.value, 1_999)
        XCTAssertFalse(source.cachedFirstPage(inbox)!.rows.contains { $0.id == first })
        source.undo(receipt)
        XCTAssertEqual(source.cachedFirstPage(inbox)?.rows.map(\.id), before.rows.map(\.id))
    }

    func testReadAndStarUpdateCachedPagesFilteredMembershipAndCountsThroughUndo() {
        let source = MailFixtureSource(samples: MailFixtureConversations.stress(days: 1))
        let unread = MailScope(place: .mailbox(.inbox), filters: [.unread])
        let starred = MailScope(place: .mailbox(.starred))
        let allBefore = source.cachedFirstPage(inbox)!
        let unreadBefore = source.cachedFirstPage(unread)!
        let starredBefore = source.cachedFirstPage(starred)!
        let target = unreadBefore.rows[0].id
        var counts: MailPlaces?
        let observer = source.observePlaces { counts = $0 }
        let unreadCount = counts?.mailboxCounts[.inbox]?.unread.value
        let receipt = source.apply(.read(true), to: .conversations([target]))
        XCTAssertEqual(source.cachedFirstPage(inbox)?.rows.map(\.id), allBefore.rows.map(\.id))
        XCTAssertFalse(source.cachedFirstPage(inbox)!.rows.first { $0.id == target }?.isUnread ?? true)
        XCTAssertEqual(source.cachedFirstPage(unread)?.total.value, unreadBefore.total.value - 1)
        XCTAssertFalse(source.cachedFirstPage(unread)!.rows.contains { $0.id == target })
        XCTAssertEqual(counts?.mailboxCounts[.inbox]?.unread.value, unreadCount.map { $0 - 1 })
        source.undo(receipt)
        XCTAssertEqual(source.cachedFirstPage(unread)?.rows, unreadBefore.rows)
        XCTAssertEqual(counts?.mailboxCounts[.inbox]?.unread.value, unreadCount)
        let starReceipt = source.apply(.star(true), to: .conversations([target]))
        XCTAssertTrue(source.cachedFirstPage(inbox)!.rows.first { $0.id == target }?.isStarred ?? false)
        source.undo(starReceipt)
        XCTAssertEqual(source.cachedFirstPage(starred)?.rows, starredBefore.rows)
        observer.cancel()
    }

    func testTheClockIsFixedAtMondayTheFifthAt941() {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .weekday, .hour, .minute],
                                                    from: MailFixtureConversations.now)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.weekday, parts.hour, parts.minute],
                       [2026, 10, 5, 2, 9, 41])
        // Every conversation was written before it.
        XCTAssertTrue(rows(MailFixtureSource()).allSatisfy { $0.date <= MailFixtureConversations.now })
    }

    func testTheNamedConversationsAreAsMAILUX132SaysTheyAre() async throws {
        let source = MailFixtureSource()
        let q3 = try XCTUnwrap(row(source, "q3"))
        XCTAssertEqual(q3.messageCount, 3)
        XCTAssertTrue(q3.isUnread && q3.isStarred && q3.hasAttachment)
        XCTAssertEqual(q3.labels.map(\.name), ["Invoices"])
        XCTAssertEqual(q3.people.map(\.name), ["Sam Lee", "Jane Park"])

        let forty = try await conversation(source, "forty")
        XCTAssertEqual(forty.messages.count, 40)
        XCTAssertEqual(forty.messages.filter(\.isUnread).count, 3)
        XCTAssertEqual(Set(forty.messages.map(\.from.address)).count, 9, "nine people")

        let long = try await conversation(source, "long")
        XCTAssertGreaterThanOrEqual(long.subject.count, 280)
        XCTAssertEqual(long.messages[0].to.count, 13, "twelve recipients and himself")
        let longBody = await source.body(long.messages[0].id)
        guard case .text(let text, _, _) = longBody else { return XCTFail("a plain body") }
        XCTAssertGreaterThan(text.blocks.reduce(0) { $0 + MailAttributedText.plain($1.runs).count }, 28_000)

        let rtl = try XCTUnwrap(row(source, "rtl"))
        XCTAssertFalse(rtl.people.isEmpty)
        XCTAssertEqual(row(source, "invite")?.isInvitation, true)
        XCTAssertEqual(row(source, "no-subject")?.subject, "")
        XCTAssertNil(row(source, "lookalike")?.people.first?.name,
                     "a name that reads like his own address is withheld and the address shown")
        XCTAssertEqual((1...8).compactMap { row(source, "github-\($0)") }.count, 8)
    }

    func testAMessageBodyIsPlainTextAndADesignedOneSaysItIsShownAsText() async throws {
        let source = MailFixtureSource()
        let q3 = try await conversation(source, "q3")
        let plain = await source.body(q3.messages[2].id)
        guard case .text(let text, _, let notices) = plain else { return XCTFail("a plain body") }
        XCTAssertTrue(notices.isEmpty)
        XCTAssertTrue(text.blocks.contains { if case .quote = $0.kind { return true } else { return false } },
                      "the quote of the message before it is a quote block")

        let newsletter = try await conversation(source, "newsletter")
        guard case .text(_, _, let shown) = await source.body(newsletter.messages[0].id) else {
            return XCTFail("text")
        }
        XCTAssertEqual(shown, [.shownAsText])

        let missing = await source.body(MailMessageID(account: account, message: "nope~1"))
        XCTAssertEqual(missing, .notOnDevice)
        let none = await source.conversation(id("nope"))
        XCTAssertNil(none)
    }

    func testQuotesAreNestedAsDeepAsTheChainSaysAndNoDeeperThanFive() async throws {
        let source = MailFixtureSource()
        let chain = try await conversation(source, "plain-chain")
        XCTAssertEqual(chain.messages.count, 6)
        guard case .text(let last, _, _) = await source.body(chain.messages[5].id) else { return XCTFail("text") }
        let depths = last.blocks.compactMap { block -> Int? in
            if case .quote(let depth) = block.kind { return depth } else { return nil }
        }
        XCTAssertEqual(depths, [1, 2, 3, 4, 5])
    }

    // MARK: A change, applied

    func testDoneRemovesTheConversationFromTheInboxBeforeTheCallReturns() {
        let source = MailFixtureSource()
        var heard: [MailListSnapshot] = []
        let observation = source.observeList(inbox, limit: 100) { heard.append($0) }
        XCTAssertEqual(heard.count, 1, "the first reading arrives at once")

        let receipt = source.apply(.done, to: .conversations([id("q3")]))

        XCTAssertEqual(heard.count, 2, "heard before apply returned")
        let after = heard[1]
        XCTAssertEqual(after.rows.count, 39)
        XCTAssertFalse(after.rows.contains { $0.id == id("q3") })
        XCTAssertEqual(after.total, MailCount(value: 39, isAtLeast: false))
        XCTAssertEqual(after.appliedThrough, receipt.sequence, "the reading carries the command")
        XCTAssertEqual(receipt.count, 1)
        XCTAssertGreaterThan(receipt.sequence, 0, "no command is ever given 0")
        XCTAssertEqual(rows(source, MailScope(place: .mailbox(.done))).map(\.id), [id("q3")])
        withExtendedLifetime(observation) {}
    }

    func testDoneAlsoMarksReadAndLeavesNothingPendingInTheRowOrTheConversation() async throws {
        let source = MailFixtureSource()
        source.apply(.done, to: .conversations([id("q3")]))
        let gone = try await conversation(source, "q3")
        XCTAssertFalse(gone.inInbox)
        XCTAssertTrue(gone.messages.allSatisfy { !$0.isUnread }, "a conversation he has dealt with is read")
        let moved = try XCTUnwrap(rows(source, MailScope(place: .mailbox(.done))).first)
        XCTAssertFalse(moved.isUnread)
        XCTAssertFalse(moved.hasPendingChange, "this source is Gmail too, and takes a change at once")
    }

    func testStarAndReadMarkTheRowWhereItIs() throws {
        let source = MailFixtureSource()
        let before = rows(source).map(\.id)
        source.apply(.star(true), to: .conversations([id("receipt")]))
        source.apply(.read(true), to: .conversations([id("invite")]))
        XCTAssertEqual(rows(source).map(\.id), before, "marking moves nothing")
        XCTAssertEqual(row(source, "receipt")?.isStarred, true)
        XCTAssertEqual(row(source, "invite")?.isUnread, false)
        // Back to unread: the newest message is the one he has not read.
        source.apply(.read(false), to: .conversations([id("me-newest")]))
        XCTAssertEqual(row(source, "me-newest")?.isUnread, true)
    }

    func testAMessageTargetActsOnItsConversationAndAScopeTargetOnEveryRowInIt() {
        let source = MailFixtureSource()
        let byMessage = source.apply(.star(true), to: .message(MailMessageID(account: account, message: "q3~2")))
        XCTAssertEqual(byMessage.count, 1)

        let everything = source.apply(.read(true), to: .scope(inbox, from: nil))
        XCTAssertEqual(everything.count, 40)
        XCTAssertTrue(rows(source).allSatisfy { !$0.isUnread })
    }

    func testAChangeToAConversationThatIsNotHereChangesNothingAndSaysSo() {
        let source = MailFixtureSource()
        let receipt = source.apply(.done, to: .conversations([id("nope")]))
        XCTAssertEqual(receipt.count, 0)
        XCTAssertEqual(rows(source).count, 40)
    }

    // MARK: Undo

    func testUndoPutsBackExactlyWhatTheChangeChanged() async throws {
        let source = MailFixtureSource()
        let beforeRow = try XCTUnwrap(row(source, "q3"))
        let beforeConversation = try await conversation(source, "q3")
        let others = rows(source).filter { $0.id != id("q3") }

        let done = source.apply(.done, to: .conversations([id("q3")]))
        var heard: [MailListSnapshot] = []
        let observation = source.observeList(inbox, limit: 100) { heard.append($0) }
        let answer = source.undo(done)

        XCTAssertEqual(answer.count, 1)
        XCTAssertGreaterThan(answer.sequence, done.sequence, "an undo is a command too, and sequences only grow")
        XCTAssertEqual(heard.last?.rows.count, 40, "the observer heard it before undo returned")
        XCTAssertEqual(heard.last?.appliedThrough, answer.sequence)
        XCTAssertEqual(row(source, "q3"), beforeRow)
        let afterConversation = await source.conversation(id("q3"))
        XCTAssertEqual(afterConversation?.messages, beforeConversation.messages)
        XCTAssertEqual(afterConversation?.inInbox, true)
        XCTAssertEqual(rows(source).filter { $0.id != id("q3") }, others, "nothing else was touched")
        withExtendedLifetime(observation) {}
    }

    func testAnUndoIsOnlyEverTakenOnce() {
        let source = MailFixtureSource()
        let done = source.apply(.done, to: .conversations([id("q3")]))
        XCTAssertEqual(source.undo(done).count, 1)
        XCTAssertEqual(source.undo(done).count, 0, "nothing is left to undo: the screen says it can no longer be")
        XCTAssertEqual(source.undo(MailReceipt(sequence: 999, count: nil)).count, 0)
    }

    func testUndoOfAStarTouchesOnlyTheStar() {
        let source = MailFixtureSource()
        let star = source.apply(.star(true), to: .conversations([id("receipt")]))
        source.apply(.done, to: .conversations([id("q3")]))
        source.undo(star)
        XCTAssertEqual(row(source, "receipt")?.isStarred, false)
        XCTAssertNil(row(source, "q3"), "the Done after it stands")
    }

    // MARK: What observers hear

    func testAConversationObserverIsToldItsFirstReadingAndEachChange() {
        let source = MailFixtureSource()
        var heard: [MailConversation?] = []
        let observation = source.observeConversation(id("q3")) { heard.append($0) }
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard[0]?.messages.count, 3)
        source.apply(.star(false), to: .conversations([id("q3")]))
        XCTAssertEqual(heard.count, 2)
        XCTAssertEqual(heard[1]?.isStarred, false)
        var absent: [MailConversation?] = []
        let none = source.observeConversation(id("nope")) { absent.append($0) }
        XCTAssertEqual(absent.count, 1)
        XCTAssertNil(absent[0] ?? nil, "nil is a conversation this device does not hold")
        withExtendedLifetime((observation, none)) {}
    }

    func testAnObservationThatIsCancelledHearsNothingMore() {
        let source = MailFixtureSource()
        var heard = 0
        let observation = source.observeList(inbox, limit: 100) { _ in heard += 1 }
        observation.cancel()
        source.apply(.star(true), to: .conversations([id("q3")]))
        XCTAssertEqual(heard, 1)
    }

    func testTheCountsAndTheBadgeFollowUnreadMail() {
        let source = MailFixtureSource()
        var places: [MailPlaces] = []
        let observation = source.observePlaces { places.append($0) }
        let unread = rows(source).filter(\.isUnread).count
        XCTAssertEqual(places.last?.mailboxCounts[.inbox]?.unread.value, unread)
        XCTAssertEqual(places.last?.mailboxCounts[.inbox]?.total.value, 40)
        XCTAssertEqual(source.badges.value.unreadInFirstSplit, unread)

        source.apply(.done, to: .conversations([id("q3")]))   // unread, and now Done
        XCTAssertEqual(places.last?.mailboxCounts[.inbox]?.unread.value, unread - 1)
        XCTAssertEqual(places.last?.mailboxCounts[.inbox]?.total.value, 39)
        XCTAssertEqual(source.badges.value.unreadInFirstSplit, unread - 1)
        withExtendedLifetime(observation) {}
    }

    // MARK: The contract

    /// Every member this source declares is really its own: calling each through the protocol
    /// reaches no default in `MailSource+NotYet.swift`. (Swift accepts a member declared with a
    /// slightly wrong signature as a separate overload, and a screen would never reach it.)
    func testNoMemberThisSourceDeclaresIsAnsweredByAStub() async {
        let source: MailSource = MailFixtureSource()
        let reached = await MailSourceProbe.defaultsReached(by: source)
        let declared: Set<String> = [
            "activate()", "setVisible(_:)", "accounts", "observeAccounts(_:)", "observePlaces(_:)",
            "cachedFirstPage(_:)", "observeList(_:limit:_:)", "observeConversation(_:_:)",
            "conversation(_:)", "body(_:)", "status", "badges", "apply(_:to:)", "undo(_:)",
            // Drafts and sending (MailFixtureSource+Drafts.swift).
            "people(matching:limit:)", "draft(_:)", "newDraft(_:)", "save(_:)", "discard(_:) draft",
            "send(_:_:)", "cancelSend(_:)", "hasUnfinishedSends", "finishSends(within:)",
            // Who he can send as (MailFixtureSource+Schedule.swift).
            "changeIdentity(of:to:)",
        ]
        XCTAssertEqual(reached.intersection(declared), [])
        XCTAssertFalse(reached.isEmpty, "the members it has not built still say so")
    }
}
#endif
