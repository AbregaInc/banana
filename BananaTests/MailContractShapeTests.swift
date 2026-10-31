import XCTest

/// The few things in the contract file that are code rather than shape, and the defaults that
/// stand in for every member a source has not built.
///
/// The contract is almost all declarations, and those are tested by compiling. What is left is
/// small and each piece is relied on blind: the order of a list is whatever `MailOrderKey`
/// says it is; "Open in Gmail" opens whatever `gmailURL` builds; the badge drawn at launch is
/// whatever the mirror reads back, before any store is open to contradict it; a receipt kept
/// for undo must still be the receipt that comes back in an event; and an observation that
/// stops twice, or not at all, is a leak or a crash in a screen that did nothing wrong.
@MainActor
final class MailContractShapeTests: XCTestCase {

    /// The defaults report into one shared set and hand out two shared objects, so each test
    /// starts and ends with them clean: what one test reached is never counted against another.
    override func setUp() {
        super.setUp()
        MailNotYet.reset()
    }

    override func tearDown() {
        MailNotYet.reset()
        MailNotYet.onReach = nil
        super.tearDown()
    }

    // MARK: - Identity and order

    func testAListIsItsKeysInDescendingOrder() {
        let newest = MailOrderKey(group: 0, sortKey: 300, tie: 1)
        let older = MailOrderKey(group: 0, sortKey: 200, tie: 9)
        let olderLowerTie = MailOrderKey(group: 0, sortKey: 200, tie: 2)
        // Found only by Gmail: after everything this device found, however recent.
        let fromGmail = MailOrderKey(group: 1, sortKey: 900, tie: 5)
        let fromGmailOlder = MailOrderKey(group: 1, sortKey: 100, tie: 5)

        let shuffled = [fromGmailOlder, older, fromGmail, newest, olderLowerTie]
        XCTAssertEqual(shuffled.sorted(by: >),
                       [newest, older, olderLowerTie, fromGmail, fromGmailOlder])

        XCTAssertGreaterThan(newest, fromGmail, "group 0 comes before group 1")
        XCTAssertGreaterThan(newest, older, "a larger sort key comes first")
        XCTAssertGreaterThan(older, olderLowerTie, "the tie decides between equal sort keys")
    }

    func testAConversationsTextIsItsAccountAndThreadAndReadsBack() {
        let ids = [
            MailConversationID(account: "me@example.com", thread: "18c2f"),
            // Not yet sent: the thread is the draft's.
            MailConversationID(account: "me@example.com", thread: "local:4F2A-99"),
            // A bar is legal in an address. The thread never holds one, so the last bar is
            // the join.
            MailConversationID(account: "odd|name@example.com", thread: "18c2f"),
        ]
        XCTAssertEqual(ids[0].text, "me@example.com|18c2f")
        for id in ids {
            XCTAssertEqual(MailConversationID(text: id.text), id, id.text)
        }
    }

    func testTextThatIsNotAConversationReadsAsNothing() {
        for text in ["", "me@example.com", "me@example.com|", "|18c2f", "|"] {
            XCTAssertNil(MailConversationID(text: text), text)
        }
    }

    func testTheGmailAddressOfAConversation() throws {
        let id = MailConversationID(account: "me@example.com", thread: "18c2f")
        let url = try XCTUnwrap(id.gmailURL)
        XCTAssertEqual(url.absoluteString, "https://mail.google.com/mail/u/me@example.com/#all/18c2f")
        XCTAssertEqual(url.host, "mail.google.com")
        XCTAssertEqual(url.fragment, "all/18c2f")
    }

    func testTheGmailAddressEncodesWhatWouldEndThePath() throws {
        // An address may legally hold these. Unencoded, the first would end the path early and
        // the conversation would be lost from the address; the space would make no URL at all.
        let odd = MailConversationID(account: "a b#c?d@example.com", thread: "18c2f")
        let url = try XCTUnwrap(odd.gmailURL)
        XCTAssertEqual(url.absoluteString,
                       "https://mail.google.com/mail/u/a%20b%23c%3Fd@example.com/#all/18c2f")
        XCTAssertEqual(url.fragment, "all/18c2f")
        XCTAssertNil(url.query)
    }

