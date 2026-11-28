/// Isolated store boundaries for the real GoogleCalendarService scoped window implementation.
/// The selected account is a reader of an opted-in shared calendar which another account owns.
import Foundation

struct GoogleAccountCredential: Equatable {
    let email: String
    var id: String { email }
    let cloudOnly: Bool? = nil
}
struct GoogleCalendar {
    let id: String
    let accountEmail: String
    var accessRole: String? = "reader"
    var isDeleted = false
    var isHidden = false
}
enum GoogleCalendarReadAuthorization: Equatable {
    case direct(String)
    case cloud(email: String, context: String)
}
struct GoogleEvent {
    var id: String?
    var status: String? = nil
    var transparency: String? = nil
}
enum GoogleCalendarError: Error { case malformedResponse }
enum GoogleCalendarDates { static func range(of event: GoogleEvent) -> DateInterval? { DateInterval() } }
struct GoogleFetchedEvent { let calendarID: String; let event: GoogleEvent }
enum AllDayEvents { struct Choice {} }
struct CalendarEventWindow { let conflicts: [String]; static let empty = Self(conflicts: []) }
struct GoogleWindowFetch {
    let window: CalendarEventWindow
    let isComplete: Bool
    let problems: [String]
    let covered: Set<String>
}
@MainActor final class FeatureAccessStore {
    static let shared = FeatureAccessStore()
    var calendarReadContext: String?
}
enum BananaAccount { static func requiresCloudCalendar(email: String) async throws -> Bool { false } }

@MainActor final class GoogleCalendarService {
    static let owner = "owner@plan.example"
    static let other = "another@plan.example"
    var restorationFinished = true
    var accounts = [GoogleAccountCredential(email: owner), GoogleAccountCredential(email: other)]
    var accountsNeedingReconnect: Set<String> = [other]
    var listReads: [String] = []
    var sharedRole = "reader"
    static var eventReads: [(String, GoogleCalendarReadAuthorization)] = []

    static func calendarInfoID(_ id: String) -> String { id }
    func accessToken(for account: GoogleAccountCredential) async throws -> String { account.email }
    func calendars(for account: GoogleAccountCredential, explicitCoverage: Bool) async throws -> [GoogleCalendar] {
        precondition(explicitCoverage)
        listReads.append(account.id)
        return [
            GoogleCalendar(id: "primary", accountEmail: account.id),
            GoogleCalendar(id: "shared", accountEmail: account.id, accessRole: sharedRole),
            GoogleCalendar(id: "excluded", accountEmail: account.id),
            GoogleCalendar(id: "hidden", accountEmail: account.id, isHidden: true)
        ]
    }
    static func eventsListURL(calendarID: String, from: Date, to: Date) -> URL {
        URL(fileURLWithPath: "/").appendingPathComponent(calendarID)
    }
    struct Page { let events: [GoogleEvent] }
    static func fetchAllPages(firstPage: URL, authorization: GoogleCalendarReadAuthorization,
                              explicitCoverage: Bool) async throws -> Page {
        precondition(explicitCoverage)
        let calendar = firstPage.lastPathComponent
        eventReads.append((calendar, authorization))
        return Page(events: calendar == "shared" ? [GoogleEvent(id: "conflict")] : [])
    }
    func buildCalendarWindow(_ events: [GoogleFetchedEvent], included: [GoogleCalendar],
                             from: Date, to: Date, allDay: AllDayEvents.Choice?) async -> CalendarEventWindow {
        CalendarEventWindow(conflicts: events.compactMap { $0.event.id })
    }

    static func prove() async {
        let service = GoogleCalendarService()
        for context in [nil, "selected-cloud"] as [String?] {
            FeatureAccessStore.shared.calendarReadContext = context
            eventReads = []
            let result = await service.composerWindowFetch(from: .distantPast, to: .distantFuture,
                                                           excluding: ["excluded"], allDay: nil, account: owner)
            let authorization = context.map { GoogleCalendarReadAuthorization.cloud(email: owner, context: $0) } ?? .direct(owner)
            precondition(result.isComplete && result.covered == ["primary", "shared"])
            precondition(result.window.conflicts == ["conflict"])
            precondition(Set(eventReads.map { $0.0 }) == ["primary", "shared"])
            precondition(eventReads.allSatisfy { $0.1 == authorization })
        }
        service.sharedRole = "none"
        eventReads = []
        let denied = await service.composerWindowFetch(from: .distantPast, to: .distantFuture,
                                                       excluding: [], allDay: nil, account: owner)
        precondition(!denied.isComplete && denied.covered.isEmpty && eventReads.isEmpty)
        precondition(service.listReads == [owner, owner, owner])
    }
}
@main enum ScopeContracts {
    static func main() async {
        await GoogleCalendarService.prove()
        print("Scoped shared-calendar conflict, foreign sign-out, selected grant and missing-grant controls passed")
    }
}
