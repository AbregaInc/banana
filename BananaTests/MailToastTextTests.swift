import XCTest

/// Every line of the table in MAIL-UX 7.9, held against the words that were written there, so a
/// slip in the wording is a failing test and not something he reads. Where the document gives
/// one example, the others are the same sentence with the same shape, and the test says so.
final class MailToastTextTests: XCTestCase {

    private let open = "\u{201C}"
    private let close = "\u{201D}"
    private func q(_ subject: String) -> String { "\(open)\(subject)\(close)" }

    private let invoices = MailLabelRef(id: "L1", name: "Invoices", colorHex: nil)
    private let account = "me@example.com"

    private func toast(_ action: MailAction, _ change: MailChange, _ subjects: [String], _ count: Int,
                       time: String? = nil) -> MailToast? {
        MailToastText.toast(for: action, change: change, subjects: subjects, count: count, time: time)
    }

    // MARK: After an action

    func testDoneNamesTheConversationOrCountsThem() {
        XCTAssertEqual(toast(.done, .done, ["Q3 numbers"], 1),
                       MailToast(text: "Marked \(q("Q3 numbers")) Done", action: .undo))
        XCTAssertEqual(toast(.done, .done, ["Q3 numbers"], 12),
                       MailToast(text: "12 marked Done", action: .undo))
    }

    func testTrashAndSpam() {
        XCTAssertEqual(toast(.trash, .trash, ["Q3 numbers"], 1)?.text, "Moved \(q("Q3 numbers")) to Trash")
        XCTAssertEqual(toast(.spam, .spam, ["Q3 numbers"], 1)?.text, "Marked \(q("Q3 numbers")) as spam")
        XCTAssertEqual(toast(.trash, .trash, [], 4)?.text, "4 moved to Trash")
        XCTAssertEqual(toast(.spam, .spam, [], 4)?.text, "4 marked as spam")
    }

    func testMoveAndLabel() {
        let move = MailAction.move(account: account, to: invoices)
        XCTAssertEqual(toast(move, .move(account: account, to: "L1", from: nil), ["Q3 numbers"], 1)?.text,
                       "Moved \(q("Q3 numbers")) to Invoices")
        let label = MailAction.label(account: account, add: [invoices], remove: [])
        XCTAssertEqual(toast(label, .label(account: account, add: ["L1"], remove: []), ["Q3 numbers"], 1)?.text,
                       "Labelled \(q("Q3 numbers")) Invoices")
        XCTAssertEqual(toast(move, .move(account: account, to: "L1", from: nil), [], 3)?.text,
                       "3 moved to Invoices")
        XCTAssertEqual(toast(label, .label(account: account, add: ["L1"], remove: []), [], 3)?.text,
                       "3 labelled Invoices")
    }

    func testNotDoneBackToTheInboxAndNotSpamAreBackInTheInbox() {
        for action in [MailAction.notDone, .backToInbox, .notSpam] {
            XCTAssertEqual(toast(action, .notDone, ["Q3 numbers"], 1),
                           MailToast(text: "\(q("Q3 numbers")) is back in the inbox", action: .undo), "\(action)")
        }
        XCTAssertEqual(toast(.backToInbox, .notDone, [], 2)?.text, "2 are back in the inbox")
    }

    func testRestoreFromTrashSaysRestoredBecauseItMayNotReturnToTheInbox() {
        XCTAssertEqual(toast(.restore, .restore, ["Q3 numbers"], 1),
                       MailToast(text: "Restored \(q("Q3 numbers"))", action: .undo))
        XCTAssertEqual(toast(.restore, .restore, [], 12)?.text, "12 restored")
        XCTAssertEqual(MailToastText.description(for: .restore, change: .restore, count: 1), "Restored")
    }

    func testALabelTakenOffIsRemovedFromNotLabelled() {
        let take = MailAction.removeLabel(account: account, label: invoices)
        XCTAssertEqual(toast(take, .label(account: account, add: [], remove: ["L1"]), ["Q3 numbers"], 1)?.text,
                       "Removed \(q("Q3 numbers")) from Invoices")
        XCTAssertEqual(toast(take, .label(account: account, add: [], remove: ["L1"]), [], 12)?.text,
                       "12 removed from Invoices")
        XCTAssertEqual(MailToastText.description(for: take, change: .label(account: account, add: [], remove: ["L1"]),
                                                 count: 1), "Removed from Invoices")
        // A label put on, with several names, takes them with commas.
        let both = MailLabelRef(id: "L2", name: "Hiring", colorHex: nil)
        let put = MailAction.label(account: account, add: [invoices, both], remove: [])
        XCTAssertEqual(toast(put, .label(account: account, add: ["L1", "L2"], remove: []), ["Q3 numbers"], 1)?.text,
                       "Labelled \(q("Q3 numbers")) Invoices, Hiring")
    }

