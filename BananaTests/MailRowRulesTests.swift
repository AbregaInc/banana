import XCTest

/// What a change does to a row, cell by cell.
///
/// `MailRowRules` is the reason a row moves in the same turn as the key press: the list edits
/// its own rows through it before the store has committed anything. So a wrong cell here is a
/// row that vanishes and comes back, or one that stays under his cursor after he has dealt
/// with it — for the few milliseconds until the store's reading corrects it, every time.
///
/// The membership table is written out below as a grid, one line per change and one character
/// per place, in the shape of the table in MAIL-ENGINE 13.2. It is deliberately a second
/// spelling of that table rather than a call into the rule's own notion of "kinds of place":
/// the two are compared, and a slip in either shows.
final class MailRowRulesTests: XCTestCase {

    // MARK: - Fixtures

    private static let account = "me@example.com"
    private static let invoices = MailLabelRef(id: "L1", name: "Invoices", colorHex: "#16a765")
    private static let hiring = MailLabelRef(id: "L2", name: "Hiring", colorHex: nil)
    private static let thursday = Date(timeIntervalSince1970: 1_800_000_000)

    /// An unread conversation in the inbox carrying both labels, with nothing pending.
    private func row(account: String = MailRowRulesTests.account,
                     inInbox: Bool = true,
                     isUnread: Bool = true,
                     isStarred: Bool = false,
                     isImportant: Bool = false,
                     isMuted: Bool = false,
                     reason: MailRowReason? = nil) -> MailRow {
        MailRow(id: MailConversationID(account: account, thread: "18c2f"),
                key: MailOrderKey(group: 0, sortKey: 1_700_000_000_000, tie: 7),
                date: Date(timeIntervalSince1970: 1_700_000_000),
                people: [MailPerson(name: "Sam Lee", address: "sam@example.com", isMe: false,
                                    isKnown: true, fromTheirMail: false)],
                peopleTotal: 1,
                messageCount: 3,
                subject: "Q3 numbers before Thursday",
                snippet: "Attached, with the two changes we talked about.",
                isUnread: isUnread, isStarred: isStarred, isImportant: isImportant,
                hasAttachment: true, isInvitation: false, inInbox: inInbox, isMuted: isMuted,
                hasPendingChange: false,
                fromGmailSearch: false,
                labels: [Self.invoices, Self.hiring],
                reason: reason)
    }

    private func scope(_ place: MailPlace, _ filters: Set<MailFilter> = []) -> MailScope {
        MailScope(place: place, filters: filters)
    }

    private func label(add: [String] = [], remove: [String] = []) -> MailChange {
        .label(account: Self.account, add: add, remove: remove)
    }

    private func move(to: String = "L9", from: String?) -> MailChange {
        .move(account: Self.account, to: to, from: from)
    }

    /// The row an outcome carries. Every outcome carries one.
    private func carried(_ outcome: MailRowRules.Outcome) -> MailRow {
        switch outcome {
        case .stays(let row), .leaves(let row), .unknown(let row): return row
        }
    }

    /// The row as changed. The same in every place, so it is read in All Mail.
    private func changed(_ row: MailRow, by change: MailChange) -> MailRow {
        carried(MailRowRules.apply(change, to: row, in: scope(.mailbox(.all))))
    }

    // MARK: - The row as changed

    func testDoneLeavesTheInboxAndMarksRead() {
        var expected = row()
        expected.inInbox = false
        expected.isUnread = false
        expected.hasPendingChange = true
        XCTAssertEqual(changed(row(), by: .done), expected)
    }

    func testNotDoneNotSpamAndUnsnoozePutItBackInTheInbox() {
        var expected = row()
        expected.hasPendingChange = true
        for change in [MailChange.notDone, .notSpam, .unsnooze] {
            XCTAssertEqual(changed(row(inInbox: false), by: change), expected, "\(change)")
        }
    }

