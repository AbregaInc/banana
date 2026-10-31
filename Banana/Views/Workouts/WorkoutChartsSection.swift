import SwiftUI
import Charts

/// The detail view's chart stack (spec §4.4): heart rate, pace/speed, elevation, cadence
/// (cycling only), power, running dynamics, and stroke rate — each `WorkoutChartFrame`-wrapped,
/// each gated on its own data, all sharing one explicit x-domain (`0...duration/60` minutes) so a
/// scrub position means the same instant on every chart.
///
/// Standalone — takes the workout summary and the shared scrub clock (spec §4.3). `settings`
/// arrives via the ambient environment the composing view (`WideWorkoutDetailView`, Package 7)
/// already provides.
struct WorkoutChartsSection: View {
    let workout: FitnessSessionSummary
    @Binding var cursorT: TimeInterval?

    @EnvironmentObject private var settings: AppSettings

    private var activityKind: WorkoutActivityKind { WorkoutActivityKind(activity: workout.activity) }

    /// One shared domain for every chart on the page — making the cursor mean the same instant
    /// everywhere, instead of each chart inferring its own extent from its own series.
    private var xDomain: ClosedRange<Double> {
        let minutes = workout.duration / 60
        return 0...(minutes > 0 ? minutes : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkoutMetrics.sectionSpacing) {
            if workout.heartRateSeries.count > 1 { heartRateChart }
            if workout.heartRateSeries.count > 10 { HeartRateZonesCard(workout: workout) }
            if workout.speedSeries.count > 1, !workout.stayedInOnePlace { speedChart }
            if workout.elevationSeries.count > 1, !workout.stayedInOnePlace { elevationChart }
            // Recorded cadence is cycling-only — a stray non-cycling sample must never render a
            // chart that implies a run recorded cadence.
            if activityKind == .cycling, workout.cadenceSeries.count > 1 { cadenceChart }
            // Running cadence isn't a HealthKit quantity (see `derivedCadenceSeries`'s doc
            // comment) — it's derived from speed × stride length at ingest, so it has its own
            // series and its own activity gate, never overlapping with the cycling chart above.
            if [.running, .walking].contains(activityKind), workout.derivedCadenceSeries.count > 1 { derivedCadenceChart }
            if workout.powerSeries.count > 1 { powerChart }
            if hasRunningDynamics { runningDynamicsSection }
            if strokeRatePoints.count > 1 { strokeRateChart }
        }
    }

    // MARK: - Heart rate

    private var heartRateChart: some View {
        let points = workout.heartRateSeries.map { WorkoutMetricPoint(t: $0.t, value: $0.bpm) }
        return WorkoutChartFrame(title: "Heart rate", unit: "bpm",
                                  average: workout.avgHeartRate,
                                  maximum: workout.heartRateSeries.map(\.bpm).max(),
                                  cursorT: $cursorT) { cursor in
            lineChart(points, seriesName: "Heart rate", unit: "bpm", color: WorkoutPalette.heartRate, cursor: cursor)
        }
    }

    // MARK: - Pace / speed

    /// Unchanged content from the pre-redesign `speedChart`: always plotted as speed (mph/km-h),
    /// not converted to pace, matching today's chart exactly. Avg/max come from `insights`,
    /// converted the same way the chart's own y-values are.
    private var speedChart: some View {
        let points = workout.speedSeries.map { WorkoutMetricPoint(t: $0.t, value: speedValue($0.metersPerSecond)) }
        let unit = settings.distanceUnit == .miles ? "mph" : "km/h"
        return WorkoutChartFrame(title: "Speed", unit: unit,
                                  average: workout.insights?.averageSpeed.map(speedValue),
                                  maximum: workout.insights?.maxSpeed.map(speedValue),
                                  formatValue: { String(format: "%.1f", $0) },
                                  cursorT: $cursorT) { cursor in
            lineChart(points, seriesName: "Speed", unit: unit, color: WorkoutPalette.speed, cursor: cursor)
        }
    }

    private func speedValue(_ metersPerSecond: Double) -> Double {
        metersPerSecond * (settings.distanceUnit == .miles ? 2.236936 : 3.6)
    }

    // MARK: - Elevation

