import SwiftUI
import Charts
import MapKit
import CoreLocation

/// Workouts on the Mac — your training, on a screen big enough to see it.
///
/// A Watch records the workout and the phone is the hub that aggregates it; the Mac has neither, so
/// this reads the workout SUMMARIES that sync from the phone via iCloud (small aggregate rows —
/// activity, duration, distance, average heart rate, energy, and a downsampled route), plus the
/// portable Health context imported on the phone. A Mac's own HealthKit store is effectively empty;
/// it renders that synced cache rather than pretending it can query the phone's database.
struct WideWorkoutsView: View {
    @EnvironmentObject var fitness: FitnessStore
    @EnvironmentObject var health: HealthKitStore
    @EnvironmentObject var settings: AppSettings
    /// This week. Earlier periods, and how they compare, are Review's (`PageChromeRules`); the
    /// way to an older workout is "Show all", as on the phone.
    @State private var period = RhythmPeriod.current
    @State private var showAll = false
    @State private var filter = LiveFilter(scope: "workouts")
    @State private var autoOpen: FitnessSessionSummary?
    /// A workout deleted a moment ago stays hidden until its Undo window closes.
    @ObservedObject private var toasts = ToastCenter.shared
    /// Where you are in Workouts, kept with the phone's (`ShellState.workouts`): a full-width
    /// iPad forgot it whenever the app came back or the window changed width, and the Mac
    /// whenever you looked at another section.
    @ObservedObject private var shell = ShellNavigation.shared