    func testDoneEndsASnoozeAndClearsNoOtherLine() {
        // The table says Done leaves Snoozed; the row says so too, as unsnooze's does.
        let snoozed = row(inInbox: false, reason: .snoozed(until: Self.thursday, ifNoReply: true))
        XCTAssertNil(changed(snoozed, by: .done).reason)
        XCTAssertEqual(changed(snoozed, by: .done).inInbox, false)

        // A draft's line, a question and a refusal are about something else.
        let withDraft = row(inInbox: false, reason: .draft(firstLine: "Thanks, I will"))
        XCTAssertEqual(changed(withDraft, by: .done).reason, .draft(firstLine: "Thanks, I will"))
        let refused = row(reason: .changeRefused(.labelMissing))
        XCTAssertEqual(changed(refused, by: .done).reason, .changeRefused(.labelMissing))
    }

    func testUnsnoozeClearsASnoozedLineAndNoOther() {
        let snoozed = row(inInbox: false, reason: .snoozed(until: Self.thursday, ifNoReply: true))
        XCTAssertNil(changed(snoozed, by: .unsnooze).reason)

        // A draft's line is about something else, and outranks a snooze; it is not unsnooze's
        // to remove.
        let withDraft = row(inInbox: false, reason: .draft(firstLine: "Thanks, I will"))
        XCTAssertEqual(changed(withDraft, by: .unsnooze).reason, .draft(firstLine: "Thanks, I will"))

        // Nor does putting a conversation back in the inbox by another route end its snooze.
        XCTAssertEqual(changed(snoozed, by: .notDone).reason,
                       .snoozed(until: Self.thursday, ifNoReply: true))
    }

    func testTrashAndSpamLeaveTheInboxAndChangeNothingElse() {
        var expected = row()
        expected.inInbox = false
        expected.hasPendingChange = true
        XCTAssertEqual(MailRowRules.apply(.trash, to: row(), in: scope(.mailbox(.trash))),
                       .stays(expected))
        XCTAssertEqual(MailRowRules.apply(.spam, to: row(), in: scope(.mailbox(.spam))),
                       .stays(expected))
    }

    func testMoveLeavesTheInboxAndDropsTheLabelItCameFrom() {
        var expected = row()
        expected.inInbox = false
        expected.labels = [Self.hiring]
        expected.hasPendingChange = true
        XCTAssertEqual(changed(row(), by: move(from: "L1")), expected)

        // Moved from the inbox rather than from a label: no label is dropped, and the one it
        // went to is not drawn yet — the rule has its id and nothing to draw it with.
        expected.labels = [Self.invoices, Self.hiring]
        XCTAssertEqual(changed(row(), by: move(from: nil)), expected)
    }

    func testRestoreChangesNothingButThatSomethingIsPending() {
        var expected = row(inInbox: false)
        expected.hasPendingChange = true
        XCTAssertEqual(changed(row(inInbox: false), by: .restore), expected)
    }

    func testReadStarAndImportantSetTheirOwnFlagAndNoOther() {
        var expected = row()
        expected.hasPendingChange = true

        expected.isUnread = false
        XCTAssertEqual(changed(row(), by: .read(true)), expected)
        XCTAssertEqual(changed(row(isUnread: false), by: .read(false)).isUnread, true)

        expected = row()
        expected.hasPendingChange = true
        expected.isStarred = true
        XCTAssertEqual(changed(row(), by: .star(true)), expected)
        XCTAssertEqual(changed(row(isStarred: true), by: .star(false)).isStarred, false)

        expected = row()
        expected.hasPendingChange = true
        expected.isImportant = true
        XCTAssertEqual(changed(row(), by: .important(true)), expected)
        XCTAssertEqual(changed(row(isImportant: true), by: .important(false)).isImportant, false)
    }

    func testMutingLeavesTheInboxAndUnmutingDoesNotReturnToIt() {
        var expected = row()
        expected.isMuted = true
        expected.inInbox = false
        expected.hasPendingChange = true
        XCTAssertEqual(changed(row(), by: .mute(true)), expected)

        // Unmuting says only that later replies will show; where this one is, is unchanged.
        expected = row(inInbox: false)
        expected.hasPendingChange = true
        XCTAssertEqual(changed(row(inInbox: false, isMuted: true), by: .mute(false)), expected)
    }

