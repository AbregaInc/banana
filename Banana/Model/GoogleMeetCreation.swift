import Foundation

/// Conference creation is asynchronous. A saved event is not proof that its Meet link exists.
enum GoogleMeetCreation {
    enum State: Equatable { case ready, pending, failed }
    enum Failure: LocalizedError {
        case unsupported, conflictingLink, pending, failed
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This calendar does not support Google Meet. Choose another Google calendar."
            case .conflictingLink: return "Remove the existing video link before adding Google Meet."
            case .pending: return "The event is saved, but Google Meet is still being created. Retry to check the same event."
            case .failed: return "The event is saved, but Google could not create its Meet link. Retry to add Meet to the same event."
            }
        }
    }

    static func conference(requestID: UUID) -> [String: Any] {
        ["createRequest": ["requestId": requestID.uuidString.lowercased(),
                           "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
    }

    static func state(videoURL: String?, statusCode: String?) -> State {
        if let videoURL, let url = URL(string: videoURL), url.scheme == "https", url.host == "meet.google.com" {
            return .ready
        }
        return statusCode == "pending" || statusCode == "success" ? .pending : .failed
    }

    @MainActor
    static func complete(initial: State, retryCreation: () async throws -> State,
                         poll: () async throws -> State,
                         pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async throws {
        var state = initial
        // A confirmed failure needs a NEW conference request, but never another event.
        if state == .failed { state = try await retryCreation() }
        for _ in 0..<6 {
            if state == .ready { return }
            if state == .failed { throw Failure.failed }
            try await pause()
            state = try await poll()
        }
        if state == .ready { return }
        throw state == .failed ? Failure.failed : Failure.pending
    }
}
