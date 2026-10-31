#if os(iOS)
// Fitness is recorded on the Watch and lives on the phone.

import SwiftUI
import Charts
import UIKit
import MapKit

/// The Workouts tab: the workout just done (with its review) and this week's sessions from the
/// Watch and Apple Health. For doing, like every tab: its period switch, its trends and the
/// Sleep row were looking back, and are in Review (the chart button) now.
struct FitnessView: View {
    @EnvironmentObject var fitness: FitnessStore
    @EnvironmentObject var health: HealthKitStore
    @EnvironmentObject var settings: AppSettings

    /// This week. Earlier weeks, and how they compare, are Review's.
    private let period: RhythmPeriod
    @State private var showAllWorkouts = false
    @State private var filter = LiveFilter(scope: "workouts")
    /// A workout deleted a moment ago stays hidden until its Undo window closes.
    @ObservedObject private var toasts = ToastCenter.shared

    init(period: RhythmPeriod = .current) {
        self.period = period
    }

    var body: some View {
        let _ = RenderStats.note("FitnessView")
        VStack(spacing: 0) {
            // One merge per render: `entries` pairs every summary with its Health record (O(n²)
            // in the worst case).
            let all = entries
            List {
                if !health.hasData {
                    connectSection
                }
                workoutsSection(all)
                if Features.guidedPlans { plansSection }
                if health.hasData { healthAccessSection }
            }
        }
        .safeAreaInset(edge: .top) { LiveFilterSearch(scope: "workouts", filter: $filter).padding(.horizontal).padding(.vertical, 8).background(.background) }
        .navigationTitle("Workouts")
        // Value-based, so the stack is stored in ShellNavigation and survives the background
        // rebuild — including a guided workout left running while the phone was locked.
        .navigationDestination(for: ShellState.WorkoutsRoute.self) { destination($0) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ReviewToolbarItem(section: .workouts)
            ToolbarItem(placement: .automatic) { MoreMenu() }
        }
        .bodySwitch()
        // Nothing of its own to add; on a phone the + opens the list of everything.
        .addListButton(identifier: "workouts.add")
        .refreshable { await health.refresh() }
        .task {
            if health.hasData { await health.refreshIfStale() }
        }
        .alert("Apple Health", isPresented: Binding(
            get: { health.errorMessage != nil },
            set: { if !$0 { health.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(health.errorMessage ?? "") }
    }

    @ViewBuilder private var connectSection: some View {
        let emptyAfterTry = health.didAttemptImport && !health.hasData

        Section {
            Button {
                Task { await health.connect() }
            } label: {
                Label(emptyAfterTry ? "Try again" : "Connect Apple Health",
                      systemImage: "heart.text.square.fill")
            }
            .disabled(!health.isAvailable || health.isImporting)

            if emptyAfterTry {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open iOS Settings", systemImage: "gear")
                }
            }
        } footer: {
            if emptyAfterTry {
                Text("No workouts came back. iOS never tells an app whether Health access was granted. If you have workouts, turn them on in **Settings › Privacy & Security › Health › Banana**, then tap Try again.")
            }
        }
    }

    /// HealthKit lets an app read back its OWN written data even without read access. So if
    /// Workouts read access is off but Banana has been writing workouts, only Banana-logged
    /// sessions appear and every other app's workout is invisible. This makes the fix findable.
    private var healthAccessSection: some View {
        Section {
            Button {
                Task { await health.connect() }
            } label: {
                Label { Text("Update Apple Health access") } icon: {
                    IconTile(systemImage: "arrow.clockwise.heart", tint: WorkoutPalette.healthSource, style: .soft)
                }
            }
            .disabled(!health.isAvailable || health.isImporting)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label { Text("Manage Apple Health access") } icon: {
                    IconTile(systemImage: "heart.text.square", tint: WorkoutPalette.healthSource, style: .soft)
                }
            }
        }
    }

    /// Each metric's last N finished days against the N before (or a past period against the
    /// one before it) — see `MetricTrends`. Totals compare per day, so a week that's under way
    /// no longer reads as everything falling.
    /// Watch summaries and Apple Health workouts, one row per session, newest first.
    private func destination(_ route: ShellState.WorkoutsRoute) -> some View {
        WorkoutsRouteScreen(route: route)
    }

    private var entries: [WorkoutEntry] {
        WorkoutRemoval.visible(
            WorkoutEntry.merge(summaries: fitness.summaries, health: health.workouts,
                               hiddenHealthIDs: health.hiddenWorkoutIDs),
            hiding: toasts.hiddenIDs)
    }

    /// Workouts scoped to the current period, unless the user asked to see everything.
    private func periodEntries(from all: [WorkoutEntry]) -> [WorkoutEntry] {
        if !filter.isEmpty { let match = filter.predicate(); return all.filter { match($0.start, $0.activity, $0.activity, $0.duration) } }
        guard !showAllWorkouts else { return all }
        let (start, end) = period.range()
        return all.filter { $0.start >= start && $0.start < end }
    }

    /// Workouts · active time · distance for the period — the tiles the Rhythm screen used to
    /// lead with, above the list they summarize.
    private func summaryStrip(_ list: [WorkoutEntry], all: [WorkoutEntry]) -> some View {
        VStack(spacing: DS.Space.xs) {
            HStack(spacing: 0) {
                stripStat("Workouts", "\(list.count)")
                Divider().frame(height: 30)
                stripStat("Active", activeText(list))
                Divider().frame(height: 30)
                stripStat("Distance", distanceText(list) ?? "—")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workouts.summaryStrip")
    }

    private func activeText(_ list: [WorkoutEntry]) -> String {
        let minutes = Int(list.reduce(0) { $0 + $1.duration } / 60)
        return minutes >= 120 ? String(format: "%.1f h", Double(minutes) / 60) : "\(minutes) min"
    }

    private func distanceText(_ list: [WorkoutEntry]) -> String? {
        let meters = list.compactMap(\.distanceMeters).reduce(0, +)
        return meters > 0 ? settings.distanceUnit.format(meters: meters) : nil
    }

    private func stripStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func workoutsSection(_ all: [WorkoutEntry]) -> some View {
        let list = periodEntries(from: all)
        return Section {
            if list.isEmpty {
                Text(!filter.isEmpty ? "No matching workouts." : showAllWorkouts ? "No workouts yet." : "No workouts \(period.label().lowercased())")
                    .foregroundStyle(.secondary)
            } else {
                summaryStrip(list, all: all)
                ForEach(list) { entry in
                    WorkoutRow(entry: entry)
                        .listRowInsets(EdgeInsets())
                        .background {
                            NavigationLink(value: ShellState.WorkoutsRoute.workout(entry.id)) { EmptyView() }.opacity(0)
                        }
                        .swipeActions {
                            if entry.summary != nil {
                                Button(role: .destructive) {
                                    // Gone at once, with Undo; removed for real — and its Apple
                                    // Health half with it — when the Undo closes (`WorkoutRemoval`).
                                    WorkoutRemoval.remove(entry, fitness: fitness, health: health)
                                } label: { Label("Delete", systemImage: "trash") }
                            } else if let hw = entry.health {
                                // Health-only row: delete when Banana wrote it, otherwise this is
                                // someone else's Health record — hide it instead (see
                                // `canDeleteFromHealth`).
                                if health.canDeleteFromHealth(hw) {
                                    Button(role: .destructive) {
                                        Task { await health.remove(workoutID: hw.id) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                } else {
                                    Button {
                                        health.hide(hw.id)
                                    } label: { Label("Hide", systemImage: "eye.slash") }
                                }
                            }
                        }
                }
            }
        } header: {
            HStack {
                Text(!filter.isEmpty ? "Matching workouts" : showAllWorkouts ? "All workouts" : "Workouts · \(period.label())")
                Spacer()
                if filter.isEmpty { Button(showAllWorkouts ? "Show \(period.granularity.rawValue)" : "Show all") {
                    withAnimation { showAllWorkouts.toggle() }
                }.buttonStyle(.inline).textCase(nil) }
            }
        }
    }

    /// The guided plans (the former Wellness "Coach" segment) belong with workouts, not meals.
    private var plansSection: some View {
        Section {
            NavigationLink(value: ShellState.WorkoutsRoute.guidedPlans) {
                Label("Guided plans", systemImage: "figure.strengthtraining.traditional")
            }
            .accessibilityIdentifier("workouts.guidedPlans")
        }
    }
}

// MARK: - Workout rows

private struct WorkoutRow: View {
    @EnvironmentObject var settings: AppSettings
    let entry: WorkoutEntry

    /// Its route (or its symbol), what and when, its numbers, the chevron. Where it came from
    /// isn't said: a "Banana" tag on every row was noise.
    var body: some View {
        let h = entry.health, s = entry.summary
        let hr = h?.avgHeartRate ?? s?.avgHeartRate
        let energy = h?.energyKcal ?? s?.totalEnergy
        let distance = h?.distanceMeters ?? s?.totalDistance
        let activity = h?.activity ?? s?.activity ?? "Workout"
        return HStack(alignment: .top, spacing: DS.Space.m) {
            WorkoutThumbnail(activity: activity, route: s?.route ?? [])
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(activity).font(.headline).lineLimit(1)
                Text(entry.start, format: .dateTime.weekday().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 10) {
                    stat(clock(h?.duration ?? s?.duration ?? 0), "timer")
                    if let hr { stat("\(Int(hr)) bpm", "heart.fill") }
                    if let energy { stat("\(Int(energy.rounded()).formatted()) kcal", "flame.fill") }
                    if let distance, distance > 0 { stat(settings.distanceUnit.format(meters: distance), "location.fill") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
            RowChevron()
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
    }

    private func stat(_ text: String, _ icon: String) -> some View {
        // Icon and number held close; a List's Label would space them like a row's icon.
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon)
            Text(text)
        }
        .lineLimit(1).fixedSize()
    }
}

#if DEBUG
/// Debug harness: jump straight to the first workout's detail (podcast-colored route).
struct FitnessDebugDetail: View {
    @EnvironmentObject var fitness: FitnessStore
    @EnvironmentObject var history: ListenHistoryStore
    var body: some View {
        NavigationStack {
            if let summary = fitness.summaries.first { WorkoutDetailScreen(entry: WorkoutEntry(health: nil, summary: summary)) }
            else { Text("no workout") }
        }
        // After the store's own load, which would otherwise replace the sample with the
        // (empty) index on disk.
        .task {
            await fitness.whenLoaded()
            fitness.injectSampleForPreview()
            if let summary = fitness.summaries.first { history.injectRunListens(around: summary.start) }
        }
    }
}

/// `--workout-detail <summaryID>`: opens the Workouts tab with that summary's detail already
/// pushed, for auditing `WorkoutDetailScreen` against a real recorded workout instead of the
/// synthetic `--workout` fixture. Unlike `--workout`/`FitnessDebugDetail`, this route never
/// injects a fixture — it waits out `fitness.whenLoaded()` and resolves against whatever the
/// on-disk index actually holds, since a fabricated ride wouldn't answer a real summary id or
/// "which is the latest pool swim" anyway. `<summaryID>` matches loosely, the same
/// case-insensitive substring rule `WideWorkoutsView`'s `--mac-workout-id` uses; the literal value
/// `latest-swim` instead picks the most recently started pool swim in the store.
struct WorkoutDetailDebugHost: View {
    @EnvironmentObject var fitness: FitnessStore
    @State private var target: WorkoutEntry?

    var body: some View {
        NavigationStack {
            FitnessView()
                .navigationDestination(item: $target) { WorkoutDetailScreen(entry: $0) }
        }
        .task {
            await fitness.whenLoaded()
            // The sample sessions are put back just after the index loads (`BananaApp`): give
            // them a moment rather than racing them.
            for _ in 0..<20 {
                if let found = Self.resolve(ProcessInfo.processInfo.arguments, in: fitness.summaries) {
                    target = found
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static func resolve(_ arguments: [String], in summaries: [FitnessSessionSummary]) -> WorkoutEntry? {
        guard let i = arguments.firstIndex(of: "--workout-detail"), i + 1 < arguments.count else { return nil }
        let needle = arguments[i + 1]
        let match: FitnessSessionSummary?
        if needle == "latest-swim" {
            match = summaries
                .filter { $0.activity.localizedCaseInsensitiveContains("pool swim") }
                .max { $0.start < $1.start }
        } else {
            match = summaries.first { $0.id.uuidString.localizedCaseInsensitiveContains(needle) }
        }
        return match.map { WorkoutEntry(health: nil, summary: $0) }
    }
}
#endif

// MARK: - Flow layout (wraps stat chips to new lines as needed)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxWidth, widest), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.width && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Formatter

private func clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
#endif
