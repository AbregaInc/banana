import SwiftUI

/// What meal estimates have learned from the amounts you changed (docs/design/MEAL-LEARNING.md):
/// how far you've been moving them, and the foods they now size differently. The calendar's travel
/// learning says what it's learned in the same spirit — a learning system you can't see is one you
/// can't trust or correct.
struct EstimateLearning: Equatable {
    var summary: String?
    var learned: [LearnedPortions.Factor]
    /// Learned, but replaying recent meals says it makes the guesses worse: set aside.
    var turnedOff: Bool

    static let title = "How estimates are learning"

    /// Nil before any meal has kept its estimate: nothing to say yet.
    static func make(_ meals: [MealEntry]) -> EstimateLearning? {
        let rows = EstimateLedger.rows(meals)
        guard !rows.isEmpty else { return nil }
        let category: (String) -> String? = { FoodDatabase.food(id: $0)?.category }
        let book = LearnedPortions.book(rows, category: category)
        let learned = (Array(book.byName.values) + Array(book.byCategory.values))
            .sorted { $0.samples != $1.samples ? $0.samples > $1.samples : $0.basis < $1.basis }
        return EstimateLearning(summary: EstimateLedger.line(EstimateLedger.summary(rows)),
                                learned: Array(learned.prefix(6)),
                                turnedOff: !learned.isEmpty && !LearnedPortions.backtest(rows, category: category).keepsFactors)
    }

    /// "Rice ×1.3 · Pasta ×0.8".
    var learnedLine: String? {
        learned.isEmpty ? nil : learned.map { "\($0.basis) \u{00D7}\(String(format: "%.1f", $0.ratio))" }
            .joined(separator: " \u{00B7} ")
    }

    var footer: String {
        if turnedOff {
            return "Set aside for now: on your recent meals these made the guesses worse. They come back when they help."
        }
        if learned.isEmpty {
            return "It learns from amounts you change, packages you scan and portions you pick when asked \u{2014} never from an estimate you leave alone."
        }
        return "How much more or less you have than it guesses, learned from the amounts you changed. Used only when you don\u{2019}t say how much."
    }
}

/// `EstimateLearning` as a section of the phone's Nutrition list.
struct EstimateLearningSection: View {
    let meals: [MealEntry]
    @State private var learning: EstimateLearning?

    var body: some View {
        Group {
            if let learning {
                Section {
                    EstimateLearningLines(learning: learning)
                } header: {
                    Text(EstimateLearning.title)
                } footer: {
                    Text(learning.footer)
                }
            }
        }
        .task(id: meals.count) { learning = EstimateLearning.make(meals) }
    }
}

/// The same on the iPad and Mac Nutrition page, as a card.
struct EstimateLearningCard: View {
    let meals: [MealEntry]
    @State private var learning: EstimateLearning?

    var body: some View {
        Group {
            if let learning {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(EstimateLearning.title).font(.headline).padding(.horizontal, DS.Space.xs)
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        EstimateLearningLines(learning: learning)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.m)
                    .dsCard()
                    Text(learning.footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, DS.Space.xs)
                }
            }
        }
        .task(id: meals.count) { learning = EstimateLearning.make(meals) }
    }
}

private struct EstimateLearningLines: View {
    let learning: EstimateLearning

    var body: some View {
        if let summary = learning.summary {
            Text(summary).font(.callout)
        }
        if let line = learning.learnedLine {
            Text(line)
                .font(.callout.monospacedDigit())
                .foregroundStyle(learning.turnedOff ? .secondary : .primary)
                .accessibilityIdentifier("wellness.learned")
        }
    }
}
