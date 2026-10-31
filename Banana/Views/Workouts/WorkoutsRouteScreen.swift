import SwiftUI

/// The screen a Workouts route stands for. One mapping for the phone's list, the iPad's wide page
/// and the Mac's, so a place saved in one opens in the others: an iPad window narrowed or widened,
/// or the app coming back, lands where it was. (The wide page kept no place at all, and the Mac's
/// had its own stack that could open only a workout Banana recorded.)
struct WorkoutsRouteScreen: View {
    let route: ShellState.WorkoutsRoute
    /// The wide page — the Mac's, and an iPad's at full width — opens a workout Banana recorded
    /// in its wide detail.
    var wide = false
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var health: HealthKitStore

    var body: some View {
        switch route {
        case .workout(let id):
            let entries = WorkoutEntry.merge(summaries: fitness.summaries, health: health.workouts,
                                             hiddenHealthIDs: health.hiddenWorkoutIDs)
            if let entry = entries.first(where: { $0.matches(routeID: id) }) {
                detail(entry)
            } else {
                // Restored before Health's copy has loaded: wait a moment before calling it gone.
                RestoreGrace {
                    ContentUnavailableView("Workout unavailable", systemImage: "figure.run",
                                           description: Text("It was deleted, or merged with another recording."))
                }
            }
        case .guidedPlans where Features.guidedPlans:
            WorkoutPlansView()
        case .plan where Features.guidedPlans, .coach where Features.guidedPlans:
            GuidedPlanRoute(route: route)
        case .guidedPlans, .plan, .coach:
            // Switched off (`Features.guidedPlans`); a saved place that pointed here is dropped
            // on restore, so this is only what's left if one slips through.
            ContentUnavailableView("Guided plans are off", systemImage: "figure.strengthtraining.traditional")
        case .sleep:
            SleepView()
        case .trends(let window):
            TrendsView(window: TrendWindow(rawValue: window) ?? .month) { kind, window in
                .trend(kind.trendID, window: window.rawValue)
            }
        case .trend(let id, let window):
            if let kind = MetricKind(trendID: id) {
                TrendDetailView(kind: kind, window: TrendWindow(rawValue: window) ?? .month)
            }
        }
    }

    @ViewBuilder private func detail(_ entry: WorkoutEntry) -> some View {
        switch entry.detail(wide: wide) {
        case .wide:
            if let summary = entry.summary { WideWorkoutDetailView(workout: summary) }
        case .compact:
            #if os(iOS)
            WorkoutDetailScreen(entry: entry)
            #else
            // The Mac has the wide detail and no other.
            if let summary = entry.summary { WideWorkoutDetailView(workout: summary) }
            #endif
        case .healthOnly:
            if let workout = entry.health { HealthOnlyWorkoutDetail(workout: workout) }
        }
    }
}

/// A spinner for the first few seconds, then `content`. A screen restored after a trip to the
/// background can be asked for before its store has loaded; "unavailable" flashed for a moment
/// and then the real screen replaced it.
private struct RestoreGrace<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var waited = false

    var body: some View {
        Group {
            if waited { content } else { ProgressView() }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            waited = true
        }
    }
}

/// A guided plan or its coach, looked up by id so the route can be stored.
private struct GuidedPlanRoute: View {
    @EnvironmentObject private var wellness: WellnessStore
    let route: ShellState.WorkoutsRoute

    var body: some View {
        switch route {
        case .plan(let id):
            if let plan = plan(id) { WorkoutPlanDetailView(plan: plan) } else { unavailable }
        case .coach(let id):
            if let plan = plan(id) { WorkoutCoachView(plan: plan) } else { unavailable }
        default:
            unavailable
        }
    }

    private func plan(_ id: UUID) -> WorkoutPlan? { wellness.workoutPlans.first { $0.id == id } }

    private var unavailable: some View {
        RestoreGrace {
            ContentUnavailableView("Plan unavailable", systemImage: "figure.strengthtraining.traditional",
                                   description: Text("It was deleted."))
        }
    }
}

/// A workout that's only in Apple Health — an Apple Watch session Banana never recorded: its
/// numbers, and nothing else to show. One screen for the phone, the iPad and the Mac; on the Mac
/// the row had no screen at all.
struct HealthOnlyWorkoutDetail: View {
    let workout: HealthWorkout
    @State private var showReview = false

    var body: some View {
        let _ = RenderStats.note("HealthOnlyWorkoutDetail")
        ScrollView {
            VStack(alignment: .leading, spacing: WorkoutMetrics.sectionSpacing) {
                HealthOnlyWorkoutCard(workout: workout)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: WorkoutMetrics.detailContentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(workout.activity)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showReview = true } label: { Label("Review", systemImage: "checkmark.seal") }
                    .accessibilityIdentifier("workout.review")
            }
        }
        .sheet(isPresented: $showReview) {
            PostWorkoutReviewView(subject: WorkoutReviewSubject(summary: nil, health: workout))
        }
        .accessibilityIdentifier("workout.healthOnly")
    }
}

/// The card of a Health-only workout's numbers.
struct HealthOnlyWorkoutCard: View {
    let workout: HealthWorkout
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.activity).font(WorkoutType.heroActivity)
                Text(workout.start.formatted(date: .complete, time: .shortened))
                    .font(WorkoutType.heroWhen)
                    .foregroundStyle(.secondary)
                if !workout.source.isEmpty {
                    Text(workout.source).font(.caption).foregroundStyle(.secondary)
                }
            }
            WorkoutFlowLayout(spacing: 20, lineSpacing: 12) {
                WorkoutMetricTile(value: WorkoutComparisons.durationText(workout.duration), label: "Time", alignment: .leading)
                if let d = workout.distanceMeters, d > 0 {
                    WorkoutMetricTile(value: settings.distanceUnit.format(meters: d), label: "Distance", alignment: .leading)
                }
                if let hr = workout.avgHeartRate, hr > 0 {
                    WorkoutMetricTile(value: "\(Int(hr.rounded()))", label: "Avg BPM", alignment: .leading)
                }
                if let mx = workout.maxHeartRate, mx > 0 {
                    WorkoutMetricTile(value: "\(Int(mx.rounded()))", label: "Max BPM", alignment: .leading)
                }
                if let e = workout.energyKcal, e > 0 {
                    WorkoutMetricTile(value: "\(Int(e.rounded()))", label: "Calories", alignment: .leading)
                }
            }
            WorkoutSectionNote(text: "Recorded outside Banana — no route, charts, or motion data to show.")
        }
        .padding(WorkoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}
