import SwiftUI

/// The Repeat rows of an event form — new and existing events, iPhone, iPad and Mac alike
/// (ADAPTIVE-LAYOUT.md rule 5). Rows for a `Section`:
///
/// - Repeat: Never, Daily, Weekdays, Weekly, Monthly, Yearly, Custom — one word, so the row
///   never wraps.
/// - Under any weekly repeat, a toggle for each day of the week: several days are as easy as
///   one ("Every week on Mon, Wed and Fri"), and Mon–Fri reads as Every weekday.
/// - Custom: every N days/weeks/months/years, and for a month the date or the weekday.
/// - Ends: never, on a date (that day included), or after a number of times.
struct RepeatPicker: View {
    @Binding var recurrence: EventRecurrence
    let start: Date
    let isAllDay: Bool
    /// The prefix of the accessibility identifiers, so the new-event form keeps its own.
    var identifier = "event"

    /// Custom keeps its controls open even for a rule a preset could show.
    @State private var customOpen = false
    private let calendar = Calendar.current

    private var value: EventRepeat? { recurrence.repeatValue }

    var body: some View {
        Picker("Repeat", selection: presetBinding) {
            ForEach(EventRepeatPreset.allCases) { preset in
                Text(title(for: preset)).tag(preset)
            }
        }
        .accessibilityIdentifier("\(identifier).recurrence")

        if case .unsupported = recurrence {
            Text("A custom rule from Google Calendar. Pick another to replace it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if customOpen, let value {
            customRows(value)
        }

        if let value, value.frequency == .weekly {
            WeekdayToggleRow(selection: weekdaysBinding, identifier: identifier)
            if let aligned = value.alignedStart(start, calendar: calendar) {
                Text("Starts \(aligned.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), the first of these days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if let value {
            endRows(value)
            // The whole rule in words, when the Repeat row above doesn't already say it: an end,
            // an interval, a custom rule.
            if customOpen || value.end != .never || value.interval != 1 {
                Text(value.summary(start: start, calendar: calendar))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier).repeatSummary")
            }
        }
    }

    // MARK: - Presets

    private var presetBinding: Binding<EventRepeatPreset> {
        Binding(
            get: { customOpen ? .custom : EventRepeat.preset(of: recurrence) },
            set: { choice in
                // Picking the row it's already on keeps the days chosen under it.
                if choice == EventRepeat.preset(of: recurrence), !customOpen { return }
                customOpen = choice == .custom
                switch choice {
                case .custom:
                    if value == nil { recurrence = EventRepeat.preset(.weekly, start: start, calendar: calendar) }
                case .never:
                    recurrence = .none
                default:
                    guard case .rule(var fresh) = EventRepeat.preset(choice, start: start, calendar: calendar) else { return }
                    fresh.end = value?.end ?? .never
                    recurrence = .rule(fresh)
                }
            })
    }

    /// One word, so the row never wraps: the day chips under a weekly repeat show its days.
    private func title(for preset: EventRepeatPreset) -> String {
        switch preset {
        case .never: return "Never"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .custom: return "Custom\u{2026}"
        }
    }

    // MARK: - Custom

    @ViewBuilder private func customRows(_ value: EventRepeat) -> some View {
        Picker("Frequency", selection: Binding(
            get: { value.frequency },
            set: { frequency in
                update { rule in
                    rule.frequency = frequency
                    if frequency == .weekly, rule.weekdays.isEmpty {
                        rule.weekdays = [EventRepeat.Weekday(of: start, calendar: calendar)]
                    }
                    if frequency != .weekly { rule.weekdays = [] }
                    if frequency != .monthly { rule.monthly = nil }
                }
            })) {
            Text("Daily").tag(EventRepeat.Frequency.daily)
            Text("Weekly").tag(EventRepeat.Frequency.weekly)
            Text("Monthly").tag(EventRepeat.Frequency.monthly)
            Text("Yearly").tag(EventRepeat.Frequency.yearly)
        }
        .accessibilityIdentifier("\(identifier).repeatFrequency")

        Stepper(value: Binding(get: { value.interval }, set: { interval in update { $0.interval = interval } }),
                in: 1...99) {
            Text(value.interval == 1 ? "Every \(value.frequency.unit)" : "Every \(value.interval) \(value.frequency.unit)s")
        }
        .accessibilityIdentifier("\(identifier).repeatInterval")

        if value.frequency == .monthly {
            Picker("On", selection: Binding(
                get: { value.monthly ?? .dayOfMonth(calendar.component(.day, from: start)) },
                set: { mode in update { $0.monthly = mode } })) {
                ForEach(monthlyChoices, id: \.self) { mode in
                    Text(monthlyLabel(mode)).tag(mode)
                }
            }
        }
    }

    /// The start's date, its weekday's place in the month, and — in the month's last week — "the last".
    private var monthlyChoices: [EventRepeat.MonthlyMode] {
        let day = calendar.component(.day, from: start)
        let weekday = EventRepeat.Weekday(of: start, calendar: calendar)
        var choices: [EventRepeat.MonthlyMode] = [.dayOfMonth(day), .weekdayOrdinal(ordinal: min((day - 1) / 7 + 1, 5), weekday: weekday)]
        if let days = calendar.range(of: .day, in: .month, for: start), day + 7 > days.count {
            choices.append(.weekdayOrdinal(ordinal: -1, weekday: weekday))
        }
        return choices
    }

    private func monthlyLabel(_ mode: EventRepeat.MonthlyMode) -> String {
        let text = EventRepeat(frequency: .monthly, monthly: mode).summary(start: start, calendar: calendar)
        return text.replacingOccurrences(of: "Every month on ", with: "")
    }

    // MARK: - Ends

    private enum EndKind: Hashable { case never, onDate, afterCount }

    @ViewBuilder private func endRows(_ value: EventRepeat) -> some View {
        Picker("Ends", selection: Binding(
            get: {
                switch value.end {
                case .never: return EndKind.never
                case .onDate: return .onDate
                case .afterCount: return .afterCount
                }
            },
            set: { kind in
                update { rule in
                    switch kind {
                    case .never: rule.end = .never
                    case .onDate:
                        rule.end = .onDate(calendar.date(byAdding: .month, value: 3, to: start) ?? start)
                    case .afterCount: rule.end = .afterCount(10)
                    }
                }
            })) {
            Text("Never").tag(EndKind.never)
            Text("On a date").tag(EndKind.onDate)
            Text("After a number of times").tag(EndKind.afterCount)
        }
        .accessibilityIdentifier("\(identifier).recurrenceEnds")

        switch value.end {
        case .never:
            EmptyView()
        case .onDate(let lastDay):
            DatePicker("Last day", selection: Binding(
                get: { lastDay },
                set: { day in update { $0.end = .onDate(day) } }),
                       in: start..., displayedComponents: .date)
                .accessibilityIdentifier("\(identifier).recurrenceEnd")
        case .afterCount(let count):
            Stepper(value: Binding(get: { count }, set: { number in update { $0.end = .afterCount(number) } }),
                    in: 1...999) {
                Text(count == 1 ? "Once" : "\(count) times")
            }
        }
    }

    // MARK: - Editing the rule

    private var weekdaysBinding: Binding<Set<EventRepeat.Weekday>> {
        Binding(
            get: { value?.weekdays ?? [] },
            set: { days in
                guard !days.isEmpty else { return }   // a weekly repeat keeps at least one day
                update { $0.weekdays = days }
            })
    }

    private func update(_ change: (inout EventRepeat) -> Void) {
        guard var rule = value else { return }
        change(&rule)
        recurrence = .rule(rule)
    }
}

/// The one weekday picker: a toggle for each day of the week, in the order the locale's week
/// starts.
struct WeekdayToggleRow: View {
    @Binding var selection: Set<EventRepeat.Weekday>
    var identifier = "event"
    /// False keeps the last day on (a weekly repeat needs one); true lets every day be off.
    var allowsEmpty = false
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(EventRepeat.Weekday.ordered(for: calendar)) { day in
                let on = selection.contains(day)
                Button {
                    selection = WeekdaySelection.toggled(day, in: selection, allowsEmpty: allowsEmpty)
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[day.rawValue - 1])
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #else
                        .frame(minHeight: 28)
                        #endif
                        .foregroundStyle(on ? DS.Palette.onAccent : Color.primary)
                        .background(on ? DS.Palette.accent : Color.primary.opacity(DS.Tint.subtle),
                                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[day.rawValue - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).repeatDay.\(day.code)")
                .disabled(!WeekdaySelection.canToggle(day, in: selection, allowsEmpty: allowsEmpty))
            }
        }
    }
}
