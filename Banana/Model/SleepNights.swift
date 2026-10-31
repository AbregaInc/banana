import Foundation

/// What a stretch awake at night was — as far as the Watch's sleep stages and step counts can
/// tell, or as you said it was.
///
/// Kinds are data, not text baked into views: a later "Feeding" versus "Settling" is a new case
/// here, and a case this build doesn't know decodes as `upForAWhile` rather than failing.
enum NightWakeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case bathroom
    case baby
    case upForAWhile
    case awakeInBed

    var label: String {
        switch self {
        case .bathroom: "Bathroom"
        case .baby: "Baby"
        case .upForAWhile: "Up for a while"
        case .awakeInBed: "Awake in bed"
        }
    }

    var symbol: String {
        switch self {
        case .bathroom: "drop.fill"
        case .baby: "figure.and.child.holdinghands"
        case .upForAWhile: "figure.walk"
        case .awakeInBed: "bed.double.fill"
        }
    }

    /// Out of bed, as opposed to awake in it.
    var gotUp: Bool { self != .awakeInBed }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NightWakeKind(rawValue: raw) ?? .upForAWhile
    }
}

/// One stretch awake in the night.
struct NightWake: Codable, Hashable, Sendable, Identifiable {
    var start: Date
    var end: Date
    /// Steps taken during it — see `SleepNights.stepsByStretch`.
    var steps: Int
    var kind: NightWakeKind = .awakeInBed
    /// You said what it was; otherwise it's Banana's guess.
    var labelled = false
    /// Your Watch noticed you washing your hands during it (or just after).
    var handwash: Date?

    var id: Date { start }
    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

/// One night: from falling asleep to the last wake-up of the morning.
struct NightSummary: Codable, Hashable, Sendable, Identifiable {
    /// The morning it ended — which day's summary it belongs to.
    var night: Date
    var bedtime: Date
    var wake: Date
    var asleepMinutes: Double
    var wakes: [NightWake]

    var id: Date { night }
    var timesUp: Int { wakes.filter(\.kind.gotUp).count }
    func count(_ kind: NightWakeKind) -> Int { wakes.filter { $0.kind == kind }.count }
}

/// Finds the nights in Health's sleep samples, the stretches awake in each, and guesses what
/// each stretch was. Pure — the phone runs the first part on Health's data; any device runs
/// `classified` to apply your labels, what they've taught, and the baby-duty switch.
enum SleepNights {
    enum Stage: Sendable { case asleep, awake }

    struct Segment: Sendable {
        var start: Date
        var end: Date
        var stage: Stage
    }

    struct StepSample: Sendable {
        var start: Date
        var end: Date
        var count: Double
    }

    /// Asleep time separated by less than this is one night.
    static let nightGap: TimeInterval = 90 * 60
    /// A stretch of asleep time shorter than this is a nap, not a night.
    static let minimumNight: TimeInterval = 3 * 3_600
    /// Shorter awake stretches are the brief stirrings the Watch records all night and nobody
    /// remembers — unless there were steps in them.
    static let minimumWake: TimeInterval = 2 * 60
    /// Fewer steps than this in a stretch is awake in bed (shifting about, reaching for water).
    static let gotUpSteps = 8
    /// A hand-wash this soon after a stretch awake still belongs to it: sleep stages mark you
    /// asleep again a little before you're back in bed.
    static let handwashAfter: TimeInterval = 3 * 60
    /// Minute-by-minute steps this close together are one walk (`walksTheStagesMissed`).
    static let walkJoin: TimeInterval = 3 * 60

    // MARK: - Nights and stretches (on the phone, from Health)

