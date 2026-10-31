import SwiftUI

/// The first run, the same on a phone, an iPad and a Mac: a welcome that asks what Banana should
/// look after, two questions that build a day in front of the person (when it starts, when it
/// winds down), the calendar, shown by what Banana does between two of them, the other calendar,
/// then the app. One path (`OnboardingFlow`): the welcome's choice only decides what is shown.
///
/// The welcome used to say the four areas, not ask (17 Oct 2026 changed it): the author wants a
/// new person to start with what they came for, Plan alone unless they tick more (the calendar is
/// the way in), and himself to have everything. Settings › Modules changes it later; off only
/// hides.
///
/// Nothing here is required and nothing gates the app. Whatever is skipped is on the setup list
/// (`SetupSheet`), which the plan offers whether or not a calendar is connected.
///
/// What it was, and why it changed (review of 9 Oct 2026): three screens whose way forward was
/// 20-point text in a corner, page dots that didn't swipe, a red button for Google, a last card
/// that only said "Banana is ready", the phone's layout stretched across an iPad, and on the Mac
/// a different screen altogether that could not be passed without a Google account.
struct OnboardingView: View {
    @EnvironmentObject private var onboarding: OnboardingStore
    @ObservedObject private var google = GoogleCalendarService.shared
    @ObservedObject private var writeBack = CalendarWriteBack.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var widthClass
    @State private var connecting = false
    @State private var problem: String?

