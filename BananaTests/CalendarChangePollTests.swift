import XCTest

/// The Google change poll must stop for the background and start again after it — without
/// forgetting what it had not yet asked, and without ever running twice.
///
/// A backgrounded audio app keeps its process alive for hours, and the poll woke it every two
/// minutes to skip its own work. Stopped for the background, the risk is the other way: a poll
/// left off, a second one started beside it, or one that comes back with its window reset to "now"
/// and so never learns what changed while the app was away.
///
/// These run the real loop with an interval of a few hundredths of a second.
@MainActor
final class CalendarChangePollTests: XCTestCase {

    private let interval: TimeInterval = 0.02

    /// What the poll was asked, and what the test lets it answer.
    private final class Recorder {
        var sinces: [Date] = []
        var answers: [Bool?] = []     // consumed in order; false once exhausted
        var active = true
        var changes = 0
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var count: Int { sinces.count }
    }

    private func makePoll(_ recorder: Recorder, interval: TimeInterval? = nil) -> CalendarChangePoll {
        CalendarChangePoll(
            interval: interval ?? self.interval,
            now: { recorder.clock },
            isActive: { recorder.active },
            check: { since in
                recorder.sinces.append(since)
                return recorder.answers.isEmpty ? false : recorder.answers.removeFirst()
            },
            onChange: { recorder.changes += 1 })
    }

    private func until(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - The wait after a restart

    func testARestartWaitsOnlyTheRestOfTheInterval() {
        let last = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(CalendarChangePoll.firstWait(interval: 120, since: last, now: last.addingTimeInterval(30)), 90,
                       accuracy: 0.001, "a short trip away is noticed when the interval is up, not a whole one later")
    }

    func testAnOverdueRestartChecksAtOnce() {
        let last = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(CalendarChangePoll.firstWait(interval: 120, since: last, now: last.addingTimeInterval(120)), 0)
        XCTAssertEqual(CalendarChangePoll.firstWait(interval: 120, since: last, now: last.addingTimeInterval(3_600)), 0,
                       "a long absence is checked at once")
    }

    func testARestartNeverWaitsLongerThanTheInterval() {
        let last = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(CalendarChangePoll.firstWait(interval: 120, since: last, now: last), 120)
        XCTAssertEqual(CalendarChangePoll.firstWait(interval: 120, since: last, now: last.addingTimeInterval(-50)), 120,
                       "a clock set back is not an excuse to wait longer")
    }

    // MARK: - Running

    func testItChecksEveryIntervalOnceStarted() async {
        let recorder = Recorder()
        let poll = makePoll(recorder)
        poll.start()
        let checked = await until { recorder.count >= 3 }
        poll.pause()
        XCTAssertTrue(checked)
    }

    func testItDoesNothingOnATickThatIsNotActive() async {
        let recorder = Recorder()
        recorder.active = false
        let poll = makePoll(recorder)
        let started = recorder.clock
        poll.start()
        try? await Task.sleep(for: .seconds(0.2))
        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(poll.lastCheck, started, "nothing was asked, so nothing was answered")
        recorder.active = true
        let checked = await until { recorder.count >= 1 }
        poll.pause()
        XCTAssertTrue(checked)
    }

    func testAYesRunsTheRefresh() async {
        let recorder = Recorder()
        recorder.answers = [true, false]
        let poll = makePoll(recorder)
        poll.start()
        let changed = await until { recorder.changes >= 1 && recorder.count >= 2 }
        poll.pause()
        XCTAssertTrue(changed)
        XCTAssertEqual(recorder.changes, 1, "only the yes")
    }

    // MARK: - The background

    func testAPausedPollAsksNothing() async {
        let recorder = Recorder()
        let poll = makePoll(recorder)
        poll.start()
        _ = await until { recorder.count >= 1 }
        poll.pause()
        let asked = recorder.count
        try? await Task.sleep(for: .seconds(0.2))
        XCTAssertEqual(recorder.count, asked, "no wakeups in the background")
        XCTAssertFalse(poll.isRunning)
    }

    func testResumingAfterAPauseStartsItAgain() async {
        let recorder = Recorder()
        let poll = makePoll(recorder)
        poll.start()
        _ = await until { recorder.count >= 1 }
        poll.pause()
        let asked = recorder.count
        poll.resume()
        let again = await until { recorder.count > asked }
        poll.pause()
        XCTAssertTrue(again, "a poll left off is the failure that matters")
        XCTAssertFalse(poll.isRunning)
    }

    /// Resume is called on every activation, and at launch when nothing was paused: it must not
    /// start a second loop beside the first.
    func testResumingWhileRunningStartsNoSecondLoop() async {
        let recorder = Recorder()
        let poll = makePoll(recorder, interval: 0.05)
        poll.start()
        for _ in 0..<5 { poll.resume() }
        try? await Task.sleep(for: .seconds(0.26))
        poll.pause()
        // One loop checks at most once per interval plus once at the end of the window; two would
        // roughly double it.
        XCTAssertLessThanOrEqual(recorder.count, 6)
        XCTAssertGreaterThan(recorder.count, 0)
    }

    /// The reason `lastCheck` lives in the poll: the first check after coming back must look back
    /// over the whole absence, not over the moment of coming back.
    func testTheWindowSurvivesAPause() async {
        let recorder = Recorder()
        let start = recorder.clock
        let poll = makePoll(recorder)
        recorder.clock = start.addingTimeInterval(100)
        poll.start()
        _ = await until { recorder.count >= 1 }
        poll.pause()
        XCTAssertEqual(recorder.sinces[0], start.addingTimeInterval(-10), "the first look starts at the poll's own start")
        XCTAssertEqual(poll.lastCheck, start.addingTimeInterval(100))

        let asked = recorder.count
        recorder.clock = start.addingTimeInterval(10_000)   // a long absence
        poll.resume()
        _ = await until { recorder.count > asked }
        poll.pause()
        XCTAssertEqual(recorder.sinces[asked], start.addingTimeInterval(100 - 10),
                       "it asks about everything since the last answer, not since it came back")
    }

    func testAnUnansweredCheckKeepsTheWindowOpen() async {
        let recorder = Recorder()
        let start = recorder.clock
        recorder.answers = [nil, false]
        let poll = makePoll(recorder)
        recorder.clock = start.addingTimeInterval(50)
        poll.start()
        _ = await until { recorder.count >= 2 }
        poll.pause()
        XCTAssertEqual(recorder.sinces[1], recorder.sinces[0],
                       "offline or an error: what was missed is asked again")
        XCTAssertEqual(poll.lastCheck, start.addingTimeInterval(50), "answered by the second check only")
    }

    func testAnOverdueResumeChecksBeforeAFullIntervalHasPassed() async {
        let recorder = Recorder()
        let start = recorder.clock
        let poll = makePoll(recorder, interval: 1_000)   // a tick would never come in this test
        poll.start()
        poll.pause()
        recorder.clock = start.addingTimeInterval(5_000)
        poll.resume()
        let checked = await until { recorder.count >= 1 }
        poll.pause()
        XCTAssertTrue(checked, "a return after a long absence checks at once")
    }

    func testARecentResumeWaitsRatherThanChecksAtOnce() async {
        let recorder = Recorder()
        let poll = makePoll(recorder, interval: 1_000)
        poll.start()
        poll.pause()
        poll.resume()   // the clock has not moved: nearly the whole interval is left
        try? await Task.sleep(for: .seconds(0.15))
        poll.pause()
        XCTAssertEqual(recorder.count, 0)
    }
}
