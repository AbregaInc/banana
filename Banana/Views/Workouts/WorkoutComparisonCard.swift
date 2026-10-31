import SwiftUI

/// "Compared with your last 90 days" (spec §4.6) — reachable any time from the Mac, not only in
/// the moment right after a workout. Builds the same `WorkoutReviewSubject` /
/// `WorkoutReviewCoordinator.recentPeers` / `WorkoutComparisons.compute` pipeline
/// `PostWorkoutReviewView` uses and renders the identical card layout, so the numbers here are
/// byte-identical to what the phone shows.
///
/// Standalone — takes only the workout summary. `fitness`/`health`/`settings` arrive via the
/// ambient environment the composing view (`WideWorkoutDetailView`, Package 7) already provides
/// (or adds, for `health`, per spec §4.6).
struct WorkoutComparisonCard: View {
    let workout: FitnessSessionSummary

    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var settings: AppSettings

    private var activityKind: WorkoutActivityKind { WorkoutActivityKind(activity: workout.activity) }
    private var subject: WorkoutReviewSubject { WorkoutReviewSubject(summary: workout, health: nil) }

    private var peers: [WorkoutReviewSubject] {
        WorkoutReviewCoordinator.recentPeers(of: subject, summaries: fitness.summaries, healthWorkouts: health.workouts)
    }

    private var comparisons: [WorkoutComparison] {
        WorkoutComparisons.compute(subject: subject, peers: peers,
                                    distanceUnit: settings.distanceUnit, usesPace: activityKind.usesPace)
    }

    var body: some View {
        let peers = self.peers
        // Nothing to compare with: no card, rather than a note saying so.
        if !peers.isEmpty {
            card(peers)
        }
    }

    private func card(_ peers: [WorkoutReviewSubject]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Compared with your last 90 days")
                    .font(WorkoutType.chartTitle)
                Spacer()
                Text("\(peers.count) \(workout.activity.lowercased()) \(peers.count == 1 ? "workout" : "workouts")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(comparisons) { comparison in
                HStack(spacing: 10) {
                    Text(comparison.title).font(.subheadline)
                    Spacer()
                    Text(comparison.now).font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("usually \(comparison.usual)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(comparison.deltaPercent == 0 ? "±0%" : String(format: "%+d%%", comparison.deltaPercent))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(comparison.tone)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .padding(WorkoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}
