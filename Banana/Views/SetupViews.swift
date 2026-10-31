#if os(iOS)
import SwiftUI
import UIKit

// The setup list on a phone and an iPad: one line above the plan (`SetupLine`), the list it opens
// (`SetupSheet`), and one page of explanation per item before the system is asked
// (`SetupPrimerPage`). The rules are `SetupChecklist`'s.
//
// It replaced `FinishSetupCard`: three rows at most, finished ones removed, no card at all until
// a calendar was connected, small "Connect" buttons that went straight to the system's prompt,
// and a "Not now" that hid it for good (review of 9 Oct 2026).

/// Opens the setup list from anywhere: the line, the calendar card's footer, the plan's menu.
@MainActor
final class SetupPresenter: ObservableObject {
    static let shared = SetupPresenter()
    @Published var isShowing = false
}

/// Where each item stands, read from the stores that know, and the asking.
@MainActor
struct SetupAccess: DynamicProperty {
    @EnvironmentObject private var alarms: AlarmStore
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var music: MusicController
    @EnvironmentObject private var onboarding: OnboardingStore
    @ObservedObject private var occurrences = OccurrenceStore.shared
    @ObservedObject private var google = GoogleCalendarService.shared
    @ObservedObject private var location = LocationAccess.shared
    @ObservedObject private var modules = ModuleStore.shared

    var checklist: SetupChecklist {
        SetupChecklist(items: SetupItem.list(isHub: DeviceRole.current.isHub, modules: modules.choice)) { state(of: $0) }
    }

    func state(of item: SetupItem) -> SetupState {
        switch item {
        case .calendar:
            return google.isConnected ? .done : .todo
        case .reminders:
            return onboarding.remindersState(authorized: occurrences.remindersAuthorized)
        case .alarms:
            if alarms.isAuthorized { return .done }
            return alarms.authorization == .denied ? .refused : .todo
        case .notifications:
            if onboarding.notificationsGranted { return .done }
            return onboarding.notificationsDenied ? .refused : .todo
        case .location:
            switch location.standing {
            case .allowed: return .done
            case .refused: return .refused
            case .notAsked, .unknown: return .todo
            }
        case .health:
            return health.setupState
        case .music:
            if music.isAuthorized { return .done }
            return [.denied, .restricted].contains(music.authorization) ? .refused : .todo
        }
    }

    /// Whether the system has never been asked about `item`, for a card on the plan that asks.
    /// Stricter than `.todo`: that is also what a status not yet read looks like.
    func neverAsked(_ item: SetupItem) -> Bool {
        switch item {
        case .notifications: onboarding.notificationsNeverAsked
        case .reminders: state(of: .reminders) == .todo
        default: state(of: item) == .todo
        }
    }

    func refresh() async { await onboarding.refresh() }

    /// Show the system's question for `item`. The calendar is Google's sign-in, and reports
    /// whether it connected; the others are answered on the system's own prompt.
    @discardableResult
    func ask(for item: SetupItem) async -> Bool {
        switch item {
        case .calendar: _ = await onboarding.requestCalendar()
        case .reminders:
            // The answer shows on the page at once. Putting the reminders on the plan takes
            // longer, and a refusal used to wait behind it before the page said "Open Settings".
            _ = await onboarding.requestReminders()
            _ = await occurrences.requestRemindersAccess()
        case .alarms: await alarms.requestAuthorization()
        case .notifications: _ = await onboarding.requestNotifications()
        case .location:
            location.ask()
            // The answer arrives by itself, usually. While the prompt may be up, look again
            // every half second (off the main thread) so the page never sits on "Asking…".
            for _ in 0..<120 where location.standing == .notAsked || location.standing == .unknown {
                try? await Task.sleep(for: .milliseconds(500))
                location.recheck()
            }
        case .health: await health.connect()
        case .music: await music.requestAuthorization()
        }
        // An answer already in doesn't wait for the rest (the notification daemon, Google's
        // credentials): the page that asked would sit on "Set up" until they had been read.
        if state(of: item) == .done {
            Task { await onboarding.refresh() }
            return true
        }
        await onboarding.refresh()
        return state(of: item) == .done
    }

    var calendarProblem: String? { onboarding.calendarErrorMessage }
}

