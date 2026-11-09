import Combine
import SwiftUI

/// What needs attention beside the reminders: routines past their time, and in builds with Food
/// meals to review and doses due (`PlanAttentionSnapshot`). They are chips in the same row as
/// the day's reminders and routines, on every device (owner, 9 Nov 2026: "they should be
/// unified"); there is no band, badge or count of their own.
///
/// The plan grid must not rebuild for these stores' publishes (docs/performance/
/// ui-performance-contract.md). It observes only this object, which publishes the number of
/// items when that number changes; the chips themselves are their own observed subview
/// (`PlanAttentionChips`).
@MainActor
final class PlanAttention: ObservableObject {
    static let shared = PlanAttention()

    /// How many items there are. Published only when it changes.
    @Published private(set) var count = 0
    private var watching: Set<AnyCancellable> = []

    private init() {
        var changes: [AnyPublisher<Void, Never>] = [
            OccurrenceStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            RoutineStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            ModuleStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            AnchoredTimingHub.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            // A routine or a dose comes due with the clock, not with a store.
            Timer.publish(every: 60, on: .main, in: .common).autoconnect().map { _ in }.eraseToAnyPublisher(),
        ]
        #if BANANA_MODULE_FOOD
        changes.append(MealInboxStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher())
        changes.append(WellnessStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher())
        #endif
        // `objectWillChange` comes before the change: count once the stores have settled.
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &watching)
        refresh()
    }

    func refresh() {
        let now = PlanAttentionSnapshot.make().count
        if now != count { count = now }
    }

}

/// The attention items as chips, the reminders' look and actions: the circle does it (a
/// routine done, a dose taken), the words open it (a routine's sheet, a meal to review). Placed
/// inside a row's own layout: its body is the chips themselves, so a wrapping row wraps them
/// with the reminders. Only on today's row.
struct PlanAttentionChips: View {
    /// The most chips before the rest fold behind "+N more" (a row that wraps); nil shows all
    /// (a row that scrolls sideways).
    var limit: Int?
    var desktop = false

    @ObservedObject private var attention = PlanAttention.shared
    @ObservedObject private var timeline = OccurrenceStore.shared
    @ObservedObject private var routines = RoutineStore.shared
    #if BANANA_MODULE_FOOD
    @ObservedObject private var inbox = MealInboxStore.shared
    @ObservedObject private var wellness = WellnessStore.shared
    #endif
    @ObservedObject private var modules = ModuleStore.shared
    @ObservedObject private var timing = AnchoredTimingHub.shared
    @State private var showingAll = false
    @State private var opening: Occurrence?
    #if BANANA_MODULE_FOOD
    @State private var reviewing: MealDayRequest?
    #endif

    var body: some View {
        let items = PlanAttentionSnapshot.make()
        let chips = items.chips
        let shown = PlanAttentionLine.shown(chips.count, limit: limit)
        ForEach(chips.prefix(shown.chips)) { chip in
            chipView(chip)
        }
        if shown.more > 0 {
            Button { showingAll = true } label: {
                Text("+\(shown.more) more")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.inline)
            .accessibilityIdentifier("plan.attention.more")
            .sheet(isPresented: $showingAll) { PlanAttentionList().toastHost() }
        }
    }

    @ViewBuilder private func chipView(_ chip: PlanAttentionSnapshot.Chip) -> some View {
        AttentionChip(chip: chip, desktop: desktop, complete: complete(chip), open: open(chip))
            .contextMenu {
                #if BANANA_MODULE_FOOD
                if case .dose(let dose) = chip.kind {
                    Button("Mark skipped", systemImage: "xmark.circle") {
                        wellness.logSupplement(dose.id, status: .skipped, at: NutritionDays.doseDate(for: dose.supplement, on: Date()))
                    }
                }
                #endif
            }
            .sheet(item: $opening) { occurrence in
                if let routine = routines.routines.first(where: { $0.id == occurrence.routineID }) {
                    CueOccurrenceSheet(occurrence: occurrence, routine: routine, plan: nil) { _ in opening = nil }
                }
            }
            #if BANANA_MODULE_FOOD
            .sheet(item: $reviewing) { request in MealDayReviewView(day: request.day).environmentObject(wellness) }
            #endif
    }

