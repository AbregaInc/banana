import SwiftUI

// One look for each control (DESIGN-SYSTEM.md, "One look for each control").
//
// Every control here is the system's, with the app's choices set once: which system style a job
// gets, its size and its shape. A page never draws a button, a chip or a field of its own. The
// system then draws them the way the OS it runs on draws them.

// MARK: - Buttons

/// The app's buttons: `.primary`, `.secondary` and `.quiet`, each in three sizes.
///
/// - `.primary`: the one main action of a page, a sheet's content or a card. Filled, ink on the
///   accent (the system's white label is 2.3:1 on Banana's orange).
/// - `.secondary`: an action beside or under it. The system's bordered button.
/// - `.quiet`: the way out ("Not now"). Words alone, in the secondary colour.
/// - `.inline`: a small action in a line of text or a dense row ("Undo", "Edit"). Words alone,
///   in the accent.
///
/// Sizes: `.page` is full width at the bottom of a page or sheet; the plain one sits on a card or
/// in a row; `.small` sits inside a line or a dense card.
struct AppButtonStyle: PrimitiveButtonStyle {
    enum Kind { case primary, secondary, quiet, inline }
    enum Size { case page, regular, small }

    var kind: Kind
    var size: Size = .regular
    var fill: Color = DS.Palette.accent
    var label: Color = DS.Palette.onAccent
    /// A hairline, for a button that is the colour of the page (Google's white one).
    var outline: Color?

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let button = Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .multilineTextAlignment(.center)
                .frame(maxWidth: size == .page ? .infinity : nil)
                // A finger's target, whatever the size the system draws at (its regular
                // bordered button is 34 points tall on a phone).
                .frame(minHeight: labelHeight)
        }
        .controlSize(size == .page ? .large : size == .small ? .small : .regular)
        .buttonBorderShape(.capsule)

        switch kind {
        case .primary:
            button
                .buttonStyle(.borderedProminent)
                .tint(destructive ? DS.Palette.danger : fill)
                .foregroundStyle(destructive ? Color.white : label)
                .fontWeight(.semibold)
                .overlay { if let outline { Capsule().strokeBorder(outline, lineWidth: 1).allowsHitTesting(false) } }
        case .secondary:
            button.buttonStyle(.bordered)
        case .quiet:
            button.buttonStyle(.borderless).foregroundStyle(.secondary)
        case .inline:
            // A Mac's borderless button is grey; its link is the accent.
            #if os(macOS)
            button.buttonStyle(.link)
            #else
            button.buttonStyle(.borderless)
            #endif
        }
    }

    private var labelHeight: CGFloat? {
        #if os(iOS)
        switch (kind, size) {
        case (.quiet, _): DS.Row.minHeight
        case (.inline, _), (_, .small), (_, .page): nil
        default: 30
        }
        #else
        nil
        #endif
    }
}

extension PrimitiveButtonStyle where Self == AppButtonStyle {
    static var primary: AppButtonStyle { AppButtonStyle(kind: .primary) }
    static var primaryPage: AppButtonStyle { AppButtonStyle(kind: .primary, size: .page) }
    static var primarySmall: AppButtonStyle { AppButtonStyle(kind: .primary, size: .small) }
    static var secondary: AppButtonStyle { AppButtonStyle(kind: .secondary) }
    static var secondaryPage: AppButtonStyle { AppButtonStyle(kind: .secondary, size: .page) }
    static var secondarySmall: AppButtonStyle { AppButtonStyle(kind: .secondary, size: .small) }
    static var quiet: AppButtonStyle { AppButtonStyle(kind: .quiet) }
    static var inline: AppButtonStyle { AppButtonStyle(kind: .inline, size: .small) }
}

extension View {
    /// A button that is only a symbol, inside content (not a toolbar, which sizes its own): the
    /// system's borderless button on a full-size target.
    func iconButton() -> some View {
        // A pointer needs less than a finger.
        #if os(macOS)
        buttonStyle(.borderless)
        #else
        buttonStyle(.borderless)
            .frame(minWidth: DS.Row.minHeight, minHeight: DS.Row.minHeight)
            .contentShape(Rectangle())
        #endif
    }
}

// MARK: - Choices

/// One of a few choices that can each be on or off (weekdays, a filter): the system's toggle
/// button, as a capsule. For one choice out of a few, use a `Picker`.
struct ChoiceChip<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .toggleStyle(.button)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }
}

/// A word or two that says what something is (a state, a count, a kind). Not tappable.
struct Tag: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.hair)
        .background(tint.opacity(DS.Tint.soft), in: Capsule())
    }
}

/// Which days are on after one is tapped (`WeekdayToggleRow`). Unless the row may be left with
/// no day, the last one stays on.
enum WeekdaySelection {
    static func toggled<Day: Hashable>(_ day: Day, in selection: Set<Day>, allowsEmpty: Bool) -> Set<Day> {
        guard canToggle(day, in: selection, allowsEmpty: allowsEmpty) else { return selection }
        var next = selection
        if next.contains(day) { next.remove(day) } else { next.insert(day) }
        return next
    }

    static func canToggle<Day: Hashable>(_ day: Day, in selection: Set<Day>, allowsEmpty: Bool) -> Bool {
        allowsEmpty || !(selection.count == 1 && selection.contains(day))
    }
}

// MARK: - Clock time

/// The one way to set a clock time: the system's compact hour-and-minute field, in five-minute
/// steps. (the author, 11 Oct 2026: "we need five minutes steppers it can't be one minute".)
struct TimeField: View {
    private let title: String
    @Binding private var selection: Date
    private let range: ClosedRange<Date>?