    func testADoneThatActedOnTheMessagesSeenSaysThatAReplyKeepsTheConversationInTheInbox() {
        XCTAssertEqual(MailToastText.toast(for: .done, change: .done, subjects: ["Q3 numbers"], count: 1,
                                           keepsInInbox: true),
                       MailToast(text: "Marked Done \u{00B7} a new reply keeps \(q("Q3 numbers")) in the inbox",
                                 action: .undo))
        XCTAssertEqual(MailToastText.description(for: .done, change: .done, count: 1), "Marked Done")
    }

    func testSnoozeSaysUntilWhenAndUnlessTheyReply() {
        let until = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(toast(.snooze(until: until, ifNoReply: false), .snooze(until: until, ifNoReply: false),
                             ["Q3 numbers"], 1, time: "Thu 8 AM")?.text,
                       "Snoozed \(q("Q3 numbers")) until Thu 8 AM")
        XCTAssertEqual(toast(.snooze(until: until, ifNoReply: true), .snooze(until: until, ifNoReply: true),
                             ["Q3 numbers"], 1, time: "Thu 8 AM")?.text,
                       "Snoozed \(q("Q3 numbers")) until Thu 8 AM, unless they reply")
    }

    func testStarReadAndUnreadHaveNoToastBecauseTheRowShowsIt() {
        XCTAssertNil(toast(.toggleStar, .star(true), ["Q3 numbers"], 1))
        XCTAssertNil(toast(.toggleStar, .star(false), ["Q3 numbers"], 1))
        XCTAssertNil(toast(.toggleRead, .read(true), ["Q3 numbers"], 1))
        XCTAssertNil(toast(.toggleRead, .read(false), ["Q3 numbers"], 1))
    }

    func testSendAndDoneIsTheComposersToastAndAnotherFeaturesActionHasNone() {
        XCTAssertNil(toast(.sendAndDone, .done, ["Q3 numbers"], 1))
        XCTAssertNil(toast(.answerInvitation, .done, ["Q3 numbers"], 1))
        XCTAssertNil(toast(.addToPlan, .done, ["Q3 numbers"], 1))
        XCTAssertNil(toast(.unsubscribe, .done, ["Q3 numbers"], 1))
    }

    func testNothingIsInventedForAnActionThatPutsNothingOnTheStackLeastOfAllDone() {
        for action in [MailAction.answerInvitation, .addToPlan, .unsubscribe] {
            XCTAssertEqual(MailToastText.description(for: action, change: .done, count: 1), "", "\(action)")
        }
    }

    // MARK: Numbers and long subjects

    func testANumberIsGroupedAsEverywhereElse() {
        XCTAssertEqual(MailToastText.number(1_204, locale: Locale(identifier: "en_US")), "1,204")
        XCTAssertEqual(MailToastText.number(12, locale: Locale(identifier: "en_US")), "12")
        XCTAssertEqual(MailToastText.number(1_204, locale: Locale(identifier: "de_DE")), "1.204")
    }

    func testEveryPluralUsesTheGroupedNumber() {
        let n = MailToastText.number(1_204)
        XCTAssertEqual(toast(.done, .done, [], 1_204)?.text, "\(n) marked Done")
        XCTAssertEqual(toast(.trash, .trash, [], 1_204)?.text, "\(n) moved to Trash")
        XCTAssertEqual(toast(.restore, .restore, [], 1_204)?.text, "\(n) restored")
        XCTAssertEqual(MailToastText.description(for: .done, change: .done, count: 1_204), "\(n) marked Done")
        XCTAssertEqual(MailToastText.refused(.done, change: .done, subjects: [], count: 1_204,
                                             failure: .other).text,
                       "Couldn't mark \(n) conversations Done: Gmail refused it.")
        if n.contains(",") { XCTAssertNotEqual(n, "1204") }
    }

