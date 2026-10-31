import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// How the agenda conveys each item's duration. A bench: switch live from the nav‑bar ruler.
enum DurationStyle: String, CaseIterable, Identifiable {
    case range, height, grid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .range:  return "Time range + length"
        case .height: return "Proportional heights"
        case .grid:   return "Time grid"
        }
    }
    var icon: String {
        switch self {
        case .range:  return "text.alignright"
        case .height: return "arrow.up.and.down"
        case .grid:   return "calendar.day.timeline.left"
        }
    }
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
    struct Placement {
        let occurrence: Occurrence
        let lane: Int
        let laneCount: Int
    }

    private static let displayedMinuteTolerance: TimeInterval = 60

    static func placements(_ occurrences: [Occurrence]) -> [Placement] {
        // A cache-first render and the subsequent EventKit/Google refresh can deliver equal
        // intervals in a different order. `sort` deliberately makes no stability promise for
        // equal values, so using only start/end let two simultaneous blocks trade columns while
        // the same screen was settling. The durable occurrence ID is our final tie-breaker: a
        // given event owns the same lane on every render, regardless of source arrival order.
        let sorted = occurrences.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.resolvedEnd != $1.resolvedEnd { return $0.resolvedEnd < $1.resolvedEnd }
            return $0.id < $1.id
        }
        var result: [Placement] = []
        var cluster: [Occurrence] = []
        var clusterEnd = Date.distantPast

        func appendCluster(_ items: [Occurrence], to result: inout [Placement]) {
            guard !items.isEmpty else { return }
            var laneEnds: [Date] = []
            var assignments: [(Occurrence, Int)] = []
            for item in items {
                if let lane = laneEnds.firstIndex(where: {
                    $0.timeIntervalSince(item.start) < displayedMinuteTolerance
                }) {
                    laneEnds[lane] = item.resolvedEnd
                    assignments.append((item, lane))
                } else {
                    laneEnds.append(item.resolvedEnd)
                    assignments.append((item, laneEnds.count - 1))
                }
            }
            let laneCount = max(1, laneEnds.count)
            result += assignments.map {
                Placement(occurrence: $0.0, lane: $0.1, laneCount: laneCount)
            }
        }

        for item in sorted {
            if !cluster.isEmpty,
               clusterEnd.timeIntervalSince(item.start) < displayedMinuteTolerance {
                appendCluster(cluster, to: &result)
                cluster.removeAll(keepingCapacity: true)
                clusterEnd = .distantPast
            }
            cluster.append(item)
            clusterEnd = max(clusterEnd, item.resolvedEnd)
        }
        appendCluster(cluster, to: &result)
        return result
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

/// A hatched band, drawn deliberately unlike an event: this is time consumed, not an
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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            if height >= 22 {
                Text(text)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: height >= 22 ? .leading : .center)
        .background(
            Stripes(color: tint.opacity(DS.Tint.strong))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(tint.opacity(DS.Tint.strong), lineWidth: 1)
        }
        .blockedDayBase(cornerRadius: 3)
        .allowsHitTesting(false)
        .accessibilityLabel(isReturn ? "Travel home, \(text)" : "Travel, \(text)")
    }
}