    private func complete(_ chip: PlanAttentionSnapshot.Chip) -> (() -> Void)? {
        switch chip.kind {
        case .routine(let item): return { CueCompletion.toggle(item.occurrence) }
        #if BANANA_MODULE_FOOD
        case .dose(let dose):
            return { wellness.logSupplement(dose.id, status: .taken, at: NutritionDays.doseDate(for: dose.supplement, on: Date())) }
        case .meal: return nil
        #endif
        }
    }

    private func open(_ chip: PlanAttentionSnapshot.Chip) -> (() -> Void)? {
        switch chip.kind {
        case .routine(let item): return { opening = item.occurrence }
        #if BANANA_MODULE_FOOD
        case .meal(let meal): return { reviewing = MealDayRequest(day: meal.eatenAt) }
        case .dose: return nil
        #endif
        }
    }
}

/// One attention item, drawn as a reminder chip is (`WeekView.reminderChip` on a phone and an
/// iPad, the To do row on the Mac): a circle that does it, the words, and when it was due.
private struct AttentionChip: View {
    let chip: PlanAttentionSnapshot.Chip
    let desktop: Bool
    let complete: (() -> Void)?
    let open: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let complete {
                Button(action: complete) {
                    Image(systemName: "circle")
                        .foregroundStyle(DS.Palette.task)
                        .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(chip.title) completed")
                .accessibilityIdentifier("plan.attention.done.\(chip.id)")
            } else {
                Image(systemName: chip.symbol)
                    .foregroundStyle(DS.Palette.quietText)
                    .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 6)
                    .accessibilityHidden(true)
            }
            Button { open?() } label: {
                HStack(spacing: 5) {
                    Text(chip.title)
                        .font(desktop ? DS.Typeface.eventTitle : .footnote)
                        .lineLimit(1)
                    Text(chip.detail)
                        .font(desktop ? DS.Typeface.eventMeta.weight(.semibold) : .caption2.weight(.semibold))
                        .foregroundStyle(chip.late ? DS.Palette.danger : DS.Palette.quietText)
                        .lineLimit(1)
                }
                .padding(.trailing, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(open == nil)
            .accessibilityLabel(open == nil ? "\(chip.title), \(chip.detail)" : "Open \(chip.title)")
            .accessibilityIdentifier("plan.attention.open.\(chip.id)")
        }
        .background { chipGround }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan.attention.chip")
    }

    /// The reminders' ground: the Mac's To do rows are a wash of the reminders' colour, a
    /// phone's and an iPad's chips are the calendar's white with a hairline.
    @ViewBuilder private var chipGround: some View {
        if desktop {
            Capsule().fill(DS.Palette.task.opacity(DS.Tint.subtle))
        } else {
            #if os(iOS)
            Capsule().fill(Color(.systemBackground))
                .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
            #endif
        }
    }
}

@MainActor
struct PlanAttentionSnapshot {
    struct RoutineItem: Identifiable {
        var occurrence: Occurrence
        var routine: Routine
        var id: String { occurrence.id }
    }
    #if BANANA_MODULE_FOOD
    struct Dose: Identifiable {
        var supplement: SupplementSchedule
        var due: Date
        var id: UUID { supplement.id }
    }
    #endif
    var routines: [RoutineItem] = []
    #if BANANA_MODULE_FOOD
    var meals: [MealInboxItem] = []
    var doses: [Dose] = []
    #else
    // Food's two parts, empty in a build without it.
    var meals: [Never] = []
    var doses: [Never] = []
    #endif
    var count: Int { routines.count + meals.count + doses.count }

    /// One item as a chip, in the row's order: routines, then meals, then doses.
    struct Chip: Identifiable {
        enum Kind {
            case routine(RoutineItem)
            #if BANANA_MODULE_FOOD
            case meal(MealInboxItem)
            case dose(Dose)
            #endif
        }
        var kind: Kind
        var id: String
        var title: String
        var detail: String
        var symbol: String
        /// Past its time (a routine, a dose), not merely waiting (a meal to review).
        var late: Bool
    }