    static func nights(segments: [Segment], steps: [StepSample], handwashes: [Date] = [],
                       calendar: Calendar = .current) -> [NightSummary] {
        let asleep = merged(segments.filter { $0.stage == .asleep }.map { ($0.start, $0.end) })
        let awake = segments.filter { $0.stage == .awake }.map { ($0.start, $0.end) }

        // Asleep intervals close together are one night; the gaps inside are where you woke.
        var groups: [[(start: Date, end: Date)]] = []
        for interval in asleep {
            if let last = groups.last?.last, interval.start.timeIntervalSince(last.end) < nightGap {
                groups[groups.count - 1].append(interval)
            } else {
                groups.append([interval])
            }
        }

        return groups.compactMap { group -> NightSummary? in
            guard let bedtime = group.first?.start, let wake = group.last?.end else { return nil }
            let asleepSeconds = group.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            guard asleepSeconds >= minimumNight else { return nil }

            // Awake = the gaps between asleep intervals, plus any awake samples inside the night.
            var stretches: [(start: Date, end: Date)] = zip(group, group.dropFirst()).map { ($0.end, $1.start) }
            stretches += awake.compactMap { a in
                let start = max(a.0, bedtime), end = min(a.1, wake)
                return end > start ? (start, end) : nil
            }
            stretches += walksTheStagesMissed(steps, awake: stretches, bedtime: bedtime, wake: wake)
            let all = merged(stretches, joiningWithin: 60)
            let counts = stepsByStretch(all, bedtime: bedtime, wake: wake, steps)
            let wakes = zip(all, counts).compactMap { stretch, count -> NightWake? in
                let length = stretch.end.timeIntervalSince(stretch.start)
                let washed = handwashes.first {
                    $0 >= stretch.start.addingTimeInterval(-60) && $0 <= stretch.end.addingTimeInterval(handwashAfter)
                }
                guard length >= minimumWake || ((count >= gotUpSteps || washed != nil) && length >= 60) else { return nil }
                return NightWake(start: stretch.start, end: stretch.end, steps: count, handwash: washed)
            }
            return NightSummary(night: calendar.startOfDay(for: wake), bedtime: bedtime, wake: wake,
                                asleepMinutes: asleepSeconds / 60, wakes: wakes)
        }
    }

    /// Walks the sleep stages slept through: the Watch's minute-by-minute steps (never Health's
    /// chunks, too coarse to place) with a burst of `gotUpSteps` or more inside the night where
    /// no stretch awake is. The Watch under-detects waking — a 20-step bathroom trip at 12:56
    /// was staged asleep, and its steps, belonging to no wake-up, were nobody's. Across ten
    /// real nights this found two such trips and nothing else: turning over makes a step or
    /// two, never eight.
    static func walksTheStagesMissed(_ steps: [StepSample], awake: [(start: Date, end: Date)],
                                     bedtime: Date, wake: Date) -> [(start: Date, end: Date)] {
        let minutes = steps
            .filter { $0.end.timeIntervalSince($0.start) <= 90 && $0.start >= bedtime && $0.end <= wake && $0.count > 0 }
            .sorted { $0.start < $1.start }
        var walks: [(start: Date, end: Date, steps: Double)] = []
        for minute in minutes {
            if let last = walks.last, minute.start.timeIntervalSince(last.end) <= walkJoin {
                walks[walks.count - 1].end = max(last.end, minute.end)
                walks[walks.count - 1].steps += minute.count
            } else {
                walks.append((minute.start, minute.end, minute.count))
            }
        }
        return walks.compactMap { walk in
            guard walk.steps >= Double(gotUpSteps) else { return nil }
            let start = max(bedtime, walk.start.addingTimeInterval(-60))
            let end = min(wake, walk.end.addingTimeInterval(60))
            let known = awake.contains { $0.start < end.addingTimeInterval(120) && $0.end > start.addingTimeInterval(-120) }
            return known ? nil : (start, end)
        }
    }

