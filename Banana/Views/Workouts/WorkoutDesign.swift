import SwiftUI

/// Single source of truth for every size, font, and color the Workouts feature (list + detail)
/// uses. Every other file under `Banana/Views/Workouts/`, plus the redesigned
/// `WideWorkoutsView`/`WideWorkoutDetailView`, imports these instead of writing ad hoc
/// `DS.Palette.accent`, `.title2`, or `cornerRadius: 14` inline — that duplication (12/14/16 radius;
/// 14/16/18/24 padding; several near-duplicate icon/isX helpers) is what made the feature read as
/// three loosely related screens instead of one.
enum WorkoutMetrics {
    static let cardRadius: CGFloat = DS.Radius.card
    static let rowPadding: CGFloat = DS.Space.m   // list row inset
    static let cardPadding: CGFloat = DS.Space.l  // detail section card inset: the app card's
    static let sectionSpacing: CGFloat = 20       // vertical gap between detail sections
    static let listRowSpacing: CGFloat = 8
    static let chartHeight: CGFloat = 180         // was 200; frees vertical room, still readable
    static let heroGlyphSize: CGFloat = 44
    static let rowGlyphSize: CGFloat = 40         // unchanged

    /// List row fixed-column widths (spec §3.3/§3.5) — every row uses the same widths so two rows
    /// with different available fields still align, instead of the columns drifting per-row based
    /// on which fields happen to be populated for that workout.
    static let rowTitleWidth: CGFloat = 200
    static let rowVisualWidth: CGFloat = 130
    static let rowVisualHeight: CGFloat = 40
    /// Time, dist/laps, pace/avg-lap, avg bpm — in that fixed order.
    static let rowMetricColumnWidths: [CGFloat] = [64, 80, 84, 66]
    static let rowMetricSpacing: CGFloat = 16

    /// Content width caps (spec §3.1/§3.6, §4.1).
    static let navColumnMaxWidth: CGFloat = 640
    static let listContentMaxWidth: CGFloat = 1040
    static let detailContentMaxWidth: CGFloat = 900
}

/// Named font tokens. A number that appears three times across list row, detail stat strip, and
/// comparison card should look the same size everywhere it appears — these names describe *what
/// the text is*, not which screen it happens to be on this time.
enum WorkoutType {
    static let sectionLabel = Font.headline
    static let groupHeader = Font.subheadline.weight(.semibold)
    static let groupHeaderDetail = Font.caption
    static let rowTitle = Font.body.weight(.semibold)
    static let rowSubtitle = Font.caption
    static let rowMetricValue = Font.callout.weight(.medium).monospacedDigit()
    static let rowMetricLabel = Font.system(size: 9, weight: .semibold)   // unchanged, it's already tiny/correct
    static let stripValue = Font.title3.weight(.semibold).monospacedDigit()   // was .title2/.title/.largeTitle-adjacent
    static let stripLabel = Font.caption2.weight(.semibold)
    static let heroActivity = Font.title2.weight(.bold)
    static let heroWhen = Font.subheadline
    static let chartTitle = Font.subheadline.weight(.semibold)
    static let badge = Font.caption2.weight(.semibold)
}

/// Named chart/series colors — one name per meaning, used everywhere that meaning appears (list
/// row metric, detail stat tile, detail chart, motion module) so the same fact is always the same
/// color instead of each surface picking its own.
enum WorkoutPalette {
    static let accent = DS.Palette.accent              // unchanged app accent
    static let heartRate = Color.red
    static let speed = Color.cyan
    static let elevation = Color.green
    static let cadence = Color.mint
    /// Running cadence, derived from speed × stride length (`WorkoutChartsSection`'s running
    /// "Cadence" chart). Same hue as `cadence` above — they're never on screen together (cycling
    /// vs. running/walking are mutually exclusive activity gates on the two charts), so there's
    /// no risk of the shared color reading as one series when it's actually two.
    static let derivedCadence = Color.mint
    static let power = Color.yellow
    static let strideLength = Color.indigo
    static let verticalOscillation = Color.purple
    static let groundContact = Color.teal
    static let strokeRate = Color.blue             // was mislabeled "Strokes" on a cumulative line
    static let motionSignature = Color.indigo
    static let spectrogramLow = Color.blue
    static let spectrogramHigh = DS.Palette.accent
    static let good = DS.Palette.success           // comparison deltas, fastest split/lap
    static let bad = DS.Palette.danger              // the accent is Banana itself; it never judges
    static let neutral = Color.secondary
    static let healthSource = Color.pink            // HealthWorkoutRow, unchanged
    static let routeGradient: [Color] = [.blue, .cyan, .green, .yellow, .orange]   // slow → fast / low → high, 5 stops
    /// Hand-path acceleration ramp: one perceptually ordered sequential scale, cool-and-dim at the
    /// low end through warm-and-bright at the high end, so a viewer can tell which end is hard
    /// work at a glance. `routeGradient` above deliberately isn't reused here — its blue→cyan→
    /// green→yellow→orange run doubles back through the same brightness twice (blue and orange
    /// are both roughly mid-brightness), so a lap whose effort dips back toward "low" near the end
    /// reads as an unrelated hue jump ("why did it turn blue again?") rather than a return to the
    /// dim end of one scale. This ramp instead stays strictly monotonic in both hue (indigo →
    /// magenta → amber) and lightness (dark → bright), the same shape as the reference render's
    /// colour key.
    static let handPathEffortGradient: [Color] = [
        Color(red: 0.09, green: 0.09, blue: 0.28),   // low — cool, dim indigo
        Color(red: 0.42, green: 0.10, blue: 0.46),   // violet
        Color(red: 0.78, green: 0.18, blue: 0.35),   // magenta-red
        Color(red: 0.98, green: 0.56, blue: 0.16),   // amber
        Color(red: 1.00, green: 0.92, blue: 0.45),   // high — warm, bright yellow
    ]
}

