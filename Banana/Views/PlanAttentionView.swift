import SwiftUI

/// Kept in its own observed subtree: backlog/dose publishes must not rebuild the clock grid.
struct PlanAttentionBand: View {
    @ObservedObject private var timeline = OccurrenceStore.shared
    @ObservedObject private var routines = RoutineStore.shared
    @ObservedObject private var inbox = MealInboxStore.shared
    @ObservedObject private var wellness = WellnessStore.shared
    @ObservedObject private var modules = ModuleStore.shared
    @ObservedObject private var timing = AnchoredTimingHub.shared
    @State private var showing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            // Overdue reminders already have completion/edit controls in the calendar's
            // reminders row. This band only adds the other kinds of work due.
            let items = PlanAttentionSnapshot.make()
            if items.count > 0 {
                Button { showing = true } label: {
                    HStack(spacing: 8) {
                        Label("Needs attention", systemImage: "tray.full")
                            .font(.subheadline.weight(.semibold))
                        Text("\(items.count)").font(.subheadline.monospacedDigit())
                        Spacer(minLength: 4)
                        Text(items.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, DS.Space.m)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Needs attention, \(items.summary)")
                .accessibilityIdentifier("plan.attention")
            }
        }
        .sheet(isPresented: $showing) { PlanAttentionList().toastHost() }
    }
}

@MainActor
private struct PlanAttentionSnapshot {
    struct RoutineItem: Identifiable {
        var occurrence: Occurrence
        var routine: Routine
        var id: String { occurrence.id }
    }
    struct Dose: Identifiable {
        var supplement: SupplementSchedule
        var due: Date
        var id: UUID { supplement.id }
    }
    var routines: [RoutineItem] = []
    var meals: [MealInboxItem] = []
    var doses: [Dose] = []
    var count: Int { routines.count + meals.count + doses.count }
    var summary: String {
        [(routines.count, "routine"), (meals.count, "meal"), (doses.count, "dose")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " · ")
    }
    static func make(now: Date = Date()) -> Self {
        var result = Self()
        let timeline = OccurrenceStore.shared.occurrences
        for occurrence in timeline where occurrence.behavior == .cue {
            guard let routine = RoutineStore.shared.routines.first(where: { $0.id == occurrence.routineID }),
                  routine.cueType == .custom || routine.cueType == .workout,
                  ActionItems.routineDueSince(start: occurrence.start, hasTime: occurrence.hasScheduledTime,
                      completed: occurrence.completed, skipped: occurrence.skipped, now: now) != nil else { continue }
            result.routines.append(.init(occurrence: occurrence, routine: routine))
        }
        result.routines.sort { $0.occurrence.start < $1.occurrence.start }
        if ModuleStore.shared.includes(.food) {
            result.meals = MealInboxStore.shared.items.filter(ActionItems.foodNeedsAttention).sorted { $0.eatenAt < $1.eatenAt }
            let wellness = WellnessStore.shared
            result.doses = wellness.supplements.compactMap { supplement in
                guard let due = ActionItems.dueSince(supplement, marked: wellness.supplementStatus(supplement.id, on: now) != nil,
                    due: AnchoredTimingHub.shared.dueDate(supplement, now: now), now: now) else { return nil }
                return Dose(supplement: supplement, due: due)
            }.sorted { $0.due < $1.due }
        }
        return result
    }
}

private struct PlanAttentionList: View {
    @ObservedObject private var timeline = OccurrenceStore.shared
    @ObservedObject private var routines = RoutineStore.shared
    @ObservedObject private var inbox = MealInboxStore.shared
    @ObservedObject private var wellness = WellnessStore.shared
    @ObservedObject private var modules = ModuleStore.shared
    @ObservedObject private var timing = AnchoredTimingHub.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reviewing: MealDayRequest?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                let items = PlanAttentionSnapshot.make()
                List {
                    if items.count == 0 {
                        ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("Nothing needs your attention right now."))
                    }
                    if !items.routines.isEmpty {
                        Section("Routines due") {
                            ForEach(items.routines) { item in
                                attentionRow(item.occurrence.title, detail: ActionItems.dueText(since: item.occurrence.start), icon: item.routine.icon) {
                                    CueCompletion.toggle(item.occurrence)
                                }
                                .accessibilityIdentifier("plan.attention.routine.\(item.routine.id.uuidString)")
                            }
                        }
                    }
                    if !items.meals.isEmpty {
                        Section("Food to review") {
                            ForEach(items.meals) { meal in
                                Button { reviewing = MealDayRequest(day: meal.eatenAt) } label: {
                                    HStack {
                                        Label(meal.trimmedNote.isEmpty ? "Meal to review" : meal.trimmedNote, systemImage: "fork.knife")
                                            .lineLimit(2)
                                        Spacer()
                                        Text(MealInboxText.when(meal.eatenAt)).font(.caption).foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").font(.caption)
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                    if !items.doses.isEmpty {
                        Section("Taken · due") {
                            ForEach(items.doses) { dose in
                                attentionRow(dose.supplement.name, detail: ActionItems.dueText(since: dose.due), icon: "pills") {
                                    wellness.logSupplement(dose.id, status: .taken, at: NutritionDays.doseDate(for: dose.supplement, on: Date()))
                                }
                                .contextMenu {
                                    Button("Mark skipped", systemImage: "xmark.circle") {
                                        wellness.logSupplement(dose.id, status: .skipped, at: NutritionDays.doseDate(for: dose.supplement, on: Date()))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Needs attention")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $reviewing) { request in MealDayReviewView(day: request.day).environmentObject(wellness) }
        }
    }

    private func attentionRow(_ title: String, detail: String, icon: String, complete: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: complete) { Image(systemName: "circle").font(.title2) }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Mark \(title) completed")
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
