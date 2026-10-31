import SwiftUI

/// The detail view's top section: the activity's tile, name and when, then a card of every stat
/// this workout has, in rows of equal columns with a line between rows (the approved Workout
/// image, 16 Oct 2026). Whether the full recording is here is said under the map, where it
/// matters; the fitness sync picture is in Settings.
///
/// Standalone — takes only the workout summary. `settings` arrives via the ambient environment
/// the composing view (`WorkoutDetailScreen`, `WideWorkoutDetailView`) already provides.
struct WorkoutHeroHeader: View {
    let workout: FitnessSessionSummary

    @EnvironmentObject private var settings: AppSettings
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var activityKind: WorkoutActivityKind { WorkoutActivityKind(activity: workout.activity) }

    /// Four across on a phone, as in the image; six where the page is wide.
    private var columns: Int {
        #if os(macOS)
        6
        #else
        sizeClass == .regular ? 6 : 4
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identityRow
            statCard
        }
    }

    // MARK: - Identity

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(WorkoutPalette.accent.opacity(DS.Tint.soft))
                Image(systemName: activityKind.systemImage)
                    .font(.system(size: WorkoutMetrics.heroGlyphSize * 0.45, weight: .semibold))
                    .foregroundStyle(WorkoutPalette.accent)
            }
            .frame(width: WorkoutMetrics.heroGlyphSize, height: WorkoutMetrics.heroGlyphSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.activity).font(WorkoutType.heroActivity)
                // One line: the whole date when it fits, the short weekday and month when not.
                ViewThatFits(in: .horizontal) {
                    Text(workout.start.formatted(date: .complete, time: .shortened))
                    Text(workout.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute()))
                }
                .font(WorkoutType.heroWhen)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    // MARK: - Stats

    /// Rows of `columns` cells, a line between rows; a short last row leaves its cells empty so
    /// every column lines up.
    private var statCard: some View {
        let all = stats
        let rows = stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { r in
                if r > 0 {
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        if c < rows[r].count {
                            WorkoutMetricTile(value: rows[r][c].value, label: rows[r][c].label, alignment: .leading)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
        // Full width however few stats there are, like every card on the page.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.l)
        .dsCard()
    }

    /// Fixed order, content-gated: a stat appears only when its value exists, but the ORDER
    /// never changes.
    private var stats: [(label: String, value: String)] {
        var out: [(label: String, value: String)] = []
        // Pauses left out, as on the Watch and in Apple Health.
        out.append(("Time", durationText(workout.activeDuration)))
        if let s = distanceOrLaps { out.append(s) }
        if let s = paceOrSpeed { out.append(s) }
        if let hr = workout.avgHeartRate, hr > 0 {
            out.append(("Avg BPM", "\(Int(hr.rounded()))"))
        }
        if let energy = workout.totalEnergy, energy > 0 {
            out.append(("Calories", Int(energy.rounded()).formatted()))
        }
        if !workout.stayedInOnePlace, let moving = workout.insights?.movingDuration {
            out.append(("Moving time", durationText(moving)))
        }
        if let power = workout.insights?.averagePower {
            out.append(("Avg power", "\(Int(power.rounded())) W"))
        }
        // Recorded cadence is cycling-only — gating on activity kind (not just on the value
        // being non-nil) keeps a stray sample from ever implying a run has cadence.
        if activityKind == .cycling, let cadence = workout.insights?.averageCadence {
            out.append(("Avg cadence", "\(Int(cadence.rounded()))"))
        }
        if !workout.stayedInOnePlace, let gain = workout.insights?.elevationGain {
            out.append(("Elevation gain", "\(Int(gain.rounded())) m"))
        }
        if !workout.stayedInOnePlace, let loss = workout.insights?.elevationLoss {
            out.append(("Elevation loss", "\(Int(loss.rounded())) m"))
        }
        if !workout.stayedInOnePlace, let maxSpeed = workout.insights?.maxSpeed {
            out.append(("Max speed", speedText(mps: maxSpeed)))
        }
        if let weather = workout.outdoorConditions {
            out.append(("Weather", "\(Int(weather.temperatureF.rounded()))°"))
            out.append(("Humidity", "\(Int((weather.humidity * 100).rounded()))%"))
        }
        return out
    }

    private var distanceOrLaps: (label: String, value: String)? {
        if activityKind.usesLaps, let laps = lapCount, laps > 0 {
            return ("Laps", "\(laps)")
        } else if let distance = workout.totalDistance, distance > 0 {
            return ("Distance", settings.distanceUnit.format(meters: distance))
        }
        return nil
    }

    private var paceOrSpeed: (label: String, value: String)? {
        if activityKind.usesLaps, let laps = lapCount, laps > 0 {
            return ("Avg lap", durationText(averageLapTime))
        } else if let distance = workout.totalDistance, distance > 0, workout.activeDuration > 0 {
            return activityKind.usesPace
                ? ("Pace", WorkoutComparisons.paceText(distance: distance, seconds: workout.activeDuration, unit: settings.distanceUnit))
                : ("Speed", WorkoutComparisons.speedText(distance: distance, seconds: workout.activeDuration, unit: settings.distanceUnit))
        }
        return nil
    }

    // MARK: - Laps (pool swim only)

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

    // MARK: - Formatting

    private func durationText(_ seconds: TimeInterval) -> String { WorkoutComparisons.durationText(seconds) }

    /// Same mph/km-h conversion the Speed chart's y-axis uses (`WorkoutChartsSection`), applied to
    /// a single raw m/s value for the "Max speed" stat.
    private func speedText(mps: Double) -> String {
        let value = mps * (settings.distanceUnit == .miles ? 2.236936 : 3.6)
        return String(format: "%.1f %@", value, settings.distanceUnit == .miles ? "mph" : "km/h")
    }
}
