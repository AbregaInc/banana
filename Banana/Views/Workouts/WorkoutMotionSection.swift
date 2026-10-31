import SwiftUI
import Charts

/// The detail view's Motion section (spec §4.7): a frequency-content spectrogram that works for
/// every raw-backed session regardless of activity (the one motion sub-view that doesn't need a
/// periodic signal — strength/yoga still get *a* spectrogram), plus, where at least one
/// accelerometer cycle was detected, a paged 3D acceleration-cycle signature.
///
/// Entirely driven by `WorkoutMotionCache.shared.result(for:fitness:)` (Package 1) — this file
/// only renders the states that cache/analysis can produce: still loading, loaded with nothing
/// usable, loaded with data. With no raw file on this device the section isn't shown at all.
///
/// Standalone — takes only the workout summary. `fitness` arrives via the ambient environment the
/// composing view (`WideWorkoutDetailView` on the Mac, `WorkoutDetailScreen` on iOS) already
/// provides.
struct WorkoutMotionSection: View {
    let workout: FitnessSessionSummary

    @EnvironmentObject private var fitness: FitnessStore

    /// `nil` until the `.task` below resolves (or resolves to "no result"); `hasLoaded` is what
    /// actually distinguishes "still loading" from "loaded, and the answer was nothing" — a bare
    /// `Result?` can't tell those apart on its own, since both look like `nil`.
    @State private var result: WorkoutMotionAnalysis.Result?
    @State private var hasLoaded = false
    /// Only attempted for `activityKind.usesLaps` (pool swims) — see `.task` below. Non-nil only
    /// when `WorkoutHandPath.analyze` actually produced at least one lap, i.e. the workout had a
    /// pool length, lap-turn marks, and a resolvable stroke count per lap.
    @State private var handPath: WorkoutHandPath.Analysis?
    /// `nil` for every activity other than a hand-path-eligible pool swim — that's what keeps
    /// `modePicker` out of the view entirely and `content` on its original, unmodified stacked
    /// layout for everything else. Set once, in `.task`, to the mode `content` should render.
    @State private var mode: MotionMode?

    private var activityKind: WorkoutActivityKind { WorkoutActivityKind(activity: workout.activity) }

    private enum MotionMode: Hashable, CaseIterable, Identifiable {
        case handPath, signature, frequency
        var id: Self { self }
        var label: String {
            switch self {
            case .handPath: return "Hand path"
            case .signature: return "Stroke signature"
            case .frequency: return "Frequency"
            }
        }
    }