    /// The page's stack. Its path is the shell's, so it is kept, restored, and shared with the
    /// narrow layout; one route type for every screen it can open (`WorkoutsRouteScreen`). The
    /// Mac had its own stack, which could open a workout Banana recorded and nothing else.
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { shell.state.workouts }, set: { shell.state.workouts = $0 })) {
            content()
                .navigationDestination(for: ShellState.WorkoutsRoute.self) { WorkoutsRouteScreen(route: $0, wide: true) }
        }
    }

    /// The launch arguments that open this page somewhere, for looking at it and for the
    /// store's screenshots.
    private func openSampleRoute(_ data: PeriodData) {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--mac-workout-period"), i + 1 < args.count,
           let g = RhythmGranularity(rawValue: args[i + 1]) {
            period = RhythmPeriod(granularity: g, offset: 0)
        }
        if let i = args.firstIndex(of: "--mac-workout-id"), i + 1 < args.count {
            let needle = args[i + 1]
            autoOpen = data.entries.compactMap(\.summary)
                .first { $0.id.uuidString.localizedCaseInsensitiveContains(needle) }
        } else if args.contains("--mac-workout-detail") {
            autoOpen = data.entries.compactMap(\.summary).first
        }
        #if DEBUG
        // `--workouts-route guided-plans|plan|coach|sleep|health-only`: a screen of this
        // page, to look at and to photograph for the store.
        if let i = args.firstIndex(of: "--workouts-route"), i + 1 < args.count, shell.state.workouts.isEmpty {
            switch args[i + 1] {
            case "guided-plans" where Features.guidedPlans: shell.state.workouts = [.guidedPlans]
            case "sleep": shell.state.workouts = [.sleep]
            case "plan" where Features.guidedPlans:
                if let plan = WellnessStore.shared.workoutPlans.first {
                    shell.state.workouts = [.guidedPlans, .plan(plan.id)]
                }
            case "coach" where Features.guidedPlans:
                if let plan = WellnessStore.shared.workoutPlans.first {
                    shell.state.workouts = [.guidedPlans, .plan(plan.id), .coach(plan.id)]
                }
            case "health-only":
                if let entry = data.entries.first(where: { $0.summary == nil }) {
                    shell.state.workouts = [.workout(entry.id)]
                }
            default: break
            }
        }
        #endif
    }

    private struct PeriodData {
        var entries: [WorkoutEntry]
        /// The same stretch of the period before (`PeriodPace`).
        var before: [WorkoutEntry]
        var workoutCount: Int { entries.count }
    }

    /// One pass over each lifetime store per render. The old computed-property graph repeatedly
    /// filtered/sorted the same arrays for the empty state, header, and auto-open. That made
    /// changing Week → Month → Quarter progressively slower as history grew.
    private func makePeriodData() -> PeriodData {
        let match = filter.predicate()
        let range = showAll || !filter.isEmpty ? (start: Date.distantPast, end: Date.distantFuture) : period.range()
        var selected: [FitnessSessionSummary] = []
        for workout in fitness.summaries where workout.start >= range.start && workout.start < range.end {
            selected.append(workout)
        }
        let healthInRange = health.workouts.filter { $0.start >= range.start && $0.start < range.end }
        let span = PeriodPace.comparison(for: period, calendar: .app, now: Date())
        let before = WorkoutEntry.merge(summaries: fitness.summaries.filter { span.contains($0.start) },
                                        health: health.workouts.filter { span.contains($0.start) },
                                        hiddenHealthIDs: health.hiddenWorkoutIDs)
        return PeriodData(entries: WorkoutRemoval.visible(
                              WorkoutEntry.merge(summaries: selected, health: healthInRange,
                                                 hiddenHealthIDs: health.hiddenWorkoutIDs),
                              hiding: toasts.hiddenIDs).filter { match($0.start, $0.activity, $0.activity, $0.duration) },
                          before: before)
    }

    var body: some View {
        let _ = RenderStats.note("WideWorkoutsView")
        let data = makePeriodData()
        // Everything is grouped by month, as a year was.
        let groups = WorkoutGrouping.grouped(data.entries, granularity: showAll ? .year : period.granularity)
        stack {
            GeometryReader { geo in
                // Controls, summary, and rows share the same readable desktop column.
                let navInset = max(DS.Space.xl, (geo.size.width - WorkoutMetrics.listContentMaxWidth) / 2)

                VStack(spacing: 0) {
                    // The one date line (`PageChrome`): the toolbar's on the Mac, a row on an
                    // iPad. A week at a time, as Plan steps days; "Show all" beside it.
                    DateLine(current: !filter.isEmpty ? "Filtered workouts" : showAll ? "All workouts" : "This week",
                             dates: !filter.isEmpty ? "" : showAll ? "" : period.rangeLabel(),
                             isCurrent: showAll || period.offset == 0,
                             canGoForward: !showAll && period.canGoForward, unit: "week",
                             titleIdentifier: "workouts.period",
                             step: { delta in showAll = false; period = period.stepped(by: delta) },
                             toCurrent: { showAll = false; period = .current }) {
                        Button(showAll ? "Show week" : "Show all") { withAnimation { showAll.toggle() } }
                            .buttonStyle(.inline)
                            .accessibilityIdentifier("workouts.showAll")
                    }
                    .disabled(!filter.isEmpty)
                    #if os(iOS)
                    .padding(.horizontal, navInset - DS.Space.s)
                    #endif
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: WorkoutMetrics.listRowSpacing) {
                            // The week's summary heads its card; all workouts, or none, get it
                            // in a card of its own.
                            LiveFilterSearch(scope: "workouts", filter: $filter).padding(.horizontal, navInset).padding(.top, DS.Space.s)
                            if showAll || data.workoutCount == 0 {
                                summaryStrip(data)
                                    .padding(.vertical, DS.Space.m)
                                    .frame(maxWidth: WorkoutMetrics.listContentMaxWidth)
                                    .dsCard()
                                    .padding(.horizontal, navInset)
                            }

                            // Guided plans, as the phone's list has: they belong with workouts
                            // and had no door on the wide page, or on the Mac at all.
                            if Features.guidedPlans {
                            NavigationLink(value: ShellState.WorkoutsRoute.guidedPlans) {
                                HStack {
                                    Label("Guided plans", systemImage: "figure.strengthtraining.traditional")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(DS.Space.m)
                                .dsCard()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, navInset)
                            .accessibilityIdentifier("workouts.guidedPlans")
                            }

                            Group {
                                if data.workoutCount == 0 {
                                    ContentUnavailableView {
                                        Label(!filter.isEmpty ? "No matching workouts" : showAll ? "No workouts yet" : "No workouts this week", systemImage: "figure.run")
                                    } description: {
                                        Text("Watch workouts sync here through your iPhone.")
                                    }
                                    .frame(maxWidth: .infinity)
                                } else if showAll {
                                    ForEach(groups) { group in
                                        groupSection(group)
                                    }
                                } else {
                                    groupCard(data.entries, summary: data)
                                }
                            }
                            .frame(maxWidth: WorkoutMetrics.listContentMaxWidth, alignment: .leading)
                            .padding(.horizontal, navInset)
                        }
                        .padding(.vertical, 20)
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationDestination(item: $autoOpen) { WideWorkoutDetailView(workout: $0) }
            .onAppear { openSampleRoute(data) }
            // The sample workouts can arrive after the page (the store reads its index first).
            .onChange(of: fitness.summaries.count) { openSampleRoute(data) }
            // Inside the stack, where a toolbar belongs to a page.
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ReviewToolbarItem(section: .workouts)
                ToolbarItem(placement: .automatic) { MoreMenu() }
            }
            .bodySwitch(wide: true)
            // As the phone's: the + opens the list of everything.
            .addListButton(identifier: "workouts.add")
            #endif
        }
        .navigationTitle("Workouts")
    }

    // MARK: - Summary strip

    /// Selected period at a glance, replacing the old hero-card + `stat` row double statement
    /// (spec §3.3) with one row of `WorkoutMetricTile`s: workouts (always, "0" not "–" when
    /// empty), distance (only when any is recorded), moving time (always), and avg BPM (new —
    /// the mean of every entry's nonzero average heart rate).
    private func summaryStrip(_ data: PeriodData) -> some View {
        let count = data.workoutCount
        let meters = data.entries.compactMap(\.distanceMeters).reduce(0, +)
        let seconds = data.entries.reduce(0.0) { $0 + $1.duration }
        // Health's own average when Banana didn't record the workout.
        let heartRates = data.entries.compactMap { $0.summary?.avgHeartRate ?? $0.health?.avgHeartRate }.filter { $0 > 0 }
        let avgBPM = heartRates.isEmpty ? nil : heartRates.reduce(0, +) / Double(heartRates.count)
        return HStack(spacing: 0) {
            WorkoutMetricTile(value: "\(count)", label: count == 1 ? "Workout" : "Workouts", alignment: .center)
            if meters > 0 {
                WorkoutMetricTile(value: settings.distanceUnit.format(meters: meters), label: "Distance", alignment: .center)
            }
            WorkoutMetricTile(value: Self.activeText(seconds), label: "Active", alignment: .center)
            if let avgBPM {
                WorkoutMetricTile(value: "\(Int(avgBPM.rounded()))", label: "Avg BPM", alignment: .center)
            }
        }
        .frame(maxWidth: WorkoutMetrics.navColumnMaxWidth)
    }

    /// "5h 48m", "45m": the app's one duration format.
    private static func activeText(_ seconds: TimeInterval) -> String {
        DS.duration(minutes: seconds / 60)
    }

    // MARK: - Groups

    /// A month under its own header when everything is shown; one card per group either way.
    @ViewBuilder
    private func groupSection(_ group: WorkoutGroup) -> some View {
        Section {
            groupCard(group.entries)
        } header: {
            groupHeader(group)
        }
    }

    /// The workouts in one card, a line between rows, as the phone's grouped list. Each row's
    /// own date line says the day, so a week needs no header per day.
    private func groupCard(_ entries: [WorkoutEntry], summary: PeriodData? = nil) -> some View {
        VStack(spacing: 0) {
            if let summary {
                summaryStrip(summary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.m)
                Divider()
            }
            ForEach(entries) { entry in
                if entry.id != entries.first?.id {
                    Divider().padding(.leading, WorkoutMetrics.rowPadding + WorkoutMetrics.rowGlyphSize + 14)
                }
                entryRow(entry)
            }
        }
        .dsCard()
    }

    private func groupHeader(_ group: WorkoutGroup) -> some View {
        let meters = group.entries.compactMap(\.distanceMeters).reduce(0, +)
        let count = group.entries.count
        let workoutWord = count == 1 ? "workout" : "workouts"
        return HStack(alignment: .firstTextBaseline) {
            Text(group.title).font(WorkoutType.groupHeader)
            Spacer()
            Text(meters > 0 ? "\(count) \(workoutWord) · \(settings.distanceUnit.format(meters: meters))"
                            : "\(count) \(workoutWord)")
                .font(WorkoutType.groupHeaderDetail)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private func entryRow(_ entry: WorkoutEntry) -> some View {
        if let workout = entry.summary {
            NavigationLink(value: ShellState.WorkoutsRoute.workout(entry.id)) {
                WorkoutRow(workout: workout)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    // As the phone's list, on every device: gone at once, with Undo, its Health
                    // half with it (`WorkoutRemoval`). The Mac asked first, and warned that its
                    // delete couldn't reach the phone's Health copy.
                    WorkoutRemoval.remove(entry, fitness: fitness, health: health)
                } label: {
                    Label("Delete workout", systemImage: "trash")
                }
            }
        } else if let workout = entry.health {
            // Health-only row: no Banana summary to delete, so the menu offers whichever action
            // is actually legal — a real delete when Banana wrote the HKWorkout, otherwise Hide
            // (Banana can never delete another source's Health data — see `canDeleteFromHealth`).
            // On an iPad or the Mac either one hides the copy here and asks the phone, which
            // owns Health, to do it (`HealthRemovalInbox`).
            // A workout that's only in Health opens too, as it does in the phone's list: on the
            // Mac the row went nowhere.
            NavigationLink(value: ShellState.WorkoutsRoute.workout(entry.id)) {
                HealthWorkoutRow(workout: workout)
            }
            .buttonStyle(.plain)
                .contextMenu {
                    if health.canDeleteFromHealth(workout) {
                        Button(role: .destructive) {
                            Task { await health.remove(workoutID: workout.id) }
                        } label: {
                            Label("Delete workout", systemImage: "trash")
                        }
                    } else {
                        Button {
                            health.hide(workout.id)
                        } label: {
                            Label("Hide", systemImage: "eye.slash")
                        }
                    }
                }
        }
    }
}

/// One workout, one row, four fixed-width metric columns — every row uses the same column
/// widths regardless of which fields this particular workout has (spec §3.5), so a pool swim and
/// a run in the same group stay aligned instead of each row's content dictating its own layout.
private struct WorkoutRow: View {
    let workout: FitnessSessionSummary
    @EnvironmentObject private var settings: AppSettings

    private var kind: WorkoutActivityKind { WorkoutActivityKind(activity: workout.activity) }

    var body: some View {
        HStack(spacing: 14) {
            // Its route, or its symbol: the phone's thumbnail (`WorkoutThumbnail`).
            WorkoutThumbnail(activity: workout.activity, route: workout.route, size: WorkoutMetrics.rowGlyphSize)
            titleBlock
            Spacer(minLength: DS.Space.s)
            metricsRow
            RowChevron()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkoutMetrics.rowPadding)
        .contentShape(Rectangle())
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workout.activity).font(WorkoutType.rowTitle).lineLimit(1)
            // The phone's format: no year.
            Text(workout.start, format: .dateTime.weekday().month().day().hour().minute())
                .font(WorkoutType.rowSubtitle).foregroundStyle(.secondary)
        }
        .frame(width: WorkoutMetrics.rowTitleWidth, alignment: .leading)
    }

    private var metricsRow: some View {
        HStack(spacing: WorkoutMetrics.rowMetricSpacing) {
            metric(WorkoutComparisons.durationText(workout.activeDuration), "Time",
                   width: WorkoutMetrics.rowMetricColumnWidths[0])
            metric(distanceOrLapsValue, distanceOrLapsLabel,
                   width: WorkoutMetrics.rowMetricColumnWidths[1])
            metric(paceOrAvgLapValue, paceOrAvgLapLabel,
                   width: WorkoutMetrics.rowMetricColumnWidths[2])
            metric(bpmValue, "Avg BPM", width: WorkoutMetrics.rowMetricColumnWidths[3])
        }
    }

    private func metric(_ value: String?, _ label: String, width: CGFloat) -> some View {
        WorkoutMetricTile(value: value, label: label, alignment: .trailing, size: .row)
            .frame(width: width)
    }

    // MARK: - Column values

    private var lapCount: Int? {
        if !workout.laps.isEmpty { return workout.laps.count }
        guard let distance = workout.totalDistance else { return nil }
        let length = workout.poolLengthMeters ?? settings.poolLength.meters
        guard length > 0 else { return nil }
        return Int((distance / length).rounded(.down))
    }

    private var averageLapTime: TimeInterval {
        if !workout.laps.isEmpty {
            return workout.laps.map(\.duration).reduce(0, +) / Double(workout.laps.count)
        }
        guard let laps = lapCount, laps > 0 else { return 0 }
        return workout.activeDuration / Double(laps)
    }

    private var distanceOrLapsLabel: String { kind.usesLaps ? "Laps" : "Dist" }
    private var distanceOrLapsValue: String? {
        if kind.usesLaps {
            guard let laps = lapCount, laps > 0 else { return nil }
            return "\(laps)"
        }
        guard let d = workout.totalDistance, d > 0 else { return nil }
        return settings.distanceUnit.format(meters: d)
    }

    private var paceOrAvgLapLabel: String { kind.usesLaps ? "Avg lap" : (kind.usesPace ? "Pace" : "Speed") }
    private var paceOrAvgLapValue: String? {
        if kind.usesLaps {
            guard let laps = lapCount, laps > 0 else { return nil }
            return WorkoutComparisons.durationText(averageLapTime)
        }
        guard kind.usesPace || kind == .cycling,   // running/walking/etc. get pace, cycling gets speed
              let d = workout.totalDistance, d > 0, workout.activeDuration > 0 else { return nil }
        return kind.usesPace
            ? WorkoutComparisons.paceText(distance: d, seconds: workout.activeDuration, unit: settings.distanceUnit)
            : WorkoutComparisons.speedText(distance: d, seconds: workout.activeDuration, unit: settings.distanceUnit)
    }

    private var bpmValue: String? {
        guard let hr = workout.avgHeartRate, hr > 0 else { return nil }
        return "\(Int(hr.rounded()))"
    }
}

