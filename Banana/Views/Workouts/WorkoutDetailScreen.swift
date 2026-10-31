#if os(iOS)
import SwiftUI

/// iOS parity with `WideWorkoutDetailView` (Workouts redesign, Package 2): the same locked section
/// order — hero, route, charts, splits, comparison, motion — built from the identical Package
/// 4/5/6 subviews the Mac uses, instead of the pre-redesign flat `List` (`FitnessView
/// .WorkoutDetailView`) that showed a pool swim as three summary rows, an HR chart, and a raw
/// CUMULATIVE strokes line that read as a near-straight diagonal and told a swimmer nothing.
///
/// Two inputs, mirroring `WorkoutEntry` (health + summary) rather than the Mac's single
/// non-optional `FitnessSessionSummary` — because every existing call site hands this screen a
/// `WorkoutEntry`, and iOS (unlike the Mac's Banana-only workout list) also reaches this screen
/// for Health-only workouts (an Apple Watch session never recorded by Banana). `init(entry:)`
/// exists so the later integrate step is a one-line rename at each call site
/// (`WorkoutDetailView(entry: entry)` → `WorkoutDetailScreen(entry: entry)`); `init(health:summary:)`
/// is the same two fields spelled out for a call site that already has them unpacked.
///
/// `summary` drives every Mac-parity section below. When a workout is Health-only (`summary ==
/// nil`), none of those sections have anything to build from — `WorkoutHeroHeader`,
/// `WorkoutChartsSection`, etc. all take a non-optional `FitnessSessionSummary`, exactly like the
/// Mac — so this degrades to a compact stat-only card instead of forcing those sections to grow a
/// second optional-input code path the Mac doesn't have.
struct WorkoutDetailScreen: View {
    let health: HealthWorkout?
    let summary: FitnessSessionSummary?

    init(entry: WorkoutEntry) {
        self.health = entry.health
        self.summary = entry.summary
    }

    init(health: HealthWorkout?, summary: FitnessSessionSummary?) {
        self.health = health
        self.summary = summary
    }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var healthStore: HealthKitStore
    @Environment(\.dismiss) private var dismiss

    @State private var showReview = false
    @State private var showTrim = false

    /// The one shared scrub clock (spec §4.3, same role as `WideWorkoutDetailView.cursorT`): a
    /// drag on any chart in `WorkoutChartsSection` and the map's own scrub marker in
    /// `WorkoutRouteMap` read and write this single value.
    @State private var cursorT: TimeInterval?

    /// `nil` until `.task(id:)` below resolves, or forever if this workout has no raw `.samples`
    /// file — see `WorkoutRouteMap`'s doc comment for how its three states read this.
    @State private var fullRatePayload: FullRateRoutePayload?

    /// Live summary so a trim reflects immediately — same "re-look-up by id" pattern the
    /// pre-redesign `WorkoutDetailView` used, since `summary` is a value snapshot from whichever
    /// list handed this screen its `WorkoutEntry`.
    private var liveSummary: FitnessSessionSummary? {
        guard let summary else { return nil }
        return fitness.summaries.first { $0.id == summary.id } ?? summary
    }

    private var activity: String { health?.activity ?? liveSummary?.activity ?? "Workout" }
    /// Only editable when we hold the detailed samples for it — matches the pre-redesign gate.
    private var canTrim: Bool { (liveSummary?.sampleCount ?? 0) > 0 }

