import XCTest
import GRDB

/// Snooze end to end on the device, against a fake Gmail (MAIL-ENGINE 6.5, 8): shown at once,
/// durable, delivered as a hidden label made once, undone, and woken by the rules on fresh state.
final class MailSnoozeTests: XCTestCase {
    private static let account = "noor@plan.example"
    /// 2026-11-07 09:00 UTC.
    private static let nine = Date(timeIntervalSince1970: 1_794_042_000)
    private static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    /// Gmail, as far as snooze needs it: labels with names, `labels.create`, per-message `modify`.
    actor FakeGmail: GmailAPI {
        var messages: [String: Set<String>] = [:]
        var dates: [String: Int64] = [:]
        var labelList: [GmailLabel] = ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"].map {
            GmailLabel(id: $0, name: $0, type: "system")
        }
        var created: [GmailLabel] = [], modifies: [(String, [String], [String])] = []
        /// The create reaches Gmail and its answer is lost: the device sees a conflict on its retry.
        var loseCreateAnswer = false
        private var history: UInt64 = 100

        func put(_ id: String, _ labels: Set<String>, date: Int64) { messages[id] = labels; dates[id] = date }
        func addLabel(id: String, name: String) { labelList.append(GmailLabel(id: id, name: name, type: "user")) }
        func losingCreateAnswers() { loseCreateAnswer = true }
        func labelsOf(_ id: String) -> Set<String> { messages[id] ?? [] }
        func label(named name: String) -> GmailLabel? { labelList.first { $0.name == name } }