    var body: some View {
        Group {
            switch onboarding.step {
            case .welcome: welcome
            case .wake: wake
            case .windDown: windDown
            case .calendar: calendar
            case .otherCalendar: otherCalendar
            }
        }
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)))
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: onboarding.step)
        .task {
            #if DEBUG
            // Straight to one step, for a picture of it.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--onboarding-wake-preview") { onboarding.step = .wake }
            if arguments.contains("--onboarding-winddown-preview") { onboarding.step = .windDown }
            if arguments.contains("--onboarding-calendar-preview") { onboarding.step = .calendar }
            if !Self.previewAccounts.isEmpty { onboarding.step = .otherCalendar }
            #endif
            await onboarding.refresh()
        }
        // An account that arrives by itself (signed in on another device, carried over by
        // iCloud Keychain) while this step is showing: straight in, as after a sign-in here.
        .onChange(of: google.isConnected) { _, connected in
            if connected, onboarding.step == .calendar, !connecting { advance() }
        }
        // How far a first run gets (`Telemetry`): each step as it comes up.
        .onChange(of: onboarding.step, initial: true) { _, step in
            Telemetry.shared.record(.onboarding(Self.counted(step), .shown))
        }
    }

    private static func counted(_ step: OnboardingStep) -> Telemetry.Signal.Step {
        switch step {
        case .welcome: .welcome
        case .wake: .wake
        case .windDown: .winddown
        case .calendar: .calendar
        case .otherCalendar: .otherCalendar
        }
    }

    // MARK: - Welcome

    /// A whole iPad screen or a Mac window, where the page sits in the middle.
    private var roomy: Bool {
        #if os(macOS)
        true
        #else
        widthClass == .regular
        #endif
    }

    private var welcome: some View {
        OnePage(centred: roomy) {
            BrandMark()
                .padding(.top, DS.Space.l)
                .frame(maxWidth: .infinity)
            Text("What should Banana look after?")
                .font(.largeTitle.bold())
                .pageTitle()
                .accessibilityAddTraits(.isHeader)
            ModuleChooser(choice: $onboarding.modules)
        } actions: {
            Button("Get started") {
                ModuleStore.shared.set(onboarding.modules)
                advance()
            }
                .buttonStyle(.primaryCapsule)
                .accessibilityIdentifier("onboarding.continue")
            DemoEntryButton().buttonStyle(.plain).font(.callout)
            // Getting started is agreeing to them: the one place they're asked for.
            Text("By continuing you agree to the [Terms](\(Telemetry.termsURL.absoluteString)) and [Privacy Policy](\(Telemetry.privacyURL.absoluteString)).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("onboarding.terms")
        }
    }

    // MARK: - The two questions

    // Each answer moves a block on the day above it, and is on the plan when the app opens:
    // these are two of the few things a new person can say that change the plan at once.

    private var wake: some View {
        question("When do you wake up?", stage: .wake, minutes: \.wakeMinutes,
                 range: DayAnchors.wakeRange, id: "onboarding.wake.time")
    }

    private var windDown: some View {
        question("When do you wind down?", stage: .windDown, minutes: \.windDownMinutes,
                 range: DayAnchors.windDownRange, id: "onboarding.windDown.time")
    }

    private func question(_ title: String, stage: DayDraft.Stage, minutes: WritableKeyPath<DayAnchors, Int>,
                          range: ClosedRange<Int>, id: String) -> some View {
        OnePage(onBack: { back() }, centred: roomy) {
            DayDraft(anchors: onboarding.anchors, stage: stage)
            Text(title)
                .font(.title.bold())
                .pageTitle()
                .accessibilityAddTraits(.isHeader)
            timePicker(title, minutes: minutes, range: range)
                .accessibilityIdentifier(id)
        } actions: {
            Button("Continue") { advance() }
                .buttonStyle(.primaryCapsule)
                .accessibilityIdentifier("onboarding.continue")
        }
    }

    private func timePicker(_ title: String, minutes: WritableKeyPath<DayAnchors, Int>,
                            range: ClosedRange<Int>) -> some View {
        let stored = Binding<Int>(
            get: { onboarding.anchors[keyPath: minutes] },
            set: { onboarding.anchors[keyPath: minutes] = $0 })
        return TimeField(title, selection: ClockTime.binding(stored, in: range), in: ClockTime.range(range))
            .wheels()
            .labelsHidden()
            .frame(maxWidth: .infinity)
    }

    // MARK: - Calendar

    private var calendar: some View {
        OnePage(onBack: { back() }, centred: roomy) {
            // What connecting is for, drawn: a meeting on one calendar leaves the other looking
            // free, and with Banana it doesn't. (This was the day with an empty middle under
            // "Add your meetings", which showed one calendar and nothing Banana does with two.)
            // Before sits above the title and after below it (the author, 10 Oct 2026): the title is
            // what turns one into the other.
            BusyBeforeAfter(stage: .before, captioned: true)
            Text("Never double-booked")
                .font(.title.bold())
                .pageTitle()
                .accessibilityAddTraits(.isHeader)
            BusyBeforeAfter(stage: .after, captioned: true)
        } actions: {
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.calendar.problem")
            }
            GoogleButton(working: connecting) { Task { await connect() } }
            Button("Not now") {
                Telemetry.shared.record(.onboarding(Self.counted(onboarding.step), .skipped))
                finish()
            }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("onboarding.notNow")
        }
    }

    // MARK: - The other calendar

    /// After the first sign-in: the account that is in, and a place for the other one. Work and
    /// personal is the pair this is for. With two in, the main button is the yes to busy blocks.
    private var otherCalendar: some View {
        let emails = connectedEmails
        let action = OnboardingFlow.otherCalendarAction(accounts: emails.count)
        return OnePage(centred: roomy) {
            BusyBeforeAfter(stage: .after)
            Text(action == .addAccount ? "Add your other calendar" : "Keep them in step")
                .font(.title.bold())
                .pageTitle()
                .accessibilityAddTraits(.isHeader)
            AccountList(emails: emails, adding: connecting) { Task { await addAccount() } }
        } actions: {
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.calendar.problem")
            }
            switch action {
            case .addAccount:
                GoogleButton(working: connecting) { Task { await addAccount() } }
            case .blockBusyTime:
                // The yes: busy blocks start only now, on the calendars the person owns.
                Button("Block busy time") {
                    writeBack.answerQuestion()
                    finish()
                }
                .buttonStyle(.primaryCapsule)
                .accessibilityIdentifier("onboarding.blockBusy")
            }
            Button("Not now") {
                Telemetry.shared.record(.onboarding(Self.counted(onboarding.step), .skipped))
                finish()
            }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("onboarding.notNow")
        }
    }

    private var connectedEmails: [String] {
        #if DEBUG
        if !Self.previewAccounts.isEmpty { return Self.previewAccounts }
        #endif
        return google.accounts.map(\.email)
    }

    #if DEBUG
    /// A simulator has no Google account: the step is shown with one or two made-up ones.
    private static var previewAccounts: [String] {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--onboarding-two-calendars-preview") { return ["sam@work.example", "sam@home.example"] }
        if arguments.contains("--onboarding-other-calendar-preview") { return ["sam@work.example"] }
        return []
    }
    #else
    private static let previewAccounts: [String] = []
    #endif

    @MainActor
    private func addAccount() async {
        guard !connecting else { return }
        connecting = true
        problem = nil
        await google.connect()
        writeBack.refreshCalendars()
        connecting = false
        problem = google.lastError
    }

    // MARK: - Moving on

    private func advance() {
        Telemetry.shared.record(.onboarding(Self.counted(onboarding.step), .continued))
        // An answer is on the plan as soon as its question is left.
        if onboarding.step == .wake || onboarding.step == .windDown { onboarding.applyAnchors() }
        if let next = OnboardingFlow.next(after: onboarding.step, accounts: google.accounts.count,
                                          busySettled: writeBack.questionSettled) {
            onboarding.step = next
        } else {
            finish()
        }
    }

    private func back() {
        if let previous = OnboardingFlow.previous(before: onboarding.step) { onboarding.step = previous }
    }

    @MainActor
    private func connect() async {
        guard !connecting else { return }
        connecting = true
        problem = nil
        let connected = await onboarding.requestCalendar()
        connecting = false
        if connected {
            // On to the other calendar, or the plan when busy blocks already have an answer.
            advance()
        } else {
            // Closing Google's page leaves no message, and needs none. Anything else is said:
            // on a phone it wasn't, and the button simply went back to how it was.
            problem = onboarding.calendarErrorMessage
        }
    }

    /// Into the app, on the plan.
    private func finish() {
        Telemetry.shared.record(.onboarding(.done, .shown))
        onboarding.applyAnchors()
        onboarding.finish()
    }
}

