import Foundation

/// Timing conflicts between the supplements you take and what you eat or drink around them.
///
/// SCOPE, deliberately narrow. This covers ABSORPTION — two things that compete when they meet in
/// the gut, where the fix is simply taking them further apart. A rule earns its place here only
/// when the mechanism is established, the effect is large enough to matter at ordinary doses, and
/// there is a specific remedy in hours.
///
/// MEDICATIONS ARE IN SCOPE, BUT ONLY ON THE SAME TERMS. Now that the app tracks prescriptions
/// (`SupplementSchedule.Kind.medication`) the chelation rules belong here: calcium, iron and
/// magnesium bind levothyroxine, the tetracyclines, the fluoroquinolones and the bisphosphonates
/// in the gut, and a real fraction of the dose is simply never absorbed. Those are printed on the
/// patient leaflet of every one of those drugs, the mechanism is not in dispute, and the remedy is
/// a number of hours — which is exactly the bar every other rule here had to clear.
///
/// What is still OUT of scope is pharmacodynamic drug-drug interaction — two drugs whose combined
/// EFFECT is the problem rather than their absorption. That needs a maintained pharmacological
/// database and a standard of care a curated list cannot meet, and it has no timing remedy, so it
/// would not belong in a timing feature even if the data were here. The app also never proposes
/// moving a prescription: it reports the clash and offers to move the supplement or flag the meal.
///
/// WHY A TABLE AND NOT A MODEL. The on-device model was measured, on a far easier task in this same
/// app, at 55–75% precision with deterministic refusals on ordinary content. Asked about nutrient
/// interactions it would produce fluent, confident, occasionally invented pharmacology. For health
/// content that is the wrong tool at any accuracy, because the failure is invisible: a fabricated
/// warning reads exactly like a real one.
///
/// AND NO FALSE POSITIVES. The same rule the ad-skipping work landed on applies with more force
/// here. A warning that fires when it shouldn't teaches you to dismiss the ones that matter — so
/// this flags less than folklore does. "You can't take anything with coffee" is the folklore
/// version; the evidence is specifically about iron, and saying so is more useful than a blanket
/// warning nobody can act on.
enum SupplementInteractions {

    /// Something the app can recognise by name and reason about: a nutrient, or a drug class
    /// whose absorption a nutrient measurably interferes with.
    ///
    /// Drugs are held at the level of the CLASS, not the molecule, because that is the level the
    /// interaction actually lives at — every tetracycline chelates, every fluoroquinolone
    /// chelates — and because a per-molecule list would be a pharmacological database maintained
    /// by hand, which is exactly what this file refuses to be.
    enum Substance: String, CaseIterable, Codable, Sendable {
        case iron, calcium, zinc, magnesium, copper
        case vitaminC, vitaminD, vitaminE, vitaminK, vitaminA
        case caffeine, fibre
        case levothyroxine, tetracycline, fluoroquinolone, bisphosphonate

        /// Drives the wording shown to the person. A nutrient clash is advice about your own
        /// routine; a clash with a prescription ends in "ask your pharmacist", because the dose
        /// was set against a blood result this app has never seen.
        var isMedication: Bool {
            switch self {
            case .levothyroxine, .tetracycline, .fluoroquinolone, .bisphosphonate: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .iron: return "Iron"
            case .calcium: return "Calcium"
            case .zinc: return "Zinc"
            case .magnesium: return "Magnesium"
            case .copper: return "Copper"
            case .vitaminC: return "Vitamin C"
            case .vitaminD: return "Vitamin D"
            case .vitaminE: return "Vitamin E"
            case .vitaminK: return "Vitamin K"
            case .vitaminA: return "Vitamin A"
            case .caffeine: return "Caffeine"
            case .fibre: return "Fibre"
            case .levothyroxine: return "Levothyroxine"
            case .tetracycline: return "Tetracycline antibiotic"
            case .fluoroquinolone: return "Fluoroquinolone antibiotic"
            case .bisphosphonate: return "Bisphosphonate"
            }
        }

