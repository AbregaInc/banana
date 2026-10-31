import SwiftUI
import Charts
import MapKit

/// The workout payoff: shown the first time you come back to the app after a workout. The
/// numbers that matter, how they compare with your last 90 days of the same activity, the
/// heart-rate curve and the route — and a way into the full analysis. Same shape as the morning
/// briefing, on purpose: you open the app, it tells you how it went.
struct PostWorkoutReviewView: View {
    let subject: WorkoutReviewSubject

    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        statCard
                        comparisonCard
                        if let summary = subject.summary, summary.heartRateSeries.count > 1 {
                            heartRateCard(summary.heartRateSeries)
                        }
                        if let summary = subject.summary, summary.route.count > 1 {
                            if summary.route.isOnePlace, let center = summary.route.center {
                                WorkoutPlaceMap(center: center, activity: summary.activity, height: 220)
                            } else {
                                routeCard(summary.route)
                            }
                        }
                        if let summary = subject.summary, isPoolSwim, !summary.laps.isEmpty {
                            // Pool swim with recorded laps: SWOLF, not distance splits — a pool
                            // swim's `distanceSplits` is usually empty anyway (no GPS to derive
                            // 1 km/1 mi checkpoints from), but the lap check comes first so a
                            // pool swim never falls through to the GPS-shaped table below.
                            swolfCard(WorkoutSplits.swolfRows(laps: summary.laps, strokeSeries: summary.strokeSeries))
                        } else if let summary = subject.summary,
                                  case let splits = WorkoutSplits.distanceSplits(for: summary, unit: settings.distanceUnit),
                                  !splits.isEmpty {
                            splitsCard(splits, partial: WorkoutSplits.finalPartial(for: summary, unit: settings.distanceUnit))
                        }
                        fullAnalysisLink
                            .id("end")
                    }
                    .padding(DS.Space.l)
                    // A column on a wide screen, as the briefing is.
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                .groupedPage()
                .onAppear {
                    #if DEBUG
                    // Layout verification of the lower half: `--workout-review-end` lands scrolled.
                    if ProcessInfo.processInfo.arguments.contains("--workout-review-end") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    #endif
                }
            }
            // The title rides in the bar, so scrolled content never slides under Done.
            .navigationTitle(praise)
            .navigationSubtitle("\(subject.activity) · \(whenText)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 780)
        #endif
    }

    // MARK: - Header

    /// "Nice run" beats "Workout complete": it names what you did.
    private var praise: String {
        let a = subject.activity.lowercased()
        if a.contains("run") { return "Nice run" }
        if a.contains("swim") || a.contains("open water") { return "Nice swim" }
        if a.contains("cycl") || a.contains("bike") { return "Nice ride" }
        if a.contains("walk") { return "Nice walk" }
        if a.contains("hik") { return "Nice hike" }
        if a.contains("row") { return "Nice row" }
        if a.contains("yoga") { return "Nice session" }
        return "Workout done"
    }

    private var whenText: String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(subject.start) { day = "Today" }
        else if cal.isDateInYesterday(subject.start) { day = "Yesterday" }
        else { day = subject.start.formatted(.dateTime.weekday(.wide)) }
        let from = subject.start.formatted(date: .omitted, time: .shortened)
        let to = subject.end.formatted(date: .omitted, time: .shortened)
        return "\(day) \(from)–\(to)"
    }

    // MARK: - Stat rows

    private struct StatRow: Identifiable {
        let title: String
        let value: String
        /// A secondary fact under the value (peak heart rate, average lap).
        var detail: String? = nil
        var id: String { title }
    }

    private var isPoolSwim: Bool { subject.activity.localizedCaseInsensitiveContains("pool swim") }
    private var isSwim: Bool { subject.activity.localizedCaseInsensitiveContains("swim") || subject.activity.localizedCaseInsensitiveContains("open water") }
    private var isCycling: Bool { subject.activity.localizedCaseInsensitiveContains("cycl") }
    private var usesPace: Bool { !isSwim && !isCycling }

    private var lapCount: Int? {
        guard let summary = subject.summary, isPoolSwim else { return nil }
        if !summary.laps.isEmpty { return summary.laps.count }
        guard let distance = summary.totalDistance else { return nil }
        let length = summary.poolLengthMeters ?? settings.poolLength.meters
        guard length > 0 else { return nil }
        return Int((distance / length).rounded(.down))
    }

    private var statRows: [StatRow] {
        var rows: [StatRow] = []
        // The workout detail's words and values (`WorkoutHeroHeader`): active time, pauses left out.
        rows.append(StatRow(title: "Time", value: durationText(subject.duration)))
        if let laps = lapCount, laps > 0, let summary = subject.summary {
            let avg = summary.laps.isEmpty ? summary.activeDuration / Double(laps)
                                            : summary.laps.map(\.duration).reduce(0, +) / Double(laps)
            rows.append(StatRow(title: "Laps", value: "\(laps)", detail: "avg \(durationText(avg))"))
        } else if let d = subject.distanceMeters {
            rows.append(StatRow(title: "Distance", value: settings.distanceUnit.format(meters: d)))
            if subject.duration > 0 {
                if usesPace {
                    rows.append(StatRow(title: "Pace", value: paceText(distance: d, seconds: subject.duration)))
                } else {
                    rows.append(StatRow(title: "Speed", value: speedText(distance: d, seconds: subject.duration)))
                }
            }
        }
        if let hr = subject.avgHeartRate {
            // The recorded series' peak first, as the detail's chart shows it; Health's max otherwise.
            let peak = subject.summary?.heartRateSeries.map(\.bpm).max().flatMap { $0 > 0 ? $0 : nil } ?? subject.maxHeartRate
            rows.append(StatRow(title: "Avg BPM", value: "\(Int(hr.rounded()))",
                                detail: peak.map { "max \(Int($0.rounded()))" }))
        }
        if let e = subject.energyKcal {
            rows.append(StatRow(title: "Calories", value: Int(e.rounded()).formatted()))
        }
        if subject.summary?.stayedInOnePlace != true, let gain = subject.summary?.insights?.elevationGain, gain >= 5 {
            rows.append(StatRow(title: "Elevation gain", value: "\(Int(gain.rounded())) m"))
        }
        return rows
    }

    /// Three across, a line between rows, in one card: the same stat card as the workout
    /// detail's top (`WorkoutHeroHeader`).
    private static let statColumns = 3

    private var statCard: some View {
        let all = statRows
        let columns = Self.statColumns
        let rows = stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { r in
                if r > 0 {
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        if c < rows[r].count {
                            WorkoutMetricTile(value: rows[r][c].value, label: rows[r][c].title,
                                              alignment: .leading, footnote: rows[r][c].detail)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
        .padding(DS.Space.l)
        .dsCard()
    }

    // MARK: - Compared with the last 90 days

    private var peers: [WorkoutReviewSubject] {
        WorkoutReviewCoordinator.recentPeers(of: subject, summaries: fitness.summaries, healthWorkouts: health.workouts)
    }

    /// Delegates to `WorkoutComparisons.compute` (`Banana/Model/WorkoutComparison.swift`) —
    /// lifted out of this view so the Mac detail view's own "compared with your last 90 days"
    /// card can reuse the exact same computation instead of re-deriving it.
    private var comparisons: [WorkoutComparison] {
        WorkoutComparisons.compute(subject: subject, peers: peers,
                                    distanceUnit: settings.distanceUnit, usesPace: usesPace)
    }

    /// Nothing to compare with: no card, rather than a note saying so.
    @ViewBuilder private var comparisonCard: some View {
        let peers = self.peers
        if !peers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Compared with your last 90 days")
                        .font(.headline)
                    Spacer()
                    Text("\(peers.count) \(subject.activity.lowercased()) \(peers.count == 1 ? "workout" : "workouts")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(comparisons) { c in
                    HStack(spacing: 10) {
                        Text(c.title).font(.subheadline)
                        Spacer()
                        Text(c.now).font(.subheadline.weight(.semibold).monospacedDigit())
                        Text("usually \(c.usual)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(c.deltaPercent == 0 ? "±0%" : String(format: "%+d%%", c.deltaPercent))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(c.tone)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupedCard()
        }
    }

    // MARK: - Heart rate

    private func heartRateCard(_ series: [HRPoint]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heart rate").font(.headline)
            Chart(series, id: \.t) { point in
                LineMark(x: .value("Minute", point.t / 60), y: .value("BPM", point.bpm))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(DS.Palette.danger)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let m = value.as(Double.self) { Text("\(Int(m))m") }
                    }
                }
            }
            .frame(height: 150)
        }
        .groupedCard()
    }

    // MARK: - Route

    private func routeCard(_ route: [RoutePoint]) -> some View {
        let coords = route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let lats = route.map(\.lat), lons = route.map(\.lon)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, 0.003),
                                   longitudeDelta: max((lons.max()! - lons.min()!) * 1.4, 0.003)))
        return Map(initialPosition: .region(region), interactionModes: []) {
            MapPolyline(coordinates: coords).stroke(DS.Palette.accent, lineWidth: 4)
        }
        .mapControlVisibility(.hidden)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
    }

    // MARK: - Splits

    private func splitsCard(_ splits: [DistanceSplit], partial: (meters: Double, duration: TimeInterval)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Splits").font(.headline)
            let fastest = splits.map(\.duration).min() ?? 0
            ForEach(splits.prefix(12)) { split in
                HStack {
                    Text(WorkoutSplits.label(split, unit: settings.distanceUnit))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(durationText(split.duration))
                        .font(.subheadline.weight(split.duration == fastest ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(split.duration == fastest ? DS.Palette.success : Color.primary)
                }
            }
            if splits.count > 12 {
                Text("+\(splits.count - 12) more in the full analysis").font(.caption).foregroundStyle(.secondary)
            } else if let partial {
                HStack {
                    Text(settings.distanceUnit.format(meters: partial.meters))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(durationText(partial.duration))
                        .font(.subheadline.monospacedDigit())
                }
            }
        }
        .groupedCard()
    }

    // MARK: - Splits (pool swim: SWOLF, not distance — same `WorkoutSplits.swolfRows` pipeline
    // `WorkoutSplitsSection` uses for the Mac/full-analysis detail view, so the numbers here are
    // byte-identical to what the full analysis shows for the same workout)

    private func swolfCard(_ rows: [SWOLFRow]) -> some View {
        let fastest = WorkoutSplits.fastestIndex(rows, duration: \.duration)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Splits").font(.headline)
            HStack {
                Text("Lap").frame(width: 40, alignment: .leading)
                Spacer()
                Text("Duration").frame(width: 64, alignment: .trailing)
                Text("Strokes").frame(width: 56, alignment: .trailing)
                Text("SWOLF").frame(width: 56, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated().prefix(12)), id: \.element.id) { index, row in
                let isFastest = fastest == index
                HStack {
                    Text("\(row.lapNumber)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Spacer()
                    Text(durationText(row.duration)).frame(width: 64, alignment: .trailing)
                    Text(row.strokes.map { "\($0)" } ?? "–").frame(width: 56, alignment: .trailing)
                    Text(row.swolf.map { "\($0)" } ?? "–").frame(width: 56, alignment: .trailing)
                }
                .font(.subheadline.weight(isFastest ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isFastest ? DS.Palette.success : Color.primary)
            }
            if rows.count > 12 {
                Text("+\(rows.count - 12) more in the full analysis").font(.caption).foregroundStyle(.secondary)
            }
        }
        .groupedCard()
    }

    // MARK: - Full analysis

    @ViewBuilder private var fullAnalysisLink: some View {
        #if os(iOS)
        NavigationLink {
            WorkoutDetailScreen(entry: WorkoutEntry(health: subject.health, summary: subject.summary))
        } label: {
            Label("Full analysis", systemImage: "chart.xyaxis.line")
        }
        .buttonStyle(.primaryPage)
        #else
        if let summary = subject.summary {
            NavigationLink {
                WideWorkoutDetailView(workout: summary)
            } label: {
                Label("Full analysis", systemImage: "chart.xyaxis.line")
            }
            .buttonStyle(.primaryPage)
        }
        #endif
    }

    // MARK: - Formatting

    private func durationText(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = Int(s) % 60
        if h > 0 { return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", sec))" }
        return "\(m):\(String(format: "%02d", sec))"
    }

    private func paceText(distance: Double, seconds: TimeInterval) -> String {
        let divisor = settings.distanceUnit == .miles ? 1609.344 : 1000
        let units = distance / divisor
        guard units > 0.01 else { return "—" }
        let pace = seconds / units
        let suffix = settings.distanceUnit == .miles ? "/mi" : "/km"
        return "\(Int(pace) / 60):\(String(format: "%02d", Int(pace) % 60)) \(suffix)"
    }

    private func speedText(distance: Double, seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let mps = distance / seconds
        let value = mps * (settings.distanceUnit == .miles ? 2.236936 : 3.6)
        return String(format: "%.1f %@", value, settings.distanceUnit == .miles ? "mph" : "km/h")
    }
}

#if DEBUG
/// `--workout-review` launch route: the review over a fixed sample session, for layout checks
/// on the Simulator and the Mac without waiting for a real workout.
struct PostWorkoutReviewDebugHost: View {
    @EnvironmentObject private var fitness: FitnessStore

    var body: some View {
        Group {
            if let summary = fitness.summaries.first {
                PostWorkoutReviewView(subject: WorkoutReviewSubject(summary: summary, health: nil))
            } else {
                Text("no workout")
            }
        }
        // The index decode lands asynchronously and sweeps the preview fixture out if it got
        // in first; inject only once the store has settled.
        .task { await fitness.whenLoaded(); fitness.injectSampleForPreview() }
    }
}
#endif

#if DEBUG && os(macOS)
import AppKit

/// `--snapshot-workout-review <path>`: the review as plain window content over the sample
/// session, written from the window's backing store the way MacAppStoreSnapshotHarness does —
/// a sheet lives in its own window, which that harness never captures.
@MainActor
struct MacWorkoutReviewSnapshotHarness: View {
    let outputURL: URL
    @State private var didCapture = false

    var body: some View {
        PostWorkoutReviewDebugHost()
            .frame(width: 560, height: 820)
            .task {
                guard !didCapture else { return }
                didCapture = true
                try? await Task.sleep(for: .milliseconds(2_500))
                guard let window = NSApp.keyWindow ?? NSApp.windows.first,
                      let contentView = window.contentView,
                      let view = contentView.superview ?? window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    fputs("Workout review snapshot failed: no renderable Mac window\n", stderr)
                    exit(EXIT_FAILURE)
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    fputs("Workout review snapshot failed: PNG encoding\n", stderr)
                    exit(EXIT_FAILURE)
                }
                do {
                    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try png.write(to: outputURL, options: .atomic)
                    fputs("Workout review snapshot: \(outputURL.path)\n", stderr)
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("Workout review snapshot failed: \(error)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
    }
}
#endif
