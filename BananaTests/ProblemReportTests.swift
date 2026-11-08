import XCTest

/// Problem reports (docs/design/PROBLEM-REPORTS.md): scrubbing the log, the daily allowance, the
/// request body, and the outbox that keeps reports until the service has them.
final class ProblemReportTests: XCTestCase {

    // MARK: - Scrubbing

    func testScrubbingTakesOutWhatIsTheirsAndKeepsTheReadings() {
        let line = #"11-08 09:14:02.118  PLAY "Dinner with Sam"  local playing@1.00x"#
        XCTAssertEqual(ReportScrubber.scrub(line), "11-08 09:14:02.118  PLAY ‹›  local playing@1.00x")

        XCTAssertEqual(ReportScrubber.scrub("🔎 food search  “oat milk latte”: 3 foods"), "🔎 food search  ‹›: 3 foods")
        XCTAssertEqual(ReportScrubber.scrub("signed out: noor@plan.example"), "signed out: ‹›")
        XCTAssertEqual(ReportScrubber.scrub("GET https://gmail.googleapis.com/gmail/v1/users/me/messages/abc?q=from:x failed"),
                       "GET https://gmail.googleapis.com/‹› failed")
        XCTAssertEqual(ReportScrubber.scrub("push token 0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c"), "push token ‹›")
        XCTAssertEqual(ReportScrubber.scrub("call +1 (415) 555-0134 now"), "call ‹› now")
        XCTAssertEqual(ReportScrubber.scrub("account 4111111111111111 charged"), "account ‹› charged")

        // The log's own words and numbers stay.
        let power = "11-08 09:15:00.002  ⚡ POWER 60s  cpu=12.5% avg/40.1% max mem=512MB wakeups=1234 syscalls=12345678 csw=9876543"
        XCTAssertEqual(ReportScrubber.scrub(power), power)
        let storm = "11-08 09:15:00.002  🌀 STORM: occurrences↻ at 154/s  cpu=92% over 15s — occurrences↻×2310 TodayView×2290"
        XCTAssertEqual(ReportScrubber.scrub(storm), storm)
        XCTAssertEqual(ReportScrubber.scrub("day 2026-11-08 read"), "day 2026-11-08 read")
        XCTAssertEqual(ReportScrubber.scrub("id 3F2504E0-4F89-11D3-9A0C-0305E82C3301"), "id 3F2504E0-4F89-11D3-9A0C-0305E82C3301")
    }

    func testMarkedValuesGoWhateverTheyLookLike() {
        let title = ReportScrubber.mark("Pick up Lina")   // what PlaybackDiagnostics.personal writes
        let line = "↻ missed  \(title): moved on to Nov 9, 3 missed"
        // Reads as it is in the local log…
        XCTAssertTrue(line.contains("Pick up Lina"))
        // …and is gone from a report.
        XCTAssertEqual(ReportScrubber.scrub(line), "↻ missed  ‹›: moved on to Nov 9, 3 missed")
        // A mark inside the value can't end the span early; an unclosed mark takes the rest.
        XCTAssertEqual(ReportScrubber.scrub("a " + ReportScrubber.mark("x\u{2069}y") + " b"), "a ‹› b")
        XCTAssertEqual(ReportScrubber.scrub("a \u{2068}secret"), "a ‹›")
        XCTAssertEqual(ReportScrubber.scrub(lines: (1...300).map { "line \($0)" }).count, 200)
        XCTAssertEqual(ReportScrubber.scrub(lines: (1...300).map { "line \($0)" }).last, "line 300")
    }

    // MARK: - Allowance

    func testAKindGoesThreeTimesADay() {
        var allowance = ProblemReportAllowance()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertEqual((0..<5).map { _ in allowance.take("storm", now: morning, calendar: calendar) }, [true, true, true, false, false])
        XCTAssertTrue(allowance.take("hang", now: morning, calendar: calendar), "each kind has its own")
        let tomorrow = morning.addingTimeInterval(86_400)
        XCTAssertTrue(allowance.take("storm", now: tomorrow, calendar: calendar), "a new day starts again")
    }

    // MARK: - The request

