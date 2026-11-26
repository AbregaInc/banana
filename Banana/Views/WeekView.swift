import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Loading a planning window changes its status indicator independently of the calendar grid.
@MainActor
private final class CalendarPageLoading: ObservableObject {
    @Published private(set) var active = false

    func set(_ value: Bool) {
        if active != value { active = value }
    }
}

private struct CalendarRefreshStatus<Content: View>: View {
    @ObservedObject var loading: CalendarPageLoading
    @ViewBuilder var content: (Bool) -> Content

    var body: some View { content(loading.active) }
}

/// A bounded local snapshot for the first body evaluation, before onAppear takes ownership.
@MainActor
private final class CalendarMountSnapshot<Value> {
    private var value: Value?

    func resolve(_ prepare: () -> Value) -> Value {
        if let value { return value }
        let prepared = prepare()
        value = prepared
        return prepared
    }

    func clear() { value = nil }
}

/// The label shown on a tap/drag-to-create draft rectangle. A rectangle alone doesn't say what
/// it will create; the range does — this is what makes the gesture's result unmistakable once
/// it takes over, on both the Mac click-drag grid and the mobile long-press-then-drag one.
enum GridDraftSelection {
    static func rangeLabel(start: Date, durationMinutes: Int, calendar: Calendar = .current) -> String {
        let end = calendar.date(byAdding: .minute, value: durationMinutes, to: start)
            ?? start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return "\(start.formatted(.dateTime.hour().minute())) – \(end.formatted(.dateTime.hour().minute()))"
    }
}

/// The slice of an occurrence that belongs to one day's column.
///
/// A calendar grid draws a day, not an event: an entry that runs past midnight is a band from its
/// start to the bottom of this column and a fresh band on the next one. `gridY` always understood
/// that — it clamps the top edge to 0…86,400s — but the block's HEIGHT was taken from the raw
/// `resolvedEnd`, so the two disagreed for anything crossing midnight. A five-day car hire asked
/// for 120 × 58pt = 6,958pt of block inside a 1,392pt day: it covered its own column from 17:00
/// downwards and every row under it, which is why a full day could look like one giant item and
/// nothing else.
/// Whether a routine moment with no time is shown above the hours now (`UntimedMoments`): it
/// leaves once it's done, whether marked done or, for a workout routine, once a workout has been
/// recorded that day.
@MainActor
func untimedMomentIsDue(_ occurrence: Occurrence, routines: [Routine], signals: CalendarSignals,
                        now: Date = Date()) -> Bool {
    guard occurrence.isUntimedCue else { return false }
    let followsWorkout = routines.first { $0.id == occurrence.routineID }?.triggerKind == .workoutStart
    return UntimedMoments.shows(start: occurrence.start, completed: occurrence.completed,
                                skipped: occurrence.skipped,
                                workedOut: followsWorkout && signals.didWorkout(on: occurrence.start), now: now)
}

enum DayColumn {
    static func visibleInterval(of occurrence: Occurrence,
                                on day: Date,
                                calendar: Calendar = .current) -> DateInterval {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let start = min(max(occurrence.start, dayStart), dayEnd)
        let end = max(min(occurrence.resolvedEnd, dayEnd), start)
        return DateInterval(start: start, end: end)
    }

    static func occurrences(_ occurrences: [Occurrence],
                            on day: Date,
                            calendar: Calendar = .current) -> [Occurrence] {
        let range = CalendarDayRange(day: day, calendar: calendar)
        return occurrences.filter {
            range.contains(start: $0.start, end: $0.resolvedEnd, timed: $0.hasScheduledTime)
        }
    }
}

/// Pure interval partitioning shared by the Mac and iOS calendar grids. EventKit can retain
/// sub-minute seconds while our UI labels only minutes, so intervals whose displayed boundaries
/// touch (within one minute) stay full width instead of looking spuriously simultaneous.
enum CalendarLaneAllocator {
    struct Placement: Equatable, Identifiable {
        var id: String { occurrence.id }
        let occurrence: Occurrence
        let lane: Int
        let laneCount: Int
        var laneSpan: Int = 1
    }

    static func placements(_ occurrences: [Occurrence]) -> [Placement] {
        let plan = CalendarLanePlan.make(occurrences.map {
            .init(id: $0.id, start: $0.start, end: $0.resolvedEnd)
        })
        return plan.map {
            Placement(occurrence: occurrences[$0.index], lane: $0.lane, laneCount: $0.laneCount, laneSpan: $0.laneSpan)
        }
    }

}

private struct Stripes: View {
    let color: Color
    var spacing: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            // 45°, so the lines run from bottom-left to top-right across whatever box they land
            // in. Drawn from -height so the leading edge is covered at every band height.
            var x = -size.height
            let path = Path { p in
                while x < size.width + size.height {
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += spacing
                }
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        .drawingGroup()   // one rasterised layer per band rather than per-line compositing
        .accessibilityHidden(true)
    }
}

/// A day blocked all day: a wash of the blocking event's calendar colour with its hatch over it,
/// deep enough to read as "taken" at a glance, under whatever else is on the day. Shared by the
/// Mac and iOS grids.
private struct BlockedDayFill: View {
    let color: Color

    var body: some View {
        ZStack {
            color.opacity(DS.Tint.fill)
            Stripes(color: color.opacity(DS.Tint.strong), spacing: 8)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// Set on a day blocked all day (`BlockedDayFill`): the solid card what's on that day sits
    /// on. Block fills are translucent, so without it the hatch showed through every block and
    /// read as drawn over them. Nil on every other day, which therefore draw as they always have.
    @Entry var blockedDayBase: Color? = nil
}

private struct BlockedDayBase: ViewModifier {
    @Environment(\.blockedDayBase) private var base
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if let base {
            content.background(base, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}

private extension View {
    /// Under everything a block draws, so a faded (done, skipped) block fades onto the card too.
    func blockedDayBase(cornerRadius: CGFloat) -> some View {
        modifier(BlockedDayBase(cornerRadius: cornerRadius))
    }
}

/// A flat band, drawn deliberately unlike an event: this is time consumed, not an
/// appointment. Shared by the Mac and iOS week grids, and by both directions of a trip.
///
/// Travel is always `DS.Palette.travel`; the icon is the MODE (walk, transit, drive), never a
/// colour, so the two directions read as one trip. With room it says how long and where —
/// "24 min · Chelsea Piers" — and a place that is only a guess ends in "?", so a trip timed to
/// the wrong Chelsea is visible on the grid instead of quietly wrong.
private struct TravelBand: View {
    let minutes: Int
    let height: CGFloat
    var detail: TravelLegDetail? = nil
    var isReturn = false

    private var icon: String { detail?.mode.systemImage ?? (isReturn ? "house" : "figure.walk.motion") }
    private var text: String {
        if let detail { return isReturn ? "\(detail.minutes) min home" : detail.summary }
        return "\(minutes) min"
    }
    private var tint: Color { DS.Palette.travel }

    /// "15 min": what a band too short for the place still says beside its mode. A band with
    /// only a glyph read as broken drawing, and its length could not be checked.
    private var minutesText: String {
        "\(detail?.minutes ?? minutes) min"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(DS.Typeface.small(.semibold))
            if height >= 22 {
                Text(text)
                    .font(DS.Typeface.small(.medium).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if height >= DS.Typeface.minimumSize + 2 {
                Text(minutesText)
                    .font(DS.Typeface.small(.medium).monospacedDigit())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: height >= 22 ? .leading : .center)
        // A flat wash, never hatching: stripes mean "tentative" on the grid.
        .background(tint.opacity(DS.Tint.subtle), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .blockedDayBase(cornerRadius: 3)
        .allowsHitTesting(false)
        .accessibilityLabel(isReturn ? "Travel home, \(text)" : "Travel, \(text)")
    }
}

/// A drag that landed on a repeating event and is waiting on this-one-vs-all-future.
/// An event's colour comes from the calendar it lives in. Shared by both week grids.
/// The hour the phone's grids open around: the one it is, or a fixed morning hour in a marketing
/// capture, so the same day is framed the same way at any hour of the run (the Mac's grid has
/// done this for every `--ui-audit` launch).
enum GridOpeningHour {
    static var current: Int {
        #if DEBUG
        if SmartScheduleStore.isStoreCapture { return 9 }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--calendar-opening-hour"), args.indices.contains(index + 1),
           let hour = Int(args[index + 1]), (0...23).contains(hour) { return hour }
        #endif
        return Calendar.current.component(.hour, from: Date())
    }
}

func sourceCalendarColor(_ occ: Occurrence, colors: [String: String]) -> Color? {
    guard occ.behavior == .event || occ.behavior == .allDay,
          let id = occ.meeting?.calendarID,
          let hex = colors[id] else { return nil }
    return calendarTint(hex)
}

/// A delete waiting on confirmation. Deleting is irreversible and a right-click is easy to
/// hit by accident, so it always asks — and a repeating event has to say which it means.
/// The items a column ran out of lanes for, shown in a popover so they stay reachable.
struct OverflowCluster: Identifiable {
    let start: Date
    /// How many did not fit — what the chip reads. `items` is everything at this time.
    let hidden: Int
    let items: [Occurrence]
    var id: Date { start }
}

struct PendingEventDelete: Identifiable {
    let meeting: MeetingInfo
    let recurring: Bool
    var id: String { meeting.id }
}

struct PendingEventMove: Identifiable {
    let meeting: MeetingInfo
    let occurrenceID: String
    let newStart: Date
    var id: String { "\(meeting.id)-\(newStart.timeIntervalSince1970)" }
}

#if os(macOS)
/// A desktop week is a spatial planning surface, not seven phone agenda sections stacked in a
/// scroll view. Keep all seven days visible, put time on one shared vertical axis, and use the
/// same occurrence actions/write-back sheets as the rest of the app.
/// Diagonal hatching for the travel bands on the week grid. A flat fill would read as another
/// event; hatching is the long-standing convention for "this time is consumed, but it isn't an
/// appointment" — and unlike a text label it still reads at six points tall.

struct MacWeekView: View {
    private let calendarScope = ShellCalendarScope.shared
    /// Whether the toolbar offers the booking link.
    @ObservedObject private var booking = BookingCenter.shared
    /// Match iPhone Day: observe only the two calendar publishers below, not every transient
    /// occurrence-store publication while the native scroll view is moving.
    private var occurrences: OccurrenceStore { .shared }
    @EnvironmentObject private var routines: RoutineStore
    @Environment(\.weekSmartStore) private var installedSmartStore
    private var smart: SmartScheduleStore {
        guard let store = installedSmartStore.store else {
            preconditionFailure("MacWeekView requires the installed SmartScheduleStore")
        }
        return store
    }

    @AppStorage("macWeekSpan") private var weekSpan: MacWeekSpan = .sevenDays
    /// Day and Week deliberately share one spatial calendar implementation. Keeping the Day view
    /// as a separate agenda made the two controls look like unrelated parts of the app.
    private let dayMode: Bool

    init(dayMode: Bool = false) {
        self.dayMode = dayMode
    }

    private var visibleDayCount: Int { dayMode ? 1 : weekSpan.rawValue }

    @State private var mountedDays: [MacWeekDay]?
    @State private var mountSnapshot = CalendarMountSnapshot<[MacWeekDay]>()
    private var days: [MacWeekDay] {
        mountedDays ?? mountSnapshot.resolve { makeDays(occurrences.occurrences) }
    }
    private typealias TimedLayout = (placements: [MacWeekPlacement], overflow: [OverflowCluster])
    @State private var preparedTimedLayouts: [Date: TimedLayout] = [:]
    private static let reuseTimedLayouts: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-cache-layout")
            && !ProcessInfo.processInfo.arguments.contains("--calendar-recompute-layout")
        #else
        false
        #endif
    }()

    @State private var visibleSmartRevision = 0
    @State private var showSettings = false
    @State private var editing: Routine?
    @State private var movingOccurrence: Occurrence?
    /// A routine moment opened for itself: its time, why it's there, skip, move, add another —
    /// the sheet the phone opens. (A click used to open the whole routine's settings.)
    @State private var inspectingCue: Occurrence?
    @State private var addingExtraFor: Routine?
    /// What to open once the sheet on screen has gone: one sheet leading to another, or to a question.
    @State private var afterSheet: (() -> Void)?
    /// A new event Google didn't take, being asked about: try again, discard, keep for later.
    @State private var failedWriteToResolve: UUID?
    /// Not observed: the calendar only cancels alarms (see AlarmStoreReference).
    @Environment(\.alarmStore) private var alarmsRef
    /// Live drag-to-move: which block is being dragged, and by how far vertically. The commit
    /// happens on release, so an abandoned drag costs nothing.
    @State private var draggingEventID: String?
    @State private var dragOffsetY: CGFloat = 0
    @State private var dragDayShift: Int = 0
    @State private var pendingRecurringMove: PendingEventMove?
    @State private var moveError: String?
    /// Where a just-moved event should be drawn until the store catches up, and whether the
    /// write is still in flight. Without this the block snapped back to its old time the instant
    /// the finger lifted and jumped forward again a moment later — the move looked rejected.
    @State private var optimisticStart: [String: Date] = [:]
    @State private var savingEventIDs: Set<String> = []
    @State private var deletingMeeting: PendingEventDelete?
    /// Every reminder past its time and not done, for today's Reminders row.
    @State private var mountedOverdueReminders: [Occurrence]?
    private var overdueReminders: [Occurrence] {
        mountedOverdueReminders ?? occurrences.occurrences.filter(\.isOverdueReminder)
    }
    /// Whether a workout has happened today: a workout routine's moment is done then.
    @ObservedObject private var signals = CalendarSignals.shared
    /// The Reminders row opened past the rows that fit ("+N more").
    @State private var remindersExpanded = false
    /// The day whose whole "No time" list is open, from its "+N more".
    @State private var untimedOverflowDay: Date?
    /// Only whether anything needs attention, and how much: the chips are their own subview
    /// (`PlanAttentionChips`), so their stores' publishes never rebuild this grid.
    @ObservedObject private var attention = PlanAttention.shared
    @State private var reschedulingTask: Occurrence?
    @State private var editingTask: Occurrence?
    @State private var eventSheet: CalendarEventSheet?
    @State private var newEventRequest: MacNewEventRequest?
    @State private var showingNewTask = false
    /// The slot a right-click on empty grid means. macOS always hovers before it clicks, so the
    /// last hover position is the click position — SwiftUI's contextMenu does not report one.
    @State private var hoverSlot: (day: Date, date: Date)?
    /// Preset time for the New Reminder sheet, when opened from a grid slot.
    @State private var newTaskDue: Date?
    @State private var showingAlarms = false
    @State private var draftSelection: MacGridSelection?
    @State private var weekOffset = 0
    /// Not observed here: only the toolbar status reads it.
    @State private var loading = CalendarPageLoading()
    private static let nativeViewport: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-reference-mac")
        #else
        true
        #endif
    }()
    @State private var nativeInitialOffset: CGFloat?
    @State private var gridScroll = ScrollPosition(idType: Int.self)
    @State private var didSetInitialScroll = false
    @AppStorage("macDayScrollOffset") private var persistedDayScrollOffset: Double = -1
    // Persistence bookkeeping is not presentation state: scrolling must not invalidate the grid.
    @State private var scrollBookkeeping = MacGridScrollBookkeeping()
    #if DEBUG
    @State private var didOpenDebugSheet = false
    #endif

    /// A second column of hours while a trip is in view (see `TripTimeZone`).
    @State private var secondaryZone: TimeZone?
    private static let secondaryGutterWidth: CGFloat = 44
    private var timeGutterWidth: CGFloat { 58 + (secondaryZone == nil ? 0 : Self.secondaryGutterWidth) }
    private let hourHeight: CGFloat = 58
    /// One line: "Mon 21". Was three lines (weekday, big date, "18 scheduled") at 68 pt.
    private let dayHeaderHeight: CGFloat = 30
    /// Two 18 pt chips + 4 pt gaps, and a line more when some day has a "+N more" to show.
    private var allDayHeight: CGFloat {
        let crowded = days.contains { untimedItems($0).count > 2 }
        return crowded ? 64 : 48
    }
    private let reminderRowHeight: CGFloat = 34
    private let maxVisibleReminderRows = 3

    private var gridHeight: CGFloat { hourHeight * 24 }

    var body: some View {
        let _ = RenderStats.note("MacWeekView")
        let _ = visibleSmartRevision

        NavigationStack {
            VStack(spacing: 0) {
                // A trip timed to a guessed place asks here too, as it does on the phone.
                PlanPromptCard()
                if dayMode { ReminderTimingOffers().padding(.vertical, DS.Space.xs) }
                dayHeaders
                if hasReminderRows {
                    Divider()
                    reminderRows
                }
                if hasUntimedItems {
                    Divider()
                    allDayRow
                }
                Divider()
                if Self.nativeViewport {
                    GeometryReader { geometry in
                        let viewportWidth = geometry.size.width
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            CalendarMacCollectionViewport(
                                items: macViewportItems(width: geometry.size.width, now: timeline.date),
                                contentSize: CGSize(width: geometry.size.width, height: gridHeight),
                                background: AnyView(timeGrid(now: timeline.date, includesEvents: false)),
                                initialOffset: nativeInitialOffset ?? openingScrollOffset(),
                                activeID: draggingEventID,
                                onOffset: { scrollBookkeeping.offset = $0.rounded() },
                                onScrollEnd: { persistDayScrollPosition() },
                                slotActions: { nativeSlotActions(at: $0, width: viewportWidth) })
                        }
                    }
                    .accessibilityIdentifier("mac.week.timeGrid")
                } else {
                ScrollView(.vertical) {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        timeGrid(now: timeline.date)
                    }
                }
                .scrollPosition($gridScroll)
                .onScrollGeometryChange(for: CGFloat.self) {
                    max(0, $0.contentOffset.y + $0.contentInsets.top)
                } action: { _, offset in
                    scrollBookkeeping.offset = offset.rounded()
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { persistDayScrollPosition() }
                }
                .background(Color(.systemBackground))
                .accessibilityIdentifier("mac.week.timeGrid")
                }
                #if DEBUG
                if Self.observationAuditEnabled {
                    HStack {
                        Button("Change audit palette") {
                            var colors = smart.calendarColorHex
                            colors["stress-observation-audit"] = colors["stress-observation-audit"] == "FF0000" ? "00FF00" : "FF0000"
                            smart.injectPreviewCalendarColors(colors)
                        }
                        .accessibilityIdentifier("calendar.audit.changePalette")
                        Button("Republish audit palette") {
                            smart.injectPreviewCalendarColors(smart.calendarColorHex)
                        }
                        .accessibilityIdentifier("calendar.audit.repeatPalette")
                        Text(smart.calendarColorHex["stress-observation-audit"] ?? "unset")
                            .accessibilityIdentifier("calendar.audit.palette")
                        Text(String(RenderStats.lifetimeCount("MacWeekView")))
                            .accessibilityIdentifier("calendar.audit.renderCount")
                        Text(CalendarSlotContextMenu.localObservation ? "local" : "parent")
                            .accessibilityIdentifier("calendar.audit.hoverPolicy")
                        Text(CalendarEventDragFeedback.experimentalEnabled ? "local" : "parent")
                            .accessibilityIdentifier("calendar.audit.dragPolicy")
                        Text(CalendarEventAccessibility.enabled ? "grouped" : "children")
                            .accessibilityIdentifier("calendar.audit.eventAccessibilityPolicy")
                        Text(String(persistedDayScrollOffset))
                            .accessibilityIdentifier("calendar.audit.savedDayOffset")
                        if PendingCalendarWriteStore.auditLocalWriteFailureEnabled {
                            Text("Local writes disabled")
                                .accessibilityIdentifier("calendar.audit.localWriteFailure")
                        }
                    }.padding(8)
                }
                #endif
            }
            .background(Color(.systemBackground))
            // Page changes replace hundreds of blocks. Do not animate the entire retained
            // grid for 160 ms on the navigation/input path.
            // The period is the window title, so the content gets its full height: there is no
            // second header row under the toolbar any more.
            .navigationTitle(dateRangeTitle)
            // The dates are the period picker's, in the paging group: the window keeps its title
            // (the Window menu) without a second one in the toolbar.
            .toolbar(removing: .title)
            .macToolbarLeading { plannerPaging }
            .macToolbarStatus { plannerStatus }
            .macToolbarActions { plannerActions }
            .sheet(item: $editing) { RoutineEditorView(draft: $0, isNew: false) }
            .sheet(item: $eventSheet) {
                CalendarEventSheetView(sheet: $0) {
                    Task {
                        await smart.refreshAgenda()
                        await occurrences.recompute()
                    }
                }
            }
            .confirmationDialog(
                deletingMeeting.map { "Delete “\($0.meeting.title)”?" } ?? "Delete event?",
                isPresented: Binding(get: { deletingMeeting != nil },
                                     set: { if !$0 { deletingMeeting = nil } }),
                titleVisibility: .visible
            ) {
                if deletingMeeting?.recurring == true {
                    Button("Delete this event only", role: .destructive) {
                        if let d = deletingMeeting {
                            ToastCenter.shared.deferDelete(d.meeting, span: .thisEvent, smart: smart)
                        }
                        deletingMeeting = nil
                    }
                    // Google expresses this by truncating the series' recurrence rule.
                    Button("Delete this and all future", role: .destructive) {
                        if let d = deletingMeeting {
                            ToastCenter.shared.deferDelete(d.meeting, span: .futureEvents, smart: smart)
                        }
                        deletingMeeting = nil
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        if let d = deletingMeeting {
                            ToastCenter.shared.deferDelete(d.meeting, span: .thisEvent, smart: smart)
                        }
                        deletingMeeting = nil
                    }
                }
                Button("Cancel", role: .cancel) { deletingMeeting = nil }
            }
            .confirmationDialog(
                "This event repeats",
                isPresented: Binding(get: { pendingRecurringMove != nil },
                                     set: { if !$0 { pendingRecurringMove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Move this event only") {
                    if let move = pendingRecurringMove {
                        commitMove(move.meeting, occurrenceID: move.occurrenceID,
                                   to: move.newStart, span: .thisEvent)
                    }
                    pendingRecurringMove = nil
                }
                // The whole series: a move by drag has no "this and following" (it would split
                // the series in two).
                Button("Move entire series") {
                    if let move = pendingRecurringMove {
                        commitMove(move.meeting, occurrenceID: move.occurrenceID,
                                   to: move.newStart, span: .allEvents)
                    }
                    pendingRecurringMove = nil
                }
                Button("Cancel", role: .cancel) { pendingRecurringMove = nil }
            } message: {
                if let move = pendingRecurringMove {
                    Text("Move “\(move.meeting.title)” to \(move.newStart.formatted(.dateTime.weekday().hour().minute()))?")
                }
            }
            .modifier(CalendarMoveRecoveryModifier(smart: smart))
            .alert("Couldn't move that event",
                   isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })) {
                Button("OK", role: .cancel) { moveError = nil }
            } message: {
                Text(moveError ?? "")
            }
            .sheet(item: $movingOccurrence, onDismiss: runAfterSheet) { occurrence in
                OccurrenceTimeSheet(title: "Move \(occurrence.title)", initial: occurrence.start) { newStart in
                    if let key = occurrence.occurrenceKey {
                        ExceptionStore.shared.reschedule(key, to: newStart)
                        Task { await occurrences.recompute() }
                    } else if let meeting = occurrence.meeting {
                        // A calendar event: the move a drag makes, asking first when it repeats.
                        // (This sheet used to do nothing for one.)
                        afterSheet = {
                            if smart.meetingRecurs(meeting) {
                                pendingRecurringMove = PendingEventMove(meeting: meeting,
                                                                        occurrenceID: occurrence.id,
                                                                        newStart: newStart)
                            } else {
                                commitMove(meeting, occurrenceID: occurrence.id, to: newStart, span: .thisEvent)
                            }
                        }
                    }
                }
            }
            .sheet(item: $inspectingCue, onDismiss: runAfterSheet) { occurrence in
                if let routine = routine(of: occurrence) {
                    CueOccurrenceSheet(occurrence: occurrence, routine: routine, plan: smart.plan) { action in
                        switch action {
                        case .move: afterSheet = { movingOccurrence = occurrence }
                        case .edit: afterSheet = { editing = routine }
                        case .addAnother: afterSheet = { addingExtraFor = routine }
                        }
                    }
                    .frame(minWidth: 380, minHeight: 380)
                }
            }
            .sheet(item: $addingExtraFor) { routine in
                OccurrenceTimeSheet(title: "Add \(routine.name)", initial: Date().addingTimeInterval(3600)) { start in
                    ExceptionStore.shared.addExtra(seriesID: routine.id.uuidString, start: start)
                    Task { await occurrences.recompute() }
                }
            }
            .confirmationDialog(
                "This event hasn\u{2019}t been saved",
                isPresented: Binding(get: { failedWriteToResolve != nil },
                                     set: { if !$0 { failedWriteToResolve = nil } }),
                titleVisibility: .visible
            ) {
                Button("Try again") {
                    if let ticket = failedWriteToResolve { occurrences.retryPendingWrite(ticket) }
                    failedWriteToResolve = nil
                }
                Button("Discard", role: .destructive) {
                    if let ticket = failedWriteToResolve { occurrences.discardPendingWrite(ticket) }
                    failedWriteToResolve = nil
                }
                Button("Keep for later", role: .cancel) { failedWriteToResolve = nil }
            } message: {
                Text(failedWriteToResolve
                        .flatMap { occurrences.pendingWrites.entry($0)?.lastError }
                        ?? "It couldn\u{2019}t be written to your calendar.")
            }
            .sheet(item: $reschedulingTask) { occurrence in
                OccurrenceTimeSheet(
                    title: "Reschedule \(occurrence.title)",
                    initial: occurrence.hasScheduledTime
                        ? occurrence.start
                        : Date().addingTimeInterval(3_600)
                ) { newDue in
                    if let id = occurrence.reminderID {
                        Task { await occurrences.rescheduleTask(reminderID: id, to: newDue) }
                    }
                }
            }
            .sheet(item: $editingTask) { occurrence in
                if let id = occurrence.reminderID {
                    NewTaskSheet(reminderID: id, title: occurrence.title,
                                 tick: (occurrence.completed, { TaskTick.toggle(occurrence) }),
                                 missed: NewTaskSheet.Missed(occurrence))
                }
            }
            .onAdd(.event, .reminder, .alarm) { kind in
                switch kind {
                case .event:
                    newEventRequest = MacNewEventRequest(start: defaultNewEventStart(), durationMinutes: 60)
                case .reminder:
                    newTaskDue = defaultNewEventStart()
                    showingNewTask = true
                default: showingAlarms = true
                }
            }
            .sheet(item: $newEventRequest) { request in
                NewCalendarEventSheet(
                    initialStart: request.start,
                    initialDurationMinutes: request.durationMinutes
                )
            }
            .sheet(isPresented: $showingNewTask, onDismiss: { newTaskDue = nil }) {
                NewTaskSheet(initialDue: newTaskDue)
            }
            .sheet(isPresented: $showingAlarms) { OneOffAlarmSheet().toastHost() }
        }
        .onChange(of: calendarScope.calendarIDs) { _, _ in rebuild(occurrences.occurrences) }
        .onAppear {
            rebuild(occurrences.occurrences)
            setInitialScrollPosition()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--mac-new-event"), !didOpenDebugSheet {
                didOpenDebugSheet = true
                newEventRequest = MacNewEventRequest(start: defaultNewEventStart(), durationMinutes: 60)
            }
            #endif
        }
        .task {
            #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("--ui-audit") else { return }
            #endif
            async let rollingRefresh: Void = occurrences.recomputeIfStale()
            async let windowRefresh: Void = refreshVisibleWeek()
            _ = await (rollingRefresh, windowRefresh)
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--offscreen-recompute-regression") else { return }
            try? await Task.sleep(for: .seconds(4))
            for round in 0..<20 where !Task.isCancelled {
                occurrences.republishWithOffscreenChange(round: round)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        #endif
        // @Published emits before the store installs its new interval index. Rebuild on the
        // next run-loop turn so the range query and its source snapshot agree.
        .onReceive(occurrences.$occurrences.receive(on: RunLoop.main)) { _ in
            rebuild(occurrences.occurrences)
            Task { await refreshVisibleWeek() }
        }
        .onReceive(occurrences.$planningWindowRevision) { _ in
            rebuild(occurrences.occurrences)
        }
        .onReceive(smart.$flightLegs.dropFirst()) { _ in
            DispatchQueue.main.async { updateSecondaryZone() }
        }
        // Read directly rather than through @AppStorage: this view is expensive, and it must
        // not re-render for defaults writes that have nothing to do with it. The update below
        // only touches state when the zone actually changes.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)) { _ in
            updateSecondaryZone()
        }
        .onReceive(MacNavigator.shared.$offeredSlots.dropFirst()) { slots in
            // Offered times are the point of the panel: if none fall in the period on screen
            // (on a Sunday the next five weekdays are all next week), go to the first of them.
            guard let first = slots.first?.start,
                  let firstDay = days.first?.date, let lastDay = days.last?.date,
                  !(firstDay...Calendar.current.date(byAdding: .day, value: 1, to: lastDay)!).contains(first)
            else { return }
            DispatchQueue.main.async { MacCommandCenter.shared.perform(.goTo(first)) }
        }
        .onReceive(ToastCenter.shared.$hiddenIDs.dropFirst()) { _ in
            // @Published fires before the value is stored; rebuild once it is.
            DispatchQueue.main.async { rebuild(occurrences.occurrences) }
        }
        .onReceive(smart.$calendarColorHex.removeDuplicates().dropFirst()) { _ in
            visibleSmartInputChanged()
        }
        .onReceive(smart.$commuteLegs.removeDuplicates().dropFirst()) { _ in
            visibleSmartInputChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macNewEventRequested)) { _ in
            newEventRequest = MacNewEventRequest(start: defaultNewEventStart(), durationMinutes: 60)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macNewTaskRequested)) { _ in
            showingNewTask = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .macCalendarAction)) { note in
            guard let action = note.object as? MacCalendarAction else { return }
            switch action {
            case .today: moveToCurrentWeek()
            case .nextPeriod: moveWeek(1)
            case .previousPeriod: moveWeek(-1)
            case .goTo(let date): moveWeek(periodOffset(to: date) - weekOffset)
            case .newEvent:
                newEventRequest = MacNewEventRequest(start: defaultNewEventStart(), durationMinutes: 60)
            case .newTask: showingNewTask = true
            case .shareAvailability: MacNavigator.shared.toggleAvailability()
            default: break
            }
        }
        // A booking push was tapped: its day, and its event in the drawer when it's still there.
        .onReceive(PlanOpenRequests.shared.$pending) { pending in
            // The value handed over (`$pending` publishes before it is stored), taken once it is.
            guard let pending else { return }
            Task { @MainActor in
                guard PlanOpenRequests.shared.take(pending) else { return }
                await openFromPush(pending)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macForceRefreshRequested)) { _ in
            // ⌘R: same chain as iOS pull-to-refresh — refresh EventKit sources, force the
            // Google fetch, then a full (not stale-gated) recompute so the grid re-renders.
            Task { await smart.refreshCalendar(); await occurrences.recompute() }
        }
        .onChange(of: weekSpan) {
            draftSelection = nil
            weekOffset = 0   // rolling and aligned spans page by different units
            rebuild(occurrences.occurrences)
            Task { await refreshVisibleWeek() }
        }
        .onReceive(
            smart.$settings
                .map(\.weekStartWeekday)
                .removeDuplicates()
                .dropFirst()
        ) { _ in
            draftSelection = nil
            rebuild(occurrences.occurrences)
            Task { await refreshVisibleWeek() }
        }
        .onDisappear { persistDayScrollPosition() }
        .background {
            MacHorizontalPeriodSwipe { moveWeek($0) }
        }
    }

    // MARK: - Fixed week chrome

    #if DEBUG
    private static let observationAuditEnabled = ScaleStress.days != nil
        && ProcessInfo.processInfo.arguments.contains("--calendar-observation-audit")
    private static let observationControlEnabled = ProcessInfo.processInfo.arguments.contains("--calendar-observation-control")
    #endif

    private func visibleSmartInputChanged() {
        #if DEBUG
        if Self.observationControlEnabled {
            rebuild(occurrences.occurrences)
            return
        }
        #endif
        // The identity-only store environment does not invalidate this view. These publishers
        // affect visible colors/travel even when the occurrence snapshot compares equal.
        // Their removeDuplicates operators suppress identical publications upstream.
        visibleSmartRevision &+= 1
    }

    private var headerLabel: String {
        if dayMode { return weekOffset == 0 ? "TODAY" : "DAY OF" }
        if weekSpan.isAlignedWeek {
            return weekOffset == 0 ? "THIS WEEK" : "WEEK OF"
        }
        return weekOffset == 0 ? "NEXT \(weekSpan.rawValue) DAYS" : "\(weekSpan.rawValue) DAYS FROM"
    }

    private var plannerPaging: some View {
        let dates = days.first.map { PlanPaging.dates(start: $0.date, days: visibleDayCount) } ?? ""
        return MacPeriodPagingControls(days: visibleDayCount, dates: dates, isCurrent: weekOffset == 0,
                                       step: moveWeek, toCurrent: moveToCurrentWeek) {
            PlanPeriodMenu(dates: dates, datesPlace: .hidden)
        }
    }

    @ViewBuilder private var plannerStatus: some View {
        if dayMode, let day = days.first?.date {
            WeatherChip(day: day)
        } else if days.contains(where: \.isToday) {
            WeatherChip(day: Date())
        }
        CalendarRefreshStatus(loading: loading) { active in
            if active { ProgressView().controlSize(.small) }
        }
    }