    func testSnoozeLeavesTheInboxAndSaysUntilWhen() {
        let snooze = MailChange.snooze(until: Self.thursday, ifNoReply: true)
        var expected = row()
        expected.inInbox = false
        expected.reason = .snoozed(until: Self.thursday, ifNoReply: true)
        expected.hasPendingChange = true
        XCTAssertEqual(changed(row(), by: snooze), expected)

        // Snoozed again: the earlier snooze, and "back from snooze", are both replaced.
        let earlier = Date(timeIntervalSince1970: 1_750_000_000)
        for replaced in [MailRowReason.snoozed(until: earlier, ifNoReply: false),
                         .backFromSnooze(due: earlier, wasIfNoReply: false),
                         .keptAfterRemoval] {
            XCTAssertEqual(changed(row(reason: replaced), by: snooze).reason,
                           .snoozed(until: Self.thursday, ifNoReply: true), "\(replaced)")
        }
    }

    func testSnoozeDoesNotReplaceALineThatOutranksIt() {
        // A row draws one line, the highest-ranking one. A question, a send and a draft all
        // outrank a snooze, so the snooze shows only as the row leaving the inbox.
        let snooze = MailChange.snooze(until: Self.thursday, ifNoReply: false)
        let draft = MailDraftID(raw: "d1")
        let outranking: [MailRowReason] = [
            .asking(MailQuestion.ID(raw: "q1"), .sendUnconfirmed(draft, draftStillInGmail: nil)),
            .failedToSend(.addressRejected),
            .changeRefused(.labelMissing),
            .held(until: Self.thursday),
            .waitingToSend, .sending, .checkingSent,
            .scheduled(Self.thursday, onThisDevice: true, isLate: false),
            .draft(firstLine: "Thanks, I will"),
        ]
        for reason in outranking {
            let after = changed(row(reason: reason), by: snooze)
            XCTAssertEqual(after.reason, reason, "\(reason)")
            XCTAssertFalse(after.inInbox, "\(reason)")
        }
    }

    func testLabelDropsWhatWasRemovedAndDoesNotDrawWhatWasAdded() {
        var expected = row()
        expected.labels = [Self.hiring]
        expected.hasPendingChange = true
        XCTAssertEqual(changed(row(), by: label(add: ["L9"], remove: ["L1", "L404"])), expected)
    }

    func testEveryChangeMarksTheRowPending() {
        for change in Self.grid.map(\.change) {
            XCTAssertTrue(changed(row(), by: change).hasPendingChange, "\(change)")
        }
    }

    func testEveryOutcomeCarriesTheSameChangedRow() {
        var expected = row()
        expected.inInbox = false
        expected.isUnread = false
        expected.hasPendingChange = true
        XCTAssertEqual(MailRowRules.apply(.done, to: row(), in: scope(.mailbox(.inbox))),
                       .leaves(expected))
        XCTAssertEqual(MailRowRules.apply(.done, to: row(), in: scope(.mailbox(.all))),
                       .stays(expected))
        // In a search, where it belongs is not known — but that it is done is, and it shows
        // at once: the row is drawn without its inbox mark while the reading decides.
        XCTAssertEqual(MailRowRules.apply(.done, to: row(), in: scope(.search("budget"))),
                       .unknown(expected))
    }

    // MARK: - A label's id is one account's