// MARK: - The day being built

/// The day the first run builds: its two ends as the person sets them, and a middle that is
/// faint until the calendar step, where it is drawn empty for the calendar to fill.
struct DayDraft: View {
    enum Stage { case wake, windDown, calendar }
    let anchors: DayAnchors
    let stage: Stage

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            end("Wake", symbol: "sunrise.fill", tint: DS.Palette.Feature.wake, glyph: DS.Palette.onAccent,
                minutes: anchors.wakeMinutes, faint: false)
            middle
            end("Wind down", symbol: "moon.fill", tint: DS.Palette.Brand.purple, glyph: nil,
                minutes: anchors.windDownMinutes, faint: stage == .wake)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your day: wake at \(Self.label(anchors.wakeMinutes)), wind down at \(Self.label(anchors.windDownMinutes)).")
    }

    private func end(_ title: String, symbol: String, tint: Color, glyph: Color?, minutes: Int, faint: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: symbol, tint: tint, glyph: glyph)
            Text(title).font(.headline)
            Spacer(minLength: DS.Space.s)
            Text(Self.label(minutes))
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: minutes)
        }
        .opacity(faint ? 0.35 : 1)
    }

    /// The hours between: three slots where meetings will sit. Faint while the ends are being
    /// set; outlined and empty once the calendar is what is being asked for.
    private var middle: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach([0.82, 0.58, 0.7], id: \.self) { width in
                let slot = RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
                Group {
                    if stage == .calendar {
                        slot.strokeBorder(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    } else {
                        slot.fill(Color.primary.opacity(DS.Tint.wash))
                    }
                }
                .frame(height: 26)
                .containerRelativeFrame(.horizontal) { length, _ in length * width * 0.7 }
            }
        }
        .padding(.leading, DS.Row.iconTile + DS.Space.m)
    }

    static func date(at minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func label(_ minutes: Int) -> String {
        date(at: minutes).formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Two calendars, before and after

/// What Banana does between two calendars, as a small pair of columns: before, a meeting on one
/// leaves the same hour looking free on the other; after, that hour reads Busy there.
struct BusyBeforeAfter: View {
    enum Stage { case before, after }
    var stage = Stage.after
    /// Whether the card says which of the two it is: only where both are on the page.
    var captioned = false

    var body: some View {
        pair(captioned ? (stage == .before ? "Before" : "After") : nil, blocked: stage == .after)
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stage == .before
                ? "Before: a meeting on Work leaves that hour free on Personal, and the other way round."
                : "\(captioned ? "After: a" : "A") meeting on Work shows as Busy on Personal, and the other way round.")
            .accessibilityIdentifier(stage == .before ? "onboarding.busyBefore" : "onboarding.busyPicture")
    }

    private func pair(_ caption: String?, blocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let caption {
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: DS.Space.m) {
                column("Work", symbol: "briefcase.fill", tint: DS.Palette.Brand.blue,
                       first: .meeting("Design review", DS.Palette.Brand.blue), second: blocked ? .busy : .free)
                column("Personal", symbol: "house.fill", tint: DS.Palette.Brand.green,
                       first: blocked ? .busy : .free, second: .meeting("Dentist", DS.Palette.Brand.green))
            }
        }
    }

    private enum Slot {
        case meeting(String, Color), busy, free
    }

    private func column(_ title: String, symbol: String, tint: Color, first: Slot, second: Slot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                IconTile(systemImage: symbol, tint: tint, size: 22)
                Text(title).font(.footnote.weight(.semibold))
            }
            .padding(.bottom, DS.Space.hair)
            slot(first)
            slot(second)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func slot(_ slot: Slot) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
        switch slot {
        case .meeting(let title, let tint):
            block(title, tint: tint)
        case .busy:
            block("Busy", tint: .secondary)
                .transition(.opacity)
        case .free:
            Text("Looks free")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.s)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .overlay(shape.strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
    }

    private func block(_ title: String, tint: Color) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, DS.Space.s)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(tint.opacity(DS.Event.fill))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
    }
}

