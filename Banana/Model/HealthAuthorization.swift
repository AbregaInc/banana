import Foundation

/// HealthKit's synchronous permission read waits for another process. Keep that
/// wait off the caller's actor, even when a view starts it from the main actor.
enum HealthAuthorization {
    static func read<Status: Sendable>(_ query: @escaping @Sendable () -> Status) async -> Status {
        await Task.detached(priority: .utility, operation: query).value
    }
}
