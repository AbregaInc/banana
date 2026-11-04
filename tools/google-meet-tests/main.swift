import Foundation

@main struct MeetChecks {
    @MainActor static func main() async throws {
        let id = UUID()
        let first = GoogleMeetCreation.conference(requestID: id)
        let second = GoogleMeetCreation.conference(requestID: id)
        assert(NSDictionary(dictionary: first).isEqual(to: second))
        let request = first["createRequest"] as! [String: Any]
        assert(request["requestId"] as? String == id.uuidString.lowercased())
        assert((request["conferenceSolutionKey"] as? [String: String])?["type"] == "hangoutsMeet")
        assert(GoogleMeetCreation.state(videoURL: "https://meet.google.com/abc-defg-hij", statusCode: "pending") == .ready)
        assert(GoogleMeetCreation.state(videoURL: nil, statusCode: "pending") == .pending)
        assert(GoogleMeetCreation.state(videoURL: nil, statusCode: "success") == .pending)
        assert(GoogleMeetCreation.state(videoURL: "https://example.com", statusCode: "failure") == .failed)
        var polls = 0, retries = 0
        try await GoogleMeetCreation.complete(initial: .ready, retryCreation: { retries += 1; return .failed }, poll: { polls += 1; return .failed }, pause: {})
        assert(polls == 0 && retries == 0)
        try await GoogleMeetCreation.complete(initial: .pending, retryCreation: { retries += 1; return .failed }, poll: { polls += 1; return polls == 2 ? .ready : .pending }, pause: {})
        assert(polls == 2 && retries == 0)
        try await GoogleMeetCreation.complete(initial: .failed, retryCreation: { retries += 1; return .ready }, poll: { fatalError("No poll for a completed retry") }, pause: {})
        assert(retries == 1)
        do {
            try await GoogleMeetCreation.complete(initial: .failed, retryCreation: { .failed }, poll: { .ready }, pause: {})
            fatalError("Failure was silently accepted")
        } catch GoogleMeetCreation.Failure.failed {}
        polls = 0
        do {
            try await GoogleMeetCreation.complete(initial: .pending, retryCreation: { fatalError("Do not replace pending conferences") }, poll: { polls += 1; return .pending }, pause: {})
            fatalError("Timeout was silently accepted")
        } catch GoogleMeetCreation.Failure.pending {}
        assert(polls == 6)
        do {
            try await GoogleMeetCreation.complete(initial: .pending, retryCreation: { .ready }, poll: { .ready }, pause: { throw CancellationError() })
            fatalError("Cancellation was swallowed")
        } catch is CancellationError {}
        print("PASS: stable requests, response states, bounded polling, conference-only retry, failure retention and cancellation")
    }
}