    /// The steps taken in each stretch awake. The Watch writes steps in chunks of several minutes,
    /// whatever happened in them — a trip to the bathroom can sit in a 40-minute chunk that's
    /// mostly asleep. Nobody walks in their sleep, so a chunk's steps are shared only among the
    /// stretches awake inside it, by how long each is, and the time before falling asleep or
    /// after waking (walking to bed stays with the evening). Each stretch is widened by a minute
    /// either side, since sleep stages' edges are approximate. Steps in a chunk that's asleep
    /// throughout are nobody's.
    static func stepsByStretch(_ stretches: [(start: Date, end: Date)], bedtime: Date, wake: Date,
                               _ steps: [StepSample]) -> [Int] {
        let pad: TimeInterval = 60
        // Widened, but never into a neighbour's widening or outside the night, so the windows
        // don't overlap and no time is counted twice.
        let windows = stretches.indices.map { i -> (start: Date, end: Date) in
            var start = max(stretches[i].start.addingTimeInterval(-pad), bedtime)
            var end = min(stretches[i].end.addingTimeInterval(pad), wake)
            if i > 0 {
                start = max(start, midpoint(stretches[i - 1].end, stretches[i].start))
            }
            if i < stretches.count - 1 {
                end = min(end, midpoint(stretches[i].end, stretches[i + 1].start))
            }
            return (start, end)
        }
        var totals = Array(repeating: 0.0, count: stretches.count)
        for sample in steps {
            if sample.end <= sample.start {
                if let i = windows.firstIndex(where: { $0.start <= sample.start && sample.start < $0.end }) {
                    totals[i] += sample.count
                }
                continue
            }
            let shares = windows.map { overlap(sample.start, sample.end, $0.start, $0.end) }
            let inside = shares.reduce(0, +)
            guard inside > 0 else { continue }
            let outside = overlap(sample.start, sample.end, .distantPast, bedtime)
                + overlap(sample.start, sample.end, wake, .distantFuture)
            for i in shares.indices where shares[i] > 0 {
                totals[i] += sample.count * shares[i] / (inside + outside)
            }
        }
        return totals.map { Int($0.rounded()) }
    }

    private static func overlap(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> TimeInterval {
        max(0, min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart)))
    }

    private static func midpoint(_ a: Date, _ b: Date) -> Date {
        a.addingTimeInterval(b.timeIntervalSince(a) / 2)
    }