    func testALabelChangeForAnotherAccountLeavesTheRowUntouched() {
        // Gmail numbers labels per mailbox: "L1" in the other account is some other label. A
        // change that names that account is not about this row, which is neither changed nor
        // pending — wherever it is being looked at.
        let other = "work@example.com"
        let mine = row()
        let changes: [MailChange] = [
            .label(account: other, add: ["L9"], remove: ["L1"]),
            .move(account: other, to: "L9", from: "L1"),
        ]
        let places: [MailPlace] = [.mailbox(.inbox), .split("vip"), .mailbox(.all),
                                   .label(account: Self.account, id: "L1"), .search("budget"),
                                   .mailbox(.drafts)]
        for change in changes {
            for place in places {
                XCTAssertEqual(MailRowRules.apply(change, to: mine, in: scope(place, [.unread])),
                               .stays(mine), "\(change) in \(place)")
            }
        }

        // And the same change does apply to a row of the account it names.
        let theirs = row(account: other)
        guard case .leaves(let moved) = MailRowRules.apply(changes[1], to: theirs,
                                                           in: scope(.mailbox(.inbox)))
        else { return XCTFail("a move leaves the inbox for its own account's row") }
        XCTAssertEqual(moved.labels, [Self.hiring])
        XCTAssertTrue(moved.hasPendingChange)
    }

    // MARK: - Whether it still belongs

    /// The places, in the order of the grid's columns: one of every kind a list can be, every
    /// mailbox there is, and each of the built-in splits beside a custom one.
    private static let places: [MailPlace] = [
        // inbox
        .split(MailSplit.importantID), .split(MailSplit.otherID), .split(MailSplit.calendarID),
        .split("vip"), .mailbox(.inbox),
        // done
        .mailbox(.done),
        // label-like
        .mailbox(.all), .mailbox(.sent), .mailbox(.starred), .mailbox(.important),
        .mailbox(.muted), .label(account: account, id: "L1"),
        // bin
        .mailbox(.trash), .mailbox(.spam),
        // snoozed
        .mailbox(.snoozed),
        // search
        .search("budget"),
        // composed
        .mailbox(.drafts), .mailbox(.outbox), .heldRemoval(account: account),
    ]

    private static func label(add: [String], remove: [String]) -> MailChange {
        .label(account: account, add: add, remove: remove)
    }

    private static func move(from: String?) -> MailChange {
        .move(account: account, to: "L9", from: from)
    }

    /// S stays, L leaves, ? unknown. Spaces only separate the kinds of place.
    ///
    ///     Important, Other, Calendar, a custom split, the whole inbox
    ///     |     done
    ///     |     | All Mail, Sent, Starred, Important, Muted, the label L1
    ///     |     | |      Trash, Spam
    ///     |     | |      |  Snoozed
    ///     |     | |      |  | a search
    ///     |     | |      |  | | Drafts, Outbox, a held removal
    private static let grid: [(change: MailChange, cells: String)] = [
        (.done,                                         "LLLLL S SSSSSS SS L ? ???"),
        (.notDone,                                      "SSS?S L SSSSSS SS ? ? ???"),
        (.trash,                                        "LLLLL L LLLLLL SL L L ???"),
        (.spam,                                         "LLLLL L LLLLLL LS L L ???"),
        (.restore,                                      "SSS?S S SSSSSS LS S ? ???"),
        (.notSpam,                                      "SSS?S S SSSSSS SL S ? ???"),
        (.read(true),                                   "SSS?S S SSSSSS SS S S ???"),
        (.read(false),                                  "SSS?S S SSSSSS SS S S ???"),
        (.star(true),                                   "SSS?S S SSSSSS SS S S ???"),
        (.star(false),                                  "SSS?S S SSLSSS SS S S ???"),
        // Important is "marked important" and Other is the rest, so marking moves a
        // conversation between them; Calendar holds invitations whatever their marking.
        (.important(true),                              "SLS?S S SSSSSS SS S S ???"),
        (.important(false),                             "LSS?S S SSSLSS SS S S ???"),
        (.mute(true),                                   "LLLLL S SSSSSS SS S ? ???"),
        (.mute(false),                                  "SSS?S S SSSSLS SS S ? ???"),
        (.snooze(until: thursday, ifNoReply: false),    "LLLLL S SSSSSS SS S ? ???"),
        (.unsnooze,                                     "SSS?S L SSSSSS SS L ? ???"),
        (label(add: ["L9"], remove: []),                "SSS?S S SSSSSS SS S ? ???"),
        (label(add: [], remove: ["L2"]),                "SSS?S S SSSSSS SS S ? ???"),
        (label(add: ["L9"], remove: ["L2", "L1"]),      "SSS?S S SSSSSL SS S ? ???"),
        (move(from: nil),                               "LLLLL S SSSSSS SS L ? ???"),
        (move(from: "L2"),                              "LLLLL S SSSSSS SS L ? ???"),
        (move(from: "L1"),                              "LLLLL S SSSSSL SS L ? ???"),
    ]

