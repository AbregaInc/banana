import SwiftUI

/// "When" for something done each day: at a time, or around a moment — after your workout,
/// 30 min before breakfast, after another reminder — with its own time as what happens otherwise
/// (`TimingAnchor`, docs/design/ANCHORED-TIMING.md). Used by Taken's editors and reminders'.
struct TimingFields: View {
    @Binding var anchor: TimingAnchor?
    @Binding var time: Date
    /// Other things it could follow: Taken items and repeating reminders, by name.
    var others: [TimingAnchor.Moment] = []
    /// False where the form already has its own time field (a reminder's): that time is what
    /// happens otherwise, and isn't asked twice.
    var showsOwnTime = true

    private enum Mode: String, CaseIterable, Identifiable {
        case time = "At a time", around = "Around something"
        var id: String { rawValue }
    }

    static let minuteChoices = TimingAnchor.minuteChoices

    private var mode: Binding<Mode> {
        Binding(get: { anchor == nil ? .time : .around },
                set: { anchor = $0 == .time ? nil : (anchor ?? TimingAnchor(moment: .workout)) })
    }

    private var moments: [TimingAnchor.Moment] {
        [.workout, .wake, .meal(MealTextPart.breakfast.rawValue), .meal(MealTextPart.lunch.rawValue),
         .meal(MealTextPart.dinner.rawValue), .meal(nil)] + others
    }

    var body: some View {
        Picker("When", selection: mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("timing.mode")
        if let current = anchor {
            Picker("Around", selection: Binding(get: { current.moment }, set: { anchor?.moment = $0 })) {
                ForEach(moments, id: \.self) { Text(Self.name($0)).tag($0) }
            }
            .accessibilityIdentifier("timing.moment")
            Picker("Before or after", selection: Binding(get: { current.relation }, set: { anchor?.relation = $0 })) {
                Text("After").tag(TimingAnchor.Relation.after)
                Text("Before").tag(TimingAnchor.Relation.before)
            }
            .pickerStyle(.segmented)
            Picker(current.relation == .before ? "How long before" : "How long after",
                   selection: Binding(get: { current.minutes }, set: { anchor?.minutes = $0 })) {
                ForEach(Self.minuteChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? (current.relation == .before ? "Just before" : "Right away")
                                      : AnchoredTiming.duration(minutes)).tag(minutes)
                }
            }
            .accessibilityIdentifier("timing.minutes")
            Toggle("If it doesn\u{2019}t happen, still remind me",
                   isOn: Binding(get: { current.fallback == .usualTime }, set: { anchor?.fallback = $0 ? .usualTime : .skip }))
            if current.fallback == .usualTime, showsOwnTime {
                TimeField("At", selection: $time)
            }
        } else if showsOwnTime {
            TimeField("Time", selection: $time)
        }
    }

    /// "Workout", "Waking", "Breakfast", "First meal", or the item's own name.
    static func name(_ moment: TimingAnchor.Moment) -> String {
        switch moment {
        case .workout: return "Workout"
        case .wake: return "Waking"
        case .meal(let raw): return raw.flatMap(MealTextPart.init(rawValue:))?.title ?? "First meal"
        case .reminder(_, let title): return title
        case .dose(_, let name): return name
        case .event(let words): return words.first.map { "\u{201C}\($0)\u{201D}" } ?? "Event"
        }
    }
}

extension AnchoredTimingHub {
    /// A Taken item's time as its row says it: "8:00 AM", "After your workout", "After your
    /// workout · 9:42 AM" once its moment came, "Not today" on a day it skips.
    func timeText(_ supplement: SupplementSchedule, on day: Date = Date(), now: Date = Date(),
                  calendar: Calendar = .current) -> String {
        let usual = calendar.date(bySettingHour: supplement.safeHour, minute: supplement.safeMinute, second: 0,
                                  of: day) ?? day
        let clock = usual.formatted(date: .omitted, time: .shortened)
        guard let anchor = supplement.anchor else { return clock }
        guard calendar.isDate(day, inSameDayAs: now) else { return AnchoredTiming.label(anchor) }
        switch due(supplement, now: now, calendar: calendar) {
        case .at(let date):
            let at = date.formatted(date: .omitted, time: .shortened)
            return date == usual ? at : "\(AnchoredTiming.label(anchor)) \u{00B7} \(at)"
        case .waiting(let label): return label
        case .skipped: return "Not today"
        }
    }

    /// What a Taken item could be due around besides the usual moments: the other Taken items.
    static func otherMoments(excluding id: UUID?, supplements: [SupplementSchedule]) -> [TimingAnchor.Moment] {
        supplements.filter { $0.id != id }.map { .dose(id: $0.id, name: $0.name) }
    }
}