/// A workout read from the phone's Apple Health cache rather than recorded by Banana. It has the
/// same list-level facts as iOS, but no local raw route/sample file to open on this Mac.
///
/// Shares `WorkoutRow`'s fixed-column skeleton (glyph / title block / mini-visual / four metric
/// columns) instead of its own free-floating trailing `VStack` — a Health row sits in the same
/// `ForEach` as Banana-recorded rows (`entryRow(_:)` above), so its Time/Dist values must land
/// under the same TIME/DIST/PACE/AVG BPM columns as the surrounding rows or the whole group looks
/// broken rather than merely "less data available" (spec §3.5's column-alignment guarantee,
/// extended to the one row type that predates it).
private struct HealthWorkoutRow: View {
    let workout: HealthWorkout
    @EnvironmentObject private var settings: AppSettings

    private var kind: WorkoutActivityKind { WorkoutActivityKind(activity: workout.activity) }

    var body: some View {
        HStack(spacing: 14) {
            WorkoutThumbnail(activity: workout.activity, route: [], size: WorkoutMetrics.rowGlyphSize)
            titleBlock
            Spacer(minLength: DS.Space.s)
            metricsRow
            RowChevron()
        }
        .padding(WorkoutMetrics.rowPadding)
        .contentShape(Rectangle())
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workout.activity).font(WorkoutType.rowTitle).lineLimit(1)
            // The phone's format: no year.
            Text(workout.start, format: .dateTime.weekday().month().day().hour().minute())
                .font(WorkoutType.rowSubtitle).foregroundStyle(.secondary)
        }
        .frame(width: WorkoutMetrics.rowTitleWidth, alignment: .leading)
    }

    private var metricsRow: some View {
        HStack(spacing: WorkoutMetrics.rowMetricSpacing) {
            metric(WorkoutComparisons.durationText(workout.duration), "Time",
                   width: WorkoutMetrics.rowMetricColumnWidths[0])
            metric(distanceValue, "Dist", width: WorkoutMetrics.rowMetricColumnWidths[1])
            metric(paceValue, kind.usesPace ? "Pace" : "Speed", width: WorkoutMetrics.rowMetricColumnWidths[2])
            metric(bpmValue, "Avg BPM", width: WorkoutMetrics.rowMetricColumnWidths[3])
        }
    }

    private func metric(_ value: String?, _ label: String, width: CGFloat) -> some View {
        WorkoutMetricTile(value: value, label: label, alignment: .trailing, size: .row)
            .frame(width: width)
    }

    private var distanceValue: String? {
        guard let d = workout.distanceMeters, d > 0 else { return nil }
        return settings.distanceUnit.format(meters: d)
    }

    private var paceValue: String? {
        guard kind.usesPace || kind == .cycling,
              let d = workout.distanceMeters, d > 0, workout.duration > 0 else { return nil }
        return kind.usesPace
            ? WorkoutComparisons.paceText(distance: d, seconds: workout.duration, unit: settings.distanceUnit)
            : WorkoutComparisons.speedText(distance: d, seconds: workout.duration, unit: settings.distanceUnit)
    }

    private var bpmValue: String? {
        guard let hr = workout.avgHeartRate, hr > 0 else { return nil }
        return "\(Int(hr.rounded()))"
    }
}