    static func merged(_ intervals: [(Date, Date)], joiningWithin gap: TimeInterval = 0) -> [(start: Date, end: Date)] {
        var out: [(start: Date, end: Date)] = []
        for (start, end) in intervals.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, start.timeIntervalSince(last.end) <= gap {
                out[out.count - 1].end = max(last.end, end)
            } else {
                out.append((start, end))
            }
        }
        return out
    }

    // MARK: - What each stretch was (any device)

    /// A label you gave, keyed by the stretch's start to the minute.
    static func labelKey(_ start: Date) -> String {
        String(Int(start.timeIntervalSince1970 / 60))
    }

    /// The label for a stretch, allowing its start to have moved a few minutes since you gave it
    /// (Health refines a night's stages as the Watch syncs).
    static func label(for wake: NightWake, in labels: [String: NightWakeKind]) -> NightWakeKind? {
        let minute = Int(wake.start.timeIntervalSince1970 / 60)
        for offset in [0, -1, 1, -2, 2, -3, 3] {
            if let kind = labels[String(minute + offset)] { return kind }
        }
        return nil
    }

    /// Your labels applied, then everything else guessed from what they teach — each kind's
    /// usual length and steps — falling back to the defaults until there's enough to go on.
    static func classified(_ nights: [NightSummary], labels: [String: NightWakeKind], babyDuty: Bool) -> [NightSummary] {
        var result = nights
        for n in result.indices {
            for w in result[n].wakes.indices {
                if let kind = label(for: result[n].wakes[w], in: labels) {
                    result[n].wakes[w].kind = kind
                    result[n].wakes[w].labelled = true
                } else {
                    result[n].wakes[w].labelled = false
                }
            }
        }
        let profile = Profile(result.flatMap { $0.wakes.filter(\.labelled) })
        for n in result.indices {
            for w in result[n].wakes.indices where !result[n].wakes[w].labelled {
                let wake = result[n].wakes[w]
                result[n].wakes[w].kind = guess(minutes: wake.minutes, steps: wake.steps, handwashed: wake.handwash != nil,
                                                profile: profile, babyDuty: babyDuty)
            }
        }
        return result
    }

    /// What your labels say each kind usually looks like.
    struct Profile: Sendable {
        /// Per kind: labelled examples as (log minutes, log steps).
        var examples: [NightWakeKind: [(Double, Double)]] = [:]
        static let enough = 3

        init(_ labelled: [NightWake]) {
            for wake in labelled where wake.kind.gotUp {
                examples[wake.kind, default: []].append(Self.point(wake.minutes, wake.steps))
            }
        }

        static func point(_ minutes: Double, _ steps: Int) -> (Double, Double) {
            (log(max(minutes, 0.5)), log(Double(max(steps, 1))))
        }

        /// The labelled kind this stretch sits closest to, once at least two kinds have enough
        /// examples to say anything.
        func nearest(minutes: Double, steps: Int) -> NightWakeKind? {
            let known = examples.filter { $0.value.count >= Self.enough }
            guard known.count >= 2 else { return nil }
            let p = Self.point(minutes, steps)
            return known.min { a, b in distance(p, a.value) < distance(p, b.value) }?.key
        }

        private func distance(_ p: (Double, Double), _ points: [(Double, Double)]) -> Double {
            let cx = points.map(\.0).reduce(0, +) / Double(points.count)
            let cy = points.map(\.1).reduce(0, +) / Double(points.count)
            return (p.0 - cx) * (p.0 - cx) + (p.1 - cy) * (p.1 - cy)
        }
    }

    /// A hand-wash: the bathroom — unless you're on baby duty, when it may as well be a nappy, and
    /// only says you got up. No steps: awake in bed. Otherwise what your labels suggest, else: a
    /// short trip with a handful of steps is the bathroom; anything longer is the baby when you're
    /// on baby duty, or "up for a while".
    ///
    /// No study gives thresholds for any of this from a wrist — the step and length rules are
    /// Banana's own, which is why your labels take over as soon as there are enough of them.
    static func guess(minutes: Double, steps: Int, handwashed: Bool = false, profile: Profile, babyDuty: Bool) -> NightWakeKind {
        if handwashed && !babyDuty { return .bathroom }
        guard steps >= gotUpSteps || handwashed else { return .awakeInBed }
        if let learned = profile.nearest(minutes: minutes, steps: steps) {
            // Baby duty off means no baby guesses, whatever old labels say.
            return learned == .baby && !babyDuty ? .upForAWhile : learned
        }
        if minutes <= 10 && steps <= 150 { return .bathroom }
        return babyDuty ? .baby : .upForAWhile
    }

    // MARK: - The Watch's minute-by-minute steps

    /// Health's step chunks, with the Watch's minute-by-minute counts in their place wherever the
    /// Watch has sent them. A chunk reaching past a window keeps its share of the time outside.
    static func preferringMinutes(_ chunks: [StepSample], windows: [NightMotionReport.Window]) -> [StepSample] {
        guard !windows.isEmpty else { return chunks }
        let covered = merged(windows.map { ($0.start, $0.end) })
        var out: [StepSample] = []
        for chunk in chunks {
            let length = chunk.end.timeIntervalSince(chunk.start)
            // What's left of the chunk once the covered windows are cut out of it.
            var pieces = [(start: chunk.start, end: chunk.end)]
            for window in covered {
                pieces = pieces.flatMap { piece -> [(start: Date, end: Date)] in
                    guard window.start < piece.end, window.end > piece.start else { return [piece] }
                    return [(piece.start, window.start), (window.end, piece.end)].filter { $0.1 > $0.0 }
                }
            }
            for piece in pieces {
                let share = length > 0 ? piece.end.timeIntervalSince(piece.start) / length : 1
                out.append(StepSample(start: piece.start, end: piece.end, count: chunk.count * share))
            }
        }
        for window in windows {
            out += window.minutes.map { StepSample(start: $0.start, end: $0.start.addingTimeInterval(60), count: Double($0.steps)) }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: - The measures sleep research uses

    /// Awake after first falling asleep, until the last wake-up — "WASO" in sleep research.
    static func awakeMinutes(_ night: NightSummary) -> Double {
        max(0, night.wake.timeIntervalSince(night.bedtime) / 60 - night.asleepMinutes)
    }

    /// Wake-ups that break the night: every time you got up, and stretches in bed long enough to
    /// remember. Brief stirrings don't.
    static func disturbances(_ night: NightSummary) -> [NightWake] {
        split(night.wakes).listed
    }

    /// The longest stretch between falling asleep, the wake-ups that break the night, and waking.
    static func longestSleepMinutes(_ night: NightSummary) -> Double {
        var edges: [(start: Date, end: Date)] = [(night.bedtime, night.bedtime)]
        edges += disturbances(night).map { ($0.start, $0.end) }
        edges.append((night.wake, night.wake))
        return zip(edges, edges.dropFirst()).map { $1.start.timeIntervalSince($0.end) / 60 }.max() ?? 0
    }

    /// From falling asleep to the first trip to the bathroom — what nocturia research calls the
    /// first uninterrupted sleep period. Nil when you didn't go.
    static func firstTripMinutes(_ night: NightSummary) -> Double? {
        night.wakes.first { $0.kind == .bathroom }.map { $0.start.timeIntervalSince(night.bedtime) / 60 }
    }

    /// Nights with two or more bathroom trips — where, in the research, getting up starts to cost
    /// you (Tikkinen 2010). The morning's first trip isn't counted: it isn't a wake-up here.
    static func nightsWithTwoOrMoreTrips(_ nights: [NightSummary]) -> Int {
        nights.filter { $0.count(.bathroom) >= 2 }.count
    }

    /// Last night's guesses that got you up and haven't been confirmed or corrected.
    static func unconfirmed(_ night: NightSummary) -> [NightWake] {
        night.wakes.filter { $0.kind.gotUp && !$0.labelled }
    }

    /// How many labels there are, and whether they're enough to guess from.
    static func learning(_ nights: [NightSummary]) -> (labelled: Int, inUse: Bool) {
        let labelled = nights.flatMap(\.wakes).filter { $0.labelled && $0.kind.gotUp }
        let perKind = Dictionary(grouping: labelled, by: \.kind).mapValues(\.count)
        return (labelled.count, perKind.values.filter { $0 >= Profile.enough }.count >= 2)
    }

    // MARK: - Summaries

    /// Stretches awake in bed at least this long are listed one by one; shorter ones are folded
    /// into one line. About 5 minutes is roughly how long an awakening has to last to be
    /// remembered in the morning (Winser 2013: the shortest recalled averaged 4.3 min), the
    /// actigraphy guide's example definition of an awakening (Ancoli-Israel 2015), and shorter
    /// ones weren't linked to how people functioned the next day (Di Marco 2023).
    static let listedInBedMinutes: Double = 5

    /// The wake-ups worth a row each — every time you got up, and long stretches awake in bed —
    /// and the brief ones in bed, which are only worth a count.
    static func split(_ wakes: [NightWake]) -> (listed: [NightWake], brief: [NightWake]) {
        let brief = wakes.filter { !$0.kind.gotUp && $0.minutes < listedInBedMinutes }
        let briefIDs = Set(brief.map(\.id))
        return (wakes.filter { !briefIDs.contains($0.id) }, brief)
    }

    /// "Also awake in bed 5× · 32m".
    static func briefLine(_ brief: [NightWake]) -> String {
        let minutes = brief.reduce(0) { $0 + $1.minutes }
        return "Also awake in bed \(brief.count)\u{00D7} \u{00B7} \(duration(minutes))"
    }

    static func averageAsleepMinutes(_ nights: [NightSummary]) -> Double? {
        guard !nights.isEmpty else { return nil }
        return nights.map(\.asleepMinutes).reduce(0, +) / Double(nights.count)
    }

    static func averageMinutes(_ nights: [NightSummary], _ value: (NightSummary) -> Double) -> Double? {
        guard !nights.isEmpty else { return nil }
        return nights.map(value).reduce(0, +) / Double(nights.count)
    }

    static func average(_ nights: [NightSummary], _ value: (NightSummary) -> Int) -> Double? {
        guard !nights.isEmpty else { return nil }
        return Double(nights.map(value).reduce(0, +)) / Double(nights.count)
    }

    /// "Up 2×: bathroom, baby" / "Slept through".
    static func upLine(_ night: NightSummary) -> String {
        let up = night.wakes.filter(\.kind.gotUp)
        guard !up.isEmpty else {
            return night.wakes.isEmpty ? "Slept through" : "Didn\u{2019}t get up"
        }
        let kinds = up.map { $0.kind.label.lowercased() }
        var seen = Set<String>()
        let unique = kinds.filter { seen.insert($0).inserted }
        return "Up \(up.count)\u{00D7}: \(unique.joined(separator: ", "))"
    }

    /// "7h 12m"; "38m" under an hour (`DS.duration`).
    static func duration(_ minutes: Double) -> String { DS.duration(minutes: minutes) }
}
