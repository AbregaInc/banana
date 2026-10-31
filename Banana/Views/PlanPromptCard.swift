import SwiftUI

/// The one thing the plan may ask for, above the day (`PlanPrompt`).
///
/// These lived on the retired Today screen and nowhere else, so on a phone the plan had no
/// "not connected" state at all: a skipped or expired Google account showed only in Settings,
/// and the setup onboarding promised "from Today" had no screen to be on.
struct PlanPromptCard: View {
    @EnvironmentObject private var smart: SmartScheduleStore
    @EnvironmentObject private var occurrences: OccurrenceStore
    @ObservedObject private var google = GoogleCalendarService.shared
    @ObservedObject private var writeBack = CalendarWriteBack.shared
    @State private var connectingCalendar = false
    @State private var choosingCalendars = false
    @State private var asking = false
    // "Not now" on a card sends its question to the setup list (or Settings) for good. The keys
    // have no dots: a dotted @AppStorage key on a plan view once redrew it several times a second.
    @AppStorage("planBusyCalendarsLater") private var busyLater = false
    @AppStorage("planNotificationsLater") private var notificationsLater = false
    @AppStorage("planRemindersLater") private var remindersLater = false
    #if os(iOS)
    private var setup = SetupAccess()
    @ObservedObject private var setupPresenter = SetupPresenter.shared
    #endif

    var body: some View {
        // Always a container, even when there is nothing to show: it is what the setup list
        // is presented from, and the plan's menu opens that with the line hidden.
        VStack(spacing: 0) {
            switch PlanPrompt.current(calendarConnected: smart.calendarAuthorized,
                                      hasPlaceQuestion: PlaceQuestionCard.hasQuestion(smart), open: open) {
            case .connectCalendar:
                calendarAccessCard.padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            case .placeQuestion:
                PlaceQuestionCard().padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            case .busyCalendars:
                askCard(symbol: "arrow.triangle.2.circlepath", tint: DS.Palette.Brand.purple,
                        title: "Block my busy time", verb: "Choose", id: "plan.busy",
                        action: { choosingCalendars = true }, later: { busyLater = true })
            case .notifications:
                #if os(iOS)
                notificationsCard
                #else
                EmptyView()
                #endif
            case .reminders:
                #if os(iOS)
                askCard(symbol: "checklist", tint: DS.Palette.task,
                        title: "Your reminders, here", verb: "Show", id: "plan.reminders",
                        action: { ask(.reminders) }, later: { remindersLater = true })
                #else
                EmptyView()
                #endif
            case .finishSetup:
                #if os(iOS)
                // Draws nothing once everything has been asked for or it has been put away.
                SetupLine().padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                #else
                EmptyView()   // the permissions it lists are the phone's
                #endif
            }
        }
        #if os(iOS)
        .sheet(isPresented: $setupPresenter.isShowing) { SetupSheet() }
        .task { await setup.refresh() }   // what has been asked before, before any card asks
        #endif
        // Which calendars keep each other busy: opened from its card, never by itself.
        .sheet(isPresented: $choosingCalendars) {
            WriteBackCalendarSetupSheet { choosingCalendars = false }
        }
    }

    // MARK: - What a connected calendar makes worth asking

    /// What is still open to ask from here. Each ask shows when its reason is on the screen: the
    /// calendars once there are some, alerts while there is a meeting ahead to show one for.
    private var open: PlanPrompt.Open {
        var open = PlanPrompt.Open()
        open.busyCalendars = !busyLater
            && (writeBack.needsAnswer || (Self.previewsBusyQuestion && !writeBack.questionAnswered))
        #if os(iOS)
        open.notifications = !notificationsLater && setup.neverAsked(.notifications)
            && occurrences.nextAlertSample != nil
        open.reminders = !remindersLater && setup.neverAsked(.reminders)
        #endif
        return open
    }