    func testALongSubjectIsCutTo30CharactersAndAnEllipsisSoTheOutcomeIsTheLastWord() {
        let thirty = String(repeating: "a", count: 30)
        XCTAssertEqual(MailToastText.quoted(thirty), "\u{201C}\(thirty)\u{201D}", "30 is not cut")
        let long = String(repeating: "a", count: 31)
        XCTAssertEqual(MailToastText.quoted(long), "\u{201C}\(thirty)\u{2026}\u{201D}")
        XCTAssertTrue(toast(.done, .done, [long], 1)!.text.hasSuffix("\u{2026}\u{201D} Done"))
        XCTAssertTrue(toast(.spam, .spam, [long], 1)!.text.hasSuffix(" as spam"))
        XCTAssertEqual(MailToastText.refused(.trash, change: .trash, subjects: [long], count: 1, failure: .other).text,
                       "Couldn't move \u{201C}\(thirty)\u{2026}\u{201D} to Trash: Gmail refused it.")
        XCTAssertEqual(MailToastText.quoted("Re: " + long), "\u{201C}\(thirty)\u{2026}\u{201D}", "cleaned first, then cut")
    }

    func testASubjectIsNamedAsARowSaysItWithReAndFwdTakenOff() {
        XCTAssertEqual(MailToastText.cleanSubject("Re: Fwd: Q3 numbers"), "Q3 numbers")
        XCTAssertEqual(MailToastText.cleanSubject("RE: re: FW: Q3"), "Q3")
        XCTAssertEqual(MailToastText.cleanSubject("Re:Q3"), "Q3")
        XCTAssertEqual(MailToastText.cleanSubject("Real estate update"), "Real estate update")
        XCTAssertEqual(MailToastText.cleanSubject("Refund: Fwd"), "Refund: Fwd")
        XCTAssertEqual(MailToastText.cleanSubject(""), "(no subject)")
        XCTAssertEqual(MailToastText.cleanSubject("  Re:  "), "(no subject)")
        XCTAssertEqual(MailToastText.quoted("Re: Q3 numbers"), q("Q3 numbers"))
    }

    // MARK: Sending and discarding

    func testSend() {
        XCTAssertEqual(MailToastText.sending(thenDone: false), MailToast(text: "Sending", action: .undo))
        XCTAssertEqual(MailToastText.sending(thenDone: true),
                       MailToast(text: "Sending · marked Done", action: .undo))
        XCTAssertEqual(MailToastText.sent, MailToast(text: "Sent.", action: nil))
        XCTAssertEqual(MailToastText.willSendWhenOnline,
                       MailToast(text: "Will send when Banana is next open and online", action: .undo))
    }

    func testDiscard() {
        XCTAssertEqual(MailToastText.draftDiscarded, MailToast(text: "Draft discarded", action: .undo))
    }

    // MARK: Undo

    func testUndoSaysUndoneAndOffersTheEntryBeforeIt() {
        XCTAssertEqual(MailToastText.undone(previous: nil), MailToast(text: "Undone", action: nil))
        let again = MailToastText.undone(previous: "Marked Done")
        XCTAssertEqual(again, MailToast(text: "Undone", action: .undoPrevious("Marked Done")))
        XCTAssertEqual(again.action?.title, "Undo previous: Marked Done")
    }

    func testUndoFailsAndTooLate() {
        XCTAssertEqual(MailToastText.cannotBeUndone, MailToast(text: "That can no longer be undone.", action: nil))
        XCTAssertEqual(MailToastText.alreadySent(), MailToast(text: "Already sent.", action: nil))
        XCTAssertEqual(MailToastText.alreadySent(backInInbox: "Q3 numbers").text,
                       "Already sent. \(q("Q3 numbers")) is back in the inbox.")
    }

    func testTheButtonsAreNamed() {
        XCTAssertEqual(MailToast.Action.undo.title, "Undo")
        XCTAssertEqual(MailToast.Action.retry.title, "Retry")
        XCTAssertEqual(MailToast.duration, 6)
    }

    // MARK: A change that cannot stand (T36)

    func testARefusedChangeSaysWhatAndWhyWithRetry() {
        let move = MailAction.move(account: account, to: invoices)
        let change = MailChange.move(account: account, to: "L1", from: nil)
        XCTAssertEqual(MailToastText.refused(move, change: change, subjects: ["Q3 numbers"], count: 1,
                                             failure: .labelMissing),
                       MailToast(text: "Couldn't move \(q("Q3 numbers")): that label no longer exists.",
                                 action: .retry))
    }