    init(_ title: String, selection: Binding<Date>) {
        self.title = title
        _selection = selection
        range = nil
    }

    /// Between two times of the same day (`ClockTime.range`).
    init(_ title: String, selection: Binding<Date>, in range: ClosedRange<Date>) {
        self.title = title
        _selection = selection
        self.range = range
    }

    /// The system's wheels, for a page whose whole question is the time (onboarding's wake
    /// and wind-down). A row in a form is the compact field.
    func wheels() -> TimeField {
        var copy = self
        copy.showsWheels = true
        return copy
    }

    private var showsWheels = false

    var body: some View {
        #if os(macOS)
        // The Mac's field steps by single minutes; `FiveMinuteGrid.stepped` makes them fives.
        if let range {
            DatePicker(title, selection: FiveMinuteGrid.binding($selection), in: range, displayedComponents: .hourAndMinute)
        } else {
            DatePicker(title, selection: FiveMinuteGrid.binding($selection), displayedComponents: .hourAndMinute)
        }
        #else
        if showsWheels {
            FiveMinuteTimeWheel(selection: $selection, mode: .hourAndMinuteOnly, style: .wheels,
                                minimum: range?.lowerBound, maximum: range?.upperBound)
                .frame(height: 216)
                .accessibilityLabel(title)
        } else {
            LabeledContent(title) {
                FiveMinuteTimeWheel(selection: $selection, mode: .hourAndMinuteOnly, style: .compact,
                                    minimum: range?.lowerBound, maximum: range?.upperBound)
            }
        }
        #endif
    }
}

/// The one way to set a day and a time together (an event's start, an alarm, when a meal was
/// eaten): the system's compact field, in the same five-minute steps.
struct MomentField: View {
    private let title: String
    @Binding private var selection: Date
    private let earliest: Date?

    init(_ title: String, selection: Binding<Date>, from earliest: Date? = nil) {
        self.title = title
        _selection = selection
        self.earliest = earliest
    }

    var body: some View {
        #if os(macOS)
        if let earliest {
            DatePicker(title, selection: FiveMinuteGrid.binding($selection), in: earliest...,
                       displayedComponents: [.date, .hourAndMinute])
        } else {
            DatePicker(title, selection: FiveMinuteGrid.binding($selection), displayedComponents: [.date, .hourAndMinute])
        }
        #else
        LabeledContent(title) {
            FiveMinuteTimeWheel(selection: $selection, mode: .fullDate, style: .compact, minimum: earliest)
        }
        #endif
    }
}

extension FiveMinuteGrid {
    /// A binding whose every change lands on the grid (`stepped`).
    static func binding(_ date: Binding<Date>) -> Binding<Date> {
        Binding(get: { date.wrappedValue },
                set: { date.wrappedValue = stepped(from: date.wrappedValue, to: $0) })
    }
}

/// A clock time kept as minutes after midnight, for a `TimeField`.
enum ClockTime {
    /// One fixed day, so a time never lands in a day's missing or repeated hour.
    private static let day = Date(timeIntervalSinceReferenceDate: 0)

    static func date(minutes: Int, calendar: Calendar = .current) -> Date {
        let minutes = min(max(minutes, 0), 24 * 60 - 1)
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                             of: calendar.startOfDay(for: day)) ?? day
    }

    static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The minutes a picked time is stored as: inside `range`, when there is one.
    static func stored(_ date: Date, in range: ClosedRange<Int>? = nil, calendar: Calendar = .current) -> Int {
        let picked = minutes(of: date, calendar: calendar)
        guard let range else { return picked }
        return min(max(picked, range.lowerBound), range.upperBound)
    }

    static func range(_ minutes: ClosedRange<Int>, calendar: Calendar = .current) -> ClosedRange<Date> {
        date(minutes: minutes.lowerBound, calendar: calendar) ... date(minutes: minutes.upperBound, calendar: calendar)
    }

    static func binding(_ minutes: Binding<Int>, in range: ClosedRange<Int>? = nil) -> Binding<Date> {
        Binding(get: { date(minutes: minutes.wrappedValue) },
                set: { minutes.wrappedValue = stored($0, in: range) })
    }
}

// MARK: - Fields and forms

/// The notes field of an editing sheet: grows with what is typed, between the same limits
/// everywhere.
struct NotesField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text, axis: .vertical)
            .lineLimit(2...8)
    }
}

extension View {
    /// Every sheet that edits something: the system's grouped form, at a readable width.
    @ViewBuilder func editingFormStyle() -> some View {
        #if os(macOS)
        self.formStyle(.grouped).formControls()
        #else
        self.formStyle(.grouped).readableColumn().formControls()
        #endif
    }

    /// What every form's controls share, set once on the form: a switch is a switch (a bare
    /// `Toggle` is a checkbox in some Mac containers) and it is on in the accent.
    func formControls() -> some View {
        #if os(macOS)
        toggleStyle(.switch).tint(DS.Palette.accent)
        #else
        tint(DS.Palette.accent)
        #endif
    }

    /// Something that floats over the page for a moment (a toast, a notice, a map's legend):
    /// the system's glass, as a capsule.
    func floatingCapsule() -> some View {
        glassEffect(.regular, in: .capsule)
    }
}

/// The sign that a row opens something, where the row isn't a `NavigationLink` (which draws its
/// own): the system's chevron, in the tertiary colour, at the trailing edge.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