/// A drag that landed on a repeating event and is waiting on this-one-vs-all-future.
/// An event's colour comes from the calendar it lives in. Shared by both week grids.
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

    @State private var days: [MacWeekDay] = []
    @State private var visibleSmartRevision = 0
    @State private var showSettings = false
    @State private var editing: Routine?
    @State private var movingOccurrence: Occurrence?
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
    @State private var overdueReminders: [Occurrence] = []
    /// The day whose whole "No time" list is open, from its "+N more".
    @State private var untimedOverflowDay: Date?
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
    @State private var loadingWeek = false
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
        let crowded = days.contains { day in
            day.items.filter { !$0.hasScheduledTime && $0.behavior != .block && $0.behavior != .task }.count > 2
        }
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
            .toolbar { plannerToolbar }
            .sheet(isPresented: $showSettings) { SettingsView(showsDoneButton: true) }
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
            .alert("Couldn't move that event",
                   isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })) {
                Button("OK", role: .cancel) { moveError = nil }
            } message: {
                Text(moveError ?? "")
            }
            .sheet(item: $movingOccurrence) { occurrence in
                OccurrenceTimeSheet(title: "Move \(occurrence.title)", initial: occurrence.start) { newStart in
                    if let key = occurrence.occurrenceKey {
                        ExceptionStore.shared.reschedule(key, to: newStart)
                    }
                    Task { await occurrences.recompute() }
                }
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
                    NewTaskSheet(reminderID: id)
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
            .sheet(isPresented: $showingAlarms) { OneOffAlarmSheet() }
        }
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
            case .shareAvailability: MacNavigator.shared.showsAvailability.toggle()
            default: break
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

    /// Everything that acts on the planner, in the window toolbar: move through time, choose the
    /// view, share availability, create. Settings lives in the sidebar, not here.
    @ToolbarContentBuilder private var plannerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if loadingWeek { ProgressView().controlSize(.small) }
        }
        ToolbarItem(placement: .automatic) {
            ControlGroup {
                Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .help(dayMode ? "Previous day (K)" : (weekSpan.isAlignedWeek ? "Previous week (K)" : "Back \(weekSpan.rawValue) days (K)"))
                    .accessibilityLabel("Earlier")
                Button("Today") { moveToCurrentWeek() }
                    .disabled(weekOffset == 0)
                    .help("Go to today (T)")
                Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }
                    .help(dayMode ? "Next day (J)" : (weekSpan.isAlignedWeek ? "Next week (J)" : "Forward \(weekSpan.rawValue) days (J)"))
                    .accessibilityLabel("Later")
            }
        }
        ToolbarItem(placement: .automatic) { MacPlannerViewMenu() }
        ToolbarItem(placement: .automatic) {
            Button { MacNavigator.shared.showsAvailability.toggle() } label: {
                Image(systemName: "calendar.badge.checkmark")
            }
            .help("Share availability (S)")
        }
        ToolbarItem(placement: .primaryAction) {
            // A MENU, like Day's "+", not an event-only button: the calendar — where you can see
            // when you are free — is exactly where a reminder should be creatable too.
            Menu {
                Button {
                    newEventRequest = MacNewEventRequest(start: defaultNewEventStart(), durationMinutes: 60)
                } label: {
                    Label("New calendar event", systemImage: "calendar.badge.plus")
                }
                Button {
                    newTaskDue = defaultNewEventStart()
                    showingNewTask = true
                } label: {
                    Label("New reminder", systemImage: "checklist")
                }
                Button { showingAlarms = true } label: {
                    Label("New alarm", systemImage: "alarm")
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .help("Create an event (C), a reminder or an alarm")
            .accessibilityIdentifier("mac.week.newEvent")
        }
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
                            .foregroundStyle(day.isToday ? Color.white : Color.primary)
                            .padding(.horizontal, day.isToday ? 5 : 0)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(day.isToday ? DS.Palette.accent : Color.clear,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
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
                    let untimed = AllDayEvents.busyFirst(day.items.filter {
                        !$0.hasScheduledTime && $0.behavior != .block && $0.behavior != .task
                    }, blocks: \.blocksWholeDay)
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
            .foregroundStyle(.tertiary)
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
                gutterLabel("Reminders")
                ForEach(days) { day in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 3) {
                            ForEach(reminderLine(day)) { occurrence in
                                reminderRow(occurrence)
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

    private func timeGrid(now: Date) -> some View {
        GeometryReader { geometry in
            let dayWidth = availableDayWidth(in: geometry.size.width)
            HStack(alignment: .top, spacing: 0) {
                timeLabels(now: now)
                    .frame(width: timeGutterWidth, height: gridHeight)
                if Self.reusesGridColumns {
                    // Experimental: retain fixed column chrome across page changes. Events
                    // and overflow groups still use their own content IDs and are replaced.
                    ForEach(days.indices, id: \.self) { index in
                        dayColumn(days[index], width: dayWidth, now: now)
                            .frame(width: dayWidth, height: gridHeight)
                    }
                } else {
                    ForEach(days) { day in
                        dayColumn(day, width: dayWidth, now: now)
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
                    ForEach(1..<24, id: \.self) { hour in
                        Text(TripTimeZone.label(forHour: hour, on: days.first?.date ?? Date(),
                                                primary: .current, zone: secondaryZone))
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: Self.secondaryGutterWidth - 6, alignment: .trailing)
                            .offset(y: CGFloat(hour) * hourHeight - 7)
                    }
                }
                .frame(width: Self.secondaryGutterWidth)
            }
            ZStack(alignment: .topLeading) {
                Color(.systemBackground)
                ForEach(1..<24, id: \.self) { hour in
                    let y = CGFloat(hour) * hourHeight
                    Text(hourLabel(hour))
                        .font(DS.Typeface.gutter)
                        .foregroundStyle(.tertiary)
                        .frame(width: 58 - DS.Space.s, alignment: .trailing)
                        .offset(y: y - 7)
                        .opacity(nowY.map { abs($0 - y) < 12 } == true ? 0 : 1)
                }
                if let nowY {
                    // Clock time only ("12:29"): the gutter is too narrow for the day part, and
                    // a label that truncates to "12:29…" reads as broken.
                    Text(TimeRangeText.clockOnly(now))
                        .font(DS.Typeface.gutter.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Space.xs)
                        .frame(height: 16)
                        .background(DS.Palette.now, in: RoundedRectangle(cornerRadius: DS.Radius.chip - 2, style: .continuous))
                        .frame(width: 58 - DS.Space.xs, alignment: .trailing)
                        .offset(y: nowY - 8)
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
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.secondaryGutterWidth - 6, alignment: .trailing)
                    .help(secondaryZone.identifier)
                Spacer(minLength: 0)
                Text(TripTimeZone.shortName(.current, at: date))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                    .help(TimeZone.current.identifier)
                Spacer(minLength: 10)
            }
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.bottom, 6)
        } else {
            Color.clear
        }
    }

    private func updateSecondaryZone() {
        guard TripTimeZone.isEnabled, let first = days.first?.date, let last = days.last?.date,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else {
            if secondaryZone != nil { secondaryZone = nil }
            return
        }
        let flights = smart.flightLegs.compactMap { leg -> TripTimeZone.Flight? in
            guard let airport = AirportTable.lookup(leg.destCode) else { return nil }
            return TripTimeZone.Flight(departs: leg.flightStart, arrives: leg.arriveAt, zone: airport.timeZone)
        }
        let zone = TripTimeZone.secondaryZone(visible: DateInterval(start: first, end: end), flights: flights,
                                              home: TripTimeZone.home, current: .current)
        if zone?.identifier != secondaryZone?.identifier { secondaryZone = zone }
    }

    private func dayColumn(_ day: MacWeekDay, width: CGFloat, now: Date) -> some View {
        let layout = timedLayout(for: day)
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
                if CalendarSlotContextMenu.localObservation {
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

            ForEach(placements) { placement in
                let blockWidth = laneWidth(totalWidth: width, lanes: placement.laneCount)
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

            // Anything the lane cap could not show, including staggered overlaps.
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

            // The current time across the whole week, faint, so "now" can be read against any
            // day — full strength only where it is actually today.
            if !day.isToday, days.contains(where: \.isToday) {
                Rectangle()
                    .fill(DS.Palette.now.opacity(DS.Tint.strong))
                    .frame(height: 1)
                    .offset(y: gridY(for: now, on: Calendar.current.startOfDay(for: now)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if day.isToday {
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

    /// - Parameter showsIcon: decided once per column (see `DS.Event.iconMinColumnWidth`), so a
    ///   "Lunch" block is drawn the same way on every day of the week — it used to lose its icon
    ///   only on days where its lane happened to be narrow.
    private func occurrenceBlock(_ occurrence: Occurrence, height: CGFloat, width: CGFloat,
                                 showsIcon: Bool) -> some View {
        let tint = blockTint(for: occurrence)
        let ribbons = EventStateStyle.ribbonColors(occurrence, tint: tint, colors: smart.calendarColorHex)
        let twoLine = height >= DS.Event.twoLineMinHeight
        let start = TimeRangeText.time(displayStart(occurrence))
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DS.Space.xs) {
                // Reminders always carry their done/not-done mark, at any width: for a reminder
                // that IS the important fact. Other kinds show their icon only when the column
                // has room for it on every block.
                if occurrence.behavior == .task {
                    Image(systemName: occurrence.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9, weight: .semibold))
                } else if occurrence.completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                } else if occurrence.skipped {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 9, weight: .semibold))
                } else if showsIcon {
                    Image(systemName: occurrence.icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                if occurrence.meeting?.othersAllDeclined == true { OthersDeclinedMark() }
                if twoLine {
                    Text(occurrence.title)
                        .font(DS.Typeface.eventTitle)
                        // Strikethrough carries at any size and says "done" rather than the
                        // "faded" that also means skipped, past, or tentative.
                        .strikethrough(occurrence.completed || occurrence.skipped, color: .secondary)
                        .lineLimit(max(1, Int((height - 20) / 13)))
                } else {
                    // Too short for two lines: title, then when — on one.
                    (Text(occurrence.title).font(DS.Typeface.eventTitle)
                        + Text("  \(start)").font(DS.Typeface.eventMeta).foregroundColor(tint.opacity(0.75)))
                        .strikethrough(occurrence.completed || occurrence.skipped, color: .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if twoLine {
                if let ret = returnLeg(forGrid: occurrence), (ret.end ?? ret.start) > Date() {
                    let mins = Int((ret.end ?? ret.start).timeIntervalSince(ret.start) / 60)
                    Label(height >= 48 ? "Home by \(TimeRangeText.time(ret.start)) · \(mins) min"
                                       : TimeRangeText.time(ret.start),
                          systemImage: "house")
                        .font(DS.Typeface.eventMeta.weight(.semibold))
                        .foregroundStyle(DS.Palette.travel)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                } else {
                    Text(timeRange(for: occurrence))
                        .font(DS.Typeface.eventMeta)
                        .foregroundStyle(tint.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(tint)
        .padding(.leading, DS.Space.s + EventStateStyle.ribbonInset(ribbons))
        .padding(.trailing, DS.Space.xs)
        .padding(.vertical, twoLine ? DS.Space.xs : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: twoLine ? .topLeading : .leading)
        // A free event keeps its calendar's colour but loses the solid fill and the full-strength
        // spine, so a glance down the column separates what holds a slot from what merely sits in it.
        .background(tint.opacity(EventStateStyle.fillOpacity(occurrence)))
        .overlay(alignment: .leading) {
            EventRibbons(colors: ribbons, opacity: occurrence.showsAsFree ? 0.4 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
        .freeBlockTreatment(occurrence.showsAsFree, tint: tint, cornerRadius: DS.Radius.block)
        .eventStateTreatment(occurrence.meeting, tint: tint, cornerRadius: DS.Radius.block)
        .opacity(occurrence.completed ? 0.55 : (occurrence.skipped ? 0.4 : 1))
        .blockedDayBase(cornerRadius: DS.Radius.block)
        .contentShape(Rectangle())
        .onTapGesture { activate(occurrence) }
        .contextMenu { occurrenceMenu(occurrence) }
        .help("\(occurrence.title), \(timeRange(for: occurrence))")
        .accessibilityLabel("\(occurrence.title), \(timeRange(for: occurrence))")
        .accessibilityIdentifier("mac.week.occurrence.\(occurrence.id)")
    }

    private func allDayChip(_ occurrence: Occurrence) -> some View {
        let tint = blockTint(for: occurrence)
        // An all-day event that's Free — a birthday — is outlined: it's there, and blocks nothing.
        let outlined = occurrence.behavior == .allDay && !occurrence.blocksWholeDay
        // …and one that blocks the day is solid, its calendar's colour.
        let solid = occurrence.blocksWholeDay
        let shape = RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
        return Button { activate(occurrence) } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: occurrence.completed ? "checkmark.circle.fill" : occurrence.icon)
                    .font(.system(size: 9, weight: .semibold))
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
                occurrences.toggleTask(occurrence)
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
                    .font(.system(size: 8.5, weight: occurrence.overdue ? .semibold : .regular))
                    .foregroundStyle(occurrence.overdue ? DS.Palette.danger : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, minHeight: reminderRowHeight, alignment: .leading)
        .background(DS.Palette.task.opacity(DS.Tint.subtle), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(occurrence.completed ? 0.5 : 1)
        .contentShape(Rectangle())
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
        if occurrence.hasScheduledTime {
            return occurrence.start.formatted(.dateTime.hour().minute())
        }
        return "No time"
    }

    // MARK: - Occurrence actions

    private func activate(_ occurrence: Occurrence) {
        switch occurrence.behavior {
        case .task:
            occurrences.toggleTask(occurrence)
        case .event, .allDay:
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
            if let id = occurrence.routineID,
               let routine = routines.routines.first(where: { $0.id == id }) {
                editing = routine
            }
        case .block, .alarm:
            break
        }
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
                occurrences.toggleTask(occurrence)
            } label: {
                Label(
                    occurrence.completed ? "Mark not done" : "Mark done",
                    systemImage: occurrence.completed ? "circle" : "checkmark.circle"
                )
            }
            Button { reschedulingTask = occurrence } label: {
                Label("Reschedule…", systemImage: "clock.arrow.circlepath")
            }
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
            if occurrence.hasScheduledTime, occurrence.occurrenceKey != nil {
                Button { movingOccurrence = occurrence } label: {
                    Label("Move…", systemImage: "clock.arrow.circlepath")
                }
            }
            if occurrence.occurrenceKey != nil {
                if occurrence.skipped {
                    Button {
                        CueSkip.restore(occurrence)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        CueSkip.skip(occurrence)
                    } label: {
                        Label("Skip", systemImage: "xmark.circle")
                    }
                }
            }
            if occurrence.routineID != nil {
                Button { activate(occurrence) } label: {
                    Label("Edit cue", systemImage: "pencil")
                }
            }
        case .block, .alarm:
            EmptyView()
        }
    }

    // MARK: - Layout and data

    private func rebuild(_ all: [Occurrence]) {
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
        let source = PendingRemovals.visible(window, id: { $0.meeting?.eventID }, start: \.start, hiding: hidden)
        let overdue = occurrences.occurrences.filter(\.isOverdueReminder)
        if overdue != overdueReminders { overdueReminders = overdue }
        let nextDays: [MacWeekDay] = (0..<visibleDayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let items = DayColumn.occurrences(source, on: date, calendar: calendar)
            return MacWeekDay(
                date: date,
                isToday: calendar.isDateInToday(date),
                items: items.sorted { $0.start < $1.start }
            )
        }
        if nextDays != days { days = nextDays }
        updateSecondaryZone()
    }

    /// How many lanes a column can show before each becomes unusable. Five reminders due at
    /// 9:00 split a 150pt column into 28pt slivers: too narrow to read, and too narrow to hit.
    /// Past this, the overflow collapses into one "+N" chip that opens the full list.
    private static let maxVisibleLanes = 3

    private func timedLayout(for day: MacWeekDay) -> (placements: [MacWeekPlacement], overflow: [OverflowCluster]) {
        let timed = day.items.filter { $0.hasScheduledTime && $0.behavior != .block }
        let allocated = CalendarLaneAllocator.placements(timed)
        let hiddenIDs = Set(allocated.filter { $0.lane >= Self.maxVisibleLanes }.map { $0.occurrence.id })
        let placements = allocated.compactMap { placement -> MacWeekPlacement? in
            guard placement.lane < Self.maxVisibleLanes else { return nil }
            return MacWeekPlacement(occurrence: placement.occurrence, lane: placement.lane,
                                    laneCount: min(placement.laneCount, Self.maxVisibleLanes))
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
        let usePersistedOffset: Bool
        #if DEBUG
        usePersistedOffset = dayMode && persistedDayScrollOffset >= 0
            && !ProcessInfo.processInfo.arguments.contains("--ui-audit")
        #else
        usePersistedOffset = dayMode && persistedDayScrollOffset >= 0
        #endif
        let targetOffset: CGFloat
        if usePersistedOffset {
            targetOffset = CGFloat(persistedDayScrollOffset)
        } else {
        let firstVisibleHour: Int
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
            // Marketing/QA captures must show the same useful workday at 9 AM and 9 PM.
            firstVisibleHour = 7
        } else {
            let hour = Calendar.current.component(.hour, from: Date())
            firstVisibleHour = min(18, max(5, hour - 1))
        }
        #else
        let hour = Calendar.current.component(.hour, from: Date())
        firstVisibleHour = min(18, max(5, hour - 1))
        #endif
            targetOffset = max(0, CGFloat(firstVisibleHour) * hourHeight - 10)
        }
        Task { @MainActor in
            await Task.yield()
            // Hour labels sit seven points above their grid line. Leave a little leading room so
            // the first visible label is not cut in half by the ScrollView's clipping boundary.
            gridScroll.scrollTo(y: targetOffset)
        }
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
        days.contains { !$0.reminders.isEmpty }
    }

    private var hasUntimedItems: Bool {
        days.contains { day in
            day.items.contains {
                !$0.hasScheduledTime && $0.behavior != .block && $0.behavior != .task
            }
        }
    }

    /// A day's reminders row — on today, everything outstanding first (`OutstandingReminders`).
    private func reminderLine(_ day: MacWeekDay) -> [Occurrence] {
        OutstandingReminders.line(untimed: day.reminders, overdue: overdueReminders, isToday: day.isToday,
                                  id: \.id, due: { $0.schedule.constraints?.deadline ?? $0.start })
    }

    private var reminderRowsHeight: CGFloat {
        let largestDay = days.map { reminderLine($0).count }.max() ?? 0
        let visibleRows = min(maxVisibleReminderRows, max(1, largestDay))
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
                               preferred: CGFloat) -> CGFloat {
        let start = displayStart(placement.occurrence)
        var top = preferred
        for other in placements where other.lane == placement.lane
            && other.occurrence.id != placement.occurrence.id {
            let otherStart = displayStart(other.occurrence)
            guard otherStart < start else { continue }
            let bottom = gridY(for: otherStart, on: day)
                + blockHeight(for: other.occurrence, on: day,
                              endingAt: visualEnd(for: other, among: placements))
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
    private func draggedStart(for occ: Occurrence, on day: Date, dy: CGFloat, dayShift: Int) -> Date? {
        let cal = Calendar.current
        let minutes = Double(dy / hourHeight) * 60
        let snapped = (minutes / 5).rounded() * 5
        guard let shiftedDay = cal.date(byAdding: .day, value: dayShift, to: day) else { return nil }
        let components = cal.dateComponents([.hour, .minute], from: occ.start)
        guard let sameTimeOnTargetDay = cal.date(bySettingHour: components.hour ?? 0,
                                                 minute: components.minute ?? 0,
                                                 second: 0, of: shiftedDay) else { return nil }
        return sameTimeOnTargetDay.addingTimeInterval(snapped * 60)
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
        loadingWeek = true
        await occurrences.refreshPlanningWindow(from: request.start, to: request.end)
        if visibleStart == visibleWeekStart {
            rebuild(occurrences.occurrences)
            loadingWeek = false
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
        case .event, .allDay: return sourceCalendarColor(occurrence, colors: smart.calendarColorHex) ?? .blue
        case .task: return .green
        case .alarm: return .orange
        case .cue, .block: return occurrence.tint.color
        }
    }

    private func timeRange(for occurrence: Occurrence) -> String {
        TimeRangeText.compact(displayStart(occurrence),
                              displayStart(occurrence).addingTimeInterval(occurrence.resolvedEnd.timeIntervalSince(occurrence.start)))
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

private struct MacWeekPlacement: Identifiable {
    let occurrence: Occurrence
    let lane: Int
    let laneCount: Int
    var id: String { occurrence.id }
}

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
        private var accumulatedX: CGFloat = 0
        private var didMove = false
        private var lastTimestamp: TimeInterval = 0

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

            if event.phase.contains(.began) || event.timestamp - lastTimestamp > 0.45 {
                accumulatedX = 0
                didMove = false
            }
            lastTimestamp = event.timestamp
            guard !didMove else { return }

            let x = event.isDirectionInvertedFromDevice
                ? -event.scrollingDeltaX
                : event.scrollingDeltaX
            guard abs(x) > abs(event.scrollingDeltaY) * 1.2 else { return }
            accumulatedX += x

            guard abs(accumulatedX) >= 60 else { return }
            didMove = true
            // Pushing the calendar content left reveals the next period; pushing it right
            // reveals the previous one. AppKit's normalized scroll delta is positive for that
            // physical leftward gesture.
            move?(accumulatedX > 0 ? 1 : -1)
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
private final class FingerCounter: UIGestureRecognizer {
    var onAllLifted: (() -> Void)?
    private var down = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        down += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }

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

private struct DirectionalDayScrollView<Content: View>: UIViewRepresentable {
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
        return coordinator
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.decelerationRate = .normal
        scrollView.isMultipleTouchEnabled = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.backgroundColor = .systemBackground
        scrollView.delegate = context.coordinator

        let host = UIHostingController(rootView: AnyView(content.id(resetToken)))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        let height = host.view.heightAnchor.constraint(equalToConstant: contentHeight)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            height
        ])

        let horizontalPan = UIPanGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.didPan(_:)))
        // Once a sideways swipe is under way, the touch is the swipe's: cancel it for the events
        // under the finger. Left uncancelled, a swipe that started on an event still reached that
        // event's tap on lift-off and opened it while the day changed.
        horizontalPan.cancelsTouchesInView = true
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
        scrollView.panGestureRecognizer.require(toFail: createLongPress)
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
        fingers.delegate = context.coordinator
        scrollView.addGestureRecognizer(fingers)
        context.coordinator.pinch = pinch
        context.coordinator.host = host
        context.coordinator.horizontalPan = horizontalPan
        context.coordinator.createLongPress = createLongPress
        context.coordinator.heightConstraint = height
        context.coordinator.resetToken = resetToken
        DispatchQueue.main.async {
            scrollView.contentSize = CGSize(width: scrollView.bounds.width, height: contentHeight)
            scrollView.contentOffset.y = min(max(0, initialOffset),
                                             max(0, contentHeight - scrollView.bounds.height))
        }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
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
        if pageChanged {
            // A horizontal page gesture is an explicit request, not a background publication.
            // End any vertical coast exactly where it is so the destination day does not wait
            // for deceleration to finish while the fixed date header has already changed.
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            context.coordinator.pendingRoot = nil
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
        } else {
            if pageChanged, let hostView = context.coordinator.host?.view {
                let transition = CATransition()
                transition.type = .push
                transition.subtype = resetToken > previousResetToken ? .fromRight : .fromLeft
                transition.duration = 0.18
                transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
                hostView.layer.add(transition, forKey: "day-page")
            }
            context.coordinator.host?.rootView = nextRoot
            context.coordinator.pendingRoot = nil
        }
        context.coordinator.heightConstraint?.constant = contentHeight
        // `UIHostingController` does not always propagate its intrinsic height through a
        // UIScrollView's content layout guide. The calendar has a fixed ruler, so state the
        // scroll range directly instead of asking UIKit to infer it.
        scrollView.contentSize = CGSize(width: scrollView.bounds.width, height: contentHeight)
        guard pageChanged else { return }
        context.coordinator.resetToken = resetToken
        let maximum = max(0, contentHeight - scrollView.bounds.height)
        // Preserve the scroll view's live position in the same update transaction as the host
        // replacement. Dispatching this to the next run-loop turn exposed a one-frame jump to the
        // top on dense days and made a preserved position look reset.
        let targetOffset = min(maximum, max(0, preservedOffset))
        scrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
        onVerticalOffset(targetOffset)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
        // The hosted view does not retain its view controller. This must be strong or the
        // controller dies after `makeUIView`, making every later day update a silent no-op.
        var host: UIHostingController<AnyView>?
        var heightConstraint: NSLayoutConstraint?
        var resetToken = ""
        var pendingRoot: AnyView?
        var onHorizontalSwipe: (Bool) -> Void
        var canBeginSwipe: () -> Bool
        var onVerticalOffset: (CGFloat) -> Void
        var canBeginCreate: (CGPoint) -> Bool
        var onCreateChanged: (CGPoint, CGPoint) -> Void
        var onCreateEnded: (CGPoint, CGPoint) -> Void
        var onCreateCancelled: () -> Void
        weak var horizontalPan: UIPanGestureRecognizer?
        weak var createLongPress: UILongPressGestureRecognizer?
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
            // The page swipe shares the touch with the vertical scroll and the create press only.
            // Sharing it with everything let a block's button, under the finger where the swipe
            // began, still take the lift-off as a tap and open while the day changed.
            guard gestureRecognizer === horizontalPan || otherGestureRecognizer === horizontalPan else { return true }
            let partner = gestureRecognizer === horizontalPan ? otherGestureRecognizer : gestureRecognizer
            return partner === (horizontalPan?.view as? UIScrollView)?.panGestureRecognizer
                || partner === createLongPress
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === createLongPress {
                return canBeginCreate(gestureRecognizer.location(in: gestureRecognizer.view))
            }
            guard gestureRecognizer === horizontalPan,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            guard canBeginSwipe() else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.25
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
                scrollView.panGestureRecognizer.isEnabled = false
                scrollView.panGestureRecognizer.isEnabled = true
                GridZoom.gate.pinchChanged()
                isPinching = true
                pinchBase = hourHeight
                pinchAnchorHours = point.y / max(1, hourHeight)
            case .changed:
                guard isPinching else { return }
                GridZoom.gate.pinchChanged()
                let height = min(hourHeightRange.upperBound,
                                 max(hourHeightRange.lowerBound, pinchBase * recognizer.scale))
                let hours = (heightConstraint?.constant ?? scrollView.contentSize.height) / max(1, hourHeight)
                hourHeight = height
                // Size the grid now, in this frame, so the offset below isn't clamped to the old
                // height; SwiftUI redraws the hours to match a moment later.
                let contentHeight = hours * height
                heightConstraint?.constant = contentHeight
                scrollView.contentSize = CGSize(width: scrollView.bounds.width, height: contentHeight)
                scrollView.contentOffset.y = MobileZoom.offset(anchorHours: pinchAnchorHours, hourHeight: height,
                                                               fingersAt: onScreen, contentHeight: contentHeight,
                                                               viewportHeight: scrollView.bounds.height)
                onZoomChanged(height)
            case .ended, .cancelled, .failed:
                guard isPinching else { return }
                isPinching = false
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
            if !decelerate {
                applyPendingRoot()
                onVerticalOffset(scrollView.contentOffset.y)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            applyPendingRoot()
            onVerticalOffset(scrollView.contentOffset.y)
        }

        private func applyPendingRoot() {
            guard let pendingRoot else { return }
            host?.rootView = pendingRoot
            self.pendingRoot = nil
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
    @Published var x: CGFloat = 0
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

    /// A day's all-day events, the ones that block it first: never the ones behind "+N more".
    private func events(_ day: WeekView.DayData) -> [Occurrence] {
        AllDayEvents.busyFirst(day.items.filter { $0.behavior == .allDay }, blocks: \.blocksWholeDay)
    }

    /// Tall enough for the busiest day: two chips, and a "+N more" line when one has more.
    private var height: CGFloat {
        let counts = days.map { $0.items.filter { $0.behavior == .allDay }.count }
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
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 3)
                                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(fitting.more) more all-day events")
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
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .scrollPosition($position)
        .frame(height: height)
        .background(Color(.secondarySystemGroupedBackground))
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
        let shape = RoundedRectangle(cornerRadius: inList ? 6 : 4, style: .continuous)
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
                .font(.system(size: inList ? 14 : 10, weight: busy ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(busy ? Color.white : Color.secondary)
                .padding(.horizontal, inList ? 8 : 4)
                .frame(maxWidth: .infinity, minHeight: inList ? 30 : 18, alignment: .leading)
                // Busy is solid, its calendar's colour: a blocked day reads at a glance.
                .background(busy ? color : Color.clear, in: shape)
                .overlay(shape.strokeBorder(color.opacity(busy ? 0 : 0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
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
        .accessibilityLabel("\(occurrence.title), all day\(busy ? ", busy" : ", free")")
        .accessibilityIdentifier("allDay.chip")
    }
}

private struct MobileDayHeaderStrip: View {
    let days: [WeekView.DayData]
    let dayWidth: CGFloat
    let selectedDay: Date
    let onSelect: (WeekView.DayData) -> Void
    @ObservedObject var offset: HeaderScrollOffset
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(days) { day in
                    let selected = Calendar.current.isDate(day.date, inSameDayAs: selectedDay)
                    Button {
                        onSelect(day)
                    } label: {
                        VStack(spacing: 1) {
                            Text(day.letter.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(day.isToday ? .orange : .secondary)
                            Text(day.dayNum)
                                .font(.system(size: 16, weight: day.isToday ? .bold : .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(day.isToday ? .white : .primary)
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
                    .id(day.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .scrollPosition($position)
        .frame(height: 44)
        .background(Color(.secondarySystemGroupedBackground))
        .onChange(of: offset.x, initial: true) { _, x in
            position.scrollTo(x: x)
        }
    }
}
#endif

struct WeekView: View {
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
    /// Plan's List: the agenda, overdue reminders first (`PlanMode.list`).
    private let listMode: Bool
    /// Overdue reminders: their own group at the top of List (and not again under today), and
    /// the first chips of today's reminders line in Day and Week.
    @State private var overdueTasks: [Occurrence] = []
    /// The reminders line opened past its first few.
    @State private var showsEveryReminder = false

    init(dayMode: Bool = false, listMode: Bool = false) {
        self.dayMode = dayMode
        self.listMode = listMode
    }

    @AppStorage("durStyle") private var durStyle: DurationStyle = .range
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
    #if os(iOS)
    /// List · Day · Week is one switch now (`PlanModePicker`): the list is Plan's List mode, no
    /// longer an agenda setting in Week's "…" menu that Day couldn't reach.
    private var mobileWeekLayout: MobileWeekLayout { listMode ? .agenda : .calendar }
    #endif
    @State private var showSettings = false
    /// Routines lost its iOS tab: it is configuration edited weekly at most, so it lives under
    /// "…" with the briefing, which was otherwise reachable only in the ten minutes after a wake.
    @State private var showRoutines = false
    @State private var showBriefing = false
    @State private var showingAvailability = false
    @State private var days: [DayData] = []
    @State private var dayOffsets: [Int: CGFloat] = [:]
    @State private var scrollPos = ScrollPosition(idType: Int.self)
    @State private var contentH: CGFloat = 1
    @State private var viewH: CGFloat = 1

    @State private var editing: Routine?
    @State private var movingOcc: Occurrence?
    @State private var reschedulingTask: Occurrence?
    @State private var editingTask: Occurrence?
    @State private var addingExtraFor: Routine?
    @State private var eventSheet: CalendarEventSheet?
    /// A routine moment tapped in the calendar: its time and what set it (`CueOccurrenceSheet`).
    @State private var inspectingCue: Occurrence?
    /// What that sheet asked for next — opened once it has gone.
    @State private var afterCueSheet: (() -> Void)?

    /// Row positions per day, so each day's weather stripe can share that day's vertical scale.
    @State private var dayAnchors: [Int: [TimeAnchor]] = [:]
    @State private var weatherFocus: WeatherFocus?
    #if os(iOS)
    @State private var calendarDays: [DayData] = []
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
    @State private var mobileWeekLoading = false
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
    #endif

    private var maxScroll: CGFloat { max(1, contentH - viewH) }

    struct DayData: Identifiable, Equatable {
        let id: Int
        let date: Date
        let weekday: String
        let dayNum: String
        let letter: String
        let isToday: Bool
        let items: [Occurrence]
        let committed: Double
        /// `items.hashValue`, computed once here at construction (items is immutable), for
        /// views that key on a day's contents.
        let itemsToken: Int
        var load: Double { min(1, committed / 16) }
        var free: Int { Int(max(0, 16 - committed).rounded()) }
    }
    private struct GridPlacement: Identifiable {
        let occurrence: Occurrence
        let lane: Int
        let laneCount: Int
        var id: String { occurrence.id }
    }
    struct Geo: Equatable { var content: CGFloat; var container: CGFloat }

    var body: some View {

        let _ = RenderStats.note("WeekView")
        #if os(iOS)
        let _ = mobileVisibleSmartRevision
        #endif
        NavigationStack {
            Group {
            #if os(iOS)
                mobilePlanner
            #else
                macAgenda
            #endif
            }
            #if os(iOS)
            // Day's calendar surface is systemBackground. Let that same color cover the bottom
            // safe area under the collapsible tab/menu chrome; the grouped background otherwise
            // leaks through as a solid gray strip when the chrome contracts.
            .background(Color(.systemBackground).ignoresSafeArea())
            #else
            .background(Color(.systemGroupedBackground))
            #endif
            #if os(iOS)
            .navigationTitle("")
            #else
            .navigationTitle("Agenda")
            #endif
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
            .alert("Couldn\u{2019}t move that event",
                   isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })) {
                Button("OK", role: .cancel) { moveError = nil }
            } message: {
                Text(moveError ?? "")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .automatic) { MacPlannerViewMenu() }
                #else
                ToolbarItem(placement: .principal) {
                    PlanModePicker()
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            newEventRequest = MobileNewEventRequest(
                                start: mobileDefaultNewEventStart(),
                                durationMinutes: 60)
                        } label: {
                            Label("New calendar event", systemImage: "calendar.badge.plus")
                        }
                        Button {
                            newTaskDue = mobileDefaultNewEventStart()
                            showingNewTask = true
                        } label: {
                            Label("New reminder", systemImage: "checklist")
                        }
                        Button { showingAlarms = true } label: {
                            Label("New alarm", systemImage: "alarm")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                    .accessibilityIdentifier("mobile.week.newEvent")
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            showingNewTask = true
                        } label: {
                            Label("New task", systemImage: "checklist")
                        }
                        .accessibilityIdentifier("mobile.week.newTask")
                        Divider()
                        Button { showRoutines = true } label: {
                            Label("Routines", systemImage: "repeat")
                        }
                        .accessibilityIdentifier("mobile.week.routines")
                        Button { showBriefing = true } label: {
                            Label("Morning briefing", systemImage: "sunrise.fill")
                        }
                        .accessibilityIdentifier("mobile.week.briefing")
                        Button { showingAvailability = true } label: {
                            Label("Share availability", systemImage: "calendar.badge.checkmark")
                        }
                        .accessibilityIdentifier("mobile.week.availability")
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("mobile.week.more")
                }
                #endif
            }
            .sheet(item: $weatherFocus) { WeatherDetailView(focus: $0.date) }
            .sheet(isPresented: $showSettings) { SettingsView(showsDoneButton: true) }
            .sheet(isPresented: $showRoutines) { RoutinesView(showsDoneButton: true) }
            .sheet(isPresented: $showBriefing) { MorningBriefingView() }
            .sheet(isPresented: $showingAvailability) { AvailabilitySheet() }
            .sheet(item: $editing) { RoutineEditorView(draft: $0, isNew: false) }
            .sheet(item: $eventSheet) {
                CalendarEventSheetView(sheet: $0) {
                    Task {
                        await smart.refreshAgenda()
                        await occurrences.recompute()
                    }
                }
            }
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
                    NewTaskSheet(reminderID: id)
                }
            }
            #if os(iOS)
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
            .sheet(isPresented: $showingAlarms) { OneOffAlarmSheet() }
            #endif
        }
        .onAppear {
            // instant: draw from what the store already holds
            if agendaVisible { rebuild(occurrences.occurrences) }
            #if os(iOS)
            rebuildMobileCalendar(mobileWindowOccurrences())
            #endif
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
            #if os(iOS)
            let isVisualAudit = VisualAuditRoute.matches(arguments)
            #else
            let isVisualAudit = arguments.contains("--ui-audit")
            #endif
            guard !isVisualAudit || cacheBackfillValidation || readOnlyCalendarValidation
            else { return }
            #endif
            let windowTask = Task { @MainActor in
                #if os(iOS)
                if dayMode || mobileWeekLayout == .calendar { await refreshMobileWeek() }
                #endif
            }
            #if DEBUG
            if !readOnlyCalendarValidation && !cacheBackfillValidation {
                await occurrences.recomputeIfStale(reason: "day view")
            }
            #else
            await occurrences.recomputeIfStale(reason: "day view")
            #endif
            await windowTask.value
            if agendaVisible { rebuild(occurrences.occurrences) }
            #if os(iOS)
            rebuildMobileCalendar(mobileWindowOccurrences())
            #endif
        }
        .task {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard !arguments.contains("--ui-audit"),
                  !arguments.contains("--day-real-calendar") else { return }
            #endif
            await weather.refreshIfStale()   // Week needs the whole week's forecast, not just today's
        }
        #if DEBUG && os(iOS)
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
        .onReceive(occurrences.$occurrences) {
            if agendaVisible { rebuild($0) }
            #if os(iOS)
            if dayMode || mobileWeekLayout == .calendar {
                // `@Published` announces a change BEFORE storing it, and the grid reads the store
                // (`planningWindow` falls back to `occurrences`), so rebuilding here drew the
                // previous timeline — an event just confirmed, or just added, was missing until
                // something else rebuilt the day. Read once the new value is in.
                DispatchQueue.main.async { rebuildMobileCalendar(mobileWindowOccurrences()) }
            }
            #endif
        }
        // Changes only, not the value replayed on subscribing: that one arrives while this view is
        // still being put on screen, and a day written then was stored but never drawn — the
        // grid's content had already been built from the empty one, and every rebuild after it
        // found the days equal and wrote nothing. Switching to Day from List or Week left it
        // blank until something changed. `onAppear` draws the first day.
        .onReceive(occurrences.$planningWindowRevision.dropFirst()) { _ in
            #if os(iOS)
            if dayMode || mobileWeekLayout == .calendar {
                rebuildMobileCalendar(mobileWindowOccurrences())
            }
            #endif
        }
        // Declined or deleted a moment ago: off the day now; back if undone. A turn later, as
        // `@Published` announces before it stores.
        .onReceive(ToastCenter.shared.$hiddenIDs.dropFirst()) { _ in
            DispatchQueue.main.async {
                if agendaVisible { rebuild(occurrences.occurrences) }
                #if os(iOS)
                if dayMode || mobileWeekLayout == .calendar {
                    rebuildMobileCalendar(mobileWindowOccurrences())
                }
                #endif
            }
        }
        .onReceive(smart.$calendarColorHex.removeDuplicates().dropFirst()) { _ in
            #if os(iOS)
            mobileVisibleSmartRevision &+= 1
            #else
            rebuild(occurrences.occurrences)
            #endif
        }
        .onReceive(smart.$commuteLegs.removeDuplicates().dropFirst()) { _ in
            #if os(iOS)
            mobileVisibleSmartRevision &+= 1
            #else
            rebuild(occurrences.occurrences)
            #endif
        }
        .onReceive(smart.$flightLegs.removeDuplicates().dropFirst()) { _ in
            #if os(iOS)
            mobileVisibleSmartRevision &+= 1
            #else
            rebuild(occurrences.occurrences)
            #endif
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
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .macForceRefreshRequested)) { _ in
            // ⌘R also reaches here: the Week tab's Agenda layout renders this shared WeekView
            // instead of MacWeekView, and needs the same force-refresh chain.
            Task { await smart.refreshCalendar(); await occurrences.recompute() }
        }
        #else
        .onReceive(
            smart.$settings
                .map(\.weekStartWeekday)
                .removeDuplicates()
                .dropFirst()
        ) { _ in
            guard dayMode || mobileWeekLayout == .calendar else { return }
            rebuildMobileCalendar(mobileWindowOccurrences())
            Task { await refreshMobileWeek() }
        }
        #endif
    }

    /// Whether the agenda subtree — the sole reader of `days` (built by `rebuild` below) — is
    /// actually mounted right now. On iOS the agenda only shows in Week mode with the `.agenda`
    /// layout picked; `days` is written and never read for Day mode or the default `.calendar`
    /// layout. macOS's WeekView always shows the agenda, so it stays unconditionally true there.
    private var agendaVisible: Bool {
        #if os(iOS)
        !dayMode && mobileWeekLayout == .agenda
        #else
        true
        #endif
    }

    private func rebuild(_ all: [Occurrence]) {
        // An event declined (or deleted) a moment ago is gone at once, while its Undo lasts.
        var all = PendingRemovals.visible(all, id: { $0.meeting?.eventID }, start: \.start, hiding: ToastCenter.shared.hiddenIDs)
        // Every reminder past its time and not done leads the list — exactly what the Plan badge
        // counts (`isOverdueReminder`). Today's 8 AM creatine at 9 included: kept down in today, the
        // badge said 2 with nothing at the top to show for it.
        let overdue = all.filter(\.isOverdueReminder)
            .sorted { ($0.schedule.constraints?.deadline ?? $0.start) < ($1.schedule.constraints?.deadline ?? $1.start) }
        if overdue.map(\.id) != overdueTasks.map(\.id) { overdueTasks = overdue }
        let overdueIDs = Set(overdue.map(\.id))
        all.removeAll { overdueIDs.contains($0.id) }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        #if os(macOS)
        let visibleDayCount = 7
        #else
        let visibleDayCount = dayMode ? 1 : 7
        #endif
        days = (0..<visibleDayCount).compactMap { i -> DayData? in
            guard let day = cal.date(byAdding: .day, value: i, to: start) else { return nil }
            let items = DayColumn.occurrences(all, on: day, calendar: cal)
            let committed = items
                .filter { $0.behavior == .event || ($0.behavior == .task && $0.hasScheduledTime) }
                .reduce(0.0) { $0 + $1.resolvedEnd.timeIntervalSince($1.start) } / 3600
            return DayData(id: i, date: day,
                           weekday: Self.weekdayFmt.string(from: day).uppercased(),
                           dayNum: Self.dayFmt.string(from: day),
                           letter: Self.letterFmt.string(from: day),
                           isToday: cal.isDateInToday(day),
                           items: items, committed: committed, itemsToken: items.hashValue)
        }
    }

    #if os(iOS)
    // MARK: - Mobile calendar

    /// The agenda remains available, but the default mobile week is a real shared time axis.
    /// Three readable columns fit in portrait; horizontal scrolling exposes the rest of the week,
    /// while landscape naturally shows most or all seven.
    private var mobilePlanner: some View {
        VStack(spacing: 0) {
            if dayMode || mobileWeekLayout == .calendar {
                mobileWeekChrome
                Divider()
                mobileCalendarGrid
            } else {
                agenda
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var mobileWeekChrome: some View {
        HStack(spacing: 4) {
            Button { moveMobileWeek(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel(dayMode ? "Previous day" : "Previous week")

            HStack(spacing: 6) {
                Text(mobileWeekOffset == 0 ? (dayMode ? "Today" : "This week") : mobileWeekRangeTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if mobileWeekOffset == 0 {
                    Text(mobileWeekRangeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if mobileWeekLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .lineLimit(1)
            .accessibilityIdentifier("mobile.day.title")
            .accessibilityValue(dayMode ? Occurrence.dayKey(mobileVisibleWeekStart) : mobileWeekRangeTitle)
            .contentShape(Rectangle())
            .onTapGesture {
                if mobileWeekOffset != 0 { moveMobileWeekToCurrent() }
            }

            Spacer(minLength: 0)
            if mobileWeekOffset != 0 {
                Button("Today") { moveMobileWeekToCurrent() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Return to today")
            }
            Button { moveMobileWeek(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel(dayMode ? "Next day" : "Next week")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(Color(.systemBackground))
        // Keep period navigation on the fixed header rather than the grid: the Week grid already
        // scrolls horizontally between its day columns, while a Day grid has no such conflict.
        // This gives both views the natural calendar swipe without stealing vertical scrolling.
        .gesture(mobilePeriodSwipe)
    }

    private var mobilePeriodSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let horizontal = value.translation.width
                guard abs(horizontal) > abs(value.translation.height) * 1.4 else { return }
                moveMobileWeek(horizontal < 0 ? 1 : -1)
            }
    }

    @ViewBuilder private var mobileCalendarGrid: some View {
        mobileWeekCalendarGrid
    }

    private func mobileSingleDayHeader(width: CGFloat) -> some View {
        let day = calendarDays.first(where: { $0.id == 1 })
        return VStack(spacing: 1) {
            Text(day?.weekday ?? "")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(day?.isToday == true ? .orange : .secondary)
            Text(day?.dayNum ?? "")
                .font(.system(size: 16, weight: day?.isToday == true ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(day?.isToday == true ? .white : .primary)
                .frame(width: 26, height: 24)
                .background(day?.isToday == true ? DS.Palette.accent : Color.clear, in: Circle())
        }
        .frame(width: width, height: 44)
        .background(Color(.secondarySystemGroupedBackground))
    }

    /// Reminders with no time, for the day on screen (today's include the overdue ones), above the
    /// grid. The grid draws only what has a time, so these were nowhere on the iPhone's calendar —
    /// the Mac lists them above each day — and two overdue reminders could badge the app while
    /// only one could be found.
    /// All-day events for the day on screen, above its reminders: a trip, an offsite, a birthday.
    /// Solid when it blocks the day (Busy), outlined when it's Free.
    @ViewBuilder private func mobileAllDayBand(_ day: DayData?) -> some View {
        let events = AllDayEvents.busyFirst((day?.items ?? []).filter { $0.behavior == .allDay },
                                            blocks: \.blocksWholeDay)
        if !events.isEmpty {
            // Every one of the day's, wrapped onto as many lines as they take: one day has the
            // room, and a row that scrolled sideways hid whatever was past the edge.
            WorkoutFlowLayout(spacing: DS.Space.s, lineSpacing: DS.Space.xs + 2, fitsWidth: true) {
                ForEach(events) { allDayEventChip($0) }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            Divider()
        }
    }

    private func allDayEventChip(_ occ: Occurrence) -> some View {
        let tint = sourceCalendarColor(occ, colors: smart.calendarColorHex) ?? .blue
        let busy = occ.blocksWholeDay
        return Button {
            if let meeting = occ.meeting { openEvent(meeting) }
        } label: {
            Label(occ.title, systemImage: busy ? "calendar.badge.clock" : "calendar")
                .font(.caption.weight(busy ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(busy ? Color.white : Color.secondary)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .background(busy ? tint : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(busy ? 0 : 0.7), lineWidth: 1))
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

    /// The day's reminders above the hours — and on today everything outstanding, whenever it
    /// was due (`OutstandingReminders`): what the Plan badge counts is here, not only in List.
    /// Wrapped, not scrolled sideways, so none of it is past the edge.
    @ViewBuilder private func mobileRemindersBand(_ day: DayData?) -> some View {
        let untimed = (day?.items ?? [])
            .filter { $0.behavior == .task && !$0.hasScheduledTime }
            .sorted { ($0.overdue ? 0 : 1, $0.title) < ($1.overdue ? 0 : 1, $1.title) }
        let reminders = OutstandingReminders.line(untimed: untimed, overdue: overdueTasks,
                                                  isToday: day?.isToday ?? false, id: \.id, due: Self.due)
        if !reminders.isEmpty {
            let shown = showsEveryReminder ? reminders : Array(reminders.prefix(Self.reminderLineLimit))
            WorkoutFlowLayout(spacing: DS.Space.s, lineSpacing: DS.Space.xs + 2, fitsWidth: true) {
                ForEach(shown) { reminderChip($0) }
                if reminders.count > Self.reminderLineLimit {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showsEveryReminder.toggle() }
                    } label: {
                        Text(showsEveryReminder ? "Fewer" : "+\(reminders.count - Self.reminderLineLimit) more")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(DS.Palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mobile.reminders.more")
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            // Its own container, as the sideways scroll it replaced was: without one, the grid's
            // identifier lands on every chip in place of the chip's own.
            .accessibilityElement(children: .contain)
            Divider()
        }
    }

    /// When a reminder was due: its deadline, else its time.
    private static func due(_ reminder: Occurrence) -> Date {
        reminder.schedule.constraints?.deadline ?? reminder.start
    }

    private func reminderChip(_ reminder: Occurrence) -> some View {
        let overdue = reminder.overdue && !reminder.completed
        return Button {
            occurrences.toggleTask(reminder)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(DS.Palette.task)
                Text(reminder.title)
                    .font(.footnote)
                    .lineLimit(1)
                    .strikethrough(reminder.completed, color: .secondary)
                if overdue {
                    Text(OutstandingReminders.since(Self.due(reminder)))
                        .font(.caption2.weight(.semibold)).foregroundStyle(DS.Palette.danger)
                } else if let waiting = reminder.waitingFor, !reminder.completed {
                    // Tied to a moment that hasn't come: not due, not late.
                    Text(waiting).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(.tertiarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .contextMenu { taskMenu(reminder) }
        .accessibilityLabel(reminder.completed ? "Mark \(reminder.title) not done" : "Mark \(reminder.title) done")
        .accessibilityValue(overdue ? "Overdue" : "")
        .accessibilityIdentifier("mobile.reminder.\(reminder.reminderID ?? reminder.id)")
    }

    private var mobileWeekCalendarGrid: some View {
        GeometryReader { geometry in
            let timeWidth: CGFloat = 36
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
                        MobileDayHeaderStrip(
                            days: calendarDays,
                            dayWidth: dayWidth,
                            selectedDay: mobileSelectedDay,
                            onSelect: { day in
                                mobileSelectedDay = day.date
                                mobileVisibleDayID = min(max(0, day.id), max(0, calendarDays.count - 3))
                            },
                            offset: headerOffset
                        )
                }
                Divider()
                // All-day events under each day's own column, scrolling with the header — not the
                // selected day's stretched across the week, which read as "all week" and hid
                // every other day's (a Saturday trip with Sunday selected).
                if calendarDays.contains(where: { $0.items.contains { $0.behavior == .allDay } }) {
                    HStack(spacing: 0) {
                        Color(.secondarySystemGroupedBackground).frame(width: timeWidth)
                        MobileAllDayStrip(
                            days: calendarDays,
                            dayWidth: dayWidth,
                            offset: headerOffset,
                            tint: { sourceCalendarColor($0, colors: smart.calendarColorHex) ?? .blue },
                            onOpen: { if let meeting = $0.meeting { openEvent(meeting) } },
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
                if dayMode { mobileAllDayBand(bandDay) }
                mobileRemindersBand(bandDay)
                if dayMode, let currentDay = calendarDays.first(where: { $0.id == 1 }) {
                    DirectionalDayScrollView(
                        resetToken: Occurrence.dayKey(currentDay.date),
                        contentHeight: gridHeight,
                        initialOffset: mobileDayScrollOffset >= 0
                            ? CGFloat(mobileDayScrollOffset)
                            : max(0, (CGFloat(Calendar.current.component(.hour, from: Date())) - 1.5) * hourHeight),
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
                                $0.hasScheduledTime && $0.behavior != .block
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
                        content: HStack(alignment: .top, spacing: 0) {
                            mobileTimeGutter(width: timeWidth, startHour: startHour,
                                             endHour: endHour, hourHeight: hourHeight)
                            mobileDayColumn(currentDay, width: dayWidth, startHour: startHour,
                                            endHour: endHour, hourHeight: hourHeight)
                        }
                        .frame(height: gridHeight, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    )
                    .frame(height: max(1, geometry.size.height - 45))
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                            let hour = min(22, max(0, Calendar.current.component(.hour, from: Date()) - 1))
                            scrollProxy.scrollTo(hour, anchor: .top)
                        }
                    }
                }
            }
            .task {
                guard !didSetMobileInitialHorizontalScroll else { return }
                didSetMobileInitialHorizontalScroll = true
                await Task.yield()
                let calendar = Calendar.current
                let selectedIndex = calendarDays.firstIndex {
                    calendar.isDate($0.date, inSameDayAs: mobileSelectedDay)
                } ?? 0
                mobileVisibleDayID = min(
                    max(0, selectedIndex),
                    max(0, calendarDays.count - visibleDays))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mobile.week.timeGrid")
    }

    /// The header strip (`MobileDayHeaderStrip`, extracted above) is a scroll-disabled ScrollView
    /// steered to the day-columns scroller's live offset via `headerOffset`, so the two track
    /// pixel-for-pixel without the header being independently draggable — and, since `headerOffset`
    /// is read only through that subview's own @ObservedObject, without invalidating this whole
    /// view's body on every scroll frame.
    @State private var headerOffset = HeaderScrollOffset()

    private func mobileTimeGutter(
        width: CGFloat,
        startHour: Int,
        endHour: Int,
        hourHeight: CGFloat
    ) -> some View {
        let gridHeight = CGFloat(endHour - startHour) * hourHeight
        return VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                Text(hour > startHour ? mobileHourLabel(hour) : "")
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: width - 5, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -6)
                    .id(hour)
            }
        }
        .background(Color(.systemBackground))
        .frame(width: width, height: gridHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(.separator).opacity(0.35)).frame(width: 0.5)
        }
    }

    private func mobileDayColumn(
        _ day: DayData,
        width: CGFloat,
        startHour: Int,
        endHour: Int,
        hourHeight: CGFloat
    ) -> some View {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day.date)
        let visibleStart = calendar.date(byAdding: .hour, value: startHour, to: dayStart) ?? dayStart
        let visibleEnd = calendar.date(byAdding: .hour, value: endHour, to: dayStart) ?? dayStart
        let timed = day.items.filter {
            $0.hasScheduledTime && $0.behavior != .block
                && $0.start < visibleEnd
                && $0.resolvedEnd > visibleStart
        }
        let placements = gridPlacements(timed)
        if day.items.contains(where: { $0.pendingWriteID != nil }) {
        }
        // A day blocked all day (Busy all-day event), hatched as on the Mac.
        let blockedBy = day.items.first(where: \.blocksWholeDay)
        return ZStack(alignment: .topLeading) {
            // Today's wash marks a column among others; in Day mode there are no others.
            (day.isToday && !dayMode ? DS.Palette.todayWash : Color(.systemBackground))
                .overlay {
                    if let blockedBy {
                        BlockedDayFill(color: sourceCalendarColor(blockedBy, colors: smart.calendarColorHex) ?? .blue)
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
                                    $0.hasScheduledTime && $0.behavior != .block
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
                            handlesDrag: !dayMode)
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
                let start = mobileGridY(selection.start, startHour: startHour, hourHeight: hourHeight)
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
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
            ForEach(placements) { placement in
                let occurrence = placement.occurrence
                let visualEnd = mobileVisualEnd(for: placement, among: placements)
                let span = mobileLaneSpan(placement, width: width)
                let laneWidth = span.upperBound - span.lowerBound
                let x = span.lowerBound
                let start = mobileGridY(
                    max(displayStart(occurrence), visibleStart),
                    startHour: startHour,
                    hourHeight: hourHeight)
                let end = mobileGridY(
                    min(visualEnd, visibleEnd),
                    startHour: startHour,
                    hourHeight: hourHeight)
                // Its minutes, stretched to fit a title only where nothing is beneath it: a
                // 15-minute blocker straight before a swim was stretched over the swim when
                // zoomed out, while everything else stayed end to end.
                let blockHeight = CalendarBlockHeight.height(
                    natural: end - start,
                    minimum: 24,
                    roomBelow: mobileTopOfNextBlock(
                        below: placement, among: placements, width: width,
                        visibleStart: visibleStart, startHour: startHour, hourHeight: hourHeight
                    ).map { $0 - start - 1 })
                // Same band as the Mac grid: on a calendar layout travel is time, so it occupies
                // the minutes it takes rather than being a caption on the event.
                if let outbound = outboundBand(for: occurrence) {
                    // Prefer the reserved block and clamp against the previous event, for the same
                    // two reasons as the Mac grid: the block is in the first-paint snapshot so it
                    // draws immediately, and an unclamped short leg was drawn through whatever ran
                    // before it.
                    let preferred = mobileGridY(
                        max(outbound.leaveBy, visibleStart), startHour: startHour, hourHeight: hourHeight)
                    let travelTop = mobileTravelBandTop(
                        placement, among: placements, startHour: startHour,
                        hourHeight: hourHeight, preferred: preferred)
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
                        mobileGridY(max(ret.start, visibleStart), startHour: startHour, hourHeight: hourHeight),
                        meetingBottom)
                    let bandBottom = mobileGridY(
                        min(returnEnd, visibleEnd), startHour: startHour, hourHeight: hourHeight)
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
                gridBlock(occurrence, height: blockHeight)
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

            if day.isToday {
                let nowY = mobileGridY(Date(), startHour: startHour, hourHeight: hourHeight)
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
        .animation(.easeInOut(duration: 0.16), value: placements.map(\.id))
        // Keep each day as an accessibility container. Without this boundary SwiftUI flattens
        // the full dense week into one spatial sort; 100 events/day made an AX snapshot take
        // about five seconds and blocked the main thread during every assistive/UI-test query.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mobile.day.surface.\(day.id)")
        .accessibilityValue(
            "\(Occurrence.dayKey(day.date))|\(placements.map(\.occurrence.id).joined(separator: ","))"
        )
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
                guard case .second(true, let drag?) = value,
                      occ.behavior == .event, occ.meeting != nil else { return }
                if draggingEventID != occ.id {
                    draggingEventID = occ.id
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()   // the grab landed
                }
                dragOffsetY = drag.translation.height
                dragDayShift = Int((drag.translation.width / max(columnWidth, 1)).rounded())
            }
            .onEnded { value in
                guard draggingEventID == occ.id, let meeting = occ.meeting else {
                    draggingEventID = nil; dragOffsetY = 0; dragDayShift = 0
                    return
                }
                var translation = CGSize.zero
                if case .second(true, let drag?) = value { translation = drag.translation }
                defer { draggingEventID = nil; dragOffsetY = 0; dragDayShift = 0 }

                let cal = Calendar.current
                let shift = Int((translation.width / max(columnWidth, 1)).rounded())
                let snapped = ((Double(translation.height / hourHeight) * 60) / 5).rounded() * 5
                guard let targetDay = cal.date(byAdding: .day, value: shift, to: day) else { return }
                let clock = cal.dateComponents([.hour, .minute], from: occ.start)
                guard let base = cal.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                                          second: 0, of: targetDay) else { return }
                let newStart = base.addingTimeInterval(snapped * 60)
                guard abs(newStart.timeIntervalSince(occ.start)) >= 60 else { return }

                if smart.meetingRecurs(meeting) {
                    pendingRecurringMove = PendingEventMove(meeting: meeting,
                                                            occurrenceID: occ.id,
                                                            newStart: newStart)
                } else {
                    commitMove(meeting, occurrenceID: occ.id, to: newStart, span: .thisEvent)
                }
            }
    }

    private func mobileGridY(_ date: Date, startHour: Int, hourHeight: CGFloat) -> CGFloat {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = CGFloat(components.hour ?? startHour)
        let minute = CGFloat(components.minute ?? 0)
        return (hour + minute / 60 - CGFloat(startHour)) * hourHeight
    }

    /// Where a placement sits across the Day column: its lane of the column's width.
    private func mobileLaneSpan(_ placement: GridPlacement, width: CGFloat) -> Range<CGFloat> {
        let gap: CGFloat = 2
        let laneWidth = max(
            24,
            (width - 6 - CGFloat(placement.laneCount - 1) * gap) / CGFloat(placement.laneCount))
        let x = 3 + CGFloat(placement.lane) * (laneWidth + gap)
        return x..<(x + laneWidth)
    }

    /// The top of the nearest block drawn beneath `placement` across the same stretch of the
    /// column, for `CalendarBlockHeight` — nil when nothing is beneath it.
    private func mobileTopOfNextBlock(
        below placement: GridPlacement, among placements: [GridPlacement], width: CGFloat,
        visibleStart: Date, startHour: Int, hourHeight: CGFloat
    ) -> CGFloat? {
        let mine = mobileLaneSpan(placement, width: width)
        let myStart = displayStart(placement.occurrence)
        return placements
            .filter { $0.occurrence.id != placement.occurrence.id && displayStart($0.occurrence) > myStart }
            .filter { mobileLaneSpan($0, width: width).overlaps(mine) }
            .map { mobileGridY(max(displayStart($0.occurrence), visibleStart),
                               startHour: startHour, hourHeight: hourHeight) }
            .min()
    }

    private func mobileVisualEnd(for placement: GridPlacement, among placements: [GridPlacement]) -> Date {
        let end = placement.occurrence.resolvedEnd
        guard let next = placements
            .filter({ $0.lane == placement.lane && $0.occurrence.start >= end })
            .min(by: { $0.occurrence.start < $1.occurrence.start }),
              next.occurrence.start.timeIntervalSince(end) <= 5 * 60
        else { return end }
        return next.occurrence.start
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

    private func rebuildMobileCalendar(_ all: [Occurrence]) {
        // Everything outstanding, for today's reminders line — from the whole timeline, not the
        // days on screen: one from last week is still to do.
        let overdue = occurrences.occurrences.filter(\.isOverdueReminder)
        if overdue != overdueTasks { overdueTasks = overdue }
        let all = PendingRemovals.visible(all, id: { $0.meeting?.eventID }, start: \.start, hiding: ToastCenter.shared.hiddenIDs)
        let calendar = Calendar.current
        let offsets = dayMode ? Array(-1...1) : Array(0..<7)
        let rebuilt = offsets.compactMap { offset -> DayData? in
            guard let day = calendar.date(
                byAdding: .day,
                value: offset,
                to: mobileVisibleWeekStart) else { return nil }
            let items = DayColumn.occurrences(all, on: day, calendar: calendar)
            let committed = items
                .filter { $0.behavior == .event || ($0.behavior == .task && $0.hasScheduledTime) }
                .reduce(0.0) { $0 + $1.resolvedEnd.timeIntervalSince($1.start) } / 3_600
            return DayData(
                id: dayMode ? offset + 1 : offset,
                date: day,
                weekday: Self.weekdayFmt.string(from: day).uppercased(),
                dayNum: Self.dayFmt.string(from: day),
                letter: Self.letterFmt.string(from: day),
                isToday: calendar.isDateInToday(day),
                items: items,
                committed: committed,
                itemsToken: items.hashValue)
        }
        // Every occurrence publish lands here — a launch sends several, most changing nothing
        // on these days. Assigning an equal list still redrew the whole grid each time.
        if rebuilt != calendarDays { calendarDays = rebuilt }
        if mobileVisibleDayID == nil {
            let selectedIndex = calendarDays.firstIndex {
                calendar.isDate($0.date, inSameDayAs: mobileSelectedDay)
            } ?? 0
            mobileVisibleDayID = dayMode ? 1 : min(max(0, selectedIndex), max(0, calendarDays.count - 3))
        }
    }

    private func moveMobileWeek(_ delta: Int) {
        mobileWeekOffset += delta
        mobileSelectedDay = mobileVisibleWeekStart
        mobileVisibleDayID = dayMode ? 1 : 0
        rebuildMobileCalendar(mobileWindowOccurrences())
        Task { await refreshMobileWeek() }
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
        guard !mobileWeekLoading else { return }
        let requestedStart = mobileVisibleWeekStart
        let calendar = Calendar.current
        let requestStart = dayMode
            ? (calendar.date(byAdding: .day, value: -1, to: requestedStart) ?? requestedStart)
            : requestedStart
        guard let end = calendar.date(byAdding: .day, value: dayMode ? 3 : 7, to: requestedStart)
        else { return }
        mobileWeekLoading = true
        await occurrences.refreshPlanningWindow(from: requestStart, to: end)
        if requestedStart == mobileVisibleWeekStart {
            rebuildMobileCalendar(mobileWindowOccurrences())
            mobileWeekLoading = false
        } else {
            // Navigation happened while the old window was in flight. Finish it, then fetch the
            // newly visible range once — never run both refresh loops concurrently.
            mobileWeekLoading = false
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
    #endif

    // MARK: - Agenda

    #if os(macOS)
    /// A schedule table: date, time, then the existing actionable row. The calendar owns the
    /// weather/time geometry; the agenda needs neither row measurements nor duration scaling.
    private var macAgenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if listMode { ReminderTimingOffers() }
                if !overdueTasks.isEmpty {
                    Section {
                        ForEach(overdueTasks) { occ in
                            wrap(occ) { taskContent(occ) }.contextMenu { taskMenu(occ) }
                        }
                    } header: {
                        HStack(spacing: DS.Space.s) {
                            Text("Overdue").foregroundStyle(DS.Palette.danger)
                            Text("\(overdueTasks.count)").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .font(.headline)
                        .padding(DS.Space.l)
                        .background(Color(.systemGroupedBackground))
                    }
                    .accessibilityIdentifier("plan.list.overdue")
                }
                ForEach(days) { day in
                    let items = day.items.filter { $0.behavior != .block }
                    let nextID = items.first { $0.hasScheduledTime && $0.start >= nowAnchor }?.id
                    Section {
                        if items.isEmpty {
                            Text("Nothing scheduled")
                                .foregroundStyle(.secondary)
                                .padding(DS.Space.l)
                                .padding(.leading, DS.Agenda.dateColumn)
                        } else {
                            ForEach(items) { occ in
                                if day.isToday && occ.id == nextID {
                                    nowMarker.padding(.leading, DS.Agenda.dateColumn + DS.Space.l)
                                }
                                styledRow(occ)
                            }
                            if day.isToday && nextID == nil {
                                nowMarker.padding(.leading, DS.Agenda.dateColumn + DS.Space.l)
                            }
                        }
                    } header: {
                        HStack(spacing: DS.Space.l) {
                            Text(day.isToday ? "Today" : day.date.formatted(.dateTime.weekday(.wide)))
                                .foregroundStyle(day.isToday ? DS.Palette.accent : .primary)
                                .frame(width: DS.Agenda.dateColumn, alignment: .leading)
                            Text(day.date, format: .dateTime.month(.wide).day())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .font(.headline)
                        .padding(DS.Space.l)
                        .background(Color(.systemGroupedBackground))
                        .overlay(alignment: .bottom) { Divider() }
                    }
                    .id(day.id)
                }
            }
            .padding(.bottom, DS.Space.xl)
        }
        .accessibilityIdentifier("plan.agenda")
    }

    private func agendaTime(_ occ: Occurrence) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if occ.behavior == .allDay {
                Text("All day")
            } else if occ.overdue {
                Text(occ.schedule.constraints?.deadline ?? occ.start,
                     format: .dateTime.month(.abbreviated).day())
            } else if occ.hasScheduledTime {
                Text(occ.start, format: .dateTime.hour().minute())
                if spanItem(occ) {
                    Text(occ.resolvedEnd, format: .dateTime.hour().minute())
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Any time")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: DS.Agenda.timeColumn, alignment: .leading)
    }
    #endif

    private var agenda: some View {
        ScrollView {
            // Deliberately EAGER, not LazyVStack — decided, not overlooked. The weather stripes
            // are positioned by preference-published row anchors; a lazy container births and
            // kills those GeometryReaders as day sections scroll in and out, so every scroll
            // position change would mutate the anchor dictionaries → guarded @State writes →
            // body re-evaluations *while scrolling*. The eager tree publishes once per data
            // change (post loop-fix: occurrence updates and the once-a-minute now marker), which
            // is strictly cheaper for 7 sections. Revisit only with Instruments evidence.
            VStack(alignment: .leading, spacing: 14) {
                // A repeating reminder that follows a moment, offered it (`AnchorSuggestions`).
                if listMode { ReminderTimingOffers() }
                if !overdueTasks.isEmpty {
                    VStack(alignment: .leading, spacing: durStyle == .height ? 8 : 6) {
                        HStack(spacing: 8) {
                            Text("OVERDUE").font(.caption.weight(.bold)).foregroundStyle(DS.Palette.danger)
                            Text("\(overdueTasks.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        ForEach(overdueTasks) { occ in
                            wrap(occ) { taskContent(occ) }.contextMenu { taskMenu(occ) }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plan.list.overdue")
                }
                ForEach(days) { d in
                    VStack(alignment: .leading, spacing: durStyle == .height ? 8 : 6) {
                        dayHeader(d)
                            .background(GeometryReader { g in
                                // Rounded like every other published measurement in this file —
                                // raw minY jitter would defeat the onPreferenceChange guard.
                                Color.clear.preference(key: DayOffsetKey.self,
                                    value: [d.id: g.frame(in: .named("weekContent")).minY.rounded()])
                            })
                        if d.items.isEmpty {
                            Text("Nothing scheduled").font(.footnote).foregroundStyle(.secondary)
                                .padding(.horizontal, 18)
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                // Travel-aware, per-day: a day you fly shows its origin → transit →
                                // destination, with seams. A normal day is the single-location stripe.
                                let wx = weather.stripeData(for: d.date, endHour: durStyle == .grid ? 23 : 22)
                                if !wx.hours.isEmpty {
                                    WeatherStripe(hourly: wx.hours,
                                                  anchors: dayAnchors[d.id] ?? [],
                                                  day: d.date,
                                                  markers: wx.markers,
                                                  // The grid runs to 23:00; the row styles stop at 22.
                                                  endHour: durStyle == .grid ? 23 : 22) { instant in
                                        weatherFocus = WeatherFocus(id: instant)
                                    }
                                    .padding(.leading, 18)
                                    .opacity((dayAnchors[d.id]?.count ?? 0) >= 2 ? 1 : 0)
                                }
                                VStack(alignment: .leading, spacing: durStyle == .height ? 8 : 6) {
                                    if durStyle == .grid {
                                        dayGrid(d)
                                    } else {
                                        // `nowAnchor`, not `Date()`. A raw Date published into the
                                        // anchor preference differs on every body pass, so the
                                        // preference always "changes", onPreferenceChange always
                                        // writes, and the view re-invalidates forever — the exact
                                        // loop that got TodayView killed for background CPU.
                                        // TodayView was fixed; this was its unfixed twin.
                                        let now = nowAnchor
                                        let nowIdx = d.isToday ? d.items.firstIndex { $0.start >= now } : nil
                                        ForEach(Array(d.items.enumerated()), id: \.element.id) { idx, occ in
                                            if let n = nowIdx, idx == n { nowMarker.background(dayAnchor(d.id, now)) }
                                            // Open time ahead, named ("1 hr 15 min free") — only
                                            // for time still to come, and only gaps worth planning.
                                            if idx > 0, occ.start > now,
                                               let gap = TodayText.freeGap(
                                                   from: max(d.items[idx - 1].resolvedEnd, now), to: occ.start,
                                                   minimum: 45 * 60) {
                                                agendaGapRow(gap)
                                            }
                                            styledRow(occ).background(dayAnchor(d.id, occ.start))
                                        }
                                    }
                                }
                            }
                            .coordinateSpace(.named("weekDay-\(d.id)"))
                        }
                    }
                    .id(d.id)
                }
            }
            .padding(.bottom, 44)
            .coordinateSpace(.named("weekContent"))
        }
        .scrollPosition($scrollPos)
        // Write only on real change: assigning an identical value to @State still invalidates the
        // view, and the view republishes the preference — that's the shape of the loop that killed
        // the app (see TodayView's onPreferenceChange). The values themselves are quantized at the
        // publish sites (minute for dates, whole points for y) so float jitter can't defeat this.
        .onPreferenceChange(DayOffsetKey.self) { new in
            if new != dayOffsets { dayOffsets = new }
        }
        .onPreferenceChange(DayTimeAnchorKey.self) { new in
            if new != dayAnchors { dayAnchors = new }
        }
        .onScrollGeometryChange(for: Geo.self,
            of: { Geo(content: $0.contentSize.height, container: $0.containerSize.height) },
            action: { _, g in
                if contentH != g.content { contentH = g.content }
                if viewH != g.container { viewH = g.container }
            })
        .frame(maxWidth: .infinity)
    }

    // MARK: - Styled row dispatch

    /// The "now" the week timeline is drawn against, truncated to the minute — published values
    /// must be stable between body passes or the preference loop never converges (see TodayView's
    /// nowAnchor for the full story; the stripe only needs minute resolution anyway).
    private var nowAnchor: Date {
        let t = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 60).rounded(.down) * 60)
    }

    /// Publish where this row sits within its day, so that day's stripe can line its hours up
    /// with the actual layout rather than assuming a linear clock.
    ///
    /// `y` is rounded to whole points: raw `midY` carries sub-point layout jitter, which makes
    /// "identical" layouts publish unequal values pass after pass and defeats the equality guard
    /// in onPreferenceChange — the residual foreground storm ran on exactly that. The stripe
    /// interpolates hours across tens of points, so point precision is more than it needs.
    private func dayAnchor(_ dayID: Int, _ date: Date) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: DayTimeAnchorKey.self,
                value: [dayID: [TimeAnchor(time: date,
                                           y: proxy.frame(in: .named("weekDay-\(dayID)")).midY.rounded())]]
            )
        }
    }

    private func agendaGapRow(_ text: String) -> some View {
        Label(text, systemImage: "circle.dashed")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 2)
    }

    /// An all-day event as a row of the list: title, Free when it is, "All day".
    private func allDayContent(_ occ: Occurrence) -> some View {
        HStack(spacing: 8) {
            Image(systemName: occ.blocksWholeDay ? "calendar.badge.clock" : "calendar")
                .foregroundStyle(sourceCalendarColor(occ, colors: smart.calendarColorHex) ?? .blue)
            Text(occ.title).font(.body).lineLimit(1)
            Spacer(minLength: 4)
            if occ.showsAsFree { FreeBadge() }
            #if os(iOS)
            Text("All day").font(.caption).foregroundStyle(.secondary)
            #endif
        }
    }

    @ViewBuilder private func styledRow(_ occ: Occurrence) -> some View {
        switch occ.behavior {
        case .task:
            wrap(occ) { taskContent(occ) }.contextMenu { taskMenu(occ) }
        case .event:
            if let m = occ.meeting {
                Button { openEvent(m) } label: { wrap(occ) { meetingContent(m, occ) } }.buttonStyle(.plain)
            }
        case .allDay:
            if let m = occ.meeting {
                Button { openEvent(m) } label: { wrap(occ) { allDayContent(occ) } }.buttonStyle(.plain)
            }
        case .alarm:
            wrap(occ) { alarmContent(occ) }
                .contextMenu {
                    Button(role: .destructive) {
                        if let id = UUID(uuidString: String(occ.id.dropFirst("alarm:".count))) { alarms?.cancelOneOff(id) }
                    } label: { Label("Delete alarm", systemImage: "trash") }
                }
        case .cue:
            if let r = routines.routines.first(where: { $0.id == occ.routineID }) {
                Button { inspectingCue = occ } label: { wrap(occ) { cueContent(r, occ) } }
                    .buttonStyle(.plain).contextMenu { cueMenu(r, occ) }
            } else {
                wrap(occ) { genericCueContent(occ) }
            }
        case .block:
            EmptyView()
        }
    }

    /// Wrap a row's inner content in the card, applying proportional height when selected.
    @ViewBuilder private func wrap<C: View>(_ occ: Occurrence, @ViewBuilder _ content: () -> C) -> some View {
        #if os(macOS)
        HStack(spacing: DS.Space.l) {
            agendaTime(occ)
            content()
        }
        .padding(.leading, DS.Agenda.dateColumn + DS.Space.l * 2)
        .padding(.trailing, DS.Space.l)
        .frame(minHeight: DS.Row.minHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            DS.Palette.separator.frame(height: 1)
                .padding(.leading, DS.Agenda.dateColumn + DS.Space.l)
        }
        #else
        content()
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity,
                   minHeight: durStyle == .height ? blockHeight(occ) : nil,
                   alignment: durStyle == .height ? .topLeading : .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.horizontal, 12)
        #endif
    }

    // MARK: - Row contents (no card)

    private func taskContent(_ occ: Occurrence) -> some View {
        HStack(spacing: 12) {
            Button {
                occurrences.toggleTask(occ)
            } label: { Image(systemName: occ.completed ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(DS.Palette.task) }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(occ.title).font(.subheadline).lineLimit(1).strikethrough(occ.completed, color: .secondary)
                // Tied to a moment that hasn't come: what it waits for ("After your workout").
                Text(occ.waitingFor ?? ReminderText.subtitle(missedDays: occ.missedDays)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if occ.overdue { Text("Overdue").font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.danger) }
            else {
                #if os(iOS)
                if occ.hasScheduledTime { spanTrailing(occ) }
                else { Text("Due").font(.caption2).foregroundStyle(.secondary) }
                #endif
            }
        }
        .padding(.vertical, 8)
        .opacity(occ.completed ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private func meetingContent(_ meeting: MeetingInfo, _ occ: Occurrence) -> some View {
        let past = meeting.start < Date()
        return HStack(spacing: 12) {
            MeetingActionIcon(meeting: meeting)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.subheadline).lineLimit(1)
                if let f = flightLeg(for: meeting), !past, let line = flightLine(f) {
                    Label(line, systemImage: "airplane")
                        .font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.accent).labelStyle(.titleAndIcon).lineLimit(1)
                } else if let leg = leaveBy(for: meeting), !past {
                    Label("Leave by \(leg.leaveBy.formatted(.dateTime.hour().minute())) · \(leg.travelMinutes) min", systemImage: "figure.walk.motion")
                        .font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.accent).labelStyle(.titleAndIcon)
                } else if let ret = returnLeg(for: meeting), (ret.end ?? ret.start) > Date() {
                    // Keyed to the return block's own window, not `past` (the meeting's start) --
                    // `past` would mask this the moment the meeting begins, which is exactly when
                    // the outbound "leave by" above stops applying and this one starts to matter.
                    let mins = Int((ret.end ?? ret.start).timeIntervalSince(ret.start) / 60)
                    Label("Leave for home by \(ret.start.formatted(.dateTime.hour().minute())) · \(mins) min", systemImage: "house")
                        .font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.travel).labelStyle(.titleAndIcon)
                } else if meeting.isVirtual { Text(meeting.platform?.label ?? "Video call").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                else if let address = meeting.address { Text(address).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            #if os(iOS)
            spanTrailing(occ)
            #endif
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .opacity(past ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private func cueContent(_ r: Routine, _ occ: Occurrence) -> some View {
        let status = cueStatus(r, occ)
        return HStack(spacing: 12) {
            tile(r)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.subheadline).strikethrough(status == .done || occ.skipped, color: .secondary)
                Text(occ.skipped ? "Skipped" : r.sourceLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if occ.skipped { Text("Skipped").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            else { cueTrailing(status, occ) }
        }
        .padding(.vertical, 8)
        .opacity(status == .done || occ.skipped ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private func genericCueContent(_ occ: Occurrence) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(occ.tint.color).frame(width: 30, height: 30)
                .overlay(Image(systemName: occ.icon).font(.system(size: 14)).foregroundStyle(.white))
            Text(occ.title).font(.subheadline).lineLimit(1)
            Spacer(minLength: 4)
            #if os(iOS)
            if occ.hasScheduledTime { Text(occ.start, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            #endif
        }
        .padding(.vertical, 8)
    }

    private func alarmContent(_ occ: Occurrence) -> some View {
        let past = occ.start < Date()
        return HStack(spacing: 12) {
            ZStack { Circle().fill(DS.Palette.accent.opacity(DS.Tint.soft))
                Image(systemName: "alarm").font(.system(size: 14)).foregroundStyle(DS.Palette.accent) }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(occ.title).font(.subheadline).lineLimit(1)
                Text("Alarm").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            #if os(iOS)
            Text(occ.start, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            #endif
        }
        .padding(.vertical, 8)
        .opacity(past ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    // MARK: - Trailing / duration text

    /// A start–end range plus a length label, for items with a real span.
    @ViewBuilder private func spanTrailing(_ occ: Occurrence) -> some View {
        // Start–end already conveys the length in the range style; the extra duration label below
        // it was redundant, so it's gone. (The height/grid styles still show length visually.)
        Text("\(occ.start, format: .dateTime.hour().minute())–\(occ.resolvedEnd, format: .dateTime.hour().minute())")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    @ViewBuilder private func cueTrailing(_ status: DayMoment.Status, _ occ: Occurrence) -> some View {
        switch status {
        case .active: HStack(spacing: 5) { Circle().fill(DS.Palette.accent).frame(width: 7, height: 7); Text("Now").font(.caption.weight(.bold)).foregroundStyle(DS.Palette.accent) }
        case .done:   Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(DS.Palette.success)
        case .manual: autonomyTag(.manual)
        case .upcoming:
            #if os(macOS)
            if !occ.hasScheduledTime { Text("On start").font(.caption2).foregroundStyle(.secondary) }
            #else
            if occ.hasScheduledTime { Text(occ.start, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            else { Text("On start").font(.caption2).foregroundStyle(.secondary) }
            #endif
        }
    }

    private func durMin(_ occ: Occurrence) -> Int { max(0, Int(occ.resolvedEnd.timeIntervalSince(occ.start) / 60)) }
    private func spanItem(_ occ: Occurrence) -> Bool { occ.behavior == .event || (occ.behavior == .task && occ.hasScheduledTime) }
    private func lengthText(_ occ: Occurrence) -> String? {
        guard spanItem(occ) else { return nil }
        let m = durMin(occ); guard m > 0 else { return nil }
        if m < 60 { return "\(m)m" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h\(r)"
    }
    /// Proportional card height for the .height style.
    private func blockHeight(_ occ: Occurrence) -> CGFloat {
        guard spanItem(occ) else { return 46 }
        return min(150, 46 + CGFloat(max(0, durMin(occ) - 30)) * 0.8)
    }
    // MARK: - Time grid (per day)

    private func dayGrid(_ d: DayData) -> some View {
        let startHour = 6, endHour = 23
        let span = CGFloat(endHour - startHour)          // hours
        let hourH: CGFloat = 30
        let gridH = span * hourH
        let timed = d.items.filter { $0.hasScheduledTime }
        let placements = gridPlacements(timed)
        let untimed = d.items.filter { !$0.hasScheduledTime && $0.behavior != .block }
        let cal = Calendar.current
        func y(_ date: Date) -> CGFloat {
            let h = CGFloat(cal.component(.hour, from: date)) + CGFloat(cal.component(.minute, from: date)) / 60
            return max(0, (h - CGFloat(startHour)) * hourH)
        }
        return VStack(alignment: .leading, spacing: 8) {
            if !untimed.isEmpty {
                HStack(spacing: 6) {
                    ForEach(untimed) { occ in
                        HStack(spacing: 4) {
                            Circle().fill(occ.tint.color).frame(width: 6, height: 6)
                            Text(occ.title).font(.caption2).lineLimit(1)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                }
                .padding(.leading, 44)
            }
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(0...Int(span), id: \.self) { i in
                        let hour = startHour + i
                        let label = hour == 12 ? "12p" : hour < 12 ? "\(hour)a" : "\(hour - 12)p"
                        HStack(spacing: 6) {
                            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
                            Rectangle().fill(Color(.separator).opacity(0.4)).frame(height: 0.5)
                        }
                        .offset(y: CGFloat(i) * hourH)
                    }
                    ForEach(placements) { placement in
                        let occ = placement.occurrence
                        let gap: CGFloat = 3
                        let usable = max(40, geo.size.width - 44)
                        let width = (usable - CGFloat(placement.laneCount - 1) * gap)
                            / CGFloat(placement.laneCount)
                        let x = 44 + CGFloat(placement.lane) * (width + gap)
                        let h = max(hourH * 0.7, CGFloat(max(15, durMin(occ))) / 60 * hourH)
                        gridBlock(occ)
                            .frame(width: width, height: h)
                            .offset(x: x, y: y(occ.start))
                    }
                }
            }
            .frame(height: gridH, alignment: .topLeading)
            // The grid is linear in time, so two anchors pin the whole scale — no per-row
            // measurement needed. They're still *measured*, which is what makes the stripe line
            // up: the grid starts below the untimed-cue capsules, and runs to 23:00, neither of
            // which the stripe could have guessed.
            .background(GeometryReader { g in
                let frame = g.frame(in: .named("weekDay-\(d.id)"))
                // Rounded for the same reason as dayAnchor: published anchors must be bit-stable
                // between passes or the preference→@State write loop never settles.
                Color.clear.preference(key: DayTimeAnchorKey.self, value: [d.id: [
                    TimeAnchor(time: hourOn(d.date, startHour), y: frame.minY.rounded()),
                    TimeAnchor(time: hourOn(d.date, endHour), y: frame.maxY.rounded()),
                ]])
            })
        }
        .padding(.horizontal, 12).padding(.trailing, 12)
    }

    /// Assign simultaneous items to deterministic side-by-side lanes. Previously every block
    /// occupied the same full-width x position, so overlapping meetings/reminders covered each
    /// other and only the topmost action could be used.
    private func gridPlacements(_ occurrences: [Occurrence]) -> [GridPlacement] {
        CalendarLaneAllocator.placements(occurrences).map {
            GridPlacement(occurrence: $0.occurrence, lane: $0.lane, laneCount: $0.laneCount)
        }
    }

    private func hourOn(_ day: Date, _ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    @ViewBuilder private func gridBlock(_ occ: Occurrence, height: CGFloat = 24) -> some View {
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
                occurrences.toggleTask(occ)
            } label: {
                gridBlockContent(occ, height: height)
            }
            .buttonStyle(.plain)
            .contextMenu { taskMenu(occ) }
        case .alarm:
            gridBlockContent(occ, height: height)
                .contextMenu {
                    Button(role: .destructive) {
                        if let id = UUID(uuidString: String(occ.id.dropFirst("alarm:".count))) {
                            alarms?.cancelOneOff(id)
                        }
                    } label: {
                        Label("Delete alarm", systemImage: "trash")
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
        // Zoomed-in hours make blocks taller; use the room for more of the event.
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if occ.behavior == .task {
                    // Same rule as the Mac grid: for a reminder, done-or-not is the fact worth
                    // the glyph, so it always shows the circle/checkmark rather than a kind icon.
                    Image(systemName: occ.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                } else if occ.behavior != .event {
                    Image(systemName: occ.completed ? "checkmark.circle.fill" : (occ.skipped ? "xmark.circle" : occ.icon))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                }
                if occ.meeting?.othersAllDeclined == true { OthersDeclinedMark() }
                Text(occ.title)
                    // A block kept to its own few minutes (see CalendarBlockHeight) still names itself.
                    .font(height < 20 ? .system(size: 9, weight: .semibold) : DS.Typeface.eventTitle)
                    .foregroundStyle(.primary)
                    .strikethrough(occ.completed || occ.skipped, color: .secondary)
                    .lineLimit(height >= 76 ? 3 : (height >= 40 ? 2 : 1))
                // A moment — a wake-up, an alarm — has no length to draw, so its block is too short
                // for the time line below: its time goes beside the name, and keeps its room first.
                if height < 40, occ.hasScheduledTime, occ.behavior == .cue || occ.behavior == .alarm {
                    Text(occ.start, format: .dateTime.hour().minute())
                        .font(DS.Typeface.eventMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                        .accessibilityIdentifier("grid.cueTime")
                }
                Spacer(minLength: 0)
            }
            // Same "Travel home" hold meetingContent surfaces inline, drawn here too so Day-grid
            // users (WeekView in dayMode) see it — the grid's own .block occurrences stay
            // undrawn (design intent), so this is the only place the return leg reaches the grid.
            // A short block has no room for the duration, so collapse to icon + time only.
            if occ.behavior == .event, let meeting = occ.meeting,
               let ret = returnLeg(for: meeting), (ret.end ?? ret.start) > Date() {
                let mins = Int((ret.end ?? ret.start).timeIntervalSince(ret.start) / 60)
                Label(
                    height >= 40
                        ? "Home by \(ret.start.formatted(.dateTime.hour().minute())) · \(mins) min"
                        : ret.start.formatted(.dateTime.hour().minute()),
                    systemImage: "house"
                )
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Palette.travel)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            } else if height >= 40 {
                Text(TimeRangeText.compact(occ.start, occ.resolvedEnd))
                    .font(DS.Typeface.eventMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if height >= 64, let meeting = occ.meeting {
                if meeting.isVirtual {
                    Text(meeting.platform?.label ?? "Video call")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let address = meeting.address, !address.isEmpty {
                    Text(address)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, DS.Space.s + EventStateStyle.ribbonInset(ribbons))
        .padding(.trailing, DS.Space.xs)
        .padding(.vertical, height < 16 ? 0 : DS.Space.hair)
        // Too short for any text: just the block, its colour and ribbon.
        .opacity(height < 9 ? 0 : 1)
        // The block fills its whole slot at every height, text at the top. Below 46 pt the
        // content used to hug its text and sit centred in the slot, so a 7:00–7:25 call drew as a
        // slim pill from about 7:07 to 7:18.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Matches the Mac grid: free events keep the calendar colour but lose the solid fill and
        // the full-strength spine, so the column separates held slots from merely-noted ones.
        .background(
            color.opacity(EventStateStyle.fillOpacity(occ)),
            in: RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
        )
        // Text never spills out of a short block onto the one below it.
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
        .overlay(alignment: .leading) {
            EventRibbons(colors: ribbons, opacity: occ.showsAsFree ? 0.4 : 1, cornerRadius: 1.5)
                .padding(.vertical, 2)
        }
        .freeBlockTreatment(occ.showsAsFree, tint: color, cornerRadius: DS.Radius.block)
        .eventStateTreatment(occ.meeting, tint: color, cornerRadius: DS.Radius.block)
        .opacity(occ.completed || occ.skipped ? 0.55 : 1)
        .blockedDayBase(cornerRadius: DS.Radius.block)
        .contentShape(Rectangle())
        .accessibilityLabel("\(occ.title), \(occ.start.formatted(.dateTime.hour().minute()))")
    }

    private var nowMarker: some View {
        HStack(spacing: 8) {
            Circle().fill(DS.Palette.accent).frame(width: 7, height: 7)
            Text("Now · \(Date().formatted(.dateTime.hour().minute()))").font(.caption2.weight(.bold)).foregroundStyle(DS.Palette.accent).monospacedDigit()
            Rectangle().fill(DS.Palette.accent.opacity(0.4)).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 2)
    }

    // MARK: - Menus

    @ViewBuilder private func cueMenu(_ r: Routine, _ occ: Occurrence) -> some View {
        if occ.id.hasPrefix("extra:") {
            Button(role: .destructive) {
                ExceptionStore.shared.removeExtra(String(occ.id.dropFirst("extra:".count))); Task { await occurrences.recompute() }
            } label: { Label("Remove this extra", systemImage: "trash") }
        } else if occ.occurrenceKey != nil {
            if occ.skipped {
                Button { CueSkip.restore(occ) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            } else {
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
            occurrences.toggleTask(occ)
        } label: { Label(occ.completed ? "Mark not done" : "Mark done", systemImage: occ.completed ? "circle" : "checkmark.circle") }
        Button { reschedulingTask = occ } label: { Label("Reschedule…", systemImage: "clock.arrow.circlepath") }
        if occ.isRepeatingTask {
            // Something taken each day belongs in Taken: logged taken or skipped, checked for clashes.
            Button { AnchorSuggestionStore.shared.move(reminder: occ) } label: {
                Label("Move to Taken…", systemImage: "pills")
            }
        }
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

    private func cueStatus(_ r: Routine, _ occ: Occurrence) -> DayMoment.Status {
        if r.triggerKind == .workoutStart { return signals.didWorkout(on: occ.start) ? .done : .upcoming }
        if signals.playingRoutineID == r.id { return .active }
        if r.triggerKind == .manual { return .manual }
        if occ.hasScheduledTime { return occ.start <= Date() ? .done : .upcoming }
        return .upcoming
    }
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

    #if os(iOS)
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
                                     startHour: Int,
                                     hourHeight: CGFloat,
                                     preferred: CGFloat) -> CGFloat {
        let start = displayStart(placement.occurrence)
        var top = preferred
        for other in placements where other.lane == placement.lane
            && other.occurrence.id != placement.occurrence.id {
            let otherStart = displayStart(other.occurrence)
            guard otherStart < start else { continue }
            let otherTop = mobileGridY(otherStart, startHour: startHour, hourHeight: hourHeight)
            let otherBottom = mobileGridY(
                mobileVisualEnd(for: other, among: placements),
                startHour: startHour, hourHeight: hourHeight)
            top = max(top, max(otherTop + 24, otherBottom))
        }
        return top
    }
    #endif

    /// Grid-layout variant of `returnLeg(for:)`, matched by occurrence the same way
    /// `travelLeg(for:)` matches the outbound leg — mirrors `returnLeg(forGrid:)` on the Mac
    /// grid. `.block` occurrences never get a grid block of their own (filtered out of `timed`
    /// in `mobileDayColumn`), so this is the only place the return leg reaches the mobile grid.
    private func returnLeg(forGrid occurrence: Occurrence) -> Occurrence? {
        guard occurrence.behavior == .event, let meeting = occurrence.meeting else { return nil }
        return returnLeg(for: meeting)
    }
    private func flightLeg(for meeting: MeetingInfo) -> SmartScheduleStore.FlightLeg? {
        smart.flightLegs.first { abs($0.flightStart.timeIntervalSince(meeting.start)) < 60 }
    }
    private func landingTempF(_ f: SmartScheduleStore.FlightLeg) -> Int? {
        guard let a = AirportTable.lookup(f.destCode) else { return nil }
        return weather.tempF(lat: a.latitude, lon: a.longitude, at: f.arriveAt)
    }
    private func flightLine(_ f: SmartScheduleStore.FlightLeg) -> String? {
        var parts: [String] = []
        if let by = f.leaveBy {
            parts.append("\(f.boardingAt == nil ? "Est. leave by" : "Leave by") \(by.formatted(.dateTime.hour().minute()))")
        }
        if let boarding = f.boardingAt { parts.append("board \(boarding.formatted(.dateTime.hour().minute()))") }
        if let t = landingTempF(f) { parts.append("\(t)° on landing") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private func openEvent(_ meeting: MeetingInfo) {
        // A meeting with no identifier is one Banana has created but no calendar has accepted yet.
        // There is nothing to inspect.
        guard meeting.eventID != nil else { return }
        #if os(macOS)
        MacNavigator.shared.inspectedMeeting = meeting
        #else
        if GoogleCalendarService.isGoogleEventInfoID(meeting.eventID) {
            eventSheet = CalendarEventSheet(googleMeeting: meeting)
        }
        #endif
    }
    private func tile(_ routine: Routine) -> some View {
        ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(routine.color.color)
            Image(systemName: routine.icon).font(.system(size: 15)).foregroundStyle(.white) }.frame(width: 30, height: 30)
    }
    private func autonomyTag(_ a: Autonomy) -> some View {
        Text(a.label.uppercased()).font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(a.tint.opacity(DS.Tint.soft), in: RoundedRectangle(cornerRadius: 6, style: .continuous)).foregroundStyle(a.tint)
    }

    private func dayHeader(_ d: DayData) -> some View {
        HStack(spacing: 8) {
            Text(d.weekday).font(.caption.weight(.bold))
            Text(d.dayNum).font(.caption).foregroundStyle(.secondary)
            Capsule().fill(Color(.tertiarySystemFill)).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(LinearGradient(colors: d.load < 0.45 ? [.green, .orange] : [.orange, .red], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * d.load)
                    }
                }
            Text("\(d.free)h free").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground))
        .contentShape(Rectangle())
        .onTapGesture { jump(to: d.id) }
    }

    private func jump(to index: Int) {
        let y = dayOffsets[index] ?? (maxScroll * CGFloat(index) / 6)
        withAnimation(.easeInOut(duration: 0.3)) { scrollPos.scrollTo(y: max(0, min(maxScroll, y))) }
    }

    struct DayOffsetKey: PreferenceKey {
        static var defaultValue: [Int: CGFloat] = [:]
        static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
            value.merge(nextValue(), uniquingKeysWith: { a, _ in a })
        }
    }
    private static let weekdayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d"; return f }()
    private static let letterFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEEE"; return f }()
}

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
        let slots = nav.offeredSlots.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
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
