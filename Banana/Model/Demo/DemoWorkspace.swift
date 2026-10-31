import Foundation

/// A local sample-data profile. It has no account token, service URL, device identifier or
/// native integration dependency. Production services are deliberately not injectable here.
struct DemoCalendar: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var color: String
    var readOnly = false
    var visible = true
}

struct DemoEvent: Codable, Equatable, Identifiable, Sendable {
    enum Repeat: String, Codable, CaseIterable, Sendable { case never, daily, weekly }
    var id: UUID
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var location = ""
    var notes = ""
    var recurrence: Repeat = .never

    func occurrence(on day: Date, calendar: Calendar) -> DemoEvent? {
        let sourceDay = calendar.startOfDay(for: start), target = calendar.startOfDay(for: day)
        guard target >= sourceDay else { return nil }
        let distance = calendar.dateComponents([.day], from: sourceDay, to: target).day ?? 0
        guard distance == 0 || recurrence == .daily || (recurrence == .weekly && distance % 7 == 0) else { return nil }
        var copy = self
        copy.start = calendar.date(byAdding: .day, value: distance, to: start) ?? start
        copy.end = copy.start.addingTimeInterval(end.timeIntervalSince(start))
        return copy
    }

    func occurrences(overlapping day: Date, calendar: Calendar) -> [DemoEvent] {
        let range = calendar.dateInterval(of: .day, for: day)!
        if recurrence == .never { return start < range.end && end > range.start ? [self] : [] }
        return (0...7).compactMap { previous in
            let date = calendar.date(byAdding: .day, value: -previous, to: range.start)!
            guard let value = occurrence(on: date, calendar: calendar), value.start < range.end, value.end > range.start else { return nil }
            return value
        }
    }
}

struct DemoTask: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case reminder, routine }
    var id: UUID
    var title: String
    var kind: Kind
    var completed = false
}

struct DemoEpisode: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var show: String
    var transcript: String
    var listened = false
    var position: Double = 0
    var speed: Double = 1
}

struct DemoSleep: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var start: Date
    var hours: Double
}

struct DemoWorkspace: Codable, Sendable {
    var version = 1
    var revision: UInt64 = 0
    var fixture = "review-v1"
    var scenarioID: String?
    var anchor: Date
    var timeZone: String
    var calendars: [DemoCalendar]
    var events: [DemoEvent]
    var tasks: [DemoTask]
    var meals: [MealEntry]
    var notes: [VoiceNote]
    var workouts: [FitnessSession]
    var sleep: [DemoSleep]
    var episodes: [DemoEpisode]
    var drafts: [String: String] = [:]

    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    func events(on day: Date) -> [DemoEvent] {
        let visible = Set(calendars.filter(\.visible).map(\.id))
        let occurrences: [DemoEvent] = events.flatMap { event -> [DemoEvent] in
            guard visible.contains(event.calendarID) else { return [] }
            return event.occurrences(overlapping: day, calendar: calendar)
        }
        return occurrences.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.start < rhs.start
        }
    }

    func validate() throws {
        func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
        guard version == 1, fixture == "review-v1", TimeZone(identifier: timeZone) != nil,
              anchor.timeIntervalSince1970.isFinite else { throw DemoFailure.invalidData }
        guard unique(calendars.map(\.id)), unique(events.map(\.id)), unique(tasks.map(\.id)),
              unique(meals.map(\.id)), unique(notes.map(\.id)), unique(workouts.map(\.id)),
              unique(episodes.map(\.id)), unique(sleep.map(\.id)) else { throw DemoFailure.invalidData }
        guard events.count <= 500, meals.count <= 500, notes.count <= 500, workouts.count <= 500,
              tasks.count <= 500, episodes.count <= 100, calendars.count <= 20, sleep.count <= 100,
              drafts.count <= 10 else { throw DemoFailure.tooLarge }
        let ids = Set(calendars.map(\.id))
        for event in events {
            guard ids.contains(event.calendarID), !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.title.utf8.count <= 1000, event.notes.utf8.count <= 65_536,
                  event.end > event.start, event.end.timeIntervalSince(event.start) <= 7 * 86_400 else { throw DemoFailure.invalidData }
        }
        for meal in meals {
            guard !meal.items.isEmpty, meal.items.count <= 100, meal.date.timeIntervalSince1970.isFinite else { throw DemoFailure.invalidData }
            for item in meal.items {
                guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DemoFailure.invalidData }
                let values = [item.macros.calories, item.macros.proteinGrams, item.macros.carbohydrateGrams, item.macros.fatGrams]
                guard values.allSatisfy({ $0.isFinite && (0...100_000).contains($0) }) else { throw DemoFailure.invalidData }
            }
        }
        for note in notes {
            guard note.audioFilename.isEmpty, note.reminderID == nil, (note.transcript?.utf8.count ?? 0) <= 65_536 else { throw DemoFailure.invalidData }
        }
        for workout in workouts {
            guard let end = workout.end, end > workout.start, end.timeIntervalSince(workout.start) <= 86_400,
                  workout.samples.count <= 10_000 else { throw DemoFailure.invalidData }
            guard workout.samples.allSatisfy({ $0.t.isFinite && $0.v1.isFinite }) else { throw DemoFailure.invalidData }
        }
        for episode in episodes {
            guard episode.position.isFinite, episode.position >= 0, [0.75, 1, 1.25, 1.5, 2].contains(episode.speed) else { throw DemoFailure.invalidData }
        }
        guard drafts.values.allSatisfy({ $0.utf8.count <= 65_536 }) else { throw DemoFailure.invalidData }
    }

}

