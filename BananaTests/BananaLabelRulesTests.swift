import XCTest

/// Banana's snooze labels (MAIL-ENGINE 8): the name, its time, and the three rules any device or
/// Banana Cloud may run. Every rule is a desired end state, so running one twice is one change.
final class BananaLabelRulesTests: XCTestCase {
    private let account = "noor@plan.example"
    /// 2026-11-07 09:00:00 UTC.
    private let nine = Date(timeIntervalSince1970: 1_794_042_000)
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func message(_ id: String, _ date: Int64, labels: Set<String>, banana: [String: String] = [:]) -> MessageFacts {
        MessageFacts(gmailID: id, internalDate: date, fetchState: 1, vis: 0, labels: labels.union(banana.values),
            labelsKnown: true, bananaLabels: banana.keys.sorted(), fromName: nil, fromAddress: "sender@plan.example",
            isFromMe: false, toAddresses: [], ccAddresses: [], subject: "Subject", snippet: "",
            hasAttachment: false, hasInvite: false, listID: nil, hasUndeliveredIntent: false, hasRefusedIntent: false,
            bananaLabelIDs: banana)
    }
    private func applying(_ assertions: [Assertion], to messages: [MessageFacts], names: [String: String]) -> [MessageFacts] {
        messages.map { message in
            var message = message
            for value in assertions where value.messageID == message.gmailID {
                if value.want { message.labels.insert(value.labelRef) } else { message.labels.remove(value.labelRef) }
            }
            message.bananaLabelIDs = Dictionary(uniqueKeysWithValues: message.labels.compactMap { id in names[id].map { ($0, id) } })
            message.bananaLabels = message.bananaLabelIDs.keys.sorted()
            return message
        }
    }

    // MARK: The name

    func testTheTimeIsRoundedUpToFiveMinutesInUTC() {
        XCTAssertEqual(BananaLabelRules.snoozedName(until: nine), "Banana/Snoozed/20261107T0900Z")
        XCTAssertEqual(BananaLabelRules.snoozedName(until: nine.addingTimeInterval(1)), "Banana/Snoozed/20261107T0905Z")
        XCTAssertEqual(BananaLabelRules.snoozedName(until: nine.addingTimeInterval(299)), "Banana/Snoozed/20261107T0905Z")
        XCTAssertEqual(BananaLabelRules.snoozedName(until: nine.addingTimeInterval(15 * 3600 - 1)), "Banana/Snoozed/20261108T0000Z")
        XCTAssertEqual(BananaLabelRules.rounded(nine.addingTimeInterval(61)), nine.addingTimeInterval(300))
    }

    func testANameIsReadBackAsItsTimeAndNothingElseIsASnooze() {
        XCTAssertEqual(BananaLabelRules.parse("Banana/Snoozed/20261107T0905Z"), .snoozed(nine.addingTimeInterval(300)))
        XCTAssertEqual(BananaLabelRules.parse(BananaLabelRules.snoozedName(until: nine)), .snoozed(nine))
        XCTAssertEqual(BananaLabelRules.parse("Banana/Returned"), .returned)
        XCTAssertEqual(BananaLabelRules.parse("Banana/Muted"), .muted)
        for bad in ["Banana/Snoozed/20260230T0900Z", "Banana/Snoozed/20261107T2400Z", "Banana/Snoozed/20261107T0960Z",
                    "Banana/Snoozed/20261107T0900", "Banana/Snoozed/2026110T0900Z", "Banana/Snoozed/20261107X0900Z",
                    "Banana/Snoozed/2026-1107T0900Z", "Banana/Snoozed/", "Snoozed/20261107T0900Z", "Label_9", "Banana/Other"] {
            XCTAssertNil(BananaLabelRules.parse(bad), bad)
        }
    }

    // MARK: State

    func testSeveralSnoozesMeanTheLatestAndTheBinIsNotCounted() {
        let early = BananaLabelRules.snoozedName(until: nine), late = BananaLabelRules.snoozedName(until: nine.addingTimeInterval(3600))
        let state = BananaLabelRules.state([
            message("a", 1, labels: [], banana: [early: "L1"]),
            message("b", 2, labels: [], banana: [late: "L2"]),
            message("c", 3, labels: ["TRASH"], banana: [BananaLabelRules.snoozedName(until: nine.addingTimeInterval(9000)): "L3"]),
        ])
        XCTAssertEqual(state.wakeAt, ms(nine) + 3_600_000)
        XCTAssertTrue(state.isSnoozed)
        XCTAssertFalse(state.isBack)
    }

