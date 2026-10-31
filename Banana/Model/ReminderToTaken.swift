import Foundation

/// A repeating reminder that's something you take — Creatine, vitamin D, the morning pills —
/// belongs in Taken, where it's logged taken or skipped, checked for clashes and due around a
/// moment natively (docs/design/ANCHORED-TIMING.md, "Learning it, and moving to Taken"). Which
/// reminders read that way, and the Taken item and doses one becomes. Pure, for tests;
/// `AnchorSuggestionStore` makes the move.
enum ReminderToTaken {
    /// How far back its ticks come along, as doses taken.
    static let historyDays = 60
    /// Its time in Taken when the reminder has none: the evening, still worth a nudge.
    static let defaultHour = 20

    /// A reminder offered the move: repeating, still going, and something taken.
    struct Offer: Hashable, Identifiable, Sendable {
        /// The reminder on this device (`EKReminder.calendarItemIdentifier`), whose repeat ends.
        var reminderID: String
        var externalID: String?
        var title: String
        var due: Date?
        var hasTime: Bool
        /// The moment it's done after: its rule (`ReminderAnchors`), else what was learned.
        var anchor: TimingAnchor?

        /// The same key the reminder's learned anchor uses, so one item is one item everywhere.
        var id: String { AnchorSuggestions.key(.reminder(externalID: externalID, title: title)) }
        var name: String { ReminderToTaken.name(title) }
        var sentence: String { ReminderToTaken.sentence(name: name, anchor: anchor) }
    }

    // MARK: - Which reminders

    /// Repeating each day or week, not finished for good, and something taken.
    static func isCandidate(title: String, recurrence: CalendarItemRecurrence, completed: Bool) -> Bool {
        (recurrence == .daily || recurrence == .weekly) && !completed && readsAsTaken(title)
    }

    /// Words, whole, that say something is taken.
    static let takenWords: Set<String> = [
        "creatine", "vitamin", "vitamins", "multivitamin", "multivitamins", "mineral", "minerals",
        "magnesium", "zinc", "iron", "calcium", "potassium", "selenium", "iodine", "b12", "b6", "folate",
        "biotin", "omega", "probiotic", "probiotics", "prebiotic", "prebiotics", "protein",
        "electrolyte", "electrolytes", "melatonin", "collagen", "ashwagandha", "turmeric", "glucosamine",
        "pill", "pills", "tablet", "tablets", "capsule", "capsules", "meds", "medication", "medications",
        "medicine", "prescription", "supplement", "supplements", "inhaler",
    ]
    /// Phrases that say it, matched as whole words.
    static let takenPhrases = ["fish oil", "cod liver oil", "krill oil", "omega 3", "folic acid", "vitamin d"]
    /// Words that say the reminder is about it rather than taking it — buying more, a call, a
    /// chore that happens to share a word ("Iron shirts").
    static let notTakenWords: Set<String> = [
        "buy", "order", "reorder", "refill", "restock", "shop", "shopping", "call", "book", "research",
        "pick", "collect", "shirt", "shirts", "clothes", "laundry", "sheets", "pump",
    ]

    /// Whether a reminder's title reads as something taken: a supplement, a vitamin or mineral, a
    /// pill; anything `SupplementInteractions` recognises, except coffee and tea, which are drunk,
    /// not taken; or any drug or supplement in the bundled vocabulary (`TakenVocabulary` — RxNorm
    /// and NIH's label database), so "Synthroid" and "L-theanine" count too.
    static func readsAsTaken(_ title: String, vocabulary: TakenVocabulary.Lists = TakenVocabulary.bundled) -> Bool {
        let words = self.words(title)
        guard !words.isEmpty, words.allSatisfy({ !notTakenWords.contains($0) }) else { return false }
        if words.contains(where: takenWords.contains) { return true }
        let text = " " + words.joined(separator: " ") + " "
        if takenPhrases.contains(where: { text.contains(" \($0) ") }) { return true }
        if !SupplementInteractions.substances(in: title).subtracting([.caffeine]).isEmpty { return true }
        return TakenVocabulary.kind(of: title, in: vocabulary) != nil
    }

    /// A prescription when the title says so — meds, medication, a prescription, or a drug
    /// `SupplementInteractions` knows — else a supplement. The distinction matters: Banana never
    /// proposes moving a prescription's time.
    static func kind(_ title: String, vocabulary: TakenVocabulary.Lists = TakenVocabulary.bundled) -> SupplementSchedule.Kind {
        let words = Set(self.words(title))
        let says = ["meds", "medication", "medications", "medicine", "prescription"].contains(where: words.contains)
        let drug = SupplementInteractions.substances(in: title).contains(where: \.isMedication)
            || TakenVocabulary.kind(of: title, in: vocabulary) == .medication
        return says || drug ? .medication : .supplement
    }

    /// The Taken item's name: the title, without the "Take" Taken already says. "Take meds" →
    /// "Meds", "take vitamin D" → "Vitamin D".
    static func name(_ title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["take my ", "take "] where name.lowercased().hasPrefix(prefix) && name.count > prefix.count {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// It's about the thing rather than taking it — buying more, a call, a chore.
    static func mentionsNotTaken(_ title: String) -> Bool {
        words(title).contains(where: notTakenWords.contains)
    }

    /// Lowercased words, punctuation as spaces: "Omega-3" → ["omega", "3"], joined back as
    /// "omega 3" for the phrases.
    private static func words(_ title: String) -> [String] {
        title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }

    // MARK: - What it becomes

    /// The Taken item: named from the title, at the reminder's time of day (or 8 PM when it has
    /// none — that becomes the fallback once it's due around a moment), with the anchor offered.
    static func schedule(for offer: Offer, id: UUID = UUID(), calendar: Calendar = .current) -> SupplementSchedule {
        var hour = defaultHour, minute = 0
        if offer.hasTime, let due = offer.due {
            hour = calendar.component(.hour, from: due)
            minute = calendar.component(.minute, from: due)
        }
        return SupplementSchedule(id: id, name: offer.name, kind: kind(offer.title), hour: hour, minute: minute,
                                  anchor: offer.anchor)
    }

    /// Its history, as doses taken: each day it was ticked in the last 60, at the first tick that
    /// day — a dose is one per day, and a second tick is the same day's dose.
    static func logs(for supplementID: UUID, completions: [Date], now: Date = Date(),
                     calendar: Calendar = .current) -> [SupplementLog] {
        let since = calendar.date(byAdding: .day, value: -historyDays, to: calendar.startOfDay(for: now)) ?? now
        var first: [String: Date] = [:]
        for date in completions where date >= since && date <= now {
            let day = WellnessCloudRecord.dayKey(date, calendar: calendar)
            if first[day].map({ date < $0 }) ?? true { first[day] = date }
        }
        return first.map { SupplementLog(supplementID: supplementID, date: $0.value, status: .taken, day: $0.key) }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Words

    /// "Creatine is a reminder. Move it to Taken? It'll be logged taken or skipped, checked for
    /// clashes, and can be due after your workout." With a moment learned, it says that one.
    static func sentence(name: String, anchor: TimingAnchor?) -> String {
        let due = anchor.map { "due " + lowercasedFirst(AnchoredTiming.label($0)) } ?? "can be due after your workout"
        return "\(name) is a reminder. Move it to Taken? It\u{2019}ll be logged taken or skipped, checked for clashes, and \(due)."
    }

    /// "After your workout" → "after your workout". A label starts "After", "Just before" or a
    /// number, so only its first letter goes; a name inside it ("after Workout") keeps its capital.
    static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}