/// One place for "is this a pool swim / does it use pace / what icon" — today reimplemented per
/// file (`WorkoutRow.icon`/`isPoolSwim`/`lapCount`, `WideWorkoutDetailView.isPoolSwim`/`lapCount`,
/// `PostWorkoutReviewView.isPoolSwim`/`isSwim`/`isCycling`/`usesPace`, `HealthWorkoutRow.icon`).
/// The matching rules below mirror those existing lowercased-`contains` checks exactly, so
/// adopting this enum in place of the duplicates is behavior-preserving.
enum WorkoutActivityKind {
    case running, walking, cycling, hiking, rowing, poolSwim, openWaterSwim, strength, yoga, other

    init(activity: String) {
        let a = activity.lowercased()
        // Swim checks first: "pool swim" also contains "swim", so the more specific match has to
        // win before falling through to the general "swim"/"open water" check.
        if a.contains("pool swim") {
            self = .poolSwim
        } else if a.contains("open water") || a.contains("swim") {
            self = .openWaterSwim
        } else if a.contains("run") {
            self = .running
        } else if a.contains("walk") {
            self = .walking
        } else if a.contains("cycl") || a.contains("bike") {
            self = .cycling
        } else if a.contains("hik") {
            self = .hiking
        } else if a.contains("row") {
            self = .rowing
        } else if a.contains("strength") || a.contains("lift") {
            self = .strength
        } else if a.contains("yoga") {
            self = .yoga
        } else {
            self = .other
        }
    }

    var systemImage: String {
        switch self {
        case .running: "figure.run"
        case .walking: "figure.walk"
        case .cycling: "figure.outdoor.cycle"
        case .hiking: "figure.hiking"
        case .rowing: "figure.rower"
        case .poolSwim: "figure.pool.swim"
        case .openWaterSwim: "figure.open.water.swim"
        case .strength: "dumbbell.fill"
        case .yoga: "figure.yoga"
        case .other: "figure.mixed.cardio"
        }
    }

    var isSwim: Bool { self == .poolSwim || self == .openWaterSwim }
    var usesLaps: Bool { self == .poolSwim }
    /// Matches `PostWorkoutReviewView.usesPace` exactly: everything except swimming and cycling
    /// (cycling reports speed instead of pace; swims report laps/avg-lap instead of either).
    var usesPace: Bool { !isSwim && self != .cycling }

    /// Whether this activity has footstep-like periodic motion an accelerometer can reliably find
    /// a cycle rate for — a SIGNAL-PROCESSING question, distinct from `usesPace` above (a DISPLAY
    /// question: does the interface show a pace figure at all). The two used to be conflated:
    /// `WorkoutMotionCache` picked its cycle-detection search band with `usesPace`, which is true
    /// for anything that isn't a swim or a ride — that swept strength and yoga in alongside
    /// running/walking/hiking and ran their accelerometer noise through the footstep band and gate,
    /// which is how a single 77-minute strength recording produced 1,526 invented "cycles" at a
    /// fabricated 107/min (see `WorkoutMotionCache.result(for:fitness:)`'s doc comment for the
    /// measurement, before and after). Only running, walking, and hiking share a real footstrike
    /// cadence. Swimming has its own stroke periodicity and its own hint (`.swim`) already. Cycling,
    /// rowing, strength, yoga, and anything unrecognized all fall to the general case
    /// (`WorkoutMotionAnalysis.ActivityHint.other`) — cycling has real pedal periodicity, but not at
    /// the wrist a Watch is worn on, and rowing's stroke rate (~18–32/min) sits well below the
    /// footstep band anyway, so neither belongs in `.runOrWalk`'s 1.2–3.3 Hz search band either.
    var hasFootstepPeriodicity: Bool { self == .running || self == .walking || self == .hiking }

    /// Whether an ABSENT route is a gap worth a caption ("Indoor workout — no GPS") vs simply not
    /// applicable (strength, yoga, pool swim never have GPS and get no note at all).
    var routeIsExpected: Bool {
        switch self {
        case .running, .walking, .cycling, .hiking, .rowing, .openWaterSwim: true
        case .poolSwim, .strength, .yoga, .other: false
        }
    }
}

#if DEBUG
/// `--detail-section <hero|route|charts|splits|comparison|motion|signals>`: names one section of
/// a workout detail screen (Mac or iOS) for the DEBUG-only scroll-to-section route each
/// composing view (`WideWorkoutDetailView`, `WorkoutDetailScreen`) implements in its own `.task` —
/// see either file's `scrollToDebugSection`. Shared here, not duplicated per platform, so the two
/// screens can never drift on the flag's spelling or valid values.
///
/// `signals` only exists on iOS (`WorkoutDetailScreen.capturedSignalsSection` — the Mac detail
/// view has no equivalent section). Requesting it on the Mac finds no matching `.id(...)` in that
/// screen's `ScrollViewReader`, which is simply a silent no-op, not a crash.
enum WorkoutDetailSection: String {
    case hero, route, charts, splits, comparison, motion, signals

    static func requested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> WorkoutDetailSection? {
        guard let i = arguments.firstIndex(of: "--detail-section"), i + 1 < arguments.count else { return nil }
        return WorkoutDetailSection(rawValue: arguments[i + 1])
    }
}
#endif
