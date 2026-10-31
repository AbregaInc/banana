import Foundation

/// Stable identities and an injected clock make the public demo and automated scenarios use
/// exactly the same dataset. No names, tokens, locations or media come from a personal store.
enum DemoFixtures {
    enum Scenario: String, Codable, CaseIterable, Sendable { case review, empty }

    static func make(_ scenario: Scenario, now: Date, timeZone: TimeZone) -> DemoWorkspace {
        var workspace = review(now: now, timeZone: timeZone)
        workspace.scenarioID = scenario.rawValue
        if scenario == .empty {
            workspace.events = []; workspace.tasks = []; workspace.meals = []; workspace.notes = []
            workspace.workouts = []; workspace.sleep = []; workspace.episodes = []
        }
        return workspace
    }
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "D3A00000-0000-4000-8000-%012d", number))!
    }

    static func review(now: Date = Date(), timeZone: TimeZone = .current) -> DemoWorkspace {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone; cal.firstWeekday = 2
        let day = cal.startOfDay(for: now)
        func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let date = cal.date(byAdding: .day, value: offset, to: day)!
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
        }
        let calendars: [DemoCalendar] = [
            .init(id: "personal", title: "Personal", color: "purple"),
            .init(id: "work", title: "Work", color: "blue"),
            .init(id: "fitness", title: "Fitness", color: "orange"),
            .init(id: "shared", title: "Alex · availability", color: "gray", readOnly: true),
        ]
        let events: [DemoEvent] = [
            .init(id: id(1), calendarID: "work", title: "Design review", start: at(0, 9), end: at(0, 10), location: "Studio", notes: "Review the next milestone."),
            .init(id: id(2), calendarID: "personal", title: "Lunch with Sam", start: at(0, 12), end: at(0, 13), location: "Cafe"),
            .init(id: id(3), calendarID: "fitness", title: "Physical therapy", start: at(0, 15), end: at(0, 15, 45), recurrence: .weekly),
            .init(id: id(4), calendarID: "shared", title: "Busy", start: at(0, 15, 15), end: at(0, 16)),
            .init(id: id(5), calendarID: "personal", title: "Dinner with friends", start: at(0, 18), end: at(0, 20), location: "At home"),
            .init(id: id(6), calendarID: "work", title: "Team check-in", start: at(1, 10), end: at(1, 10, 30), recurrence: .daily),
            .init(id: id(7), calendarID: "personal", title: "Weekend walk", start: at(3, 11), end: at(3, 12)),
        ]
        let breakfast = MealEntry(id: id(20), date: at(0, 8), items: [
            MealItem(id: id(21), name: "Oats with berries", serving: "1 bowl", macros: .init(calories: 340, proteinGrams: 12, carbohydrateGrams: 54, fatGrams: 9), grams: 250),
        ], name: "Breakfast")
        let lunch = MealEntry(id: id(22), date: at(-1, 12), items: [
            MealItem(id: id(23), name: "Chicken and rice", serving: "1 plate", macros: .init(calories: 580, proteinGrams: 42, carbohydrateGrams: 65, fatGrams: 16), grams: 400),
        ], name: "Lunch")
        let note = VoiceNote(id: id(30), createdAt: at(0, 9), audioFilename: "", transcript: "Ideas for the next design review\n\nKeep the day clear. Make important actions easy to find.", status: .transcribed)
        let podcastNote = VoiceNote(id: id(31), createdAt: at(-1, 17), audioFilename: "", transcript: "Try a short walk after lunch.", kind: .podcastCapture,
            context: .init(episodeID: "demo-episode", episodeTitle: "A little room in your day", podcastTitle: "Banana sample audio", timestamp: 12), status: .transcribed)
        let samples = (0..<60).map { FitnessSample(t: Double($0) * 30, kind: .heartRate, v1: 112 + sin(Double($0) / 5) * 16, v2: nil, v3: nil) }
        let workout = FitnessSession(id: id(40), start: at(-1, 16), end: at(-1, 16, 30), activity: "Strength", avgHeartRate: 114, totalEnergy: 180, totalDistance: nil, samples: samples)
        return DemoWorkspace(anchor: at(0, 12), timeZone: timeZone.identifier, calendars: calendars, events: events,
            tasks: [.init(id: id(10), title: "Book the dentist", kind: .reminder),
                    .init(id: id(11), title: "Physical therapy exercises", kind: .routine),
                    .init(id: id(12), title: "Take a walk", kind: .routine)],
            meals: [breakfast, lunch], notes: [note, podcastNote], workouts: [workout],
            sleep: (1...7).map { .init(id: id(50 + $0), start: at(-$0, 23), hours: 7.2 + Double($0 % 3) * 0.3) },
            episodes: [.init(id: id(70), title: "A little room in your day", show: "Banana sample audio",
                transcript: "Welcome to Banana. This is sample audio for exploring the app. Plan your day, keep a note, log a meal, and make a little room for yourself. Your changes here stay in the demo."),
                .init(id: id(71), title: "Small routines, steady progress", show: "Banana sample audio", transcript: "A small routine can make a busy day feel simpler. Start with something you can repeat, and keep track of what helps.")])
    }
}