    // MARK: Rule 1, wake

    func testAWakeIsDueAtItsTimeAndNotBefore() {
        let name = BananaLabelRules.snoozedName(until: nine)
        let thread = [message("a", 1, labels: [], banana: [name: "L1"]), message("b", 2, labels: [], banana: [name: "L1"])]
        XCTAssertTrue(BananaLabelRules.due(thread, account: account, ids: [:], now: ms(nine) - 1).isEmpty)
        let due = BananaLabelRules.due(thread, account: account, ids: ["Banana/Returned": "R"], now: ms(nine))
        // INBOX (and unread) on the last message, Returned with it in the same request, and on every
        // other message that carries the snooze: the INBOX message first.
        XCTAssertEqual(due.first?.messageID, "b")
        XCTAssertEqual(Set(due.filter { $0.messageID == "b" }.map(\.labelRef)), ["INBOX", "UNREAD", "R"])
        XCTAssertEqual(due.filter { $0.messageID == "a" }.map(\.labelRef), ["R"])
        XCTAssertTrue(due.allSatisfy { $0.want && $0.origin == .rule })
    }

    func testAWakeNamesReturnedUntilTheAccountHasItAndSkipsADraft() {
        let name = BananaLabelRules.snoozedName(until: nine)
        let thread = [message("a", 1, labels: [], banana: [name: "L1"]), message("draft", 5, labels: ["DRAFT"])]
        let due = BananaLabelRules.due(thread, account: account, ids: [:], now: ms(nine))
        XCTAssertEqual(Set(due.map(\.messageID)), ["a"], "a draft can take no label")
        XCTAssertTrue(due.contains { $0.labelRef == "name:Banana/Returned" })
    }

    func testAWakeTwiceIsOneChange() {
        let name = BananaLabelRules.snoozedName(until: nine)
        let names = ["L1": name, "R": BananaLabelRules.returned]
        var thread = [message("a", 1, labels: [], banana: [name: "L1"])]
        let first = BananaLabelRules.due(thread, account: account, ids: ["Banana/Returned": "R"], now: ms(nine) + 60_000)
        XCTAssertFalse(first.isEmpty)
        thread = applying(first, to: thread, names: names)
        // Woken: back, unread, still carrying its time; nothing more is due, now or later.
        XCTAssertTrue(BananaLabelRules.state(thread).isBack)
        XCTAssertEqual(BananaLabelRules.state(thread).returnedAt, ms(nine))
        XCTAssertTrue(BananaLabelRules.due(thread, account: account, ids: ["Banana/Returned": "R"], now: ms(nine) + 600_000).isEmpty)
    }

    // MARK: Rule 2, back early

    func testAReplyDuringTheSnoozeEndsIt() {
        let name = BananaLabelRules.snoozedName(until: nine)
        let thread = [message("a", 1, labels: [], banana: [name: "L1"]), message("reply", 2, labels: ["INBOX", "UNREAD"])]
        let due = BananaLabelRules.due(thread, account: account, ids: [:], now: ms(nine) - 3_600_000)
        XCTAssertEqual(due, [Assertion(account: account, messageID: "a", labelRef: "L1", want: false, origin: .rule)])
        // And at its time nothing wakes: it is already in the inbox.
        let after = applying(due, to: thread, names: ["L1": name])
        XCTAssertTrue(BananaLabelRules.due(after, account: account, ids: [:], now: ms(nine) + 1).isEmpty)
        XCTAssertNil(BananaLabelRules.state(after).wakeAt)
    }

    // MARK: Rule 5, left the inbox after coming back

    func testArchivedAfterComingBackLeavesNothingToFire() {
        let name = BananaLabelRules.snoozedName(until: nine)
        let thread = [message("a", 1, labels: [], banana: [name: "L1", BananaLabelRules.returned: "R"])]
        let due = BananaLabelRules.due(thread, account: account, ids: ["Banana/Returned": "R"], now: ms(nine) + 1)
        XCTAssertEqual(Set(due.map(\.labelRef)), ["L1", "R"])
        XCTAssertTrue(due.allSatisfy { !$0.want })
    }

    func testTheBinIsNeverWokenIntoTheInbox() {
        let name = BananaLabelRules.snoozedName(until: nine)
        let thread = [message("a", 1, labels: ["TRASH"], banana: [name: "L1"])]
        let due = BananaLabelRules.due(thread, account: account, ids: [:], now: ms(nine) + 1)
        XCTAssertEqual(due, [Assertion(account: account, messageID: "a", labelRef: "L1", want: false, origin: .rule)])
    }