    /// The name of a change's case. Exhaustive on purpose, with no `default`: a case added to
    /// `MailChange` does not compile here until it has a name, and then fails the test below
    /// until it has a line in the grid.
    private static func name(of change: MailChange) -> String {
        switch change {
        case .done: return "done"
        case .notDone: return "notDone"
        case .trash: return "trash"
        case .restore: return "restore"
        case .spam: return "spam"
        case .notSpam: return "notSpam"
        case .read: return "read"
        case .star: return "star"
        case .important: return "important"
        case .mute: return "mute"
        case .label: return "label"
        case .move: return "move"
        case .snooze: return "snooze"
        case .unsnooze: return "unsnooze"
        }
    }

    func testTheGridCoversEveryMailboxEverySplitAndEveryKindOfChange() {
        // A mailbox added to the contract must be given a column, not left to a default.
        let mailboxes = Self.places.compactMap { place -> MailMailbox? in
            if case .mailbox(let mailbox) = place { return mailbox }
            return nil
        }
        XCTAssertEqual(Set(mailboxes), Set(MailMailbox.allCases))
        XCTAssertEqual(mailboxes.count, MailMailbox.allCases.count)

        for (change, cells) in Self.grid {
            XCTAssertEqual(cells.filter { $0 != " " }.count, Self.places.count, "\(change)")
        }

        XCTAssertEqual(Set(Self.grid.map { Self.name(of: $0.change) }),
                       ["done", "notDone", "trash", "restore", "spam", "notSpam", "read", "star",
                        "important", "mute", "label", "move", "snooze", "unsnooze"])
    }

    func testEveryCellOfTheMembershipTable() {
        for (change, cells) in Self.grid {
            for (place, cell) in zip(Self.places, cells.filter { $0 != " " }) {
                let outcome = MailRowRules.apply(change, to: row(), in: scope(place))
                let answered: Character
                switch outcome {
                case .stays: answered = "S"
                case .leaves: answered = "L"
                case .unknown: answered = "?"
                }
                XCTAssertEqual(answered, cell, "\(change) in \(place)")
            }
        }
    }

    func testACustomSplitIsSureOnlyOfWhatLeavesTheInbox() {
        // Its query may test flags and labels, and the rule does not have it. So a marking is
        // drawn at once and placed by the next reading; only leaving the inbox is certain.
        let vip = scope(.split("vip"))
        var starred = row()
        starred.isStarred = true
        starred.hasPendingChange = true
        XCTAssertEqual(MailRowRules.apply(.star(true), to: row(), in: vip), .unknown(starred))

        guard case .leaves = MailRowRules.apply(.done, to: row(), in: vip)
        else { return XCTFail("done leaves the inbox, so it leaves every split") }
    }

    func testAPlaceNarrowedToOneAccountAnswersAsThePlaceDoes() {
        var narrowed = scope(.mailbox(.inbox))
        narrowed.account = Self.account
        XCTAssertEqual(MailRowRules.apply(.done, to: row(), in: narrowed),
                       MailRowRules.apply(.done, to: row(), in: scope(.mailbox(.inbox))))
    }

    // MARK: - Filters