    func testAConversationThatExistsOnlyHereHasNoGmailAddress() {
        let local = MailConversationID(account: "me@example.com", thread: "local:4F2A")
        XCTAssertNil(local.gmailURL)
    }

    // MARK: - Receipts

    func testAReceiptIsItsSequenceWhateverItsCount() {
        // A change to a whole scope returns before it has been counted. The receipt the screen
        // keeps for undo has no count; the one that comes back in the event has. They are one
        // receipt — equal, and the same dictionary key — or the bulk actions lose their undo.
        let kept = MailReceipt(sequence: 7, count: nil)
        let counted = MailReceipt(sequence: 7, count: 500)
        XCTAssertEqual(kept, counted)
        XCTAssertEqual(kept.hashValue, counted.hashValue)
        XCTAssertEqual(counted.count, 500, "the count is still carried")

        let undoable = [kept: "archive 500"]
        XCTAssertEqual(undoable[counted], "archive 500")
        XCTAssertEqual(MailEvent.applied(kept, count: 500), .applied(counted, count: 500))

        XCTAssertNotEqual(kept, MailReceipt(sequence: 8, count: nil))
    }

    func testARefusedChangeIsIdentifiedByItsReceipt() {
        let refused = MailRefusedChange(
            receipt: MailReceipt(sequence: 41, count: 3),
            change: .label(account: "me@example.com", add: ["L1"], remove: []),
            count: 3, failure: .labelMissing, account: "me@example.com")
        XCTAssertEqual(refused.id, 41)
    }

    // MARK: - What is kept across launches

