#if os(iOS)
import SwiftUI

/// Settings › Apple Health › Workout cleanup.
///
/// Three kinds of bad workout data, each fixed only where Banana may fix it:
///  - **Banana's own duplicate saves** — the same session written to Apple Health twice. Banana
///    wrote them, so it can delete the extra copies; everything else reading Health (the Fitness
///    app, WHOOP) was counting them twice.
///  - **Swims recorded with a 50 m pool** that was really 25 yd — rewritten with the right pool
///    length, in Banana and in Apple Health. The original is backed up first.
///  - **Other apps' copies** (Strava, WHOOP…) — HealthKit forbids deleting another app's data,
///    so these are only explained; Banana already counts each workout once.
///
/// Nothing changes until a button is pressed and the confirmation accepted.
struct WorkoutCleanupView: View {
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var fitness: FitnessStore

    @State private var excludedSwims: Set<UUID> = []
    @State private var confirmingDuplicates = false
    @State private var confirmingSwims = false
    @State private var working: String?
    @State private var result: String?

    private var ownBundleID: String { Bundle.main.bundleIdentifier ?? "com.boris.banana" }

    private var duplicateGroups: [OwnWorkoutDuplicates.Group] {
        OwnWorkoutDuplicates.groups(in: health.workouts, ownBundleID: ownBundleID)
    }

    private var extraCopies: Int { duplicateGroups.reduce(0) { $0 + $1.remove.count } }

    private var swimCandidates: [PoolLengthCorrection.Candidate] {
        PoolLengthCorrection.candidates(fitness.summaries)
    }

    private var selectedSwims: [PoolLengthCorrection.Candidate] {
        swimCandidates.filter { !excludedSwims.contains($0.id) }
    }

    /// Typical lap on swims already recorded at 25 yd — the yardstick for the 50 m ones.
    private var typicalTwentyFiveYardLap: TimeInterval? {
        let laps = fitness.summaries
            .filter { abs(($0.poolLengthMeters ?? 0) - PoolLengthCorrection.twentyFiveYards) < 0.01 }
            .flatMap { $0.laps.map(\.duration) }
            .sorted()
        return laps.isEmpty ? nil : laps[laps.count / 2]
    }