    func testARowThatNowFailsAFilterLeaves() {
        let inbox = MailPlace.mailbox(.inbox)

        guard case .leaves(let read) = MailRowRules.apply(.read(true), to: row(),
                                                          in: scope(inbox, [.unread]))
        else { return XCTFail("reading under Unread should leave") }
        XCTAssertFalse(read.isUnread)

        guard case .leaves = MailRowRules.apply(.star(false), to: row(isStarred: true),
                                                in: scope(inbox, [.starred]))
        else { return XCTFail("unstarring under Starred should leave") }

        guard case .leaves = MailRowRules.apply(.important(false), to: row(isImportant: true),
                                                in: scope(inbox, [.important]))
        else { return XCTFail("unmarking under Important should leave") }
    }

    func testDoneLeavesAnUnreadFilterBecauseDoneMarksRead() {
        // All Mail keeps a conversation that is done. All Mail showing only unread does not:
        // done marked it read.
        let unreadOnly = scope(.mailbox(.all), [.unread])
        guard case .leaves = MailRowRules.apply(.done, to: row(), in: unreadOnly)
        else { return XCTFail("done under Unread should leave") }
    }

    func testARowThatStillPassesItsFiltersStays() {
        let inbox = MailPlace.mailbox(.inbox)
        let all: Set<MailFilter> = [.unread, .starred, .important]
        let matching = row(isStarred: true, isImportant: true)

        guard case .stays = MailRowRules.apply(.read(false), to: matching, in: scope(inbox, all))
        else { return XCTFail("marking unread under Unread should stay") }
        guard case .stays = MailRowRules.apply(.star(true), to: matching, in: scope(inbox, all))
        else { return XCTFail("starring under Starred should stay") }
        guard case .stays = MailRowRules.apply(label(add: ["L9"]), to: matching,
                                               in: scope(inbox, all))
        else { return XCTFail("a change no filter is about should stay") }
    }

    func testAFilterNeverKeepsARowThatHasLeft() {
        // Marked unread and done at once would pass an Unread filter; it has still left the
        // inbox. A filter takes rows away and never brings one back.
        let unreadInbox = scope(.mailbox(.inbox), [.unread])
        guard case .leaves = MailRowRules.apply(.snooze(until: Self.thursday, ifNoReply: false),
                                                to: row(), in: unreadInbox)
        else { return XCTFail("a snoozed row leaves the inbox though it is still unread") }
    }

    func testARowThatFailsAFilterLeavesEvenWhereItsPlaceIsUnknown() {
        // Whether a done conversation still matches the search is not known. That it is no
        // longer unread is — done marks read — and a list of unread results does not hold it.
        let unreadResults = scope(.search("budget"), [.unread])
        guard case .leaves(let done) = MailRowRules.apply(.done, to: row(), in: unreadResults)
        else { return XCTFail("done under Unread leaves a search too") }
        XCTAssertFalse(done.isUnread)

        let unreadDrafts = scope(.mailbox(.drafts), [.unread])
        guard case .leaves = MailRowRules.apply(.read(true), to: row(), in: unreadDrafts)
        else { return XCTFail("reading under Unread leaves, whatever the place") }

        // A filter it still passes leaves the place as unknown as it was.
        guard case .unknown = MailRowRules.apply(.star(true), to: row(), in: unreadDrafts)
        else { return XCTFail("starring an unread row says nothing new about Drafts") }
    }

    func testNoReplyIsNotAskedBecauseNoChangeAltersIt() {
        // Whether anyone has replied is a fact about the conversation's messages, and nothing
        // he can do to a row changes it. So a row that was in the list still passes: a star
        // under "No reply" shows as a star and stays.
        let inbox = MailPlace.mailbox(.inbox)
        var starred = row()
        starred.isStarred = true
        starred.hasPendingChange = true
        XCTAssertEqual(MailRowRules.apply(.star(true), to: row(), in: scope(inbox, [.noReply])),
                       .stays(starred))

        guard case .leaves = MailRowRules.apply(.done, to: row(), in: scope(inbox, [.noReply]))
        else { return XCTFail("done leaves the inbox under No reply too") }
        guard case .leaves = MailRowRules.apply(.read(true), to: row(),
                                                in: scope(inbox, [.noReply, .unread]))
        else { return XCTFail("reading under Unread leaves, No reply or not") }
    }
}
