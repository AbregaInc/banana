/// Native integration fixture for the account calendar provider. The runner compiles the
/// composer's production interval and coverage checks against this read-only window.
import Foundation

@MainActor enum AssistantCapabilities {}
@MainActor struct SmartScheduleStore {
    static let shared = Self()
    let settings = Settings()
    struct Settings { let excludedCalendarIDs: Set<String> = []; let allDayChoice = false }
}
@MainActor final class GoogleCalendarService {
    struct Account { let id: String }
    struct Window { let busyIntervals: [DateInterval] }
    struct Read {
        let isComplete: Bool
        let covered: Set<String>
        let window: Window
    }
    static let shared = GoogleCalendarService()
    var accounts = [Account(id: "owner@plan.example")]
    var accountsNeedingReconnect: Set<String> = []
    var hasDegradedSources = false
    var response = Read(isComplete: true, covered: ["primary"], window: .init(busyIntervals: []))
    var requests: [(start: Date, end: Date, account: String?)] = []

    func windowFetch(from start: Date, to end: Date, excluding: Set<String>,
                     allDay: Bool, account: String? = nil) async -> Read {
        requests.append((start, end, account))
        return response
    }
}

@main enum ComposerCalendarContracts {
    @MainActor static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let start = now.addingTimeInterval(150 * 86_400)
        let end = start.addingTimeInterval(1_800)
        let account = "owner@plan.example"
        let service = GoogleCalendarService.shared
        func check(_ s: Date, _ e: Date) async throws -> Bool {
            try await AssistantCapabilities.composerIntervalAvailable(from: s, to: e, account: account, now: now)
        }

        let clear = try await check(start, end)
        precondition(clear && service.requests.count == 1)
        precondition(service.requests[0].start == start && service.requests[0].end == end &&
                     service.requests[0].account == account)

        service.response = .init(isComplete: false, covered: ["primary"], window: .init(busyIntervals: []))
        do { _ = try await check(start, end); fatalError("Incomplete coverage yielded an availability answer") }
        catch let failure as AssistantFailure { precondition(failure.message.contains("entire time window")) }
        precondition(service.requests.count == 2)

        service.response = .init(isComplete: true, covered: [], window: .init(busyIntervals: []))
        do { _ = try await check(start, end); fatalError("No covered calendar yielded an availability answer") }
        catch let failure as AssistantFailure { precondition(failure.message.contains("entire time window")) }

        service.response = .init(isComplete: true, covered: ["primary"],
                                 window: .init(busyIntervals: [DateInterval(start: start, end: end)]))
        let freeDuringBusyInterval = try await check(start, end)
        precondition(!freeDuringBusyInterval)

        service.hasDegradedSources = true
        service.accountsNeedingReconnect = ["another@plan.example"]
        let unrelatedSignOutStillSeesConflict = try await check(start, end)
        precondition(!unrelatedSignOutStillSeesConflict)
        service.response = .init(isComplete: false, covered: [], window: .init(busyIntervals: []))
        do { _ = try await check(start, end); fatalError("Incomplete selected snapshot yielded an answer") }
        catch let failure as AssistantFailure { precondition(failure.message.contains("entire time window")) }
        service.accountsNeedingReconnect = [account]
        do { _ = try await check(start, end); fatalError("Rejected credential yielded an answer") }
        catch let failure as AssistantFailure { precondition(failure.message.hasPrefix("Reconnect this calendar account")) }
        service.accountsNeedingReconnect = []
        service.accounts = []
        do { _ = try await check(start, end); fatalError("Absent account yielded an answer") }
        catch let failure as AssistantFailure { precondition(failure.message.contains("account is unavailable")) }

        let reads = service.requests.count
        do {
            _ = try await check(now.addingTimeInterval(-60), now.addingTimeInterval(60))
            fatalError("A past interval was checked")
        } catch is AssistantFailure {}
        precondition(service.requests.count == reads)
        print("Passed future exact range, complete coverage, partial coverage, empty coverage, conflict and past range")
    }
}