        /// Words that identify this substance in a supplement, medication, or food name.
        ///
        /// Matched on whole words against a lowercased name. Chemical forms are listed because
        /// that is how bottles are actually labelled — "ferrous bisglycinate" far more often than
        /// "iron" alone — and brand names are listed for the drugs because that is what is
        /// printed on the box someone will type in.
        var aliases: [String] {
            switch self {
            case .iron:
                return ["iron", "ferrous", "ferric", "bisglycinate", "fumarate", "ferritin"]
            case .calcium:
                return ["calcium", "citrate malate", "coral calcium"]
            case .zinc:
                return ["zinc", "picolinate"]
            case .magnesium:
                return ["magnesium", "glycinate", "threonate"]
            case .copper:
                return ["copper", "cupric"]
            case .vitaminC:
                return ["vitamin c", "ascorbic", "ascorbate"]
            case .vitaminD:
                return ["vitamin d", "cholecalciferol", "ergocalciferol", "d3"]
            case .vitaminE:
                return ["vitamin e", "tocopherol"]
            case .vitaminK:
                return ["vitamin k", "menaquinone", "phylloquinone", "k2"]
            case .vitaminA:
                return ["vitamin a", "retinol", "retinyl"]
            case .caffeine:
                return ["coffee", "espresso", "americano", "latte", "cappuccino", "caffeine",
                        "black tea", "green tea", "matcha", "energy drink"]
            case .levothyroxine:
                return ["levothyroxine", "levothyroxin", "thyroxine", "synthroid", "euthyrox",
                        "eltroxin", "levoxyl", "tirosint", "unithroid", "letrox"]
            case .tetracycline:
                return ["tetracycline", "doxycycline", "minocycline", "lymecycline",
                        "oxytetracycline", "vibramycin", "doryx", "minocin"]
            case .fluoroquinolone:
                return ["ciprofloxacin", "cipro", "levofloxacin", "levaquin", "moxifloxacin",
                        "ofloxacin", "norfloxacin", "avelox"]
            case .bisphosphonate:
                return ["alendronate", "fosamax", "risedronate", "actonel", "ibandronate",
                        "boniva", "etidronate", "zoledronic", "binosto"]
            case .fibre:
                return ["psyllium", "fiber supplement", "fibre supplement", "metamucil"]
            }
        }
    }

    /// How serious a conflict is, which decides how loudly it is shown.
    enum Severity: String, Codable, Sendable {
        /// A large, well-replicated absorption effect. Worth moving something.
        case notable
        /// Real but smaller, or dose-dependent. Worth knowing, not worth rearranging a day over.
        case minor

        var label: String { self == .notable ? "Worth separating" : "Minor" }
    }

    /// One established interaction, with the remedy attached.
    struct Rule: Sendable {
        var a: Substance
        var b: Substance
        /// How far apart they should be taken. The remedy IS the rule — an interaction with no
        /// actionable separation does not belong in a timing feature.
        var separation: TimeInterval
        var severity: Severity
        /// Plain-language mechanism. Shown to the person, so it says what actually happens rather
        /// than asserting a prohibition.
        var because: String
        var involvesMedication: Bool { a.isMedication || b.isMedication }

        func involves(_ substance: Substance) -> Bool { a == substance || b == substance }
        func other(than substance: Substance) -> Substance { a == substance ? b : a }
    }

    /// Everything the app will flag: the nutrient rules below plus the chelation family.
    static let rules: [Rule] = nutrientRules + chelationRules

    /// Nutrient-on-nutrient.
    ///
    /// Kept short on purpose. Every addition is a new chance to be wrong, and a list long enough to
    /// be impressive is long enough to contain something shaky.
    static let nutrientRules: [Rule] = [
        Rule(a: .iron, b: .calcium, separation: 2 * 3600, severity: .notable,
             because: "Calcium competes with iron for the same absorption pathway, and can cut how much iron you take up substantially."),
        Rule(a: .iron, b: .caffeine, separation: 3600, severity: .notable,
             because: "Polyphenols in coffee and tea bind iron in the gut. This is the interaction the “nothing with coffee” rule is really about — it is about iron, not supplements in general."),
        Rule(a: .iron, b: .zinc, separation: 2 * 3600, severity: .minor,
             because: "Iron and zinc compete for the same transporter at supplemental doses. Taken with food the effect is small."),
        Rule(a: .zinc, b: .copper, separation: 2 * 3600, severity: .minor,
             because: "Sustained high-dose zinc lowers copper absorption. This matters over weeks rather than in one sitting — separating them helps, but dose matters more."),
        Rule(a: .calcium, b: .zinc, separation: 2 * 3600, severity: .minor,
             because: "Calcium modestly reduces zinc absorption at supplemental doses."),
        Rule(a: .iron, b: .fibre, separation: 2 * 3600, severity: .minor,
             because: "Bulk fibre supplements bind minerals in transit, iron included."),
        Rule(a: .calcium, b: .fibre, separation: 2 * 3600, severity: .minor,
             because: "Bulk fibre supplements bind calcium in transit."),
    ]

