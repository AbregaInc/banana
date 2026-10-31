import SwiftUI

/// The detail view's splits/laps card (spec §4.5): a three-way gate — SWOLF table for pool
/// swims, distance-splits table for anything with a GPS track (this is what covers open-water
/// swims, which the pre-redesign `isPoolSwim ? lapSplits : (!isPoolSwim ? distanceSplits :
/// nothing)` gate fell through entirely), or no card at all when neither applies. Both tables
/// highlight the fastest row, matching `PostWorkoutReviewView`'s treatment (absent on Mac today).
///
/// Standalone — takes only the workout summary. `settings` arrives via the ambient environment
/// the composing view (`WideWorkoutDetailView`, Package 7) already provides.
struct WorkoutSplitsSection: View {
    let workout: FitnessSessionSummary

    @EnvironmentObject private var settings: AppSettings

    private var activityKind: WorkoutActivityKind { WorkoutActivityKind(activity: workout.activity) }

    /// No pool laps and no GPS track: no card at all, rather than a note explaining the absence.
    private var hasSplits: Bool {
        (activityKind.usesLaps && !workout.laps.isEmpty) || workout.distanceSeries.count > 1
    }

    var body: some View {
        if hasSplits {
            VStack(alignment: .leading, spacing: 10) {
                WorkoutSectionLabel(title: "Splits")
                content
            }
            .padding(WorkoutMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
        }
    }

    @ViewBuilder
    private var content: some View {
        if activityKind.usesLaps, !workout.laps.isEmpty {
            swolfTable(WorkoutSplits.swolfRows(laps: workout.laps, strokeSeries: workout.strokeSeries))
        } else if workout.distanceSeries.count > 1 {
            // Covers open-water swims with a GPS track — the exact gap the pre-redesign gate missed.
            distanceSplitsTable(WorkoutSplits.distanceSplits(for: workout, unit: settings.distanceUnit),
                                partial: WorkoutSplits.finalPartial(for: workout, unit: settings.distanceUnit))
        }
    }


    // MARK: - SWOLF table (pool swims)

    private func swolfTable(_ rows: [SWOLFRow]) -> some View {
        let fastest = WorkoutSplits.fastestIndex(rows, duration: \.duration)
        return VStack(spacing: 0) {
            HStack {
                Text("Lap").frame(width: 44, alignment: .leading)
                Spacer()
                Text("Duration").frame(width: 70, alignment: .trailing)
                Text("Strokes").frame(width: 60, alignment: .trailing)
                Text("SWOLF").frame(width: 60, alignment: .trailing)
            }
            .font(WorkoutType.stripLabel)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let isFastest = fastest == index
                HStack {
                    Text("\(row.lapNumber)")
                        .font(WorkoutType.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Spacer()
                    Text(durationText(row.duration)).frame(width: 70, alignment: .trailing)
                    Text(row.strokes.map { "\($0)" } ?? "–").frame(width: 60, alignment: .trailing)
                    Text(row.swolf.map { "\($0)" } ?? "–").frame(width: 60, alignment: .trailing)
                }
                .font(WorkoutType.rowMetricValue.weight(isFastest ? .bold : .regular))
                .foregroundStyle(isFastest ? WorkoutPalette.good : Color.primary)
                .monospacedDigit()
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Distance splits table (GPS-tracked activities, including open-water swims)

    private func distanceSplitsTable(_ splits: [DistanceSplit], partial: (meters: Double, duration: TimeInterval)?) -> some View {
        let fastest = WorkoutSplits.fastestIndex(splits, duration: \.duration)
        return VStack(spacing: 0) {
            ForEach(Array(splits.enumerated()), id: \.element.id) { index, split in
                let isFastest = fastest == index
                HStack {
                    Text(WorkoutSplits.label(split, unit: settings.distanceUnit))
                        .font(WorkoutType.rowSubtitle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(durationText(split.duration))
                        .font(WorkoutType.rowMetricValue.weight(isFastest ? .bold : .regular))
                        .foregroundStyle(isFastest ? WorkoutPalette.good : Color.primary)
                        .monospacedDigit()
                }
                .padding(.vertical, 3)
            }
            // The distance after the last whole split, so the table adds up to the run.
            if let partial {
                HStack {
                    Text(settings.distanceUnit.format(meters: partial.meters))
                        .font(WorkoutType.rowSubtitle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(durationText(partial.duration))
                        .font(WorkoutType.rowMetricValue)
                        .monospacedDigit()
                }
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Formatting

    private func durationText(_ seconds: TimeInterval) -> String { WorkoutComparisons.durationText(seconds) }
}