// MARK: - What each item says

extension SetupItem {
    var title: String {
        switch self {
        case .calendar: "Google Calendar"
        case .reminders: "Reminders"
        case .alarms: "Alarms"
        case .notifications: "Notifications"
        case .location: "Location"
        case .health: "Apple Health"
        case .music: "Apple Music"
        }
    }

    /// What the row is for, as VoiceOver's hint. Not shown: the list is names, like Settings.
    var line: String {
        switch self {
        case .calendar: "Meetings and free time on your plan"
        case .reminders: "Your reminders beside your meetings"
        case .alarms: "Wake-ups that ring through Silent Mode"
        case .notifications: "When to leave, and what is due"
        case .location: "Local weather and when to leave"
        case .health: "Workouts, sleep and recovery"
        case .music: "Your own music in a routine"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .alarms: "alarm.fill"
        case .notifications: "bell.badge.fill"
        case .location: "location.fill"
        case .health: "heart.fill"
        case .music: "music.note"
        }
    }

    var tint: Color {
        switch self {
        case .calendar: DS.Palette.Feature.calendar
        case .reminders: DS.Palette.task
        case .alarms: DS.Palette.Feature.wake
        case .notifications: DS.Palette.accent
        case .location: DS.Palette.travel
        case .health: .pink
        case .music: DS.Palette.Feature.podcasts
        }
    }

    /// The glyph on a solid tile of the accent: the same as on the page's main button.
    var glyphOnTint: Color? {
        self == .notifications ? DS.Palette.onAccent : nil
    }

    /// The explanation page's title.
    var headline: String {
        switch self {
        case .calendar: "Start with your calendar"
        case .reminders: "Put your reminders on the plan"
        case .alarms: "Let Banana wake you"
        case .notifications: "A nudge at the right moment"
        case .location: "Weather and travel for where you are"
        case .health: "Bring in your workouts and sleep"
        case .music: "Start a routine with your music"
        }
    }

    /// Two or three reasons, a few words each. They are all the page says besides its title:
    /// a paragraph above them and small print below were cut ("less is more", 9 Oct 2026).
    var reasons: [(symbol: String, text: String)] {
        switch self {
        case .calendar: []   // `CalendarPrimer` has its own
        case .reminders: [
            ("checklist", "Due reminders on your day"),
            ("checkmark.circle.fill", "Tick one here, done in Reminders"),
        ]
        case .alarms: [
            ("alarm.fill", "Rings through Silent Mode"),
            ("calendar.badge.clock", "Timed to your first meeting"),
            ("iphone", "Works with Banana closed"),
        ]
        case .notifications: [
            ("figure.walk.departure", "When to leave for a meeting"),
            ("pills.fill", "A supplement or reminder that\u{2019}s due"),
            ("moon.fill", "Time to wind down"),
        ]
        case .location: [
            ("cloud.sun.fill", "Today\u{2019}s forecast"),
            ("car.fill", "Travel time, and when to leave"),
            ("hand.raised.fill", "Only while you use Banana"),
        ]
        case .health: [
            ("figure.run", "Workouts, routes and heart rate"),
            ("bed.double.fill", "Sleep and wake-ups"),
            ("applewatch", "Watch workouts saved to Health"),
        ]
        case .music: [
            ("music.note.list", "Pick from your Apple Music library"),
            ("sunrise.fill", "Plays as a routine starts"),
        ]
        }
    }

    /// The main button: what pressing it does.
    var verb: String {
        switch self {
        case .calendar: "Continue with Google"
        case .reminders: "Connect Reminders"
        case .alarms: "Allow alarms"
        case .notifications: "Turn on notifications"
        case .location: "Allow location"
        case .health: "Connect Apple Health"
        case .music: "Connect Apple Music"
        }
    }

    /// Why the button now reads "Open Settings", and what to do there.
    var settingsDirections: String {
        "Turn on \(title) in Settings."
    }
}

