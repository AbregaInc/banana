import XCTest

/// Security audit run-1 (26 Oct 2026): a feed is an untrusted publisher. Its transcript URL is
/// fetched within bounds, and its cue text is parsed in linear time.
final class FeedTranscriptParserTests: XCTestCase {

    // MARK: Tag stripping is linear and keeps an unclosed `<`

    func testStripTagsDropsSpansAndKeepsText() {
        XCTAssertEqual(FeedTranscriptParser.stripTags("<v Ann>Hi <b>there</b>, 1 < 2"), "Hi there, 1 < 2")
        XCTAssertEqual(FeedTranscriptParser.stripTags("plain"), "plain")
        XCTAssertEqual(FeedTranscriptParser.stripTags("<<i>x</i>"), "<x")
        XCTAssertEqual(FeedTranscriptParser.stripTags("a <unclosed"), "a <unclosed")
    }

    /// Linear, not quadratic: four times the input costs about four times the time (a quadratic
    /// pass would cost sixteen). Measured as a ratio so Debug and Release builds both pass.
    func testStripTagsOnARunOfOpeningBracketsIsLinear() {
        func timed(_ n: Int) -> Duration {
            let hostile = String(repeating: "<", count: n)
            let clock = ContinuousClock()
            let start = clock.now
            let out = FeedTranscriptParser.stripTags(hostile)
            let elapsed = clock.now - start
            XCTAssertEqual(out.utf8.count, n)
            return elapsed
        }
        _ = timed(50_000)   // warm up
        let small = timed(100_000), large = timed(400_000)
        // Include whole seconds: the fractional component wraps at each second.
        let smallSeconds = Double(small.components.seconds) + Double(small.components.attoseconds) / 1e18
        let largeSeconds = Double(large.components.seconds) + Double(large.components.attoseconds) / 1e18
        let ratio = largeSeconds / max(Double.leastNonzeroMagnitude, smallSeconds)
        print("transcript tag stripping: 100k=\(smallSeconds)s 400k=\(largeSeconds)s ratio=\(ratio)")
        XCTAssertLessThan(ratio, 8, "400k vs 100k took \(ratio)x; the old regex went quadratic here")
        XCTAssertLessThan(large, .seconds(5))
    }

    func testVoiceName() {
        XCTAssertEqual(FeedTranscriptParser.voiceName(in: "<v Ann Lee>Hello"), "Ann Lee")
        XCTAssertEqual(FeedTranscriptParser.voiceName(in: "  <v.loud Bob>Hello"), "Bob")
        XCTAssertNil(FeedTranscriptParser.voiceName(in: "<b>Hello"))
        XCTAssertNil(FeedTranscriptParser.voiceName(in: "Hello <v Ann>"))
        XCTAssertNil(FeedTranscriptParser.voiceName(in: "<v Ann"))
    }

    func testParsesWebVTTAndSRT() {
        let vtt = "WEBVTT\n\n00:00.000 --> 00:01.500\n<v Ann>Hello <i>there</i>\n\n00:01.500 --> 00:03.000\nSecond cue\n"
        let cues = FeedTranscriptParser.parseTimedText(vtt)
        XCTAssertEqual(cues, [
            .init(start: 0, end: 1.5, text: "Hello there", speaker: "Ann"),
            .init(start: 1.5, end: 3, text: "Second cue", speaker: nil),
        ])
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nFirst\r\n\r\n2\r\n00:00:02,000 --> 00:00:04,000\r\nSecond line\r\nand more\r\n"
        XCTAssertEqual(FeedTranscriptParser.parseTimedText(srt).map(\.text), ["First", "Second line and more"])
        XCTAssertEqual(FeedTranscriptParser.parseTimedText(srt).last?.end, 4)
    }

    func testHostileCueBodyParsesQuickly() {
        let vtt = "WEBVTT\n\n00:00.000 --> 00:01.000\n" + String(repeating: "<", count: 200_000)
        let clock = ContinuousClock()
        let start = clock.now
        let cues = FeedTranscriptParser.parseTimedText(vtt)
        XCTAssertLessThan(clock.now - start, .seconds(5))
        XCTAssertEqual(cues.count, 1)
    }

    func testInterpolateWordsSplitsTheSpanByLength() {
        let words = FeedTranscriptParser.interpolateWords(in: (start: 10, end: 14, text: "ab cdef"), speaker: 2)
        XCTAssertEqual(words.map(\.text), ["ab", "cdef"])
        XCTAssertEqual(words[0].start, 10)
        XCTAssertEqual(words[0].end, 10 + 4.0 * 2 / 6, accuracy: 0.0001)   // 2 of 6 characters
        XCTAssertEqual(words[1].end, 14, accuracy: 0.0001)
        XCTAssertEqual(words[1].speaker, 2)
    }

    // MARK: The fetch is web-only, status-checked, size-capped and time-bounded