enum DemoFailure: Error, LocalizedError, Equatable {
    case invalidData, readOnlyCalendar, missingItem, unreadable, unsafeDirectory, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidData: "Check the title, dates and values, then try again."
        case .readOnlyCalendar: "This sample calendar shares availability only. Choose Personal, Work or Fitness to make changes."
        case .missingItem: "That sample item is no longer available."
        case .unreadable: "The saved demo could not be opened. Your personal data is unaffected. Reset the sample data to start again."
        case .unsafeDirectory: "The demo storage location is not available."
        case .tooLarge: "This demo has reached its sample-data limit. Reset it to start again."
        }
    }
}

enum DemoCommand: Codable, Sendable {
    case saveEvent(DemoEvent), deleteEvent(UUID), moveEvent(UUID, Date)
    case calendarVisible(String, Bool), completeTask(UUID, Bool)
    case saveMeal(MealEntry), deleteMeal(UUID), repeatMeal(UUID, Date, UUID)
    case saveNote(VoiceNote), archiveNote(UUID, Bool), deleteNote(UUID)
    case saveWorkout(FitnessSession), deleteWorkout(UUID)
    case saveEpisode(DemoEpisode), saveDraft(String, String)
}

/// Constructor injection keeps file failures reproducible without altering global FileManager,
/// UserDefaults, URLSession, the user's account or production services.
struct DemoFileIO: Sendable {
    var read: @Sendable (URL) throws -> Data?
    var write: @Sendable (Data, URL) throws -> Void

    static let live = Self(read: { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }, write: { data, url in try data.write(to: url, options: [.atomic]) })
}