/// A Banana notification as it arrives, to open the page that asks to send them: the real thing
/// in place of a bell on a tile. The words are a leave-by nudge's own
/// (`NotificationService.scheduleLeaveByAlerts`) unless the person's next meeting is handed in.
struct NotificationPreview: View {
    var title = "Leave soon"
    var message = "~24 min drive to Design review at 2:00 PM. Leave by 1:36 PM."

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            BrandMark(size: DS.Row.glyphTile)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    Text("now").font(.caption).foregroundStyle(.secondary)
                }
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A sample notification. \(title): \(message)")
    }
}

// MARK: - Progress

/// A ring that fills as items are set up: on the plan's line and at the head of the list.
private struct SetupRing: View {
    let done: Int
    let total: Int
    var size: CGFloat = 26

    var body: some View {
        let width: CGFloat = 3
        ZStack {
            Circle().stroke(Color.primary.opacity(DS.Tint.soft), lineWidth: width)
            Circle()
                .trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.3), value: done)
        .accessibilityHidden(true)
    }
}

// MARK: - The line above the plan

/// One line, since it sits over the day: a ring, "Finish setup", how far along, and a way to
/// put it away. Putting it away hides the line and nothing else: the list stays in the plan's
/// menu, and the toast says so.
struct SetupLine: View {
    private var setup = SetupAccess()
    @ObservedObject private var presenter = SetupPresenter.shared
    @AppStorage("finishSetupDismissed") private var hidden = false