    func testOnlyWebURLsAreFetched() async {
        XCTAssertTrue(FeedTranscriptParser.allowed(URL(string: "https://example.com/t.vtt")!))
        XCTAssertTrue(FeedTranscriptParser.allowed(URL(string: "http://example.com/t.vtt")!))
        XCTAssertFalse(FeedTranscriptParser.allowed(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(FeedTranscriptParser.allowed(URL(string: "data:text/vtt,WEBVTT")!))
        XCTAssertFalse(FeedTranscriptParser.allowed(URL(string: "ftp://example.com/t.vtt")!))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).vtt")
        try? "WEBVTT\n\n00:00.000 --> 00:01.000\nx\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let got = await FeedTranscriptParser.fetch(file, session: Self.stubbedSession())
        XCTAssertNil(got, "a file: URL from a feed is never read")
    }

    func testFetchBounds() async {
        let session = Self.stubbedSession()
        let url = URL(string: "https://transcripts.example.test/t.vtt")!

        StubProtocol.handler = { _ in (200, Data("WEBVTT\n".utf8), 7) }
        let small = await FeedTranscriptParser.fetch(url, session: session)
        XCTAssertEqual(small.map { String(decoding: $0, as: UTF8.self) }, "WEBVTT\n")

        StubProtocol.handler = { _ in (500, Data("WEBVTT\n".utf8), 7) }
        let failing = await FeedTranscriptParser.fetch(url, session: session)
        XCTAssertNil(failing, "a non-2xx answer is not a transcript")

        StubProtocol.handler = { _ in (200, Data(count: 16), Int64(FeedTranscriptParser.mostBytes) + 1) }
        let declaredLarge = await FeedTranscriptParser.fetch(url, session: session)
        XCTAssertNil(declaredLarge, "a declared size over the cap is refused before reading")

        StubProtocol.handler = { _ in (200, Data(count: FeedTranscriptParser.mostBytes + 1), nil) }
        let streamedLarge = await FeedTranscriptParser.fetch(url, session: session)
        XCTAssertNil(streamedLarge, "a body over the cap with no declared size stops at the cap")

        StubProtocol.handler = { _ in (200, nil, nil) }   // never finishes
        let clock = ContinuousClock()
        let start = clock.now
        let hung = await FeedTranscriptParser.fetch(url, session: session, timeout: .seconds(1))
        XCTAssertNil(hung)
        XCTAssertLessThan(clock.now - start, .seconds(10), "the fetch gives up at its deadline")
    }

    /// Returning nil must also stop an unfinished server response, not just stop reading it.
    func testRejectedHeadersCancelTheUnderlyingTransfer() async {
        await assertTransferStops("server-error")
        await assertTransferStops("declared-too-large")
    }

    func testStreamedSizeLimitCancelsTheUnderlyingTransfer() async {
        await assertTransferStops("streamed-too-large")
    }

    func testDeadlineCancelsTheUnderlyingTransfer() async {
        await assertTransferStops("never-finishes", deadline: .milliseconds(100))
    }

    private func assertTransferStops(_ kind: String, deadline: Duration = .seconds(45)) async {
        let url = URL(string: "https://transcript-cancellation.example.test/\(kind)/\(UUID().uuidString)")!
        let stopped = expectation(description: "\(kind) transfer was cancelled")
        HeldTranscriptProtocol.observe(url, stopped: stopped)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldTranscriptProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            HeldTranscriptProtocol.forget(url)
            session.invalidateAndCancel()
        }
        let body = await FeedTranscriptParser.fetch(url, session: session, timeout: deadline)
        XCTAssertNil(body)
        await fulfillment(of: [stopped], timeout: 2)
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Answers every request from `handler`: (status, body or nil to never finish, declared Content-Length).
final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data?, Int64?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (status, body, declared) = Self.handler?(request) else { return }
        var headers: [String: String] = ["Content-Type": "text/vtt"]
        if let declared { headers["Content-Length"] = String(declared) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard let body else { return }   // a server that never finishes
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Holds each synthetic response open until the production reader cancels its task.
/// A URL-specific observer prevents cancellation from a previous request satisfying a test.
private final class HeldTranscriptProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiters: [URL: XCTestExpectation] = [:]

    static func observe(_ url: URL, stopped: XCTestExpectation) {
        lock.withLock { waiters[url] = stopped }
    }

    static func forget(_ url: URL) {
        _ = lock.withLock { waiters.removeValue(forKey: url) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let isError = url.path.contains("server-error")
        var headers = ["Content-Type": "text/vtt"]
        if url.path.contains("declared-too-large") {
            headers["Content-Length"] = String(FeedTranscriptParser.mostBytes + 1)
        }
        let response = HTTPURLResponse(url: url, statusCode: isError ? 500 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path.contains("streamed-too-large") {
            client?.urlProtocol(self, didLoad: Data(count: FeedTranscriptParser.mostBytes + 1))
        }
        // No completion: the app, rather than fixture teardown, must close the connection.
    }

    override func stopLoading() {
        guard let url = request.url else { return }
        let stopped = Self.lock.withLock { Self.waiters.removeValue(forKey: url) }
        stopped?.fulfill()
    }
}