    var body: some View {
        Form {
            if let working {
                Section { HStack { ProgressView(); Text(working) } }
            } else if let result {
                Section { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.success) }
            }

            Section {
                if extraCopies == 0 {
                    Label("No duplicate saves", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(duplicateGroups.prefix(8), id: \.keep.id) { group in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.keep.activity)
                                Text(group.keep.start.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("×\(group.remove.count + 1)").foregroundStyle(DS.Palette.accent).monospacedDigit()
                        }
                    }
                    if duplicateGroups.count > 8 {
                        Text("and \(duplicateGroups.count - 8) more").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Remove \(extraCopies) extra \(extraCopies == 1 ? "copy" : "copies")", role: .destructive) {
                        confirmingDuplicates = true
                    }
                    .disabled(working != nil)
                }
            } header: {
                Text("Saved twice by Banana")
            } footer: {
                Text("These workouts are in Apple Health more than once, so the Fitness app, WHOOP and anything else reading Health counts them twice. The most complete copy of each is kept.")
            }

            Section {
                if swimCandidates.isEmpty {
                    Label("No swims recorded with a 50 m pool", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(swimCandidates) { swim in
                        Toggle(isOn: Binding(
                            get: { !excludedSwims.contains(swim.id) },
                            set: { if $0 { excludedSwims.remove(swim.id) } else { excludedSwims.insert(swim.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(swim.start.formatted(date: .abbreviated, time: .shortened))
                                Text(detail(swim)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Correct \(selectedSwims.count) \(selectedSwims.count == 1 ? "swim" : "swims") to 25 yd") {
                        confirmingSwims = true
                    }
                    .disabled(selectedSwims.isEmpty || working != nil)
                }
            } header: {
                Text("Swims recorded with a 50 m pool")
            } footer: {
                Text(swimFooter)
            }

            Section {
                ForEach(otherAppCopies, id: \.name) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Text("\(row.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } header: {
                Text("Copies written by other apps")
            } footer: {
                Text("Apple Health only lets an app delete what it wrote, so Banana can't remove these. It already counts each of these workouts once. To stop new copies, turn off writing workouts to Apple Health in the app doing the copying (usually WHOOP and Strava).")
            }
        }
        .formControls()
        .navigationTitle("Workout cleanup")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(extraCopies) extra copies from Apple Health?",
                            isPresented: $confirmingDuplicates, titleVisibility: .visible) {
            Button("Remove \(extraCopies)", role: .destructive) { Task { await removeDuplicates() } }
        } message: {
            Text("Only copies Banana saved are removed, and one copy of every workout stays.")
        }
        .confirmationDialog("Correct \(selectedSwims.count) swims to a 25 yd pool?",
                            isPresented: $confirmingSwims, titleVisibility: .visible) {
            Button("Correct \(selectedSwims.count)") { Task { await correctSwims() } }
        } message: {
            Text("Distances and paces are recalculated; laps and lap times stay as recorded. Each swim's original is backed up, and its Apple Health copy is replaced.")
        }
    }

    private func detail(_ swim: PoolLengthCorrection.Candidate) -> String {
        var parts = ["\(Int(swim.distance.rounded())) m → \(Int((swim.correctedDistance / 0.9144).rounded())) yd"]
        if swim.lapCount > 0 { parts.append("\(swim.lapCount) laps") }
        if let lap = swim.medianLap { parts.append("typical lap \(Int(lap.rounded()))s") }
        if swim.recordedLength == nil { parts.append("pool length not stored") }
        return parts.joined(separator: " · ")
    }

    private var swimFooter: String {
        var text = "Until it was changed, the pool-length setting defaulted to 50 m, and the Watch measured every length against it."
        if let lap = typicalTwentyFiveYardLap {
            text += " Your 25 yd laps typically take \(Int(lap.rounded()))s — compare each swim's typical lap, and switch off any that really were in a 50 m pool."
        }
        return text
    }

    private var otherAppCopies: [(name: String, count: Int)] {
        let rows = WorkoutEntry.merge(summaries: [], health: health.workouts, ownBundleID: ownBundleID)
        let kept = Set(rows.compactMap { $0.health?.id })
        let dropped = health.workouts.filter { !kept.contains($0.id) && $0.sourceBundleID != ownBundleID }
        return Dictionary(grouping: dropped, by: \.source)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private func removeDuplicates() async {
        let targets = duplicateGroups.flatMap(\.remove)
        working = "Removing \(targets.count) copies…"
        var removed = 0
        for workout in targets where health.canDeleteFromHealth(workout) {
            if await health.remove(workoutID: workout.id) == .deletedFromHealth { removed += 1 }
        }
        working = nil
        result = "Removed \(removed) extra \(removed == 1 ? "copy" : "copies") from Apple Health."
    }

    private func correctSwims() async {
        let targets = selectedSwims
        var corrected = 0
        for (index, swim) in targets.enumerated() {
            working = "Correcting swim \(index + 1) of \(targets.count)…"
            guard let session = await fitness.session(for: swim.id), !session.samples.isEmpty else { continue }
            let fixed = PoolLengthCorrection.corrected(session, from: swim.recordedLength ?? 50)
            guard await fitness.replaceSession(fixed) else { continue }
            await health.replaceOwnWorkout(with: fixed, originalStart: session.start,
                                           originalEnd: session.end ?? session.start)
            corrected += 1
        }
        working = nil
        result = "Corrected \(corrected) \(corrected == 1 ? "swim" : "swims") to a 25 yd pool."
    }
}
#endif
