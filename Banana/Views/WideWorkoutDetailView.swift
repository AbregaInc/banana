import SwiftUI
import MapKit

/// One workout, full-screen — the payoff of a desktop Rhythm.
///
/// This is the composing view for the Workouts redesign's detail screen (spec §5): it owns the
/// shared scrub clock (§4.3), the toolbar/keyboard (§4.8), and the off-main full-rate route load
/// (§4.2/§4.9), and lays out Packages 4–6's standalone subviews in the locked order. It has no
/// chart/map/motion rendering logic of its own any more — that all lives in
/// `WorkoutHeroHeader`/`WorkoutChartsSection`/`WorkoutSplitsSection`/`WorkoutComparisonCard`
/// (Package 4), `WorkoutRouteMap` (Package 5), and `WorkoutMotionSection`
/// (Package 6).
struct WideWorkoutDetailView: View {
    let workout: FitnessSessionSummary
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var health: HealthKitStore
    @Environment(\.dismiss) private var dismiss

    @State private var showReview = false
    /// Crop a lead-in or tail, as the phone's detail offers.
    @State private var showTrim = false

    /// The one shared scrub clock (spec §4.3): any chart's drag/hover in `WorkoutChartsSection`
    /// and the map's own scrub marker in `WorkoutRouteMap` all read and write this single value —
    /// that's what makes a drag on one move the cursor everywhere else, not a per-section illusion
    /// of sync.
    @State private var cursorT: TimeInterval?

    /// `nil` until the `.task(id: workout.id)` below resolves, or forever if this workout has no
    /// raw `.samples` file — see `WorkoutRouteMap`'s own doc comment for how its three states read
    /// this. Built off-main (spec §4.2/§7).
    @State private var fullRatePayload: FullRateRoutePayload?

    @FocusState private var isFocused: Bool

    var body: some View {
        let _ = RenderStats.note("WideWorkoutDetailView")
        // `ScrollViewReader`/`.id(...)` are unconditional (cheap structural identity, same as
        // position-based identity would give these sections anyway) so release behaviour is
        // unchanged; only the scroll action itself — `scrollToDebugSection` below — is DEBUG-only.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkoutMetrics.sectionSpacing) {
                    WorkoutHeroHeader(workout: workout)
                        .id("hero")

                    if WorkoutRouteMap.hasContent(for: workout, fullRate: fullRatePayload) {
                        routeMapSection
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
                .padding(DS.Space.xl)
                .frame(maxWidth: WorkoutMetrics.detailContentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(workout.activity)
            // Fallback keyboard target for the scrub shortcuts below — clicking any chart/control
            // still works and takes its own focus; this just means the shortcuts respond
            // immediately without requiring a click first.
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .delete], phases: .down, action: handleKeyPress)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showReview) {
                PostWorkoutReviewView(subject: WorkoutReviewSubject(summary: workout, health: nil))
            }
            .sheet(isPresented: $showTrim) {
                TrimWorkoutView(summary: fitness.summaries.first { $0.id == workout.id } ?? workout)
            }
            .task(id: workout.id) { await loadFullRatePayload() }
            #if DEBUG
            .task(id: workout.id) { await scrollToDebugSection(proxy) }
            #endif
        }
    }

    // MARK: - Toolbar (spec §4.8)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                showReview = true
            } label: {
                Label("Review", systemImage: "checkmark.seal")
            }
            .labelStyle(.titleAndIcon)
        }
        if (fitness.summaries.first { $0.id == workout.id } ?? workout).sampleCount > 0 {
            ToolbarItem {
                Button { showTrim = true } label: { Label("Trim", systemImage: "scissors") }
                    .labelStyle(.titleAndIcon)
            }
        }
        ToolbarItem(placement: .destructiveAction) {
            Button(role: .destructive) { delete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Keyboard (spec §4.3/§4.8)

    /// As the lists do, on every device: gone at once, with Undo, and removed for real — with its
    /// Apple Health half — when the Undo closes (`WorkoutRemoval`). The Mac asked first, and
    /// warned that its delete couldn't reach the phone's Health copy; it can now.
    private func delete() {
        WorkoutRemoval.remove(WorkoutEntry(health: nil, summary: workout), fitness: fitness, health: health)
        dismiss()
    }

    /// ←/→ step the shared cursor by 1 s, ⇧←/⇧→ by 10 s (no-op while nothing is loaded, i.e.
    /// `cursorT` is still `nil`); ⌘⌫ deletes as the Delete toolbar button does, with the same
    /// Undo.
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            guard cursorT != nil else { return .ignored }
            stepCursor(by: press.modifiers.contains(.shift) ? -10 : -1)
            return .handled
        case .rightArrow:
            guard cursorT != nil else { return .ignored }
            stepCursor(by: press.modifiers.contains(.shift) ? 10 : 1)
            return .handled
        case .delete:
            guard press.modifiers.contains(.command) else { return .ignored }
            delete()
            return .handled
        default:
            return .ignored
        }
    }

    private func stepCursor(by deltaSeconds: TimeInterval) {
        guard let current = cursorT else { return }
        cursorT = min(max(0, current + deltaSeconds), workout.duration)
    }

    // MARK: - Map / Replay (spec §4.2)

    private var routeMapSection: some View {
        WorkoutRouteMap(workout: workout, fullRate: fullRatePayload, cursorT: $cursorT)
    }

    // MARK: - Full-rate route payload (spec §4.2/§7)

    /// Off-main load: `fitness.samples(for:kinds:)` already hops to `Task.detached` internally for
    /// the file read/decode; building the payload's point/speed/heart-rate arrays out of the
    /// decoded samples is further wrapped in its own `Task.detached` below so no per-sample work
    /// runs on the main actor (PERFORMANCE RULES).
    private func loadFullRatePayload() async {
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
    // `--workout-review-end`)

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
    /// spinner placeholder — proven empirically: that first `scrollTo` computes an offset against
    /// the placeholder's height, and when Motion's real content (e.g. a full hand-path card) grows
    /// in moments later, the already-committed offset goes stale and the capture clips the bottom
    /// of exactly the content this route was built to show. Re-scrolling to the same id after the
    /// content has had more time to settle corrects for that growth; three passes over ~2.4s
    /// converges on the final layout without an unbounded wait.
    ///
    /// Not every workout ever produces a `fullRatePayload` (no GPS/HR samples at all, e.g. a
    /// strength session), so that initial wait is capped at 4s rather than unconditional — such a
    /// workout still gets the three scroll passes, just without a real load to wait out first.
    @MainActor
    private func scrollToDebugSection(_ proxy: ScrollViewProxy) async {
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
