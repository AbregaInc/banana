#if !BANANA_PUBLIC
import Foundation
import Combine

/// One invitation's cancellable lookup. Late replies cannot replace another account's card.
@MainActor
final class MailInviteLookup: ObservableObject {
    enum Phase: Equatable {
        case loading, missing, failed
        case ready(MailInviteEvent)
    }
    @Published private(set) var phase = Phase.loading
    private var generation = 0

    func load(account: String, uid: String,
              find: @MainActor (String, String) async throws -> MailInviteEvent?) async {
        generation += 1
        let request = generation
        phase = .loading
        do {
            let event = try await find(account, uid)
            guard request == generation, !Task.isCancelled else { return }
            phase = event.map(Phase.ready) ?? .missing
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            phase = .failed
        }
    }

    /// Search only calendars owned by the connected account, never shared calendars belonging
    /// to somebody else. The authenticated primary calendar remains eligible before its list loads.
    static func calendarIDs(account: String, calendars: [GoogleCalendar]) -> [String] {
        let account = account.lowercased()
        return [account] + Set(calendars.filter {
            $0.accountEmail.lowercased() == account && $0.accessRole == "owner" && $0.deleted != true && $0.id != account
        }.map(\.id)).sorted()
    }

    static func find(uid: String, calendars: [String],
                     cachedAfterFailure: @MainActor (String, Error) -> [GoogleEvent] = { _, _ in [] },
                     fetch: @MainActor (String) async throws -> [GoogleEvent]) async throws -> MailInviteEvent? {
        guard !uid.isEmpty else { return nil }
        var failures: [(calendar: String, error: Error)] = []
        for calendar in calendars {
            try Task.checkCancellation()
            do {
                if let event = MailInviteEvent.pick(try await fetch(calendar), calendarID: calendar) { return event }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                failures.append((calendar, error))
            }
        }
        // Prefer a live match anywhere over a cached one. A successful empty response
        // is authoritative for that calendar, so only failed reads can use its cache.
        for (calendar, error) in failures {
            try Task.checkCancellation()
            let matches = cachedAfterFailure(calendar, error).filter { $0.iCalUID == uid }
            if let event = MailInviteEvent.pick(matches, calendarID: calendar) { return event }
        }
        if let failure = failures.first { throw failure.error }
        return nil
    }
}
#endif