    func testTakingALabelOffIsNeverCalledLabelling() {
        let take = MailAction.removeLabel(account: account, label: invoices)
        let change = MailChange.label(account: account, add: [], remove: ["L1"])
        XCTAssertEqual(MailToastText.refused(take, change: change, subjects: ["Q3 numbers"], count: 1,
                                             failure: .labelMissing).text,
                       "Couldn't take Invoices off \(q("Q3 numbers")): that label no longer exists.")
        let picker = MailAction.label(account: account, add: [], remove: [invoices])
        XCTAssertEqual(MailToastText.refused(picker, change: change, subjects: [], count: 12, failure: .other).text,
                       "Couldn't take Invoices off 12 conversations: Gmail refused it.")
        let put = MailAction.label(account: account, add: [invoices], remove: [])
        XCTAssertEqual(MailToastText.refused(put, change: .label(account: account, add: ["L1"], remove: []),
                                             subjects: ["Q3 numbers"], count: 1, failure: .other).text,
                       "Couldn't label \(q("Q3 numbers")): Gmail refused it.")
    }

    func testRestoringIsRestoreNotMoveBackToTheInbox() {
        XCTAssertEqual(MailToastText.refused(.restore, change: .restore, subjects: ["Q3 numbers"], count: 1,
                                             failure: .other).text,
                       "Couldn't restore \(q("Q3 numbers")): Gmail refused it.")
        XCTAssertEqual(MailToastText.refused(.notDone, change: .notDone, subjects: ["Q3 numbers"], count: 1,
                                             failure: .other).text,
                       "Couldn't move \(q("Q3 numbers")) back to the inbox: Gmail refused it.")
    }

    func testWhenGmailsLimitForTheDayWasReachedThereIsOneSentenceAndNoRetry() {
        let move = MailAction.move(account: account, to: invoices)
        let change = MailChange.move(account: account, to: "L1", from: nil)
        XCTAssertEqual(MailToastText.refused(move, change: change, subjects: ["Q3 numbers"], count: 1,
                                             failure: .limitReached),
                       MailToast(text: "Couldn't move \(q("Q3 numbers")): Gmail's limit for today was reached.",
                                 action: nil))
        // Every other refusal can be tried again.
        for failure in [MailFailure.tooLarge, .addressRejected, .signedOut, .accessMissing, .notAllowedByAdmin,
                        .labelMissing, .internalError, .other] {
            XCTAssertEqual(MailToastText.refused(move, change: change, subjects: [], count: 2,
                                                 failure: failure).action, .retry, "\(failure)")
        }
    }

    func testARefusedBatchCountsTheConversations() {
        let move = MailAction.move(account: account, to: invoices)
        let change = MailChange.move(account: account, to: "L1", from: nil)
        XCTAssertEqual(MailToastText.refused(move, change: change, subjects: ["Q3 numbers"], count: 12,
                                             failure: .labelMissing).text,
                       "Couldn't move 12 conversations: that label no longer exists.")
    }

    func testEveryFailureHasItsWordsAndNoneIsGoogles() {
        let expected: [MailFailure: String] = [
            .tooLarge: "it's over Gmail's size limit.",
            .addressRejected: "Gmail rejected one of the addresses.",
            .signedOut: "this account has to be allowed again.",
            .accessMissing: "this account has to be allowed again.",
            .notAllowedByAdmin: "the organisation doesn't allow it.",
            .labelMissing: "that label no longer exists.",
            .limitReached: "Gmail's limit for today was reached. Try again tomorrow.",
            .internalError: "Gmail refused it.",
            .other: "Gmail refused it.",
        ]
        XCTAssertEqual(expected.count, 9, "every case of the contract's closed list")
        for (failure, words) in expected {
            XCTAssertEqual(MailToastText.reason(for: failure), words, "\(failure)")
        }
    }

