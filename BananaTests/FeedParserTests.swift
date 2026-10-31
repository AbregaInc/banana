import XCTest

final class FeedParserTests: XCTestCase {
    private let url = URL(string: "https://feed.example.test/rss")!
    private let feed = Data("""
    <rss version="2.0"><channel><title>Test show</title><item><guid>one</guid>
    <title>One</title><enclosure url="https://feed.example.test/one.mp3" type="audio/mpeg" length="100"/>
    </item></channel></rss>
    """.utf8)

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedStatusProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testErrorResponseCannotReplaceASavedFeedEvenWithValidRSS() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for status in [401, 403, 404, 429, 500, 503] {
            FeedStatusProtocol.response = (status, feed)
            do {
                _ = try await FeedParser.load(url, session: session)
                XCTFail("HTTP \(status) must not publish a fresh feed")
            } catch let error as FeedError {
                guard case .network(let message) = error else { return XCTFail("Expected HTTP failure, got \(error)") }
                XCTAssertTrue(message.contains(String(status)))
            }
        }
    }

    func testNotModifiedDoesNotParseItsEmptyBody() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        FeedStatusProtocol.response = (304, Data())
        guard case .unchanged = try await FeedParser.load(url, etag: "test", session: session) else {
            return XCTFail("304 must keep the existing catalogue")
        }
    }

    func testSuccessParsesTheFeedAndKeepsItsValidators() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        FeedStatusProtocol.response = (200, feed)
        guard case let .fresh(parsed, etag, _) = try await FeedParser.load(url, session: session) else {
            return XCTFail("Expected a parsed feed")
        }
        XCTAssertEqual(parsed.title, "Test show")
        XCTAssertEqual(parsed.episodes.count, 1)
        XCTAssertEqual(etag, "test")
    }
}

private final class FeedStatusProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedResponse = (200, Data())
    static var response: (Int, Data) {
        get { lock.lock(); defer { lock.unlock() }; return storedResponse }
        set { lock.lock(); defer { lock.unlock() }; storedResponse = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.response
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["ETag": "test"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