    var body: some View {
        let _ = RenderStats.note("WorkoutMotionSection")
        // No recording on this device: no section at all, rather than a note explaining why.
        if fitness.hasLocalSamples(workout.id) {
            section
        }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkoutSectionLabel(title: "Motion")
            if mode != nil {
                modePicker
            }
            content
        }
        // Keyed on the workout id so navigating to a different workout resets `hasLoaded`/`result`
        // instead of showing the previous workout's motion data for a frame.
        .task(id: workout.id) {
            hasLoaded = false
            result = nil
            handPath = nil
            mode = nil
            guard fitness.hasLocalSamples(workout.id) else { return }
            result = await WorkoutMotionCache.shared.result(for: workout, fitness: fitness)
            // Hand path is only ever meaningful for a pool swim (it needs lap-turn marks and a
            // per-lap stroke count — see `WorkoutHandPath.analyze`'s own gating); skipping the
            // fetch for every other activity avoids a second raw-sample read nothing will use.
            if activityKind.usesLaps {
                let path = await WorkoutMotionCache.shared.handPath(for: workout, fitness: fitness)
                if let path, !path.laps.isEmpty {
                    handPath = path
                    // The launch-argument override only exists in DEBUG (it is a screenshot
                    // harness affordance); Release always opens on the hand path for a swim.
                    #if DEBUG
                    mode = Self.debugMotionMode() ?? .handPath
                    #else
                    mode = .handPath
                    #endif
                }
            }
            hasLoaded = true
        }
        // Evict this workout's cached analysis when leaving a long session (see `evict`'s doc
        // comment) so browsing workout after workout doesn't hold every long accel-derived
        // result in memory for the rest of the process's lifetime.
        .onDisappear {
            if workout.duration > 60 * 60 {
                WorkoutMotionCache.shared.evict(workout.id)
            }
        }
    }

    private var modeBinding: Binding<MotionMode> {
        Binding(get: { mode ?? .handPath }, set: { mode = $0 })
    }

    private var modePicker: some View {
        PageSwitch(label: "Motion view", selection: modeBinding, choices: Array(MotionMode.allCases),
                   title: { $0.label }, fills: true)
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoaded {
            noteCard {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let mode {
            // Pool-swim, hand-path-eligible workout: the picker above already narrowed the choice
            // to exactly one visualization, so render only that one — this is the only branch
            // where the previously-always-stacked spectrogram/signature pair is split apart.
            modeContent(mode)
        } else if let result, !(result.cycles.isEmpty && result.spectrogram == nil) {
            // Unchanged for every other activity, including swims that didn't qualify for a hand
            // path: two independently-chromed sub-cards, not one card wrapping both — matches the
            // "Running dynamics" precedent (a bare `WorkoutSectionLabel` above several individually
            // carded charts) rather than the single-card-always shape `WorkoutSplitsSection` uses,
            // because here there genuinely are two unrelated visualizations, not one table with a
            // fallback caption.
            VStack(alignment: .leading, spacing: 12) {
                MotionSpectrogramCard(result: result)
                if !result.cycles.isEmpty {
                    MotionSignatureCard(workout: workout, activityKind: activityKind, cycles: result.cycles,
                                         pageConsistency: result.pageConsistency, warnings: result.warnings)
                } else {
                    // A statement, not a failure: the spectrogram above already shows this recording
                    // had real motion to analyze — this just says plainly that none of it repeated
                    // strongly enough to call a cycle, which is the honest, expected outcome for
                    // strength/yoga (and the correct one — before the `.other` periodicity gate was
                    // tightened, this same card used to show 1,526 invented "cycles" for a real
                    // strength recording; see `WorkoutMotionCache.result(for:fitness:)`'s doc
                    // comment). Not folded into `noteCard`'s three top-level states above (absent /
                    // loading / nothing-at-all-usable) because those replace the whole section; this
                    // one only replaces the signature card, alongside a spectrogram that did render.
                    noteCard(text: "No repeating motion detected in this recording.")
                }
            }
        } else {
            noteCard(text: "Not enough motion data to analyze.")
        }
    }

    @ViewBuilder
    private func modeContent(_ mode: MotionMode) -> some View {
        switch mode {
        case .handPath:
            if let handPath {
                #if DEBUG
                HandPathView(analysis: handPath, initialLapIndex: Self.debugHandPathLapIndex())
                #else
                HandPathView(analysis: handPath)
                #endif
            } else {
                noteCard(text: "Not enough motion data to analyze.")
            }
        case .signature:
            if let result, !result.cycles.isEmpty {
                MotionSignatureCard(workout: workout, activityKind: activityKind, cycles: result.cycles,
                                     pageConsistency: result.pageConsistency, warnings: result.warnings)
            } else {
                noteCard(text: "Not enough motion data to analyze.")
            }
        case .frequency:
            if let result {
                MotionSpectrogramCard(result: result)
            } else {
                noteCard(text: "Not enough motion data to analyze.")
            }
        }
    }

    // MARK: - DEBUG screenshot route: `--motion-mode <handpath|signature|frequency>` and
    // `--hand-path-lap <lap>` ride on the existing `--workout-detail` / `--mac-workout-id`
    // visual-audit routes (BananaApp.swift's `VisualAuditRoute`) rather than adding a route of
    // their own — they only ever modify a detail screen that route already opened.
    #if DEBUG
    private static func debugMotionMode() -> MotionMode? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--motion-mode"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "handpath": return .handPath
        case "signature": return .signature
        case "frequency": return .frequency
        default: return nil
        }
    }

    /// `--hand-path-lap <lap>` is 1-based, matching the lap number the interface itself shows
    /// (`HandPathView.pager`'s "Lap N of M") — passing 33 selects the same lap the pager would
    /// label "Lap 33 of 70", not the 0-based `WorkoutHandPath.Analysis.laps` array index (which
    /// would silently be lap 34). `HandPathView.initialLapIndex` still wants that 0-based index,
    /// so this is the one place the conversion happens.
    private static func debugHandPathLapIndex() -> Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--hand-path-lap"), i + 1 < args.count,
              let lap = Int(args[i + 1]) else { return nil }
        return lap - 1
    }
    #endif

    /// The three non-data states (absent / loading / empty) all render as one small chromed card
    /// under the "Motion" label, matching how `WorkoutSplitsSection`'s own no-data state reads.
    private func noteCard(text: String) -> some View {
        noteCard { WorkoutSectionNote(text: text) }
    }

    private func noteCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(WorkoutMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
    }
}

// MARK: - Sub-card 1: spectrogram + dominant-frequency trace (V4)