    /// One mechanism, four drug classes: polyvalent cations — calcium, iron, magnesium, zinc —
    /// form a complex with the drug in the gut, and the complexed fraction is simply not absorbed.
    ///
    /// Generated rather than written out sixteen times, because they genuinely are the same rule
    /// with the drug swapped. Each class keeps its own mineral list and its own separation: the
    /// tetracyclines and quinolones chelate zinc too, levothyroxine's leaflet asks for four hours
    /// rather than two, and a bisphosphonate's problem is anything at all in the stomach.
    private static let chelationFamily: [(drug: Substance, minerals: [Substance], separation: TimeInterval, because: String)] = [
        (.levothyroxine, [.calcium, .iron, .magnesium], 4 * 3600,
         "Calcium, iron and magnesium bind levothyroxine in the gut, and the bound fraction never gets absorbed. Levothyroxine is dosed against a blood level, so this shows up as the dose quietly no longer working — the leaflet asks for four hours."),
        (.tetracycline, [.calcium, .iron, .magnesium, .zinc], 2 * 3600,
         "Doxycycline and the other tetracyclines form a complex with calcium, iron, magnesium and zinc, and a large part of the dose is lost. Dairy counts as calcium here."),
        (.fluoroquinolone, [.calcium, .iron, .magnesium, .zinc], 2 * 3600,
         "Ciprofloxacin and the other fluoroquinolones form a complex with calcium, iron, magnesium and zinc. Taken together, enough of the dose is lost to matter for whether the course works."),
        (.bisphosphonate, [.calcium, .iron, .magnesium], 2 * 3600,
         "Alendronate and the other bisphosphonates are barely absorbed at the best of times, and calcium, iron or magnesium taken near them stops almost all of what little would be."),
    ]

    static let chelationRules: [Rule] = chelationFamily.flatMap { entry in
        entry.minerals.map { mineral in
            Rule(a: entry.drug, b: mineral, separation: entry.separation,
                 severity: .notable, because: entry.because)
        }
    } + [
        // Not a cation, and so not part of the family above — but the single best-documented
        // levothyroxine timing effect there is, and the one people hit every morning.
        Rule(a: .levothyroxine, b: .caffeine, separation: 3600, severity: .notable,
             because: "Coffee within an hour of levothyroxine measurably lowers how much of the dose is absorbed. Taking the tablet first and the coffee an hour later is the whole fix."),
        Rule(a: .levothyroxine, b: .fibre, separation: 4 * 3600, severity: .minor,
             because: "Bulk fibre supplements bind levothyroxine in transit, the same way they bind minerals."),
    ]

    /// Pairings that HELP, so the app can say "keep these together" rather than only ever warning.
    struct Synergy: Sendable {
        var a: Substance
        var b: Substance
        var because: String
    }

    static let synergies: [Synergy] = [
        Synergy(a: .iron, b: .vitaminC,
                because: "Vitamin C markedly improves absorption of non-heme iron. Taking them together is worth doing on purpose."),
        Synergy(a: .vitaminD, b: .calcium,
                because: "Vitamin D is what lets you absorb calcium — these belong together."),
    ]

    // MARK: - Recognising what something contains

    /// The nutrients and drug classes a name appears to contain.
    ///
    /// Word-boundary matching, so "Calcium" is found in "Calcium Citrate" but "D3" is not found
    /// inside "D30". Returns everything matched: a multivitamin legitimately contains several.
    static func substances(in name: String) -> Set<Substance> {
        let haystack = " " + name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ") + " "
        var found: Set<Substance> = []
        for substance in Substance.allCases {
            for alias in substance.aliases where haystack.contains(" \(alias) ") {
                found.insert(substance)
                break
            }
        }
        return found
    }

    // MARK: - Finding conflicts

    /// Something taken at a time: a scheduled supplement or medication, or a logged food or drink.
    struct TimedIntake: Sendable {
        enum Origin: Sendable { case supplement, medication, food }

        var name: String
        /// Minutes from midnight.
        var minuteOfDay: Int
        var substances: Set<Substance>
        var origin: Origin = .supplement

        /// Supplements can be rescheduled. A meal is a fact about the day, already eaten, and a
        /// prescription's time was set by someone with your blood results — so neither is ever
        /// what the app proposes moving. That is the whole reason `Origin` exists: with only a
        /// movable flag, the obvious fix for "levothyroxine clashes with your calcium" would
        /// eventually be to suggest moving the levothyroxine.
        var isMovable: Bool { origin == .supplement }
    }

    struct Conflict: Sendable, Identifiable {
        var id: String { "\(earlier.name)|\(later.name)|\(rule.a.rawValue)-\(rule.b.rawValue)" }
        var earlier: TimedIntake
        var later: TimedIntake
        var rule: Rule
        /// How far apart they currently are.
        var actualSeparation: TimeInterval
        var shortfall: TimeInterval { max(0, rule.separation - actualSeparation) }
    }