    private var plannerActions: some View {
        MoreMenu(identifier: "mac.planner.more") {
            BookingShareButton()
            Button { MacNavigator.shared.toggleAvailability() } label: {
                Label("Share availability", systemImage: "calendar.badge.checkmark")
            }
            .help("Share availability (S)")
            Button { NotificationCenter.default.post(name: .macForceRefreshRequested, object: nil) } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .help("Share and refresh")
    }

    private func overflowList(_ cluster: OverflowCluster, dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(cluster.items.count) events · \(cluster.start.formatted(.dateTime.weekday().month().day()))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(cluster.items) { item in
                        Button {
                            dismiss()
                            activate(item)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.completed ? "checkmark.circle.fill" : item.icon)
                                    .foregroundStyle(blockTint(for: item))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.start.formatted(.dateTime.hour().minute()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { occurrenceMenu(item) }
                    }
                }
            }
            .frame(height: min(400, CGFloat(cluster.items.count) * 48))
        }
        .frame(width: 320)
        .padding(.bottom, 6)
    }

    private var dayHeaders: some View {
        GeometryReader { geometry in
            let dayWidth = availableDayWidth(in: geometry.size.width)
            HStack(spacing: 0) {
                zoneHeader.frame(width: timeGutterWidth, height: dayHeaderHeight, alignment: .bottom)
                ForEach(days) { day in
                    let overflow = timedLayout(for: day).overflow
                    // "Mon 21" on one line; today's date sits in the accent pill. The per-day
                    // count moved to the tooltip — a number on every column was noise.
                    HStack(spacing: DS.Space.xs) {
                        Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(day.isToday ? DS.Typeface.dayHeaderToday : DS.Typeface.dayHeader)
                            .foregroundStyle(day.isToday ? DS.Palette.accent : .secondary)
                        Text(day.date.formatted(.dateTime.day()))
                            .font(DS.Typeface.dayHeaderToday)
                            .monospacedDigit()
                            .foregroundStyle(day.isToday ? DS.Palette.onAccent : Color.primary)
                            // Today's number in a circle, as on the phone and the iPad: one
                            // shape for each thing on every device (round marks, capsule chips).
                            .frame(width: 22, height: 22)
                            .background(day.isToday ? DS.Palette.accent : Color.clear, in: Circle())
                        if !overflow.isEmpty {
                            CalendarOverflowButton { dismiss in
                                overflowList(OverflowCluster(start: day.date,
                                    hidden: overflow.reduce(0) { $0 + $1.hidden },
                                    items: overflow.flatMap(\.items)), dismiss: dismiss)
                            } label: {
                                Text("+\(overflow.reduce(0) { $0 + $1.hidden })")
                                    .font(.caption.monospacedDigit())
                            }
                            .buttonStyle(.plain)
                            .help("Show overlapping events hidden by the column's lane limit")
                            .accessibilityIdentifier("mac.week.overflow.\(Self.dayIDFormatter.string(from: day.date))")
                        }
                    }
                    .frame(width: dayWidth, height: dayHeaderHeight)
                    .background(day.isToday ? DS.Palette.todayWash : Color.clear)
                    .help(day.scheduleSummary)
                    .overlay(alignment: .trailing) { verticalSeparator }
                    .accessibilityIdentifier("mac.week.day.\(Self.dayIDFormatter.string(from: day.date))")
                }
            }
        }
        .frame(height: dayHeaderHeight)
        .background(Color(.systemBackground))
    }

    private var allDayRow: some View {
        GeometryReader { geometry in
            let dayWidth = availableDayWidth(in: geometry.size.width)
            HStack(spacing: 0) {
                gutterLabel("No time")
                ForEach(days) { day in
                    // What blocks the day first: never behind "+N more".
                    let untimed = AllDayEvents.busyFirst(untimedItems(day), blocks: \.blocksWholeDay)
                    let fitting = AllDayEvents.fitting(untimed, limit: 2)
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(fitting.shown) { occurrence in
                            allDayChip(occurrence)
                        }
                        if fitting.more > 0 {
                            // The rest, a click away — the line used to open nothing.
                            Button { untimedOverflowDay = day.date } label: {
                                Text("+\(fitting.more) more")
                                    .font(DS.Typeface.eventMeta)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, DS.Space.xs)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show all \(untimed.count)")
                            .accessibilityIdentifier("mac.week.allDay.more")
                            .popover(isPresented: Binding(get: { untimedOverflowDay == day.date },
                                                          set: { if !$0 { untimedOverflowDay = nil } }),
                                     arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: DS.Space.xs) {
                                    Text(day.date.formatted(.dateTime.weekday(.wide).month().day()))
                                        .font(DS.Typeface.eventMeta)
                                        .foregroundStyle(.secondary)
                                    ForEach(untimed) { allDayChip($0) }
                                }
                                .padding(DS.Space.m)
                                .frame(width: 260)
                            }
                        }
                    }
                    .padding(DS.Space.xs)
                    .frame(width: dayWidth, height: allDayHeight, alignment: .topLeading)
                    .background(day.isToday ? DS.Palette.todayWash : Color.clear)
                    .overlay(alignment: .trailing) { verticalSeparator }
                }
            }
        }
        .frame(height: allDayHeight)
        .background(Color(.systemBackground))
    }

    /// A row label in the time gutter ("NO TIME", "REMINDERS"): one style, right-aligned to the
    /// same edge as the hour labels below it.
    private func gutterLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DS.Typeface.eyebrow)
            .tracking(DS.Typeface.eyebrowTracking)
            .foregroundStyle(DS.Palette.quietText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: timeGutterWidth - DS.Space.s, alignment: .trailing)
            .padding(.trailing, DS.Space.s)
            .padding(.top, DS.Space.s)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var reminderRows: some View {
        GeometryReader { geometry in
            let dayWidth = availableDayWidth(in: geometry.size.width)
            HStack(spacing: 0) {
                gutterLabel("To do")
                ForEach(days) { day in
                    let line = reminderLine(day)
                    // Past the rows that fit, the last one says how many more and opens them:
                    // everything overdue is in this row and nowhere else, so none of it may sit
                    // below an edge with nothing to say it's there.
                    let folded = !remindersExpanded && line.count > maxVisibleReminderRows
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 3) {
                            ForEach(folded ? Array(line.prefix(maxVisibleReminderRows - 1)) : line) { occurrence in
                                if occurrence.isUntimedCue {
                                    allDayChip(occurrence)
                                        .frame(minHeight: reminderRowHeight, alignment: .leading)
                                } else {
                                    reminderRow(occurrence)
                                }
                            }
                            // What else needs attention, beside today's reminders.
                            if day.isToday, attention.count > 0 {
                                PlanAttentionChips(desktop: true)
                                    .frame(maxWidth: .infinity, minHeight: reminderRowHeight - 3, alignment: .leading)
                            }
                            if folded || (remindersExpanded && line.count > maxVisibleReminderRows) {
                                Button {
                                    withAnimation(.snappy(duration: 0.2)) { remindersExpanded.toggle() }
                                } label: {
                                    Text(folded ? "+\(line.count - (maxVisibleReminderRows - 1)) more" : "Fewer")
                                        .frame(maxWidth: .infinity, minHeight: reminderRowHeight - 3, alignment: .leading)
                                        .padding(.leading, 6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.inline)
                                .accessibilityIdentifier("mac.week.reminders.more")
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 5)
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: dayWidth, height: reminderRowsHeight, alignment: .topLeading)
                    .background(day.isToday ? DS.Palette.todayWash : Color.clear)
                    .overlay(alignment: .trailing) { verticalSeparator }
                }
            }
        }
        .frame(height: reminderRowsHeight)
        .background(Color(.systemBackground))
        .accessibilityIdentifier("mac.week.reminders")
    }

    // MARK: - Shared time grid

    private static let reusesGridColumns: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-reuse-columns")
        #else
        false
        #endif
    }()

    private struct MacViewportTravelBand {
        let y: CGFloat
        let height: CGFloat
        let minutes: Int
        let detail: TravelLegDetail?
    }

    private func macViewportItems(width: CGFloat, now: Date) -> [CalendarMacViewportItem] {
        let columnWidth = availableDayWidth(in: width)
        let includesToday = days.contains(where: \.isToday)
        return days.enumerated().flatMap { dayIndex, day in
            let layout = timedLayout(for: day)
            let placements = layout.placements
            let neighbors = CalendarMacLaneNeighbors.make(placements.map {
                .init(lane: $0.lane, start: $0.occurrence.start, end: $0.occurrence.resolvedEnd,
                      displayedStart: displayStart($0.occurrence))
            })
            let dayKey = Occurrence.dayKey(day.date)
            let blocked = day.items.contains(where: \.blocksWholeDay)
            let events = zip(placements, neighbors).map { placement, neighbor in
                let x = laneX(totalWidth: columnWidth, lane: placement.lane, lanes: placement.laneCount)
                let y = gridY(for: displayStart(placement.occurrence), on: day.date)
                let blockWidth = laneWidth(totalWidth: columnWidth, lanes: placement.laneCount) * CGFloat(placement.laneSpan) + 2 * CGFloat(placement.laneSpan - 1)
                let room = neighbor.nextDisplayedStart.map { gridY(for: $0, on: day.date) - y }
                let height = min(blockHeight(for: placement.occurrence, on: day.date, endingAt: neighbor.visualEnd),
                                 max(12, room ?? .greatestFiniteMagnitude))
                let eventFrame = CGRect(x: x, y: y, width: blockWidth, height: height)
                let outward: MacViewportTravelBand?
                let returning: MacViewportTravelBand?
                var top = y
                var bottom = y + height
                if let outbound = outboundBand(forGrid: placement.occurrence) {
                    let bandTop = travelBandTop(placement, among: placements, on: day.date,
                        preferred: gridY(for: outbound.leaveBy, on: day.date), neighbors: neighbors)
                    let bandHeight = max(6, gridY(for: placement.occurrence.start, on: day.date) - bandTop)
                    outward = .init(y: bandTop, height: bandHeight, minutes: outbound.minutes, detail: outbound.detail)
                    top = min(top, bandTop)
                    bottom = max(bottom, bandTop + bandHeight)
                } else { outward = nil }
                if let ret = returnLeg(forGrid: placement.occurrence), (ret.end ?? ret.start) > Date() {
                    let returnEnd = ret.end ?? ret.start
                    let bandTop = max(gridY(for: ret.start, on: day.date), y + height)
                    let bandHeight = max(6, gridY(for: returnEnd, on: day.date) - bandTop)
                    returning = .init(y: bandTop, height: bandHeight,
                                      minutes: Int(returnEnd.timeIntervalSince(ret.start) / 60), detail: ret.travel)
                    bottom = max(bottom, bandTop + bandHeight)
                } else { returning = nil }
                let localFrame = CGRect(x: x, y: top, width: blockWidth, height: bottom - top)
                let frame = localFrame.offsetBy(dx: timeGutterWidth + CGFloat(dayIndex) * columnWidth, dy: 0)
                return CalendarMacViewportItem(
                    id: dayKey + "|" + placement.occurrence.id,
                    frame: frame, zIndex: draggingEventID == placement.occurrence.id ? 3 : 0) {
                        AnyView(macPlacementLayer(placement, frame: eventFrame, outbound: outward, returning: returning,
                                                  day: day.date, width: columnWidth)
                            .frame(width: columnWidth, height: gridHeight, alignment: .topLeading)
                            .offset(x: -localFrame.minX, y: -localFrame.minY)
                            .frame(width: localFrame.width, height: localFrame.height, alignment: .topLeading)
                            .environment(\.blockedDayBase, blocked
                                ? Color(.systemBackground) : nil))
                    }
            }
            let overflow = layout.overflow.map { cluster in
                let x = max(4, columnWidth - 34)
                return CalendarMacViewportItem(
                    id: dayKey + "|overflow|" + String(describing: cluster.id),
                    frame: CGRect(x: timeGutterWidth + CGFloat(dayIndex) * columnWidth + x,
                                  y: gridY(for: cluster.start, on: day.date) + 2,
                                  width: max(1, columnWidth - x), height: 26), zIndex: 2) {
                    AnyView(macOverflowControl(cluster, width: columnWidth)
                        .frame(width: columnWidth, height: 26, alignment: .topLeading)
                        .offset(x: -x)
                        .frame(width: max(1, columnWidth - x), height: 26, alignment: .topLeading).clipped())
                }
            }
            var result = events + overflow
            if includesToday {
                let y = gridY(for: now, on: Calendar.current.startOfDay(for: now))
                result.append(CalendarMacViewportItem(
                    id: dayKey + "|now",
                    frame: CGRect(x: timeGutterWidth + CGFloat(dayIndex) * columnWidth,
                                  y: day.isToday ? y - 3.5 : y,
                                  width: columnWidth, height: day.isToday ? 7 : 1),
                    zIndex: 1, allowsHitTesting: false) {
                        AnyView(Group {
                            if day.isToday {
                                HStack(spacing: 0) {
                                    Circle().fill(DS.Palette.now).frame(width: 7, height: 7)
                                    Rectangle().fill(DS.Palette.now).frame(height: 1.5)
                                }.offset(x: -3)
                            } else {
                                Rectangle().fill(DS.Palette.now.opacity(DS.Tint.strong))
                            }
                        }.clipped().accessibilityHidden(true))
                    })
            }
            return result
        }
    }

    private func nativeSlotActions(at point: CGPoint, width: CGFloat) -> [CalendarMacSlotAction] {
        let columnWidth = availableDayWidth(in: width)
        guard columnWidth > 0, point.x >= timeGutterWidth, point.x < width,
              point.y >= 0, point.y < gridHeight else { return [] }
        let index = Int((point.x - timeGutterWidth) / columnWidth)
        guard days.indices.contains(index) else { return [] }
        let start = BookingGrid.snappedStart(on: days[index].date, atY: point.y,
            hourHeight: hourHeight, rounding: .nearest)
        let time = start.formatted(.dateTime.hour().minute())
        return [
            CalendarMacSlotAction(title: "New event at \(time)") {
                newEventRequest = MacNewEventRequest(start: start, durationMinutes: 60)
            },
            CalendarMacSlotAction(title: "New reminder at \(time)") {
                newTaskDue = start
                showingNewTask = true
            }
        ]
    }

    private func timeGrid(now: Date, includesEvents: Bool = true) -> some View {
        GeometryReader { geometry in
            let dayWidth = availableDayWidth(in: geometry.size.width)
            HStack(alignment: .top, spacing: 0) {
                timeLabels(now: now)
                    .frame(width: timeGutterWidth, height: gridHeight)
                if Self.reusesGridColumns {
                    // Experimental: retain fixed column chrome across page changes. Events
                    // and overflow groups still use their own content IDs and are replaced.
                    ForEach(days.indices, id: \.self) { index in
                        dayColumn(days[index], width: dayWidth, now: now, includesEvents: includesEvents)
                            .frame(width: dayWidth, height: gridHeight)
                    }
                } else {
                    ForEach(days) { day in
                        dayColumn(day, width: dayWidth, now: now, includesEvents: includesEvents)
                            .frame(width: dayWidth, height: gridHeight)
                    }
                }
            }
        }
        .frame(height: gridHeight)
    }

    private func timeLabels(now: Date) -> some View {
        // Where the now-line crosses the gutter, if today is on screen: the hour label it would
        // collide with steps aside for a label saying the time.
        let nowY: CGFloat? = days.first(where: \.isToday).map { gridY(for: now, on: $0.date) }
        return HStack(spacing: 0) {
            if let secondaryZone {
                // The other zone's hours, dimmer and to the left, like a watch's second dial.
                ZStack(alignment: .topLeading) {
                    Color(.systemBackground)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(TripTimeZone.label(forHour: hour, on: days.first?.date ?? Date(),
                                                primary: .current, zone: secondaryZone))
                            .font(DS.Typeface.small(design: .rounded))
                            .foregroundStyle(DS.Palette.quietText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: Self.secondaryGutterWidth - 6, alignment: .trailing)
                            .offset(y: max(0, CGFloat(hour) * hourHeight - 7))
                    }
                }
                .frame(width: Self.secondaryGutterWidth)
            }
            ZStack(alignment: .topLeading) {
                Color(.systemBackground)
                ForEach(0..<24, id: \.self) { hour in
                    let y = CGFloat(hour) * hourHeight
                    Text(hourLabel(hour))
                        .font(DS.Typeface.gutter)
                        .foregroundStyle(DS.Palette.quietText)
                        .frame(width: 58 - DS.Space.s, alignment: .trailing)
                        .offset(y: max(0, y - 7))
                        .opacity(nowY.map { abs($0 - y) < 12 } == true ? 0 : 1)
                }
                if let nowY {
                    // Clock time only ("12:29"): the gutter is too narrow for the day part, and
                    // a label that truncates to "12:29…" reads as broken.
                    Text(TimeRangeText.clockOnly(now))
                        .font(DS.Typeface.gutter.weight(.semibold))
                        .foregroundStyle(DS.Palette.onAccent)
                        .padding(.horizontal, DS.Space.xs)
                        .frame(height: 16)
                        .background(DS.Palette.now, in: RoundedRectangle(cornerRadius: DS.Radius.chip - 2, style: .continuous))
                        .frame(width: 58 - DS.Space.xs, alignment: .trailing)
                        .offset(y: max(0, nowY - 8))
                        .accessibilityLabel("Now, \(TimeRangeText.time(now))")
                }
            }
            .frame(width: 58)
        }
        .overlay(alignment: .trailing) { verticalSeparator }
    }

    /// Zone names over the hour columns, only when there are two.
    @ViewBuilder private var zoneHeader: some View {
        if let secondaryZone {
            let date = days.first?.date ?? Date()
            HStack(spacing: 0) {
                Text(TripTimeZone.shortName(secondaryZone, at: date))
                    .foregroundStyle(DS.Palette.quietText)
                    .frame(width: Self.secondaryGutterWidth - 6, alignment: .trailing)
                    .help(secondaryZone.identifier)
                Spacer(minLength: 0)
                Text(TripTimeZone.shortName(.current, at: date))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                    .help(TimeZone.current.identifier)
                Spacer(minLength: 10)
            }
            .font(DS.Typeface.small(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.bottom, 6)
        } else {
            Color.clear
        }
    }

    private func updateSecondaryZone() {
        let zone = TripZoneForGrid.zone(first: days.first?.date, last: days.last?.date, legs: smart.flightLegs)
        if zone?.identifier != secondaryZone?.identifier { secondaryZone = zone }
    }

    private func dayColumn(_ day: MacWeekDay, width: CGFloat, now: Date, includesEvents: Bool = true) -> some View {
        // The native viewport already lays out events. Its background needs only the grid.
        let layout: TimedLayout = includesEvents ? timedLayout(for: day) : (placements: [], overflow: [])
        let placements = layout.placements
        // A day blocked all day (Busy all-day event): hatched in its calendar's colour, so a day
        // that can't be booked reads as one at a glance.
        let blockedBy = day.items.first(where: \.blocksWholeDay)
        let background = (day.isToday ? DS.Palette.todayWash : Color(.systemBackground))
            .overlay {
                if let blockedBy { BlockedDayFill(color: blockTint(for: blockedBy)) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { updateSelection(on: day.date, from: $0) }
                    .onEnded { finishSelection(on: day.date, from: $0) }
            )
        return ZStack(alignment: .topLeading) {
            Group {
                if !includesEvents && Self.nativeViewport {
                    // The AppKit background host resolves its contextual menu from the
                    // current mouse-down location, without retained hover state.
                    background
                } else if CalendarSlotContextMenu.localObservation {
                    background.modifier(CalendarSlotContextMenu(day: day.date, hourHeight: hourHeight,
                        createEvent: { newEventRequest = MacNewEventRequest(start: $0, durationMinutes: 60) },
                        createReminder: { newTaskDue = $0; showingNewTask = true }))
                } else {
                    // Preserve the original inline observation path as the matched control.
                    background
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let point):
                                let snapped = BookingGrid.snappedStart(on: day.date, atY: point.y,
                                    hourHeight: hourHeight, rounding: .nearest)
                                if hoverSlot?.day != day.date || hoverSlot?.date != snapped {
                                    hoverSlot = (day.date, snapped)
                                }
                            case .ended: break
                            }
                        }
                        .contextMenu {
                            if let slot = hoverSlot {
                                Button {
                                    newEventRequest = MacNewEventRequest(start: slot.date, durationMinutes: 60)
                                } label: {
                                    Label("New event at \(slot.date.formatted(.dateTime.hour().minute()))",
                                          systemImage: "calendar.badge.plus")
                                }
                                Button { newTaskDue = slot.date; showingNewTask = true } label: {
                                    Label("New reminder at \(slot.date.formatted(.dateTime.hour().minute()))",
                                          systemImage: "checklist")
                                }
                            }
                        }
                }
            }
            .help("Click to create a one-hour event, drag to set its duration, or right-click for a reminder")

            if CalendarHourLines.experimentalCanvasEnabled {
                CalendarHourLines(hourHeight: hourHeight, hourColor: DS.Palette.gridHour,
                                  halfHourColor: DS.Palette.gridHalfHour, usesCanvas: true)
            } else {
                ForEach(0...24, id: \.self) { hour in
                    Rectangle().fill(DS.Palette.gridHour).frame(height: 1)
                        .offset(y: CGFloat(hour) * hourHeight).allowsHitTesting(false)
                }
                ForEach(0..<24, id: \.self) { hour in
                    Rectangle().fill(DS.Palette.gridHalfHour).frame(height: 1)
                        .offset(y: (CGFloat(hour) + 0.5) * hourHeight).allowsHitTesting(false)
                }
            }

            if let draftSelection,
               Calendar.current.isDate(draftSelection.day, inSameDayAs: day.date) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(DS.Palette.accent.opacity(DS.Tint.fill))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(DS.Palette.accent, lineWidth: 1.5)
                    }
                    .overlay(alignment: .topLeading) {
                        // The rectangle alone doesn't say what it will create — the range does.
                        Text(draftSelection.rangeLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Palette.accent)
                            .padding(.horizontal, 4).padding(.top, 2)
                    }
                    .frame(
                        width: max(8, width - 8),
                        height: max(14, CGFloat(draftSelection.durationMinutes) / 60 * hourHeight)
                    )
                    .offset(
                        x: 4,
                        y: gridY(for: draftSelection.start, on: day.date)
                    )
                    .allowsHitTesting(false)
            }

            // Share availability: the times being offered, beneath the events that bound them.
            OfferedSlotsOverlay(day: day.date, width: width, hourHeight: hourHeight)

            if includesEvents {
            ForEach(placements) { placement in
                let blockWidth = laneWidth(totalWidth: width, lanes: placement.laneCount) * CGFloat(placement.laneSpan) + 2 * CGFloat(placement.laneSpan - 1)
                let visualEnd = visualEnd(for: placement, among: placements)
                // The 15-minute minimum height must never reach into the next block in the same
                // lane: a 20-minute travel leg drawn 22 pt tall used to cover the start of the
                // meeting it leads to.
                let nextInLane = placements
                    .filter { $0.lane == placement.lane && $0.occurrence.start > placement.occurrence.start }
                    .map { displayStart($0.occurrence) }
                    .min()
                let room = nextInLane.map {
                    gridY(for: $0, on: day.date) - gridY(for: displayStart(placement.occurrence), on: day.date)
                }
                let visualHeight = min(blockHeight(for: placement.occurrence, on: day.date, endingAt: visualEnd),
                                       max(12, room ?? .greatestFiniteMagnitude))
                // Travel renders as a band occupying the minutes it actually takes, immediately
                // before the event. On a time grid that is the honest form: a "leave by 8:40"
                // caption tells you a time, but a band tells you the 25 minutes are SPENT — so a
                // meeting booked over your commute reads as the overlap it is. The list rows on
                // Today/Tomorrow/agenda keep the caption; there they have a line to spare.
                if let outbound = outboundBand(forGrid: placement.occurrence) {
                    // Clamped to the bottom of whatever is drawn before it, exactly as the return
                    // band below already is. Two places a few hundred feet apart produce a leg
                    // rounded up to the five-minute minimum, and unclamped that band was drawn
                    // straight through the preceding event.
                    let preferred = gridY(for: outbound.leaveBy, on: day.date)
                    let travelY = travelBandTop(placement, among: placements,
                                                on: day.date, preferred: preferred)
                    let travelHeight = max(6, gridY(for: placement.occurrence.start, on: day.date) - travelY)
                    TravelBand(minutes: outbound.minutes, height: travelHeight, detail: outbound.detail)
                        .frame(width: blockWidth, height: travelHeight, alignment: .topLeading)
                        .offset(
                            x: laneX(totalWidth: width, lane: placement.lane, lanes: placement.laneCount),
                            y: travelY
                        )
                }
                // The return leg reads the same way, mirrored: a band starting right where the
                // meeting's own drawn block ends (not its nominal end time — a short meeting's
                // block can be stretched to the 22pt/15-minute minimum, and the band must start
                // at its actual bottom edge or the two would overlap) and running the "Travel
                // home" hold's own window.
                if let ret = returnLeg(forGrid: placement.occurrence), (ret.end ?? ret.start) > Date() {
                    let returnEnd = ret.end ?? ret.start
                    let meetingBottom = gridY(for: displayStart(placement.occurrence), on: day.date) + visualHeight
                    let bandTop = max(gridY(for: ret.start, on: day.date), meetingBottom)
                    let bandHeight = max(6, gridY(for: returnEnd, on: day.date) - bandTop)
                    TravelBand(
                        minutes: Int(returnEnd.timeIntervalSince(ret.start) / 60),
                        height: bandHeight,
                        detail: ret.travel,
                        isReturn: true
                    )
                        .frame(width: blockWidth, height: bandHeight, alignment: .topLeading)
                        .offset(
                            x: laneX(totalWidth: width, lane: placement.lane, lanes: placement.laneCount),
                            y: bandTop
                        )
                }
                let eventContent = occurrenceBlock(
                    placement.occurrence,
                    height: visualHeight,
                    width: blockWidth,
                    showsIcon: width >= DS.Event.iconMinColumnWidth
                )
                    .frame(
                        width: blockWidth,
                        height: visualHeight,
                        alignment: .topLeading
                    )
                if CalendarEventDragFeedback.experimentalEnabled {
                    eventContent
                        .modifier(CalendarEventDragFeedback(
                            enabled: placement.occurrence.behavior == .event && placement.occurrence.meeting != nil,
                            columnWidth: width, showProgress: savingEventIDs.contains(placement.occurrence.id),
                            finish: { finishMoveGesture(for: placement.occurrence, on: day.date,
                                translation: $0, columnWidth: width) }))
                        .offset(x: laneX(totalWidth: width, lane: placement.lane, lanes: placement.laneCount),
                                y: gridY(for: displayStart(placement.occurrence), on: day.date))
                        .animation(.snappy(duration: 0.18), value: optimisticStart[placement.occurrence.id])
                } else {
                    let isDragging = draggingEventID == placement.occurrence.id
                    eventContent
                    .opacity(isDragging ? 0.75 : 1)
                    .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 6 : 0, y: 3)
                    .zIndex(isDragging ? 1 : 0)
                    .overlay(alignment: .topTrailing) {
                        if savingEventIDs.contains(placement.occurrence.id) {
                            ProgressView()
                                .controlSize(.small)
                                .padding(3)
                        }
                    }
                    .offset(
                        x: laneX(totalWidth: width, lane: placement.lane, lanes: placement.laneCount)
                            + (isDragging ? CGFloat(dragDayShift) * width : 0),
                        y: gridY(for: displayStart(placement.occurrence), on: day.date)
                            + (isDragging ? dragOffsetY : 0)
                    )
                    .animation(.snappy(duration: 0.18), value: optimisticStart[placement.occurrence.id])
                    .gesture(moveGesture(for: placement.occurrence, on: day.date, columnWidth: width))
                }
            }

            }

            // Anything the lane cap could not show, including staggered overlaps.
            if includesEvents {
            ForEach(layout.overflow) { cluster in
                CalendarOverflowButton { dismiss in
                    overflowList(cluster, dismiss: dismiss)
                } label: {
                    Text("+\(cluster.hidden)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        // Opaque, and lifted off the grid. Color.secondary is a SEMI-TRANSPARENT
                        // label colour, so the chip took on whatever was behind it and read as
                        // part of the block it was overlapping instead of a control.
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color(nsColor: .labelColor), in: Capsule())
                        .overlay {
                            Capsule().stroke(Color(nsColor: .windowBackgroundColor).opacity(0.8),
                                             lineWidth: 0.75)
                        }
                        .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)
                }
                .buttonStyle(.plain)
                .help("\(cluster.hidden) more at this time — click to see all \(cluster.items.count)")
                .offset(x: max(4, width - 34), y: gridY(for: cluster.start, on: day.date) + 2)
            }

            }

            // The current time across the whole week, faint, so "now" can be read against any
            // day — full strength only where it is actually today.
            if includesEvents, !day.isToday, days.contains(where: \.isToday) {
                Rectangle()
                    .fill(DS.Palette.now.opacity(DS.Tint.strong))
                    .frame(height: 1)
                    .offset(y: gridY(for: now, on: Calendar.current.startOfDay(for: now)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if includesEvents, day.isToday {
                let markerY = gridY(for: now, on: day.date)
                HStack(spacing: 0) {
                    Circle().fill(DS.Palette.now).frame(width: 7, height: 7)
                    Rectangle().fill(DS.Palette.now).frame(height: 1.5)
                }
                .offset(x: -3, y: markerY - 3.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .environment(\.blockedDayBase, blockedBy == nil ? nil : Color(.systemBackground))
        .clipped()
        .overlay(alignment: .trailing) { verticalSeparator }
    }

    private func macOverflowControl(_ cluster: OverflowCluster, width: CGFloat) -> some View {
                CalendarOverflowButton { dismiss in
                    overflowList(cluster, dismiss: dismiss)
                } label: {
                    Text("+\(cluster.hidden)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        // Opaque, and lifted off the grid. Color.secondary is a SEMI-TRANSPARENT
                        // label colour, so the chip took on whatever was behind it and read as
                        // part of the block it was overlapping instead of a control.
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color(nsColor: .labelColor), in: Capsule())
                        .overlay {
                            Capsule().stroke(Color(nsColor: .windowBackgroundColor).opacity(0.8),
                                             lineWidth: 0.75)
                        }
                        .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)
                }
                .buttonStyle(.plain)
                .help("\(cluster.hidden) more at this time — click to see all \(cluster.items.count)")
                .offset(x: max(4, width - 34), y: 0)
    }

    private func macPlacementLayer(_ placement: MacWeekPlacement, frame: CGRect,
                                   outbound: MacViewportTravelBand?, returning: MacViewportTravelBand?,
                                   day: Date, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let outbound {
                TravelBand(minutes: outbound.minutes, height: outbound.height, detail: outbound.detail)
                    .frame(width: frame.width, height: outbound.height, alignment: .topLeading)
                    .offset(x: frame.minX, y: outbound.y)
            }
            if let returning {
                TravelBand(minutes: returning.minutes, height: returning.height, detail: returning.detail, isReturn: true)
                    .frame(width: frame.width, height: returning.height, alignment: .topLeading)
                    .offset(x: frame.minX, y: returning.y)
            }
            let eventContent = occurrenceBlock(
                placement.occurrence,
                height: frame.height,
                width: frame.width,
                showsIcon: width >= DS.Event.iconMinColumnWidth
            )
                .frame(
                    width: frame.width,
                    height: frame.height,
                    alignment: .topLeading
                )
            if CalendarEventDragFeedback.experimentalEnabled {
                eventContent
                    .modifier(CalendarEventDragFeedback(
                        enabled: placement.occurrence.behavior == .event && placement.occurrence.meeting != nil,
                        columnWidth: width, showProgress: savingEventIDs.contains(placement.occurrence.id),
                        finish: { finishMoveGesture(for: placement.occurrence, on: day,
                            translation: $0, columnWidth: width) }))
                    .offset(x: frame.minX,
                            y: frame.minY)
                    .animation(.snappy(duration: 0.18), value: optimisticStart[placement.occurrence.id])
            } else {
                let isDragging = draggingEventID == placement.occurrence.id
                eventContent
                .opacity(isDragging ? 0.75 : 1)
                .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 6 : 0, y: 3)
                .zIndex(isDragging ? 1 : 0)
                .overlay(alignment: .topTrailing) {
                    if savingEventIDs.contains(placement.occurrence.id) {
                        ProgressView()
                            .controlSize(.small)
                            .padding(3)
                    }
                }
                .offset(
                    x: frame.minX
                        + (isDragging ? CGFloat(dragDayShift) * width : 0),
                    y: frame.minY
                        + (isDragging ? dragOffsetY : 0)
                )
                .animation(.snappy(duration: 0.18), value: optimisticStart[placement.occurrence.id])
                .gesture(moveGesture(for: placement.occurrence, on: day, columnWidth: width))
            }
        }
    }

    /// - Parameter showsIcon: decided once per column (see `DS.Event.iconMinColumnWidth`), so a
    ///   "Lunch" block is drawn the same way on every day of the week — it used to lose its icon
    ///   only on days where its lane happened to be narrow.
    private func occurrenceBlock(_ occurrence: Occurrence, height: CGFloat, width: CGFloat,
                                 showsIcon: Bool) -> some View {
        let tint = blockTint(for: occurrence)
        let ribbons = EventStateStyle.ribbonColors(occurrence, tint: tint, colors: smart.calendarColorHex)
        let returnCaption: String?
        if height >= DS.Event.twoLineMinHeight,
           let ret = returnLeg(forGrid: occurrence), (ret.end ?? ret.start) > Date() {
            let mins = Int((ret.end ?? ret.start).timeIntervalSince(ret.start) / 60)
            returnCaption = height >= 48 ? "Home by \(TimeRangeText.time(ret.start)) · \(mins) min"
                : TimeRangeText.time(ret.start)
        } else { returnCaption = nil }
        let start = displayStart(occurrence)
        let end = start.addingTimeInterval(occurrence.resolvedEnd.timeIntervalSince(occurrence.start))
        let timeRange = TimeRangeText.compact(start, end)
        let paint = CalendarEventPaint(occurrence: occurrence, tint: tint, ribbons: ribbons,
            startText: TimeRangeText.time(start),
            timeRange: height >= DS.Event.twoLineMinHeight && returnCaption == nil ? timeRange : "",
            returnCaption: returnCaption)
        return CalendarPreparedArtwork(paint: paint, height: height, layout: .desktop, showsIcon: showsIcon)
        .blockedDayBase(cornerRadius: DS.Radius.block)
        // Saving, or not saved: a new event Google hasn't taken says so, as on the phone. It
        // looked like any other event here, and stayed that way.
        .overlay(alignment: .topTrailing) {
            if let sync = occurrence.syncState { EventSyncBadge(state: sync) }
        }
        .contentShape(Rectangle())
        .onTapGesture { activate(occurrence) }
        // A reminder's circle, at the block's leading edge, ticks it; the rest opens it.
        .overlay(alignment: .topLeading) {
            if occurrence.behavior == .task, occurrence.reminderID != nil {
                Button { TaskTick.toggle(occurrence) } label: {
                    Color.clear.frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(occurrence.completed ? "Mark not done" : "Mark done")
                .accessibilityLabel(occurrence.completed ? "Mark \(occurrence.title) not done" : "Mark \(occurrence.title) done")
                .accessibilityIdentifier("mac.week.task.tick.\(occurrence.reminderID ?? occurrence.id)")
            }
        }
        .contextMenu { occurrenceMenu(occurrence) }
        .help("\(occurrence.title), \(timeRange)")
        .modifier(CalendarEventAccessibility(occurrence: occurrence,
            timeRange: timeRange, activate: { activate(occurrence) }))
    }

    private func allDayChip(_ occurrence: Occurrence) -> some View {
        let tint = blockTint(for: occurrence)
        // An all-day event that's Free — a birthday — is outlined: it's there, and blocks nothing.
        let outlined = occurrence.behavior == .allDay && !occurrence.blocksWholeDay
        // …and one that blocks the day is solid, its calendar's colour.
        let solid = occurrence.blocksWholeDay
        // A capsule, as the phone's all-day chips are.
        let shape = Capsule()
        return Button { activate(occurrence) } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: occurrence.completed ? "checkmark.circle.fill" : occurrence.icon)
                    .font(DS.Typeface.small(.semibold))
                Text(occurrence.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(DS.Typeface.eventTitle)
            .foregroundStyle(solid ? Color.white : tint)
            .padding(.horizontal, DS.Space.s - 2)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .background(solid ? tint : outlined ? Color.clear : tint.opacity(DS.Event.fill), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(outlined ? 0.6 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(occurrence.completed || occurrence.skipped ? 0.48 : 1)
        .contextMenu { occurrenceMenu(occurrence) }
        .accessibilityIdentifier("mac.week.occurrence.\(occurrence.id)")
    }

    private func reminderRow(_ occurrence: Occurrence) -> some View {
        HStack(spacing: 5) {
            Button {
                TaskTick.toggle(occurrence)
            } label: {
                Image(systemName: occurrence.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Palette.success)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac.week.task.toggle.\(occurrence.reminderID ?? occurrence.id)")
            .accessibilityLabel(
                occurrence.completed
                    ? "Mark \(occurrence.title) not done"
                    : "Mark \(occurrence.title) done"
            )
            .accessibilityValue(occurrence.completed ? "Completed" : "Incomplete")

            VStack(alignment: .leading, spacing: 0) {
                Text(occurrence.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(occurrence.completed, color: .secondary)
                Text(reminderDetail(occurrence))
                    .font(DS.Typeface.small(occurrence.overdue ? .semibold : .regular))
                    .foregroundStyle(occurrence.overdue ? DS.Palette.danger : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, minHeight: reminderRowHeight, alignment: .leading)
        // A capsule, as the phone's reminder chips are.
        .background(DS.Palette.task.opacity(DS.Tint.subtle), in: Capsule())
        .opacity(occurrence.completed ? 0.5 : 1)
        .contentShape(Rectangle())
        // The circle ticks; a click on the rest opens the reminder, as on the phone.
        .onTapGesture { editingTask = occurrence }
        .contextMenu { occurrenceMenu(occurrence) }
        .accessibilityIdentifier("mac.week.reminder.\(occurrence.id)")
    }

    private func reminderDetail(_ occurrence: Occurrence) -> String {
        if occurrence.completed { return "Completed" }
        if occurrence.overdue {
            // Since when: one from Saturday sits in today's row now, and should say so — in the
            // few words a week column has room for ("since Sat", in the overdue red).
            return OutstandingReminders.since(occurrence.schedule.constraints?.deadline ?? occurrence.start)
        }
        // Tied to a moment that hasn't come ("After your workout"): say that, as the phone does.
        let when = occurrence.hasScheduledTime
            ? occurrence.start.formatted(.dateTime.hour().minute())
            : occurrence.waitingFor ?? "No time"
        guard let missed = occurrence.missed else { return when }
        return "\(when) · \(missed.text.lowercased())"
    }

    // MARK: - Occurrence actions

    private func activate(_ occurrence: Occurrence) {
        switch occurrence.behavior {
        case .task:
            // A click opens the reminder; its circle and the menu tick it.
            editingTask = occurrence
        case .event, .allDay:
            // A new event that isn't in the calendar yet has nothing to inspect: one Google
            // refused asks what to do with it (as on the phone), one still saving waits.
            if occurrence.syncState == .failed, let ticket = occurrence.pendingWriteID {
                failedWriteToResolve = ticket
                return
            }
            if occurrence.pendingWriteID != nil { return }
            if let meeting = occurrence.meeting {
                #if os(macOS)
                MacNavigator.shared.inspectedMeeting = meeting
                #else
                if GoogleCalendarService.isGoogleEventInfoID(meeting.eventID) {
                    eventSheet = CalendarEventSheet(googleMeeting: meeting)
                }
                #endif
            }
        case .cue:
            // That moment, not the whole routine: the sheet has Edit for the routine.
            if occurrence.routineID != nil { inspectingCue = occurrence }
        case .block, .alarm:
            break
        }
    }

    private func routine(of occurrence: Occurrence) -> Routine? {
        routines.routines.first { $0.id == occurrence.routineID }
    }

    private func runAfterSheet() {
        afterSheet?()
        afterSheet = nil
    }

    private func replyItem(_ title: String, _ response: GoogleCalendarRSVP, ticked: Bool,
                           _ meeting: MeetingInfo) -> some View {
        Button {
            #if os(macOS)
            Task { await MacCommandCenter.shared.reply(to: meeting, with: response) }
            #else
            Task {
                if response == .declined {
                    await InvitationReply.decline(meeting)
                } else {
                    do {
                        try await InvitationReply.send(response, to: meeting)
                        ToastCenter.shared.notify(response.confirmation(title: meeting.title))
                    } catch {
                        ToastCenter.shared.notify("Couldn\u{2019}t reply: \(error.localizedDescription)")
                    }
                }
            }
            #endif
        } label: {
            if ticked { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    @ViewBuilder private func occurrenceMenu(_ occurrence: Occurrence) -> some View {
        switch occurrence.behavior {
        case .task:
            Button { editingTask = occurrence } label: {
                Label("Edit reminder…", systemImage: "pencil")
            }
            Button {
                TaskTick.toggle(occurrence)
            } label: {
                Label(
                    occurrence.completed ? "Mark not done" : "Mark done",
                    systemImage: occurrence.completed ? "circle" : "checkmark.circle"
                )
            }
            if occurrence.canBeMarkedMissed {
                Button { Task { await occurrences.markMissed(occurrence) } } label: {
                    Label("Missed it", systemImage: "xmark.circle")
                }
            }
            Button { reschedulingTask = occurrence } label: {
                Label("Reschedule…", systemImage: "clock.arrow.circlepath")
            }
            #if BANANA_MODULE_FOOD
            if occurrence.isRepeatingTask {
                // Something taken each day belongs in Taken: logged taken or skipped, checked for clashes.
                Button { AnchorSuggestionStore.shared.move(reminder: occurrence) } label: {
                    Label("Move to Taken…", systemImage: "pills")
                }
            }
            #endif
            if let id = occurrence.reminderID {
                let current = TaskDurationStore.shared.minutes(for: id)
                Menu {
                    ForEach(TaskDurationStore.options, id: \.self) { minutes in
                        Button {
                            TaskDurationStore.shared.set(id, minutes: minutes)
                            Task { await occurrences.recompute() }
                        } label: {
                            Label("\(minutes) min", systemImage: minutes == current ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label("Reserve \(current) min", systemImage: "timer")
                }
            }
        case .event:
            if let meeting = occurrence.meeting {
                Button { activate(occurrence) } label: {
                    Label("Open event", systemImage: "calendar")
                }
                Button { movingOccurrence = occurrence } label: {
                    Label("Move…", systemImage: "clock.arrow.circlepath")
                }
                // An invitation: your reply, the current one ticked — as Calendar's own menu has it.
                if let current = meeting.myResponse {
                    Menu {
                        replyItem("Yes", .accepted, ticked: current == .accepted, meeting)
                        replyItem("Maybe", .tentative, ticked: current == .tentative, meeting)
                        replyItem("No", .declined, ticked: false, meeting)
                    } label: {
                        Label("Going?", systemImage: "person.crop.circle.badge.questionmark")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    // A single event goes straight to a deferred delete with Undo; only a
                    // repeating one still has to ask which occurrences it means.
                    if smart.meetingRecurs(meeting) {
                        deletingMeeting = PendingEventDelete(meeting: meeting, recurring: true)
                    } else {
                        ToastCenter.shared.deferDelete(meeting, span: .thisEvent, smart: smart)
                    }
                } label: {
                    Label("Delete event", systemImage: "trash")
                }
            }
        case .allDay:
            if let meeting = occurrence.meeting {
                Button { activate(occurrence) } label: {
                    Label("Open event", systemImage: "calendar")
                }
                // Your copy Busy or Free: whether this day is blocked (`AllDayBlocking`).
                Button { AllDayBlocking.set(meeting, busy: meeting.showsAsFree) } label: {
                    Label(meeting.showsAsFree ? "Block this day" : "Don\u{2019}t block this day",
                          systemImage: meeting.showsAsFree ? "calendar.badge.clock" : "calendar")
                }
                Button { AllDayHiding.hide(meeting) } label: {
                    Label("Hide in Banana", systemImage: "eye.slash")
                }
                if let current = meeting.myResponse {
                    Menu {
                        replyItem("Yes", .accepted, ticked: current == .accepted, meeting)
                        replyItem("Maybe", .tentative, ticked: current == .tentative, meeting)
                        replyItem("No", .declined, ticked: false, meeting)
                    } label: {
                        Label("Going?", systemImage: "person.crop.circle.badge.questionmark")
                    }
                }
            }
        case .cue:
            if occurrence.occurrenceKey != nil, !occurrence.skipped {
                Button { CueCompletion.toggle(occurrence) } label: {
                    Label(occurrence.completed ? "Mark not completed" : "Mark completed", systemImage: occurrence.completed ? "circle" : "checkmark.circle")
                }
            }
            // The phone's menu for a routine moment (`cueMenu`), item for item.
            if occurrence.id.hasPrefix("extra:") {
                // Named: this menu also edits the routine itself.
                Button(role: .destructive) {
                    DeleteUndo.extra(String(occurrence.id.dropFirst("extra:".count)), named: occurrence.title) {
                        await OccurrenceStore.shared.recompute()
                    }
                } label: {
                    Label("Delete this extra", systemImage: "trash")
                }
            } else if occurrence.occurrenceKey != nil {
                if occurrence.skipped {
                    Button {
                        CueSkip.restore(occurrence)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                } else if !occurrence.completed {
                    Button {
                        CueSkip.skip(occurrence)
                    } label: {
                        Label("Skip", systemImage: "xmark.circle")
                    }
                    if occurrence.hasScheduledTime {
                        Button { movingOccurrence = occurrence } label: {
                            Label("Move…", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }
            if let routine = routine(of: occurrence) {
                Button { addingExtraFor = routine } label: {
                    Label("Add another…", systemImage: "plus.circle")
                }
                Button { editing = routine } label: {
                    Label("Edit cue", systemImage: "pencil")
                }
            }
        case .alarm:
            Button(role: .destructive) {
                if let id = UUID(uuidString: String(occurrence.id.dropFirst("alarm:".count))),
                   let store = alarmsRef.store {
                    DeleteUndo.alarm(id, in: store)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        case .block:
            EmptyView()
        }
    }

    // MARK: - Layout and data

    private func makeDays(_ all: [Occurrence]) -> [MacWeekDay] {
        let calendar = Calendar.current
        let start = visibleWeekStart
        let request = planningWindowRange(visibleStart: start)
        #if DEBUG
        let window = ProcessInfo.processInfo.arguments.contains("--ui-audit") && ScaleStress.days == nil
            ? all
            : occurrences.planningWindow(from: request.start, to: request.end)
        #else
        let window = occurrences.planningWindow(from: request.start, to: request.end)
        #endif
        let hidden = ToastCenter.shared.hiddenIDs
        let visible = PendingRemovals.visible(window, id: { $0.meeting?.eventID }, start: \.start, hiding: hidden)
        let source = ShellCalendarScope.visible(visible, in: calendarScope.calendarIDs)
        return (0..<visibleDayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let items = DayColumn.occurrences(source, on: date, calendar: calendar)
            return MacWeekDay(
                date: date,
                isToday: calendar.isDateInToday(date),
                items: items.sorted { $0.start < $1.start }
            )
        }
    }

    private func rebuild(_ all: [Occurrence]) {
        let overdue = occurrences.occurrences.filter(\.isOverdueReminder)
        if overdue != mountedOverdueReminders { mountedOverdueReminders = overdue }
        let nextDays = makeDays(all)
        if nextDays != mountedDays {
            // Geometry depends on the complete occurrence snapshot, including title/order
            // and completion state. Replace this visible-page-only cache with that snapshot;
            // never key reusable presentation solely by an event/date identifier.
            if Self.reuseTimedLayouts {
                preparedTimedLayouts = Dictionary(uniqueKeysWithValues: nextDays.map {
                    ($0.date, Self.makeTimedLayout(for: $0))
                })
            }
            mountedDays = nextDays
            mountSnapshot.clear()
            // What Report a problem says of the calendar: the days in view and their items' ids.
            ProblemReportCenter.shared.noteCalendar(
                start: nextDays.first?.date,
                end: nextDays.last.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0.date) },
                occurrencesByDay: nextDays.lazy.map(\.items))
        }
        updateSecondaryZone()
    }

    /// How many lanes a column can show before each becomes unusable. Five reminders due at
    /// 9:00 split a 150pt column into 28pt slivers: too narrow to read, and too narrow to hit.
    /// Past this, the overflow collapses into one "+N" chip that opens the full list.
    private static let maxVisibleLanes = 3

    private func timedLayout(for day: MacWeekDay) -> TimedLayout {
        if Self.reuseTimedLayouts, let layout = preparedTimedLayouts[day.date] { return layout }
        return Self.makeTimedLayout(for: day)
    }

    private static func makeTimedLayout(for day: MacWeekDay) -> TimedLayout {
        RenderStats.note("MacWeekTimedLayout")
        let timed = day.items.filter { $0.hasScheduledTime && $0.behavior != .block
            && !OutstandingReminders.leavesTheGrid(overdueReminder: $0.isOverdueReminder,
                                                   onToday: day.isToday, lineIsTodays: true) }
        let allocated = CalendarLaneAllocator.placements(timed)
        let hiddenIDs = Set(allocated.filter { $0.lane >= Self.maxVisibleLanes }.map { $0.occurrence.id })
        let placements = allocated.compactMap { placement -> MacWeekPlacement? in
            guard placement.lane < Self.maxVisibleLanes else { return nil }
            return MacWeekPlacement(occurrence: placement.occurrence, lane: placement.lane,
                                    laneCount: min(placement.laneCount, Self.maxVisibleLanes),
                                    laneSpan: min(placement.laneSpan, Self.maxVisibleLanes - placement.lane))
        }
        let byID = Dictionary(timed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = CalendarOverflowRules.groups(timed.map {
            .init(id: $0.id, start: $0.start, end: $0.resolvedEnd, title: $0.title)
        }, hiddenIDs: hiddenIDs)
        return (placements, groups.map {
            OverflowCluster(start: $0.start, hidden: $0.hidden, items: $0.itemIDs.compactMap { byID[$0] })
        })
    }

    private func setInitialScrollPosition() {
        guard !didSetInitialScroll else { return }
        didSetInitialScroll = true
        let targetOffset = openingScrollOffset()
        nativeInitialOffset = targetOffset
        if !Self.nativeViewport {
            Task { @MainActor in
                await Task.yield()
                gridScroll.scrollTo(y: targetOffset)
            }
        }
    }

    private func openingScrollOffset() -> CGFloat {
        let usePersistedOffset: Bool
        #if DEBUG
        usePersistedOffset = dayMode && persistedDayScrollOffset >= 0
            && !ProcessInfo.processInfo.arguments.contains("--ui-audit")
        #else
        usePersistedOffset = dayMode && persistedDayScrollOffset >= 0
        #endif
        if usePersistedOffset { return CGFloat(persistedDayScrollOffset) }
        let firstVisibleHour: Int
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
            // QA captures show the same workday regardless of the clock.
            firstVisibleHour = 7
        } else {
            let hour = Calendar.current.component(.hour, from: Date())
            firstVisibleHour = min(18, max(5, hour - 1))
        }
        #else
        let hour = Calendar.current.component(.hour, from: Date())
        firstVisibleHour = min(18, max(5, hour - 1))
        #endif
        // Never open below the earliest timed item, or cut off the first hour label.
        let calendar = Calendar.current
        let earliestHour = days.flatMap { day in
            day.items.filter { $0.hasScheduledTime && $0.behavior != .block
                && !OutstandingReminders.leavesTheGrid(overdueReminder: $0.isOverdueReminder,
                    onToday: day.isToday, lineIsTodays: true) }
        }
        .map { calendar.component(.hour, from: $0.start) }
        .min()
        let openHour = min(firstVisibleHour, earliestHour ?? firstVisibleHour)
        return max(0, CGFloat(openHour) * hourHeight - 10)
    }

    private func persistDayScrollPosition() {
        guard dayMode, didSetInitialScroll else { return }
        let offset = Double(max(0, scrollBookkeeping.offset).rounded())
        if persistedDayScrollOffset != offset { persistedDayScrollOffset = offset }
    }

    private func availableDayWidth(in totalWidth: CGFloat) -> CGFloat {
        max(1, (totalWidth - timeGutterWidth) / CGFloat(visibleDayCount))
    }

    private var hasReminderRows: Bool {
        days.contains { !reminderLine($0).isEmpty || ($0.isToday && attention.count > 0) }
    }

    private var hasUntimedItems: Bool {
        days.contains { !untimedItems($0).isEmpty }
    }

    /// Calendar items with no time. Due routines share the reminders row instead.
    private func untimedItems(_ day: MacWeekDay) -> [Occurrence] {
        day.items.filter { occurrence in
            !occurrence.hasScheduledTime && occurrence.behavior != .block
                && occurrence.behavior != .task && occurrence.behavior != .cue
        }
    }

    /// Shared to-do row: reminders (including everything outstanding today), then due routines.
    private func reminderLine(_ day: MacWeekDay) -> [Occurrence] {
        OutstandingReminders.line(untimed: day.reminders, overdue: overdueReminders, isToday: day.isToday,
                                  id: \.id, due: { $0.schedule.constraints?.deadline ?? $0.start })
            + day.items.filter { untimedMomentIsDue($0, routines: routines.routines, signals: signals) }
    }

    private var reminderRowsHeight: CGFloat {
        let largestDay = days.map { reminderLine($0).count + ($0.isToday ? attention.count : 0) }.max() ?? 0
        // Opened ("+N more"): every reminder and the "Fewer" row under them.
        let visibleRows = remindersExpanded && largestDay > maxVisibleReminderRows
            ? largestDay + 1
            : min(maxVisibleReminderRows, max(1, largestDay))
        return CGFloat(visibleRows) * reminderRowHeight + 10
    }

    /// The commute leg for a grid block, if the occurrence is a meeting with one. Matched by
    /// start instant, the same way the list rows do it.
    private func leaveBy(forGrid occurrence: Occurrence) -> NotificationService.CommuteLeg? {
        guard occurrence.behavior == .event, occurrence.start > Date() else { return nil }
        return smart.commuteLegs.first { abs($0.start.timeIntervalSince(occurrence.start)) < 60 }
    }

    /// The "Travel home" hold SmartScheduleStore reserved right after this meeting, matched the
    /// same way `leaveBy(forGrid:)` matches the outbound leg. `.block` occurrences never get a
    /// grid block of their own (filtered out of `timed` above), so this is the only place the
    /// return leg reaches the Mac calendar grid.
    /// The outbound travel for this meeting: its reserved "Travel to …" block if there is one,
    /// otherwise the live commute leg.
    ///
    /// The block is preferred because it is an `Occurrence`, so it is already in the first-paint
    /// snapshot and draws on the very first frame — the same reason "Travel home" has always
    /// appeared instantly. `commuteLegs` starts empty on every launch and only fills once routing
    /// returns, which is why trips TO places arrived late while trips home did not. The leg stays
    /// as the fallback for when travel write-back is off and no block exists.
    private func outboundBand(forGrid occurrence: Occurrence) -> (leaveBy: Date, minutes: Int, detail: TravelLegDetail?)? {
        guard occurrence.behavior == .event, occurrence.start > Date() else { return nil }
        if let block = occurrences.outboundTravel(endingAt: occurrence.start) {
            return (block.start, max(1, Int(block.resolvedEnd.timeIntervalSince(block.start) / 60)), block.travel)
        }
        return leaveBy(forGrid: occurrence).map { ($0.leaveBy, $0.travelMinutes, $0.detail) }
    }

    /// The highest a travel band may start without covering the event before it.
    ///
    /// Same lane only: two events in different lanes are concurrent, and a band overlapping one of
    /// those is honest — the trip really does run through it.
    private func travelBandTop(_ placement: MacWeekPlacement,
                               among placements: [MacWeekPlacement],
                               on day: Date,
                               preferred: CGFloat,
                               neighbors: [CalendarMacLaneNeighbors.Result]? = nil) -> CGFloat {
        let start = displayStart(placement.occurrence)
        var top = preferred
        for (index, other) in placements.enumerated() where other.lane == placement.lane
            && other.occurrence.id != placement.occurrence.id {
            let otherStart = displayStart(other.occurrence)
            guard otherStart < start else { continue }
            let end = neighbors?[index].visualEnd ?? visualEnd(for: other, among: placements)
            let bottom = gridY(for: otherStart, on: day)
                + blockHeight(for: other.occurrence, on: day, endingAt: end)
            top = max(top, bottom)
        }
        return top
    }

    private func returnLeg(forGrid occurrence: Occurrence) -> Occurrence? {
        guard occurrence.behavior == .event, let meeting = occurrence.meeting else { return nil }
        let departure = meeting.end ?? meeting.start
        return occurrences.returnTravel(startingAt: departure)
    }

    /// Drag an event block to a new time, and across columns to a new day.
    ///
    /// Only events move: cues, tasks and alarms are placed by their own rules and dragging one
    /// would silently contradict the thing that scheduled it. Duration never changes — this
    /// gesture means "same meeting, different time", and resizing is a separate affordance.
    /// Commit a move, drawing it at the new time immediately.
    ///
    /// EventKit's save plus the timeline recompute take a beat, and until they land the store
    /// still reports the old start. Rendering that truthfully meant the block snapped back to
    /// where it came from and then jumped forward again — which reads as "rejected, then
    /// changed its mind". The optimistic start is held until the store agrees or the write
    /// fails, and a spinner says the difference between "done" and "still going".
    private func commitMove(_ meeting: MeetingInfo, occurrenceID: String, to newStart: Date, span: CalendarEditSpan) {
        optimisticStart[occurrenceID] = newStart
        savingEventIDs.insert(occurrenceID)
        Task { @MainActor in
            let failure = await smart.moveMeeting(meeting, to: newStart, span: span)
            savingEventIDs.remove(occurrenceID)
            if let failure {
                optimisticStart[occurrenceID] = nil   // put it back where it really is
                moveError = failure
            } else {
                ToastCenter.shared.offerMoveUndo(meeting, from: meeting.start, to: newStart,
                                                         span: span, smart: smart)
                // Let the recompute land before dropping the override, so there is never a frame
                // drawn from stale store data.
                await occurrences.recompute()
                optimisticStart[occurrenceID] = nil
            }
        }
    }

    /// The start a block should be DRAWN at: the optimistic one while a save is in flight.
    private func displayStart(_ occ: Occurrence) -> Date {
        optimisticStart[occ.id] ?? occ.start
    }

    private func moveGesture(for occ: Occurrence, on day: Date, columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard occ.behavior == .event, occ.meeting != nil else { return }
                draggingEventID = occ.id
                dragOffsetY = value.translation.height
                dragDayShift = Int((value.translation.width / max(columnWidth, 1)).rounded())
            }
            .onEnded { value in
                guard draggingEventID == occ.id, occ.meeting != nil else { return }
                defer { draggingEventID = nil; dragOffsetY = 0; dragDayShift = 0 }
                finishMoveGesture(for: occ, on: day, translation: value.translation, columnWidth: columnWidth)
            }
    }

    private func finishMoveGesture(for occ: Occurrence, on day: Date, translation: CGSize, columnWidth: CGFloat) {
        guard let meeting = occ.meeting else { return }
        let dayShift = Int((translation.width / max(columnWidth, 1)).rounded())
        guard let newStart = draggedStart(for: occ, on: day,
                                                dy: translation.height, dayShift: dayShift),
              abs(newStart.timeIntervalSince(occ.start)) >= 60 else { return }

        // A repeating event has to ask before it writes: moving every future instance is
        // not something to infer from a drag.
        if smart.meetingRecurs(meeting) {
            pendingRecurringMove = PendingEventMove(meeting: meeting,
                                                    occurrenceID: occ.id,
                                                    newStart: newStart)
        } else {
            commitMove(meeting, occurrenceID: occ.id, to: newStart, span: .thisEvent)
        }
    }

    /// Where a drag landed: vertical pixels back into minutes on the five-minute grid the rest
    /// of the app authors on, plus whole-column steps for a day change.
    private func draggedStart(for occ: Occurrence, on _: Date, dy: CGFloat, dayShift: Int) -> Date? {
        CalendarMoveGeometry.start(original: occ.start, dayShift: dayShift,
                                   minutes: Double(dy / hourHeight) * 60, calendar: .current)
    }

    private func gridY(for date: Date, on day: Date) -> CGFloat {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let seconds = max(0, min(86_400, date.timeIntervalSince(start)))
        return CGFloat(seconds / 3_600) * hourHeight
    }

    /// A five-minute sliver between adjacent blocks is technically free but visually reads as a
    /// much larger invitation than it is. Join only same-lane neighbours; overlaps retain their
    /// honest independent geometry and all scheduling still uses the real timestamps.
    private func visualEnd(for placement: MacWeekPlacement, among placements: [MacWeekPlacement]) -> Date {
        let end = placement.occurrence.resolvedEnd
        guard let next = placements
            .filter({ $0.lane == placement.lane && $0.occurrence.start >= end })
            .min(by: { $0.occurrence.start < $1.occurrence.start }),
              next.occurrence.start.timeIntervalSince(end) <= 5 * 60
        else { return end }
        return next.occurrence.start
    }

    private func blockHeight(for occurrence: Occurrence, on day: Date, endingAt visualEnd: Date? = nil) -> CGFloat {
        var interval = DayColumn.visibleInterval(of: occurrence, on: day)
        if let visualEnd, visualEnd > interval.end {
            interval = DateInterval(start: interval.start, end: min(visualEnd, interval.end.addingTimeInterval(5 * 60)))
        }
        let seconds = max(15 * 60, interval.duration)
        // A time grid is a ruler: 2:30–3:00 and 3:00–3:30 must meet at 3:00. The old
        // decorative 2pt inset made adjacent commitments look like there was free time.
        return max(22, CGFloat(seconds / 3_600) * hourHeight)
    }

    private func laneWidth(totalWidth: CGFloat, lanes: Int) -> CGFloat {
        let inset: CGFloat = 4
        let gap: CGFloat = 2
        return max(8, (totalWidth - inset * 2 - gap * CGFloat(max(0, lanes - 1))) / CGFloat(lanes))
    }

    private func laneX(totalWidth: CGFloat, lane: Int, lanes: Int) -> CGFloat {
        4 + CGFloat(lane) * (laneWidth(totalWidth: totalWidth, lanes: lanes) + 2)
    }

    private func date(on day: Date, atGridY y: CGFloat) -> Date {
        let rawMinutes = Int((max(0, y) / hourHeight * 60 / 5).rounded()) * 5
        let minutes = min(23 * 60 + 55, rawMinutes)
        return Calendar.current.date(
            byAdding: .minute,
            value: minutes,
            to: Calendar.current.startOfDay(for: day)
        ) ?? day
    }

    private var visibleWeekStart: Date {
        let calendar = Calendar.app
        if dayMode {
            let today = calendar.startOfDay(for: Date())
            return calendar.date(byAdding: .day, value: weekOffset, to: today) ?? today
        }
        if weekSpan.isAlignedWeek {
            // The calendar week: honors the configured week start, pages by whole weeks,
            // and always contains today at offset 0.
            let current = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
                ?? calendar.startOfDay(for: Date())
            return calendar.date(byAdding: .weekOfYear, value: weekOffset, to: current) ?? current
        }
        // Rolling N-day window: today is the first column at offset 0 — no workweek
        // anchor games, so every span works on any day (weekends included) and the
        // Today button always lands on a view that contains today. Pages by its span.
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: weekOffset * weekSpan.rawValue, to: today) ?? today
    }

    /// The `weekOffset` whose page contains `date`, for "Go to …".
    private func periodOffset(to date: Date) -> Int {
        // The same calendar the grid pages with, so "week" honours the configured week start.
        let calendar = Calendar.app
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        if dayMode {
            return calendar.dateComponents([.day], from: today, to: target).day ?? 0
        }
        if weekSpan.isAlignedWeek {
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let targetWeek = calendar.dateInterval(of: .weekOfYear, for: target)?.start ?? target
            return calendar.dateComponents([.weekOfYear], from: thisWeek, to: targetWeek).weekOfYear ?? 0
        }
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        return Int((Double(days) / Double(weekSpan.rawValue)).rounded(.down))
    }

    private func moveWeek(_ delta: Int) {
        weekOffset += delta
        draftSelection = nil
        rebuild(occurrences.occurrences)
        Task { await refreshVisibleWeek() }
    }

    /// A booking push's tap: the booking's day, then its event, read again once if it isn't here
    /// yet. A cancelled one is only its day.
    private func openFromPush(_ target: BananaService.BookingPushTarget) async {
        if let start = target.start { moveWeek(periodOffset(to: start) - weekOffset) }
        guard !target.cancelled, target.eventID != nil else { return }
        var meeting = BookingPushes.meeting(for: target)
        if meeting == nil {
            await smart.refreshCalendar()
            await occurrences.recompute()
            meeting = BookingPushes.meeting(for: target)
        }
        guard let meeting else { return }
        if target.start == nil { moveWeek(periodOffset(to: meeting.start) - weekOffset) }
        MacNavigator.shared.inspectedMeeting = meeting
    }

    private func moveToCurrentWeek() {
        weekOffset = 0
        draftSelection = nil
        rebuild(occurrences.occurrences)
        Task { await refreshVisibleWeek() }
    }

    @MainActor
    private func refreshVisibleWeek() async {
        #if DEBUG
        // Fixture paging reads the same indexed window, but must never refresh real providers.
        guard !ProcessInfo.processInfo.arguments.contains("--ui-audit") else { return }
        #endif
        let visibleStart = visibleWeekStart
        let request = planningWindowRange(visibleStart: visibleStart)
        loading.set(true)
        await occurrences.refreshPlanningWindow(from: request.start, to: request.end)
        if visibleStart == visibleWeekStart {
            rebuild(occurrences.occurrences)
            loading.set(false)
        }
    }

    /// Day requests the same buffered four-day window as iPhone, so moving one day retains three
    /// days of usable cache while EventKit and Google backfill. Week keeps its exact visible span.
    private func planningWindowRange(visibleStart: Date) -> DateInterval {
        let calendar = Calendar.current
        let requestStart = dayMode
            ? (calendar.date(byAdding: .day, value: -1, to: visibleStart) ?? visibleStart)
            : visibleStart
        let requestDays = dayMode ? 4 : visibleDayCount
        let requestEnd = calendar.date(byAdding: .day, value: requestDays, to: requestStart)
            ?? requestStart.addingTimeInterval(TimeInterval(requestDays) * 86_400)
        return DateInterval(start: requestStart, end: requestEnd)
    }

    private func updateSelection(on day: Date, from value: DragGesture.Value) {
        let distance = abs(value.translation.height)
        if distance < 4 {
            draftSelection = MacGridSelection(
                day: day,
                // A click picks a slot, so it snaps to the nearest hour or half hour rather than
                // to whatever five-minute mark the pointer landed on.
                start: BookingGrid.snappedStart(on: day, atY: value.startLocation.y,
                                                hourHeight: hourHeight, rounding: .nearest),
                durationMinutes: 60
            )
            return
        }
        let top = min(value.startLocation.y, value.location.y)
        let bottom = max(value.startLocation.y, value.location.y)
        // The start snaps to the hour or half hour; the end keeps the finer grid so a drag can
        // still express an arbitrary length.
        let start = BookingGrid.snappedStart(on: day, atY: top, hourHeight: hourHeight, rounding: .down)
        // A dragged NEW booking sizes in quarter hours; five-minute precision is for adjusting an
        // event that already exists.
        let end = BookingGrid.snappedEnd(on: day, atY: bottom, hourHeight: hourHeight)
        let minutes = max(15, Int(end.timeIntervalSince(start) / 60))
        draftSelection = MacGridSelection(day: day, start: start, durationMinutes: minutes)
    }

    private func finishSelection(on day: Date, from value: DragGesture.Value) {
        updateSelection(on: day, from: value)
        guard let selection = draftSelection else { return }
        draftSelection = nil
        newEventRequest = MacNewEventRequest(
            start: selection.start,
            durationMinutes: selection.durationMinutes
        )
    }

    private enum GridRounding { case down, nearest, up }

    private func date(on day: Date, atGridY y: CGFloat, rounding: GridRounding) -> Date {
        // Fifths of an hour, i.e. 5-minute steps — the same grid `moveGesture`/`draggedStart`
        // already snaps existing events to.
        let fifths = max(0, y) / hourHeight * 12
        let roundedFifths: CGFloat
        switch rounding {
        case .down: roundedFifths = floor(fifths)
        case .nearest: roundedFifths = fifths.rounded()
        case .up: roundedFifths = ceil(fifths)
        }
        let minutes = min(23 * 60 + 55, Int(roundedFifths) * 5)
        return Calendar.current.date(
            byAdding: .minute,
            value: minutes,
            to: Calendar.current.startOfDay(for: day)
        ) ?? day
    }

    private func defaultNewEventStart() -> Date {
        let candidate = nextHalfHour()
        guard let end = Calendar.current.date(
                  byAdding: .day,
                  value: visibleDayCount,
                  to: visibleWeekStart
              ),
              candidate >= visibleWeekStart, candidate < end else {
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: visibleWeekStart)
                ?? visibleWeekStart
        }
        return candidate
    }

    private func nextHalfHour(from date: Date = Date()) -> Date {
        let interval: TimeInterval = 30 * 60
        let rounded = ceil(date.timeIntervalSinceReferenceDate / interval) * interval
        return Date(timeIntervalSinceReferenceDate: rounded)
    }

    private func blockTint(for occurrence: Occurrence) -> Color {
        switch occurrence.behavior {
        // The source calendar's own colour, as every calendar client does it. A flat blue for
        // everything made work, personal and shared events indistinguishable at a glance.
        case .event, .allDay: return sourceCalendarColor(occurrence, colors: smart.calendarColorHex) ?? DS.Palette.info
        case .task: return DS.Palette.task
        case .alarm: return DS.Palette.accent
        case .cue, .block: return occurrence.tint.color
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private var dateRangeTitle: String {
        guard let first = days.first?.date, let last = days.last?.date else { return "This week" }
        return Self.rangeFormatter.string(from: first, to: last)
    }

    private var verticalSeparator: some View {
        Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1)
    }

    private static let rangeFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dayIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}


private final class MacGridScrollBookkeeping {
    var offset: CGFloat = 0
}

private struct MacWeekDay: Identifiable, Equatable {
    let date: Date
    let isToday: Bool
    let items: [Occurrence]
    var id: Date { date }

    /// Only UNTIMED reminders belong in the row above the grid. One with a time is an
    /// appointment in every sense that matters — it gets drawn at that time, like everything
    /// else on a calendar. Listing it above the grid hid the one fact the grid exists to show.
    var reminders: [Occurrence] {
        items.filter { $0.behavior == .task && !$0.hasScheduledTime }
    }

    var scheduleSummary: String {
        let count = items.filter {
            $0.hasScheduledTime && $0.behavior != .block && $0.behavior != .task
        }.count
        return count == 0 ? "Open" : "\(count) scheduled"
    }
}

private typealias MacWeekPlacement = CalendarLaneAllocator.Placement

private struct MacNewEventRequest: Identifiable {
    let id = UUID()
    let start: Date
    let durationMinutes: Int
}

private struct MacGridSelection {
    let day: Date
    let start: Date
    let durationMinutes: Int

    /// "9:15 – 10:00" — what the draft is about to create, so the rectangle doesn't have to
    /// speak for itself.
    var rangeLabel: String { GridDraftSelection.rangeLabel(start: start, durationMinutes: durationMinutes) }
}

/// SwiftUI's `DragGesture` represents a click-and-drag on macOS; a two-finger trackpad swipe
/// arrives as a precise scroll-wheel event instead. Observe those events without consuming them,
/// so vertical calendar scrolling and click-drag event creation continue to work normally.
private struct MacHorizontalPeriodSwipe: NSViewRepresentable {
    let move: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.move = move
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.move = move
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var move: ((Int) -> Void)?

        private var eventMonitor: Any?
        private var swipe = CalendarMacPeriodSwipe()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }

        private func observe(_ event: NSEvent) {
            guard event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  event.hasPreciseScrollingDeltas else { return }

            let x = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaX : event.scrollingDeltaX
            if let direction = swipe.page(x: x, y: event.scrollingDeltaY, phase: event.phase,
                                          momentum: event.momentumPhase, timestamp: event.timestamp) {
                move?(direction)
            }
        }
    }
}
#endif

#if os(iOS)
private struct MobileNewEventRequest: Identifiable {
    let id = UUID()
    let start: Date
    let durationMinutes: Int
}

private struct MobileGridSelection: Identifiable {
    let day: Date
    let start: Date
    let durationMinutes: Int
    var id: String { "\(day.timeIntervalSinceReferenceDate)-\(start.timeIntervalSinceReferenceDate)" }

    var rangeLabel: String { GridDraftSelection.rangeLabel(start: start, durationMinutes: durationMinutes) }
}

/// A single UIKit scroll view owns Day-mode interaction, avoiding SwiftUI's competing nested
/// scroll and drag recognizers while keeping all per-frame movement inside UIKit.
/// A scroll offset kept without SwiftUI observing it: written every scroll frame, read only when
/// a pinch begins.
final class ScrollOffsetBox {
    var y: CGFloat = 0
    /// `y` when the current pinch began.
    var pinchStart: CGFloat = 0
}

/// Where to scroll while pinching, so the time that was between the fingers stays between them.
enum MobileZoom {
    static func offset(anchorHours: CGFloat, hourHeight: CGFloat, fingersAt onScreen: CGFloat,
                       contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let maximum = max(0, contentHeight - viewportHeight)
        return min(maximum, max(0, anchorHours * hourHeight - onScreen))
    }
}

/// Counts the fingers on the Day grid without taking part in any gesture: it never recognizes
/// and cancels nothing. Tells the zoom gate when the last one lifts — after a pinch the second
/// finger often stays down, then lifts over an event.
#if DEBUG && STRESS_DEVICE_AUDIT
private let calendarPressRace = ProcessInfo.processInfo.arguments.contains("--stress-calendar-press-race")
#else
private let calendarPressRace = false
#endif

private final class FingerCounter: UIGestureRecognizer {
    var onAllLifted: (() -> Void)?
    private var down = 0
    var tracksDayDrag = false
    private var startPoint: CGPoint?
    private var endPoint: CGPoint?
    private weak var movingTouch: UITouch?
    var dayTranslation: CGPoint? {
        guard let start = startPoint, let end = movingTouch?.location(in: nil) ?? endPoint else { return nil }
        return CGPoint(x: end.x - start.x, y: end.y - start.y)
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        down += touches.count
        if tracksDayDrag, down == 1, let touch = touches.first {
            movingTouch = touch
            startPoint = touch.location(in: nil)
            endPoint = nil
        } else {
            movingTouch = nil
            startPoint = nil
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let movingTouch, touches.contains(movingTouch) {
            endPoint = movingTouch.location(in: nil)
            self.movingTouch = nil
        }
        lift(touches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        movingTouch = nil
        startPoint = nil
        lift(touches.count)
    }

    private func lift(_ count: Int) {
        down = max(0, down - count)
        guard down == 0 else { return }
        onAllLifted?()
        state = .failed   // resets for the next touch
    }

    override func reset() {
        super.reset()
        down = 0
    }
}

struct CalendarColumnScrollConfiguration {
    var pagesBetweenDays = false
    let contentWidth: CGFloat
    let columnWidth: CGFloat
    let selectedColumn: Int
    let gutterWidth: CGFloat
    let gutter: AnyView
    let centerDay: Date
    let selectDay: (Date) -> Void
    let onHorizontalOffset: (CGFloat) -> Void
    let onColumnSettled: (Int) -> Void
}

struct DirectionalDayScrollView<Content: View>: UIViewRepresentable {
    let resetToken: String
    let contentHeight: CGFloat
    let initialOffset: CGFloat
    let onHorizontalSwipe: (Bool) -> Void
    /// False while an event is being dragged to a new time: its sideways drag moves it to another
    /// day and must not also turn the page.
    let canBeginSwipe: () -> Bool
    let onVerticalOffset: (CGFloat) -> Void
    let canBeginCreate: (CGPoint) -> Bool
    let onCreateChanged: (CGPoint, CGPoint) -> Void
    let onCreateEnded: (CGPoint, CGPoint) -> Void
    let onCreateCancelled: () -> Void
    /// The hour height drawn now, and how far a pinch may take it.
    let hourHeight: CGFloat
    let hourHeightRange: ClosedRange<CGFloat>
    /// The hour height while a pinch is under way, then the one it settled on.
    let onZoomChanged: (CGFloat) -> Void
    let onZoomEnded: (CGFloat) -> Void
    var nativeItems: [CalendarViewportItem]? = nil
    var week: CalendarColumnScrollConfiguration? = nil
    var preservesActiveGesture = false
    let content: Content

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            onHorizontalSwipe: onHorizontalSwipe,
            canBeginSwipe: canBeginSwipe,
            onVerticalOffset: onVerticalOffset,
            canBeginCreate: canBeginCreate,
            onCreateChanged: onCreateChanged,
            onCreateEnded: onCreateEnded,
            onCreateCancelled: onCreateCancelled)
        coordinator.onZoomChanged = onZoomChanged
        coordinator.onZoomEnded = onZoomEnded
        coordinator.hourHeightRange = hourHeightRange
        coordinator.hourHeight = hourHeight
        coordinator.week = week
        return coordinator
    }

    func makeUIView(context: Context) -> UIScrollView {
        context.coordinator.isUpdatingView = true
        defer { context.coordinator.isUpdatingView = false }
        let scrollView: UIScrollView = nativeItems == nil ? UIScrollView() : CalendarDayCollectionView()
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = week != nil
        scrollView.bottomEdgeEffect.isHidden = context.environment.bottomBarShell
        scrollView.isDirectionalLockEnabled = true
        scrollView.isMultipleTouchEnabled = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.backgroundColor = .systemBackground
        scrollView.delegate = context.coordinator
        #if DEBUG
        (scrollView as? CalendarDayCollectionView)?.columnSelectionAudit = { [weak coordinator = context.coordinator] in
            coordinator?.columnSelectionAudit ?? "coordinator released"
        }
        (scrollView as? CalendarDayCollectionView)?.pageAudit = { [weak coordinator = context.coordinator] in
            ["page": coordinator?.resetToken ?? "", "pageTransitions": coordinator?.pageTransitions ?? 0,
             "bodyEvaluations": RenderStats.lifetimeCount("WeekView"),
             "preparedDayWindows": RenderStats.lifetimeCount("Calendar.prepareDays"),
             "pinchStarts": coordinator?.pinchStarts ?? 0, "pinchUpdates": coordinator?.pinchUpdates ?? 0,
             "pinchEndScale": coordinator?.pinchEndScale ?? 1,
             "lastDayDrag": coordinator?.lastDayDrag ?? [:], "dayGestureHistory": coordinator?.dayGestureHistory ?? [],
             "dayMotion": coordinator?.dayMotion ?? [], "auditEpoch": Date().timeIntervalSince1970,
             "auditUptime": ProcessInfo.processInfo.systemUptime]
        }
        #endif

        let host = UIHostingController(rootView: AnyView(content.id(resetToken)))
        host.view.backgroundColor = .clear
        var height: NSLayoutConstraint?
        if let collection = scrollView as? CalendarDayCollectionView, let nativeItems {
            host.view.frame = CGRect(x: 0, y: 0, width: scrollView.bounds.width, height: contentHeight)
            collection.insertSubview(host.view, at: 0)
            collection.calendarBackground = host.view
            collection.apply(nativeItems, height: contentHeight, width: week?.contentWidth, environment: context.environment,
                             preservesActiveGesture: preservesActiveGesture)
        } else {
            host.view.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(host.view)
            let constraint = host.view.heightAnchor.constraint(equalToConstant: contentHeight)
            height = constraint
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
                constraint
            ])
        }

        let horizontalPan = UIPanGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.didPan(_:)))
        // Once a sideways swipe is under way, the touch is the swipe's: cancel it for the events
        // under the finger. Left uncancelled, a swipe that started on an event still reached that
        // event's tap on lift-off and opened it while the day changed.
        horizontalPan.cancelsTouchesInView = true
        horizontalPan.isEnabled = week == nil
        // One finger: it no longer runs alongside everything, so a two-finger pinch to zoom
        // must not be mistaken for a page swipe.
        horizontalPan.maximumNumberOfTouches = 1
        horizontalPan.delegate = context.coordinator
        scrollView.addGestureRecognizer(horizontalPan)
        let createLongPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didLongPressCreate(_:)))
        createLongPress.minimumPressDuration = 0.45
        createLongPress.allowableMovement = 10
        createLongPress.cancelsTouchesInView = false
        createLongPress.delegate = context.coordinator
        scrollView.addGestureRecognizer(createLongPress)
        // A quick drag moves beyond the long press's allowance immediately, so the native pan
        // begins normally. A deliberate hold recognizes first and keeps the following drag from
        // scrolling while it selects the event duration.
        if !calendarPressRace { scrollView.panGestureRecognizer.require(toFail: createLongPress) }
        if scrollView is CalendarDayCollectionView, CalendarDayCollectionView.nativeMovementEnabled {
            let eventPress = CalendarMovePressRecognizer(target: context.coordinator,
                action: #selector(Coordinator.didMoveEvent(_:)))
            eventPress.minimumPressDuration = 0.3
            eventPress.numberOfTouchesRequired = 1
            eventPress.allowableMovement = 10
            eventPress.cancelsTouchesInView = true
            eventPress.delegate = context.coordinator
            context.coordinator.eventPress = eventPress
            scrollView.addGestureRecognizer(eventPress)
            if !calendarPressRace { scrollView.panGestureRecognizer.require(toFail: eventPress) }
            (scrollView as? CalendarDayCollectionView)?.auditMove("registered")
        }
        // Pinch to zoom, anchored where the two fingers are: the time between them stays between
        // them. A SwiftUI magnification gesture over this view had no way to move the scroll, so
        // the day grew from its top and slid away under the fingers — and the scroll's own pan,
        // following the first finger down, dragged it further.
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.didPinch(_:)))
        pinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(pinch)
        // Knows when the last finger of a pinch is up, for the zoom gate (taps on events wait).
        let fingers = FingerCounter(target: nil, action: nil)
        fingers.onAllLifted = { GridZoom.gate.fingersLifted() }
        fingers.tracksDayDrag = week?.pagesBetweenDays == true
        context.coordinator.fingerCounter = fingers
        fingers.delegate = context.coordinator
        scrollView.addGestureRecognizer(fingers)
        context.coordinator.pinch = pinch
        context.coordinator.host = host
        context.coordinator.horizontalPan = horizontalPan
        context.coordinator.createLongPress = createLongPress
        context.coordinator.heightConstraint = height
        context.coordinator.resetToken = resetToken
        if let week, let collection = scrollView as? CalendarDayCollectionView {
            let gutter = UIHostingController(rootView: week.gutter)
            gutter.view.backgroundColor = .systemBackground
            gutter.view.layer.zPosition = 1000
            collection.addSubview(gutter.view)
            collection.frozenGutter = gutter.view
            collection.gutterWidth = week.gutterWidth
            context.coordinator.gutterHost = gutter
        }
        if let collection = scrollView as? CalendarDayCollectionView {
            collection.onRulerRepositioned = { [weak coordinator = context.coordinator, weak collection] offset in
                // Persist only after UIKit finishes geometry, and only if the user has not
                // moved again before the next turn of the main run loop.
                DispatchQueue.main.async {
                    if let collection, collection.contentOffset.y == offset { coordinator?.onVerticalOffset(offset) }
                }
            }
            collection.openingRulerOffset = initialOffset
            collection.prepareOpeningPosition = { [weak coordinator = context.coordinator] view in
                let maximum = max(0, view.contentSize.height - view.bounds.height)
                view.contentOffset.y = min(max(0, initialOffset), maximum)
                coordinator?.applySelectedColumn(view)
            }
        } else {
            DispatchQueue.main.async {
                scrollView.contentSize = CGSize(width: scrollView.bounds.width, height: contentHeight)
                scrollView.contentOffset.y = min(max(0, initialOffset),
                                                 max(0, contentHeight - scrollView.bounds.height))
            }
        }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        scrollView.bottomEdgeEffect.isHidden = context.environment.bottomBarShell
        context.coordinator.isUpdatingView = true
        defer { context.coordinator.isUpdatingView = false }
        let previousWeek = context.coordinator.week
        context.coordinator.week = week
        context.coordinator.fingerCounter?.tracksDayDrag = week?.pagesBetweenDays == true
        if let week {
            context.coordinator.gutterHost?.rootView = week.gutter
            (scrollView as? CalendarDayCollectionView)?.gutterWidth = week.gutterWidth
        }
        context.coordinator.onHorizontalSwipe = onHorizontalSwipe
        context.coordinator.canBeginSwipe = canBeginSwipe
        context.coordinator.onVerticalOffset = onVerticalOffset
        context.coordinator.canBeginCreate = canBeginCreate
        context.coordinator.onCreateChanged = onCreateChanged
        context.coordinator.onCreateEnded = onCreateEnded
        context.coordinator.onCreateCancelled = onCreateCancelled
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.onZoomEnded = onZoomEnded
        context.coordinator.hourHeightRange = hourHeightRange
        if !context.coordinator.isPinching { context.coordinator.hourHeight = hourHeight }
        let previousResetToken = context.coordinator.resetToken
        let pageChanged = previousResetToken != resetToken
        let preservedOffset = scrollView.contentOffset.y
        let shift = pageChanged ? context.coordinator.interruptedDayShift(to: resetToken, from: previousWeek) : nil
        let rebasedX = shift.map { scrollView.contentOffset.x - $0 }
        #if DEBUG
        if pageChanged { context.coordinator.recordRebase("page before", in: scrollView, shift: shift) }
        #endif
        if pageChanged {
            context.coordinator.resetToken = resetToken
            // A horizontal page gesture is an explicit request, not a background publication.
            // End any vertical coast exactly where it is so the destination day does not wait
            // for deceleration to finish while the fixed date header has already changed.
            if rebasedX == nil { scrollView.setContentOffset(scrollView.contentOffset, animated: false) }
            context.coordinator.pendingRoot = nil
            context.coordinator.resetColumnRequest()
        }
        // Always the current day. This used to be skipped unless a hand-kept token of the day's
        // inputs changed — and every input the token missed stayed stale on screen until you paged
        // away and back: the column's width (events squeezed to the left after a launch measured
        // it narrow), a blocker, a routine's look. SwiftUI diffs an unchanged tree cheaply, and
        // this only runs when the grid itself updated.
        let nextRoot = AnyView(content.id(resetToken))
        if !pageChanged && (scrollView.isDragging || scrollView.isDecelerating) {
            // Calendar and service publications may legitimately arrive during a flick. Keep
            // UIKit's active scroll entirely compositor-owned; swapping the hosted SwiftUI
            // tree mid-deceleration is exactly what made a native scroll hitch on every update.
            context.coordinator.pendingRoot = nextRoot
            if let collection = scrollView as? CalendarDayCollectionView, let nativeItems {
                let environment = context.environment
                context.coordinator.pendingCells = { [weak collection] in
                    collection?.apply(nativeItems, height: contentHeight, width: week?.contentWidth, environment: environment,
                                      preservesActiveGesture: preservesActiveGesture)
                }
            }
        } else {
            if pageChanged, week?.pagesBetweenDays != true, !UIAccessibility.isReduceMotionEnabled, let hostView = context.coordinator.host?.view {
                let transition = CATransition()
                transition.type = .push
                transition.subtype = resetToken > previousResetToken ? .fromRight : .fromLeft
                transition.duration = 0.18
                transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
                let pageView = scrollView is CalendarDayCollectionView ? scrollView : hostView
                pageView.layer.add(transition, forKey: "day-page")
                #if DEBUG
                if context.coordinator.auditColumns { context.coordinator.pageTransitions += 1 }
                #endif
            }
            context.coordinator.host?.rootView = nextRoot
            if let collection = scrollView as? CalendarDayCollectionView, let nativeItems {
                collection.apply(nativeItems, height: contentHeight, width: week?.contentWidth, environment: context.environment,
                                 preservesActiveGesture: preservesActiveGesture)
            }
            context.coordinator.pendingCells = nil
            context.coordinator.pendingRoot = nil
        }
        context.coordinator.heightConstraint?.constant = contentHeight
        // `UIHostingController` does not always propagate its intrinsic height through a
        // UIScrollView's content layout guide. The calendar has a fixed ruler, so state the
        // scroll range directly instead of asking UIKit to infer it.
        scrollView.contentSize = CGSize(width: week?.contentWidth ?? scrollView.bounds.width, height: contentHeight)
        context.coordinator.applySelectedColumn(scrollView, preservingX: rebasedX)
        if let shift { context.coordinator.rebasePan(in: scrollView, by: shift) }
        guard pageChanged else { return }
        #if DEBUG
        context.coordinator.recordRebase("page after", in: scrollView, shift: shift)
        #endif
        let maximum = max(0, contentHeight - scrollView.bounds.height)
        // Preserve the scroll view's live position in the same update transaction as the host
        // replacement. Dispatching this to the next run-loop turn exposed a one-frame jump to the
        // top on dense days and made a preserved position look reset.
        let targetOffset = min(maximum, max(0, preservedOffset))
        let targetPoint = CGPoint(x: week == nil ? 0 : scrollView.contentOffset.x, y: targetOffset)
        if scrollView.contentOffset != targetPoint { scrollView.setContentOffset(targetPoint, animated: false) }
        onVerticalOffset(targetOffset)
        context.coordinator.pendingWeekPage = nil
        context.coordinator.continueDayCoastIfNeeded(in: scrollView)
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.cancelActiveEventMove()
        coordinator.eventPress?.isEnabled = false
        coordinator.week = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UICollectionViewDelegate {
        // The hosted view does not retain its view controller. This must be strong or the
        // controller dies after `makeUIView`, making every later day update a silent no-op.
        var host: UIHostingController<AnyView>?
        var gutterHost: UIHostingController<AnyView>?
        var week: CalendarColumnScrollConfiguration?
        // MARK: Header offset delivery
        var isUpdatingView = false
        private var pendingHorizontalOffset: CGFloat?
        private var horizontalDeliveryScheduled = false
        private let referenceHeaderPublication: Bool = {
            #if DEBUG
            ProcessInfo.processInfo.arguments.contains("--calendar-reference-header-publication")
            #else
            false
            #endif
        }()
        private func sendHorizontalOffset(_ x: CGFloat, programmatic: Bool = false) {
            guard let week else { return }
            guard (isUpdatingView || programmatic) && !referenceHeaderPublication else {
                // A real drag supersedes any older programmatic offset still queued.
                pendingHorizontalOffset = nil
                week.onHorizontalOffset(x)
                return
            }
            pendingHorizontalOffset = x
            guard !horizontalDeliveryScheduled else { return }
            horizontalDeliveryScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.horizontalDeliveryScheduled = false
                guard let pending = self.pendingHorizontalOffset else { return }
                self.pendingHorizontalOffset = nil
                self.week?.onHorizontalOffset(pending)
            }
        }
        // MARK: Selected column geometry
        private var requestedColumn: Int?
        private var appliedViewportWidth: CGFloat = 0
        private var appliedColumnWidth: CGFloat = 0
        private var appliedContentWidth: CGFloat = 0
        private var dragStart = CGPoint.zero
        private var horizontalDayAnchorY: CGFloat?
        // The intended date survives an interrupted coast. A column index alone becomes
        // ambiguous as soon as the same three native columns are reused for the next day.
        private var dragOriginDay: Date?
        private var settlingDay: Date?
        private var interruptedDay: Date?
        private var continuingFromDay: Date?
        private var panTranslationAdjustment: CGFloat = 0

        // UIKit keeps the offset at touch-down as its pan origin. Recentring a recycled
        // date must move the recognizer's coordinates too, or its next input jumps a day.
        func rebasePan(in scrollView: UIScrollView, by shift: CGFloat) {
            let pan = scrollView.panGestureRecognizer
            guard pan.state == .began || pan.state == .changed else { return }
            var translation = pan.translation(in: scrollView)
            translation.x += shift
            pan.setTranslation(translation, in: scrollView)
            panTranslationAdjustment += shift
        }

        func interruptedDayShift(to page: String, from previous: CalendarColumnScrollConfiguration?) -> CGFloat? {
            if let continuingFromDay, page == Occurrence.dayKey(continuingFromDay) { return nil }
            continuingFromDay = nil
            guard let target = interruptedDay, let previous, let week,
                  page == Occurrence.dayKey(target),
                  previous.columnWidth == week.columnWidth else {
                interruptedDay = nil
                dragOriginDay = nil
                settlingDay = nil
                return nil
            }
            interruptedDay = nil
            let columns = Calendar.app.dateComponents([.day], from: previous.centerDay, to: target).day ?? 0
            let shift = CGFloat(columns) * week.columnWidth
            dragStart.x -= shift
            return shift
        }

        var pendingWeekPage: Int?
        func resetColumnRequest() { requestedColumn = nil }
        #if DEBUG
        private var columnTransitions: [String] = []
        fileprivate let auditColumns = ProcessInfo.processInfo.arguments.contains("--calendar-viewport-audit")
        fileprivate var pageTransitions = 0
        fileprivate var pinchStarts = 0
        fileprivate var pinchUpdates = 0
        fileprivate var pinchEndScale: CGFloat = 1
        fileprivate var lastDayDrag: [String: Double] = [:]
        fileprivate var dayGestureHistory: [[String: Any]] = []
        private let tracesFlicks = ProcessInfo.processInfo.arguments.contains("--calendar-flick-trace")
        private var remainingRebaseSamples = 0
        fileprivate var dayMotion: [[Double]] = []
        private var tracksDayMotion = false
        // Only the signed stress test requests per-scroll coordinates. Day identity and
        // offset together show whether rotating the three columns moved the user's date.
        private func recordDayMotion(in view: UIScrollView) {
            guard tracesFlicks, tracksDayMotion, let week, week.pagesBetweenDays else { return }
            if dayMotion.count >= 400 { dayMotion.removeFirst(100) }
            dayMotion.append([ProcessInfo.processInfo.systemUptime, week.centerDay.timeIntervalSince1970,
                              view.contentOffset.x, view.layer.presentation()?.bounds.minX ?? view.contentOffset.x,
                              view.panGestureRecognizer.translation(in: view).x - panTranslationAdjustment, week.columnWidth])
        }
        func recordRebase(_ phase: String, in view: UIScrollView, shift: CGFloat?) {
            guard tracesFlicks else { return }
            recordDayGesture(phase, in: view)
            if shift != nil, phase == "page after" { remainingRebaseSamples = 3 }
            if let shift, !dayGestureHistory.isEmpty { dayGestureHistory[dayGestureHistory.count - 1]["shift"] = shift }
        }
        private func recordDayGesture(_ phase: String, in view: UIScrollView) {
            guard tracesFlicks, week?.pagesBetweenDays == true else { return }
            if dayGestureHistory.count == 160 { dayGestureHistory.removeFirst(80) }
            dayGestureHistory.append(["phase": phase, "time": ProcessInfo.processInfo.systemUptime,
                                      "page": resetToken, "x": view.contentOffset.x, "y": view.contentOffset.y,
                                      "dx": view.panGestureRecognizer.translation(in: view).x - panTranslationAdjustment,
                                      "origin": dragOriginDay.map { Occurrence.dayKey($0) } ?? "",
                                      "destination": settlingDay.map { Occurrence.dayKey($0) } ?? "",
                                      "center": week.map { Occurrence.dayKey($0.centerDay) } ?? ""])
        }

        private let referenceDayDeceleration =
            ProcessInfo.processInfo.arguments.contains("--calendar-reference-day-deceleration")

        private func traceColumn(_ message: @autoclosure () -> String) {
            if auditColumns && columnTransitions.count < 64 { columnTransitions.append(message()) }
        }
        var columnSelectionAudit: String {
            "transitions=\(columnTransitions);selected=\(week?.selectedColumn ?? -1);requested=\(requestedColumn ?? -1);viewport=\(appliedViewportWidth);column=\(appliedColumnWidth);content=\(appliedContentWidth)"
        }
        #endif
        func applySelectedColumn(_ scrollView: UIScrollView, preservingX: CGFloat? = nil) {
            guard let week, scrollView.bounds.width > 0 else { return }
            guard requestedColumn != week.selectedColumn
                    || appliedViewportWidth != scrollView.bounds.width
                    || appliedColumnWidth != week.columnWidth
                    || appliedContentWidth != week.contentWidth else { return }
            #if DEBUG
            traceColumn("apply selected=\(week.selectedColumn) offset=\(scrollView.contentOffset) bounds=\(scrollView.bounds) content=\(scrollView.contentSize)")
            #endif
            requestedColumn = week.selectedColumn
            appliedViewportWidth = scrollView.bounds.width
            appliedColumnWidth = week.columnWidth
            appliedContentWidth = week.contentWidth
            let x = min(max(0, preservingX ?? CGFloat(week.selectedColumn) * week.columnWidth),
                        max(0, week.contentWidth - scrollView.bounds.width))
            scrollView.setContentOffset(CGPoint(x: x, y: scrollView.contentOffset.y), animated: false)
            #if DEBUG
            traceColumn("applied target=\(x) actual=\(scrollView.contentOffset)")
            #endif
            sendHorizontalOffset(x, programmatic: true)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            #if DEBUG
            recordDayMotion(in: scrollView)
            if remainingRebaseSamples > 0, !isUpdatingView {
                remainingRebaseSamples -= 1
                recordDayGesture("scroll after rebase", in: scrollView)
            }
            traceColumn("scroll offset=\(scrollView.contentOffset) content=\(scrollView.contentSize) bounds=\(scrollView.bounds.size) updating=\(isUpdatingView) tracking=\(scrollView.isTracking)")
            #endif
            (scrollView as? CalendarDayCollectionView)?.updatePinnedGutter()
            // UIKit can adjust offsets during SwiftUI's layout, after updateUIView returns.
            // Only actual scrolling input/coasting requires synchronous header feedback.
            sendHorizontalOffset(scrollView.contentOffset.x,
                                 programmatic: !scrollView.isTracking && !scrollView.isDragging && !scrollView.isDecelerating)
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            dragStart = scrollView.contentOffset
            horizontalDayAnchorY = nil
            dragOriginDay = nil
            panTranslationAdjustment = 0
            #if DEBUG
            remainingRebaseSamples = 0
            #endif
            guard let week, week.pagesBetweenDays else { return }
            // A date snaps to a column. Scrolling through hours keeps the usual vertical coast.
            let pan = scrollView.panGestureRecognizer
            let speed = pan.velocity(in: scrollView)
            let translation = pan.translation(in: scrollView)
            let direction = speed == .zero ? translation : speed
            let horizontal = abs(direction.x) > abs(direction.y)
            scrollView.decelerationRate = horizontal ? .fast : .normal
            let previous = settlingDay
            settlingDay = nil
            dragOriginDay = horizontal ? previous ?? week.centerDay : nil
            continuingFromDay = nil
            if horizontal, let previous, previous != week.centerDay {
                // The finger can overtake the native coast. Rotate only when the same
                // piece of both dates still fits in the three-column viewport.
                let step = previous > week.centerDay ? 1 : -1
                let x = scrollView.contentOffset.x - CGFloat(step) * week.columnWidth
                let maximum = week.contentWidth - scrollView.bounds.width
                // When the finger reverses it is heading back into dates we already
                // display. Rotating toward the old destination can move it past the
                // edge between this callback and SwiftUI's update of the three columns.
                if direction.x * CGFloat(step) < 0, x >= 0, x <= maximum,
                   let next = Calendar.app.date(byAdding: .day, value: step, to: week.centerDay) {
                    interruptedDay = next
                    week.selectDay(next)
                }
            }
            #if DEBUG
            if tracesFlicks, horizontal {
                if !tracksDayMotion { dayMotion.removeAll(keepingCapacity: true) }
                tracksDayMotion = true
                recordDayMotion(in: scrollView)
            }
            recordDayGesture("began", in: scrollView)
            if referenceDayDeceleration { scrollView.decelerationRate = .normal }
            #endif
        }
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                      targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard let week else { return }
            let maximum = max(0, week.contentWidth - scrollView.bounds.width)
            var translation = scrollView.panGestureRecognizer.translation(in: scrollView)
            translation.x -= panTranslationAdjustment
            // The pan can be recognized after much of a fast drag is already over. Use the
            // single finger's window coordinates so that movement still counts after a rebase.
            if week.pagesBetweenDays, let actual = fingerCounter?.dayTranslation { translation = actual }
            if week.pagesBetweenDays, abs(translation.x) > abs(translation.y),
               !isPinching, eventMove == nil, scrollView.panGestureRecognizer.state != .cancelled {
                // Selecting another date keeps the hour under the finger. UIKit can otherwise
                // propose a small vertical adjustment even for a straight horizontal drag.
                horizontalDayAnchorY = dragStart.y
                targetContentOffset.pointee.y = dragStart.y
            }
            if !week.pagesBetweenDays, pendingWeekPage == nil, !isPinching, eventMove == nil, canBeginSwipe(),
               scrollView.panGestureRecognizer.state != .cancelled,
               let page = CalendarWeekEdge.page(start: dragStart.x, offset: scrollView.contentOffset.x,
                    maximum: maximum, width: scrollView.bounds.width,
                    translation: translation) {
                pendingWeekPage = page
                targetContentOffset.pointee = CGPoint(x: page > 0 ? maximum : 0, y: scrollView.contentOffset.y)
                let token = resetToken
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self else { return }
                    guard self.resetToken == token, self.week != nil,
                          self.pendingWeekPage == page, !self.isPinching,
                          self.eventMove == nil, self.canBeginSwipe() else {
                        self.pendingWeekPage = nil; return
                    }
                    if let scrollView { self.onVerticalOffset(scrollView.contentOffset.y) }
                    self.onHorizontalSwipe(page > 0)
                }
                return
            }
            let current: CGFloat
            if let origin = dragOriginDay, horizontalDayAnchorY != nil {
                let delta = Calendar.app.dateComponents([.day], from: week.centerDay, to: origin).day ?? 0
                current = CGFloat(week.selectedColumn + delta)
            } else {
                current = (dragStart.x / week.columnWidth).rounded()
            }
            var proposed = (targetContentOffset.pointee.x / week.columnWidth).rounded()
            if horizontalDayAnchorY != nil,
               abs(translation.x) > 44, abs(velocity.x) > abs(velocity.y),
               velocity.x * translation.x < 0, abs(velocity.x) >= 0.3 {
                // A decisive lateral flick advances one date, including on a wide viewport.
                // The native deceleration rate determines how that date settles into place.
                proposed = current + (velocity.x > 0 ? 1 : -1)
            }
            #if DEBUG
            recordDayGesture("released", in: scrollView)
            if auditColumns, horizontalDayAnchorY != nil {
                lastDayDrag = ["release": ProcessInfo.processInfo.systemUptime,
                               "panDX": scrollView.panGestureRecognizer.translation(in: scrollView).x - panTranslationAdjustment,
                               "from": current,
                               "proposed": proposed, "dx": translation.x, "vx": velocity.x,
                               "rate": Double(scrollView.decelerationRate.rawValue)]
            }
            #endif
            let column = min(current + 1, max(current - 1, proposed))
            if horizontalDayAnchorY != nil {
                settlingDay = Calendar.app.date(byAdding: .day, value: Int(column) - week.selectedColumn, to: week.centerDay)
            }
            targetContentOffset.pointee.x = min(max(0, column * week.columnWidth),
                                                max(0, week.contentWidth - scrollView.bounds.width))
        }
        private func settledColumn(_ scrollView: UIScrollView) {
            guard pendingWeekPage == nil, let week else { return }
            let index = Int((max(0, scrollView.contentOffset.x) / week.columnWidth).rounded())
            requestedColumn = index
            week.onColumnSettled(index)
        }
        var heightConstraint: NSLayoutConstraint?
        var resetToken = ""
        var pendingRoot: AnyView?
        var pendingCells: (() -> Void)?
        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            if cell.contentConfiguration == nil {
                (collectionView as? CalendarDayCollectionView)?.configure(cell, at: indexPath)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            // Retiring a cell also cancels its artwork task/releases its consumer image lease.
            cell.contentConfiguration = nil
        }
        var onHorizontalSwipe: (Bool) -> Void
        var canBeginSwipe: () -> Bool
        var onVerticalOffset: (CGFloat) -> Void
        var canBeginCreate: (CGPoint) -> Bool
        var onCreateChanged: (CGPoint, CGPoint) -> Void
        var onCreateEnded: (CGPoint, CGPoint) -> Void
        var onCreateCancelled: () -> Void
        fileprivate weak var fingerCounter: FingerCounter?
        weak var horizontalPan: UIPanGestureRecognizer?
        weak var createLongPress: UILongPressGestureRecognizer?
        weak var eventPress: UILongPressGestureRecognizer?
        private var eventMove: (target: CalendarViewportMove, start: CGPoint)?
        weak var pinch: UIPinchGestureRecognizer?
        private var createStart: CGPoint?
        var onZoomChanged: (CGFloat) -> Void = { _ in }
        var onZoomEnded: (CGFloat) -> Void = { _ in }
        var hourHeightRange: ClosedRange<CGFloat> = 44...160
        /// The hour height on screen — the pinch's own while it runs, SwiftUI's otherwise.
        var hourHeight: CGFloat = 56
        private(set) var isPinching = false
        private var pinchBase: CGFloat = 56
        /// The time under the fingers when the pinch began, in hours from the top of the grid.
        private var pinchAnchorHours: CGFloat = 0

        init(
            onHorizontalSwipe: @escaping (Bool) -> Void,
            canBeginSwipe: @escaping () -> Bool,
            onVerticalOffset: @escaping (CGFloat) -> Void,
            canBeginCreate: @escaping (CGPoint) -> Bool,
            onCreateChanged: @escaping (CGPoint, CGPoint) -> Void,
            onCreateEnded: @escaping (CGPoint, CGPoint) -> Void,
            onCreateCancelled: @escaping () -> Void
        ) {
            self.onHorizontalSwipe = onHorizontalSwipe
            self.canBeginSwipe = canBeginSwipe
            self.onVerticalOffset = onVerticalOffset
            self.canBeginCreate = canBeginCreate
            self.onCreateChanged = onCreateChanged
            self.onCreateEnded = onCreateEnded
            self.onCreateCancelled = onCreateCancelled
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The finger counter only watches; nothing may cancel it.
            if gestureRecognizer is FingerCounter || otherGestureRecognizer is FingerCounter { return true }
            if calendarPressRace, let pan = (createLongPress?.view as? UIScrollView)?.panGestureRecognizer,
               (gestureRecognizer === pan && otherGestureRecognizer === createLongPress ||
                otherGestureRecognizer === pan && gestureRecognizer === createLongPress) {
                return false
            }
            if gestureRecognizer === eventPress || otherGestureRecognizer === eventPress {
                if CalendarDayCollectionView.simultaneousMovementEnabled { return true }
                // A second finger can turn a hold into a pinch; pinch startup cancels the move.
                return gestureRecognizer === pinch || otherGestureRecognizer === pinch
            }
            // The page swipe shares the touch with the vertical scroll and the create press only.
            // Sharing it with everything let a block's button, under the finger where the swipe
            // began, still take the lift-off as a tap and open while the day changed.
            guard gestureRecognizer === horizontalPan || otherGestureRecognizer === horizontalPan else { return true }
            let partner = gestureRecognizer === horizontalPan ? otherGestureRecognizer : gestureRecognizer
            return partner === (horizontalPan?.view as? UIScrollView)?.panGestureRecognizer
                || partner === createLongPress
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === eventPress {
                (gestureRecognizer.view as? CalendarDayCollectionView)?.auditMove("shouldBegin pinching=\(isPinching) gate=\(GridZoom.gate.allowsTap())")
                guard !isPinching, GridZoom.gate.allowsTap() else { return false }
                guard let collection = gestureRecognizer.view as? CalendarDayCollectionView else { return false }
                return collection.moveTarget(at: gestureRecognizer.location(in: collection)) != nil
            }
            if gestureRecognizer === createLongPress {
                if let collection = gestureRecognizer.view as? CalendarDayCollectionView,
                   collection.frozenGutter?.frame.contains(gestureRecognizer.location(in: collection)) == true {
                    return false
                }
                return canBeginCreate(gestureRecognizer.location(in: gestureRecognizer.view))
            }
            guard gestureRecognizer === horizontalPan,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            guard eventMove == nil, canBeginSwipe() else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.25
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === eventPress {
                (gestureRecognizer.view as? CalendarDayCollectionView)?.auditMove(
                    "received at \(touch.location(in: gestureRecognizer.view)) view=\(String(describing: touch.view))")
            }
            return true
        }

        @objc func didMoveEvent(_ recognizer: UILongPressGestureRecognizer) {
            guard let collection = recognizer.view as? CalendarDayCollectionView else { return }
            let point = recognizer.location(in: collection)
            collection.auditMove("state=\(recognizer.state.rawValue) point=\(point)")
            switch recognizer.state {
            case .began:
                guard let target = collection.moveTarget(at: point) else { return }
                eventMove = (target, point)
                if CalendarDayCollectionView.localMovementFeedbackEnabled {
                    collection.beginMovePreview(target)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    target.changed(.zero)
                }
            case .changed, .ended:
                guard let move = eventMove else { return }
                guard collection.containsMoveTarget(move.target.id) else {
                    eventMove = nil
                    collection.cancelMovePreview()
                    move.target.cancelled()
                    return
                }
                let translation = CGSize(width: point.x - move.start.x, height: point.y - move.start.y)
                if recognizer.state == .ended {
                    eventMove = nil
                    if CalendarDayCollectionView.localMovementFeedbackEnabled {
                        collection.finishMovePreview()
                        if !move.target.ended(translation) { collection.cancelMovePreview() }
                    } else {
                        _ = move.target.ended(translation)
                    }
                } else if CalendarDayCollectionView.localMovementFeedbackEnabled {
                    collection.updateMovePreview(move.target, translation: translation)
                } else {
                    move.target.changed(translation)
                }
            case .cancelled, .failed:
                let move = eventMove
                eventMove = nil
                collection.cancelMovePreview()
                move?.target.cancelled()
            default:
                break
            }
        }

        func cancelActiveEventMove() {
            (eventPress?.view as? CalendarDayCollectionView)?.cancelMovePreview()
            let move = eventMove
            eventMove = nil
            move?.target.cancelled()
        }

        @objc func didLongPressCreate(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                createStart = point
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onCreateChanged(point, point)
            case .changed:
                guard let createStart else { return }
                onCreateChanged(createStart, point)
            case .ended:
                guard let createStart else { return }
                self.createStart = nil
                onCreateEnded(createStart, point)
            case .cancelled, .failed:
                createStart = nil
                onCreateCancelled()
            default:
                break
            }
        }

        @objc func didPinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView, recognizer.numberOfTouches >= 2
                    || recognizer.state == .ended || recognizer.state == .cancelled else { return }
            let point = recognizer.location(in: scrollView)            // in the grid
            let onScreen = point.y - scrollView.contentOffset.y          // in the viewport
            switch recognizer.state {
            case .began:
                // The pinch owns the touch now: stop the scroll the first finger started, which
                // is what dragged the day to wherever that finger landed.
                cancelActiveEventMove()
                scrollView.panGestureRecognizer.isEnabled = false
                scrollView.panGestureRecognizer.isEnabled = true
                GridZoom.gate.pinchChanged()
                horizontalDayAnchorY = nil
                isPinching = true
                pinchBase = hourHeight
                #if DEBUG
                if auditColumns { pinchStarts += 1 }
                #endif
                pinchAnchorHours = point.y / max(1, hourHeight)
            case .changed:
                guard isPinching else { return }
                GridZoom.gate.pinchChanged()
                let height = min(hourHeightRange.upperBound,
                                 max(hourHeightRange.lowerBound, pinchBase * recognizer.scale))
                #if DEBUG
                if auditColumns { pinchUpdates += 1 }
                #endif
                let hours = (heightConstraint?.constant ?? scrollView.contentSize.height) / max(1, hourHeight)
                hourHeight = height
                // Size the grid now, in this frame, so the offset below isn't clamped to the old
                // height; SwiftUI redraws the hours to match a moment later.
                let contentHeight = hours * height
                heightConstraint?.constant = contentHeight
                scrollView.contentSize = CGSize(width: week?.contentWidth ?? scrollView.bounds.width, height: contentHeight)
                scrollView.contentOffset.y = MobileZoom.offset(anchorHours: pinchAnchorHours, hourHeight: height,
                                                               fingersAt: onScreen, contentHeight: contentHeight,
                                                               viewportHeight: scrollView.bounds.height)
                onZoomChanged(height)
            case .ended, .cancelled, .failed:
                guard isPinching else { return }
                isPinching = false
                #if DEBUG
                if auditColumns { pinchEndScale = recognizer.scale }
                #endif
                onZoomEnded(hourHeight)
                onVerticalOffset(scrollView.contentOffset.y)
            default:
                break
            }
        }

        @objc func didPan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let translation = recognizer.translation(in: recognizer.view)
            if abs(translation.x) > 44 {
                if let scrollView = recognizer.view as? UIScrollView {
                    onVerticalOffset(scrollView.contentOffset.y)
                }
                onHorizontalSwipe(translation.x < 0)
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishScroll(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishScroll(scrollView)
        }

        private func finishScroll(_ scrollView: UIScrollView) {
            if isUpdatingView {
                // Scrolling stopped inside a SwiftUI update. The pending root and the settled
                // offset must still land: finish once the update returns, unless a new drag
                // has started (its own end finishes it).
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView, !self.isUpdatingView,
                          !scrollView.isDragging, !scrollView.isDecelerating else { return }
                    self.finishScroll(scrollView)
                }
                return
            }
            guard scrollView.panGestureRecognizer.state != .changed,
                  scrollView.panGestureRecognizer.state != .began else { return }
            let destination = settlingDay
            if let destination, let week, week.pagesBetweenDays {
                let delta = Calendar.app.dateComponents([.day], from: week.centerDay, to: destination).day ?? 0
                if abs(delta) > 1,
                   let next = Calendar.app.date(byAdding: .day, value: delta > 0 ? 1 : -1, to: week.centerDay) {
                    // Several flicks can ask for a date beyond the visible neighbors.
                    // Reuse the neighbor that just arrived and coast the remaining distance.
                    continuingFromDay = next
                    week.selectDay(next)
                    return
                }
            }
            settlingDay = nil
            dragOriginDay = nil
            applyPendingRoot()
            if let anchor = horizontalDayAnchorY {
                #if DEBUG
                recordDayMotion(in: scrollView)
                tracksDayMotion = false
                recordDayGesture("settled", in: scrollView)
                if auditColumns { lastDayDrag["settled"] = ProcessInfo.processInfo.systemUptime }
                #endif
                horizontalDayAnchorY = nil
                let y = min(max(0, anchor), max(0, scrollView.contentSize.height - scrollView.bounds.height))
                if y != scrollView.contentOffset.y { scrollView.contentOffset.y = y }
            }
            onVerticalOffset(scrollView.contentOffset.y)
            if let destination, let week, week.pagesBetweenDays {
                if destination != week.centerDay { week.selectDay(destination) }
                else { resetColumnRequest(); applySelectedColumn(scrollView) }
            } else {
                settledColumn(scrollView)
            }
        }

        func continueDayCoastIfNeeded(in scrollView: UIScrollView) {
            guard let week, let page = continuingFromDay, page == week.centerDay,
                  let destination = settlingDay else { return }
            continuingFromDay = nil
            let column = week.selectedColumn + (destination > page ? 1 : -1)
            let target = CGPoint(x: CGFloat(column) * week.columnWidth, y: scrollView.contentOffset.y)
            scrollView.setContentOffset(target, animated: true)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            if settlingDay != nil { finishScroll(scrollView) }
        }

        private func applyPendingRoot() {
            guard let pendingRoot else { return }
            host?.rootView = pendingRoot
            self.pendingRoot = nil
            pendingCells?()
            pendingCells = nil
        }
    }
}
#endif

/// The week planner: a 7‑day agenda from the unified occurrence timeline with the same
/// interactive rows as Today, plus a live switcher for four ways of showing duration.
/// An environment value passes the installed Smart Schedule instance down for actions and narrow
/// publisher subscriptions without making the entire 24-hour grid an `@EnvironmentObject`
/// observer. Identity equality also stops an unrelated parent rebuild from changing the value.
struct WeekSmartStoreReference: Equatable {
    let store: SmartScheduleStore?

    init(_ store: SmartScheduleStore? = nil) { self.store = store }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.store === rhs.store }
}

private struct WeekSmartStoreKey: EnvironmentKey {
    static let defaultValue = WeekSmartStoreReference()
}

/// The alarm store for actions only (cancelling a one-off alarm), without making the grid an
/// observer: the store republishes several times at launch (permission, the armed wake list),
/// and each one redrew the whole Day grid for nothing it shows.
struct AlarmStoreReference: Equatable {
    let store: AlarmStore?

    init(_ store: AlarmStore? = nil) { self.store = store }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.store === rhs.store }
}

private struct AlarmStoreKey: EnvironmentKey {
    static let defaultValue = AlarmStoreReference()
}

extension EnvironmentValues {
    var weekSmartStore: WeekSmartStoreReference {
        get { self[WeekSmartStoreKey.self] }
        set { self[WeekSmartStoreKey.self] = newValue }
    }

    var alarmStore: AlarmStoreReference {
        get { self[AlarmStoreKey.self] }
        set { self[AlarmStoreKey.self] = newValue }
    }
}

#if os(iOS)
/// Held via plain `@State` (not `@ObservedObject`) on WeekView, so a per-scroll-frame write to
/// `.x` invalidates only the small subview that observes it (`MobileDayHeaderStrip`) rather than
/// WeekView's whole body — and with it the entire 7-column grid it would otherwise re-diff on
/// every frame of a horizontal scroll.
private final class HeaderScrollOffset: ObservableObject {
    private struct Position: Equatable { var x: CGFloat = 0; var stretch: CGFloat = 0 }
    @Published private var position = Position()
    var x: CGFloat {
        get { position.x }
        set { set(x: newValue, stretch: 0) }
    }
    var stretch: CGFloat { position.stretch }
    func set(x: CGFloat, stretch: CGFloat) {
        let next = Position(x: x, stretch: stretch)
        if next != position { position = next }
    }
}

/// The week header's day-letter/day-number strip, extracted out of WeekView's body so that
/// tracking the day-columns scroller's live offset only re-renders this 44pt view, not the whole
/// 7-column grid underneath it. Stays pixel-locked to the columns via `offset`.
/// The week's all-day events, each under its own day's column and scrolling with the header
/// strip above (`MobileDayHeaderStrip`): solid when it blocks the day, outlined when Free; two
/// per day, then "+N".
private struct MobileAllDayStrip: View {
    let days: [WeekView.DayData]
    let dayWidth: CGFloat
    @ObservedObject var offset: HeaderScrollOffset
    let tint: (Occurrence) -> Color
    let onOpen: (Occurrence) -> Void
    let onBlock: (Occurrence, Bool) -> Void
    @State private var position = ScrollPosition()
    /// The day whose whole list is open, from its "+N more".
    @State private var showingAll: Int?

    /// How many of a day's fit in the strip; the rest are behind "+N more".
    private static let limit = 2

    /// All-day calendar events stay under their dates; routines share the selected day's
    /// reminders band. Blocking events stay first and outside the overflow.
    private func events(_ day: WeekView.DayData) -> [Occurrence] {
        AllDayEvents.busyFirst(day.items.filter { $0.behavior == .allDay }, blocks: \.blocksWholeDay)
    }

    /// Tall enough for the busiest day: two chips, and a "+N more" line when one has more.
    private var height: CGFloat {
        let counts = days.map { events($0).count }
        let chips = CGFloat(min(Self.limit, counts.max() ?? 0))
        return 6 + chips * 18 + max(0, chips - 1) * 2 + (counts.contains { $0 > Self.limit } ? 20 : 0)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(days) { day in
                    let fitting = AllDayEvents.fitting(events(day), limit: Self.limit)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(fitting.shown) { chip($0) }
                        if fitting.more > 0 {
                            // The rest of the day's, a tap away: a line that said how many and
                            // opened nothing left them out of reach from the week.
                            Button { showingAll = day.id } label: {
                                Text("+\(fitting.more) more")
                                    .font(DS.Typeface.small(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 3)
                                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(fitting.more) more with no time")
                            .accessibilityIdentifier("allDay.more")
                            .popover(isPresented: Binding(get: { showingAll == day.id },
                                                          set: { if !$0 { showingAll = nil } })) {
                                allOf(day)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                    .frame(width: dayWidth, height: height, alignment: .topLeading)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(.separator).opacity(0.35)).frame(width: 0.5)
                    }
                    .id(day.id)
                }
            }
            .scrollTargetLayout()
            .offset(x: offset.stretch)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .scrollPosition($position)
        .frame(height: height)
        .background(Color(.systemBackground))
        .onChange(of: offset.x, initial: true) { _, x in
            position.scrollTo(x: x)
        }
        #if DEBUG
        .task {
            // `--all-day-more`: the first crowded day's list open, to look at.
            guard ProcessInfo.processInfo.arguments.contains("--all-day-more") else { return }
            try? await Task.sleep(for: .seconds(2))
            showingAll = days.first { events($0).count > Self.limit }?.id
        }
        #endif
    }

    /// Everything all day on one day, from its "+N more": the same chips at a size to read, so
    /// each opens, blocks and hides exactly as it does in the strip.
    private func allOf(_ day: WeekView.DayData) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(events(day)) { chip($0, inList: true) }
        }
        .padding(DS.Space.m)
        .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("allDay.list")
    }

    private func chip(_ occurrence: Occurrence, inList: Bool = false) -> some View {
        let color = tint(occurrence)
        let busy = occurrence.blocksWholeDay
        let shape = Capsule()
        return Button {
            guard inList else { return onOpen(occurrence) }
            // One thing on screen at a time: the list goes, then the event opens.
            showingAll = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                onOpen(occurrence)
            }
        } label: {
            Text(occurrence.title)
                .font(inList ? Font.subheadline.weight(busy ? .semibold : .regular) : DS.Typeface.small(busy ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(busy ? Color.white : Color.primary)
                .padding(.horizontal, inList ? 10 : 6)
                .frame(maxWidth: .infinity, minHeight: inList ? 30 : 18, alignment: .leading)
                // Busy is solid, its calendar's colour: a blocked day reads at a glance. Otherwise a
                // soft fill — an outline means "not answered" elsewhere.
                .background(busy ? color : color.opacity(DS.Tint.soft), in: shape)
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Blocking and hiding are an all-day event's; a routine moment opens its own sheet.
            if occurrence.behavior == .allDay {
                Button { onBlock(occurrence, !busy) } label: {
                    Label(busy ? "Don\u{2019}t block this day" : "Block this day",
                          systemImage: busy ? "calendar" : "calendar.badge.clock")
                }
                if let meeting = occurrence.meeting {
                    Button { AllDayHiding.hide(meeting) } label: {
                        Label("Hide in Banana", systemImage: "eye.slash")
                    }
                }
            }
        }
        .accessibilityLabel(occurrence.isUntimedCue
                            ? "\(occurrence.title), no set time"
                            : "\(occurrence.title), all day\(busy ? ", busy" : ", free")")
        .accessibilityIdentifier(occurrence.isUntimedCue ? "untimed.cue" : "allDay.chip")
    }
}

private struct MobileDayHeaderStrip: View {
    let days: [WeekView.DayData]
    let dayWidth: CGFloat
    let selectedDay: Date
    let onSelect: (WeekView.DayData) -> Void
    let onShowItems: (WeekView.DayData) -> Void
    @ObservedObject var offset: HeaderScrollOffset
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(days) { day in
                    let selected = Calendar.current.isDate(day.date, inSameDayAs: selectedDay)
                    // The day's letter and number select it and, with anything on it, open its
                    // whole list (the list icon beside each number did that before).
                    Button {
                        onSelect(day)
                        if !day.items.isEmpty { onShowItems(day) }
                    } label: {
                        VStack(spacing: 1) {
                            Text(day.letter.uppercased())
                                .font(DS.Typeface.small(.semibold, design: .rounded))
                                .foregroundStyle(day.isToday ? DS.Palette.accent : .secondary)
                            Text(day.dayNum)
                                .font(.system(size: 16, weight: day.isToday ? .bold : .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(day.isToday ? DS.Palette.onAccent : .primary)
                                .frame(width: 26, height: 24)
                                .background(day.isToday ? DS.Palette.accent : Color.clear, in: Circle())
                        }
                        .frame(width: dayWidth, height: 44)
                        .overlay(alignment: .bottom) {
                            if selected && !day.isToday {
                                Capsule().fill(DS.Palette.accent).frame(width: 18, height: 2)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(Color(.separator).opacity(0.35)).frame(width: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(day.weekday) \(day.dayNum), \(day.items.count) items")
                    .accessibilityHint(day.items.isEmpty ? "" : "Shows all of the day\u{2019}s items")
                    .accessibilityIdentifier(day.items.isEmpty ? "calendar.day.\(Occurrence.dayKey(day.date))"
                                                               : "calendar.day.items.\(Occurrence.dayKey(day.date))")
                    .id(day.id)
                }
            }
            .scrollTargetLayout()
            .offset(x: offset.stretch)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .scrollPosition($position)
        .frame(height: 44)
        .background(Color(.systemBackground))
        .onChange(of: offset.x, initial: true) { _, x in
            position.scrollTo(x: x)
        }
    }
}
#endif

#if os(iOS)
struct WeekView: View {
    private let calendarScope = ShellCalendarScope.shared
    @Environment(\.tabBarPlacement) private var tabBarPlacement
    /// The bottom-bar shell: one top row (the title menu and "…"), and the untimed items as one
    /// sideways row (docs/design/BOTTOM-BAR-SHELL.md).
    @Environment(\.bottomBarShell) private var bottomBarShell
    /// The wide shell (the rail, one toolbar): the Mac's paging group (`PlanPagingToolbar`) at the
    /// left, "Search or ask" in the middle (`ReviewToolbarItem`), the assistant and "…".
    @Environment(\.wideShell) private var wideShell
    /// Whether the top bar offers the booking link.
    @ObservedObject private var booking = BookingCenter.shared
    /// Calendar publications are observed explicitly below. Observing the entire store here made
    /// every transient store change rebuild the 24-hour SwiftUI grid, including while UIKit was
    /// handling a vertical flick. The app has one canonical occurrence store, so actions can use
    /// it directly without subscribing this whole view to unrelated `objectWillChange` traffic.
    private var occurrences: OccurrenceStore { .shared }
    @EnvironmentObject var routines: RoutineStore
    /// Not observed: the grid only cancels alarms (see AlarmStoreReference).
    @Environment(\.alarmStore) private var alarmsRef
    private var alarms: AlarmStore? { alarmsRef.store }
    @Environment(\.weekSmartStore) private var installedSmartStore
    private var smart: SmartScheduleStore {
        guard let store = installedSmartStore.store else {
            preconditionFailure("WeekView requires the installed SmartScheduleStore")
        }
        return store
    }
    @EnvironmentObject var weather: WeatherStore
    /// Which days you worked out and what's playing — the two facts the cues need, without
    /// redrawing the grid on every Health or player publish (see `CalendarSignals`).
    @ObservedObject private var signals = CalendarSignals.shared

    /// Day and Week are the same calendar at different zoom levels. A separate agenda-style Day
    /// screen made their controls and interactions drift apart.
    private let dayMode: Bool
    /// Overdue reminders: their own group at the top of List (and not again under today), and
    /// the first chips of today's reminders line in Day and Week.
    @State private var mountedOverdueTasks: [Occurrence]?
    private var overdueTasks: [Occurrence] {
        mountedOverdueTasks ?? occurrences.occurrences.filter(\.isOverdueReminder)
    }
    /// The reminders line opened past its first few.
    @State private var showsEveryReminder = false
    /// Only whether anything needs attention: the chips are their own subview
    /// (`PlanAttentionChips`), so their stores' publishes never rebuild this grid.
    @ObservedObject private var attention = PlanAttention.shared

    init(dayMode: Bool = false) {
        self.dayMode = dayMode
    }

    /// Drag-to-move on the mobile calendar layout. Gated behind a long press so a vertical drag
    /// still scrolls the week — on touch the two gestures compete for the same movement.
    @State private var draggingEventID: String?
    @State private var dragOffsetY: CGFloat = 0
    @State private var dragDayShift: Int = 0
    @State private var pendingRecurringMove: PendingEventMove?
    @State private var moveError: String?
    @State private var optimisticStart: [String: Date] = [:]
    @State private var savingEventIDs: Set<String> = []

    /// See MacWeekView.commitMove — the block is drawn at its new time immediately, with a
    /// spinner while the write is in flight, instead of snapping back and jumping forward.
    private func commitMove(_ meeting: MeetingInfo, occurrenceID: String, to newStart: Date, span: CalendarEditSpan) {
        optimisticStart[occurrenceID] = newStart
        savingEventIDs.insert(occurrenceID)
        Task { @MainActor in
            let failure = await smart.moveMeeting(meeting, to: newStart, span: span)
            savingEventIDs.remove(occurrenceID)
            if let failure {
                optimisticStart[occurrenceID] = nil
                moveError = failure
            } else {
                ToastCenter.shared.offerMoveUndo(meeting, from: meeting.start, to: newStart,
                                                         span: span, smart: smart)
                await occurrences.recompute()
                optimisticStart[occurrenceID] = nil
            }
        }
    }

    private func displayStart(_ occ: Occurrence) -> Date {
        optimisticStart[occ.id] ?? occ.start
    }
    /// The briefing is otherwise reachable only in the ten minutes after a wake. (Routines and
    /// Settings are in every page's "…" now: `MoreMenu`.)
    @State private var showBriefing = false
    @State private var showingAvailability = false
    @State private var days: [DayData] = []

    @State private var editing: Routine?
    @State private var movingOcc: Occurrence?
    @State private var reschedulingTask: Occurrence?
    @State private var editingTask: Occurrence?
    @State private var addingExtraFor: Routine?
    @State private var eventSheet: CalendarEventSheet?
    /// The Plan's width, panel included: whether an event opens beside it or over it.
    @State private var planWidth: CGFloat = 0
    private var eventsOpenBeside: Bool { LayoutClass.opensBeside(width: planWidth) }
    /// A routine moment tapped in the calendar: its time and what set it (`CueOccurrenceSheet`).
    @State private var inspectingCue: Occurrence?
    /// What that sheet asked for next — opened once it has gone.
    @State private var afterCueSheet: (() -> Void)?

    @State private var mountedDays: [DayData]?
    @State private var mountSnapshot = CalendarMountSnapshot<(CalendarInput, [DayData])>()
    private var calendarDays: [DayData] { mountedDays ?? openingDays.1 }
    private var openingDays: (CalendarInput, [DayData]) {
        mountSnapshot.resolve {
            let input = calendarInput(mobileWindowOccurrences())
            return (input, makeMobileDays(input))
        }
    }
    // One bounded visible window, invalidated by data, navigation, midnight or calendar changes.
    private struct CalendarInput: Equatable {
        var occurrences: [Occurrence]
        var start: Date
        var today: Date
        var calendar: Calendar
    }
    @State private var preparedCalendarInput: CalendarInput?
    @State private var lastAppearanceRefresh: Date?
    @State private var mobileWeekOffset = 0
    /// Pinch-to-zoom for the mobile calendar grid: persisted so the chosen hour density
    /// sticks. A pinch scales live via `mobileLiveHourHeight` and commits on end.
    @AppStorage("mobileWeekHourHeight") private var mobileStoredHourHeight: Double = 56
    /// The hour height while a pinch is under way; nil otherwise.
    @State private var mobileLiveHourHeight: CGFloat?
    /// Where the 3-day grid is scrolled, for anchoring its pinch. A plain reference, so scrolling
    /// doesn't redraw the whole view every frame.
    @State private var mobileWeekScrollY = ScrollOffsetBox()
    @State private var mobileWeekScroll = ScrollPosition(edge: .top)
    /// The time between the fingers when a 3-day pinch began (hours from the top) and the hour
    /// height it began at.
    @State private var mobileWeekPinch: (hours: CGFloat, base: CGFloat)?
    private static let mobileHourHeights: ClosedRange<CGFloat> = 44...160
    @State private var mobileWeekLoading = CalendarPageLoading()
    @State private var mobileSelectedDay = Date()
    /// The orange block shown while a long-press drag is selecting a new event. Without it, the
    /// iPhone gesture had no visible acknowledgement until a sheet appeared on release.
    @State private var mobileDraftSelection: MobileGridSelection?
    @State private var newEventRequest: MobileNewEventRequest?
    @State private var failedWriteToResolve: UUID?
    @State private var showingNewTask = false
    /// Preset time when the reminder sheet is opened from the week's add menu.
    @State private var newTaskDue: Date?
    @State private var showingAlarms = false
    @State private var mobileVisibleDayID: Int?
    /// The other zone's hours while a trip is on screen (`TripZoneForGrid`), as on the Mac.
    @State private var mobileSecondaryZone: TimeZone?
    @State private var mobileDayList: DayData?
    @State private var mobileDayListSelection: Occurrence?
    @State private var mobileDayListQuery = ""
    /// The root deliberately removes the entire UI while backgrounded. This must therefore live
    /// outside the view's @State or every return to the app reconstructs Day at midnight.
    /// Where the Day view was left. -1 until the first scroll: a fresh install opens at the
    /// current hour, not at midnight.
    @AppStorage("mobileDayScrollOffset") private var mobileDayScrollOffset: Double = -1
    @State private var didSetMobileInitialScroll = false
    @State private var didSetMobileInitialHorizontalScroll = false
    /// Only visible Smart Schedule fields advance this revision. Status, authorization, wake-plan,
    /// and error publications no longer invalidate the 24-hour calendar.
    @State private var mobileVisibleSmartRevision = 0


    struct DayData: Identifiable, Equatable {
        let id: Int
        let date: Date
        let weekday: String
        let dayNum: String
        let letter: String
        let isToday: Bool
        let items: [Occurrence]
        let committed: Double
        let preparedPlacements: [CalendarLaneAllocator.Placement]

        init(id: Int, date: Date, weekday: String, dayNum: String, letter: String,
             isToday: Bool, items: [Occurrence], committed: Double,
             calendarGrid: Bool = false) {
            self.id = id; self.date = date; self.weekday = weekday; self.dayNum = dayNum
            self.letter = letter; self.isToday = isToday; self.items = items
            self.committed = committed
            let calendar = Calendar.current
            // Match the renderer's local midnight boundaries, including 23/25-hour days.
            // The wall-clock ruler has 24 labels; the underlying date interval can differ.
            let range = CalendarDayRange(day: date, calendar: calendar)
            preparedPlacements = WeekView.reuseGridLayouts
                ? CalendarLaneAllocator.placements(items.filter {
                    $0.hasScheduledTime && (!calendarGrid ||
                        ($0.behavior != .block && $0.start < range.end && $0.resolvedEnd > range.start))
                }) : []
        }
        var load: Double { min(1, committed / 16) }
        var free: Int { Int(max(0, 16 - committed).rounded()) }
    }
    private typealias GridPlacement = CalendarLaneAllocator.Placement
    private static let nativeWeekViewport: Bool = {
        #if os(iOS)
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-reference-week")
        #else
        true
        #endif
        #else
        false
        #endif
    }()
    private static let nativeDayViewport: Bool = {
        #if os(iOS)
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-reference-day")
        #else
        true
        #endif
        #else
        false
        #endif
    }()
    private static let prepareMobileNeighbors: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-reference-neighbors")
        #else
        true
        #endif
    }()
    private static let reuseGridLayouts: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-cache-layout")
            && !ProcessInfo.processInfo.arguments.contains("--calendar-recompute-layout")
        #else
        false
        #endif
    }()
    struct Geo: Equatable { var content: CGFloat; var container: CGFloat }

    var body: some View {

        let _ = RenderStats.note("WeekView")
        let _ = mobileVisibleSmartRevision
        NavigationStack {
            Group {
                mobilePlanner
            }
            // The grid's words grow with Dynamic Type as far as its time ruler can hold them.
            .dynamicTypeSize(...DS.Typeface.gridLargest)
            // Day's calendar surface is systemBackground. Let that same color cover the bottom
            // safe area under the collapsible tab/menu chrome; the grouped background otherwise
            // leaks through as a solid gray strip when the chrome contracts.
            .background(Color(.systemBackground).ignoresSafeArea())
            .pageNavigationTitle("Plan")
            .confirmationDialog(
                "This event repeats",
                isPresented: Binding(get: { pendingRecurringMove != nil },
                                     set: { if !$0 { pendingRecurringMove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Move this event only") {
                    if let move = pendingRecurringMove {
                        commitMove(move.meeting, occurrenceID: move.occurrenceID,
                                   to: move.newStart, span: .thisEvent)
                    }
                    pendingRecurringMove = nil
                }
                // The whole series: a move by drag has no "this and following" (it would split
                // the series in two).
                Button("Move entire series") {
                    if let move = pendingRecurringMove {
                        commitMove(move.meeting, occurrenceID: move.occurrenceID,
                                   to: move.newStart, span: .allEvents)
                    }
                    pendingRecurringMove = nil
                }
                Button("Cancel", role: .cancel) { pendingRecurringMove = nil }
            } message: {
                if let move = pendingRecurringMove {
                    Text("Move \u{201C}\(move.meeting.title)\u{201D} to \(move.newStart.formatted(.dateTime.weekday().hour().minute()))?")
                }
            }
            .modifier(CalendarMoveRecoveryModifier(smart: smart))
            .alert("Couldn\u{2019}t move that event",
                   isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })) {
                Button("OK", role: .cancel) { moveError = nil }
            } message: {
                Text(moveError ?? "")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(bottomBarShell ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if bottomBarShell { mobileTopRow }
            }
            .toolbar {
                // The bottom-bar layout draws its own top row (`mobileTopRow`): the bar moved
                // its items into an overflow menu, with room to spare, once Today joined "‹ ›",
                // and the row has to fit a 13 mini.
                if wideShell {
                    // First: the sidebar button leads the bar, as on every page.
                    ReviewToolbarItem(section: .plan)
                    PlanPagingToolbar(days: dayMode ? 1 : 7,
                                      dates: PlanPaging.dates(start: mobileVisibleWeekStart, days: dayMode ? 1 : 7),
                                      isCurrent: mobileWeekOffset == 0,
                                      step: { moveMobileWeek($0) }, toCurrent: { moveMobileWeekToCurrent() }) {
                        mobileForecast
                        CalendarRefreshStatus(loading: mobileWeekLoading) { active in
                            if active { ProgressView().controlSize(.mini) }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        MoreMenu(identifier: "mobile.week.more") {
                            if booking.canShare { BookingShareButton() }
                            planMoreItems
                        }
                    }
                } else if !bottomBarShell {
                    // Only the floating top tabs occupy the centre. With the sidebar open,
                    // keep Day/Week in the title position instead of pushing it to the far left.
                    ToolbarItem(placement: tabBarPlacement == .topBar ? .topBarLeading : .principal) {
                        PlanModePicker(widest: tabBarPlacement == .topBar ? 120 : 204)
                            .controlSize(.small)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ReviewToolbarItem(section: .plan)
                    if booking.canShare {
                        ToolbarItem(placement: .automatic) { BookingShareButton() }
                    }
                    ToolbarItem(placement: .automatic) { CalendarSearchButton() }
                    ToolbarItem(placement: .automatic) {
                        MoreMenu(identifier: "mobile.week.more") { planMoreItems }
                    }
                }
            }
            // The one + of the page (`PageChrome`). It was a menu at the top right, with a
            // second way to the same reminder sheet ("New task") inside "…".
            .addMenu(identifier: "mobile.week.newEvent", clearsList: false) {
                Button {
                    newEventRequest = MobileNewEventRequest(
                        start: mobileDefaultNewEventStart(),
                        durationMinutes: 60)
                } label: {
                    Label("Event", systemImage: "calendar.badge.plus")
                }
                .accessibilityIdentifier("mobile.week.add.event")
                Button {
                    newTaskDue = mobileDefaultNewEventStart()
                    showingNewTask = true
                } label: {
                    Label("Reminder", systemImage: "checklist")
                }
                .accessibilityIdentifier("mobile.week.newTask")
                Button { showingAlarms = true } label: {
                    Label("Alarm", systemImage: "alarm")
                }
                .accessibilityIdentifier("mobile.week.add.alarm")
            }
            // The same three, picked from the + on the tab bar's row.
            .onAdd(.event, .reminder, .alarm) { kind in
                switch kind {
                case .event:
                    newEventRequest = MobileNewEventRequest(
                        start: mobileDefaultNewEventStart(),
                        durationMinutes: 60)
                case .reminder:
                    newTaskDue = mobileDefaultNewEventStart()
                    showingNewTask = true
                default: showingAlarms = true
                }
            }
            .sheet(isPresented: $showBriefing) { MorningBriefingView() }
            .sheet(isPresented: $showingAvailability) { AvailabilitySheet() }
            // A booking push was tapped: its day, and its event when it's still there.
            .onReceive(PlanOpenRequests.shared.$pending) { pending in
                // The value handed over (`$pending` publishes before it is stored), taken once it is.
                guard let pending else { return }
                Task { @MainActor in
                    guard PlanOpenRequests.shared.take(pending) else { return }
                    await openFromPush(pending)
                }
            }
            .sheet(item: $editing) { RoutineEditorView(draft: $0, isNew: false) }
            // An event opens beside the calendar where there's room (an iPad on its side), as the
            // Mac's drawer does, and as a sheet anywhere narrower (`LayoutClass.opensBeside`).
            .sheet(item: Binding(get: { eventsOpenBeside ? nil : eventSheet }, set: { eventSheet = $0 })) {
                eventDetail($0)
            }
            .inspector(isPresented: Binding(get: { eventsOpenBeside && eventSheet != nil },
                                            set: { if !$0 { eventSheet = nil } })) {
                Group {
                    if let sheet = eventSheet {
                        eventDetail(sheet, close: { eventSheet = nil }).id(sheet.id)
                    }
                }
                .inspectorColumnWidth(min: 320, ideal: 380, max: 460)
            }
            // Measured outside the panel, so opening it never makes the room look too narrow for it.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { planWidth = $0 }
            #if DEBUG
            // `--open-event`: an invitation open as a tap would open it, beside or as a sheet.
            .task {
                if ProcessInfo.processInfo.arguments.contains("--open-event") {
                    try? await Task.sleep(for: .seconds(1))
                    eventSheet = CalendarEventSheet(googleMeeting: .detailPreview)
                }
            }
            #endif
            .sheet(item: $inspectingCue, onDismiss: {
                afterCueSheet?()
                afterCueSheet = nil
            }) { occ in
                if let routine = routines.routines.first(where: { $0.id == occ.routineID }) {
                    CueOccurrenceSheet(occurrence: occ, routine: routine, plan: smart.plan) { action in
                        switch action {
                        case .move: afterCueSheet = { movingOcc = occ }
                        case .edit: afterCueSheet = { editing = routine }
                        case .addAnother: afterCueSheet = { addingExtraFor = routine }
                        }
                    }
                }
            }
            .sheet(item: $movingOcc) { occ in
                OccurrenceTimeSheet(title: "Move \(occ.title)", initial: occ.start) { newStart in
                    if let key = occ.occurrenceKey { ExceptionStore.shared.reschedule(key, to: newStart) }
                    Task { await occurrences.recompute() }
                }
            }
            .sheet(item: $addingExtraFor) { routine in
                OccurrenceTimeSheet(title: "Add \(routine.name)", initial: Date().addingTimeInterval(3600)) { start in
                    ExceptionStore.shared.addExtra(seriesID: routine.id.uuidString, start: start)
                    Task { await occurrences.recompute() }
                }
            }
            .sheet(item: $reschedulingTask) { occ in
                OccurrenceTimeSheet(title: "Reschedule \(occ.title)",
                                    initial: occ.hasScheduledTime ? occ.start : Date().addingTimeInterval(3600)) { newDue in
                    if let id = occ.reminderID { Task { await occurrences.rescheduleTask(reminderID: id, to: newDue) } }
                }
            }
            .sheet(item: $editingTask) { occ in
                if let id = occ.reminderID {
                    NewTaskSheet(reminderID: id, title: occ.title,
                                 tick: (occ.completed, { TaskTick.toggle(occ) }),
                                 missed: NewTaskSheet.Missed(occ))
                }
            }
            .sheet(item: $mobileDayList, onDismiss: activateMobileDayListSelection) { day in
                mobileDayListView(day)
            }
            .sheet(item: $newEventRequest) { request in
                NewCalendarEventSheet(
                    initialStart: request.start,
                    initialDurationMinutes: request.durationMinutes)
            }
            .confirmationDialog(
                "This event hasn't been saved",
                isPresented: Binding(get: { failedWriteToResolve != nil },
                                     set: { if !$0 { failedWriteToResolve = nil } }),
                titleVisibility: .visible
            ) {
                Button("Try again") {
                    if let ticket = failedWriteToResolve { occurrences.retryPendingWrite(ticket) }
                    failedWriteToResolve = nil
                }
                Button("Discard", role: .destructive) {
                    if let ticket = failedWriteToResolve { occurrences.discardPendingWrite(ticket) }
                    failedWriteToResolve = nil
                }
                Button("Keep for later", role: .cancel) { failedWriteToResolve = nil }
            } message: {
                Text(failedWriteToResolve
                        .flatMap { occurrences.pendingWrites.entry($0)?.lastError }
                        ?? "It couldn't be written to your calendar.")
            }
            .sheet(isPresented: $showingNewTask, onDismiss: { newTaskDue = nil }) {
                NewTaskSheet(initialDue: newTaskDue)
            }
            .sheet(isPresented: $showingAlarms) { OneOffAlarmSheet().toastHost() }
        }
        .onChange(of: calendarScope.calendarIDs) { _, _ in rebuildMobileCalendar(mobileWindowOccurrences()) }
        .onAppear {
            let _ = RenderStats.note("Calendar.appear")
            // instant: draw from what the store already holds
            rebuildMobileCalendar(mobileWindowOccurrences())
        }
        .task {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let cacheBackfillValidation = arguments.contains("--day-cache-backfill-regression")
            let readOnlyCalendarValidation = arguments.contains("--day-real-calendar")
            // On iOS, "--ui-audit" alone is the *macOS* route's own flag (MacRootView.swift) and
            // is never passed on an iOS launch, so it could never catch --today/--day/--week/
            // --tomorrow here -- this is the same class of stale-guard gap TodayView's `.task`
            // guard already closed (see its comment). VisualAuditRoute is the complete iOS list.
            let isVisualAudit = VisualAuditRoute.matches(arguments)
            guard !isVisualAudit || cacheBackfillValidation || readOnlyCalendarValidation
            else { return }
            #endif
            // Tab re-entry shouldn't restart the same provider reads or flash a loading state.
            // Live publications and explicit refresh/navigation still bypass this appearance check.
            let refreshOnAppearance = lastAppearanceRefresh.map { Date().timeIntervalSince($0) >= 45 } ?? true
            let windowTask = Task { @MainActor in
                if refreshOnAppearance {
                    await refreshMobileWeek()
                    lastAppearanceRefresh = Date()
                }
            }
            #if DEBUG
            if !readOnlyCalendarValidation && !cacheBackfillValidation {
                await occurrences.recomputeIfStale(reason: "day view")
            }
            #else
            await occurrences.recomputeIfStale(reason: "day view")
            #endif
            await windowTask.value
            rebuildMobileCalendar(mobileWindowOccurrences())
        }
        .task {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard !arguments.contains("--ui-audit"),
                  !arguments.contains("--day-real-calendar") else { return }
            #endif
            await weather.refreshIfStale()   // Week needs the whole week's forecast, not just today's
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--offscreen-recompute-regression") else { return }
            try? await Task.sleep(for: .seconds(4))
            for round in 0..<20 where !Task.isCancelled {
                occurrences.republishWithOffscreenChange(round: round)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--smart-publish-regression")
            else { return }
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<120 where !Task.isCancelled {
                // Exercise the installed production SmartScheduleStore through SwiftUI's public
                // view boundary. The publication deliberately changes no visible calendar value.
                smart.objectWillChange.send()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        #endif
        .onReceive(occurrences.$occurrences) { _ in
            // `@Published` announces a change BEFORE storing it, and the grid reads the store
            // (`planningWindow` falls back to `occurrences`), so rebuilding here drew the
            // previous timeline — an event just confirmed, or just added, was missing until
            // something else rebuilt the day. Read once the new value is in.
            DispatchQueue.main.async { rebuildMobileCalendar(mobileWindowOccurrences()) }
        }
        // Changes only, not the value replayed on subscribing: that one arrives while this view is
        // still being put on screen, and a day written then was stored but never drawn — the
        // grid's content had already been built from the empty one, and every rebuild after it
        // found the days equal and wrote nothing. Switching to Day from List or Week left it
        // blank until something changed. `onAppear` draws the first day.
        .onReceive(occurrences.$planningWindowRevision.dropFirst()) { _ in
            rebuildMobileCalendar(mobileWindowOccurrences())
        }
        // Declined or deleted a moment ago: off the day now; back if undone. A turn later, as
        // `@Published` announces before it stores.
        .onReceive(ToastCenter.shared.$hiddenIDs.dropFirst()) { _ in
            DispatchQueue.main.async { rebuildMobileCalendar(mobileWindowOccurrences()) }
        }
        .onReceive(smart.$calendarColorHex.removeDuplicates().dropFirst()) { _ in
            mobileVisibleSmartRevision &+= 1
        }
        .onReceive(smart.$commuteLegs.removeDuplicates().dropFirst()) { _ in
            mobileVisibleSmartRevision &+= 1
        }
        .onReceive(smart.$flightLegs.removeDuplicates().dropFirst()) { _ in
            mobileVisibleSmartRevision &+= 1
            // `@Published` announces before it stores.
            DispatchQueue.main.async { updateMobileSecondaryZone() }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--slow-occurrence-recompute-regression") {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("day.performance.recomputeCount")
                    .accessibilityValue("\(occurrences.performanceRecomputeCount)")
            }
        }
        #endif
        .onReceive(
            smart.$settings
                .map(\.weekStartWeekday)
                .removeDuplicates()
                .dropFirst()
        ) { _ in
                        rebuildMobileCalendar(mobileWindowOccurrences())
            Task { await refreshMobileWeek() }
        }
    }

    // MARK: - Mobile calendar

    /// What "…" holds on the phone, whichever shell it is in.
    @ViewBuilder private var planMoreItems: some View {
        // The plan had no way to ask for fresh data: pull-to-refresh was on the
        // retired Today screen. The Mac has ⌘R.
        Button {
            Task { await smart.refreshCalendar(); await occurrences.recompute() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("mobile.week.refresh")
        Button { showBriefing = true } label: {
            Label("Morning briefing", systemImage: "sunrise.fill")
        }
        .accessibilityIdentifier("mobile.week.briefing")
        CopyBookingLinkButton()
        Button { showingAvailability = true } label: {
            Label("Share availability", systemImage: "calendar.badge.checkmark")
        }
        .accessibilityIdentifier("mobile.week.availability")
        // The setup list, while anything on it has never been asked for: the
        // way back to it once its line above the plan has been hidden.
        SetupMenuItem()
    }

    /// The forecast beside Plan's paging group: the day shown in Day, today in this week.
    @ViewBuilder private var mobileForecast: some View {
        if let day = mobileForecastDay { WeatherChip(day: day) }
    }

    /// The day the forecast is for: the day shown in Day, today in this week, none otherwise.
    private var mobileForecastDay: Date? {
        dayMode ? mobileVisibleWeekStart : mobileWeekOffset == 0 ? Date() : nil
    }

    /// The bottom-bar layout's one top row: the paging group every shell has (`PlanPagingRow`:
    /// "‹", the period picker with its dates, "›", then Today), the forecast, and "…". What gives
    /// way on a narrow phone, in order: the forecast, then the dates move under the period's name
    /// (where the old title had them), and only on the narrowest go.
    private var mobileTopRow: some View {
        let days = dayMode ? 1 : 7
        let dates = PlanPaging.dates(start: mobileVisibleWeekStart, days: days)
        let isCurrent = mobileWeekOffset == 0
        func row(_ layout: PlanPaging.TopRow) -> some View {
            let place: PlanPeriodMenu.DatesPlace = switch layout.dates {
            case .beside: .beside
            case .under: .under
            case .hidden: .hidden
            }
            return HStack(spacing: DS.Space.s) {
                PlanPagingRow(days: days, dates: dates, isCurrent: isCurrent, datesPlace: place, showsToday: layout.today,
                              step: { moveMobileWeek($0) }, toCurrent: { moveMobileWeekToCurrent() })
                if layout.forecast { mobileForecast.fixedSize() }
                Spacer(minLength: 0)
            }
        }
        // Widest first (`PlanPaging.topRowLayouts`): on the current period the forecast takes
        // Today's place before it gives way, so it is reachable at every phone width.
        let hasForecast = mobileForecastDay.map { WeatherChip.hour(on: $0, in: weather) != nil } ?? false
        let layouts = PlanPaging.topRowLayouts(isCurrent: isCurrent, hasForecast: hasForecast)
        return HStack(spacing: DS.Space.s) {
            ViewThatFits(in: .horizontal) {
                ForEach(layouts.indices, id: \.self) { row(layouts[$0]) }
            }
            MoreMenu(identifier: "mobile.week.more") {
                if booking.canShare { BookingShareButton() }
                planMoreItems
            }
            .font(.title3)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.xs)
    }

    /// A real shared time axis. Three readable columns fit in portrait; horizontal scrolling
    /// exposes the rest of the week, while landscape naturally shows most or all seven.
    private var mobilePlanner: some View {
        VStack(spacing: 0) {
            PlanPromptCard()
            // A repeating reminder that follows a moment, offered it (`AnchorSuggestions`):
            // above the day, where Plan's List had it.
            if dayMode { ReminderTimingOffers().padding(.bottom, DS.Space.xs) }
            // Only outside both shells: their bars page (`PlanPaging`).
            if PlanPaging.drawsDateLine(PlanPaging.shell(bottomBar: bottomBarShell, wide: wideShell)) {
                mobileWeekChrome
                Divider()
            }
            mobileCalendarGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(dayMode ? "plan.surface.day" : "plan.surface.week")
    }

    private var mobileWeekChrome: some View {
        // The one date line (`PageChrome`): this was the row it was lifted from.
        CalendarRefreshStatus(loading: mobileWeekLoading) { active in
            DateLine(current: dayMode ? "Today" : "This week", dates: mobileWeekRangeTitle,
                     isCurrent: mobileWeekOffset == 0, loading: active,
                     unit: dayMode ? "day" : "week", titleIdentifier: "mobile.day.title",
                     titleValue: dayMode ? Occurrence.dayKey(mobileVisibleWeekStart) : mobileWeekRangeTitle,
                     step: { moveMobileWeek($0) }, toCurrent: { moveMobileWeekToCurrent() }) {
                // The forecast: the day shown in Day, today in this week. It ran down the List.
                if dayMode {
                    WeatherChip(day: mobileVisibleWeekStart)
                } else if mobileWeekOffset == 0 {
                    WeatherChip(day: Date())
                }
            }
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder private var mobileCalendarGrid: some View {
        mobileWeekCalendarGrid
    }

    /// All-day calendar events for the day on screen: a trip, an offsite, a birthday.
    /// Routines and reminders share the wrapping band below.
    @ViewBuilder private func mobileAllDayBand(_ day: DayData?) -> some View {
        let events = AllDayEvents.busyFirst((day?.items ?? []).filter { $0.behavior == .allDay },
                                            blocks: \.blocksWholeDay)
        if !events.isEmpty {
            // Every one of the day's, wrapped onto as many lines as they take: one day has the
            // room, and a row that scrolled sideways hid whatever was past the edge.
            WrappingLayout(spacing: DS.Space.s, lineSpacing: DS.Space.xs + 2, fitsWidth: true) {
                ForEach(events) { allDayEventChip($0) }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The calendar's own white: these belong to the day, not to the header above it.
            .background(Color(.systemBackground))
            // Its own container, so the grid's identifier doesn't land on every chip in place
            // of the chip's own (as in the reminders line below).
            .accessibilityElement(children: .contain)
            Divider()
        }
    }

    /// A routine moment with no time of its own: opens its sheet, as in List.
    private func untimedCueChip(_ occ: Occurrence) -> some View {
        let tint = occ.tint.color
        return Button { inspectingCue = occ } label: {
            Label(occ.title, systemImage: occ.completed ? "checkmark.circle.fill" : occ.icon)
                .font(.caption)
                .lineLimit(1)
                .strikethrough(occ.skipped || occ.completed, color: .secondary)
                .foregroundStyle(occ.skipped ? Color.secondary : tint)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .background(tint.opacity(occ.skipped ? 0 : DS.Tint.soft), in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let routine = routines.routines.first(where: { $0.id == occ.routineID }) { cueMenu(routine, occ) }
        }
        .accessibilityLabel("\(occ.title), no set time")
        .accessibilityValue(occ.completed ? "Completed" : occ.skipped ? "Skipped" : "Not completed")
        .accessibilityIdentifier("untimed.cue")
    }

    private func allDayEventChip(_ occ: Occurrence) -> some View {
        let tint = sourceCalendarColor(occ, colors: smart.calendarColorHex) ?? DS.Palette.info
        let busy = occ.blocksWholeDay
        return Button {
            if let meeting = occ.meeting { openEvent(meeting) }
        } label: {
            Label(occ.title, systemImage: busy ? "calendar.badge.clock" : "calendar")
                .font(.caption.weight(busy ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(busy ? Color.white : Color.primary)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .background(busy ? tint : tint.opacity(DS.Tint.soft), in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let meeting = occ.meeting {
                Button { AllDayBlocking.set(meeting, busy: !busy) } label: {
                    Label(busy ? "Don\u{2019}t block this day" : "Block this day",
                          systemImage: busy ? "calendar" : "calendar.badge.clock")
                }
                Button { AllDayHiding.hide(meeting) } label: {
                    Label("Hide in Banana", systemImage: "eye.slash")
                }
            }
        }
        .accessibilityLabel("\(occ.title), all day\(busy ? ", busy" : ", free")")
        .accessibilityIdentifier("allDay.chip")
    }

    /// How many reminders the line shows before "+N more": two or three lines of chips, so the
    /// day below keeps most of the screen however much is outstanding.
    private static let reminderLineLimit = 4
    /// The attention chips the wrapping line shows before "+N more" opens the rest.
    private static let attentionLineLimit = 3

    /// Due routines and reminders share one wrapping band above the hours. Today also includes
    /// every outstanding reminder (`OutstandingReminders`). Existing actions and overflow stay
    /// attached to their chips; the two kinds no longer reserve separate full-width bands.
    @ViewBuilder private func mobileRemindersBand(_ day: DayData?) -> some View {
        let untimed = (day?.items ?? [])
            .filter { $0.behavior == .task && !$0.hasScheduledTime }
            .sorted { ($0.overdue ? 0 : 1, $0.title) < ($1.overdue ? 0 : 1, $1.title) }
        let reminders = OutstandingReminders.line(untimed: untimed, overdue: overdueTasks,
                                                  isToday: day?.isToday ?? false, id: \.id, due: Self.due)
        let moments = (day?.items ?? []).filter {
            untimedMomentIsDue($0, routines: routines.routines, signals: signals)
        }
        // What else needs attention: today's, in the same row (`PlanAttentionChips`).
        let attends = (day?.isToday ?? false) && attention.count > 0
        if !reminders.isEmpty || !moments.isEmpty || attends {
            let shown = showsEveryReminder ? reminders : Array(reminders.prefix(Self.reminderLineLimit))
            WrappingLayout(spacing: DS.Space.s, lineSpacing: DS.Space.xs + 2, fitsWidth: true) {
                ForEach(moments) { untimedCueChip($0) }
                ForEach(shown) { reminderChip($0) }
                if attends { PlanAttentionChips(limit: Self.attentionLineLimit) }
                if reminders.count > Self.reminderLineLimit {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showsEveryReminder.toggle() }
                    } label: {
                        Text(showsEveryReminder ? "Fewer" : "+\(reminders.count - Self.reminderLineLimit) more")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.inline)
                    .accessibilityIdentifier("mobile.reminders.more")
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The calendar's own white, as the all-day items above.
            .background(Color(.systemBackground))
            // Its own container, as the sideways scroll it replaced was: without one, the grid's
            // identifier lands on every chip in place of the chip's own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mobile.plan.todo")
            Divider()
        }
    }

    /// The bottom-bar shell's one row of untimed items: the day's all-day events (in Day; Week
    /// has them under each column), its routines with no time, and its reminders, scrolling
    /// sideways. Every one of them is in the row; none waits behind "+N more".
    @ViewBuilder private func mobileUntimedRow(_ day: DayData?) -> some View {
        let events = dayMode ? AllDayEvents.busyFirst((day?.items ?? []).filter { $0.behavior == .allDay },
                                                      blocks: \.blocksWholeDay) : []
        let untimed = (day?.items ?? [])
            .filter { $0.behavior == .task && !$0.hasScheduledTime }
            .sorted { ($0.overdue ? 0 : 1, $0.title) < ($1.overdue ? 0 : 1, $1.title) }
        let reminders = OutstandingReminders.line(untimed: untimed, overdue: overdueTasks,
                                                  isToday: day?.isToday ?? false, id: \.id, due: Self.due)
        let moments = (day?.items ?? []).filter {
            untimedMomentIsDue($0, routines: routines.routines, signals: signals)
        }
        let attends = (day?.isToday ?? false) && attention.count > 0
        if !events.isEmpty || !reminders.isEmpty || !moments.isEmpty || attends {
            ScrollView(.horizontal) {
                HStack(spacing: DS.Space.s) {
                    ForEach(events) { allDayEventChip($0) }
                    ForEach(moments) { untimedCueChip($0) }
                    ForEach(reminders) { reminderChip($0) }
                    // Every one of them, as the row's reminders are.
                    if attends { PlanAttentionChips() }
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.xs + 2)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mobile.plan.todo")
            Divider()
        }
    }

    /// Whether the reminders line on screen is today's: the shown day in Day, the selected one
    /// in Week.
    private var remindersLineIsTodays: Bool {
        dayMode ? (calendarDays.first(where: { $0.id == 1 })?.isToday ?? false)
                : Calendar.current.isDateInToday(mobileSelectedDay)
    }

    /// What a day's column draws at its time. An overdue reminder is in today's reminders line
    /// instead (`OutstandingReminders`), not in both.
    private func drawnAmongTheHours(_ occurrence: Occurrence, on day: DayData) -> Bool {
        occurrence.hasScheduledTime && occurrence.behavior != .block
            && !OutstandingReminders.leavesTheGrid(overdueReminder: occurrence.isOverdueReminder,
                                                   onToday: day.isToday,
                                                   lineIsTodays: remindersLineIsTodays)
    }

    /// When a reminder was due: its deadline, else its time.
    private static func due(_ reminder: Occurrence) -> Date {
        reminder.schedule.constraints?.deadline ?? reminder.start
    }

    /// A reminder in the line: the circle ticks it, the words open it. The whole chip used to
    /// tick, so one too long to read in the line could only be read by completing it.
    private func reminderChip(_ reminder: Occurrence) -> some View {
        let overdue = reminder.overdue && !reminder.completed
        // A dose that is due (a reminder that reads as something taken: "Creatine") is amber
        // across the whole chip, as a due dose is in Taken; it was the grey of any reminder.
        #if BANANA_MODULE_FOOD
        let dueDose = overdue && ReminderToTaken.readsAsTaken(reminder.title)
        #else
        let dueDose = false   // Taken is Food's
        #endif
        return HStack(spacing: 0) {
            Button {
                TaskTick.toggle(reminder)
            } label: {
                Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(DS.Palette.task)
                    .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.completed ? "Mark \(reminder.title) not done" : "Mark \(reminder.title) done")
            .accessibilityValue(overdue ? "Overdue" : "")
            .accessibilityIdentifier("mobile.reminder.\(reminder.reminderID ?? reminder.id)")
            Button {
                editingTask = reminder
            } label: {
                HStack(spacing: 5) {
                    Text(reminder.title)
                        .font(.footnote)
                        .lineLimit(1)
                        .strikethrough(reminder.completed, color: .secondary)
                    if overdue {
                        Text(OutstandingReminders.since(Self.due(reminder)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(dueDose ? DS.Palette.warning : DS.Palette.danger)
                    } else if let waiting = reminder.waitingFor, !reminder.completed {
                        // Tied to a moment that hasn't come: not due, not late.
                        Text(waiting).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else if let missed = reminder.missed, !reminder.completed {
                        Text(missed.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.trailing, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(reminder.title)")
            .accessibilityIdentifier("mobile.reminder.open.\(reminder.reminderID ?? reminder.id)")
        }
        .background(Capsule().fill(Color(.systemBackground)))
        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
        .contextMenu { taskMenu(reminder) }
    }

    private var mobileWeekCalendarGrid: some View {
        GeometryReader { geometry in
            let timeWidth = mobileGutterWidth
            let visibleDays = dayMode ? 1 : (geometry.size.width >= 700 ? 7
                : (geometry.size.width >= 520 ? 5 : 3))
            // Day is a single time axis as wide as this view. The UIKit bridge has no intrinsic
            // width, so a GeometryReader inside it could report a tiny ideal width; this one is
            // outside it. The screen width is only the fallback for such a tiny reading: beside
            // an iPad sidebar or in a split, the screen is wider than the column.
            let measured = geometry.size.width > 100 ? geometry.size.width : UIScreen.main.bounds.width
            let dayWidth = dayMode
                ? max(64, measured - timeWidth)
                : max(64, (geometry.size.width - timeWidth) / CGFloat(visibleDays))
            let startHour = 0
            let endHour = 24
            // Pinch to zoom: taller hours reveal more per event (see gridBlockContent).
            let hourHeight: CGFloat = mobileLiveHourHeight
                ?? min(Self.mobileHourHeights.upperBound, max(Self.mobileHourHeights.lowerBound, mobileStoredHourHeight))
            let gridHeight = CGFloat(endHour - startHour) * hourHeight

            VStack(spacing: 0) {
                // Day mode has no column header: the navigation row above already names the
                // day ("Today · Sunday, Sep 27"), and saying it twice cost 44 pt of timeline.
                if !dayMode {
                HStack(spacing: 0) {
                    Color(.systemBackground).frame(width: timeWidth, height: 44)
                        .overlay(alignment: .bottomTrailing) {
                            if let zone = mobileSecondaryZone {
                                TripZoneNames(secondary: zone, date: calendarDays.first?.date ?? Date())
                                    .padding(.trailing, 5).padding(.bottom, 3)
                            }
                        }
                        MobileDayHeaderStrip(
                            days: calendarDays,
                            dayWidth: dayWidth,
                            selectedDay: mobileSelectedDay,
                            onSelect: { day in
                                mobileSelectedDay = day.date
                                mobileVisibleDayID = min(max(0, day.id), max(0, calendarDays.count - visibleDays))
                            },
                            onShowItems: { day in
                                mobileDayListQuery = ""
                                mobileDayListSelection = nil
                                mobileDayList = day
                            },
                            offset: headerOffset
                        )
                }
                Divider()
                // All-day events under each day's own column, scrolling with the header — not the
                // selected day's stretched across the week, which read as "all week" and hid
                // every other day's (a Saturday trip with Sunday selected).
                if calendarDays.contains(where: { $0.items.contains {
                    $0.behavior == .allDay
                } }) {
                    HStack(spacing: 0) {
                        Color(.systemBackground).frame(width: timeWidth)
                        MobileAllDayStrip(
                            days: calendarDays,
                            dayWidth: dayWidth,
                            offset: headerOffset,
                            tint: { $0.isUntimedCue ? $0.tint.color : sourceCalendarColor($0, colors: smart.calendarColorHex) ?? DS.Palette.info },
                            onOpen: { occurrence in
                                if occurrence.isUntimedCue { inspectingCue = occurrence }
                                else if let meeting = occurrence.meeting { openEvent(meeting) }
                            },
                            onBlock: { occurrence, busy in
                                if let meeting = occurrence.meeting { AllDayBlocking.set(meeting, busy: busy) }
                            })
                    }
                    // As tall as the strip says, not as tall as the gutter's colour would stretch.
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
                }
                let bandDay = dayMode
                    ? calendarDays.first(where: { $0.id == 1 })
                    : calendarDays.first(where: { Calendar.current.isDate($0.date, inSameDayAs: mobileSelectedDay) })
                if bottomBarShell {
                    mobileUntimedRow(bandDay)
                } else {
                    if dayMode { mobileAllDayBand(bandDay) }
                    mobileRemindersBand(bandDay)
                }
                if dayMode, let currentDay = calendarDays.first(where: { $0.id == 1 }) {
                    Group {
                        if Self.nativeDayViewport {
                            mobileNativeCalendarViewport(timeWidth: timeWidth, dayWidth: dayWidth,
                                hourHeight: hourHeight, gridHeight: gridHeight, visibleDays: 1,
                                viewportHeight: nil, viewportWidth: geometry.size.width)
                        } else {
                            DirectionalDayScrollView(
                                resetToken: Occurrence.dayKey(currentDay.date),
                                contentHeight: gridHeight,
                                initialOffset: mobileDayScrollOffset >= 0
                                    ? CGFloat(mobileDayScrollOffset)
                                    : max(0, (CGFloat(GridOpeningHour.current) - 1.5) * hourHeight),
                                onHorizontalSwipe: { forward in moveMobileWeek(forward ? 1 : -1) },
                                canBeginSwipe: { draggingEventID == nil },
                                onVerticalOffset: { mobileDayScrollOffset = Double($0) },
                                canBeginCreate: { point in
                                    guard point.x >= timeWidth else { return false }
                                    let instant = mobileGridDate(
                                        on: currentDay.date,
                                        y: point.y,
                                        startHour: startHour,
                                        hourHeight: hourHeight)
                                    return !currentDay.items.contains {
                                        drawnAmongTheHours($0, on: currentDay)
                                            && $0.start <= instant && $0.resolvedEnd > instant
                                    }
                                },
                                onCreateChanged: { start, current in
                                    updateMobileSelection(
                                        on: currentDay.date,
                                        startY: start.y,
                                        currentY: current.y,
                                        startHour: startHour,
                                        hourHeight: hourHeight)
                                },
                                onCreateEnded: { start, current in
                                    updateMobileSelection(
                                        on: currentDay.date,
                                        startY: start.y,
                                        currentY: current.y,
                                        startHour: startHour,
                                        hourHeight: hourHeight)
                                    finishMobileSelection(on: currentDay.date)
                                },
                                onCreateCancelled: { mobileDraftSelection = nil },
                                hourHeight: hourHeight,
                                hourHeightRange: Self.mobileHourHeights,
                                onZoomChanged: { mobileLiveHourHeight = $0 },
                                onZoomEnded: { height in
                                    mobileStoredHourHeight = Double(height)
                                    mobileLiveHourHeight = nil
                                },
                                preservesActiveGesture: draggingEventID != nil,
                                content: HStack(alignment: .top, spacing: 0) {
                                    mobileTimeGutter(width: timeWidth, startHour: startHour,
                                                     endHour: endHour, hourHeight: hourHeight)
                                    mobileDayColumn(currentDay, width: dayWidth, startHour: startHour,
                                                    endHour: endHour, hourHeight: hourHeight)
                                }
                                .frame(height: gridHeight, alignment: .top)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            )
                        }
                    }
                    // Day has no week header row: the grid fills down to the tab bar.
                    .frame(minHeight: 1, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Day has no header row for the zones' names: a short row of their own above
                    // the hours, so they never sit over the first hour's label.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let zone = mobileSecondaryZone {
                            TripZoneNames(secondary: zone, date: currentDay.date)
                                .frame(width: timeWidth - 5, alignment: .trailing)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemBackground))
                        }
                    }
                } else if Self.nativeWeekViewport {
                    mobileNativeCalendarViewport(timeWidth: timeWidth, dayWidth: dayWidth,
                        hourHeight: hourHeight, gridHeight: gridHeight, visibleDays: visibleDays,
                        viewportHeight: max(1, geometry.size.height - 45), viewportWidth: measured)
                } else {
                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                mobileTimeGutter(width: timeWidth, startHour: startHour,
                                                 endHour: endHour, hourHeight: hourHeight)
                                ScrollView(.horizontal) {
                                    HStack(alignment: .top, spacing: 0) {
                                        ForEach(calendarDays) { day in
                                            mobileDayColumn(day, width: dayWidth, startHour: startHour,
                                                            endHour: endHour, hourHeight: hourHeight)
                                                .id(day.id)
                                        }
                                    }
                                    .scrollTargetLayout()
                                }
                                .scrollIndicators(.hidden)
                                .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                                .scrollPosition(id: $mobileVisibleDayID, anchor: .leading)
                                .onScrollGeometryChange(for: CGFloat.self) {
                                    $0.contentOffset.x + $0.contentInsets.leading
                                } action: { _, offset in
                                    // Only invalidates the small header subview (via its
                                    // @ObservedObject), not WeekView's whole body.
                                    if headerOffset.x != offset { headerOffset.x = offset }
                                }
                                .frame(width: max(1, geometry.size.width - timeWidth), height: gridHeight)
                            }
                            .frame(height: gridHeight, alignment: .top)
                            // Anchored where the fingers are, as in Day: the time between them stays
                            // between them as the hours grow or shrink. On the content, so the
                            // pinch's location is unambiguously in the grid's own coordinates.
                            .simultaneousGesture(
                                MagnifyGesture()
                                    .onChanged { value in
                                        GridZoom.gate.pinchChanged()
                                        let pinch = mobileWeekPinch
                                            ?? (value.startLocation.y / hourHeight, hourHeight)
                                        if mobileWeekPinch == nil {
                                            mobileWeekPinch = pinch
                                            mobileWeekScrollY.pinchStart = mobileWeekScrollY.y
                                        }
                                        // Where the fingers are on screen, kept for the whole pinch.
                                        let fingers = pinch.hours * pinch.base - mobileWeekScrollY.pinchStart
                                        let height = min(Self.mobileHourHeights.upperBound,
                                                         max(Self.mobileHourHeights.lowerBound, pinch.base * value.magnification))
                                        mobileLiveHourHeight = height
                                        let target = MobileZoom.offset(
                                            anchorHours: pinch.hours, hourHeight: height, fingersAt: fingers,
                                            contentHeight: CGFloat(endHour - startHour) * height + 24,
                                            viewportHeight: max(1, geometry.size.height - 45))
                                        // After the grid has grown to the new height — scrolled in the
                                        // same update, the offset was clamped to the old, shorter one.
                                        DispatchQueue.main.async { mobileWeekScroll.scrollTo(y: target) }
                                    }
                                    .onEnded { _ in
                                        GridZoom.gate.fingersLifted()
                                        if let height = mobileLiveHourHeight { mobileStoredHourHeight = Double(height) }
                                        mobileLiveHourHeight = nil
                                        mobileWeekPinch = nil
                                    }
                            )
                        }
                        .scrollIndicators(.hidden)
                        .background(Color(.systemBackground))
                        .contentMargins(.bottom, 24, for: .scrollContent)
                        .scrollPosition($mobileWeekScroll)
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                            mobileWeekScrollY.y = y
                        }
                        // While pinching, the pinch places the grid; the scroll's own pan would
                        // follow the first finger and drag it off.
                        .scrollDisabled(mobileWeekPinch != nil)
                        .frame(height: max(1, geometry.size.height - 45))
                        .task {
                            guard !didSetMobileInitialScroll else { return }
                            didSetMobileInitialScroll = true
                            await Task.yield()
                            let hour = min(22, max(0, GridOpeningHour.current - 1))
                            scrollProxy.scrollTo(hour, anchor: .top)
                        }
                    }
                }
            }
            .task {
                // The native grid applies its initial column at layout. The reference ScrollView
                // still needs an explicit request after its targets have been registered.
                guard !dayMode, !Self.nativeWeekViewport, !didSetMobileInitialHorizontalScroll else { return }
                didSetMobileInitialHorizontalScroll = true
                await Task.yield()
                mobileVisibleDayID = openingWeekColumn(visibleDays: visibleDays)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mobile.week.timeGrid")
    }

    /// The header strip (`MobileDayHeaderStrip`, extracted above) is a scroll-disabled ScrollView
    /// steered to the day-columns scroller's live offset via `headerOffset`, so the two track
    /// pixel-for-pixel without the header being independently draggable — and, since `headerOffset`
    /// is read only through that subview's own @ObservedObject, without invalidating this whole
    /// view's body on every scroll frame.
    @State private var headerOffset = HeaderScrollOffset()

    /// The hour gutter: "10 AM" on one line at the hour labels' size (`DS.Typeface.small`), which
    /// grows with Dynamic Type. At the old 36 points the 11-point label broke into "10 A / M".
    @Environment(\.dynamicTypeSize) private var typeSize
    private var mobileGutterWidth: CGFloat { DS.Typeface.Size.scaled(40, typeSize) }

    private func mobileTimeGutter(
        width: CGFloat,
        startHour: Int,
        endHour: Int,
        hourHeight: CGFloat
    ) -> some View {
        let gridHeight = CGFloat(endHour - startHour) * hourHeight
        // The other zone's hour under this one's, while a trip is on screen and the rows are
        // tall enough for two lines.
        let other = hourHeight >= 30 ? mobileSecondaryZone : nil
        let day = dayMode ? mobileVisibleWeekStart : calendarDays.first?.date ?? Date()
        return VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                VStack(alignment: .trailing, spacing: 0) {
                    Text(mobileHourLabel(hour))
                        .font(DS.Typeface.small(design: .rounded))
                        .foregroundStyle(DS.Palette.quietText)
                        .lineLimit(1)
                    if let other {
                        Text(TripTimeZone.label(forHour: hour, on: day, primary: .current, zone: other))
                            .font(DS.Typeface.small(design: .rounded))
                            .foregroundStyle(DS.Palette.quietText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityIdentifier("plan.tripZoneHour")
                    }
                }
                .monospacedDigit()
                .frame(width: width - 5, height: hourHeight, alignment: .topTrailing)
                .offset(y: hour == startHour ? 0 : -6)
                .id(hour)
            }
        }
        .background(Color(.systemBackground))
        .frame(width: width, height: gridHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(.separator).opacity(0.35)).frame(width: 0.5)
        }
    }

    private func activateMobileDayListSelection() {
        guard let occurrence = mobileDayListSelection else { return }
        mobileDayListSelection = nil
        if occurrence.syncState == .failed, let ticket = occurrence.pendingWriteID {
            failedWriteToResolve = ticket
            return
        }
        switch occurrence.behavior {
        case .event, .allDay:
            if let meeting = occurrence.meeting { openEvent(meeting) }
        case .cue:
            inspectingCue = occurrence
        case .task:
            if occurrence.reminderID != nil { occurrences.toggleTask(occurrence) }
        case .alarm, .block:
            break
        }
    }

    private func mobileDayListView(_ day: DayData) -> some View {
        NavigationStack {
            List {
                ForEach(day.items.filter {
                    mobileDayListQuery.isEmpty || ($0.title as NSString).localizedCaseInsensitiveContains(mobileDayListQuery)
                }) { occurrence in
                    Button {
                        mobileDayListSelection = occurrence
                        mobileDayList = nil
                    } label: {
                        HStack(spacing: 12) {
                            Circle().fill(sourceCalendarColor(occurrence, colors: smart.calendarColorHex)
                                ?? occurrence.tint.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(occurrence.title).foregroundStyle(.primary).lineLimit(2)
                                Text(occurrence.start.formatted(.dateTime.hour().minute()))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("calendar.day.item.\(occurrence.id)")
                }
            }
            .accessibilityIdentifier("calendar.day.items.list")
            .searchable(text: $mobileDayListQuery, prompt: "Find an item")
            .navigationTitle(day.date.formatted(.dateTime.weekday().month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetClose(id: "calendar.day.items.done") { mobileDayList = nil }
            }
        }
    }

    private func openingWeekColumn(visibleDays: Int) -> Int {
        let selected = calendarDays.firstIndex {
            Calendar.current.isDate($0.date, inSameDayAs: mobileSelectedDay)
        } ?? 0
        return min(selected, max(0, calendarDays.count - visibleDays))
    }

    private func mobileNativeCalendarViewport(
        timeWidth: CGFloat, dayWidth: CGFloat, hourHeight: CGFloat,
        gridHeight: CGFloat, visibleDays: Int, viewportHeight: CGFloat?, viewportWidth: CGFloat
    ) -> some View {
        let days = calendarDays
        let calendar = Calendar.current
        let columns = days.map { day in
            let clock = CalendarDayClockGeometry(day: day.date, calendar: calendar, startHour: 0, hourHeight: hourHeight)
            let placements = mobileDayPlacements(day, clock: clock, endHour: 24)
            return (day: day, clock: clock, placements: placements)
        }
        let items = columns.enumerated().flatMap { index, column in
            let day = column.day
            let dayKey = Occurrence.dayKey(day.date)
            return mobileNativeDayItems(day, placements: column.placements, clock: column.clock,
                                 width: dayWidth, gutter: timeWidth + CGFloat(index) * dayWidth, endHour: 24)
                .compactMap {
                    $0.clipped(to: CGRect(x: timeWidth + CGFloat(index) * dayWidth, y: 0,
                                         width: dayWidth, height: gridHeight))?
                        .namespaced(dayKey)
                }
        }
        func dayAt(_ point: CGPoint) -> DayData? {
            let index = Int(floor((point.x - timeWidth) / dayWidth))
            return days.indices.contains(index) ? days[index] : nil
        }
        let savedOffset: CGFloat? = dayMode
            ? (mobileDayScrollOffset >= 0 ? CGFloat(mobileDayScrollOffset) : nil)
            : (mobileWeekScrollY.y > 0 ? mobileWeekScrollY.y : nil)
        let openingOffset = max(0, (CGFloat(GridOpeningHour.current) - (dayMode ? 1.5 : 1)) * hourHeight)
        return DirectionalDayScrollView(
            resetToken: Occurrence.dayKey(mobileVisibleWeekStart), contentHeight: gridHeight,
            initialOffset: savedOffset ?? openingOffset,
            onHorizontalSwipe: { moveMobileWeek($0 ? 1 : -1, landingAtEdge: true) }, canBeginSwipe: { draggingEventID == nil },
            onVerticalOffset: { offset in
                if dayMode {
                    if mobileDayScrollOffset != Double(offset) { mobileDayScrollOffset = Double(offset) }
                } else { mobileWeekScrollY.y = offset }
            },
            canBeginCreate: { point in
                guard let day = dayAt(point) else { return false }
                let date = mobileGridDate(on: day.date, y: point.y, startHour: 0, hourHeight: hourHeight)
                return !day.items.contains { item in
                    let timed = dayMode ? drawnAmongTheHours(item, on: day) : item.hasScheduledTime && item.behavior != .block
                    return timed && item.start <= date && item.resolvedEnd > date
                }
            },
            onCreateChanged: { start, current in
                guard let day = dayAt(start) else { return }
                updateMobileSelection(on: day.date, startY: start.y, currentY: current.y,
                                      startHour: 0, hourHeight: hourHeight)
            },
            onCreateEnded: { start, current in
                guard let day = dayAt(start) else { return }
                updateMobileSelection(on: day.date, startY: start.y, currentY: current.y,
                                      startHour: 0, hourHeight: hourHeight)
                finishMobileSelection(on: day.date)
            },
            onCreateCancelled: { mobileDraftSelection = nil },
            hourHeight: hourHeight, hourHeightRange: Self.mobileHourHeights,
            onZoomChanged: { mobileLiveHourHeight = $0 },
            onZoomEnded: { mobileStoredHourHeight = Double($0); mobileLiveHourHeight = nil },
            nativeItems: items,
            week: CalendarColumnScrollConfiguration(
                pagesBetweenDays: dayMode, contentWidth: timeWidth + CGFloat(days.count) * dayWidth,
                columnWidth: dayWidth,
                selectedColumn: dayMode ? 1 : mobileVisibleDayID ?? openingWeekColumn(visibleDays: visibleDays),
                gutterWidth: timeWidth,
                gutter: AnyView(mobileTimeGutter(width: timeWidth, startHour: 0, endHour: 24,
                                                hourHeight: hourHeight)),
                centerDay: mobileVisibleWeekStart, selectDay: { showMobileDay($0) },
                onHorizontalOffset: { x in
                    guard !dayMode else { return }
                    let maximum = max(0, timeWidth + CGFloat(days.count) * dayWidth - viewportWidth)
                    headerOffset.set(x: min(maximum, max(0, x)), stretch: min(maximum, max(0, x)) - x)
                },
                onColumnSettled: { [center = mobileVisibleWeekStart] index in
                    if dayMode {
                        // UIKit has already scrolled the adjacent date into view. Recenter that same
                        // date at column one, keeping the live hour and fixed ruler in place.
                        if index != 1, let date = calendar.date(byAdding: .day, value: index - 1, to: center) { showMobileDay(date) }
                    } else if mobileVisibleDayID != index { mobileVisibleDayID = index }
                }),
            preservesActiveGesture: draggingEventID != nil,
            content: HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: timeWidth)
                ForEach(columns, id: \.day.date) { column in
                    mobileDayColumn(column.day, width: dayWidth, startHour: 0, endHour: 24,
                                    hourHeight: hourHeight, nativePlacements: column.placements)
                }
            }.frame(width: timeWidth + CGFloat(days.count) * dayWidth, height: gridHeight, alignment: .topLeading)
        )
        .frame(height: viewportHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mobileDayColumn(
        _ day: DayData,
        width: CGFloat,
        startHour: Int,
        endHour: Int,
        hourHeight: CGFloat,
        nativePlacements: [GridPlacement]? = nil
    ) -> some View {
        let includesEvents = nativePlacements == nil
        let calendar = Calendar.current
        let clock = CalendarDayClockGeometry(day: day.date, calendar: calendar,
                                             startHour: startHour, hourHeight: hourHeight)
        let visibleStart = clock.boundary(startHour)
        let visibleEnd = clock.boundary(endHour)
        let placements = nativePlacements ?? mobileDayPlacements(day, clock: clock, endHour: endHour)
        let neighbors = includesEvents && Self.prepareMobileNeighbors
            ? mobileNeighborPlan(placements, width: width, visibleStart: visibleStart, clock: clock) : nil
        // A day blocked all day (Busy all-day event), hatched as on the Mac.
        let blockedBy = day.items.first(where: \.blocksWholeDay)
        return ZStack(alignment: .topLeading) {
            // Today's wash marks a column among others; in Day mode there are no others.
            (day.isToday && !dayMode ? DS.Palette.todayWash : Color(.systemBackground))
                .overlay {
                    if let blockedBy {
                        BlockedDayFill(color: sourceCalendarColor(blockedBy, colors: smart.calendarColorHex) ?? DS.Palette.info)
                    }
                }
                .contentShape(Rectangle())
                .overlay {
                    // Day mode runs its own UIKit scroll view and handles creating there; this is
                    // the week grid's equivalent. A SwiftUI gesture here measured opening nothing
                    // at all — see CalendarCreateGesture for what iOS 26 does to it.
                    // Both modes take TAPS from here: the SwiftUI gesture this replaced sat inside
                    // the week grid's nested scroll views and opened nothing. Only the week grid
                    // takes drags from here; day mode recognises its own hold in UIKit already.
                    CalendarCreateGesture(
                            canBegin: { point in
                                let instant = mobileGridDate(on: day.date, y: point.y,
                                                             startHour: startHour,
                                                             hourHeight: hourHeight)
                                // Leave real events alone: a press on one of those is the start of
                                // a move, not a request for a new event on top of it.
                                return !day.items.contains {
                                    drawnAmongTheHours($0, on: day)
                                        && $0.start <= instant && $0.resolvedEnd > instant
                                }
                            },
                            // No tap-to-create. A tap on a scrolling grid is how you stop it,
                            // and every such tap opened a new event. Creating is a deliberate hold
                            // (then drag for length) or the + button — the rule Cron is praised for.
                            onTap: nil,
                            onDragChanged: { origin, current in
                                mobileSelectedDay = day.date
                                updateMobileSelection(on: day.date, startY: origin.y,
                                                      currentY: current.y, startHour: startHour,
                                                      hourHeight: hourHeight)
                            },
                            onDragEnded: { origin, current in
                                updateMobileSelection(on: day.date, startY: origin.y,
                                                      currentY: current.y, startHour: startHour,
                                                      hourHeight: hourHeight)
                                finishMobileSelection(on: day.date)
                            },
                            onDragCancelled: { mobileDraftSelection = nil },
                            handlesDrag: !dayMode && !Self.nativeWeekViewport)
                }
            ForEach(startHour...endHour, id: \.self) { hour in
                Rectangle()
                    .fill(Color(.separator).opacity(0.32))
                    .frame(height: 0.5)
                    .offset(y: CGFloat(hour - startHour) * hourHeight)
                    .allowsHitTesting(false)
            }
            ForEach(startHour..<endHour, id: \.self) { hour in
                Rectangle()
                    .fill(Color(.separator).opacity(0.12))
                    .frame(height: 0.5)
                    .offset(y: (CGFloat(hour - startHour) + 0.5) * hourHeight)
                    .allowsHitTesting(false)
            }
            if let selection = mobileDraftSelection,
               calendar.isDate(selection.day, inSameDayAs: day.date) {
                let start = clock.y(selection.start)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Palette.accent.opacity(0.24))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Palette.accent, lineWidth: 1.5)
                    }
                    .overlay(alignment: .topLeading) {
                        // The long press that starts this drag has no visible affordance of its
                        // own, so once it does take over, the range label is the confirmation
                        // that something is happening — and what it's about to do.
                        Text(selection.rangeLabel)
                            .font(DS.Typeface.small(.semibold, design: .rounded))
                            .foregroundStyle(DS.Palette.accent)
                            .padding(.horizontal, 4).padding(.top, 2)
                    }
                    .frame(
                        width: max(24, width - 6),
                        height: max(18, CGFloat(selection.durationMinutes) / 60 * hourHeight)
                    )
                    .offset(x: 3, y: max(0, start))
                    .allowsHitTesting(false)
            }
            ForEach(includesEvents ? placements : []) { placement in
                let occurrence = placement.occurrence
                let neighbor = neighbors?[occurrence.id]
                let visualEnd = neighbor?.visualEnd ?? mobileVisualEnd(for: placement, among: placements)
                let span = mobileLaneSpan(placement, width: width)
                let laneWidth = span.upperBound - span.lowerBound
                let x = span.lowerBound
                let start = clock.y(
                    max(displayStart(occurrence), visibleStart))
                let end = clock.y(
                    min(visualEnd, visibleEnd))
                // Its minutes, stretched to fit a title only where nothing is beneath it: a
                // 15-minute blocker straight before a swim was stretched over the swim when
                // zoomed out, while everything else stayed end to end.
                let blockHeight = CalendarBlockHeight.height(
                    natural: end - start,
                    minimum: 24,
                    roomBelow: (neighbor != nil ? neighbor!.nextTop : mobileTopOfNextBlock(
                        below: placement, among: placements, width: width,
                        visibleStart: visibleStart, clock: clock
                    )).map { $0 - start - 1 })
                // Same band as the Mac grid: on a calendar layout travel is time, so it occupies
                // the minutes it takes rather than being a caption on the event.
                if let outbound = outboundBand(for: occurrence) {
                    // Prefer the reserved block and clamp against the previous event, for the same
                    // two reasons as the Mac grid: the block is in the first-paint snapshot so it
                    // draws immediately, and an unclamped short leg was drawn through whatever ran
                    // before it.
                    let preferred = clock.y(
                        max(outbound.leaveBy, visibleStart))
                    let travelTop = mobileTravelBandTop(
                        placement, among: placements, clock: clock, preferred: preferred, neighbors: neighbors)
                    let travelHeight = max(5, start - travelTop)
                    if travelTop >= 0 {
                        TravelBand(minutes: outbound.minutes, height: travelHeight, detail: outbound.detail)
                            .frame(width: laneWidth, height: travelHeight)
                            .offset(x: x, y: travelTop)
                    }
                }
                // Mirrors the outbound band above, using the house glyph and blue tint so both
                // directions of the commute read as one visual language. The band starts at the
                // meeting's actual drawn bottom edge (not its nominal end time — a short meeting
                // gets stretched to the 24pt minimum block height) so it never overlaps the
                // meeting block or steals its lane.
                if let ret = returnLeg(forGrid: occurrence), (ret.end ?? ret.start) > Date() {
                    let returnEnd = ret.end ?? ret.start
                    let meetingBottom = max(0, start) + max(24, end - start)
                    let bandTop = max(
                        clock.y(max(ret.start, visibleStart)),
                        meetingBottom)
                    let bandBottom = clock.y(
                        min(returnEnd, visibleEnd))
                    let bandHeight = max(5, bandBottom - bandTop)
                    if bandTop < CGFloat(endHour - startHour) * hourHeight {
                        TravelBand(
                            minutes: Int(returnEnd.timeIntervalSince(ret.start) / 60),
                            height: bandHeight,
                            detail: ret.travel,
                            isReturn: true
                        )
                            .frame(width: laneWidth, height: bandHeight)
                            .offset(x: x, y: bandTop)
                    }
                }
                let isDragging = draggingEventID == occurrence.id
                gridBlock(occurrence, height: blockHeight, width: laneWidth)
                    // Directly on the block, BEFORE the frame/offset/zIndex chain. Attached after
                    // that chain the overlay silently never rendered — a border in this position
                    // draws and the same overlay two modifiers later does not — so the badge is
                    // kept adjacent to the thing it marks.
                    .overlay(alignment: .topTrailing) {
                        if let sync = occurrence.syncState {
                            EventSyncBadge(state: sync)
                        } else if savingEventIDs.contains(occurrence.id) {
                            ProgressView().controlSize(.small).padding(3)
                        }
                    }
                    .frame(width: laneWidth, height: blockHeight)
                    .opacity(isDragging ? 0.75 : 1)
                    .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 6 : 0, y: 3)
                    .zIndex(isDragging ? 1 : 0)
                    .offset(x: x + (isDragging ? CGFloat(dragDayShift) * width : 0),
                            y: max(0, start) + (isDragging ? dragOffsetY : 0))
                    // A failed write is the one block on the grid that is not a real event, so
                    // tapping it offers the two things that can still be done with it rather than
                    // opening a detail view for something no calendar holds.
                    .onTapGesture {
                        guard GridZoom.gate.allowsTap(), occurrence.syncState == .failed,
                              let ticket = occurrence.pendingWriteID else { return }
                        failedWriteToResolve = ticket
                    }
                    .animation(.snappy(duration: 0.18), value: optimisticStart[occurrence.id])
                    // Explicit chronological order avoids a geometry-based accessibility sort
                    // of hundreds of overlapping blocks and gives VoiceOver a stable sequence.
                    .accessibilitySortPriority(-occurrence.start.timeIntervalSince(day.date))
                    .gesture(mobileMoveGesture(for: occurrence, on: day.date,
                                               columnWidth: width, hourHeight: hourHeight))
            }

            if day.isToday && includesEvents {
                let nowY = clock.y(Date())
                if nowY >= 0, nowY <= CGFloat(endHour - startHour) * hourHeight {
                    HStack(spacing: 0) {
                        Circle().fill(DS.Palette.accent).frame(width: 6, height: 6)
                        Rectangle().fill(DS.Palette.accent).frame(height: 1)
                    }
                    .offset(y: nowY - 3)
                }
            }
        }
        // A ZStack of offset grid lines has almost no intrinsic height. Explicitly make this a
        // full-day surface: otherwise blank hours do not participate in hit testing and only an
        // existing event can receive a drag.
        .environment(\.blockedDayBase, blockedBy == nil ? nil : Color(.systemBackground))
        .frame(width: width, height: CGFloat(endHour - startHour) * hourHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(.separator).opacity(0.5)).frame(width: 0.5)
        }
        .clipped()
        // Keep each day as an accessibility container. Without this boundary SwiftUI flattens
        // the full dense week into one spatial sort; 100 events/day made an AX snapshot take
        // about five seconds and blocked the main thread during every assistive/UI-test query.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mobile.day.surface.\(day.id)")
        .accessibilityValue(
            "\(Occurrence.dayKey(day.date))|\(placements.map(\.occurrence.id).joined(separator: ","))"
        )
    }

    /// The native cells and the grid's accessibility value describe the same placement snapshot.
    private func mobileDayPlacements(_ day: DayData, clock: CalendarDayClockGeometry, endHour: Int) -> [GridPlacement] {
        let visibleStart = clock.boundary(clock.startHour)
        let visibleEnd = clock.boundary(endHour)
        let timed = day.items.filter {
            drawnAmongTheHours($0, on: day) && $0.start < visibleEnd && $0.resolvedEnd > visibleStart
        }
        // Today's reminders band can remove an otherwise timed reminder from the grid.
        if Self.reuseGridLayouts, clock.startHour == 0, endHour == 24, day.preparedPlacements.count == timed.count {
            return day.preparedPlacements
        }
        return gridPlacements(timed)
    }

    private func mobileNativeDayItems(
        _ day: DayData, placements: [GridPlacement], clock: CalendarDayClockGeometry,
        width: CGFloat, gutter: CGFloat, endHour: Int
    ) -> [CalendarViewportItem] {
        let startHour = clock.startHour
        let hourHeight = clock.hourHeight
        let visibleStart = clock.boundary(startHour)
        let visibleEnd = clock.boundary(endHour)
        let blockedBy = day.items.first(where: \.blocksWholeDay)
        let neighbors = Self.prepareMobileNeighbors
            ? mobileNeighborPlan(placements, width: width, visibleStart: visibleStart, clock: clock) : nil
        var items: [CalendarViewportItem] = []
        items.reserveCapacity(placements.count)
        for placement in placements {
                let occurrence = placement.occurrence
                let neighbor = neighbors?[occurrence.id]
                let visualEnd = neighbor?.visualEnd ?? mobileVisualEnd(for: placement, among: placements)
                let span = mobileLaneSpan(placement, width: width)
                let laneWidth = span.upperBound - span.lowerBound
                let x = span.lowerBound
                let start = clock.y(
                    max(displayStart(occurrence), visibleStart))
                let end = clock.y(
                    min(visualEnd, visibleEnd))
                // Its minutes, stretched to fit a title only where nothing is beneath it: a
                // 15-minute blocker straight before a swim was stretched over the swim when
                // zoomed out, while everything else stayed end to end.
                let blockHeight = CalendarBlockHeight.height(
                    natural: end - start,
                    minimum: 24,
                    roomBelow: (neighbor != nil ? neighbor!.nextTop : mobileTopOfNextBlock(
                        below: placement, among: placements, width: width,
                        visibleStart: visibleStart, clock: clock
                    )).map { $0 - start - 1 })
                // Same band as the Mac grid: on a calendar layout travel is time, so it occupies
                // the minutes it takes rather than being a caption on the event.
                if let outbound = outboundBand(for: occurrence) {
                    // Prefer the reserved block and clamp against the previous event, for the same
                    // two reasons as the Mac grid: the block is in the first-paint snapshot so it
                    // draws immediately, and an unclamped short leg was drawn through whatever ran
                    // before it.
                    let preferred = clock.y(
                        max(outbound.leaveBy, visibleStart))
                    let travelTop = mobileTravelBandTop(
                        placement, among: placements, clock: clock, preferred: preferred, neighbors: neighbors)
                    let travelHeight = max(5, start - travelTop)
                    if travelTop >= 0 {
                        items.append(CalendarViewportItem(id: occurrence.id + ":outbound",
                            frame: CGRect(x: gutter + x, y: travelTop, width: laneWidth, height: travelHeight)) {
                            AnyView(TravelBand(minutes: outbound.minutes, height: travelHeight, detail: outbound.detail))
                        })
                    }
                }
                // Mirrors the outbound band above, using the house glyph and blue tint so both
                // directions of the commute read as one visual language. The band starts at the
                // meeting's actual drawn bottom edge (not its nominal end time — a short meeting
                // gets stretched to the 24pt minimum block height) so it never overlaps the
                // meeting block or steals its lane.
                if let ret = returnLeg(forGrid: occurrence), (ret.end ?? ret.start) > Date() {
                    let returnEnd = ret.end ?? ret.start
                    let meetingBottom = max(0, start) + max(24, end - start)
                    let bandTop = max(
                        clock.y(max(ret.start, visibleStart)),
                        meetingBottom)
                    let bandBottom = clock.y(
                        min(returnEnd, visibleEnd))
                    let bandHeight = max(5, bandBottom - bandTop)
                    if bandTop < CGFloat(endHour - startHour) * hourHeight {
                        items.append(CalendarViewportItem(id: occurrence.id + ":return",
                            frame: CGRect(x: gutter + x, y: bandTop, width: laneWidth, height: bandHeight)) {
                            AnyView(TravelBand(minutes: Int(returnEnd.timeIntervalSince(ret.start) / 60),
                                height: bandHeight, detail: ret.travel, isReturn: true))
                        })
                    }
                }
                let isDragging = draggingEventID == occurrence.id
                items.append(CalendarViewportItem(id: occurrence.id,
                    frame: CGRect(x: gutter + x + (isDragging ? CGFloat(dragDayShift) * width : 0),
                                  y: max(0, start) + (isDragging ? dragOffsetY : 0),
                                  width: laneWidth, height: blockHeight),
                    zIndex: isDragging ? 1 : 0, retainsActiveGesture: isDragging,
                    move: occurrence.behavior == .event && occurrence.meeting != nil
                        ? CalendarViewportMove(id: occurrence.id, columnWidth: width,
                            changed: { mobileMoveChanged(occurrence, translation: $0, columnWidth: width) },
                            ended: { translation in
                                if CalendarDayCollectionView.localMovementFeedbackEnabled {
                                    return mobileCommitMove(occurrence, on: day.date, translation: translation,
                                                            columnWidth: width, hourHeight: hourHeight)
                                }
                                return mobileMoveEnded(occurrence, on: day.date, translation: translation,
                                                       columnWidth: width, hourHeight: hourHeight)
                            },
                            cancelled: {
                                if !CalendarDayCollectionView.localMovementFeedbackEnabled { cancelMobileMove() }
                            }) : nil) {
                    AnyView(gridBlock(occurrence, height: blockHeight, width: laneWidth)
                    // Directly on the block, BEFORE the frame/offset/zIndex chain. Attached after
                    // that chain the overlay silently never rendered — a border in this position
                    // draws and the same overlay two modifiers later does not — so the badge is
                    // kept adjacent to the thing it marks.
                    .overlay(alignment: .topTrailing) {
                        if let sync = occurrence.syncState {
                            EventSyncBadge(state: sync)
                        } else if savingEventIDs.contains(occurrence.id) {
                            ProgressView().controlSize(.small).padding(3)
                        }
                    }
                    .frame(width: laneWidth, height: blockHeight)

                    // A failed write is the one block on the grid that is not a real event, so
                    // tapping it offers the two things that can still be done with it rather than
                    // opening a detail view for something no calendar holds.
                    .onTapGesture {
                        guard GridZoom.gate.allowsTap(), occurrence.syncState == .failed,
                              let ticket = occurrence.pendingWriteID else { return }
                        failedWriteToResolve = ticket
                    }
                    .animation(.snappy(duration: 0.18), value: optimisticStart[occurrence.id])
                    // Explicit chronological order avoids a geometry-based accessibility sort
                    // of hundreds of overlapping blocks and gives VoiceOver a stable sequence.
                    .accessibilitySortPriority(-occurrence.start.timeIntervalSince(day.date))
                    .gesture(mobileMoveGesture(for: occurrence, on: day.date,
                                               columnWidth: width, hourHeight: hourHeight),
                             including: CalendarDayCollectionView.nativeMovementEnabled ? .subviews : .all)
                    .environment(\.blockedDayBase, blockedBy == nil ? nil : Color(.systemBackground)))
                })
            }
        if day.isToday {
            let nowY = clock.y(Date())
            if nowY >= 0, nowY <= CGFloat(endHour - startHour) * hourHeight {
                items.append(CalendarViewportItem(id: "calendar.currentTime", frame:
                    CGRect(x: gutter, y: nowY - 3, width: width, height: 6), zIndex: 2,
                    allowsHitTesting: false) {
                    AnyView(HStack(spacing: 0) {
                        Circle().fill(DS.Palette.accent).frame(width: 6, height: 6)
                        Rectangle().fill(DS.Palette.accent).frame(height: 1)
                    }.allowsHitTesting(false))
                })
            }
        }
        return items
    }

    private func mobileGridDate(
        on day: Date, y: CGFloat, startHour: Int, hourHeight: CGFloat
    ) -> Date {
        let maximumMinutes = CGFloat(23 * 60 + 45 - startHour * 60)
        let minutes = min(maximumMinutes, max(0, y / hourHeight * 60))
        return Calendar.current.date(
            byAdding: .minute,
            value: Int(minutes) + startHour * 60,
            to: Calendar.current.startOfDay(for: day)) ?? day
    }

    private func updateMobileSelection(
        on day: Date,
        startY: CGFloat,
        currentY: CGFloat,
        startHour: Int,
        hourHeight: CGFloat
    ) {
        let top = min(startY, currentY)
        let bottom = max(startY, currentY)
        func snappedDate(_ y: CGFloat, rounding: FloatingPointRoundingRule) -> Date {
            let maximumMinutes = CGFloat(23 * 60 + 55 - startHour * 60)
            let minutesAtPoint = y / hourHeight * 60
            let raw = min(maximumMinutes, max(0, minutesAtPoint))
            let minutes = Int((raw / 5).rounded(rounding)) * 5 + startHour * 60
            return Calendar.current.date(byAdding: .minute, value: minutes,
                                         to: Calendar.current.startOfDay(for: day)) ?? day
        }
        // The start snaps to the hour or half hour, so a dragged booking begins where people
        // actually book. The end keeps the five-minute grid so the length stays expressive.
        let start = BookingGrid.snappedStart(
            on: day,
            atY: top + CGFloat(startHour * 60) / 60 * hourHeight,
            hourHeight: hourHeight,
            rounding: .down)
        // Quarter-hour steps, as on the Mac grid. `startHour` offsets the grid from midnight.
        let end = BookingGrid.snappedEnd(
            on: day,
            atY: bottom + CGFloat(startHour) * hourHeight,
            hourHeight: hourHeight)
        let minutes = max(15, Int(end.timeIntervalSince(start) / 60))
        mobileDraftSelection = MobileGridSelection(day: day, start: start, durationMinutes: minutes)
    }

    private func finishMobileSelection(on day: Date) {
        guard let selection = mobileDraftSelection else { return }
        mobileDraftSelection = nil
        mobileSelectedDay = day
        newEventRequest = MobileNewEventRequest(
            start: selection.start,
            durationMinutes: selection.durationMinutes)
    }

    /// Long-press, then drag, to move an event on the mobile calendar layout.
    ///
    /// The long press is load-bearing rather than decorative: a bare DragGesture on a block
    /// competes with the week's own vertical scrolling, and touch has no hover to disambiguate
    /// intent. Holding first says "I mean this block", after which the drag is unambiguous.

    private func mobileMoveGesture(
        for occ: Occurrence, on day: Date, columnWidth: CGFloat, hourHeight: CGFloat
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                mobileMoveChanged(occ, translation: drag.translation, columnWidth: columnWidth)
            }
            .onEnded { value in
                var translation = CGSize.zero
                if case .second(true, let drag?) = value { translation = drag.translation }
                mobileMoveEnded(occ, on: day, translation: translation,
                                columnWidth: columnWidth, hourHeight: hourHeight)
            }
    }

    private func mobileMoveChanged(_ occ: Occurrence, translation: CGSize, columnWidth: CGFloat) {
        guard occ.behavior == .event, occ.meeting != nil else { return }
        if draggingEventID != occ.id {
            draggingEventID = occ.id
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        dragOffsetY = translation.height
        dragDayShift = Int((translation.width / max(columnWidth, 1)).rounded())
    }

    private func cancelMobileMove() {
        draggingEventID = nil; dragOffsetY = 0; dragDayShift = 0
    }

    @discardableResult
    private func mobileMoveEnded(_ occ: Occurrence, on day: Date, translation: CGSize,
                                 columnWidth: CGFloat, hourHeight: CGFloat) -> Bool {
        defer { cancelMobileMove() }
        guard draggingEventID == occ.id else { return false }
        return mobileCommitMove(occ, on: day, translation: translation,
                                columnWidth: columnWidth, hourHeight: hourHeight)
    }

    private func mobileCommitMove(_ occ: Occurrence, on _: Date, translation: CGSize,
                                  columnWidth: CGFloat, hourHeight: CGFloat) -> Bool {
        guard let meeting = occ.meeting else { return false }
        let shift = Int((translation.width / max(columnWidth, 1)).rounded())
        guard let newStart = CalendarMoveGeometry.start(
            original: occ.start, dayShift: shift,
            minutes: Double(translation.height / hourHeight) * 60, calendar: .current)
        else { return false }
        guard abs(newStart.timeIntervalSince(occ.start)) >= 60 else { return false }
        if smart.meetingRecurs(meeting) {
            pendingRecurringMove = PendingEventMove(meeting: meeting, occurrenceID: occ.id, newStart: newStart)
        } else {
            commitMove(meeting, occurrenceID: occ.id, to: newStart, span: .thisEvent)
        }
        return true
    }

    /// Where a placement sits across the Day column: its lane of the column's width.
    private func mobileLaneSpan(_ placement: GridPlacement, width: CGFloat) -> Range<CGFloat> {
        let gap: CGFloat = 2
        let laneWidth = max(
            24,
            (width - 6 - CGFloat(placement.laneCount - 1) * gap) / CGFloat(placement.laneCount))
        let x = 3 + CGFloat(placement.lane) * (laneWidth + gap)
        return x..<(x + laneWidth * CGFloat(placement.laneSpan) + gap * CGFloat(placement.laneSpan - 1))
    }

    /// The top of the nearest block drawn beneath `placement` across the same stretch of the
    /// column, for `CalendarBlockHeight` — nil when nothing is beneath it.
    private func mobileNeighborPlan(
        _ placements: [GridPlacement], width: CGFloat,
        visibleStart: Date, clock: CalendarDayClockGeometry
    ) -> [String: CalendarMobileNeighbors.Result]? {
        let inputs = placements.map { placement in
            let occurrence = placement.occurrence
            let start = displayStart(occurrence)
            return CalendarMobileNeighbors.Input(id: occurrence.id, start: start,
                end: CalendarMoveGeometry.end(originalStart: occurrence.start,
                    originalEnd: occurrence.resolvedEnd, displayedStart: start),
                lane: placement.lane, span: mobileLaneSpan(placement, width: width),
                top: clock.y(max(start, visibleStart)))
        }
        return CalendarMobileNeighbors.indexed(inputs)
    }

    private func mobileTopOfNextBlock(
        below placement: GridPlacement, among placements: [GridPlacement], width: CGFloat,
        visibleStart: Date, clock: CalendarDayClockGeometry
    ) -> CGFloat? {
        let mine = mobileLaneSpan(placement, width: width)
        let myStart = displayStart(placement.occurrence)
        return placements
            .filter { $0.occurrence.id != placement.occurrence.id && displayStart($0.occurrence) > myStart }
            .filter { mobileLaneSpan($0, width: width).overlaps(mine) }
            .map { clock.y(max(displayStart($0.occurrence), visibleStart)) }
            .min()
    }

    private func mobileVisualEnd(for placement: GridPlacement, among placements: [GridPlacement]) -> Date {
        let occurrence = placement.occurrence
        let end = CalendarMoveGeometry.end(originalStart: occurrence.start,
                                           originalEnd: occurrence.resolvedEnd,
                                           displayedStart: displayStart(occurrence))
        guard let next = placements
            .filter({ $0.occurrence.id != occurrence.id && $0.lane == placement.lane
                && displayStart($0.occurrence) >= end })
            .min(by: { displayStart($0.occurrence) < displayStart($1.occurrence) }),
              displayStart(next.occurrence).timeIntervalSince(end) <= 5 * 60
        else { return end }
        return displayStart(next.occurrence)
    }

    private func updateMobileSecondaryZone() {
        let zone = TripZoneForGrid.zone(first: calendarDays.first?.date, last: calendarDays.last?.date,
                                        legs: smart.flightLegs)
        if zone?.identifier != mobileSecondaryZone?.identifier { mobileSecondaryZone = zone }
    }

    private func mobileHourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private var mobileVisibleWeekStart: Date {
        let calendar = Calendar.app
        if dayMode {
            let today = calendar.startOfDay(for: Date())
            return calendar.date(byAdding: .day, value: mobileWeekOffset, to: today) ?? today
        }
        let current = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .weekOfYear, value: mobileWeekOffset, to: current) ?? current
    }

    private var mobileWeekRangeTitle: String {
        if dayMode { return mobileVisibleWeekStart.formatted(.dateTime.weekday(.wide).month().day()) }
        guard let last = Calendar.current.date(byAdding: .day, value: 6, to: mobileVisibleWeekStart)
        else { return "This week" }
        let calendar = Calendar.current
        let sameMonth = calendar.component(.month, from: mobileVisibleWeekStart)
            == calendar.component(.month, from: last)
        let sameYear = calendar.component(.year, from: mobileVisibleWeekStart)
            == calendar.component(.year, from: last)
        if sameMonth && sameYear {
            return "\(mobileVisibleWeekStart.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.day()))"
        }
        if sameYear {
            return "\(mobileVisibleWeekStart.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return Self.mobileRangeFormatter.string(from: mobileVisibleWeekStart, to: last)
    }

    private func calendarInput(_ all: [Occurrence]) -> CalendarInput {
        let visible = PendingRemovals.visible(all, id: { $0.meeting?.eventID }, start: \.start,
                                               hiding: ToastCenter.shared.hiddenIDs)
        let calendar = Calendar.current
        let scoped = ShellCalendarScope.visible(visible, in: calendarScope.calendarIDs)
        return CalendarInput(occurrences: scoped, start: mobileVisibleWeekStart,
                             today: calendar.startOfDay(for: Date()), calendar: calendar)
    }

    private func makeMobileDays(_ input: CalendarInput) -> [DayData] {
        let calendar = input.calendar
        let offsets = dayMode ? Array(-1...1) : Array(0..<7)
        return offsets.compactMap { offset -> DayData? in
            guard let day = calendar.date(
                byAdding: .day,
                value: offset,
                to: input.start) else { return nil }
            let items = DayColumn.occurrences(input.occurrences, on: day, calendar: calendar)
            let committed = items
                .filter { $0.behavior == .event || ($0.behavior == .task && $0.hasScheduledTime) }
                .reduce(0.0) { $0 + $1.resolvedEnd.timeIntervalSince($1.start) } / 3_600
            return DayData(
                id: dayMode ? offset + 1 : offset,
                date: day,
                weekday: Self.weekdayFmt.string(from: day).uppercased(),
                dayNum: Self.dayFmt.string(from: day),
                letter: Self.letterFmt.string(from: day),
                isToday: calendar.isDate(day, inSameDayAs: input.today),
                items: items,
                committed: committed,
                calendarGrid: true)
        }
    }

    private func rebuildMobileCalendar(_ all: [Occurrence]) {
        // Everything outstanding, including reminders outside the visible days.
        let overdue = occurrences.occurrences.filter(\.isOverdueReminder)
        if overdue != mountedOverdueTasks { mountedOverdueTasks = overdue }
        let input = calendarInput(all)
        #if DEBUG
        let reusePreparedInput = !ProcessInfo.processInfo.arguments.contains("--calendar-reprepare-on-appear")
        #else
        let reusePreparedInput = true
        #endif
        if !reusePreparedInput || preparedCalendarInput != input {
            preparedCalendarInput = input
            let _ = RenderStats.note("Calendar.prepareDays")
            let rebuilt: [DayData]
            if mountedDays == nil, reusePreparedInput, openingDays.0 == input {
                rebuilt = openingDays.1
            } else {
                rebuilt = makeMobileDays(input)
            }
            if rebuilt != mountedDays {
                mountedDays = rebuilt
                mountSnapshot.clear()
                ProblemReportCenter.shared.noteCalendar(
                    start: rebuilt.first?.date,
                    end: rebuilt.last.flatMap { input.calendar.date(byAdding: .day, value: 1, to: $0.date) },
                    occurrencesByDay: rebuilt.lazy.map(\.items))
            }
        }
        updateMobileSecondaryZone()
    }

    private func moveMobileWeek(_ delta: Int, landingAtEdge: Bool = false) {
        let edge = delta > 0 ? 0 : 6
        let visibleDay = landingAtEdge ? edge : mobileVisibleDayID
        let calendar = Calendar.current
        let selectedOffset = dayMode ? 0 : landingAtEdge ? edge : min(6, max(0,
            calendar.dateComponents([.day], from: mobileVisibleWeekStart,
                                    to: calendar.startOfDay(for: mobileSelectedDay)).day ?? 0))
        mobileWeekOffset += delta
        mobileSelectedDay = calendar.date(byAdding: .day, value: selectedOffset,
                                          to: mobileVisibleWeekStart) ?? mobileVisibleWeekStart
        mobileVisibleDayID = dayMode ? 1 : (visibleDay ?? selectedOffset)
        rebuildMobileCalendar(mobileWindowOccurrences())
        Task { await refreshMobileWeek() }
    }

    /// The page that holds `date`: its day in Day, its week in Week.
    private func showMobileDay(_ date: Date) {
        let calendar = Calendar.app
        let target: Int
        if dayMode {
            target = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
        } else {
            let now = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
            let then = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
            target = calendar.dateComponents([.weekOfYear], from: now, to: then).weekOfYear ?? 0
        }
        if target != mobileWeekOffset { moveMobileWeek(target - mobileWeekOffset) }
        mobileSelectedDay = date
    }

    /// A booking push's tap: the booking's day, then its event, read again once if it isn't here
    /// yet (a booking made a moment ago). A cancelled one is only its day.
    private func openFromPush(_ target: BananaService.BookingPushTarget) async {
        if let start = target.start { showMobileDay(start) }
        guard !target.cancelled, target.eventID != nil else { return }
        var meeting = BookingPushes.meeting(for: target)
        if meeting == nil {
            await smart.refreshCalendar()
            await occurrences.recompute()
            meeting = BookingPushes.meeting(for: target)
        }
        guard let meeting else { return }
        if target.start == nil { showMobileDay(meeting.start) }
        openEvent(meeting)
    }

    private func moveMobileWeekToCurrent() {
        mobileWeekOffset = 0
        mobileSelectedDay = Date()
        mobileVisibleDayID = nil
        rebuildMobileCalendar(mobileWindowOccurrences())
        Task { await refreshMobileWeek() }
    }

    private func mobileWindowOccurrences() -> [Occurrence] {
        let calendar = Calendar.current
        let start = dayMode
            ? (calendar.date(byAdding: .day, value: -1, to: mobileVisibleWeekStart) ?? mobileVisibleWeekStart)
            : mobileVisibleWeekStart
        guard let end = calendar.date(byAdding: .day, value: dayMode ? 3 : 7, to: mobileVisibleWeekStart)
        else { return occurrences.occurrences }
        #if DEBUG
        // "--ui-audit" alone is the macOS route's own flag and is never passed on an iOS
        // launch, so this used to never catch --today/--day/--week/--tomorrow: the Day/Week
        // grid read the live, request-scoped planning-window cache instead of the fixture
        // injected straight into `occurrences.occurrences`, which starts empty on the
        // Simulator -- so a screenshot route's grid rendered no meetings at all. Same class of
        // stale-guard gap as the `.task` above; VisualAuditRoute is the complete iOS list.
        let arguments = ProcessInfo.processInfo.arguments
        if VisualAuditRoute.matches(arguments)
            && !arguments.contains("--day-cache-backfill-regression") {
            return occurrences.occurrences
        }
        #endif
        return occurrences.planningWindow(from: start, to: end)
    }

    @MainActor
    private func refreshMobileWeek() async {
        // A planning-window refresh publishes new occurrences. That publication rebuilds this
        // view, but it must not initiate the exact same network refresh again or the Day pager
        // spends its life rebuilding and looks visibly laggy.
        guard !mobileWeekLoading.active else { return }
        let requestedStart = mobileVisibleWeekStart
        let calendar = Calendar.current
        let requestStart = dayMode
            ? (calendar.date(byAdding: .day, value: -1, to: requestedStart) ?? requestedStart)
            : requestedStart
        guard let end = calendar.date(byAdding: .day, value: dayMode ? 3 : 7, to: requestedStart)
        else { return }
        mobileWeekLoading.set(true)
        await occurrences.refreshPlanningWindow(from: requestStart, to: end)
        if requestedStart == mobileVisibleWeekStart {
            rebuildMobileCalendar(mobileWindowOccurrences())
            mobileWeekLoading.set(false)
        } else {
            // Navigation happened while the old window was in flight. Finish it, then fetch the
            // newly visible range once — never run both refresh loops concurrently.
            mobileWeekLoading.set(false)
            await refreshMobileWeek()
        }
    }

    private func mobileDefaultNewEventStart() -> Date {
        let calendar = Calendar.current
        if calendar.isDateInToday(mobileSelectedDay) {
            let interval: TimeInterval = 30 * 60
            return Date(timeIntervalSinceReferenceDate:
                ceil(Date().timeIntervalSinceReferenceDate / interval) * interval)
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: mobileSelectedDay)
            ?? mobileSelectedDay
    }

    private static let mobileRangeFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - Agenda

    // MARK: - Styled row dispatch

    // MARK: - Row contents (no card)

    // MARK: - Trailing / duration text

    private func durMin(_ occ: Occurrence) -> Int { max(0, Int(occ.resolvedEnd.timeIntervalSince(occ.start) / 60)) }
    private func spanItem(_ occ: Occurrence) -> Bool { occ.behavior == .event || (occ.behavior == .task && occ.hasScheduledTime) }
    /// Proportional card height for the .height style.
    private func blockHeight(_ occ: Occurrence) -> CGFloat {
        guard spanItem(occ) else { return 46 }
        return min(150, 46 + CGFloat(max(0, durMin(occ) - 30)) * 0.8)
    }
    // MARK: - Time grid (per day)

    /// Assign simultaneous items to deterministic side-by-side lanes. Previously every block
    /// occupied the same full-width x position, so overlapping meetings/reminders covered each
    /// other and only the topmost action could be used.

    ///
    /// (Widening a block into free lanes was tried on 1 Nov 2026 and reverted: a reminder is drawn
    /// taller than its duration, so a widened neighbour covered its circle, and the empty slot
    /// drag-to-create relies on disappeared.)
    private func gridPlacements(_ occurrences: [Occurrence]) -> [GridPlacement] {
        CalendarLaneAllocator.placements(occurrences)
    }

    @ViewBuilder private func gridBlock(_ occ: Occurrence, height: CGFloat = 24, width: CGFloat = .infinity) -> some View {
        switch occ.behavior {
        case .allDay:
            EmptyView()   // above the grid, in the day's all-day band
        case .event:
            if occ.syncState != nil {
                // Not yet on any calendar, so there is nothing to open — and wrapping it in a
                // button would swallow the tap that offers to retry a failed write.
                gridBlockContent(occ, height: height)
            } else if let meeting = occ.meeting {
                Button {
                    guard GridZoom.gate.allowsTap() else { return }
                    openEvent(meeting)
                } label: { gridBlockContent(occ, height: height) }
                    .buttonStyle(.plain)
            } else {
                // An event with no meeting info still has to be drawn. Every event read from a
                // calendar carries one, so this used to be an `if` with no `else` — and an event
                // the user had just created, which has no calendar identity yet, rendered as
                // nothing at all: present in the day, in the placements, and invisible. There is
                // nothing to open, so it is content without a button.
                gridBlockContent(occ, height: height)
            }
        case .cue:
            if let routine = routines.routines.first(where: { $0.id == occ.routineID }) {
                Button {
                    guard GridZoom.gate.allowsTap() else { return }
                    inspectingCue = occ
                } label: { gridBlockContent(occ, height: height) }
                    .buttonStyle(.plain)
                    .contextMenu { cueMenu(routine, occ) }
            } else {
                gridBlockContent(occ, height: height)
            }
        case .task:
            Button {
                // A pinch that began on a task used to tick it off as the finger lifted.
                guard GridZoom.gate.allowsTap(), occ.reminderID != nil else { return }
                // The block opens the reminder; its circle ticks it (below).
                editingTask = occ
            } label: {
                gridBlockContent(occ, height: height)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) {
                // Over the circle the block draws at its leading edge: a finger's worth of it,
                // where the block has the room (`TaskTicks.blockHasTickTarget`).
                if TaskTicks.blockHasTickTarget(width: width) {
                    Button {
                        guard GridZoom.gate.allowsTap(), occ.reminderID != nil else { return }
                        TaskTick.toggle(occ)
                    } label: {
                        Color.clear.frame(width: TaskTicks.tickTargetWidth, height: min(max(height, 22), 34))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(occ.completed ? "Mark \(occ.title) not done" : "Mark \(occ.title) done")
                }
            }
            .contextMenu { taskMenu(occ) }
        case .alarm:
            gridBlockContent(occ, height: height)
                .contextMenu {
                    Button(role: .destructive) {
                        if let id = UUID(uuidString: String(occ.id.dropFirst("alarm:".count))), let alarms {
                            DeleteUndo.alarm(id, in: alarms)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        case .block:
            EmptyView()
        }
    }



    private func gridBlockContent(_ occ: Occurrence, height: CGFloat) -> some View {
        // Events take the colour of the calendar they came from, the way Apple Calendar and
        // every other calendar client does it. Every event being the same grey made a mixed
        // week — work, personal, shared — read as one undifferentiated wall. Falls back to grey
        // when the source has no colour, or the calendar list hasn't loaded yet.
        let color = occ.behavior == .event
            ? (sourceCalendarColor(occ, colors: smart.calendarColorHex) ?? Color(.systemGray))
            : occ.tint.color
        let ribbons = EventStateStyle.ribbonColors(occ, tint: color, colors: smart.calendarColorHex)
        let returnCaption: String?
        if occ.behavior == .event, let meeting = occ.meeting,
           let ret = returnLeg(for: meeting), (ret.end ?? ret.start) > Date() {
            let mins = Int((ret.end ?? ret.start).timeIntervalSince(ret.start) / 60)
            returnCaption = height >= 40
                ? "Home by \(ret.start.formatted(.dateTime.hour().minute())) · \(mins) min"
                : ret.start.formatted(.dateTime.hour().minute())
        } else { returnCaption = nil }
        let paint = CalendarEventPaint(occurrence: occ, tint: color, ribbons: ribbons,
            startText: "", timeRange: height >= 40 && returnCaption == nil
                ? TimeRangeText.compact(occ.start, occ.resolvedEnd) : "", returnCaption: returnCaption)
        return CalendarPreparedArtwork(paint: paint, height: height, layout: .mobile)
        .blockedDayBase(cornerRadius: DS.Radius.block)
        .contentShape(Rectangle())
        // One element with one label. Without `.ignore` the label was given to each line of text
        // inside as well, and VoiceOver read "Wake, 6:30 AM" three times.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(occ.title), \(occ.start.formatted(.dateTime.hour().minute()))")
    }

    // MARK: - Menus

    @ViewBuilder private func cueMenu(_ r: Routine, _ occ: Occurrence) -> some View {
        if occ.occurrenceKey != nil, !occ.skipped {
            Button { CueCompletion.toggle(occ) } label: {
                Label(occ.completed ? "Mark not completed" : "Mark completed", systemImage: occ.completed ? "circle" : "checkmark.circle")
            }
        }
        if occ.id.hasPrefix("extra:") {
            Button(role: .destructive) {
                DeleteUndo.extra(String(occ.id.dropFirst("extra:".count)), named: occ.title) { await OccurrenceStore.shared.recompute() }
            } label: { Label("Delete this extra", systemImage: "trash") }
        } else if occ.occurrenceKey != nil {
            if occ.skipped {
                Button { CueSkip.restore(occ) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            } else if !occ.completed {
                Button { CueSkip.skip(occ) } label: { Label("Skip", systemImage: "xmark.circle") }
                Button { movingOcc = occ } label: { Label("Move…", systemImage: "clock.arrow.circlepath") }
            }
        }
        Button { addingExtraFor = r } label: { Label("Add another…", systemImage: "plus.circle") }
        Button { editing = r } label: { Label("Edit cue", systemImage: "pencil") }
    }

    @ViewBuilder private func taskMenu(_ occ: Occurrence) -> some View {
        Button { editingTask = occ } label: {
            Label("Edit reminder…", systemImage: "pencil")
        }
        Button {
            TaskTick.toggle(occ)
        } label: { Label(occ.completed ? "Mark not done" : "Mark done", systemImage: occ.completed ? "circle" : "checkmark.circle") }
        if occ.canBeMarkedMissed {
            Button { Task { await occurrences.markMissed(occ) } } label: { Label("Missed it", systemImage: "xmark.circle") }
        }
        Button { reschedulingTask = occ } label: { Label("Reschedule…", systemImage: "clock.arrow.circlepath") }
        #if BANANA_MODULE_FOOD
        if occ.isRepeatingTask {
            // Something taken each day belongs in Taken: logged taken or skipped, checked for clashes.
            Button { AnchorSuggestionStore.shared.move(reminder: occ) } label: {
                Label("Move to Taken…", systemImage: "pills")
            }
        }
        #endif
        if let id = occ.reminderID {
            let current = TaskDurationStore.shared.minutes(for: id)
            Menu {
                ForEach(TaskDurationStore.options, id: \.self) { m in
                    Button { TaskDurationStore.shared.set(id, minutes: m); Task { await occurrences.recompute() } } label: {
                        Label("\(m) min", systemImage: m == current ? "checkmark" : "")
                    }
                }
            } label: { Label("Reserve \(current) min", systemImage: "timer") }
        }
    }

    // MARK: - Helpers

    private func leaveBy(for meeting: MeetingInfo) -> NotificationService.CommuteLeg? {
        smart.commuteLegs.first { abs($0.start.timeIntervalSince(meeting.start)) < 60 }
    }
    /// The "Travel home" hold SmartScheduleStore reserved right after this meeting (its own
    /// derived block, not a CommuteLeg — return-home has no notification leg to key off). The
    /// block's start is pinned to exactly this meeting's departure (end ?? start), so a tight
    /// tolerance is a safe match key, mirroring `leaveBy(for:)` above.
    private func returnLeg(for meeting: MeetingInfo) -> Occurrence? {
        let departure = meeting.end ?? meeting.start
        return occurrences.returnTravel(startingAt: departure)
    }

    /// Grid-layout variant: a commute band is only meaningful before a meeting still to come.
    private func travelLeg(for occurrence: Occurrence) -> NotificationService.CommuteLeg? {
        guard occurrence.behavior == .event, occurrence.start > Date(),
              let meeting = occurrence.meeting else { return nil }
        return leaveBy(for: meeting)
    }

    /// Mobile counterpart of the Mac grid's `outboundBand(forGrid:)` — reserved block first, live
    /// commute leg as the fallback.
    private func outboundBand(for occurrence: Occurrence) -> (leaveBy: Date, minutes: Int, detail: TravelLegDetail?)? {
        guard occurrence.behavior == .event, occurrence.start > Date() else { return nil }
        if let block = occurrences.outboundTravel(endingAt: occurrence.start) {
            return (block.start, max(1, Int(block.resolvedEnd.timeIntervalSince(block.start) / 60)), block.travel)
        }
        return travelLeg(for: occurrence).map { ($0.leaveBy, $0.travelMinutes, $0.detail) }
    }

    /// The highest a travel band may start without covering the event before it, same lane only.
    private func mobileTravelBandTop(_ placement: GridPlacement,
                                     among placements: [GridPlacement],
                                     clock: CalendarDayClockGeometry,
                                     preferred: CGFloat,
                                     neighbors: [String: CalendarMobileNeighbors.Result]?) -> CGFloat {
        let start = displayStart(placement.occurrence)
        var top = preferred
        for other in placements where other.lane == placement.lane
            && other.occurrence.id != placement.occurrence.id {
            let otherStart = displayStart(other.occurrence)
            guard otherStart < start else { continue }
            let otherTop = clock.y(otherStart)
            let end = neighbors?[other.occurrence.id]?.visualEnd ?? mobileVisualEnd(for: other, among: placements)
            let otherBottom = clock.y(end)
            top = max(top, max(otherTop + 24, otherBottom))
        }
        return top
    }

    /// Grid-layout variant of `returnLeg(for:)`, matched by occurrence the same way
    /// `travelLeg(for:)` matches the outbound leg — mirrors `returnLeg(forGrid:)` on the Mac
    /// grid. `.block` occurrences never get a grid block of their own (filtered out of `timed`
    /// in `mobileDayColumn`), so this is the only place the return leg reaches the mobile grid.
    private func returnLeg(forGrid occurrence: Occurrence) -> Occurrence? {
        guard occurrence.behavior == .event, let meeting = occurrence.meeting else { return nil }
        return returnLeg(for: meeting)
    }
    private func eventDetail(_ sheet: CalendarEventSheet, close: (() -> Void)? = nil) -> some View {
        CalendarEventSheetView(sheet: sheet, onComplete: {
            Task {
                await smart.refreshAgenda()
                await occurrences.recompute()
            }
        }, close: close)
    }

    private func openEvent(_ meeting: MeetingInfo) {
        // A meeting with no identifier is one Banana has created but no calendar has accepted yet.
        // There is nothing to inspect.
        guard meeting.eventID != nil else { return }
        if GoogleCalendarService.isGoogleEventInfoID(meeting.eventID) {
            eventSheet = CalendarEventSheet(googleMeeting: meeting)
        }
    }

    private static let weekdayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d"; return f }()
    private static let letterFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEEE"; return f }()
}
#endif

#if os(macOS)
/// The slots the share-availability panel is offering, as dashed accent blocks on the grid —
/// what Rise calls "options". Its own view, observing only the navigator, so adjusting the
/// panel redraws these few rectangles and not the week.
private struct OfferedSlotsOverlay: View {
    @ObservedObject private var nav = MacNavigator.shared
    let day: Date
    let width: CGFloat
    let hourHeight: CGFloat

    var body: some View {
        let dayStart = Calendar.current.startOfDay(for: day)
        let slots = (nav.rightPanelVisible ? nav.offeredSlots : []).filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        ZStack(alignment: .topLeading) {
            ForEach(slots, id: \.start) { slot in
                let y = CGFloat(slot.start.timeIntervalSince(dayStart) / 3600) * hourHeight
                let height = max(14, CGFloat(slot.duration / 3600) * hourHeight - 2)
                RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
                    .fill(DS.Palette.accent.opacity(DS.Tint.subtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
                            .strokeBorder(DS.Palette.accent.opacity(0.8),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                    .overlay(alignment: .topLeading) {
                        Text(TimeRangeText.compact(slot.start, slot.end))
                            .font(DS.Typeface.eventMeta.weight(.semibold))
                            .foregroundStyle(DS.Palette.accent)
                            .lineLimit(1)
                            .padding(.horizontal, DS.Space.s - 2)
                            .padding(.top, DS.Space.xs)
                    }
                    .frame(width: max(8, width - DS.Space.s), height: height)
                    .offset(x: DS.Space.xs, y: y + 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif

/// Preserve every event/action while bounding accessibility geometry ordering to a day.
/// The legacy flattened hierarchy remains available only as a DEBUG comparison.
private struct AgendaDayAccessibility: ViewModifier {
    let date: Date
    let index: Int
    private static let enabled: Bool = {
        #if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("--calendar-ungrouped-agenda-accessibility")
        #else
        return true
        #endif
    }()
    @ViewBuilder func body(content: Content) -> some View {
        if Self.enabled {
            content.accessibilityElement(children: .contain)
                .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                .accessibilityIdentifier("plan.agenda.day.\(index)")
        } else {
            content
        }
    }
}