    var body: some View {
        let _ = RenderStats.note("WorkoutDetailScreen")
        Group {
            if let workout = liveSummary {
                fullDetail(workout)
            } else {
                healthOnlyDetail
            }
        }
        .navigationTitle(activity)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showReview) {
            PostWorkoutReviewView(subject: WorkoutReviewSubject(summary: liveSummary, health: health))
        }
        .sheet(isPresented: $showTrim) {
            if let workout = liveSummary {
                TrimWorkoutView(summary: workout)
            }
        }
    }

    // MARK: - Toolbar (one More menu: Review, Trim, Delete)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { showReview = true } label: { Label("Review", systemImage: "checkmark.seal") }
                    .accessibilityIdentifier("workout.review")
                if canTrim {
                    Button { showTrim = true } label: { Label("Trim", systemImage: "scissors") }
                }
                // Only what Banana recorded can be deleted (`WorkoutRemoval` needs its summary).
                if liveSummary != nil {
                    Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
                        .accessibilityIdentifier("workout.delete")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("workout.more")
        }
    }

    /// As the lists and the wide detail do: gone at once, with Undo (`WorkoutRemoval`).
    private func delete() {
        WorkoutRemoval.remove(WorkoutEntry(health: health, summary: liveSummary), fitness: fitness, health: healthStore)
        dismiss()
    }

    // MARK: - Full detail (Mac parity — spec Package 2)

    private func fullDetail(_ workout: FitnessSessionSummary) -> some View {
        // `ScrollViewReader`/`.id(...)` are unconditional (LazyVStack + ScrollViewReader needs an
        // explicit id on each child to scroll to it even when off-screen and not yet realized —
        // this is the standard pairing, not new overhead) so release behaviour is unchanged; only
        // the scroll action itself — `scrollToDebugSection` below — is DEBUG-only.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkoutMetrics.sectionSpacing) {
                    WorkoutHeroHeader(workout: workout)
                        .id("hero")

                    if WorkoutRouteMap.hasContent(for: workout, fullRate: fullRatePayload) {
                        WorkoutRouteMap(workout: workout, fullRate: fullRatePayload, cursorT: $cursorT)
                            .id("route")
                    }

                    WorkoutChartsSection(workout: workout, cursorT: $cursorT)
                        .id("charts")
                    WorkoutSplitsSection(workout: workout)
                        .id("splits")
                    WorkoutComparisonCard(workout: workout)
                        .id("comparison")
                    WorkoutMotionSection(workout: workout)
                        .id("motion")
                }
                .padding(DS.Space.l)
            }
            .background(Color(.systemGroupedBackground))
            // Keyed on id *and* sample count, not just `workout.id`: a Trim rewrites the raw
            // sample file in place without changing the workout's identity, so the count is what
            // tells this task to reload the full-rate payload after the Trim sheet above is
            // dismissed.
            .task(id: RouteLoadKey(id: workout.id, sampleCount: workout.sampleCount)) {
                await loadFullRatePayload(workout)
            }
            #if DEBUG
            .task(id: RouteLoadKey(id: workout.id, sampleCount: workout.sampleCount)) {
                await scrollToDebugSection(workout, proxy)
            }
            #endif
        }
    }

    // MARK: - Health-only fallback (no Banana recording for this workout — see the type doc above)

    private var healthOnlyDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkoutMetrics.sectionSpacing) {
                healthOnlyCard
            }
            .padding(DS.Space.l)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// The same card `HealthOnlyWorkoutDetail` shows; that screen is where a Health-only workout
    /// opens now, on every device. This stays for a caller that hands this screen one directly.
    @ViewBuilder
    private var healthOnlyCard: some View {
        if let health { HealthOnlyWorkoutCard(workout: health) }
    }

    // MARK: - Full-rate route payload (mirrors `WideWorkoutDetailView.loadFullRatePayload` exactly,
    // down to the fetched-kinds list, so the two platforms' Replay maps agree byte-for-byte)

    private struct RouteLoadKey: Hashable {
        var id: UUID
        var sampleCount: Int
    }

    /// Off-main load: `fitness.samples(for:kinds:)` already hops to `Task.detached` internally for
    /// the file read/decode; building the payload's point/speed/heart-rate arrays out of the
    /// decoded samples happens in `FullRateRoutePayload.build(from:)`, wrapped in its own
    /// `Task.detached` below so no per-sample work runs on the main actor (PERFORMANCE RULES).
    private func loadFullRatePayload(_ workout: FitnessSessionSummary) async {
        fullRatePayload = nil
        // On an iPad or a Mac the recording comes from the data platform when first needed.
        guard await fitness.ensureSamples(workout.id) else { return }
        let raw = await fitness.samples(for: workout.id, kinds: [.location, .altitude, .speed, .heartRate])
        guard !raw.isEmpty else { return }
        fullRatePayload = await Task.detached(priority: .userInitiated) {
            FullRateRoutePayload.build(from: raw)
        }.value
    }

    // MARK: - DEBUG scroll-to-section (spec precedent: `PostWorkoutReviewView`'s
    // `--workout-review-end`; mirrors `WideWorkoutDetailView.scrollToDebugSection`)

    #if DEBUG
    /// `--detail-section <name>` (`WorkoutDetailSection`): waits for `fullRatePayload` — the one
    /// async load this view itself tracks, and the one every section above reads (route, charts,
    /// and the Replay map all key off it) — to settle, then scrolls, then re-issues the same
    /// scroll twice more on increasing delays.
    ///
    /// The re-issues matter: `WorkoutMotionSection` (almost always the requested section, since
    /// it is the one this whole route exists for) runs its OWN separate `.task`, loading motion
    /// analysis / hand-path data this view has no way to observe. A single `scrollTo` fired right
    /// after `fullRatePayload` settles lands while Motion is still showing its small loading
    /// spinner placeholder — proven empirically (`WideWorkoutDetailView.scrollToDebugSection`'s doc
    /// comment has the detail): that first `scrollTo` computes an offset against the placeholder's
    /// height, and when Motion's real content (e.g. a full hand-path card) grows in moments later,
    /// the already-committed offset goes stale and the capture clips the bottom of exactly the
    /// content this route was built to show. Re-scrolling to the same id after the content has had
    /// more time to settle corrects for that growth; three passes over ~2.4s converges on the
    /// final layout without an unbounded wait.
    ///
    /// Not every workout ever produces a `fullRatePayload` (no GPS/HR samples at all, e.g. a
    /// strength session), so that initial wait is capped at 4s rather than unconditional — such a
    /// workout still gets the three scroll passes, just without a real load to wait out first.
    @MainActor
    private func scrollToDebugSection(_ workout: FitnessSessionSummary, _ proxy: ScrollViewProxy) async {
        guard let requested = WorkoutDetailSection.requested() else { return }
        var attempts = 0
        while fullRatePayload == nil, fitness.hasLocalSamples(workout.id), attempts < 40 {
            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        for delayMilliseconds in [500, 700, 1_200] {
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            proxy.scrollTo(requested.rawValue, anchor: .top)
        }
    }
    #endif
}
#endif
