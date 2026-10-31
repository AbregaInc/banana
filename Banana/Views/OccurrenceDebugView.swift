#if DEBUG
import SwiftUI

/// Throwaway inspector for the L1 occurrence engine — shown under `--occurrences`. Dumps the
/// merged timeline (authored cues + derived + external meetings) grouped by day so we can
/// sanity-check the producers/store before rewiring the real Today view.
struct OccurrenceDebugView: View {
    @ObservedObject private var store = OccurrenceStore.shared
    @State private var loaded = false

    private var byDay: [(day: Date, items: [Occurrence])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: store.occurrences) { cal.startOfDay(for: $0.start) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.start < $1.start }) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(store.occurrences.count) occurrences across the horizon")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(byDay, id: \.day) { group in
                    Section(dayLabel(group.day)) {
                        ForEach(group.items) { occ in row(occ) }
                    }
                }
            }
            .navigationTitle("Occurrences")
            .toolbar {
                Button("Reload") { Task { await store.recompute() } }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            OccurrenceStore.shared.routines = RoutineStore.shared
            await store.recompute()
        }
    }

    private func row(_ occ: Occurrence) -> some View {
        HStack(spacing: 10) {
            Text(time(occ.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Image(systemName: occ.icon).foregroundStyle(occ.tint.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(occ.title).font(.footnote)
                Text("\(occ.source.rawValue) · \(occ.behavior.rawValue) · \(occ.schedule.mode.rawValue)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: d)
    }
    private func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}
#endif
