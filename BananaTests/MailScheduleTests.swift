#if DEBUG || MAIL_FIXTURES
import XCTest

/// Send later (MAIL-UX 6.3.6, 6.5.5, 7.7), on the sample source: a time chosen in the composer, a
/// message that waits in its conversation and in the Scheduled place, one that is "sent" when its
/// time comes while the app runs, and one whose time passed while it did not — late, with Send now
/// and Keep as a draft, and never sent silently. Time is the mail code's own `ManualMailClock`; no
/// test sleeps and none reads the wall clock.
@MainActor
final class MailScheduleTests: XCTestCase {

    /// A reply to q3, written and scheduled for `after` seconds from now. Returns the draft and when.
    private func schedule(_ h: MailWriteHarness, in after: TimeInterval = 3_600,
                          body: String = "Will look tonight.") async throws -> (draft: MailDraftID, at: Date) {
        let composer = await h.reply(to: "q3")
        composer.body = body
        let at = h.later(after)
        composer.chooseSchedule(at)
        let draft = try XCTUnwrap(composer.draftID)
        h.session.sendComposer()
        return (draft, at)
    }

    private func lastMessage(_ h: MailWriteHarness, _ key: String = "q3") async throws -> MailMessage {
        try await h.lastMessage(key)
    }

    // MARK: The composer

    func testChoosingATimeIsTheComposersAndTheDrafts() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        XCTAssertNil(composer.schedule)
        XCTAssertNil(composer.scheduleLine)
        let at = h.later(3_600)
        composer.toggleTimePicker()
        XCTAssertNotNil(composer.timePicker, "the picker is open")
        composer.chooseSchedule(at)
        XCTAssertNil(composer.timePicker, "choosing shuts it")
        XCTAssertEqual(composer.schedule, at)
        XCTAssertTrue(composer.scheduleLine?.hasPrefix("Sends ") == true, composer.scheduleLine ?? "")
        XCTAssertEqual(composer.currentDraft()?.schedule?.at, at, "it is saved with the draft")
        composer.body = "x"
        composer.flush()
        let stored = await h.source.draft(try XCTUnwrap(composer.draftID))
        XCTAssertEqual(stored?.schedule?.at, at)

