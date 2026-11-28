import Foundation
#if BANANA_AI && !BANANA_PUBLIC
import CryptoKit
#endif

/// Native descriptors persisted by the Pi extension. Models propose fields; native code validates them.
struct AssistantAction: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case meal, event, note, search, navigation }
    struct Food: Codable, Equatable { var name: String; var quantity: String }
    struct Result: Codable, Equatable, Identifiable {
        var id: String; var title: String; var detail: String; var section: String
    }
    var id: String
    var kind: Kind
    var title: String
    var day: String?
    var foods: [Food]?
    var start: String?
    var end: String?
    var isAllDay: Bool?
    var location: String?
    var notes: String?
    var section: String?
    var query: String?
    var results: [Result]?
    var sourceRequest: String?
    var mailAccessFingerprint: String?
}

struct AssistantWorkspaceState: Decodable {
    var revision: Int
    var action: AssistantAction?
}

#if BANANA_AI
@MainActor
enum AssistantWorkspace {
    static func prepare(_ fields: [String: Any], operation: String, now: Date = Date()) async throws -> AssistantAction {
        guard UUID(uuidString: operation) != nil,
              let raw = fields["kind"] as? String, let kind = AssistantAction.Kind(rawValue: raw) else {
            throw AssistantFailure(message: "That workspace action is invalid.")
        }
        let data = try JSONSerialization.data(withJSONObject: fields.merging(["id": operation, "title": fields["title"] as? String ?? ""]) { _, new in new })
        var action = try JSONDecoder().decode(AssistantAction.self, from: data)
        action.title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard action.title.count <= 200 else { throw AssistantFailure(message: "Use a shorter title.") }
        switch kind {
        case .meal:
            guard let foods = action.foods, (1...12).contains(foods.count), foods.allSatisfy({
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 && !$0.quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.quantity.count <= 80
            }) else { throw AssistantFailure(message: "List one to twelve foods with their amounts for review.") }
            action.day = try day(fields, now: now)
            if action.title.isEmpty { action.title = "New meal" }
        case .event:
            guard !action.title.isEmpty else { throw AssistantFailure(message: "Give the event a title.") }
            if let sourceStart = fields["sourceStart"] as? String, let sourceEnd = fields["sourceEnd"] as? String {
                guard let start = AssistantFreeTime.absoluteTime(sourceStart), let end = AssistantFreeTime.absoluteTime(sourceEnd),
                      start > now, end.timeIntervalSince(start) >= 15 * 60, end.timeIntervalSince(start) <= 24 * 3_600,
                      (action.notes?.count ?? 0) <= 2000 else {
                    throw AssistantFailure(message: "The email needs a valid future event range between 15 minutes and one day.")
                }
                action.day = AssistantNutrition.key(start)
                action.start = start.ISO8601Format()
                action.end = end.ISO8601Format()
                action.isAllDay = false
                break
            }
            let day = try day(fields, now: now)
            let base = try AssistantNutrition.date(day)
            let allDay = action.isAllDay ?? false
            let duration = fields["durationMinutes"] as? Int ?? 60
            guard (15...1440).contains(duration), (action.location?.count ?? 0) <= 300, (action.notes?.count ?? 0) <= 2000 else {
                throw AssistantFailure(message: "Choose a duration between 15 minutes and one day, and shorter event details.")
            }
            var start = base
            if !allDay {
                guard let time = fields["time"] as? String else { throw AssistantFailure(message: "What time should the event start?") }
                let pieces = time.split(separator: ":", omittingEmptySubsequences: false)
                guard pieces.count == 2, pieces[0].count == 2, pieces[1].count == 2,
                      let hour = Int(pieces[0]), let minute = Int(pieces[1]), (0...23).contains(hour), (0...59).contains(minute),
                      let date = AssistantNutrition.calendar().date(bySettingHour: hour, minute: minute, second: 0, of: base),
                      AssistantNutrition.calendar().component(.hour, from: date) == hour,
                      AssistantNutrition.calendar().component(.minute, from: date) == minute else {
                    throw AssistantFailure(message: "Use a valid local start time in HH:mm format.")
                }
                start = date
                // An omitted day means the next occurrence of this clock time.
                // Explicit dates (including today) retain the user's choice.
                if fields["day"] == nil && fields["relativeDay"] == nil && start <= now {
                    guard let next = AssistantNutrition.calendar().nextDate(after: now,
                        matching: DateComponents(hour: hour, minute: minute, second: 0),
                        matchingPolicy: .nextTime) else {
                        throw AssistantFailure(message: "Choose a date for this event.")
                    }
                    start = next
                }
            }
            let end = allDay ? AssistantNutrition.calendar().date(byAdding: .day, value: 1, to: base)! : start.addingTimeInterval(Double(duration) * 60)
            action.day = AssistantNutrition.key(start); action.start = start.ISO8601Format(); action.end = end.ISO8601Format(); action.isAllDay = allDay
        case .note:
            let text = (action.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 4000 else { throw AssistantFailure(message: "A note needs between 1 and 4,000 characters.") }
            action.notes = text
            action.title = "New note"
        case .navigation:
            guard let raw = action.section, let section = AppSection(rawValue: raw) else { throw AssistantFailure(message: "Choose a Banana page to open.") }
            if section == .mail, !ModuleStore.shared.includes(.email) {
                throw AssistantFailure(message: "Email is unavailable in this build or is turned off.")
            }
            action.title = section.title
        case .search:
            let query = (action.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.count <= 120 else { throw AssistantFailure(message: "Enter a short search phrase.") }
            action.query = query; action.title = "Results for “\(query)”"
            if action.section == AppSection.plan.rawValue {
                action.results = calendarSearch(query)
            } else {
                action.results = await search(query)
            }
        }
        return action
    }

    private static func day(_ fields: [String: Any], now: Date) throws -> String {
        let requested = fields["day"] as? String ?? fields["relativeDay"] as? String ?? "today"
        switch requested {
        case "today": return AssistantNutrition.key(now)
        case "tomorrow": return AssistantNutrition.key(AssistantNutrition.calendar().date(byAdding: .day, value: 1, to: now)!)
        case "yesterday": return AssistantNutrition.key(AssistantNutrition.calendar().date(byAdding: .day, value: -1, to: now)!)
        default:
            _ = try AssistantNutrition.date(requested)
            return requested
        }
    }

    static func mealItems(_ action: AssistantAction) -> [ResolvedFoodItem] {
        (action.foods ?? []).map { food in
            let input = ExtractedFoodItem(name: food.name, quantityPhrase: food.quantity,
                estimatedCalories: 0, estimatedProteinGrams: 0, estimatedCarbGrams: 0, estimatedFatGrams: 0)
            var resolved = FoodTextExtractor.resolve(input, learned: WellnessStore.shared.learnedLookup())
            // An unknown food has editable blanks, not an asserted zero-calorie estimate.
            if resolved.source == .aiEstimate { resolved.source = .manual; resolved.confidence = 0 }
            return resolved
        }
    }

    static func routedState(_ section: AppSection, itemID: String?, from state: ShellState, meals: [MealEntry]) -> ShellState {
        var result = state
        if let itemID {
            let pieces = itemID.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2, let id = UUID(uuidString: pieces[1]) {
                if section == .notes, pieces[0] == "note" { result.notes = [id] }
                if section == .library, pieces[0] == "podcast" { result.library = [id] }
                if section == .workouts, pieces[0] == "workout" { result.workouts = [.workout("s-\(id.uuidString)")] }
                if section == .nutrition, pieces[0] == "meal", let meal = meals.first(where: { $0.id == id }) {
                    result.nutritionDay = meal.date
                    result.nutritionSection = "food"
                }
            }
        }
        return result
    }

    #if !BANANA_PUBLIC
    static var mailAccessFingerprint: String? {
        guard ModuleStore.shared.includes(.email), let scope = FeatureAccessStore.shared.mailContext else { return nil }
        return SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func readyMail(_ scope: String) async throws -> MailLiveSource {
        guard let session = await MailApplication.shared.readySession(),
              let source = session.source as? MailLiveSource,
              ModuleStore.shared.includes(.email), FeatureAccessStore.shared.mailContext == scope else {
            throw AssistantFailure(message: "Email isn’t ready. Open Email and try again.")
        }
        return source
    }

    private static func mailSearchContext(_ fields: [String: Any]) async throws
        -> (source: MailLiveSource, filter: LiveFilter, scope: String, fingerprint: String) {
        guard let scope = FeatureAccessStore.shared.mailContext, let fingerprint = mailAccessFingerprint else {
            throw AssistantFailure(message: "Connect Email before searching the mailbox.")
        }
        var filter = LiveFilter(scope: "mail")
        for (field, key) in [("text", "query"), ("person", "sender"), ("date", "period")] {
            guard let value = (fields[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            guard value.count <= 120 else { throw AssistantFailure(message: "Use a shorter email search.") }
            filter.terms.append(.init(field: field, op: field == "date" ? "in" : "contains", value: value))
        }
        if let unread = fields["unread"] as? Bool {
            filter.terms.append(.init(field: "unread", op: "is", value: String(unread)))
        }
        guard filter.canRun, !filter.isEmpty,
              filter.terms.allSatisfy({ !["text", "person"].contains($0.field) || $0.value.contains(where: { $0.isLetter || $0.isNumber }) }) else {
            throw AssistantFailure(message: "Give me a sender, a few keywords, or a date range.")
        }
        return (try await readyMail(scope), filter, scope, fingerprint)
    }

    static func searchMail(_ fields: [String: Any], operation: String) async throws -> AssistantAction {
        guard UUID(uuidString: operation) != nil else { throw AssistantFailure(message: "Email search couldn’t start.") }
        let (source, filter, scope, fingerprint) = try await mailSearchContext(fields)
        let matches = try await source.assistantSearch(filter)
        guard ModuleStore.shared.includes(.email), FeatureAccessStore.shared.mailContext == scope else {
            throw AssistantFailure(message: "Email access changed. Try the search again.")
        }
        let results = matches.map { row in
            AssistantAction.Result(id: "mail:" + MailConversationID(account: row.account, thread: row.thread).text,
                title: row.subject.isEmpty ? "(No subject)" : row.subject,
                detail: Date(timeIntervalSince1970: Double(row.lastDate) / 1000).formatted(date: .abbreviated, time: .omitted),
                section: AppSection.mail.rawValue)
        }
        return AssistantAction(id: operation, kind: .search, title: "Email results on this device",
            section: AppSection.mail.rawValue, query: filter.searchExpression, results: results, mailAccessFingerprint: fingerprint)
    }
    static func readMailThread(_ fields: [String: Any]) async throws -> String {
        let (source, filter, scope, _) = try await mailSearchContext(fields)
        guard !filter.text.isEmpty else {
            throw AssistantFailure(message: "Tell me a thread subject or a few words from the email.")
        }
        let evidence = try await source.assistantThreadEvidence(filter, selectionKey: fields["selectionKey"] as? String)
        guard ModuleStore.shared.includes(.email), FeatureAccessStore.shared.mailContext == scope else {
            throw AssistantFailure(message: "Email access changed. Try the search again.")
        }
        return String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
    }
    static func readMailInbox(unread: Bool) async throws -> String {
        guard ModuleStore.shared.includes(.email), let scope = FeatureAccessStore.shared.mailContext else {
            throw AssistantFailure(message: "Connect Email before checking the inbox.")
        }
        let source = try await readyMail(scope)
        let evidence = try await source.assistantInbox(unread: unread)
        guard ModuleStore.shared.includes(.email), FeatureAccessStore.shared.mailContext == scope else {
            throw AssistantFailure(message: "Email access changed. Try again.")
        }
        return String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
    }
    #endif

    static func open(_ section: AppSection, itemID: String? = nil, mailQuery: String? = nil) {
        guard section != .mail || ModuleStore.shared.includes(.email) else { return }
        let shell = ShellNavigation.shared
        shell.state = routedState(section, itemID: itemID, from: shell.state, meals: WellnessStore.shared.meals)
        if section == .plan, let itemID, itemID.hasPrefix("plan:"),
           let occurrence = OccurrenceStore.shared.occurrences.first(where: { $0.id == String(itemID.dropFirst(5)) }) {
            let route = occurrence.meeting?.eventID.flatMap(GoogleCalendarIDs.rawEventRoute(from:))
            PlanOpenRequests.shared.pending = .init(calendarID: route?.calendarID, eventID: route?.eventID, start: occurrence.start)
        }
        #if !BANANA_PUBLIC
        if section == .mail, let mailQuery, FeatureAccessStore.shared.mailContext != nil,
           let session = MailApplication.shared.session {
            let scope = MailScope(place: .search(mailQuery))
            if let itemID, itemID.hasPrefix("mail:"),
               let conversation = MailConversationID(text: String(itemID.dropFirst(5))),
               session.source.accounts.contains(where: { $0.id == conversation.account && $0.state == .connected }) {
                ShellMailOpener.open(conversation, scope: scope)
            } else if itemID == nil {
                session.switchTo(scope)
            }
        }
        #endif
        #if os(iOS)
        if PageChrome.shared.showAssistant {
            PageChrome.shared.assistantDestination = section
            PageChrome.shared.showAssistant = false
            return
        }
        #endif
        NotificationCenter.default.post(name: .assistantOpenSection, object: section.rawValue)
    }

    private static func calendarSearch(_ query: String) -> [AssistantAction.Result] {
        ShellSearch.matchingPlanOccurrences(query, limit: 6).map { occurrence in
            let date = occurrence.hasScheduledTime && occurrence.behavior != .allDay
                ? occurrence.start.formatted(date: .abbreviated, time: .shortened)
                : occurrence.start.formatted(date: .abbreviated, time: .omitted)
            return AssistantAction.Result(id: "plan:\(occurrence.id)", title: occurrence.title,
                                          detail: date, section: AppSection.plan.rawValue)
        }
    }

    private static func search(_ query: String) async -> [AssistantAction.Result] {
        var results: [AssistantAction.Result] = []
        var counts: [AppSection: Int] = [:]
        func add(_ id: String, _ title: String, _ detail: String, _ section: AppSection, matched: Bool = false) {
            guard results.count < 30, counts[section, default: 0] < 6,
                  matched || (title + " " + detail).localizedStandardContains(query) else { return }
            counts[section, default: 0] += 1
            results.append(.init(id: id, title: title, detail: String(detail.prefix(240)), section: section.rawValue))
        }
        for note in await VoiceNoteStore.shared.searchResults(query, limit: 6) {
            let text = note.transcript ?? ""; add("note:\(note.id)", note.displayTitle, text, .notes, matched: true)
        }
        for meal in WellnessStore.shared.meals.sorted(by: { $0.date > $1.date }) {
            // A result is named by what it is ("Chicken grain bowl, Greek yogurt"), not by its kind.
            let foods = meal.items.map(\.name).joined(separator: ", ")
            add("meal:\(meal.id)", meal.name.isEmpty ? foods : meal.name,
                meal.date.formatted(.dateTime.month(.abbreviated).day()) + " · \(Int(meal.totals.calories.rounded())) kcal"
                    + (meal.name.isEmpty ? "" : " · " + foods), .nutrition)
        }
        for workout in FitnessStore.shared.summaries {
            add("workout:\(workout.id)", workout.activity, workout.start.formatted(), .workouts)
        }
        for routine in RoutineStore.shared.routines { add("routine:\(routine.id)", routine.name, "Routine", .routines) }
        for podcast in WakeCoordinator.shared.library.podcasts { add("podcast:\(podcast.id)", podcast.title, "Podcast", .library) }
        for occurrence in OccurrenceStore.shared.occurrences { add("plan:\(occurrence.id)", occurrence.title, occurrence.start.formatted(), .plan) }
        for section in AppSection.macSidebar { add("page:\(section.id)", section.title, "Banana page", section) }
        return results
    }
}

#endif

extension Notification.Name {
    static let assistantOpenSection = Notification.Name("banana.assistant.open-section")
}