actor DemoRepository {
    static let directoryName = "SampleData-v1"
    private let file: URL
    private let io: DemoFileIO
    private let initial: DemoWorkspace
    private var current: DemoWorkspace?

    init(directory: URL, initial: DemoWorkspace, io: DemoFileIO = .live) throws {
        guard directory.isFileURL, directory.lastPathComponent == Self.directoryName else { throw DemoFailure.unsafeDirectory }
        guard (try? directory.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw DemoFailure.unsafeDirectory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw DemoFailure.unsafeDirectory }
        guard (try directory.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw DemoFailure.unsafeDirectory }
        var excluded = directory, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        file = directory.appendingPathComponent("workspace.json")
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw DemoFailure.unsafeDirectory }
        self.initial = initial
        self.io = io
    }

    func open() throws -> DemoWorkspace {
        if let current { return current }
        if let bytes = try io.read(file) {
            guard bytes.count <= 4_000_000,
                  let restored = try? JSONDecoder().decode(DemoWorkspace.self, from: bytes),
                  (try? restored.validate()) != nil else { throw DemoFailure.unreadable }
            current = restored
            return restored
        }
        return try commit(initial)
    }

    func reset() throws -> DemoWorkspace { try commit(initial) }

    func apply(_ command: DemoCommand) throws -> DemoWorkspace {
        var next = try open()
        func editable(_ event: DemoEvent) throws {
            guard next.calendars.contains(where: { $0.id == event.calendarID && !$0.readOnly }) else { throw DemoFailure.readOnlyCalendar }
        }
        switch command {
        case .saveEvent(let event):
            try editable(event)
            if let before = next.events.first(where: { $0.id == event.id }) { try editable(before) }
            next.events.removeAll { $0.id == event.id }; next.events.append(event)
        case .deleteEvent(let id):
            guard let event = next.events.first(where: { $0.id == id }) else { throw DemoFailure.missingItem }
            try editable(event); next.events.removeAll { $0.id == id }
        case .moveEvent(let id, let date):
            guard let index = next.events.firstIndex(where: { $0.id == id }) else { throw DemoFailure.missingItem }
            try editable(next.events[index]); let duration = next.events[index].end.timeIntervalSince(next.events[index].start)
            next.events[index].start = date; next.events[index].end = date.addingTimeInterval(duration)
        case .calendarVisible(let id, let visible):
            guard let index = next.calendars.firstIndex(where: { $0.id == id }) else { throw DemoFailure.missingItem }
            next.calendars[index].visible = visible
        case .completeTask(let id, let completed):
            guard let index = next.tasks.firstIndex(where: { $0.id == id }) else { throw DemoFailure.missingItem }
            next.tasks[index].completed = completed
        case .saveMeal(let meal):
            next.meals.removeAll { $0.id == meal.id }; next.meals.append(meal)
        case .deleteMeal(let id): next.meals.removeAll { $0.id == id }
        case .repeatMeal(let id, let date, let newID):
            guard var meal = next.meals.first(where: { $0.id == id }) else { throw DemoFailure.missingItem }
            meal.id = newID; meal.date = date
            next.meals.removeAll { $0.id == newID }; next.meals.append(meal)
        case .saveNote(let note):
            next.notes.removeAll { $0.id == note.id }; next.notes.append(note)
            next.drafts.removeValue(forKey: "note")
        case .archiveNote(let id, let archived):
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw DemoFailure.missingItem }
            next.notes[index].archivedAt = archived ? next.anchor : nil
        case .deleteNote(let id): next.notes.removeAll { $0.id == id }
        case .saveWorkout(let session):
            next.workouts.removeAll { $0.id == session.id }; next.workouts.append(session)
        case .deleteWorkout(let id): next.workouts.removeAll { $0.id == id }
        case .saveEpisode(let episode):
            guard next.episodes.contains(where: { $0.id == episode.id }) else { throw DemoFailure.missingItem }
            next.episodes.removeAll { $0.id == episode.id }; next.episodes.append(episode)
        case .saveDraft(let key, let value):
            if value.isEmpty { next.drafts.removeValue(forKey: key) } else { next.drafts[key] = value }
        }
        return try commit(next)
    }

    private func commit(_ next: DemoWorkspace) throws -> DemoWorkspace {
        var committed = next
        committed.revision = max(current?.revision ?? 0, next.revision) + 1
        try committed.validate()
        let bytes = try JSONEncoder().encode(committed)
        guard bytes.count <= 4_000_000 else { throw DemoFailure.tooLarge }
        try io.write(bytes, file)
        // Publication follows durability; a failed atomic write leaves the previous state intact.
        current = committed
        return committed
    }
}
