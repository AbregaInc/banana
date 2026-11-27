import Foundation

/// Only one Parakeet job may load or use the shared model, including while its actor is suspended.
actor TranscriptionSlot {
    private var occupied = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func perform<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if occupied {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append((id, continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiting(id) }
            }
        }
        occupied = true
        defer {
            if waiters.isEmpty { occupied = false }
            else { waiters.removeFirst().continuation.resume() }
        }
        try Task.checkCancellation()
        return try await work()
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