        func profile(token: String) async throws -> GmailProfile { GmailProfile(emailAddress: MailSnoozeTests.account, messagesTotal: messages.count, historyId: history) }
        func labels(token: String) async throws -> [GmailLabel] { labelList }
        func createLabel(token: String, name: String) async throws -> GmailLabel {
            if labelList.contains(where: { $0.name == name }) { throw GmailError.conflict }
            let label = GmailLabel(id: "Label_\(labelList.count)", name: name, type: "user",
                                   messageListVisibility: "hide", labelListVisibility: "labelHide")
            labelList.append(label); created.append(label)
            if loseCreateAnswer { loseCreateAnswer = false; throw GmailError.conflict }
            return label
        }
        func modify(token: String, id: String, add: [String], remove: [String]) async throws {
            precondition(!(add + remove).contains { $0.hasPrefix("name:") }, "a label is sent by id")
            guard messages[id] != nil else { throw GmailError.notFound }
            for label in add + remove where !["INBOX", "UNREAD"].contains(label) && !labelList.contains(where: { $0.id == label }) {
                throw GmailError.refused(.invalidArgument)
            }
            history += 1
            modifies.append((id, add, remove))
            messages[id]!.formUnion(add); messages[id]!.subtract(remove)
        }
        func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
            guard let labels = messages[id] else { throw GmailError.notFound }
            return GmailMessage(id: id, threadId: "t", labelIds: labels.sorted(), historyId: history, internalDate: dates[id])
        }
        func trash(token: String, id: String) async throws { try await modify(token: token, id: id, add: ["TRASH"], remove: []) }
        func untrash(token: String, id: String) async throws { try await modify(token: token, id: id, add: [], remove: ["TRASH"]) }
        func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> GmailIDPage { throw GmailError.malformed }
        func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage { throw GmailError.malformed }
        func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread { throw GmailError.malformed }
        func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody { throw GmailError.malformed }
    }

    private struct Harness {
        let stores: MailStores, intent: MailIntentStore, writer: MailWriter
        let coordinator: MailActionCoordinator, gmail: FakeGmail, delivery: GmailIntentDelivery
        let conversation = MailConversationID(account: MailSnoozeTests.account, thread: "t")

        /// What Gmail has now, read back into the index as the live source's confirmation does.
        func importFromGmail(_ ids: [String]) async throws {
            for id in ids {
                let value = try await gmail.message(token: "", id: id, format: .minimal)
                try await Self.importing(value, writer: writer, subject: true)
            }
        }
        static func importing(_ value: GmailMessage, writer: MailWriter, subject: Bool = false) async throws {
            var wire = value
            if subject { wire.payload = GmailPart(headers: [GmailHeader(name: "Subject", value: "Plans")]) }
            _ = try await writer.transact {
                try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: wire.historyId ?? 1, headers: MessageHeaders(payload: wire.payload),
                    structure: nil), account: MailSnoozeTests.account, myAddresses: [MailSnoozeTests.account], in: $0)
            }
        }
        func page(_ view: MailViewKey) async throws -> [IndexRow] {
            try await MailIndexReader(stores: stores).page(PageRequest(view: view, account: nil, filters: [], before: nil, limit: 50))
        }
        func deliverAll(at: Int64 = 10) async throws {
            for _ in 0..<20 {
                if try await delivery.deliverNext(account: MailSnoozeTests.account, at: at) == .idle { return }
            }
            XCTFail("delivery did not settle")
        }
    }

    /// One conversation, two messages in the inbox, the newer unread.
    private func harness(labels: [String: Set<String>] = ["m1": ["INBOX"], "m2": ["INBOX", "UNREAD"]]) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-snooze-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (stores, intent) = try await Task.detached {
            let directories = try MailDirectories(root: root)
            return (try MailStores.open(directories, migrations: MailSlices.migrations()), try MailIntentStore(directories: directories))
        }.value
        let writer = MailWriter(stores: stores, sink: nil)
        let coordinator = MailActionCoordinator(stores: stores, intent: intent, writer: writer)
        let gmail = FakeGmail()
        for (id, set) in labels.sorted(by: { $0.key < $1.key }) {
            await gmail.put(id, set, date: id == "m1" ? 1000 : 2000)
        }
        let delivery = GmailIntentDelivery(store: intent, api: gmail, token: { _ in "fixture" }, allowed: { _ in true }, accept: { account, value in
            try await Harness.importing(value, writer: writer)
        }, settled: { account, message, _, _ in
            try? await coordinator.refresh(account: account, messages: [message])
        }, relabeled: { account, name, id, messages in
            try? await coordinator.adopt(account: account, name: name, id: id, messages: messages)
        })
        let h = Harness(stores: stores, intent: intent, writer: writer, coordinator: coordinator, gmail: gmail, delivery: delivery)
        try await h.importFromGmail(labels.keys.sorted())
        return h
    }

    private func snooze(_ h: Harness, until: Date = nine, sequence: Int64 = 5) async throws -> MailActionCoordinator.Applied {
        try await h.coordinator.apply(.snooze(until: until, ifNoReply: false),
                                      to: [MailActionCoordinator.Target(id: h.conversation, asOf: 2000)], sequence: sequence, at: 1)
    }

    // MARK: Snooze and unsnooze through the outbox

    func testASnoozeShowsAtOnceThenReachesGmailAsOneHiddenLabel() async throws {
        let h = try await harness()
        let applied = try await snooze(h)
        XCTAssertEqual(applied.count, 1)
        XCTAssertNil(applied.projectionError)
        // Shown at once, before Gmail has heard of it: out of the inbox, in Snoozed, with its time.
        let inboxNow = try await h.page(.unified(.inbox))
        XCTAssertTrue(inboxNow.isEmpty)
        let snoozedNow = try await h.page(.snoozed)
        XCTAssertEqual(snoozedNow.map(\.thread), ["t"])
        XCTAssertEqual(snoozedNow.first?.wakeAt, Self.ms(Self.nine))
        let row = MailRowMapper.row(snoozedNow[0], labels: [], reason: nil, in: MailScope(place: .mailbox(.snoozed)))
        XCTAssertEqual(row.reason, .snoozed(until: Self.nine, ifNoReply: false))
        // Durable, by name until delivery has the label's id.
        let pending = try await h.intent.assertions()
        XCTAssertTrue(pending.contains { $0.assertion.labelRef == "name:Banana/Snoozed/20261107T0900Z" })

        try await h.deliverAll()
        let created = await h.gmail.created
        XCTAssertEqual(created.map(\.name), ["Banana/Snoozed/20261107T0900Z"], "made once, for both messages")
        let id = try XCTUnwrap(created.first?.id)
        for message in ["m1", "m2"] {
            let labels = await h.gmail.labelsOf(message)
            XCTAssertTrue(labels.contains(id), message)
            XCTAssertFalse(labels.contains("INBOX"), message)
        }
        let remaining = try await h.intent.assertions()
        XCTAssertTrue(remaining.isEmpty)
        // Gmail's own state, read back, keeps it in Snoozed; the stand-in label row is gone.
        let snoozed = try await h.page(.snoozed)
        XCTAssertEqual(snoozed.first?.wakeAt, Self.ms(Self.nine))
        let standIns = try await h.stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM label WHERE gmail_id LIKE 'name:%'") }
        XCTAssertEqual(standIns, 0)
    }

    func testAnExistingLabelIsUsedAndALostCreateAnswerIsFoundAgain() async throws {
        let h = try await harness()
        await h.gmail.addLabel(id: "Label_99", name: "Banana/Snoozed/20261107T0900Z")
        _ = try await snooze(h)
        try await h.deliverAll()
        var created = await h.gmail.created
        XCTAssertTrue(created.isEmpty, "the name was looked up before anything was made")
        let v1 = await h.gmail.labelsOf("m1").contains("Label_99")
        XCTAssertTrue(v1)

        let other = try await harness()
        await other.gmail.losingCreateAnswers()
        _ = try await snooze(other)
        try await other.deliverAll()
        created = await other.gmail.created
        XCTAssertEqual(created.count, 1, "a conflict reads the labels again; it never makes a second")
        let id = try XCTUnwrap(created.first?.id)
        let v2 = await other.gmail.labelsOf("m2").contains(id)
        XCTAssertTrue(v2)
    }

    func testUndoBeforeDeliveryNeverReachesGmailAndUnsnoozeAfterwardBringsItBack() async throws {
        let h = try await harness()
        let applied = try await snooze(h)
        let undone = try await h.coordinator.undo(applied, change: .snooze(until: Self.nine, ifNoReply: false), sequence: 6, at: 2)
        XCTAssertNil(undone.projectionError)
        let inbox = try await h.page(.unified(.inbox))
        XCTAssertEqual(inbox.map(\.thread), ["t"])
        let snoozed = try await h.page(.snoozed)
        XCTAssertTrue(snoozed.isEmpty)
        try await h.deliverAll()
        let made = await h.gmail.created
        XCTAssertTrue(made.isEmpty, "no label is made only to be taken off")
        let modifies = await h.gmail.modifies
        XCTAssertTrue(modifies.allSatisfy { $0.1.allSatisfy { !$0.hasPrefix("Label_") } }, "no snooze label was put on")
        let v3 = await h.gmail.labelsOf("m2").contains("INBOX")
        XCTAssertTrue(v3)

        // Snoozed and delivered, then unsnoozed: the label comes off by its id, INBOX goes back.
        let again = try await harness()
        _ = try await snooze(again)
        try await again.deliverAll()
        _ = try await again.coordinator.apply(.unsnooze, to: [MailActionCoordinator.Target(id: again.conversation, asOf: 2000)], sequence: 9, at: 3)
        let back = try await again.page(.unified(.inbox))
        XCTAssertEqual(back.map(\.thread), ["t"])
        try await again.deliverAll()
        let v4 = await again.gmail.created.first?.id
        let id = try XCTUnwrap(v4)
        for message in ["m1", "m2"] { let labels = await again.gmail.labelsOf(message); XCTAssertFalse(labels.contains(id), message) }
        let v5 = await again.gmail.labelsOf("m2").contains("INBOX")
        XCTAssertTrue(v5)
        let snoozedAfter = try await again.page(.snoozed)
        XCTAssertTrue(snoozedAfter.isEmpty)
    }

    // MARK: The rules on this device (the fallback; Banana Cloud wakes on time)

    /// A conversation another device snoozed: Gmail has the label by id, and the directory names it.
    private func snoozedElsewhere(_ messages: [String: Set<String>], name: String = "Banana/Snoozed/20261107T0900Z") async throws -> Harness {
        var labels = messages
        for key in labels.keys where labels[key]!.contains("S") { labels[key]!.remove("S"); labels[key]!.insert("Label_7") }
        let h = try await harness(labels: labels)
        await h.gmail.addLabel(id: "Label_7", name: name)
        let directory = await h.gmail.labelList
        _ = try await h.writer.transact { try MailLabelCatalog.replace(directory, account: Self.account, in: $0) }
        return h
    }

    func testAWakeIsDueOnlyAtItsTimeAndComesBackUnreadAtTheTopWithItsReason() async throws {
        let h = try await snoozedElsewhere(["m1": ["S"], "m2": ["S"]])
        // The directory named the label after the messages arrived: the conversation now reads as snoozed.
        let snoozed = try await h.page(.snoozed)
        XCTAssertEqual(snoozed.map(\.thread), ["t"])
        let early = try await h.coordinator.deriveRules(account: Self.account, now: Self.ms(Self.nine) - 1, sequence: 20, at: 1)
        XCTAssertEqual(early, 0)
        let woken = try await h.coordinator.deriveRules(account: Self.account, now: Self.ms(Self.nine), sequence: 21, at: 1)
        XCTAssertEqual(woken, 1)
        let inbox = try await h.page(.unified(.inbox))
        XCTAssertEqual(inbox.first?.thread, "t")
        XCTAssertEqual(inbox.first?.sortKey, Self.ms(Self.nine), "at the top, as of the time it was due")
        let row = MailRowMapper.row(inbox[0], labels: [], reason: nil, in: MailScope(place: .mailbox(.inbox)))
        XCTAssertEqual(row.reason, .backFromSnooze(due: Self.nine, wasIfNoReply: false))
        XCTAssertTrue(row.isUnread)
        try await h.deliverAll()
        let v6 = await h.gmail.label(named: "Banana/Returned")?.id
        let returned = try XCTUnwrap(v6)
        let v7 = await h.gmail.labelsOf("m2")
        XCTAssertEqual(v7, ["INBOX", "UNREAD", "Label_7", returned])
        let v8 = await h.gmail.labelsOf("m1")
        XCTAssertEqual(v8, ["Label_7", returned])
        // Woken in Gmail, read back: nothing more is due, now or later.
        let after = try await h.coordinator.deriveRules(account: Self.account, now: Self.ms(Self.nine) + 86_400_000, sequence: 22, at: 2)
        XCTAssertEqual(after, 0)
    }

    func testADoubleWakeIsOneChangeAtGmail() async throws {
        let h = try await snoozedElsewhere(["m1": ["S"]])
        for sequence in Int64(30)...32 {
            _ = try await h.coordinator.deriveRules(account: Self.account, now: Self.ms(Self.nine) + 1, sequence: sequence, at: 1)
        }
        // Each run discards what the last derived and derives it again: one group, one key per label.
        let pending = try await h.intent.assertions()
        XCTAssertEqual(Set(pending.map(\.groupSeq)).count, 1)
        XCTAssertEqual(pending.count, 3)
        XCTAssertTrue(pending.allSatisfy { $0.assertion.origin == .rule })
        // Another device (or Banana Cloud) woke it first: what is delivered changes nothing more.
        let returned = "Label_R"
        await h.gmail.addLabel(id: returned, name: "Banana/Returned")
        try await h.gmail.modify(token: "", id: "m1", add: ["INBOX", "UNREAD", returned], remove: [])
        let before = await h.gmail.modifies.count
        try await h.deliverAll()
        let v9 = await h.gmail.labelsOf("m1")
        XCTAssertEqual(v9, ["INBOX", "UNREAD", "Label_7", returned])
        let v10 = await h.gmail.modifies.count - before
        XCTAssertLessThanOrEqual(v10, 1)
    }

    func testAReplyDuringTheSnoozeEndsItAndNothingWakesLater() async throws {
        let h = try await snoozedElsewhere(["m1": ["S"], "m2": ["INBOX", "UNREAD"]])
        let snoozed = try await h.page(.snoozed)
        XCTAssertTrue(snoozed.isEmpty, "a conversation with a reply in the inbox is not away")
        let ended = try await h.coordinator.deriveRules(account: Self.account, now: Self.ms(Self.nine) - 3_600_000, sequence: 40, at: 1)
        XCTAssertEqual(ended, 1)
        try await h.deliverAll()
        let v11 = await h.gmail.labelsOf("m1")
        XCTAssertEqual(v11, [])
        let v12 = await h.gmail.labelsOf("m2")
        XCTAssertEqual(v12, ["INBOX", "UNREAD"])
        let later = try await h.coordinator.deriveRules(account: Self.account, now: Self.ms(Self.nine) + 1, sequence: 41, at: 2)
        XCTAssertEqual(later, 0)
    }

    func testAChangeOfHisStillUndeliveredIsNeverOverruledByARule() async throws {
        let h = try await snoozedElsewhere(["m1": ["S"]])
        _ = try await h.coordinator.apply(.star(true), to: [MailActionCoordinator.Target(id: h.conversation, asOf: 2000)], sequence: 50, at: 1)
        let derived = try await h.coordinator.deriveRules(account: Self.account, now: Self.ms(Self.nine) + 1, sequence: 51, at: 1)
        XCTAssertEqual(derived, 0)
    }
}