    /// Every conflict among the day's intakes.
    ///
    /// Only pairs that are actually too close are returned — two things separated by more than the
    /// rule asks for are not a conflict, they are the rule already being followed.
    static func conflicts(among intakes: [TimedIntake]) -> [Conflict] {
        var found: [Conflict] = []
        for (index, first) in intakes.enumerated() {
            for second in intakes.dropFirst(index + 1) {
                let gap = abs(TimeInterval((first.minuteOfDay - second.minuteOfDay) * 60))
                for rule in rules {
                    let forward = first.substances.contains(rule.a) && second.substances.contains(rule.b)
                    let backward = first.substances.contains(rule.b) && second.substances.contains(rule.a)
                    guard forward || backward, gap < rule.separation else { continue }
                    // Something that contains BOTH substances cannot be separated from itself, and
                    // telling someone their multivitamin conflicts with itself is noise.
                    guard !(first.name == second.name) else { continue }
                    let (earlier, later) = first.minuteOfDay <= second.minuteOfDay
                        ? (first, second) : (second, first)
                    found.append(Conflict(earlier: earlier, later: later,
                                          rule: rule, actualSeparation: gap))
                }
            }
        }
        return found.sorted {
            $0.rule.severity == $1.rule.severity
                ? $0.earlier.minuteOfDay < $1.earlier.minuteOfDay
                : $0.rule.severity == .notable
        }
    }
}

// MARK: - Proposing a better time

extension SupplementInteractions {

    struct Suggestion: Sendable {
        var supplementName: String
        var fromMinuteOfDay: Int
        var toMinuteOfDay: Int
        /// The conflicts this move clears.
        var resolves: [Conflict]

        var movedBy: TimeInterval { TimeInterval(abs(toMinuteOfDay - fromMinuteOfDay) * 60) }
    }

    /// Hours a supplement may be moved to.
    ///
    /// Waking hours only: a rule that resolves a conflict by suggesting 3am has not solved
    /// anything, it has just moved the problem somewhere you will not go.
    static let earliestMinute = 6 * 60
    static let latestMinute = 22 * 60

    /// Times are proposed on the half hour. A supplement is not a medication with a dosing curve —
    /// suggesting 8:47 implies a precision that does not exist and is harder to remember.
    static let proposalStep = 30

    /// A new time for one supplement that clears the most conflicts while moving it least.
    ///
    /// Deliberately moves ONE thing. A solver that rearranges someone's whole routine to satisfy a
    /// constraint graph produces a schedule nobody asked for and will not follow; moving the single
    /// item that is in the way is a suggestion a person can accept or ignore.
    static func suggestion(movingSupplementNamed name: String,
                           among intakes: [TimedIntake]) -> Suggestion? {
        // This small table cannot establish a safe medication schedule. Even moving a
        // supplement for another reason could move it toward an unrecognized prescription.
        guard !intakes.contains(where: {
            $0.origin == .medication || $0.substances.contains(where: \.isMedication)
        }) else { return nil }
        guard let subject = intakes.first(where: { $0.name == name && $0.isMovable }) else { return nil }
        let others = intakes.filter { $0.name != name }
        let current = conflicts(among: intakes).filter {
            $0.earlier.name == name || $0.later.name == name
        }
        guard !current.isEmpty else { return nil }

        var best: Suggestion?
        var candidate = earliestMinute
        while candidate <= latestMinute {
            defer { candidate += proposalStep }
            guard candidate != subject.minuteOfDay else { continue }
            var moved = subject
            moved.minuteOfDay = candidate
            let remaining = conflicts(among: others + [moved]).filter {
                $0.earlier.name == name || $0.later.name == name
            }
            guard remaining.isEmpty else { continue }
            let proposal = Suggestion(supplementName: name,
                                      fromMinuteOfDay: subject.minuteOfDay,
                                      toMinuteOfDay: candidate,
                                      resolves: current)
            // Nearest workable time wins: the point is the smallest change that fixes it. A tie
            // goes to the LATER time on purpose — moving something earlier can push it before you
            // are up, which resolves the constraint on paper and not in life.
            guard let incumbent = best else { best = proposal; continue }
            if proposal.movedBy < incumbent.movedBy
                || (proposal.movedBy == incumbent.movedBy
                    && proposal.toMinuteOfDay > incumbent.toMinuteOfDay) {
                best = proposal
            }
        }
        return best
    }

    /// One suggestion per supplement that is currently in a conflict, most serious first.
    static func suggestions(among intakes: [TimedIntake]) -> [Suggestion] {
        let names = Set(conflicts(among: intakes).flatMap { [$0.earlier, $0.later] }
            .filter(\.isMovable).map(\.name))
        return names.compactMap { suggestion(movingSupplementNamed: $0, among: intakes) }
            .sorted { $0.resolves.count > $1.resolves.count }
    }
}