    private let device = ProblemReport.Device(platform: "iphone", channel: "testflight", variant: "beta",
                                              version: "1.0 (84)", os: "27.1", model: "iPhone18,1")

    func testTheBodyIsWhatTheServiceTakes() throws {
        var report = ProblemReport(kind: .problem, page: "mail", note: "  The table is squashed \n")
        report.context = ["messageId": .text("18c2f0a1"), "messageIds": .list(["18c2f0a1", "18c2f0a0"]), "included": .flag(true)]
        report.numbers = ["seconds": .number(2.5)]
        report.attachments = [ProblemReport.Attachment(name: .mailHTML, type: "text/html", data: Data("<p>Hi</p>".utf8))]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(report.body(device: device))) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "problem")
        XCTAssertEqual(json["page"] as? String, "mail")
        XCTAssertEqual(json["note"] as? String, "The table is squashed")
        XCTAssertEqual(json["variant"] as? String, "beta")
        XCTAssertEqual(json["device"] as? String, "iPhone18,1")
        XCTAssertNil(json["detector"])
        XCTAssertEqual((json["numbers"] as? [String: Any])?["seconds"] as? Double, 2.5)
        XCTAssertEqual((json["context"] as? [String: Any])?["messageIds"] as? [String], ["18c2f0a1", "18c2f0a0"])
        XCTAssertEqual((json["context"] as? [String: Any])?["included"] as? Bool, true)
        let attachment = try XCTUnwrap((json["attachments"] as? [[String: String]])?.first)
        XCTAssertEqual(attachment["name"], "mail-html")
        XCTAssertEqual(attachment["data"].flatMap { Data(base64Encoded: $0) }, Data("<p>Hi</p>".utf8))

        var spike = ProblemReport(kind: .spike, detector: .metricKitCrash, signature: String(repeating: "x", count: 400), page: "nowhere")
        spike.note = "   "
        let spikeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(spike.body(device: device))) as? [String: Any])
        XCTAssertEqual(spikeJSON["detector"] as? String, "metrickit-crash")
        XCTAssertEqual((spikeJSON["signature"] as? String)?.count, 300)
        XCTAssertEqual(spikeJSON["page"] as? String, "other", "a page off the list")
        XCTAssertNil(spikeJSON["note"], "an empty note isn't sent")
        XCTAssertNil(spikeJSON["attachments"])
    }

    func testALongTextKeepsItsEnd() throws {
        let text = String(repeating: "a", count: 300 * 1024) + "the end"
        let attachment = try XCTUnwrap(ProblemReport.Attachment.text(.log, text))
        XCTAssertEqual(attachment.data.count, ProblemReport.Attachment.Name.log.most)
        XCTAssertTrue(String(decoding: attachment.data, as: UTF8.self).hasSuffix("the end"))
        XCTAssertNil(ProblemReport.Attachment.text(.log, ""))
    }

    func testTheRequestIsAnonymous() throws {
        let request = ProblemReportOutbox.request(body: Data("{}".utf8), host: "service.test")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://service.test/v1/reports")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testValuesRoundTrip() throws {
        let values: [String: ProblemReport.Value] = ["a": .number(1.5), "b": .flag(false), "c": .text("x"), "d": .list(["y"])]
        XCTAssertEqual(try JSONDecoder().decode([String: ProblemReport.Value].self, from: JSONEncoder().encode(values)), values)
    }

    // MARK: - The outbox

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("problem-reports-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private final class FakeService: @unchecked Sendable {
        private let lock = NSLock()
        var answers: [Int?] = []
        private(set) var ids: [String] = []
        func take(_ request: URLRequest) -> Int? {
            lock.lock(); defer { lock.unlock() }
            if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                ids.append(json["id"] as? String ?? "?")
            }
            return answers.isEmpty ? 204 : answers.removeFirst()
        }
    }

    func testReportsWaitUntilTheServiceHasThem() async throws {
        let outbox = ProblemReportOutbox(folder: folder())
        let service = FakeService()
        let transport: ProblemReportOutbox.Transport = { service.take($0) }
        let first = ProblemReport(id: "first-0001", kind: .problem, page: "plan")
        let second = ProblemReport(id: "second-0001", kind: .spike, detector: .storm, page: "plan")
        await outbox.add(first, device: device)
        await outbox.add(second, device: device)

        // Offline: nothing is lost, and the next try waits.
        service.answers = [nil]
        let now = Date()
        let offline = await outbox.send(host: "service.test", transport: transport, now: now, automatic: true)?.value
        XCTAssertEqual(offline, 0)
        let waiting = await outbox.waiting()
        XCTAssertEqual(waiting, ["first-0001", "second-0001"])
        let tooSoon = await outbox.send(host: "service.test", transport: transport, now: now.addingTimeInterval(5), automatic: true)
        XCTAssertNil(tooSoon, "backs off after a failure")

        // Back online, a minute later: both go, oldest first.
        let sent = await outbox.send(host: "service.test", transport: transport, now: now.addingTimeInterval(61), automatic: true)?.value
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(service.ids, ["first-0001", "first-0001", "second-0001"])
        let empty = await outbox.waiting()
        XCTAssertEqual(empty, [])
    }

    func testRefusedAsNotOursIsNotSentAgain() async throws {
        let outbox = ProblemReportOutbox(folder: folder())
        let service = FakeService()
        service.answers = [400]
        await outbox.add(ProblemReport(id: "bad-00001", kind: .problem, page: "plan"), device: device)
        _ = await outbox.send(host: "service.test", transport: { service.take($0) }, automatic: true)?.value
        let waiting = await outbox.waiting()
        XCTAssertEqual(waiting, [])
    }

    func testWithShareUsageOffOnlyThePersonsOwnGo() async throws {
        let outbox = ProblemReportOutbox(folder: folder())
        let service = FakeService()
        await outbox.add(ProblemReport(id: "spike-0001", kind: .spike, detector: .cpu, page: "plan"), device: device)
        await outbox.add(ProblemReport(id: "mine-00001", kind: .problem, page: "mail"), device: device)
        _ = await outbox.send(host: "service.test", transport: { service.take($0) }, automatic: false)?.value
        XCTAssertEqual(service.ids, ["mine-00001"])
        await outbox.discard(automaticOnly: true)
        let waiting = await outbox.waiting()
        XCTAssertEqual(waiting, [])
    }

    func testAFullOutboxLetsAutomaticReportsGoFirst() async throws {
        let outbox = ProblemReportOutbox(folder: folder())
        await outbox.add(ProblemReport(id: "mine-00000", kind: .problem, page: "mail"), device: device)
        for n in 1...ProblemReportOutbox.mostWaiting {
            await outbox.add(ProblemReport(id: "spike-\(String(format: "%04d", n))", kind: .spike, detector: .cpu, page: "plan"), device: device)
        }
        let waiting = await outbox.waiting()
        XCTAssertEqual(waiting.count, ProblemReportOutbox.mostWaiting)
        XCTAssertEqual(waiting.first, "mine-00000", "his own report stays")
        XCTAssertFalse(waiting.contains("spike-0001"), "the oldest spike made room")
    }

    func testTheAllowanceOutlivesTheProcess() async throws {
        let place = folder()
        let outbox = ProblemReportOutbox(folder: place)
        for _ in 0..<3 { _ = await outbox.allow("storm") }
        let again = ProblemReportOutbox(folder: place)
        let allowed = await again.allow("storm")
        XCTAssertFalse(allowed)
    }

    // MARK: - The main thread's stack

    func testTheMainThreadsStackIsReadWhileItWaits() throws {
        MainThreadSampler.remember()
        let done = DispatchSemaphore(value: 0)
        var sample: String?
        DispatchQueue.global().async {
            usleep(100_000)   // the main thread is in the wait below by now
            sample = MainThreadSampler.sample()
            done.signal()
        }
        done.wait()
        let text = try XCTUnwrap(sample, "no stack")
        let frames = text.split(separator: "\n").prefix { !$0.isEmpty }
        XCTAssertGreaterThan(frames.count, 3, text)
        XCTAssertTrue(text.contains("Binary images:"), text)
        XCTAssertTrue(text.contains("libsystem_kernel") || text.contains("libdispatch"), "it was waiting: \(text)")
        XCTAssertNil(MainThreadSampler.sample().flatMap { _ in "read on the main thread" }, "it never reads its own thread")
    }
}