    var chips: [Chip] {
        var result = routines.map {
            Chip(kind: .routine($0), id: "routine.\($0.routine.id.uuidString)", title: $0.occurrence.title,
                 detail: ActionItems.dueText(since: $0.occurrence.start), symbol: $0.routine.icon, late: true)
        }
        #if BANANA_MODULE_FOOD
        result += meals.map {
            Chip(kind: .meal($0), id: "meal.\($0.id)", title: $0.trimmedNote.isEmpty ? "Meal to review" : $0.trimmedNote,
                 detail: MealInboxText.when($0.eatenAt), symbol: "fork.knife", late: false)
        }
        result += doses.map {
            Chip(kind: .dose($0), id: "dose.\($0.id.uuidString)", title: $0.supplement.name,
                 detail: ActionItems.dueText(since: $0.due), symbol: "pills", late: true)
        }
        #endif
        return result
    }
    var summary: String {
        [(routines.count, "routine"), (meals.count, "meal"), (doses.count, "dose")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " · ")
    }
    static func make(now: Date = Date()) -> Self {
        var result = Self()
        let timeline = OccurrenceStore.shared.occurrences
        // A routine with no time of its own is already in the row as one of the day's moments.
        for occurrence in timeline where occurrence.behavior == .cue && occurrence.hasScheduledTime {
            guard let routine = RoutineStore.shared.routines.first(where: { $0.id == occurrence.routineID }),
                  routine.cueType == .custom || routine.cueType == .workout,
                  ActionItems.routineDueSince(start: occurrence.start, hasTime: occurrence.hasScheduledTime,
                      completed: occurrence.completed, skipped: occurrence.skipped, now: now) != nil else { continue }
            result.routines.append(.init(occurrence: occurrence, routine: routine))
        }
        result.routines.sort { $0.occurrence.start < $1.occurrence.start }
        #if BANANA_MODULE_FOOD
        if ModuleStore.shared.includes(.food) {
            result.meals = MealInboxStore.shared.items.filter(ActionItems.foodNeedsAttention).sorted { $0.eatenAt < $1.eatenAt }
            let wellness = WellnessStore.shared
            result.doses = wellness.supplements.compactMap { supplement in
                guard let due = ActionItems.dueSince(supplement, marked: wellness.supplementStatus(supplement.id, on: now) != nil,
                    due: AnchoredTimingHub.shared.dueDate(supplement, now: now), now: now) else { return nil }
                return Dose(supplement: supplement, due: due)
            }
            // A dose that is also an open reminder ("Creatine") is already a reminder chip.
            .filter { dose in
                !timeline.contains { $0.behavior == .task && !$0.completed
                    && $0.title.localizedCaseInsensitiveCompare(dose.supplement.name) == .orderedSame }
            }
            .sorted { $0.due < $1.due }
        }
        #endif
        return result
    }
}

struct PlanAttentionList: View {
    @ObservedObject private var timeline = OccurrenceStore.shared
    @ObservedObject private var routines = RoutineStore.shared
    #if BANANA_MODULE_FOOD
    @ObservedObject private var inbox = MealInboxStore.shared
    @ObservedObject private var wellness = WellnessStore.shared
    #endif
    @ObservedObject private var modules = ModuleStore.shared
    @ObservedObject private var timing = AnchoredTimingHub.shared
    @Environment(\.dismiss) private var dismiss
    #if BANANA_MODULE_FOOD
    @State private var reviewing: MealDayRequest?
    #endif

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
                    #if BANANA_MODULE_FOOD
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
                    #endif
                }
            }
            .navigationTitle("Needs attention")
            .toolbar { SheetClose { dismiss() } }
            #if BANANA_MODULE_FOOD
            .sheet(item: $reviewing) { request in MealDayReviewView(day: request.day).environmentObject(wellness) }
            #endif
        }
        #if os(macOS)
        // List has no useful intrinsic height. Give the desktop sheet a usable
        // initial size while retaining room for resizing and scrolling.
        .frame(minWidth: 520, idealWidth: 580, minHeight: 480, idealHeight: 600)
        #endif
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