    func testARefusalNamesWhatItWasAboutForEveryAction() {
        let done = MailToastText.refused(.done, change: .done, subjects: ["Q3"], count: 1, failure: .other)
        XCTAssertEqual(done.text, "Couldn't mark \(q("Q3")) Done: Gmail refused it.")
        let trash = MailToastText.refused(.trash, change: .trash, subjects: ["Q3"], count: 1, failure: .other)
        XCTAssertEqual(trash.text, "Couldn't move \(q("Q3")) to Trash: Gmail refused it.")
        let star = MailToastText.refused(.toggleStar, change: .star(true), subjects: ["Q3"], count: 1,
                                         failure: .other)
        XCTAssertEqual(star.text, "Couldn't star \(q("Q3")): Gmail refused it.")
        let unread = MailToastText.refused(.toggleRead, change: .read(false), subjects: ["Q3"], count: 1,
                                           failure: .other)
        XCTAssertEqual(unread.text, "Couldn't mark \(q("Q3")) unread: Gmail refused it.")
    }

    // MARK: Could not be saved

    func testACouldNotBeSavedToastNamesTheDeviceAndHasNoButton() {
        XCTAssertEqual(MailToastText.notSaved(on: "iPhone", problem: .diskFull),
                       MailToast(text: "Couldn't save that: this iPhone is full.", action: nil))
        XCTAssertEqual(MailToastText.notSaved(on: "Mac", problem: .diskFull).text,
                       "Couldn't save that: this Mac is full.")
    }

    func testTheFourStoreProblemsEachHaveTheirOwnPlainReasonAndNoButton() {
        XCTAssertEqual(MailToastText.notSaved(on: "iPad", problem: .diskFull),
                       MailToast(text: "Couldn't save that: this iPad is full.", action: nil))
        XCTAssertEqual(MailToastText.notSaved(on: "iPad", problem: .damaged),
                       MailToast(text: "Couldn't save that: Mail's data on this iPad is being repaired.", action: nil))
        XCTAssertEqual(MailToastText.notSaved(on: "iPad", problem: .newerVersion),
                       MailToast(text: "Couldn't save that: this iPad's mail was made by a newer Banana. Update Banana.",
                                 action: nil))
        XCTAssertEqual(MailToastText.notSaved(on: "iPad", problem: .unavailable),
                       MailToast(text: "Couldn't save that: Mail's data can't be opened right now.", action: nil))
    }

    // MARK: What the stack calls an entry

    func testADescriptionIsTheToastWithoutTheName() {
        XCTAssertEqual(MailToastText.description(for: .done, change: .done, count: 1), "Marked Done")
        XCTAssertEqual(MailToastText.description(for: .done, change: .done, count: 3), "3 marked Done")
        XCTAssertEqual(MailToastText.description(for: .trash, change: .trash, count: 1), "Moved to Trash")
        XCTAssertEqual(MailToastText.description(for: .spam, change: .spam, count: 1), "Marked as spam")
        XCTAssertEqual(MailToastText.description(for: .move(account: account, to: invoices),
                                                 change: .move(account: account, to: "L1", from: nil), count: 1),
                       "Moved to Invoices")
        XCTAssertEqual(MailToastText.description(for: .notDone, change: .notDone, count: 1), "Back in the inbox")
    }

    func testWhatCannotBeSentSaysWhyInTheWordsOfSection633() {
        XCTAssertEqual(MailToastText.addSomeone, MailToast(text: "Add someone to send to.", action: nil))
        XCTAssertEqual(MailToastText.nothingToSend, MailToast(text: "Nothing to send yet.", action: nil))
        XCTAssertEqual(MailToastText.notAnAddress("sam@"),
                       MailToast(text: "\u{201C}sam@\u{201D} isn't an address.", action: nil))
    }

    func testASetAsideNewMessageAndASendHaveTheirWordsAndNoOtherToastHasADuration() {
        XCTAssertEqual(MailToastText.draftKept, MailToast(text: "Draft kept", action: nil))
        XCTAssertEqual(MailToastText.sentDescription, "Sent")
        XCTAssertNil(MailToastText.sending(thenDone: false).lasts, "how long it stays is the session's, from the hold")
        XCTAssertNil(MailToastText.draftDiscarded.lasts)
    }

    func testStarsAndReadingHaveADescriptionThoughNoToast() {
        XCTAssertEqual(MailToastText.description(for: .toggleStar, change: .star(true), count: 1), "Starred")
        XCTAssertEqual(MailToastText.description(for: .toggleStar, change: .star(false), count: 2), "2 unstarred")
        XCTAssertEqual(MailToastText.description(for: .toggleRead, change: .read(true), count: 1), "Marked read")
        XCTAssertEqual(MailToastText.description(for: .toggleRead, change: .read(false), count: 1), "Marked unread")
    }
}