/// Works for every raw session, including strength/yoga — a `RectangleMark` heatmap of frequency
/// content over time with the dominant-frequency trace overlaid. Deliberately never labelled
/// "cadence": recorded cadence is a cycling-only sensor kind, and this is a derived quantity from
/// raw wrist motion that exists for every activity — conflating the two would misattribute a
/// number to a kind of sensor data the workout never actually recorded.
private struct MotionSpectrogramCard: View {
    let result: WorkoutMotionAnalysis.Result

    /// One time-bucketed column of the heatmap: several raw STFT frames' bins averaged together.
    /// A full-rate spectrogram frame lands roughly every ~2.5 s (50%-overlapped 128-sample/25 Hz
    /// windows), so an hour-long session produces 1,000+ frames — well past this app's "a few
    /// hundred points per series" chart budget (see PERFORMANCE RULES). Averaging adjacent frames
    /// into a fixed column budget keeps a long session's heatmap smooth instead of either
    /// aliasing or silently dropping frames.
    private struct Column { var tStart: Float; var tEnd: Float; var bins: [Float] }

    private static let maxColumns = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Motion spectrogram").font(WorkoutType.chartTitle)
            if let spectrogram = result.spectrogram, !spectrogram.frames.isEmpty {
                chart(spectrogram)
                    .frame(height: WorkoutMetrics.chartHeight)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Frequency content of wrist motion over time — brighter means a stronger rhythm at that rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // What to do with the picture, not just what it plots — the axis line above says
                // what's on screen; this says how to read it. Deliberately activity-neutral, with
                // no examples of what a gap is (a pool turn, a rest, a red light): this is the one
                // motion sub-view every raw session gets, run and strength included (see this
                // file's top doc comment), and "turns" specifically would be a swim-only claim on
                // a screen this same sentence also has to be true for on a run.
                Text("A clean, level band means a steady rhythm; a smeared or drifting one means it's ragged or changing. Dark gaps are where the motion paused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(WorkoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func chart(_ spectrogram: WorkoutMotionAnalysis.Spectrogram) -> some View {
        let columns = Self.decimate(spectrogram.frames)
        let trace = Self.decimatedTrace(result.cadenceHzTrace, maxCount: Self.maxColumns)
        return Chart {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                ForEach(Array(column.bins.enumerated()), id: \.offset) { bin, magnitude in
                    RectangleMark(
                        xStart: .value("Start", Double(column.tStart) / 60),
                        xEnd: .value("End", Double(max(column.tEnd, column.tStart + 0.001)) / 60),
                        yStart: .value("Low", Double(bin) * Double(spectrogram.binHz)),
                        yEnd: .value("High", Double(bin + 1) * Double(spectrogram.binHz))
                    )
                    .foregroundStyle(by: .value("Magnitude", Double(magnitude)))
                }
            }
            ForEach(trace, id: \.t) { point in
                LineMark(x: .value("Time", point.t / 60), y: .value("Hz", point.value))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartForegroundStyleScale(range: Gradient(colors: [WorkoutPalette.spectrogramLow, WorkoutPalette.spectrogramHigh]))
        .chartXAxisLabel("minutes")
        .chartYAxisLabel("frequency (Hz)")
        .chartLegend(.hidden)
    }

    private static func decimate(_ frames: [WorkoutMotionAnalysis.SpectrogramFrame]) -> [Column] {
        guard !frames.isEmpty else { return [] }
        guard frames.count > maxColumns else {
            let halfStep = frames.count > 1 ? (frames[1].t - frames[0].t) / 2 : 0.5
            return frames.map { Column(tStart: $0.t - halfStep, tEnd: $0.t + halfStep, bins: $0.bins) }
        }
        let bucketSize = Int((Double(frames.count) / Double(maxColumns)).rounded(.up))
        var columns: [Column] = []
        columns.reserveCapacity(maxColumns)
        var i = 0
        while i < frames.count {
            let end = min(i + bucketSize, frames.count)
            let slice = frames[i..<end]
            let binCount = slice.map(\.bins.count).max() ?? 0
            var averaged = [Float](repeating: 0, count: binCount)
            for frame in slice {
                for b in 0..<frame.bins.count { averaged[b] += frame.bins[b] }
            }
            let count = Float(slice.count)
            if count > 0 { for b in 0..<binCount { averaged[b] /= count } }
            columns.append(Column(tStart: slice.first!.t, tEnd: slice.last!.t, bins: averaged))
            i = end
        }
        return columns
    }

    /// Simple stride pick (not averaging — this is a single trace, not a heatmap) so the overlay
    /// line stays in the same "a few hundred points" budget as the heatmap it's drawn over.
    private static func decimatedTrace(_ points: [WorkoutMetricPoint], maxCount: Int) -> [WorkoutMetricPoint] {
        guard points.count > maxCount else { return points }
        let step = max(Int((Double(points.count) / Double(maxCount)).rounded(.up)), 1)
        return stride(from: 0, to: points.count, by: step).map { points[$0] }
    }
}

// MARK: - Sub-card 2: 3D acceleration signature (V3)

/// One `Cycle`'s (x, y, z) plotted as a depth-sorted `Canvas` point cloud (`MotionSignatureScene`),
/// phase-colored, paged by lap (pool swims) or 60 s window (everything else). Deliberately not a
/// path/trajectory — the caption says so explicitly, because a naive viewer of a 3D point cloud
/// over motion data reasonably expects it to be one (spec's whole "no dead-reckoned IMU
/// trajectory" exclusion exists because that expectation is wrong for wrist-worn accelerometer
/// data with no recorded attitude).
///
/// This used to be a `Chart3D` of individual `PointMark`s. Measured on the owner's real BFCCD614…
/// swim (65,270 accel samples, 72 laps) with the app's own `CADisplayLink`-based `FrameProbe`
/// (`--frame-probe`) and `PerfWatchdog`'s high-CPU alert: opening this card on lap 10 (its busiest
/// real lap, 2,900 points) stalled the UI to ~3.5 fps for roughly 12.5 SECONDS — `PerfWatchdog`
/// logged `HIGH CPU 93% over 15s`, and `WorkoutMotionSection`'s own body re-ran twice during that
/// window — with a WARM `WorkoutMotionDiskCache` already on disk, so nothing was being
/// recomputed; the stall was pure `Chart3D` rendering. The hand path's `Canvas` (`HandPathScene`/
/// `HandPathView`), same app, same launch, same real data, settled to a steady 59 fps within
/// about 1.5 seconds. That comparison — not a guess about point counts — is why this card now
/// draws through the same `Canvas` approach `HandPathView` already used, via
/// `MotionSignatureScene`, instead of trying to find a `Chart3D` point budget that keeps it fast.
private struct MotionSignatureCard: View {
    let workout: FitnessSessionSummary
    let activityKind: WorkoutActivityKind
    let cycles: [WorkoutMotionAnalysis.Cycle]
    /// `WorkoutMotionAnalysis.Result.pageConsistency`, keyed by the exact same `page` index this
    /// card already pages by — see that field's doc comment and `WorkoutMotionConsistency` for
    /// what the number means and why it's scale-invariant. Read directly, never recomputed here:
    /// it was already derived off the main actor alongside `cycles`, which is what lets the "play"
    /// button below advance through every lap without spinning the CPU.
    let pageConsistency: [Int: Float]
    /// `WorkoutMotionAnalysis.Result.warnings` (e.g. "3 gaps > 200 ms skipped") — the spec places
    /// these under this card's caption specifically, not as a section-wide line, since they're
    /// about the same raw stream this card visualizes.
    let warnings: [String]

    @State private var camera: MotionSignatureScene.Camera = .default
    @State private var page: Int = -1   // -1 = "not yet defaulted"; set in .onAppear
    /// Drives the "play" button (`playButton`) via `.task(id: isPlaying)` in `body` — see
    /// `LapPlayback`'s doc comment for why a boolean + `.task` rather than a `Timer`.
    @State private var isPlaying = false
    /// Tracks one `DragGesture`'s direction decision, same technique and reasoning as
    /// `HandPathView.orbitDrag`'s own `DragLock` — a drag beginning on a view carrying ANY
    /// `DragGesture`, direction-gated or not, measurably ate the enclosing `ScrollView`'s vertical
    /// drag on this SDK (see that doc comment for the measured evidence), which is why the inline
    /// iOS card below stays completely gesture-free and only the expanded sheet gets a live drag.
    private enum DragLock: Equatable { case none, horizontal, rejected }
    @State private var dragLock: DragLock = .none
    @State private var dragStartCamera: MotionSignatureScene.Camera?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// iOS only: the inline card shows a fixed, non-interactive pose (see `signature` below) so a
    /// one-finger drag on it doesn't fight the detail screen's own `ScrollView`; tapping it opens
    /// this full-screen sheet, where the canvas gets the same draggable `camera` binding the Mac
    /// uses inline, with nothing else competing for the gesture.
    #if os(iOS)
    @State private var showExpanded = false
    #endif

    private var usesLapPaging: Bool { activityKind.usesLaps }

    /// The activity's name for one detected `Cycle`, named honestly per activity rather than left
    /// to a generic "acceleration signature" caption that lets "cycle" silently mean whatever rate
    /// the detector happened to lock onto — an ambiguous label is exactly how the arm-swing/
    /// step-rate mixup (see `WorkoutMotionAnalysis`'s file doc comment) went unnoticed on this
    /// chart. Running/walking/hiking cycles are one step (not one arm swing — `WorkoutMotionAnalysis`
    /// targets the step rate specifically for `.runOrWalk` now); pool/open-water swims and rowing
    /// are one stroke; cycling/strength/yoga/unrecognized make no specific claim, since a "cycle"
    /// there isn't a named athletic unit the way a step or a stroke is. `nil` for the latter group.
    private var cycleNoun: String? {
        switch activityKind {
        case .running, .walking, .hiking: return "step"
        case .poolSwim, .openWaterSwim, .rowing: return "stroke"
        case .cycling, .strength, .yoga, .other: return nil
        }
    }

    /// Leads with "not a path" as its own independent clause — not a trailing aside — because the
    /// hand path sits one tab over and genuinely *is* a path; a viewer bouncing between the two
    /// pickers needs the distinction to register before the axis label does. The reason ("overlaid
    /// … not traced through space") is what makes it a claim rather than a warning label: every
    /// cycle in the page shares the same plot instead of being placed in sequence, which is also
    /// why the read is OVERLAP — whether the cycles land on top of one another — and NOT overall
    /// cloud size (see `consistencyText`/`readingHintText`). This corrects a real mistake made
    /// about this chart: the original guidance here read "a tight cloud means consistent technique,
    /// a scattered one means inconsistent." The owner caught it himself — the cloud's overall SIZE
    /// is set by how forcefully he moved (and, since this is raw accelerometer signal with gravity
    /// still in it, by wrist orientation too, not force alone), which has nothing to do with
    /// whether the shape repeats cycle to cycle: a gentle, perfectly even effort produces a small
    /// cloud that reads as "tight" by size alone despite carrying no real consistency signal, and a
    /// hard, well-drilled effort can produce a big one. `consistencyText` below reports the
    /// scale-invariant number that corrects for this instead of leaving it to an eyeball size
    /// judgement.
    private var captionText: String {
        let base = "Not a path — every cycle is overlaid here in acceleration (g, gravity included), not traced through space."
        guard let cycleNoun else { return base }
        return base + " Each cycle is one \(cycleNoun)."
    }

    /// The real number for this page — see `WorkoutMotionAnalysis.Result.pageConsistency` and
    /// `WorkoutMotionConsistency` for exactly what it measures (median pairwise spread after
    /// aligning the cycles to each other, as a FRACTION of their own aligned size, which is what
    /// makes it immune to the force/size confound `captionText` above explains). Leads over
    /// `readingHintText`'s eyeball guidance because it actually answers the question that guidance
    /// can only gesture at. `nil` when this page has fewer than two usable cycles (a rest length,
    /// a page where every cycle got flagged `offBaseline`, or simply too few strokes) — there is
    /// nothing to compare yet, so no number is shown rather than a misleading placeholder.
    ///
    /// Deliberately reports DIRECTION ("lower is tighter"), not an absolute "tight"/"scattered"
    /// verdict against a fixed cutoff: measured across all 72 laps of the owner's real BFCCD614…
    /// swim, the ratio ranged roughly 0.58–1.99 with a median around 1.7 — well above the sub-1.0
    /// range an unscaled Kabsch-RMSD-over-size number might suggest at a glance (this is raw,
    /// un-smoothed per-sample acceleration, so ordinary point-to-point sensor noise and small
    /// cycle-to-cycle TIMING jitter both count toward the spread — rotation-only alignment corrects
    /// for orientation, not for a stroke's peak landing at a slightly different phase each time).
    /// With only one real workout's distribution to go on, a fixed "under X% is good" claim would
    /// be a precision this hasn't earned; comparing laps to EACH OTHER (which the ratio's own
    /// scale-invariance makes valid) is the honest use of the number today.
    private var consistencyText: String? {
        guard let ratio = pageConsistency[max(page, 0)] else { return nil }
        let percent = Int((ratio * 100).rounded())
        return "Consistency: \(percent)% spread relative to the loop's own size — lower means the cycles overlay " +
        "more tightly (more repeatable), higher means they vary more from one cycle to the next. Most informative " +
        "compared lap to lap, not read alone."
    }

    /// What to actually do with the picture when `consistencyText` isn't available (too few cycles
    /// on this page) — and the plain-English explanation behind the number when it is. Says
    /// "cycle", not `cycleNoun` again — that word was just defined by `captionText` immediately
    /// above, so repeating "step"/"stroke" here would be the axis description a second time, not
    /// new guidance (and this line renders unchanged for cycling/strength/yoga/other, where there's
    /// no such noun). `usesLapPaging` picks the same word the pager already shows ("Lap N of M" vs
    /// "0–1 min"), so a swim's hint says "lap" and a run's says "window" instead of a page word not
    /// on screen.
    private var readingHintText: String {
        let page = usesLapPaging ? "lap" : "window"
        return "Read this by how well the cycles line up with each other, not by how big or small the cloud looks — size mostly reflects how hard he moved, not how consistent his technique was. Compare an early \(page) with a later one to see drift."
    }

    /// Laps come from the workout's own recorded lap count, not `max(cycle.lap)` — a lap with
    /// zero detected cycles (e.g. a rest length) must still get a page, not silently vanish from
    /// the stepper.
    private var lapCount: Int { max(workout.laps.count, 1) }
    private var windowCount: Int { max(Int((workout.duration / 60).rounded(.up)), 1) }
    private var pageCount: Int { usesLapPaging ? lapCount : windowCount }

    private var cyclesForPage: [WorkoutMotionAnalysis.Cycle] {
        let p = max(page, 0)
        if usesLapPaging {
            return cycles.filter { $0.lap == p + 1 }
        }
        let windowStart = Float(p * 60)
        let windowEnd = windowStart + 60
        return cycles.filter { $0.startT >= windowStart && $0.startT < windowEnd }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("3D acceleration signature").font(WorkoutType.chartTitle)
                Spacer()
                pager
            }
            signature
                .frame(maxHeight: signatureHeight)
            VStack(alignment: .leading, spacing: 2) {
                // Leads with the real number (when this page has one) — the "key figure" the
                // auto-play button's lap-by-lap advance is meant to make register as more than a
                // shimmer, per the owner's own reasoning (see `LapPlayback`'s doc comment).
                if let consistencyText {
                    Text(consistencyText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text(captionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(readingHintText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !warnings.isEmpty {
                    Text(warnings.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(WorkoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .onAppear { if page < 0 { page = defaultPage } }
        // Explicit belt-and-suspenders stop, matching `HandPathView`'s same pattern — see
        // `LapPlayback`'s doc comment for why `.task(id:)` alone already covers "stop when the
        // view goes away".
        .onDisappear { isPlaying = false }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            await LapPlayback.run {
                let next = page + 1
                guard next < pageCount else {
                    isPlaying = false
                    return false
                }
                withAnimation(reduceMotion ? nil : .default) { page = next }
                return true
            }
        }
    }

    /// Pool swims default to the lap with the most detected cycles (the most informative page to
    /// open on); windowed paging has no analogous "best" page called out by the spec, so page 0.
    private var defaultPage: Int {
        guard usesLapPaging else { return 0 }
        var counts: [Int: Int] = [:]
        for cycle in cycles { if let lap = cycle.lap { counts[lap, default: 0] += 1 } }
        let bestLap = counts.max(by: { $0.value < $1.value })?.key ?? 1
        return max(0, min(bestLap - 1, lapCount - 1))
    }

    private var pager: some View {
        HStack(spacing: 0) {
            playButton
            Button {
                isPlaying = false   // manual navigation always wins over auto-play, never fights it
                page = max(0, page - 1)
            } label: { Image(systemName: "chevron.left") }
                .iconButton()
                .disabled(page <= 0)
            Text(pageLabel).font(.caption).monospacedDigit().frame(minWidth: 70)
            Button {
                isPlaying = false
                page = min(pageCount - 1, page + 1)
            } label: { Image(systemName: "chevron.right") }
                .iconButton()
                .disabled(page >= pageCount - 1)
        }
    }

    /// Auto-advances through every page at `LapPlayback.stepInterval` — see that type's doc
    /// comment for the owner's own reasoning (watching the signature change lap by lap makes
    /// wobble over time visible in a way stepping through by hand does not). Disabled with only
    /// one page to page through — nothing to animate.
    private var playButton: some View {
        Button {
            isPlaying.toggle()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        }
        .iconButton()
        .disabled(pageCount <= 1)
        .accessibilityLabel(isPlaying ? "Pause playback" : "Play through every \(usesLapPaging ? "lap" : "window")")
    }

    private var pageLabel: String {
        let p = max(page, 0)
        return usesLapPaging ? "Lap \(p + 1) of \(lapCount)" : "\(p)–\(p + 1) min"
    }

    /// A 3D point cloud reads as noise below a certain size — the shared 2D `WorkoutMetrics
    /// .chartHeight` (180 pt, tuned for a flat line chart) is too short for it. Mac has the width
    /// to spare so it keeps that shared height; the phone gets a taller, phone-only frame instead
    /// of raising the constant for every 2D chart on both platforms.
    private var signatureHeight: CGFloat {
        #if os(iOS)
        300
        #else
        WorkoutMetrics.chartHeight
        #endif
    }

    @ViewBuilder
    private var signature: some View {
        let pageCycles = cyclesForPage
        if pageCycles.isEmpty {
            WorkoutSectionNote(text: "No cycles detected in this \(usesLapPaging ? "lap" : "window").")
                .frame(maxHeight: .infinity, alignment: .center)
        } else {
            let points = Self.decimatedPoints(pageCycles)
            #if os(macOS)
            // Mac: click-drag rotates in place — nothing else on the page competes for that
            // gesture. Double-tap resets, matching `HandPathView.resetCamera()`.
            let drawing = MotionSignatureScene.build(points: points, camera: camera)
            canvas(for: drawing, identifier: "workout.motionSignatureChart")
                .aspectRatio(CGFloat(MotionSignatureScene.aspectRatio(for: drawing)), contentMode: .fit)
                .contentShape(Rectangle())
                .simultaneousGesture(orbitDrag)
                .onTapGesture(count: 2) { resetCamera() }
            #else
            // iOS: a *fixed* pose — attaching the live drag here measurably fights the enclosing
            // `ScrollView`'s own vertical drag (see `DragLock`'s doc comment above). Tap to rotate
            // it for real in `expandedSignature`.
            let drawing = MotionSignatureScene.build(points: points, camera: .default)
            canvas(for: drawing, identifier: "workout.motionSignatureChart")
                .aspectRatio(CGFloat(MotionSignatureScene.aspectRatio(for: drawing)), contentMode: .fit)
                .contentShape(Rectangle())
                .onTapGesture { showExpanded = true }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .accessibilityAddTraits(.isButton)
                .sheet(isPresented: $showExpanded) { expandedSignature(points) }
            #endif
        }
    }

    #if os(iOS)
    /// The interactive counterpart to the inline card's fixed pose above — same content, but with
    /// the draggable `camera` binding and nothing else on screen to contest the gesture with.
    private func expandedSignature(_ points: [MotionSignatureScene.Point]) -> some View {
        let drawing = MotionSignatureScene.build(points: points, camera: camera)
        return NavigationStack {
            canvas(for: drawing, identifier: "workout.motionSignatureChart.expanded")
                .aspectRatio(CGFloat(MotionSignatureScene.aspectRatio(for: drawing)), contentMode: .fit)
                .padding()
                .contentShape(Rectangle())
                .simultaneousGesture(orbitDrag)
                .onTapGesture(count: 2) { resetCamera() }
                .navigationTitle("3D acceleration signature")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showExpanded = false }
                    }
                }
        }
    }
    #endif

    // MARK: - Gestures (same technique as `HandPathView.orbitDrag`/`resetCamera`)

    private var orbitDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartCamera == nil { dragStartCamera = camera }
                if dragLock == .none {
                    let width = abs(value.translation.width)
                    let height = abs(value.translation.height)
                    if width > height * 1.2 {
                        dragLock = .horizontal
                    } else if height > 6 {
                        dragLock = .rejected
                    } else {
                        return   // not enough movement yet to tell — wait for the next update
                    }
                }
                guard dragLock == .horizontal, let start = dragStartCamera else { return }
                let sensitivity = 0.012
                camera.azimuth = start.azimuth + Double(value.translation.width) * sensitivity
                camera.elevation = Self.clampElevation(start.elevation - Double(value.translation.height) * sensitivity)
            }
            .onEnded { _ in
                dragLock = .none
                dragStartCamera = nil
            }
    }

    private static func clampElevation(_ value: Double) -> Double { min(max(value, -1.45), 1.45) }

    private func resetCamera() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            camera = .default
        }
    }

    // MARK: - Point budget
    //
    // Measured, not guessed — see this type's doc comment for the full `Chart3D`-vs-`Canvas`
    // comparison. The busiest real lap in the recording that comparison used (72-lap pool swim,
    // lap 10) produced 2,900 raw phase-resampled points; the hand path's `Canvas` was verified
    // fast at up to ~480 drawn segments/lap in that same run. This card's own `Canvas` draws have
    // NOT been separately profiled all the way up to the signature's larger per-lap point counts,
    // so — unlike the old `Chart3D` cap, which sat right at the edge of real usage — this cap is
    // set with wide, deliberately untested headroom above anything a real page has produced, as a
    // defensive bound against a pathological recording rather than a number Canvas is known to
    // struggle at.
    private static let maxSignaturePoints = 20_000

    private static func decimatedPoints(_ pageCycles: [WorkoutMotionAnalysis.Cycle]) -> [MotionSignatureScene.Point] {
        var raw: [MotionSignatureScene.Point] = []
        raw.reserveCapacity(pageCycles.count * 100)
        for cycle in pageCycles {
            let count = min(cycle.phaseX.count, cycle.phaseY.count, cycle.phaseZ.count)
            for i in 0..<count {
                raw.append(MotionSignatureScene.Point(x: cycle.phaseX[i], y: cycle.phaseY[i], z: cycle.phaseZ[i],
                                                        phase: i, dim: cycle.offBaseline))
            }
        }
        guard raw.count > maxSignaturePoints else { return raw }
        let step = max(Int((Double(raw.count) / Double(maxSignaturePoints)).rounded(.up)), 1)
        return stride(from: 0, to: raw.count, by: step).map { raw[$0] }
    }

    // MARK: - Drawing (fits `MotionSignatureScene`'s scene-unit output to the canvas's pixel size)

    private struct FitTransform {
        var scale: Double
        var originX: Double
        var originY: Double
        var canvasCenter: CGPoint

        func point(_ p: MotionSignatureScene.ProjectedPoint) -> CGPoint {
            CGPoint(x: canvasCenter.x + CGFloat((p.x - originX) * scale),
                    y: canvasCenter.y - CGFloat((p.y - originY) * scale))
        }
    }

    private static func fitTransform(drawing: MotionSignatureScene.Drawing, size: CGSize) -> FitTransform {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let box = MotionSignatureScene.boundingBox(drawing: drawing) else {
            return FitTransform(scale: 1, originX: 0, originY: 0, canvasCenter: center)
        }
        let spanX = max(box.maxX - box.minX, 0.001)
        let spanY = max(box.maxY - box.minY, 0.001)
        let margin = 0.86   // leaves room so nothing clips the canvas edge
        let fitScale = min(Double(size.width) / spanX, Double(size.height) / spanY) * margin
        return FitTransform(scale: fitScale, originX: (box.minX + box.maxX) / 2, originY: (box.minY + box.maxY) / 2,
                             canvasCenter: center)
    }

    /// Every dot in one `context.fill` call each — cheap, direct `Canvas` draws instead of
    /// `Chart3D`'s per-point `PointMark` view identities. `falloff` (near=1, far=0.5, from
    /// `MotionSignatureScene.build`) scales both radius and opacity so the near half of the cloud
    /// reads as solid and the far half recedes, the same depth language `HandPathScene`'s tube
    /// uses.
    private func canvas(for drawing: MotionSignatureScene.Drawing, identifier: String) -> some View {
        Canvas { context, size in
            let transform = Self.fitTransform(drawing: drawing, size: size)
            for point in drawing.points {
                let center = transform.point(point)
                let radius = max(2.4 * point.falloff, 1.0)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let color: Color = point.dim
                    ? WorkoutPalette.motionSignature.opacity(0.22 * point.falloff)
                    : Self.phaseColor(point.phase).opacity(0.55 + 0.45 * point.falloff)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("3D acceleration signature. Double tap to rotate.")
    }

    /// Interpolates through `WorkoutPalette.handPathEffortGradient` by phase position (0...99 →
    /// 0...1) rather than effort — same ramp, same reasoning as `HandPathView.effortColor(_:)`
    /// (one perceptually ordered sequential scale), reused here so a viewer moving between the two
    /// 3D cards doesn't have to learn a second color language. `phase` replaces `Chart3D`'s
    /// automatic categorical scale-by-phase-index with a deliberate one.
    private static func phaseColor(_ phase: Int) -> Color {
        let stops = WorkoutPalette.handPathEffortGradient
        guard let first = stops.first else { return WorkoutPalette.motionSignature }
        guard stops.count > 1 else { return first }
        let clamped = Double(min(max(phase, 0), 99)) / 99
        let scaled = clamped * Double(stops.count - 1)
        let low = Int(scaled)
        let high = min(low + 1, stops.count - 1)
        return stops[low].mix(with: stops[high], by: scaled - Double(low))
    }
}