    /// A simulator has no Google account to connect, so the walk shows the card this way.
    private static var previewsBusyQuestion: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--busy-question-preview")
        #else
        false
        #endif
    }

    /// One line and one action, with a way to put it off: the form every ask from the plan takes.
    private func askCard(symbol: String, tint: Color, glyph: Color? = nil, title: String, verb: String, id: String,
                         action: @escaping () -> Void, later: @escaping () -> Void) -> some View {
        PromptCard(symbol: symbol, tint: tint, glyph: glyph, title: title, id: id, onDismiss: later) {
            Button(verb, action: action)
                .buttonStyle(.primary)
                .disabled(asking)
                .accessibilityIdentifier("\(id).allow")
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }

    #if os(iOS)
    /// The ask to send alerts, opened by the alert itself: the person's next meeting, in the
    /// words Banana would send.
    private var notificationsCard: some View {
        VStack(spacing: 0) {
            if let sample = occurrences.nextAlertSample {
                NotificationPreview(title: sample.title, message: sample.body)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.top, DS.Space.s)
            }
            askCard(symbol: "bell.badge.fill", tint: DS.Palette.accent, glyph: DS.Palette.onAccent,
                    title: "Alerts like this", verb: "Turn on", id: "plan.notifications",
                    action: { ask(.notifications) }, later: { notificationsLater = true })
        }
    }

    /// Show the system's question, asked for by the card's own button.
    private func ask(_ item: SetupItem) {
        guard !asking else { return }
        asking = true
        Task {
            await setup.ask(for: item)
            asking = false
        }
    }
    #endif

    private var calendarAccessCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.m) {
                IconTile(systemImage: "calendar", tint: DS.Palette.accent, style: .soft, size: DS.Row.glyphTile)
                // The name and the action, like any row for a service that isn't connected. It
                // read "Calendar isn't connected" over a sentence saying why to; beside the
                // button that wrapped to two lines, and the button says the rest.
                Text("Google Calendar")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                Button {
                    connect()
                } label: {
                    if connectingCalendar {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.primary)
                .disabled(connectingCalendar)
                .accessibilityLabel(connectingCalendar ? "Connecting" : "Connect Google Calendar")
                .accessibilityIdentifier("plan.calendar.connect")
            }
            // A sign-in that failed says why. It said nothing: the button went back to "Connect".
            if let problem = google.lastError, !connectingCalendar {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Space.s)
                    .accessibilityIdentifier("plan.calendar.problem")
            }
            #if os(iOS)
            // The rest of setup, which this card stands in the place of: without a calendar
            // there was no way to it from the plan at all.
            if setup.checklist.hasTodoBesidesCalendar {
                Divider().padding(.top, DS.Space.m)
                Button { setupPresenter.isShowing = true } label: {
                    HStack {
                        Text("Set up the rest").font(.footnote.weight(.medium))
                        Spacer(minLength: DS.Space.s)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: DS.Row.minHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("plan.setup.rest")
            }
            #endif
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.m)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.accent.opacity(DS.Tint.subtle),
                    in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
    }

    /// The footer row brings its own height; without it the card needs its bottom padding back.
    private var bottomInset: CGFloat {
        #if os(iOS)
        setup.checklist.hasTodoBesidesCalendar ? 0 : DS.Space.m
        #else
        DS.Space.m
        #endif
    }

    private func connect() {
        Task {
            connectingCalendar = true
            await smart.requestCalendarAccess()
            connectingCalendar = false
            // The day fills in. Which calendars keep each other busy is asked by its own card.
            if smart.calendarAuthorized { await occurrences.recompute() }
        }
    }
}


/// Every prompt above the plan, and every offer, in one shape: icon tile · one line · its
/// button(s) · ×. The host pads it.
struct PromptCard<Actions: View>: View {
    var symbol: String
    var tint: Color = DS.Palette.accent
    var glyph: Color? = nil
    var title: String
    var id: String
    /// Boxed in an accent wash; bare as a List row, which its host tints instead.
    var boxed = true
    var dismissLabel = "Not now"
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        let row = HStack(spacing: DS.Space.m) {
            IconTile(systemImage: symbol, tint: tint, glyph: glyph)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(-1)
            Spacer(minLength: DS.Space.s)
            // The buttons keep their words on one line; the title wraps instead.
            HStack(spacing: DS.Space.s) { actions() }
                .lineLimit(1)
                .fixedSize()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.Row.minHeight, height: DS.Row.minHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dismissLabel)
                .accessibilityIdentifier("\(id).later")
            }
        }
        .padding(.vertical, DS.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        if boxed {
            row
                .padding(.leading, DS.Space.l)
                .padding(.trailing, onDismiss == nil ? DS.Space.l : 0)
                .frame(minHeight: DS.Row.minHeight)
                .background(DS.Palette.accent.opacity(DS.Tint.subtle),
                            in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        } else {
            row
        }
    }
}