/// The Google accounts that are in, each ticked, and a dashed row that adds one.
private struct AccountList: View {
    let emails: [String]
    let adding: Bool
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(emails, id: \.self) { email in
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DS.Palette.success)
                        .accessibilityHidden(true)
                    Text(email)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: DS.Row.minHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(email), connected")
            }
            Button(action: add) {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text(emails.count < 2 ? "Work or personal" : "Another account")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: DS.Row.minHeight)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(adding)
            .accessibilityLabel(emails.count < 2 ? "Add your work or personal Google account" : "Add another Google account")
            .accessibilityIdentifier("onboarding.other.add")
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

// MARK: - What Banana looks after

/// What Banana looks after, chosen on the way in: Plan, always on, then each module, then
/// Everything. Rows in the look the read-only list had, so the welcome still reads as a picture
/// of the app; the choice is held by `OnboardingStore`, which outlives the view. (Before 17 Oct
/// 2026 these were said, not asked: four rows to read. Still one path through the first run.)
private struct ModuleChooser: View {
    @Binding var choice: ModuleChoice

    private struct Row {
        let module: AppModule
        let title: String
        let colour: Color
    }

    private let rows = [
        Row(module: .workouts, title: "Track workouts and sleep", colour: AppModule.workouts.tint),
        Row(module: .food, title: "Log your meals", colour: AppModule.food.tint),
        Row(module: .notes, title: "Keep notes", colour: AppModule.notes.tint),
        Row(module: .podcasts, title: "Listen to podcasts", colour: AppModule.podcasts.tint),
        Row(module: .email, title: "Email", colour: AppModule.email.tint),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            // Plan is the app: shown ticked, not a choice.
            line(title: "Plan your day", symbol: AppSection.plan.symbol,
                 colour: DS.Palette.Brand.yellow, glyph: DS.Palette.Brand.ink, on: true, fixed: true)
                .accessibilityElement(children: .combine)
                .accessibilityValue("Always on")
            ForEach(rows.filter { $0.module.isAvailable }, id: \.module) { row in
                let on = choice.includes(row.module)
                Button {
                    choice = choice.setting(row.module, on: !on)
                } label: {
                    line(title: row.module.statusLabel.map { "\(row.title) · \($0)" } ?? row.title,
                         symbol: row.module.symbol, colour: row.colour, on: on)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .disabled(!row.module.isAvailable)
                .accessibilityIdentifier("onboarding.module.\(row.module.rawValue)")
            }
            Button {
                choice = choice.isEverything ? .planOnly : .everything
            } label: {
                line(title: "Everything", symbol: "square.grid.2x2.fill",
                     colour: DS.Palette.Brand.ink, glyph: DS.Palette.Brand.yellow, on: choice.isEverything)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(choice.isEverything ? .isSelected : [])
            .accessibilityIdentifier("onboarding.module.everything")
        }
        .padding(.top, DS.Space.xs)
    }

    private func line(title: String, symbol: String, colour: Color, glyph: Color? = nil,
                      on: Bool, fixed: Bool = false) -> some View {
        HStack(spacing: DS.Space.l) {
            IconTile(systemImage: symbol, tint: colour, size: DS.Row.glyphTile, glyph: glyph)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(on ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(.secondary))
                .opacity(fixed ? 0.6 : 1)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - The calendar's explanation

/// Why connect a Google calendar: a small day as the opener, a title, and three reasons of a
/// few words each. No paragraph and no small print: the day says what the paragraph did, and
/// which calendars keep each other busy is the next sheet's to say. The first run's second
/// step, and what the setup list shows for its Google Calendar row.
struct CalendarPrimer: View {
    var body: some View {
        DayPreview()
        Text("Start with your calendar")
            .font(.title.bold())
            .pageTitle()
            .accessibilityAddTraits(.isHeader)
        // The tiles take the colours of the day above them.
        ReasonCard(reasons: [
            Reason(symbol: "calendar.day.timeline.left", text: "Your meetings on one timeline",
                   tint: DS.Palette.Brand.blue),
            Reason(symbol: "calendar.badge.plus", text: "Changes here save to Google",
                   tint: DS.Palette.Brand.green),
            Reason(symbol: "lock.fill", text: "No Banana server in between",
                   tint: DS.Palette.Brand.purple),
        ])
    }
}

/// A few hours of a plan, drawn with the plan's own blocks: the thing being offered, where a
/// calendar symbol in a circle used to be.
private struct DayPreview: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let hour: String
        let title: String
        let time: String
        let tint: Color
        var tall = false
    }

    private let entries = [
        Entry(hour: "9", title: "Team standup", time: "9\u{2013}9:30 AM", tint: DS.Palette.Brand.blue),
        Entry(hour: "10", title: "Design review", time: "10\u{2013}11:30 AM", tint: DS.Palette.Brand.purple, tall: true),
        Entry(hour: "12", title: "Lunch with Sam", time: "12:30\u{2013}1:15 PM", tint: DS.Palette.Brand.green),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "circle")
                    .foregroundStyle(DS.Palette.task)
                Text("Send the proposal")
                    .font(.footnote.weight(.medium))
                Text("due today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 30 + DS.Space.s)
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Text(entry.hour)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.footnote.weight(.semibold))
                            Text(entry.time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, DS.Space.xs + 2)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: entry.tall ? 50 : 38, alignment: .top)
                    .background(entry.tint.opacity(DS.Event.fill))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
                }
            }
        }
        // Kept short: under the title bar of the setup list's sheet, the page still fits a phone
        // with its note in view.
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A sample day: a reminder due today, Team standup at 9, Design review at 10, Lunch with Sam at 12:30.")
    }
}