    /// Average is omitted (not a meaningful fact for elevation); gain/loss are derived totals, not
    /// a y-value, so they render as a caption under the title instead of a `RuleMark`.
    private var elevationChart: some View {
        WorkoutChartFrame(title: "Elevation", unit: "m",
                           maximum: workout.elevationSeries.map(\.value).max(),
                           cursorT: $cursorT) { cursor in
            VStack(alignment: .leading, spacing: 4) {
                if let caption = elevationCaption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
                lineChart(workout.elevationSeries, seriesName: "Elevation", unit: "m", color: WorkoutPalette.elevation, cursor: cursor)
            }
        }
    }

    private var elevationCaption: String? {
        guard let insights = workout.insights else { return nil }
        var parts: [String] = []
        if let gain = insights.elevationGain { parts.append("+\(Int(gain.rounded())) m gain") }
        if let loss = insights.elevationLoss { parts.append("−\(Int(loss.rounded())) m loss") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Cadence (cycling only)

    private var cadenceChart: some View {
        WorkoutChartFrame(title: "Cadence", unit: "rpm",
                           average: workout.insights?.averageCadence,
                           maximum: workout.cadenceSeries.map(\.value).max(),
                           cursorT: $cursorT) { cursor in
            lineChart(workout.cadenceSeries, seriesName: "Cadence", unit: "rpm", color: WorkoutPalette.cadence, cursor: cursor)
        }
    }

    // MARK: - Cadence (running/walking, derived — see `FitnessSessionSummary.derivedCadenceSeries`)

    private var derivedCadenceChart: some View {
        WorkoutChartFrame(title: "Cadence", unit: "spm",
                           maximum: workout.derivedCadenceSeries.map(\.value).max(),
                           cursorT: $cursorT) { cursor in
            lineChart(workout.derivedCadenceSeries, seriesName: "Cadence", unit: "spm",
                      color: WorkoutPalette.derivedCadence, cursor: cursor)
        }
    }

    // MARK: - Power

    private var powerChart: some View {
        WorkoutChartFrame(title: "Power", unit: "watts",
                           average: workout.insights?.averagePower,
                           maximum: workout.powerSeries.map(\.value).max(),
                           cursorT: $cursorT) { cursor in
            lineChart(workout.powerSeries, seriesName: "Power", unit: "watts", color: WorkoutPalette.power, cursor: cursor)
        }
    }

    // MARK: - Running dynamics (stride length, vertical oscillation, ground contact time)

    private var hasRunningDynamics: Bool {
        workout.strideLengthSeries.count > 1 || workout.verticalOscillationSeries.count > 1 || workout.groundContactSeries.count > 1
    }

    /// Three same-height cards sharing one label and one row, rather than three consecutive
    /// full-width cards — groups "these are all form metrics" visually, the way the pre-redesign
    /// stacked treatment did not. Whichever of the three exist share the row evenly.
    private var runningDynamicsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkoutSectionLabel(title: "Running dynamics")
            HStack(alignment: .top, spacing: 12) {
                if workout.strideLengthSeries.count > 1 {
                    strideLengthChart.frame(maxWidth: .infinity)
                }
                if workout.verticalOscillationSeries.count > 1 {
                    verticalOscillationChart.frame(maxWidth: .infinity)
                }
                if workout.groundContactSeries.count > 1 {
                    groundContactChart.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var strideLengthChart: some View {
        let points = workout.strideLengthSeries.map { WorkoutMetricPoint(t: $0.t, value: $0.value * 100) }
        return WorkoutChartFrame(title: "Stride length", unit: "cm",
                                  maximum: points.map(\.value).max(),
                                  cursorT: $cursorT) { cursor in
            lineChart(points, seriesName: "Stride length", unit: "cm", color: WorkoutPalette.strideLength, cursor: cursor)
        }
    }

    private var verticalOscillationChart: some View {
        let points = workout.verticalOscillationSeries.map { WorkoutMetricPoint(t: $0.t, value: $0.value * 100) }
        return WorkoutChartFrame(title: "Vertical oscillation", unit: "cm",
                                  maximum: points.map(\.value).max(),
                                  cursorT: $cursorT) { cursor in
            lineChart(points, seriesName: "Vertical oscillation", unit: "cm", color: WorkoutPalette.verticalOscillation, cursor: cursor)
        }
    }

    private var groundContactChart: some View {
        let points = workout.groundContactSeries.map { WorkoutMetricPoint(t: $0.t, value: $0.value * 1_000) }
        return WorkoutChartFrame(title: "Ground contact", unit: "ms",
                                  maximum: points.map(\.value).max(),
                                  cursorT: $cursorT) { cursor in
            lineChart(points, seriesName: "Ground contact", unit: "ms", color: WorkoutPalette.groundContact, cursor: cursor)
        }
    }

    // MARK: - Stroke rate (replaces the old raw-cumulative "Strokes" chart)

    /// `strokeSeries` is a CUMULATIVE counter (`FitnessSample.Kind.strokeCount`); charted raw it's
    /// a near-straight diagonal that answers nothing. Differencing consecutive points and dividing
    /// by the time delta turns it into strokes/minute — did the swimmer slow down.
    private func strokeRateSeries(_ cumulative: [WorkoutMetricPoint]) -> [WorkoutMetricPoint] {
        // Sort and guard non-decreasing values first — mirrors WorkoutSplits.swolfRows, which
        // reads this same cumulative strokeSeries and applies the identical defense (sensor
        // jitter or a resampled/duplicate timestamp could otherwise plot a negative strokes/min).
        let sorted = cumulative.sorted { $0.t < $1.t }
        return zip(sorted, sorted.dropFirst()).compactMap { a, b in
            let dt = b.t - a.t
            guard dt > 0, b.value >= a.value else { return nil }
            return WorkoutMetricPoint(t: b.t, value: (b.value - a.value) / dt * 60)
        }
    }

    private var strokeRatePoints: [WorkoutMetricPoint] { strokeRateSeries(workout.strokeSeries) }

    private var strokeRateChart: some View {
        WorkoutChartFrame(title: "Stroke rate", unit: "strokes/min",
                           maximum: strokeRatePoints.map(\.value).max(),
                           cursorT: $cursorT) { cursor in
            lineChart(strokeRatePoints, seriesName: "Stroke rate", unit: "strokes/min", color: WorkoutPalette.strokeRate, cursor: cursor)
        }
    }

    // MARK: - Shared chart body: line + shared-clock cursor + drag-to-scrub

    private func lineChart(_ points: [WorkoutMetricPoint], seriesName: String, unit: String, color: Color,
                            cursor: Binding<TimeInterval?>) -> some View {
        Chart {
            ForEach(points, id: \.t) { point in
                LineMark(x: .value("Time", point.t / 60), y: .value(seriesName, point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(color)
            }
            if let t = cursor.wrappedValue {
                RuleMark(x: .value("Cursor", t / 60))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXScale(domain: xDomain)
        // Series can run past the workout's length (a trimmed recording keeps its raw samples);
        // keep them inside the plot rather than drawn over the axis.
        .chartPlotStyle { plot in plot.clipped() }
        // Ticks say their unit ("20m"); axis titles only reserved an empty band under the plot.
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let m = value.as(Double.self) { Text(DS.duration(minutes: m)) }
                }
            }
        }
        .chartOverlay { proxy in scrubOverlay(proxy, cursor: cursor) }
    }

    /// Any chart's tap writes the one shared clock (spec §4.3) — this is "one clock", not a
    /// per-chart illusion of sync: the map marker and every other chart's `RuleMark` read the same
    /// value this writes. `ChartScrubOverlay` (below) is what actually attaches the gesture — see
    /// its doc comment for why this is a tap, not the drag it used to be.
    private func scrubOverlay(_ proxy: ChartProxy, cursor: Binding<TimeInterval?>) -> some View {
        ChartScrubOverlay(proxy: proxy, cursor: cursor)
    }
}

/// A chart's tap-to-inspect hit area — reads the x position of a single tap and writes the shared
/// scrub clock, rather than following a continuous drag.
///
/// This used to be a plain `.gesture(DragGesture(minimumDistance: 0))` wired straight to
/// `cursor.wrappedValue` on every `onChanged`, dragging along the chart to scrub it. Regression:
/// `.gesture` (not `.simultaneousGesture`) wins first-touch priority over an ancestor `ScrollView`
/// per SwiftUI's own gesture disambiguation, and `minimumDistance: 0` claims the touch before any
/// direction is even known. Since every chart here sits inside `WorkoutDetailScreen`/
/// `WideWorkoutDetailView`'s vertical `ScrollView`, and the Heart Rate chart is the first large,
/// full-width element below the hero header — the single most natural place for a first scroll
/// attempt to land — this silently ate the page's scroll the moment a drag touched down on any
/// chart, in any direction.
///
/// The obvious-looking fix — `.simultaneousGesture(DragGesture(...))` plus a direction gate so a
/// vertical drag never updates `cursor`, exactly how `HandPathView.orbitDrag` reads on paper — was
/// tried and measured NOT to work here: a real `XCUIApplication` drag beginning on a
/// `.simultaneousGesture`-attached `DragGesture` still measured 0pt of page movement, direction
/// gate or not, `minimumDistance: 4` or a `LongPressGesture.sequenced(before:)` that fails outright
/// on a quick swipe. `.simultaneousGesture`'s "the ancestor `ScrollView` is never pre-empted"
/// guarantee did not hold for ANY `DragGesture`-shaped recognizer attached to a descendant of this
/// `ScrollView` on this SDK. A plain `.onTapGesture`, by contrast, measured clean: the identical
/// swipe that a `DragGesture` swallowed moved the page 320+pt once the gesture here was changed to
/// a tap (see `WorkoutDetailScrollUITest` in `BananaUITests`) — a `UITapGestureRecognizer` fails
/// out of a moving touch's way in a manner a `UIPanGestureRecognizer`-backed `DragGesture` here did
/// not, simultaneous or not. `HandPathView`'s hand-path canvas hit the identical wall and is fixed
/// the same way this file was: no `DragGesture` left on the scrolling page at all — see its
/// `expandedCanvas` doc comment for the on-canvas-orbit case, where a tap can't substitute and the
/// fix is a full-screen sheet instead.
///
/// Trade-off: dragging along a chart no longer scrubs it continuously — a drag anywhere on the
/// page, chart included, only ever scrolls now. A tap still sets the cursor to that exact instant,
/// which is what every chart's `RuleMark` and the route map's marker actually key off; the reading
/// simply updates per tap instead of following a moving finger.
private struct ChartScrubOverlay: View {
    let proxy: ChartProxy
    @Binding var cursor: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard let plotFrame = proxy.plotFrame else { return }
                    let origin = geometry[plotFrame].origin
                    guard let minute: Double = proxy.value(atX: location.x - origin.x) else { return }
                    cursor = max(0, minute) * 60
                }
        }
    }
}

/// Time in each heart-rate zone, under the heart-rate chart: one bar per zone on the shared
/// zone ramp, a zone with no time faded back, and the headline in words — "Most time in Tempo".
private struct HeartRateZonesCard: View {
    let workout: FitnessSessionSummary
    @State private var recentMax: Double?

    var body: some View {
        let ceiling = recentMax ?? HeartRateZones.estimatedMax(peaks: workout.heartRateSeries.map(\.bpm))
        let totals = HeartRateZones.timeInZones(workout.heartRateSeries, max: ceiling)
        let total = max(1, totals.reduce(0, +))
        let ranges = HeartRateZones.ranges(max: ceiling)
        let top = totals.enumerated().max { $0.element < $1.element }?.offset ?? 0

        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                WorkoutSectionLabel(title: "Heart-rate zones")
                Spacer(minLength: DS.Space.s)
                Text("Most time in \(HeartRateZones.names[top])")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(0..<totals.count, id: \.self) { index in
                HStack(spacing: DS.Space.s) {
                    Text(HeartRateZones.names[index])
                        .font(.caption)
                        .frame(width: 74, alignment: .leading)
                    Text(rangeText(ranges[index]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(DS.Tint.subtle))
                            Capsule().fill(DS.Palette.zones[index])
                                .frame(width: max(totals[index] > 0 ? 4 : 0, proxy.size.width * totals[index] / total))
                        }
                    }
                    .frame(height: 8)
                    Text(WorkoutComparisons.durationText(totals[index]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .opacity(totals[index] > 0 ? 1 : DS.Tint.strong)
            }
        }
        .padding(WorkoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .task(id: workout.id) {
            // Your own peak over the last six months: the recent summaries' top readings.
            let cutoff = Date().addingTimeInterval(-182 * 86_400)
            let peaks = FitnessStore.shared.summaries
                .filter { $0.start > cutoff }
                .compactMap { $0.heartRateSeries.map(\.bpm).max() }
            recentMax = HeartRateZones.estimatedMax(peaks: peaks + workout.heartRateSeries.map(\.bpm))
        }
    }

    private func rangeText(_ range: (lower: Int, upper: Int?)) -> String {
        range.upper.map { "\(range.lower)\u{2013}\($0)" } ?? "\(range.lower)+"
    }
}