        composer.clearSchedule()
        XCTAssertNil(composer.schedule)
        XCTAssertNil(composer.currentDraft()?.schedule)
    }

    func testAChosenTimeIsStillThereWhenTheDraftIsOpenedAgain() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        composer.body = "Half a thought"
        let at = h.later(7_200)
        composer.chooseSchedule(at)
        h.session.closeComposer()
        let back = await h.reply(to: "q3")
        XCTAssertEqual(back.schedule, at, "he comes back to what he chose")

        // A time that has gone by while the draft waited is not one to send at.
        h.session.closeComposer()
        h.manual.advance(by: 7_300)
        let later = await h.reply(to: "q3")
        XCTAssertNil(later.schedule)
    }

    func testTheTimeHeChoseWentByWhileHeWroteSoNothingIsSentOrScheduled() async throws {
        let h = MailWriteHarness()
        let composer = await h.reply(to: "q3")
        composer.body = "Slow thought"
        composer.chooseSchedule(h.later(60))
        h.manual.advance(by: 120)
        h.session.sendComposer()
        XCTAssertEqual(h.toasts.last, MailScheduleCopy.timePassed)
        XCTAssertNotNil(h.composer, "nothing was lost")
        XCTAssertNil(composer.schedule)
        let conversation = try await h.thread("q3")
        XCTAssertEqual(conversation.messages.count, 3)
    }

    // MARK: Scheduling

    func testAScheduledMessageLeavesTheComposerAndIsInItsConversationAndTheScheduledPlace() async throws {
        let h = MailWriteHarness()
        let (draft, at) = try await schedule(h)
        XCTAssertNil(h.composer, "it leaves the composer")

        let conversation = try await h.thread("q3")
        XCTAssertEqual(conversation.messages.count, 4)
        let message = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(message.delivery, .scheduled(at))
        XCTAssertEqual(message.draft, draft, "it can be reopened")
        XCTAssertNil(conversation.draft, "it is not a draft in the conversation any more")

        // What its card says.
        let display = MailMessageDisplay(message, now: h.now)
        XCTAssertEqual(display.scheduled?.draft, draft)
        XCTAssertEqual(display.scheduled?.isLate, false)
        let when = MailScheduleCopy.when(at, now: h.now)
        XCTAssertEqual(display.scheduled?.when, when)
        XCTAssertEqual(MailScheduleCopy.marker(when: when, holder: .thisDevice(name: "Mac")),
                       "Scheduled \u{00B7} \(when) \u{00B7} from this Mac")

        // The Scheduled place, with its count; Drafts no longer has it.
        XCTAssertEqual(h.count(.outbox), 1)
        XCTAssertEqual(h.count(.drafts), 0)
        let row = try XCTUnwrap(h.rows(.outbox).first)
        XCTAssertEqual(row.id, h.id("q3"))
        XCTAssertEqual(row.reason, .scheduled(at, onThisDevice: true, isLate: false))
        XCTAssertEqual(row.people.map(\.address), ["sam@lee.example"])
        XCTAssertEqual(MailRowDisplay(row, now: h.session.now).scheduled, MailScheduleCopy.scheduled(at, now: h.session.now))
        let inboxRow = try XCTUnwrap(h.rows(.inbox).first { $0.id == h.id("q3") })
        XCTAssertEqual(inboxRow.reason, row.reason, "and so does its row in the inbox")

        XCTAssertEqual(h.toasts.last, MailScheduleCopy.scheduledToast(at, now: h.now))
        XCTAssertEqual(h.toasts.last?.action, .undo)
        guard case .send(draft, let holdEnds, nil)? = h.session.undoStack.top?.kind else {
            return XCTFail("the entry is a send that is held until its time")
        }
        XCTAssertEqual(holdEnds, at)
    }

    func testTwoScheduledMessagesInOneConversationAreOneRowAndOneCount() async throws {
        let h = MailWriteHarness()
        let (_, first) = try await schedule(h, in: 7_200, body: "First")
        let (_, second) = try await schedule(h, in: 3_600, body: "Second")
        XCTAssertNotEqual(first, second)
        let rows = h.rows(.outbox)
        XCTAssertEqual(rows.count, 1, "a place counts conversations, and this is one")
        XCTAssertEqual(h.count(.outbox), 1)
        XCTAssertEqual(rows.first?.reason, .scheduled(second, onThisDevice: true, isLate: false),
                       "the one that goes first")
        let conversation = try await h.thread("q3")
        XCTAssertEqual(conversation.messages.count, 5, "both are in the conversation")
    }

    func testTheScheduledPlaceListsTheSoonestFirst() async throws {
        let h = MailWriteHarness()
        _ = try await schedule(h, in: 7_200, body: "Later")
        let other = await h.reply(to: "lunch")
        other.body = "Sooner"
        other.chooseSchedule(h.later(1_800))
        h.session.sendComposer()
        XCTAssertEqual(h.rows(.outbox).map(\.snippet), ["Sooner", "Later"])
        XCTAssertEqual(h.count(.outbox), 2)
    }

    func testANewMessageScheduledIsOnlyInScheduledUntilItHasGone() async throws {
        let h = MailWriteHarness()
        let composer = await h.newMessage()
        composer.toText = "pat@quinn.example,"
        composer.subject = "Lunch"
        composer.body = "Thursday?"
        let at = h.later(3_600)
        composer.chooseSchedule(at)
        let draft = try XCTUnwrap(composer.draftID)
        h.session.sendComposer()

        let local = MailConversationID(account: MailWriteHarness.account, thread: "local:" + draft.raw)
        XCTAssertEqual(h.rows(.outbox).map(\.id), [local])
        XCTAssertFalse(h.rows(.done).contains { $0.id == local }, "not in Done while it waits")
        XCTAssertFalse(h.rows(.inbox).contains { $0.id == local })
        XCTAssertEqual(h.count(.drafts), 0)

        await h.manual.untilSleeping(atLeast: 1)
        h.manual.advance(by: 3_600)
        await h.source.settleWake(of: draft)
        XCTAssertEqual(h.count(.outbox), 0)
        XCTAssertTrue(h.rows(.done).contains { $0.id == local }, "once sent it is like any sent sample message")
    }

    // MARK: The time arrives

    func testTheSampleSourceSendsAtTheTimeAndItThenLooksLikeAnyOtherSentMessage() async throws {
        let h = MailWriteHarness()
        let (draft, _) = try await schedule(h)
        await h.manual.untilSleeping(atLeast: 1)
        XCTAssertEqual(h.count(.outbox), 1)

        // A second early the sleeper is still asleep, so there is nothing to wait for.
        XCTAssertTrue(h.manual.advance(by: 3_599).isEmpty)
        let early = try await lastMessage(h)
        XCTAssertNotNil(early.draft, "a second early, it still waits")
        XCTAssertEqual(h.count(.outbox), 1)

        h.manual.advance(by: 1)
        await h.source.settleWake(of: draft)
        let sent = try await lastMessage(h)
        XCTAssertNil(sent.delivery, "it has gone")
        XCTAssertNil(sent.draft, "and cannot be reopened")
        XCTAssertEqual(h.count(.outbox), 0)
        let row = try XCTUnwrap(h.rows(.inbox).first { $0.id == h.id("q3") })
        XCTAssertNil(row.reason)
        XCTAssertNil(MailMessageDisplay(sent, now: h.now).scheduled)
        XCTAssertEqual(MailMessageDisplay(sent, now: h.now).sampleNote, "Sample \u{00B7} nothing was really sent")
        let kept = await h.source.draft(draft)
        XCTAssertNil(kept, "nothing is left of the draft")
        XCTAssertFalse(h.source.hasUnfinishedSends)
    }

    func testAWakeLongPastItsTimeIsLateAndNotSent() async throws {
        let h = MailWriteHarness()
        let (draft, at) = try await schedule(h)
        await h.manual.untilSleeping(atLeast: 1)
        // The machine slept through it: the sleeper wakes an hour after its time.
        h.manual.advance(by: 3_600 + 3_600)
        await h.source.settleWake(of: draft)

        let message = try await lastMessage(h)
        guard case .asking(_, .sendLate(draft, let since))? = message.delivery else {
            return XCTFail("it asks: \(String(describing: message.delivery))")
        }
        XCTAssertEqual(since, at)
        XCTAssertEqual(MailMessageDisplay(message, now: h.now).scheduled?.isLate, true)
        let row = try XCTUnwrap(h.rows(.outbox).first)
        XCTAssertEqual(row.reason, .scheduled(at, onThisDevice: true, isLate: true))
        XCTAssertTrue(MailRowDisplay(row, now: h.now).isLate)
        let stillThere = await h.source.draft(draft)
        XCTAssertNotNil(stillThere, "it was not sent")
    }

    // MARK: A relaunch

    func testARelaunchAfterTheTimeShowsItLateAndNeverSendsItUnasked() async throws {
        let defaults = MailWriteHarness.ephemeralDefaults()
        let first = MailWriteHarness(defaults: defaults)
        let (draft, at) = try await schedule(first)

        // The app is closed. An hour and a bit later it is opened again.
        let manual = ManualMailClock(start: at.addingTimeInterval(600))
        let second = MailWriteHarness(manual: manual, defaults: defaults)
        let message = try await lastMessage(second)
        XCTAssertEqual(message.draft, draft, "the message is back in its conversation")
        guard case .asking(_, .sendLate(draft, let since))? = message.delivery else {
            return XCTFail("late: \(String(describing: message.delivery))")
        }
        XCTAssertEqual(since, at)
        let display = MailMessageDisplay(message, now: second.now)
        XCTAssertEqual(display.scheduled?.isLate, true)
        XCTAssertEqual(MailScheduleCopy.lateMarker(when: try XCTUnwrap(display.scheduled).when,
                                                   holder: .thisDevice(name: "Mac")),
                       "Not sent yet. It was due \(display.scheduled!.when) and this Mac wasn\u{2019}t running Banana.")
        XCTAssertEqual(second.count(.outbox), 1)
        XCTAssertEqual(second.rows(.outbox).first?.reason, .scheduled(at, onThisDevice: true, isLate: true))
        XCTAssertEqual(second.manual.pendingSleeps, [], "nothing is waiting to send it")
        manual.advance(by: 86_400)
        await second.source.settleWake(of: draft)
        let still = try await lastMessage(second)
        XCTAssertNotNil(still.draft, "a day on, it is still waiting for him")

        // The reply's conversation is as it was.
        let conversation = try await second.thread("q3")
        XCTAssertEqual(conversation.messages.count, 4)
    }

    func testARelaunchBeforeTheTimeKeepsItWaitingAndSendsItWhenItComes() async throws {
        let defaults = MailWriteHarness.ephemeralDefaults()
        let first = MailWriteHarness(defaults: defaults)
        let (draft, at) = try await schedule(first)

        let manual = ManualMailClock(start: at.addingTimeInterval(-1_800))
        let second = MailWriteHarness(manual: manual, defaults: defaults)
        let message = try await lastMessage(second)
        XCTAssertEqual(message.delivery, .scheduled(at), "not late: its time has not come")
        await manual.untilSleeping(atLeast: 1)
        manual.advance(by: 1_800)
        await second.source.settleWake(of: draft)
        let sent = try await lastMessage(second)
        XCTAssertNil(sent.delivery, "it is sent when its time comes while the app runs")
    }

    func testANewMessageScheduledSurvivesARelaunchAsWell() async throws {
        let defaults = MailWriteHarness.ephemeralDefaults()
        let first = MailWriteHarness(defaults: defaults)
        let composer = await first.newMessage()
        composer.toText = "pat@quinn.example,"
        composer.subject = "Lunch"
        composer.body = "Thursday?"
        let at = first.later(3_600)
        composer.chooseSchedule(at)
        let draft = try XCTUnwrap(composer.draftID)
        first.session.sendComposer()

        let second = MailWriteHarness(manual: ManualMailClock(start: at.addingTimeInterval(60)), defaults: defaults)
        let row = try XCTUnwrap(second.rows(.outbox).first)
        XCTAssertEqual(row.subject, "Lunch")
        XCTAssertEqual(row.people.map(\.address), ["pat@quinn.example"])
        XCTAssertEqual(row.reason, .scheduled(at, onThisDevice: true, isLate: true))
        // A draft made after the relaunch does not take the number the kept one has.
        let fresh = await second.newMessage()
        XCTAssertNotEqual(fresh.draftID, draft)
    }

    func testWhatIsSentOrCancelledIsNotKeptForTheNextLaunch() async throws {
        let defaults = MailWriteHarness.ephemeralDefaults()
        let first = MailWriteHarness(defaults: defaults)
        let (draft, at) = try await schedule(first)
        await first.manual.untilSleeping(atLeast: 1)
        first.manual.advance(by: 3_600)
        await first.source.settleWake(of: draft)

        let second = MailWriteHarness(manual: ManualMailClock(start: at.addingTimeInterval(60)), defaults: defaults)
        XCTAssertEqual(second.count(.outbox), 0)

        let third = MailWriteHarness(defaults: defaults)
        let (cancelled, cancelledAt) = try await schedule(third, body: "Another")
        third.session.cancelSchedule(cancelled, at: cancelledAt)
        await third.session.settle()
        let fourth = MailWriteHarness(defaults: defaults)
        XCTAssertEqual(fourth.count(.outbox), 0)
    }

    // MARK: What can be done to it

    func testCancelReturnsItToADraftWithUndoThatSchedulesItAgain() async throws {
        let h = MailWriteHarness()
        let (draft, at) = try await schedule(h)
        h.session.cancelSchedule(draft, at: at)
        await h.session.settle()

        let conversation = try await h.thread("q3")
        XCTAssertEqual(conversation.messages.count, 3, "the scheduled message is out of the conversation")
        XCTAssertEqual(conversation.draft, draft, "and it is a draft again")
        XCTAssertEqual(h.count(.outbox), 0)
        XCTAssertEqual(h.count(.drafts), 1)
        XCTAssertEqual(h.toasts.last, MailScheduleCopy.backToDraft)
        XCTAssertEqual(h.toasts.last?.action, .undo)
        XCTAssertEqual(h.manual.pendingSleeps, [], "nothing is waiting to send it")

        h.session.undoTop()
        await h.session.settle()
        XCTAssertEqual(h.count(.outbox), 1, "Undo schedules it again, for the same time")
        let got2 = try await lastMessage(h).delivery
        XCTAssertEqual(got2, .scheduled(at))
        XCTAssertEqual(h.count(.drafts), 0)
    }

    func testRescheduleMovesTheTimeAndUndoPutsTheOldOneBack() async throws {
        let h = MailWriteHarness()
        let (draft, at) = try await schedule(h)
        let new = h.later(86_400)
        h.session.reschedule(draft, from: at, to: new)
        await h.session.settle()
        let got3 = try await lastMessage(h).delivery
        XCTAssertEqual(got3, .scheduled(new))
        XCTAssertEqual(h.rows(.outbox).count, 1, "one message, another time")
        XCTAssertEqual(h.toasts.last, MailScheduleCopy.rescheduledToast(new, now: h.now))

        h.session.undoTop()
        await h.session.settle()
        let got4 = try await lastMessage(h).delivery
        XCTAssertEqual(got4, .scheduled(at))
        let got5 = try await h.thread("q3").messages.count
        XCTAssertEqual(got5, 4)
    }

    func testSendNowTakesItOverAndSendsItThroughTheOrdinaryHold() async throws {
        let h = MailWriteHarness()
        let (draft, _) = try await schedule(h)
        h.session.sendScheduledNow(draft)
        await h.session.settle()
        let message = try await lastMessage(h)
        guard case .held(let until)? = message.delivery else {
            return XCTFail("inside the undo hold: \(String(describing: message.delivery))")
        }
        XCTAssertEqual(until, h.now.addingTimeInterval(MailSession.undoHold))
        XCTAssertEqual(h.count(.outbox), 0)
        XCTAssertEqual(h.toasts.last?.text, "Sending")
        XCTAssertEqual(h.toasts.last?.action, .undo)
        let got6 = try await h.thread("q3").messages.count
        XCTAssertEqual(got6, 4)
    }

    func testEditOpensTheComposerOnItWithTheTimeStillChosen() async throws {
        let h = MailWriteHarness()
        let (draft, at) = try await schedule(h, body: "Will look tonight.")
        h.session.editScheduled(draft)
        await h.session.settle()
        let composer = try XCTUnwrap(h.composer)
        await composer.waitForDraft()
        XCTAssertEqual(composer.draftID, draft)
        XCTAssertEqual(composer.body, "Will look tonight.")
        XCTAssertEqual(composer.schedule, at, "the time is still on it, to keep or to change")
        let got7 = try await h.thread("q3").messages.count
        XCTAssertEqual(got7, 3, "it is not also in the conversation")
        XCTAssertEqual(h.count(.outbox), 0)
    }

    func testUndoOfTheScheduleReopensTheComposerAsItWas() async throws {
        let h = MailWriteHarness()
        let (draft, at) = try await schedule(h)
        h.press("z")
        await h.session.settle()
        let composer = try XCTUnwrap(h.composer, "Undo before its time is a cancel: he is writing it again")
        await composer.waitForDraft()
        XCTAssertEqual(composer.draftID, draft)
        XCTAssertEqual(composer.body, "Will look tonight.")
        XCTAssertEqual(composer.schedule, at)
        XCTAssertEqual(h.count(.outbox), 0)
        XCTAssertEqual(h.toasts.last, MailToast(text: "Undone", action: nil))
    }

    func testUndoAfterItsTimeSaysAlreadySent() async throws {
        let h = MailWriteHarness()
        let (draft, _) = try await schedule(h)
        await h.manual.untilSleeping(atLeast: 1)
        h.manual.advance(by: 3_600)
        await h.source.settleWake(of: draft)
        h.press("z")
        await h.session.settle()
        XCTAssertEqual(h.toasts.last, MailToast(text: "Already sent.", action: nil))
        XCTAssertNil(h.composer)
    }

    // MARK: Late

    private func lateMessage(_ h: MailWriteHarness) async throws -> (draft: MailDraftID, at: Date) {
        let (draft, at) = try await schedule(h)
        await h.manual.untilSleeping(atLeast: 1)
        h.manual.advance(by: 7_200)
        await h.source.settleWake(of: draft)
        return (draft, at)
    }

    func testALateMessageCanBeSentNowWithAnUndoHold() async throws {
        let h = MailWriteHarness()
        let (draft, _) = try await lateMessage(h)
        h.session.sendScheduledNow(draft)
        await h.session.settle()
        guard case .held? = try await lastMessage(h).delivery else { return XCTFail("sending, inside its hold") }
        XCTAssertEqual(h.toasts.last?.text, "Sending")
        XCTAssertEqual(h.count(.outbox), 0)
    }

    func testALateMessageCanBeKeptAsADraft() async throws {
        let h = MailWriteHarness()
        let (draft, _) = try await lateMessage(h)
        h.session.keepAsDraft(draft)
        await h.session.settle()
        XCTAssertEqual(h.toasts.last, MailScheduleCopy.keptAsDraft)
        XCTAssertEqual(h.count(.outbox), 0)
        XCTAssertEqual(h.count(.drafts), 1, "it is in Drafts, whole")
        let conversation = try await h.thread("q3")
        XCTAssertEqual(conversation.messages.count, 3)
        XCTAssertEqual(conversation.draft, draft)
        // Opened again, the time it had is past and is not one to send at.
        h.session.begin(.continuing(draft), requestFocus: false)
        let composer = try XCTUnwrap(h.composer)
        await composer.waitForDraft()
        XCTAssertNil(composer.schedule)
        XCTAssertEqual(composer.body, "Will look tonight.")
    }

    // MARK: Leaving the app

    func testLeavingTheAppDoesNotSendAScheduledMessage() async throws {
        let h = MailWriteHarness()
        let (draft, at) = try await schedule(h)
        XCTAssertFalse(h.source.hasUnfinishedSends, "nothing is waiting on a hold")
        await h.source.finishSends(within: 0)
        let got8 = try await lastMessage(h).delivery
        XCTAssertEqual(got8, .scheduled(at))
        _ = draft
    }
}
#endif