    var body: some View {
        let checklist = setup.checklist
        if checklist.showsLine(hidden: hidden) {
            HStack(spacing: 0) {
                Button { presenter.isShowing = true } label: {
                    HStack(spacing: DS.Space.m) {
                        SetupRing(done: checklist.done, total: checklist.total)
                        // The ring says how far along; VoiceOver gets the count in words.
                        Text("Finish setup").font(.subheadline.weight(.semibold))
                        Spacer(minLength: DS.Space.s)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, DS.Space.m + 2)
                    .frame(minHeight: DS.Row.minHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish setup, \(checklist.summary)")
                .accessibilityIdentifier("plan.setup.open")
                Button {
                    hidden = true
                    ToastCenter.shared.notify("Setup is in the \u{2026} menu")
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.Row.minHeight, height: DS.Row.minHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide setup")
                .accessibilityIdentifier("plan.setup.hide")
            }
            .background(DS.Palette.accent.opacity(DS.Tint.subtle),
                        in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        }
    }
}

/// "Finish setup" in the plan's menu, while anything has never been asked for: the way back
/// after the line was hidden.
struct SetupMenuItem: View {
    private var setup = SetupAccess()

    var body: some View {
        if setup.checklist.showsMenuItem {
            Button { SetupPresenter.shared.isShowing = true } label: {
                Label("Finish setup", systemImage: "checklist.checked")
            }
            .accessibilityIdentifier("mobile.week.setup")
        }
    }
}

// MARK: - The list

struct SetupSheet: View {
    private var setup = SetupAccess()
    @State private var path: [SetupItem] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let checklist = setup.checklist
        NavigationStack(path: $path) {
            List {
                Section {
                    // The ring and the count, once each: the ring had the count inside it as
                    // well, and a sentence under it.
                    HStack(spacing: DS.Space.m) {
                        SetupRing(done: checklist.done, total: checklist.total)
                        Text(checklist.summary).font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                }
                Section {
                    ForEach(checklist.rows) { row in
                        SetupRow(row: row) { path.append(row.item) }
                    }
                }
            }
            .navigationTitle("Set up Banana")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: SetupItem.self) { item in
                SetupPrimerPage(item: item)
            }
        }
        .presentationDetents([.large])
    }
}

/// A row keeps its place whatever its state: a tile, the name, one line, and what it stands at.
private struct SetupRow: View {
    let row: SetupChecklist.Row
    let open: () -> Void

    var body: some View {
        let item = row.item
        Button(action: open) {
            HStack(spacing: DS.Space.m) {
                // A Settings row: the solid tile and the name. What it is for is its own page's to
                // say (and VoiceOver's hint); a grey line under every name was seven more to read.
                IconTile(systemImage: item.symbol, tint: item.tint, glyph: item.glyphOnTint)
                Text(item.title)
                    .foregroundStyle(row.state == .done ? .secondary : .primary)
                Spacer(minLength: DS.Space.s)
                trailing
            }
            .frame(minHeight: DS.Row.minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(word)")
        .accessibilityHint(item.line)
        .accessibilityIdentifier("setup.row.\(item.rawValue)")
    }

    private var word: String {
        switch row.state {
        case .todo: "not set up"
        case .done: "set up"
        case .refused: "off"
        case .asked: "asked"
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(DS.Palette.success)
        case .todo:
            chevron
        case .refused:
            HStack(spacing: DS.Space.xs) { Text("Off").font(.subheadline).foregroundStyle(.secondary); chevron }
        case .asked:
            HStack(spacing: DS.Space.xs) { Text("Asked").font(.subheadline).foregroundStyle(.secondary); chevron }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - One item's page

/// The page before the system is asked (DESIGN-SYSTEM.md, "Permissions"): what it is for, two
/// or three reasons, what happens to the data, one button that says what it does, "Not now"
/// under it. Once the system has said no, the button opens Settings instead.
struct SetupPrimerPage: View {
    let item: SetupItem
    private var setup = SetupAccess()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var working = false
    @State private var choosingCalendars = false
    @State private var celebrated = 0

    init(item: SetupItem) { self.item = item }

    var body: some View {
        let state = setup.state(of: item)
        OnePage {
            if item == .calendar {
                CalendarPrimer()
            } else {
                if item == .notifications {
                    NotificationPreview()
                        .padding(.top, DS.Space.s)
                } else {
                    IconTile(systemImage: item.symbol, tint: item.tint, size: DS.Page.heroTile, glyph: item.glyphOnTint)
                        .padding(.top, DS.Space.s)
                        .frame(maxWidth: .infinity)
                }
                Text(item.headline)
                    .font(.title2.bold())
                    .pageTitle()
                    .accessibilityAddTraits(.isHeader)
                ReasonCard(reasons: item.reasons.map {
                    Reason(symbol: $0.symbol, text: $0.text, tint: item.tint, glyph: item.glyphOnTint)
                })
            }
        } actions: {
            actions(for: state)
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: celebrated)
        .sheet(isPresented: $choosingCalendars) {
            WriteBackCalendarSetupSheet {
                choosingCalendars = false
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func actions(for state: SetupState) -> some View {
        switch state {
        case .todo:
            if item == .calendar, let problem = setup.calendarProblem {
                note(problem, colour: DS.Palette.danger)
            }
            if item == .calendar {
                GoogleButton(working: working) { ask() }
            } else {
                Button(working ? "Asking\u{2026}" : item.verb) { ask() }
                    .buttonStyle(.primaryCapsule)
                    .disabled(working)
                    .accessibilityIdentifier("setup.primer.allow")
            }
            Button("Not now") { dismiss() }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("setup.primer.notNow")
        case .refused:
            note(item.settingsDirections)
            Button("Open Settings") {
                if let url = URL(string: item == .notifications ? UIApplication.openNotificationSettingsURLString
                                                               : UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.primaryCapsule)
            .accessibilityIdentifier("setup.primer.settings")
        case .asked:
            // Health won't say what was answered, so the row can't be ticked: where to look.
            note("In Health: your picture, Apps, Banana.")
            Button("Open Health") {
                if let url = URL(string: "x-apple-health://") { openURL(url) }
            }
            .buttonStyle(.primaryCapsule)
            .accessibilityIdentifier("setup.primer.health")
        case .done:
            Label("Set up", systemImage: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(DS.Palette.success)
                .frame(minHeight: DS.Page.buttonHeight)
            if item == .calendar {
                // Where the busy-block question lives once the plan's card has been put off.
                Button("Busy calendars") { choosingCalendars = true }
                    .buttonStyle(.quiet)
                    .accessibilityIdentifier("setup.primer.busy")
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.quiet)
            }
        }
    }

    private func note(_ text: String, colour: Color = .secondary) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(colour)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, DS.Space.xs)
    }

    private func ask() {
        guard !working else { return }
        working = true
        Task {
            let done = await setup.ask(for: item)
            working = false
            guard done else { return }   // refused or closed: the page now says what to do
            celebrated += 1
            if item == .calendar {
                choosingCalendars = true   // which calendars keep each other busy
            } else {
                dismiss()
            }
        }
    }
}
#endif
