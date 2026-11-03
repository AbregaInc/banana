import Foundation

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
}

struct AssistantWorkspaceState: Decodable {
    var revision: Int
    var action: AssistantAction?
}

#if BANANA_AI
@MainActor
enum AssistantWorkspace {
    static func prepare(_ fields: [String: Any], operation: String, now: Date = Date()) throws -> AssistantAction {
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
            action.title = section.title
        case .search:
            let query = (action.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.count <= 120 else { throw AssistantFailure(message: "Enter a short search phrase.") }
            action.query = query; action.title = "Results for “\(query)”"
            action.results = search(query)
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

    static func open(_ section: AppSection, itemID: String? = nil) {
        let shell = ShellNavigation.shared
        shell.state = routedState(section, itemID: itemID, from: shell.state, meals: WellnessStore.shared.meals)
        #if os(iOS)
        if PageChrome.shared.showAssistant {
            PageChrome.shared.assistantDestination = section
            PageChrome.shared.showAssistant = false
            return
        }
        #endif
        NotificationCenter.default.post(name: .assistantOpenSection, object: section.rawValue)
    }

    private static func search(_ query: String) -> [AssistantAction.Result] {
        var results: [AssistantAction.Result] = []
        var counts: [AppSection: Int] = [:]
        func add(_ id: String, _ title: String, _ detail: String, _ section: AppSection) {
            guard results.count < 30, counts[section, default: 0] < 6,
                  (title + " " + detail).localizedStandardContains(query) else { return }
            counts[section, default: 0] += 1
            results.append(.init(id: id, title: title, detail: String(detail.prefix(240)), section: section.rawValue))
        }
        for note in VoiceNoteStore.shared.matchingNotes(search: query, archived: false).prefix(6) {
            let text = note.transcript ?? ""; add("note:\(note.id)", String(text.prefix(80)), text, .notes)
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