    private func stored<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testTheStoredFormOfWhatIsKeptAcrossLaunches() throws {
        // These are written to disk — the scope and the open conversation in `ShellState`, a
        // change in the outbox — and read back by a later build. Their coding is the
        // compiler's, made from the names of cases and labels, so renaming one silently makes
        // every stored value unreadable. Each form is spelled out here so that a rename fails
        // a test instead, and is then a decision about the data already on his devices.
        let me = "me@example.com"
        XCTAssertEqual(try stored(MailConversationID(account: me, thread: "18c2f")),
                       #"{"account":"me@example.com","thread":"18c2f"}"#)
        XCTAssertEqual(try stored(MailMessageID(account: me, message: "m1")),
                       #"{"account":"me@example.com","message":"m1"}"#)
        XCTAssertEqual(try stored(MailDraftID(raw: "d1")), #"{"raw":"d1"}"#)
        XCTAssertEqual(try stored(MailOrderKey(group: 0, sortKey: 5, tie: 7)),
                       #"{"group":0,"sortKey":5,"tie":7}"#)

        let places: [(MailPlace, String)] = [
            (.split("important"), #"{"split":{"_0":"important"}}"#),
            (.mailbox(.inbox), #"{"mailbox":{"_0":"inbox"}}"#),
            (.label(account: me, id: "L1"), #"{"label":{"account":"me@example.com","id":"L1"}}"#),
            (.search("from:sam budget"), #"{"search":{"_0":"from:sam budget"}}"#),
            (.heldRemoval(account: me), #"{"heldRemoval":{"account":"me@example.com"}}"#),
        ]
        for (place, form) in places {
            XCTAssertEqual(try stored(place), form)
        }

        XCTAssertEqual(try stored(MailScope(place: .mailbox(.inbox))),
                       #"{"filters":[],"place":{"mailbox":{"_0":"inbox"}}}"#)
        let narrowed = MailScope(place: .label(account: me, id: "L1"), filters: [.unread], account: me)
        XCTAssertEqual(
            try stored(narrowed),
            #"{"account":"me@example.com","filters":["unread"],"#
                + #""place":{"label":{"account":"me@example.com","id":"L1"}}}"#)

        XCTAssertEqual(try stored(MailMailbox.allCases),
                       #"["inbox","starred","important","drafts","snoozed","sent","outbox","#
                        + #""done","all","spam","trash","muted"]"#)
        XCTAssertEqual(try stored([MailFilter.unread, .starred, .important, .noReply]),
                       #"["unread","starred","important","noReply"]"#)
        XCTAssertEqual(try stored(MailSyncLimit.allCases),
                       #"["oneMonth","threeMonths","sixMonths","oneYear","everything"]"#)
        XCTAssertEqual(MailSyncLimit.standard, .sixMonths)
        XCTAssertEqual(try stored([MailPictureGrant.sender, .domain, .everyone]),
                       #"["sender","domain","everyone"]"#)
        let pictureRules: [(MailPictureRule, String)] = [
            (.sender("sam@example.com"), #"{"sender":{"_0":"sam@example.com"}}"#),
            (.domain("example.com"), #"{"domain":{"_0":"example.com"}}"#),
            (.everyone, #"{"everyone":{}}"#),
        ]
        for (rule, form) in pictureRules {
            XCTAssertEqual(try stored(rule), form)
            XCTAssertEqual(try JSONDecoder().decode(MailPictureRule.self,
                from: JSONEncoder().encode(rule)), rule)
        }
        for state in [MailRemoteSearch.pending, .failed, .offline,
                      .done(added: 50, more: true), .done(added: 0, more: false)] {
            XCTAssertEqual(try JSONDecoder().decode(MailRemoteSearch.self,
                from: JSONEncoder().encode(state)), state)
        }

        let thursday = Date(timeIntervalSince1970: 1_800_000_000)
        let changes: [(MailChange, String)] = [
            (.done, #"{"done":{}}"#),
            (.notDone, #"{"notDone":{}}"#),
            (.trash, #"{"trash":{}}"#),
            (.restore, #"{"restore":{}}"#),
            (.spam, #"{"spam":{}}"#),
            (.notSpam, #"{"notSpam":{}}"#),
            (.read(true), #"{"read":{"_0":true}}"#),
            (.star(false), #"{"star":{"_0":false}}"#),
            (.important(true), #"{"important":{"_0":true}}"#),
            (.mute(true), #"{"mute":{"_0":true}}"#),
            (.label(account: me, add: ["L1"], remove: ["L2"]),
             #"{"label":{"account":"me@example.com","add":["L1"],"remove":["L2"]}}"#),
            (.move(account: me, to: "L1", from: nil),
             #"{"move":{"account":"me@example.com","to":"L1"}}"#),
            (.move(account: me, to: "L1", from: "L2"),
             #"{"move":{"account":"me@example.com","from":"L2","to":"L1"}}"#),
            (.snooze(until: thursday, ifNoReply: true),
             #"{"snooze":{"ifNoReply":true,"until":1800000000}}"#),
            (.unsnooze, #"{"unsnooze":{}}"#),
        ]
        for (change, form) in changes {
            XCTAssertEqual(try stored(change), form)
        }
    }

    func testAFirstPageOfRowsReadsBackAsItWasWritten() throws {
        // The first page of the last list shown is written to disk and drawn at the next
        // launch before any store is open. So the whole row family has to survive the trip,
        // including the line under a subject and the question that line may point at.
        let me = "me@example.com"
        let draft = MailDraftID(raw: "d1")
        let thursday = Date(timeIntervalSince1970: 1_800_000_000)
        let reasons: [MailRowReason?] = [
            nil,
            .asking(MailQuestion.ID(raw: "q1"), .sendUnconfirmed(draft, draftStillInGmail: nil)),
            .asking(MailQuestion.ID(raw: "q2"), .removalHeld(account: me, count: 4_000)),
            .failedToSend(.tooLarge), .changeRefused(.labelMissing), .held(until: thursday),
            .waitingToSend, .sending, .checkingSent,
            .scheduled(thursday, onThisDevice: true, isLate: false),
            .draft(firstLine: "Thanks, I will"),
            .backFromSnooze(due: thursday, wasIfNoReply: true),
            .snoozed(until: thursday, ifNoReply: false), .keptAfterRemoval,
        ]
        let rows = reasons.enumerated().map { index, reason in
            MailRow(id: MailConversationID(account: me, thread: "t\(index)"),
                    key: MailOrderKey(group: 0, sortKey: Int64(1_000 - index), tie: Int64(index)),
                    date: thursday,
                    people: [MailPerson(name: nil, address: "sam@example.com", isMe: false,
                                        isKnown: true, fromTheirMail: false)],
                    peopleTotal: 1, messageCount: 2, subject: "Q3 numbers", snippet: "Attached.",
                    isUnread: true, isStarred: false, isImportant: true, hasAttachment: true,
                    isInvitation: false, inInbox: true, isMuted: false, hasPendingChange: false,
                    fromGmailSearch: false,
                    labels: [MailLabelRef(id: "L1", name: "Invoices", colorHex: "#16a765")],
                    reason: reason, isOnDevice: index.isMultiple(of: 2))
        }
        let page = MailListSnapshot(
            scope: MailScope(place: .split(MailSplit.importantID), filters: [.unread], account: me),
            rows: rows, total: MailCount(value: 40, isAtLeast: true), hasMore: true,
            stillLoading: 2, isRebuilding: false, remote: .done(added: 3, more: true),
            coverage: MailCoverage(searched: 900, of: 1_200), appliedThrough: 41,
            heldSince: thursday)

        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(MailListSnapshot.self, from: data), page)
    }

    // MARK: - The badge mirror

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "MailContractShapeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTheBadgeMirrorReadsBackWhatWasWritten() throws {
        let defaults = try throwawayDefaults()
        XCTAssertNil(MailBadgeCounts.mirrored(in: defaults), "nothing written yet")

        MailBadgeCounts(unreadInFirstSplit: 12, needsAnswer: 2).mirror(to: defaults)
        XCTAssertEqual(MailBadgeCounts.mirrored(in: defaults),
                       MailBadgeCounts(unreadInFirstSplit: 12, needsAnswer: 2))

        MailBadgeCounts(unreadInFirstSplit: 0, needsAnswer: 0).mirror(to: defaults)
        XCTAssertEqual(MailBadgeCounts.mirrored(in: defaults),
                       MailBadgeCounts(unreadInFirstSplit: 0, needsAnswer: 0),
                       "zero is a count, not an absence")
    }

    func testTheBadgeMirrorIsTwoPlainIntegers() throws {
        // Read at launch before anything of mail's is loaded, so nothing of mail's is decoded.
        let defaults = try throwawayDefaults()
        MailBadgeCounts(unreadInFirstSplit: 12, needsAnswer: 2).mirror(to: defaults)
        XCTAssertEqual(defaults.array(forKey: MailBadgeCounts.mirrorKey) as? [Int], [12, 2])
    }

    func testAMalformedBadgeMirrorReadsAsNothing() throws {
        let defaults = try throwawayDefaults()
        let malformed: [Any] = ["12,2", [12], [12, 2, 7], ["12", "2"], [12, "2"], 12,
                                Data([1, 2]), ["unread": 12]]
        for value in malformed {
            defaults.set(value, forKey: MailBadgeCounts.mirrorKey)
            XCTAssertNil(MailBadgeCounts.mirrored(in: defaults), "\(value)")
        }
    }

    // MARK: - Observations

    func testLettingGoOfAnObservationStopsItOnce() {
        var stops = 0
        var observation: MailObservation? = MailObservation { stops += 1 }
        XCTAssertEqual(stops, 0)
        XCTAssertNotNil(observation)
        observation = nil
        XCTAssertEqual(stops, 1)
    }

    func testCancellingAnObservationStopsItOnceHoweverOftenItIsAsked() {
        var stops = 0
        var observation: MailObservation? = MailObservation { stops += 1 }
        observation?.cancel()
        XCTAssertEqual(stops, 1)
        observation?.cancel()
        XCTAssertEqual(stops, 1)
        // And letting go afterwards is not a second stop.
        observation = nil
        XCTAssertEqual(stops, 1)
    }

    func testAnObservationCancelledFromManyThreadsAtOnceStopsOnce() {
        // The engine hands observations between threads. Two cancels arriving together must
        // not both find the closure still there.
        for _ in 0..<200 {
            let stops = Counter()
            let observation = MailObservation { stops.add() }
            DispatchQueue.concurrentPerform(iterations: 8) { _ in observation.cancel() }
            XCTAssertEqual(stops.value, 1)
        }
    }

    /// A count that is safe to add to from any thread, so that the test above measures the
    /// observation and not its own counter.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: - Until it is built

    /// A source that has built nothing. That it compiles is the first assertion here: every
    /// requirement of `MailSource` has a default, or this line would not build.
    private final class NothingBuilt: MailSource {}

    /// A source that has built one member, the way every package does: by declaring it.
    private final class OneMemberBuilt: MailSource {
        var checks = 0
        func checkNow() { checks += 1 }
    }

    /// A source that meant to build a member and missed its signature by one parameter. Swift
    /// accepts this as a method of its own; it is not the protocol's `checkNow()`.
    private final class NearMiss: MailSource {
        var checks = 0
        func checkNow(force: Bool = false) { checks += 1 }
    }

    func testEveryDefaultAnswersQuietlyAndSaysItWasReached() async {
        let source: MailSource = NothingBuilt()
        let account = "me@example.com"
        let conversation = MailConversationID(account: account, thread: "18c2f")
        let message = MailMessageID(account: account, message: "m1")
        let attachment = MailAttachmentID(message: message, part: "2")
        let draftID = MailDraftID(raw: "d1")
        let inbox = MailScope(place: .mailbox(.inbox))
        let picture = URL(string: "https://example.com/logo.png")!
        let receipt = MailReceipt(sequence: 7, count: 1)
        var delivered = 0

        // Nothing happens.
        source.activate()
        source.setVisible(true)
        source.checkNow()
        XCTAssertEqual(source.syncLimit, .sixMonths)
        source.setSyncLimit(.everything)
        let beyond = await source.conversationsBeyond(.oneMonth)
        XCTAssertEqual(beyond, 0)
        source.askGmail(MailScope(place: .search("budget")))
        source.wants([conversation])
        source.fetchBody(message)
        source.fetchAttachment(attachment)
        source.showPictures(in: message, always: .sender)
        source.removePictureRule(.domain("example.com"))
        source.removeAttachment("a1", from: draftID)
        source.retry(receipt)
        source.discard(receipt)
        source.retrySend(draftID)
        source.answer(MailQuestion.ID(raw: "q1"), .keepHere)
        source.setWantsMail(true, account: account)
        source.forgetPermission(account: account)
        source.reconsiderKeptMail(account: account)
        await source.finishSends(within: 5)
        await source.removeDownloadedMail(account: nil)

        // Nothing is ever delivered, and the observation returned does nothing.
        let observations = [
            source.observeAccounts { _ in delivered += 1 },
            source.observePlaces { _ in delivered += 1 },
            source.observeList(inbox, limit: MailTuning.firstPageRows) { _ in delivered += 1 },
            source.observeConversation(conversation) { _ in delivered += 1 },
            source.observeEvents { _ in delivered += 1 },
        ]
        await Task.yield()
        observations.forEach { $0.cancel() }
        XCTAssertEqual(delivered, 0)

        // Empty lists.
        XCTAssertEqual(source.accounts, [])
        let suggestions = await source.suggestions(for: "sa")
        XCTAssertEqual(suggestions, [])
        let people = await source.people(matching: "sa", limit: 8)
        XCTAssertEqual(people, [])
        XCTAssertEqual(source.queryTokens("from:sam budget"), [])
        let domains = await source.pictureRules()
        XCTAssertEqual(domains, [])

        // No split is saved, and each is said not to be: an empty answer would mean "all saved".
        let splits = [MailSplit(id: "vip", name: "VIP", query: "from:sam"),
                      MailSplit(id: "bills", name: "Bills", query: "label:invoices")]
        XCTAssertEqual(source.saveSplits(splits), ["vip", "bills"])

        // Nothing here.
        XCTAssertNil(source.cachedFirstPage(inbox))
        let read = await source.conversation(conversation)
        XCTAssertNil(read)
        let found = await source.draft(draftID)
        XCTAssertNil(found)
        let ofMessage = await source.resource(picture, for: message, presentation: .onScreen)
        XCTAssertNil(ofMessage)
        let ofDraft = await source.resource(picture, forDraft: draftID, presentation: .onScreen)
        XCTAssertNil(ofDraft)
        let attached = await source.addAttachment(URL(fileURLWithPath: "/dev/null"), to: draftID)
        XCTAssertNil(attached)
        let rewritten = await source.rewriteAsText(draftID)
        XCTAssertNil(rewritten)
        let unquoted = await source.quoteAsText(in: draftID)
        XCTAssertNil(unquoted)
        let reidentified = await source.changeIdentity(of: draftID, to: "other@example.com")
        XCTAssertNil(reidentified)

        // The one safe answer each.
        let body = await source.body(message)
        XCTAssertEqual(body, .notOnDevice)
        let link = await source.decideLink(picture, in: message)
        XCTAssertEqual(link, .refuse)
        let cancelled = await source.cancelSend(draftID)
        XCTAssertFalse(cancelled)
        XCTAssertFalse(source.hasUnfinishedSends)
        let permission = await source.requestPermission(account: account)
        XCTAssertEqual(permission, .failed)
        let unsubscribed = await source.unsubscribe(conversation)
        XCTAssertEqual(unsubscribed, .unavailable)

        // Status and badges: one shared object each, saying nothing has been opened.
        XCTAssertTrue(source.status === NothingBuilt().status)
        XCTAssertTrue(source.badges === NothingBuilt().badges)
        XCTAssertEqual(source.status.value, MailStatusValue(
            isOnline: true, lastChecked: nil, unreachableSince: nil, slowedSince: nil, asked: nil,
            waitingChanges: 0, waitingSince: nil, waitingMessages: 0, refused: [], downloads: [],
            store: .notOpened, questions: []))
        XCTAssertEqual(source.badges.value, MailBadgeCounts(unreadInFirstSplit: 0, needsAnswer: 0))

        // Progress is new each time, at nothing; storage is nothing.
        XCTAssertEqual(source.attachmentProgress(attachment).fraction, 0)
        XCTAssertFalse(source.attachmentProgress(attachment) === source.attachmentProgress(attachment))
        let storage = await source.storageUsed()
        XCTAssertEqual(storage, MailStorage(bodies: 0, attachments: 0, search: 0, index: 0))

        // A change is the receipt of nothing — sequence 0, nothing counted — so no screen
        // shows a toast for it or offers to undo it.
        let nothings = [
            source.apply(.done, to: .conversations([conversation])),
            source.undo(receipt),
            source.discard(draftID),
            source.send(draftID, MailSendOptions(hold: nil, thenDone: false)),
        ]
        for nothing in nothings {
            XCTAssertEqual(nothing.sequence, 0)
            XCTAssertEqual(nothing.count, 0)
        }

        // A label he can use at once.
        XCTAssertEqual(source.createLabel(named: "Invoices", account: account),
                       MailLabelRef(id: "local:Invoices", name: "Invoices", colorHex: nil))

        // A draft that is only a value.
        let draft = await source.newDraft(.reply(to: message))
        XCTAssertEqual(draft.account, account)
        XCTAssertEqual(draft.conversation, MailConversationID(account: account,
                                                              thread: "local:" + draft.id.raw))
        XCTAssertEqual(draft.format, .banana)
        XCTAssertEqual(draft.body, MailText(blocks: []))
        XCTAssertTrue(draft.to.isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty)
        XCTAssertTrue(draft.subject.isEmpty && draft.attachments.isEmpty)
        XCTAssertNil(draft.signature)
        XCTAssertNil(draft.quote)
        XCTAssertNil(draft.schedule)
        XCTAssertNil(draft.delivery)
        XCTAssertEqual(draft.encodedBytes, 0)
        source.save(draft)
        let saved = await source.draft(draft.id)
        XCTAssertNil(saved, "it was saved nowhere")

        let another = await source.newDraft(.new(account: nil))
        XCTAssertEqual(another.account, "")
        XCTAssertNotEqual(another.id, draft.id)
        let chosen = await source.newDraft(.new(account: "work@example.com"))
        XCTAssertEqual(chosen.account, "work@example.com")
        let fromLink = await source.newDraft(.toAddress(["sam@example.com"], subject: "Hello"))
        XCTAssertEqual(fromLink.account, "")
        XCTAssertTrue(fromLink.to.isEmpty && fromLink.subject.isEmpty)

        // And every one of them said so, under the name the probe knows it by.
        XCTAssertEqual(MailNotYet.reachedNames, MailSourceProbe.everyMember)
    }

    func testTheProbeReachesEveryDefaultOfASourceThatHasBuiltNothing() async {
        // The same probe is run on the engine and on the in-memory source when they are
        // finished, expecting nothing. Here it is run where everything is a default, which
        // proves both halves of what that later test relies on: the probe calls every member,
        // and every default reports.
        let reached = await MailSourceProbe.defaultsReached(by: NothingBuilt())
        XCTAssertEqual(reached, MailSourceProbe.everyMember)
        XCTAssertEqual(MailSourceProbe.everyMember.count, 59)
    }

    func testAMemberASourceDeclaresIsItsOwnAndReachesNoDefault() async {
        let built = OneMemberBuilt()
        let source: MailSource = built

        source.checkNow()
        XCTAssertEqual(built.checks, 1)
        XCTAssertEqual(MailNotYet.reachedNames, [], "its own member ran, not the default")

        source.activate()
        XCTAssertEqual(MailNotYet.reachedNames, ["activate()"], "and what it has not built says so")

        let reached = await MailSourceProbe.defaultsReached(by: built)
        XCTAssertEqual(reached, MailSourceProbe.everyMember.subtracting(["checkNow()"]))
    }

    func testAMemberDeclaredWithANearMissSignatureIsStillADefaultAndTheProbeSaysSo() async {
        // The source's own tests call its own method and pass. Every screen holds a
        // `MailSource` and gets the default. Only asking through the protocol shows it.
        let missed = NearMiss()
        missed.checkNow(force: true)
        XCTAssertEqual(missed.checks, 1, "called as the source's own tests call it, it runs")

        let reached = await MailSourceProbe.defaultsReached(by: missed)
        XCTAssertTrue(reached.contains("checkNow()"), "through the protocol, the default does")
        XCTAssertEqual(missed.checks, 1)
    }

    func testAReachedDefaultIsAnnouncedToWhoeverAsked() {
        var announced: [String] = []
        MailNotYet.onReach = { announced.append($0) }
        let source: MailSource = NothingBuilt()

        source.checkNow()
        source.checkNow()
        XCTAssertEqual(announced, ["checkNow()", "checkNow()"], "each time, not once per name")

        // Resetting forgets what was reached; the hook is whoever set it's to clear.
        MailNotYet.reset()
        source.activate()
        XCTAssertEqual(announced.last, "activate()")
    }

    func testResetForgetsWhatWasReachedAndRestoresTheSharedObjects() {
        let source: MailSource = NothingBuilt()
        source.activate()
        source.status.value.isOnline = false
        source.badges.value.needsAnswer = 3

        MailNotYet.reset()

        XCTAssertEqual(MailNotYet.reachedNames, [])
        XCTAssertTrue(MailNotYet.status.value.isOnline)
        XCTAssertEqual(MailNotYet.status.value.store, .notOpened)
        XCTAssertEqual(MailNotYet.badges.value, MailBadgeCounts(unreadInFirstSplit: 0, needsAnswer: 0))
    }
}