    // MARK: The changes he makes

    func testSnoozeNamesTheLabelUntilGmailHasItThenUsesItsID() throws {
        let thread = [message("a", 1, labels: ["INBOX"]), message("b", 2, labels: ["INBOX", "UNREAD"])]
        let name = BananaLabelRules.snoozedName(until: nine)
        let named = try OutboxRules.assertions(for: .snooze(until: nine, ifNoReply: false), account: account, messages: thread, asOf: 2)
        XCTAssertEqual(Set(named.filter(\.want).map(\.labelRef)), ["name:" + name])
        XCTAssertEqual(Set(named.filter { !$0.want }.map(\.labelRef)), ["INBOX"])
        XCTAssertEqual(Set(named.map(\.messageID)), ["a", "b"])
        let byID = try OutboxRules.assertions(for: .snooze(until: nine, ifNoReply: false), account: account, messages: thread,
                                              asOf: 2, bananaLabelIDs: [name: "Label_7"])
        XCTAssertEqual(Set(byID.filter(\.want).map(\.labelRef)), ["Label_7"])
    }

    func testSnoozingAgainReplacesTheEarlierTimeAndAnyReturned() throws {
        let old = BananaLabelRules.snoozedName(until: nine)
        let thread = [message("a", 1, labels: ["INBOX"], banana: [old: "L1", BananaLabelRules.returned: "R"])]
        let later = nine.addingTimeInterval(86_400)
        let result = try OutboxRules.assertions(for: .snooze(until: later, ifNoReply: false), account: account, messages: thread, asOf: 1)
        XCTAssertEqual(Set(result.map { "\($0.labelRef):\($0.want)" }),
                       ["name:\(BananaLabelRules.snoozedName(until: later)):true", "INBOX:false", "L1:false", "R:false"])
    }

    func testUnsnoozeAndEveryWayOutOfTheInboxEndTheSnooze() throws {
        let name = BananaLabelRules.snoozedName(until: nine)
        let thread = [message("a", 1, labels: [], banana: [name: "L1"]), message("b", 2, labels: [], banana: [name: "L1"])]
        let unsnooze = try OutboxRules.assertions(for: .unsnooze, account: account, messages: thread, asOf: 2)
        XCTAssertEqual(Set(unsnooze.map { "\($0.messageID) \($0.labelRef):\($0.want)" }),
                       ["a L1:false", "b L1:false", "b INBOX:true"])
        for change in [MailChange.done, .trash, .spam, .move(account: account, to: "Label_1", from: nil)] {
            let result = try OutboxRules.assertions(for: change, account: account, messages: thread, asOf: 2)
            XCTAssertEqual(Set(result.filter { $0.labelRef == "L1" }.map(\.messageID)), ["a", "b"], "\(change)")
            XCTAssertTrue(result.filter { $0.labelRef == "L1" }.allSatisfy { !$0.want })
        }
        // Marking read touches nothing of the snooze.
        let read = try OutboxRules.assertions(for: .read(true), account: account, messages: thread, asOf: 2)
        XCTAssertFalse(read.contains { $0.labelRef == "L1" })
    }

    // MARK: Where it shows

    func testSnoozedIsListedSoonestFirstAndBackFromSnoozeSortsAtItsTime() {
        let soon = BananaLabelRules.snoozedName(until: nine), later = BananaLabelRules.snoozedName(until: nine.addingTimeInterval(3600))
        func key(_ banana: [String: String], labels: Set<String> = []) -> ViewMembership? {
            ViewMembershipRules.memberships([message("a", 1000, labels: labels, banana: banana)], account: account,
                splits: [], matches: { _, _ in false }, myAddresses: [account]).first { $0.view == .snoozed }
        }
        let a = key([soon: "L1"]), b = key([later: "L2"])
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertGreaterThan(a!.sortKey, b!.sortKey, "the list is read largest key first")
        XCTAssertGreaterThan(b!.sortKey, 0)
        XCTAssertNil(key([soon: "L1"], labels: ["INBOX"]), "back in the inbox is not snoozed")
        let back = ViewMembershipRules.memberships([message("a", 1000, labels: ["INBOX"], banana: [soon: "L1", BananaLabelRules.returned: "R"])],
            account: account, splits: [], matches: { _, _ in false }, myAddresses: [account])
        XCTAssertEqual(back.first { $0.view == .unified(.inbox) }?.sortKey, ms(nine), "at the time it was due, not its date")
    }
}
