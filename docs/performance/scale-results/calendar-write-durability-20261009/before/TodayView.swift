import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One row on the merged day timeline — a cue you control (carrying its occurrence, so
/// per-day exceptions can attach), or a meeting for context.
private enum DayItem: Identifiable {
    case cue(DayMoment, Occurrence)
    case meeting(MeetingInfo)
    case task(Occurrence)
    case alarm(Occurrence)

    var id: String {
        switch self {
        case .cue(_, let occ): return "cue-\(occ.id)"
        case .meeting(let m):  return "mtg-\(m.id)"
        case .task(let occ):   return "task-\(occ.id)"
        case .alarm(let occ):  return occ.id
        }
    }
    var sortDate: Date {
        switch self {
        case .cue(let m, let occ): return m.time ?? occ.start
        case .meeting(let m):      return m.start
        case .task(let occ):       return occ.start
        case .alarm(let occ):      return occ.start
        }
    }

    var title: String {
        switch self {
        case .cue(let m, _):   return m.routine.name
        case .meeting(let m):  return m.title
        case .task(let occ):   return occ.title
        case .alarm(let occ):  return occ.title
        }
    }

    /// Behind you, and nothing left to do about it — so it can fold away.
    ///
    /// Note what is deliberately NOT finished: an overdue task is not done just because its time
    /// has passed, and an active cue is not done because it's playing right now. Folding either of
    /// those away would hide the two things you most need to see.
    var isFinished: Bool {
        switch self {
        case .cue(let m, let occ): return m.status == .done || occ.skipped
        // A past meeting is NOT folded away: events are the skeleton the day hangs on, and
        // "what did I have this morning" is a question this screen must answer at a glance.
        // Finished cues/tasks fold because they're checklist items, not anchors.
        case .meeting:             return false
        case .task(let occ):       return occ.completed
        case .alarm(let occ):      return occ.start < Date()
        }
    }
}

/// A timeline row, or a folded run of finished ones.
private enum TimelineBlock: Identifiable {
    case item(DayItem)
    case done([DayItem])

    var id: String {
        switch self {
        case .item(let i):   return i.id
        case .done(let run): return "done-\(run.first?.id ?? "")"
        }
    }
    var sortDate: Date {
        switch self {
        case .item(let i):   return i.sortDate
        case .done(let run): return run.first?.sortDate ?? .distantPast
        }
    }
}

/// Everything this screen can present, as one value.
///
/// There were eleven `.sheet` modifiers stacked on this view. SwiftUI supports ONE sheet per view;
/// stack more and they fight — the symptoms being exactly the two reported: Re-plan came up blank
/// the first time (its content was built before the sibling state that fed it had committed) and a
/// calendar event opened from a timeline row couldn't be swiped away, while the identical sheet
/// opened from Up next could. One modifier, one item, no fight.
private enum TodaySheet: Identifiable {
    case weather(Date)
    case alarms
    case settings
    case nowPlaying
    case editCue(Routine)
    case event(CalendarEventSheet)
    case tomorrow
    case replan(Scheduler.Result)
    case move(Occurrence)
    case addExtra(Routine)
    case rescheduleTask(Occurrence)
    case editTask(Occurrence)
    case newTask
    case newCalendarEvent

    var id: String {
        switch self {
        case .weather(let d):        return "wx-\(d.timeIntervalSince1970)"
        case .alarms:                return "alarms"
        case .settings:              return "settings"
        case .nowPlaying:            return "nowplaying"
        case .editCue(let r):        return "cue-\(r.id)"
        case .event(let e):          return "event-\(e.id)"
        case .tomorrow:              return "tomorrow"
        case .replan:                return "replan"
        case .move(let o):           return "move-\(o.id)"
        case .addExtra(let r):       return "extra-\(r.id)"
        case .rescheduleTask(let o): return "resched-\(o.id)"
        case .editTask(let o):       return "edittask-\(o.id)"
        case .newTask:                return "newtask"
        case .newCalendarEvent:       return "newcalendarevent"
        }
    }
}

/// The new home: your day as ONE timeline — cues you control interleaved with the
/// meetings from your calendar (and their leave-by nudges) — the active one up top,
/// and a grid of cues you can start by hand.
struct TodayView: View {
    @EnvironmentObject var routines: RoutineStore
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var music: MusicController
    @EnvironmentObject var smart: SmartScheduleStore
    @EnvironmentObject var occurrences: OccurrenceStore
    @EnvironmentObject var health: HealthKitStore
    @EnvironmentObject var fitness: FitnessStore
    @EnvironmentObject var weather: WeatherStore
    @EnvironmentObject var alarms: AlarmStore

    /// Last night's card shows until noon.
    private static func showsLastNight(_ now: Date = Date()) -> Bool {
        Calendar.current.component(.hour, from: now) < 12
    }

    /// Health is otherwise only re-read from the Workouts tab, so the morning card would show
    /// the night before last (or nothing) until you'd been there.
    private func refreshLastNight() async {
        if Self.showsLastNight() { await health.refreshIfStale() }
    }
    /// One sheet, one source of truth. See TodaySheet.
    @State private var sheet: TodaySheet?
    /// Which folded runs of finished items the person has opened. Collapsed by default: the day
    /// you have left is the point of this screen, and the day you've already done is reference.
    @State private var expandedRuns: Set<String> = []
    @State private var connectingCalendar = false
    /// Row positions, measured, so the weather stripe can share the timeline's vertical scale.
    static let timelineSpace = "todayTimeline"
    @State private var timeAnchors: [TimeAnchor] = []

    /// Travel-aware stripe data for today: hours stitched from the right location, plus place
    /// markers. Memoised inside WeatherStore, so reading it a few times per body is cheap.
    private var stripe: WeatherStore.StripeData { weather.stripeData(for: Date()) }

    private func cueStatus(for r: Routine, time: Date?) -> DayMoment.Status {
        if r.triggerKind == .workoutStart {
            return didWorkoutToday ? .done : .upcoming   // fired today = done; else "On start"
        }
        if player.isPlaying, player.activeRoutineID == r.id { return .active }
        if r.triggerKind == .manual { return .manual }
        if let t = time { return t <= Date() ? .done : .upcoming }
        return .upcoming
    }

    /// True if a workout was recorded today (Apple Health — includes Watch sessions the
    /// phone wrote), so the workout-start cue reads as done once you've trained.
    private var didWorkoutToday: Bool {
        health.workouts.contains { Calendar.current.isDateInToday($0.start) }
            || fitness.summaries.contains { Calendar.current.isDateInToday($0.start) }
    }
    private var scenes: [Routine] {
        routines.routines.filter { $0.enabled && ($0.triggerKind == .manual || $0.autonomy == .nudge) }
    }
    /// The next thing on the actual day — meeting or cue — whichever comes first.
    /// Takes the already-built list so the body materializes the day exactly once per pass.
    private func nextItem(in items: [DayItem], now: Date) -> DayItem? {
        items.first { item in
            switch item {
            case .cue(let m, _):
                return UpNext.isCandidate(time: m.time, pending: m.status == .upcoming, now: now)
            case .meeting(let mt):
                return UpNext.isCandidate(time: mt.start, pending: true, now: now)
            case .task(let occ):
                // An undated task has no time to be "next" at — see `UpNext`.
                return UpNext.isCandidate(time: occ.hasScheduledTime ? occ.start : nil,
                                          pending: !occ.completed, now: now)
            case .alarm(let occ):
                return UpNext.isCandidate(time: occ.start, pending: true, now: now)
            }
        }
    }

    /// Cues + calendar meetings, merged and sorted into one day — built straight from the
    /// unified occurrence timeline so each cue row carries its occurrence (for exceptions).
    private var dayItems: [DayItem] {
        var items: [DayItem] = []
        let routineByID = Dictionary(uniqueKeysWithValues: routines.routines.map { ($0.id, $0) })
        for occ in occurrences.occurrences(on: Date()) {
            switch occ.behavior {
            case .cue:
                guard let routineID = occ.routineID, let r = routineByID[routineID] else { continue }
                let time = occ.hasScheduledTime ? occ.start : nil
                items.append(.cue(DayMoment(routine: r, time: time, status: cueStatus(for: r, time: time)), occ))
            case .event, .allDay:
                if let m = occ.meeting { items.append(.meeting(m)) }
            case .task:
                items.append(.task(occ))
            case .alarm:
                items.append(.alarm(occ))
            case .block:
                break   // derived blocks (bedtime) not shown on the timeline yet
            }
        }
        return items.sorted { $0.sortDate < $1.sortDate }
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
    private func flightLeg(for meeting: MeetingInfo) -> SmartScheduleStore.FlightLeg? {
        smart.flightLegs.first { abs($0.flightStart.timeIntervalSince(meeting.start)) < 60 }
    }
    private func landingTempF(_ f: SmartScheduleStore.FlightLeg) -> Int? {
        guard let a = AirportTable.lookup(f.destCode) else { return nil }
        return weather.tempF(lat: a.latitude, lon: a.longitude, at: f.arriveAt)
    }
    /// ONE concise flight line for the row — the two facts you act on: when to leave, and what
    /// you're landing into. The airport buffer and the hotel drive live in the tap-through detail,
    /// not crammed into two truncated rows.
    private func flightLine(_ f: SmartScheduleStore.FlightLeg) -> String? {
        var parts: [String] = []
        if let by = f.leaveBy {
            parts.append("\(f.boardingAt == nil ? "Est. leave by" : "Leave by") \(by.formatted(.dateTime.hour().minute()))")
        }
        if let boarding = f.boardingAt { parts.append("board \(boarding.formatted(.dateTime.hour().minute()))") }
        if let t = landingTempF(f) { parts.append("\(t)° on landing") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {

        let _ = RenderStats.note("TodayView")
        let _ = LaunchClock.mark("today.body")
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Built ONCE per body pass. The day list used to be re-derived 3–4 times per
                    // pass (next-item, timeline, and friends each re-filtered and re-sorted it).
                    let items = dayItems
                    let _ = { if !items.isEmpty { LaunchClock.mark("today.content") } }()

                    Text(Date(), format: .dateTime.weekday(.wide).month().day())
                        .font(.subheadline).foregroundStyle(.secondary)

                    // How the night went, while it's still the morning it's about.
                    if Self.showsLastNight() {
                        LastNightCard()
                    }

                    nowCard
                    // Re-picked every minute: when the next thing starts, the card moves on by itself
                    // instead of waiting for something else to redraw the screen.
                    TimelineView(.everyMinute) { context in
                        if player.currentEpisode == nil, let next = nextItem(in: items, now: context.date) {
                            switch next {
                            case .cue(let moment, _): upNextCard(moment)
                            case .meeting(let meeting): upNextMeetingCard(meeting)
                            case .task(let occ): upNextTaskCard(occ)
                            case .alarm(let occ): upNextAlarmCard(occ)
                            }
                        }
                    }

                    // At most one prompt card at a time, most pressing first: a calendar that
                    // isn't connected, then a trip timed to a guessed place (it has a clock on it),
                    // then the rest of setup. Stacked, they pushed the day itself below the fold.
                    if !smart.calendarAuthorized {
                        calendarAccessCard
                    } else if PlaceQuestionCard.hasQuestion(smart) {
                        PlaceQuestionCard()
                    } else {
                        #if os(iOS)
                        FinishSetupCard()   // AlarmKit is iPhone-only; the Mac's stub never authorizes
                        #endif
                    }

                    sectionLabel("Your day")
                    if items.isEmpty {
                        // A clear day still renders a card, and the card has to say what to do
                        // next. Without this branch the timeline collapses to a zero-height
                        // rounded rectangle under a section header — a labelled void.
                        emptyDayCard
                    } else if stripe.hours.isEmpty {
                        timelineCard(items)
                    } else {
                        // One rail, not two — a mirrored second stripe shows identical data and
                        // only costs the timeline width. On a travel day `markers` adds the seams
                        // and place labels where the location (and its weather) changes.
                        HStack(spacing: 8) {
                            WeatherStripe(hourly: stripe.hours, anchors: timeAnchors,
                                          day: Date(), markers: stripe.markers) { instant in
                                sheet = .weather(instant)
                            }
                            .opacity(timeAnchors.count >= 2 ? 1 : 0)
                            timelineCard(items)
                        }
                        .coordinateSpace(.named(Self.timelineSpace))
                        .onPreferenceChange(TimeAnchorKey.self) { new in
                            // Assigning an identical value still invalidates the view, and the view
                            // republishes the preference — that's the shape of the loop that killed
                            // the app. Only write when something actually moved.
                            if new != timeAnchors {
                                RenderStats.note("anchorWrite")   // the loop's own footprint
                                timeAnchors = new
                            }
                        }
                    }

                    replanButton
                    planTomorrowButton

                    if !scenes.isEmpty {
                        sectionLabel("Start a cue")
                        scenesGrid
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
                #if os(macOS)
                // A day reads at a column, not a banner. Cap the measure and center it on the
                // grouped background rather than stretching rows across a 1100pt window.
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                #endif
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .principal) {
                    PlanModePicker()
                }
                ToolbarItem(placement: .automatic) {
                    BananaAssistantLaunchButton()
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button { sheet = .newTask } label: {
                            Label("New task", systemImage: "checklist")
                        }
                        Button { sheet = .newCalendarEvent } label: {
                            Label("New calendar event", systemImage: "calendar.badge.plus")
                        }
                        Button { sheet = .alarms } label: {
                            Label("New alarm", systemImage: "alarm")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
                #else
                ToolbarItem(placement: .automatic) {
                    BananaAssistantLaunchButton()
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button { sheet = .newTask } label: {
                            Label("New task", systemImage: "checklist")
                        }
                        Button { sheet = .newCalendarEvent } label: {
                            Label("New calendar event", systemImage: "calendar.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
                #endif
                #if os(macOS)
                ToolbarItem(placement: .principal) { PlanModePicker() }
                #endif
                ToolbarItem(placement: .automatic) {
                    Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                }
            }
            .task { alarms.pruneExpiredOneOffs() }
            .sheet(item: $sheet) { destination in
                switch destination {
                case .weather(let date):
                    WeatherDetailView(focus: date)
                case .alarms:
                    OneOffAlarmSheet()
                case .settings:
                    SettingsView(showsDoneButton: true)
                case .nowPlaying:
                    NowPlayingView()
                case .editCue(let routine):
                    RoutineEditorView(draft: routine, isNew: false)
                case .event(let box):
                    CalendarEventSheetView(sheet: box) {
                        Task {
                            await smart.refreshAgenda()
                            await occurrences.recompute()
                        }
                    }
                case .tomorrow:
                    TomorrowView()
                case .replan(let result):
                    ReplanSheet(result: result) { Task { await occurrences.applyReplan(result) } }
                case .move(let occ):
                    OccurrenceTimeSheet(title: "Move \(occ.title)", initial: occ.start) { newStart in
                        if let key = occ.occurrenceKey { ExceptionStore.shared.reschedule(key, to: newStart) }
                        Task { await occurrences.recompute() }
                    }
                case .addExtra(let routine):
                    OccurrenceTimeSheet(title: "Add \(routine.name)", initial: defaultExtraTime) { start in
                        ExceptionStore.shared.addExtra(seriesID: routine.id.uuidString, start: start)
                        Task { await occurrences.recompute() }
                    }
                case .rescheduleTask(let occ):
                    OccurrenceTimeSheet(title: "Reschedule \(occ.title)",
                                        initial: occ.hasScheduledTime ? occ.start : defaultExtraTime) { newDue in
                        if let id = occ.reminderID { Task { await occurrences.rescheduleTask(reminderID: id, to: newDue) } }
                    }
                case .editTask(let occ):
                    if let id = occ.reminderID {
                        NewTaskSheet(reminderID: id)
                    }
                case .newTask:
                    NewTaskSheet()
                case .newCalendarEvent:
                    #if DEBUG
                    // `--new-calendar-event-text "…"`: the form with words already typed, to look at.
                    NewCalendarEventSheet(initialTitle: CommandLine.arguments.firstIndex(of: "--new-calendar-event-text")
                        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "")
                    #else
                    NewCalendarEventSheet()
                    #endif
                }
            }
            #if DEBUG
            // `--wx-page 9` opens the detail page at 9am — the Simulator won't deliver synthetic
            // taps to the stripe, so this is how the page gets exercised without a device.
            .task {
                let args = CommandLine.arguments
                if args.contains("--new-calendar-event") {
                    sheet = .newCalendarEvent
                    return
                }
                if args.contains("--new-task") {
                    sheet = .newTask
                    return
                }
                if args.contains("--tomorrow") {
                    sheet = .tomorrow
                    return
                }
                guard let i = args.firstIndex(of: "--wx-page"), i + 1 < args.count,
                      let hour = Int(args[i + 1]) else { return }
                try? await Task.sleep(for: .seconds(3))   // let the forecast land first
                sheet = .weather(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date())
            }
            #endif
            .refreshable { await smart.refreshCalendar(); await occurrences.recompute(); await weather.refresh() }
            .task {
                #if DEBUG
                // This guard's own list used to omit "--today"/"--day"/"--week" — the very
                // routes TodayView itself renders under — so a screenshot launched with one of
                // those still ran the real agenda/occurrence/weather refresh below and overwrote
                // the route's injected fixture data with live (empty-on-Simulator) state within
                // about a second of launch. Same class of stale-list gap as RootView's
                // scenePhase-active guard nearby.
                let arguments = ProcessInfo.processInfo.arguments
                guard !arguments.contains("--ui-audit"),
                      !arguments.contains("--new-calendar-event"),
                      !arguments.contains("--new-task"),
                      !arguments.contains("--tomorrow"),
                      !arguments.contains("--today"),
                      !arguments.contains("--day"),
                      !arguments.contains("--week") else { return }
                #endif
                // Independent refreshes run concurrently — serialized, the agenda fetch delayed
                // the occurrence recompute, which delayed the weather fetch behind it.
                async let agenda: Void = smart.refreshAgenda()
                async let occs: Void = occurrences.recomputeIfStale()
                async let wx: Void = weather.refreshIfStale()
                async let night: Void = refreshLastNight()
                _ = await (agenda, occs, wx, night)
            }
            #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .macReplanRequested)) { _ in
                sheet = .replan(occurrences.replanToday())   // ⌘R / the Plan menu, same path as the button
            }
            #endif
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .macNewEventRequested)) { _ in
            sheet = .newCalendarEvent
        }
        .onReceive(NotificationCenter.default.publisher(for: .macNewTaskRequested)) { _ in
            sheet = .newTask
        }
        #endif
    }

    // MARK: - Now

    private var calendarAccessCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Calendar isn’t connected")
                    .font(.subheadline.weight(.semibold))
                Text("Connect it so meetings and free time appear in your day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(connectingCalendar ? "Connecting…" : "Connect") {
                Task {
                    connectingCalendar = true
                    await smart.requestCalendarAccess()
                    if smart.calendarAuthorized {
                        await occurrences.recompute()
                    }
                    connectingCalendar = false
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Palette.accent)
            .disabled(connectingCalendar)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.accent.opacity(DS.Tint.subtle), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("today.calendar-access")
    }

    /// The empty day. Deliberately a call to action rather than a status message: an empty
    /// state is the one screen where the next step has to be reachable from the emptiness itself.
    /// When the calendar isn't connected, `calendarAccessCard` is already above with that CTA, so
    /// this one points there instead of competing with it.
    private var emptyDayCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.horizon")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DS.Palette.accent)
                .symbolRenderingMode(.hierarchical)
            Text("Nothing scheduled today")
                .font(.headline)
            Text(smart.calendarAuthorized
                 ? "Add a task or an event, and it lands here."
                 : "Connect your calendar above and today fills in.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if smart.calendarAuthorized {
                HStack(spacing: 10) {
                    Button { sheet = .newTask } label: {
                        Label("New task", systemImage: "checklist")
                    }
                    Button { sheet = .newCalendarEvent } label: {
                        Label("New event", systemImage: "calendar.badge.plus")
                    }
                }
                .buttonStyle(.bordered)
                .tint(DS.Palette.accent)
                .font(.subheadline)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("today.empty-day")
    }

    @ViewBuilder private var nowCard: some View {
        if let episode = player.currentEpisode {
            Button { sheet = .nowPlaying } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        eyebrow(routines.routines.first { $0.id == player.activeRoutineID }?.name ?? "Now Playing")
                        Spacer()
                        Button { player.stop() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 13) {
                        Artwork(url: artworkURL, size: 58)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title).font(.headline).lineLimit(2)
                            if let name = podcastName {
                                Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 22) {
                        Spacer()
                        Button { player.goToPreviousEpisode() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                            .disabled(!player.hasPreviousEpisode)
                        Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 46)).foregroundStyle(DS.Palette.accent)
                        }
                        Button { player.skip(by: 30) } label: { Image(systemName: "goforward.30") }
                        Button { player.goToNextEpisode() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                            .disabled(!player.hasNextEpisode)
                        Spacer()
                    }
                    .font(.title3).foregroundStyle(.primary).buttonStyle(.plain)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        // Nothing playing → no card at all. A box announcing "Nothing playing" is a whole card's
        // worth of screen spent telling you about an absence you can already see; "Up next" moves
        // up and does something useful with the space.
    }

    private func upNextCard(_ moment: DayMoment) -> some View {
        HStack(spacing: 12) {
            tile(moment.routine)
            VStack(alignment: .leading, spacing: 1) {
                Text("Up next · \(moment.routine.name)").font(.subheadline.weight(.semibold))
                Text(subtitle(for: moment)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            autonomyTag(moment.routine.autonomy)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func upNextMeetingCard(_ meeting: MeetingInfo) -> some View {
        Button { openEvent(meeting) } label: {
            HStack(spacing: 12) {
                MeetingActionIcon(meeting: meeting)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Up next · \(meeting.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
                    // Redrawn each minute, so "Leave in 12 min" counts down while you look.
                    TimelineView(.everyMinute) { context in
                        Text(meetingSubtitle(meeting, now: context.date))
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func upNextTaskCard(_ occ: Occurrence) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist").font(.title3).foregroundStyle(DS.Palette.task).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Up next · \(occ.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(occ.hasScheduledTime ? occ.start.formatted(.dateTime.hour().minute()) + " · task" : "Task due today")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func upNextAlarmCard(_ occ: Occurrence) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm").font(.title3).foregroundStyle(DS.Palette.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Up next · \(occ.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
                TimelineView(.everyMinute) { context in
                    Text(occ.start.formatted(.dateTime.hour().minute()) + " \u{00B7} rings \(TodayText.countdown(to: occ.start, now: context.date))")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func meetingSubtitle(_ meeting: MeetingInfo, now: Date = Date()) -> String {
        let time = meeting.start.formatted(.dateTime.hour().minute())
        // Within a few hours, lead with the countdown in words; the clock time follows.
        let departure = flightLeg(for: meeting)?.leaveBy ?? leaveBy(for: meeting)?.leaveBy
        if let lead = TodayText.upNextLead(start: meeting.start, leaveBy: departure, now: now) {
            return "\(lead) \u{00B7} \(time)"
        }
        if let f = flightLeg(for: meeting), let by = f.leaveBy {
            let boarding = f.boardingAt.map { " · board \($0.formatted(.dateTime.hour().minute()))" } ?? ""
            let leaveLabel = f.boardingAt == nil ? "est. leave by" : "leave by"
            return "\(time) · \(leaveLabel) \(by.formatted(.dateTime.hour().minute()))\(boarding)"
        }
        if let leg = leaveBy(for: meeting) {
            return "\(time) · leave by \(leg.leaveBy.formatted(.dateTime.hour().minute()))"
        }
        if let ret = returnLeg(for: meeting) {
            return "\(time) · then home by \((ret.end ?? ret.start).formatted(.dateTime.hour().minute()))"
        }
        return meeting.isVirtual ? "\(time) · video call" : (meeting.address.map { "\(time) · \($0)" } ?? time)
    }

    // MARK: - Timeline

    /// Everything finished folds into ONE group, sitting where the first finished thing sat.
    ///
    /// I tried folding only *consecutive* runs first, to keep the timeline strictly chronological.
    /// It looked principled and was useless: a single un-finished row in the middle — a Workout
    /// cue still waiting to fire — splits the morning into two runs and strands a done item on its
    /// own, so you get "2 done" and a leftover. Gathering them all is what you actually asked for.
    ///
    /// It stays honest because everything finished is, by definition, behind you: the group sits
    /// above everything still to come. What remains in place below it are the past things that
    /// AREN'T done — an overdue task, a cue that never fired — which is exactly where you want
    /// your eye to land.
    ///
    /// One finished item is left inline. Replacing a row with a row that says "1 done" saves no
    /// space and costs a tap.
    private func timelineBlocks(_ items: [DayItem]) -> [TimelineBlock] {
        let finished = items.filter(isFinishedForLayout)
        guard finished.count > 1 else { return items.map { .item($0) } }

        var blocks: [TimelineBlock] = []
        var placed = false
        for item in items {
            if isFinishedForLayout(item) {
                if !placed { blocks.append(.done(finished)); placed = true }   // the whole pile, once
            } else {
                blocks.append(.item(item))
            }
        }
        return blocks
    }

    /// A just-tapped reminder stays where the finger expects it until the completion burst has
    /// persisted and reconciled. Other genuinely finished items still fold normally.
    private func isFinishedForLayout(_ item: DayItem) -> Bool {
        if case .task(let occurrence) = item,
           occurrences.taskCompletionIsSettling(occurrence.reminderID) {
            return false
        }
        return item.isFinished
    }

    /// The "now" the timeline is drawn against, truncated to the minute.
    ///
    /// This is load-bearing, not tidiness. `timeAnchor(Date())` published a *live* Date into a
    /// SwiftUI preference on every body evaluation, so the value differed every single pass:
    /// preference changes → onPreferenceChange writes @State → TodayView invalidates → body runs →
    /// a NEW Date() → preference differs again. A feedback loop that can never converge. On a bike
    /// ride it spun TodayView and WeatherStripe 154 times a second with the screen off, pinned a
    /// core at 100%, and iOS killed the app for it mid-episode.
    ///
    /// Truncated to the minute, the anchor is stable between renders, so the loop settles — and the
    /// timeline only needs minute resolution anyway; it's an agenda, not a stopwatch.
    private var nowAnchor: Date {
        let t = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 60).rounded(.down) * 60)
    }

    private func timelineCard(_ items: [DayItem]) -> some View {
        // All-day events head the day under their own heading: they belong to no part of it, and
        // must not move the now line or the free time between things.
        let allDay = items.filter { if case .meeting(let m) = $0 { m.isAllDay } else { false } }
        let blocks = timelineBlocks(items.filter { if case .meeting(let m) = $0 { !m.isAllDay } else { true } })
        let now = nowAnchor
        let nowIdx = blocks.firstIndex { $0.sortDate >= now } ?? blocks.count
        return VStack(spacing: 0) {
            if !allDay.isEmpty {
                dayPartHeader(nil)
                ForEach(Array(allDay.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().padding(.leading, 52) }
                    timelineRow(item)
                }
                if !blocks.isEmpty { Divider() }
            }
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                // Morning / Afternoon / Evening — the day in the parts people talk about.
                let part = DayPart.of(block.sortDate)
                let startsPart = index == 0 || DayPart.of(blocks[index - 1].sortDate) != part
                if startsPart {
                    if index > 0 { Divider() }
                    dayPartHeader(part)
                }
                if index == nowIdx { nowMarker.background(timeAnchor(now)) }
                else if index > 0 && !startsPart { Divider().padding(.leading, 52) }
                // Open time ahead, named: "45 min free".
                if index > 0, let gap = freeGap(before: block, after: blocks[index - 1], now: now) {
                    gapRow(gap)
                    Divider().padding(.leading, 52)
                }

                switch block {
                case .item(let item):
                    timelineRow(item).background(timeAnchor(item.sortDate))
                case .done(let run):
                    doneRun(run)
                }
            }
            if nowIdx >= blocks.count && !blocks.isEmpty {
                nowMarker.background(timeAnchor(now))   // whole day is in the past
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// "Morning", "Afternoon", "Evening" — or "All day" (nil).
    private func dayPartHeader(_ part: DayPart?) -> some View {
        Text(part?.rawValue ?? "All day")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// When the thing before `block` ends: a meeting's end, otherwise its time (cues, tasks and
    /// alarms are moments). A folded run ends with its last item.
    private func endOf(_ block: TimelineBlock) -> Date {
        func end(_ item: DayItem) -> Date {
            if case .meeting(let m) = item { return m.end ?? m.start.addingTimeInterval(30 * 60) }
            return item.sortDate
        }
        switch block {
        case .item(let item): return end(item)
        case .done(let run): return run.map(end).max() ?? .distantPast
        }
    }

    /// Free time before `block`, if it's still ahead and long enough to plan into.
    private func freeGap(before block: TimelineBlock, after previous: TimelineBlock, now: Date) -> String? {
        guard block.sortDate > now else { return nil }
        return TodayText.freeGap(from: max(endOf(previous), now), to: block.sortDate)
    }

    private func gapRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 30)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityLabel(text)
    }

    /// A folded run of finished items: one summary row that expands in place.
    @ViewBuilder private func doneRun(_ run: [DayItem]) -> some View {
        let key = run.first?.id ?? ""
        let expanded = expandedRuns.contains(key)

        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    if expanded { expandedRuns.remove(key) } else { expandedRuns.insert(key) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).foregroundStyle(DS.Palette.success).frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(run.count) done").font(.subheadline.weight(.semibold))
                        Text(run.map(\.title).joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(run) { item in
                    Divider().padding(.leading, 52)
                    timelineRow(item).background(timeAnchor(item.sortDate))
                }
            }
        }
        .background(timeAnchor(run.first?.sortDate ?? nowAnchor))   // fallback is dead (run non-empty) but must never be a raw Date
    }

    /// Publish where this row sits so the weather stripe can line its hours up with the actual
    /// layout — the timeline is an agenda list, so y is driven by index, not by the clock.
    ///
    /// `y` is rounded to whole points. The date half of the anchor was stabilized (nowAnchor
    /// truncates to the minute), but raw `midY` carries sub-point layout jitter — so "identical"
    /// layouts published unequal values pass after pass, the `new != timeAnchors` guard let them
    /// through, and a residual render storm survived the date fix. The stripe interpolates hours
    /// across tens of points; whole-point precision is more than it needs.
    private func timeAnchor(_ date: Date) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TimeAnchorKey.self,
                value: [TimeAnchor(time: date, y: proxy.frame(in: .named(Self.timelineSpace)).midY.rounded())]
            )
        }
    }

    @ViewBuilder private func timelineRow(_ item: DayItem) -> some View {
        switch item {
        case .cue(let moment, let occ):
            Button { sheet = .editCue(moment.routine) } label: { momentRow(moment, skipped: occ.skipped) }
                .buttonStyle(.plain)
                .contextMenu { cueMenu(moment, occ) }
        case .meeting(let meeting):
            Button { openEvent(meeting) } label: { meetingRow(meeting) }
                .buttonStyle(.plain)
        case .task(let occ):
            taskRow(occ)
        case .alarm(let occ):
            alarmRow(occ)
        }
    }

    /// A one-off alarm on the timeline. Long-press to delete it.
    private func alarmRow(_ occ: Occurrence) -> some View {
        let past = occ.start < Date()
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(DS.Palette.accent.opacity(DS.Tint.soft))
                Image(systemName: "alarm").font(.system(size: 14)).foregroundStyle(DS.Palette.accent)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(occ.title).font(.body).lineLimit(1)
                Text("Alarm").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(occ.start, format: .dateTime.hour().minute())
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .opacity(past ? 0.5 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                if let id = UUID(uuidString: String(occ.id.dropFirst("alarm:".count))) {
                    alarms.cancelOneOff(id)
                }
            } label: { Label("Delete alarm", systemImage: "trash") }
        }
    }

    /// The current-time line dividing what's past (above, dimmed) from what's upcoming.
    private var nowMarker: some View {
        HStack(spacing: 8) {
            Circle().fill(DS.Palette.accent).frame(width: 7, height: 7)
            Text("Now · \(Date().formatted(.dateTime.hour().minute()))")
                .font(.caption2.weight(.bold)).foregroundStyle(DS.Palette.accent).monospacedDigit()
            Rectangle().fill(DS.Palette.accent.opacity(0.4)).frame(height: 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func meetingRow(_ meeting: MeetingInfo) -> some View {
        // An all-day event is over when its day is, not from midnight.
        let past = (meeting.isAllDay ? (meeting.end ?? meeting.start) : meeting.start) < Date()
        return HStack(spacing: 12) {
            MeetingActionIcon(meeting: meeting)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.body).lineLimit(1)
                if let f = flightLeg(for: meeting), !past, let line = flightLine(f) {
                    Label(line, systemImage: "airplane")
                        .font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.travel).labelStyle(.titleAndIcon).lineLimit(1)
                } else if let leg = leaveBy(for: meeting), !past {
                    // The icon is the mode the time was computed for — a walking figure on a
                    // transit estimate hid exactly the kind of mismatch that makes times wrong.
                    // …and the place it was timed to, so "Chelsea?" — a guess — can't hide.
                    Label("Leave by \(leg.leaveBy.formatted(.dateTime.hour().minute())) · \(leg.detail?.summary ?? "\(leg.travelMinutes) min")",
                          systemImage: (leg.detail?.mode ?? smart.settings.transitMode).systemImage)
                        .font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.travel).labelStyle(.titleAndIcon)
                        .lineLimit(1)
                } else if let ret = returnLeg(for: meeting), (ret.end ?? ret.start) > Date() {
                    // Keyed to the return block's own window, not `past` (the meeting's start) --
                    // `past` would mask this the moment the meeting begins, which is exactly when
                    // the outbound "leave by" above stops applying and this one starts to matter.
                    let mins = Int((ret.end ?? ret.start).timeIntervalSince(ret.start) / 60)
                    Label("Leave for home by \(ret.start.formatted(.dateTime.hour().minute())) · \(ret.travel?.minutes ?? mins) min",
                          systemImage: ret.travel?.mode.systemImage ?? "house")
                        .font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.travel).labelStyle(.titleAndIcon)
                } else if meeting.isVirtual {
                    Text(meeting.platform?.label ?? "Video call").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                } else if let address = meeting.address {
                    Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if meeting.showsAsFree { FreeBadge() }
            Group {
                if meeting.isAllDay {
                    Text("All day")
                } else {
                    Text(meeting.start, format: .dateTime.hour().minute())
                }
            }
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .opacity(past ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private func openEvent(_ meeting: MeetingInfo) {
        #if os(macOS)
        MacNavigator.shared.inspectedMeeting = meeting
        #else
        if GoogleCalendarService.isGoogleEventInfoID(meeting.eventID) {
            sheet = .event(CalendarEventSheet(googleMeeting: meeting))
        }
        #endif
    }

    /// A task from Apple Reminders — tap the circle to complete it (syncs back to Reminders).
    private func taskRow(_ occ: Occurrence) -> some View {
        HStack(spacing: 12) {
            Button {
                occurrences.toggleTask(occ)
            } label: {
                Image(systemName: occ.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(DS.Palette.success)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("task.toggle.\(occ.reminderID ?? occ.id)")
            .accessibilityLabel(occ.completed ? "Mark \(occ.title) not done" : "Mark \(occ.title) done")
            .accessibilityValue(occ.completed ? "Completed" : "Incomplete")
            Button { sheet = .editTask(occ) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(occ.title).font(.body).lineLimit(1)
                            .strikethrough(occ.completed, color: .secondary)
                        Text("Reminder").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if occ.overdue {
                        Text("Overdue").font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.danger)
                    } else if occ.hasScheduledTime {
                        Text(occ.start, format: .dateTime.hour().minute())
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("Due").font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(occ.title)")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .opacity(occ.completed ? 0.5 : 1)
        .contentShape(Rectangle())
        .contextMenu { taskMenu(occ) }
    }

    private func momentRow(_ moment: DayMoment, skipped: Bool = false) -> some View {
        HStack(spacing: 12) {
            tile(moment.routine)
            VStack(alignment: .leading, spacing: 1) {
                Text(moment.routine.name)
                    .font(.body)
                    .strikethrough(moment.status == .done || skipped, color: .secondary)
                Text(skipped ? "Skipped today" : moment.routine.sourceLabel)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if skipped {
                Text("Skipped").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                trailing(for: moment)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .opacity(moment.status == .done || skipped ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func trailing(for moment: DayMoment) -> some View {
        switch moment.status {
        case .active:
            HStack(spacing: 5) {
                Circle().fill(DS.Palette.accent).frame(width: 7, height: 7)
                Text("Now").font(.caption.weight(.bold)).foregroundStyle(DS.Palette.accent)
            }
        case .done:
            Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(DS.Palette.success)
        case .manual:
            autonomyTag(.manual)
        case .upcoming:
            if let t = moment.time {
                Text(t, format: .dateTime.hour().minute()).font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("On start").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Per-occurrence exception actions (L2): skip/move just this one, add an extra, or edit
    /// the whole series.
    @ViewBuilder private func cueMenu(_ moment: DayMoment, _ occ: Occurrence) -> some View {
        if occ.id.hasPrefix("extra:") {
            Button(role: .destructive) {
                ExceptionStore.shared.removeExtra(String(occ.id.dropFirst("extra:".count)))
                Task { await occurrences.recompute() }
            } label: { Label("Remove this extra", systemImage: "trash") }
        } else if occ.occurrenceKey != nil {
            if occ.skipped {
                Button { CueSkip.restore(occ) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            } else {
                Button { CueSkip.skip(occ) } label: { Label("Skip today", systemImage: "xmark.circle") }
                Button { sheet = .move(occ) } label: { Label("Move…", systemImage: "clock.arrow.circlepath") }
            }
        }
        Button { sheet = .addExtra(moment.routine) } label: { Label("Add another…", systemImage: "plus.circle") }
        Button { sheet = .editCue(moment.routine) } label: { Label("Edit cue", systemImage: "pencil") }
    }

    private var defaultExtraTime: Date { Date().addingTimeInterval(3600) }

    /// Long-press actions on a task row.
    @ViewBuilder private func taskMenu(_ occ: Occurrence) -> some View {
        Button { sheet = .editTask(occ) } label: {
            Label("Edit reminder…", systemImage: "pencil")
        }
        Button {
            occurrences.toggleTask(occ)
        } label: {
            Label(occ.completed ? "Mark not done" : "Mark done",
                  systemImage: occ.completed ? "circle" : "checkmark.circle")
        }
        Button { sheet = .rescheduleTask(occ) } label: { Label("Reschedule…", systemImage: "clock.arrow.circlepath") }
        if let id = occ.reminderID {
            let current = TaskDurationStore.shared.minutes(for: id)
            Menu {
                ForEach(TaskDurationStore.options, id: \.self) { m in
                    Button {
                        TaskDurationStore.shared.set(id, minutes: m)
                        Task { await occurrences.recompute() }
                    } label: {
                        Label("\(m) min", systemImage: m == current ? "checkmark" : "")
                    }
                }
            } label: {
                Label("Reserve \(current) min", systemImage: "timer")
            }
        }
    }

    // MARK: - Re-plan (L4)

    /// Moveable tasks the scheduler could actually place today: incomplete tasks that are
    /// overdue or unscheduled. If there are none, Re-plan has nothing to do.
    private var replannableCount: Int {
        occurrences.occurrences(on: Date()).filter {
            $0.behavior == .task && !$0.completed && ($0.overdue || !$0.hasScheduledTime)
        }.count
    }

    private var replanButton: some View {
        let count = replannableCount
        return Button {
            sheet = .replan(occurrences.replanToday())
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars").font(.title3)
                    .foregroundStyle(count == 0 ? Color.secondary : .orange).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Re-plan my day").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(count == 0
                         ? "Nothing to fit right now"
                         : "Fit \(count) open task\(count == 1 ? "" : "s") into today's free time")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if count > 0 {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.6 : 1)
    }

    // MARK: - Plan tomorrow

    private var planTomorrowButton: some View {
        Button { sheet = .tomorrow } label: {
            HStack(spacing: 12) {
                Image(systemName: "moon.stars.fill").font(.title3).foregroundStyle(.indigo).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plan tomorrow").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(tomorrowSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var tomorrowSubtitle: String {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var parts: [String] = []
        if let wake = smart.planDay(for: tomorrow)?.wake {
            parts.append("Wake \(wake.formatted(.dateTime.hour().minute()))")
        }
        let n = smart.tomorrowMeetings.count
        parts.append(n == 0 ? "No meetings" : "\(n) meeting\(n == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    // MARK: - Scenes

    private var scenesGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(scenes) { routine in
                Button { start(routine) } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(routine.color.color)
                            Image(systemName: routine.icon).font(.system(size: 18)).foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)
                        Text(routine.name).font(.subheadline.weight(.semibold))
                        Text(routine.sourceLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions & bits

    private func start(_ routine: Routine) {
        if let next = library.nextInPool(routine.podcastIDs) {
            player.play(next.episode, in: next.podcast, routineID: routine.id)
            if let minutes = routine.sleepTimerMinutes { player.startSleepTimer(minutes: minutes) }
        } else if let item = routine.musicItem {
            Task { await music.playWake(item) }
        } else if let slot = routine.slot {
            Task {
                await WakeCoordinator.shared.play(slot: slot, reason: "cue:\(routine.name)",
                                                  sleepTimerMinutes: routine.sleepTimerMinutes,
                                                  routineID: routine.id)
            }
        }
    }

    private func tile(_ routine: Routine) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(routine.color.color)
            Image(systemName: routine.icon).font(.system(size: 15)).foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
    }

    private func autonomyTag(_ a: Autonomy) -> some View {
        Text(a.label.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(a.tint.opacity(DS.Tint.soft), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(a.tint)
    }

    /// Same look as a List section header everywhere else in the app (iOS 26's native style),
    /// so Today doesn't have its own dialect.
    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(.secondary)
            .padding(.leading, DS.Space.xs).padding(.top, DS.Space.xs)
    }
    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(DS.Palette.accent).tracking(0.6)
    }
    private func subtitle(for moment: DayMoment) -> String {
        if let t = moment.time { return "\(t.formatted(.dateTime.hour().minute())) · \(moment.routine.sourceLabel)" }
        return moment.routine.sourceLabel
    }

    private var artworkURL: URL? {
        guard let pid = player.currentPodcastID else { return nil }
        return library.podcast(pid)?.artworkURL
    }
    private var podcastName: String? {
        guard let pid = player.currentPodcastID else { return nil }
        return library.podcast(pid)?.title
    }
}

/// Creates a real event in a writable Apple Calendar destination. Unlike a task, this item owns
/// a fixed start and end and has no completion state.
struct NewCalendarEventSheet: View {
    @EnvironmentObject private var occurrences: OccurrenceStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var eventStart: Date
    @State private var eventEnd: Date
    @State private var isAllDay = false
    @State private var location = ""
    @State private var structuredLocation: CalendarEventLocation?
    @State private var videoCallLink = ""
    @State private var notes = ""
    @AppStorage("eventAuthoringAvailability") private var availability: CalendarEventAvailability = .busy
    @AppStorage("eventAuthoringAlertMinutes") private var alertMinutesBefore = 10
    @AppStorage("eventAuthoringSecondAlertMinutes") private var secondaryAlertMinutesBefore = -1
    @AppStorage("eventAuthoringLastCalendarID") private var lastCalendarID = ""
    /// Shared with the event editor (`RepeatPicker`): weekly on several days, custom, an end.
    @State private var recurrence: EventRecurrence = .none
    @State private var calendars: [CalendarSourceInfo] = []
    @State private var templates: [CalendarEventTemplate] = []
    @State private var calendarID: String?
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool
    /// Filling the form in from the words typed as the title (`EventPhrase`), and the form as it
    /// was before, for Undo.
    @State private var filling = false
    @State private var beforeFill: FilledFields?
    /// The title as Fill in left it: "Lunch with Sam" still names Sam, but that's been read.
    @State private var filledTitle: String?
    /// An end set together with a new start (Fill in, Undo): kept when the start's change lands,
    /// instead of being shifted along with it.
    @State private var pendingEnd: Date?
    /// Who it's with. Google emails each an invitation when the event is saved.
    @State private var guests: [GuestPerson] = []
    @State private var guestQuery = ""
    /// Everyone it could be with (`GuestSources`), favourites first when matched.
    @State private var people: [GuestPerson] = []
    /// Names typed that fit more than one person — "Which Sam?" — or no one.
    @State private var askingWhich: [GuestQuestion] = []
    /// The words each guest was chosen for, remembered on Save (`GuestPicks`).
    @State private var chosenFor: [String: String] = [:]

    private struct FilledFields {
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String
        var structuredLocation: CalendarEventLocation?
        var recurrence: EventRecurrence
        var guests: [GuestPerson]
        var askingWhich: [GuestQuestion]
    }

    struct GuestQuestion: Identifiable, Equatable {
        var name: String
        var options: [GuestPerson]
        var id: String { name }
    }

    init(initialStart: Date = Date().addingTimeInterval(3_600), initialDurationMinutes: Int? = nil,
         initialTitle: String = "") {
        _title = State(initialValue: initialTitle)
        let remembered = UserDefaults.standard.integer(forKey: "eventAuthoringDurationMinutes")
        let duration = initialDurationMinutes ?? (remembered > 0 ? remembered : 60)
        // A new event has no owner-authored time to preserve — unlike editing an existing one,
        // there's nothing to silently move. Seed the grid the picker steps on, so a plain "+"
        // (no grid tap behind it) doesn't default to an arbitrary minute like 14:37.
        let start = FiveMinuteGrid.snapped(initialStart)
        _eventStart = State(initialValue: start)
        _eventEnd = State(initialValue: start.addingTimeInterval(
            TimeInterval(max(15, duration) * 60)))
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedStart: Date {
        guard isAllDay else { return eventStart }
        return Calendar.current.startOfDay(for: eventStart)
    }

    private var normalizedEnd: Date {
        guard isAllDay else { return eventEnd }
        let calendar = Calendar.current
        let inclusiveEndDay = calendar.startOfDay(for: max(eventStart, eventEnd))
        return calendar.date(byAdding: .day, value: 1, to: inclusiveEndDay) ?? inclusiveEndDay
    }

    private var cleanVideoCallURL: URL? {
        let value = videoCallLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              components.host?.isEmpty == false else { return nil }
        return components.url
    }

    private var videoCallLinkIsValid: Bool {
        videoCallLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || cleanVideoCallURL != nil
    }

    private var timeRangeIsValid: Bool { normalizedEnd > normalizedStart }

    private var conflicts: [Occurrence] {
        schedulingConflicts(
            in: occurrences,
            from: normalizedStart,
            to: normalizedEnd
        )
    }

    private var input: CalendarEventInput {
        // Weekly on days that don't include the start's: begin on the first of them — a series'
        // start always counts as an occurrence.
        let shift = recurrence.repeatValue?.alignedStart(normalizedStart)
            .map { $0.timeIntervalSince(normalizedStart) } ?? 0
        return CalendarEventInput(
            title: cleanTitle,
            start: normalizedStart.addingTimeInterval(shift),
            end: normalizedEnd.addingTimeInterval(shift),
            isAllDay: isAllDay,
            location: location,
            notes: notes,
            url: cleanVideoCallURL,
            availability: availability,
            alertMinutesBefore: alertMinutesBefore < 0 ? nil : alertMinutesBefore,
            structuredLocation: structuredLocation,
            secondaryAlertMinutesBefore: secondaryAlertMinutesBefore < 0
                ? nil : secondaryAlertMinutesBefore,
            // The whole rule, end included: set here rather than by deleting later, since cutting
            // a series short has to reach every copy of the calendar.
            recurrenceRules: recurrence.repeatValue.map { [$0.rule(isAllDay: isAllDay)] },
            attendees: guests.isEmpty ? nil : guests.map(\.email))
    }

    private var selectedCalendar: CalendarSourceInfo? {
        calendars.first { $0.id == calendarID }
    }

    private var matchingTemplates: [CalendarEventTemplate] {
        let query = cleanTitle
        guard query.count >= 2 else { return [] }
        return Array(templates.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                && $0.title.caseInsensitiveCompare(query) != .orderedSame
        }.prefix(3))
    }

    var body: some View {
        NavigationStack {
            eventForm
                .navigationTitle("New calendar event")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveTitle) { save() }
                            .disabled(cleanTitle.isEmpty || !timeRangeIsValid || !videoCallLinkIsValid || saving)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("event.save")
                    }
                    #endif
                }
                #if os(macOS)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.bordered)
                        Button(saveTitle) { save() }
                            .buttonStyle(.borderedProminent)
                            .tint(DS.Palette.accent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(cleanTitle.isEmpty || !timeRangeIsValid || !videoCallLinkIsValid || saving)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
                #endif
                .interactiveDismissDisabled(saving)
                .alert("Couldn’t create event", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
        #if os(macOS)
        .frame(width: 620, height: 680)
        #else
        .presentationDetents([.large])
        #endif
        .task {
            await GoogleCalendarService.shared.restoreIfNeeded()
            calendars = occurrences.writableEventCalendars
            if calendarID == nil {
                calendarID = calendars.first(where: { $0.id == lastCalendarID })?.id
                    ?? calendars.first(where: \.isDefault)?.id
                    ?? calendars.first?.id
            }
            titleFocused = true
            templates = await occurrences.eventAuthoringTemplates()
            people = await GuestSources.people()
            #if DEBUG
            // `--new-calendar-event-fill`: the typed words filled in on open, to look at the result.
            if CommandLine.arguments.contains("--new-calendar-event-fill"), phraseDraft != nil { await fillIn() }
            #endif
        }
    }

    /// What the title's words say beyond a title — a time, a place, a repeat — when they do.
    private var phraseDraft: EventPhrase.Draft? {
        guard cleanTitle.count >= 4, cleanTitle != filledTitle else { return nil }
        let draft = EventPhrase.parse(cleanTitle, defaultDuration: max(15 * 60, eventEnd.timeIntervalSince(eventStart)))
        return draft.saysMore ? draft : nil
    }

    /// "Sat, Oct 4 · 1:00–2:00 PM · Balthazar" with Fill in; once filled, Undo.
    @ViewBuilder private var phraseRow: some View {
        if let draft = phraseDraft {
            Button { Task { await fillIn() } } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "wand.and.stars").foregroundStyle(DS.Palette.accent)
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(EventPhrase.preview(draft)).font(.subheadline).foregroundStyle(.primary)
                        if !draft.title.isEmpty {
                            Text("\u{201C}\(draft.title)\u{201D}").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: DS.Space.s)
                    if filling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Fill in").font(.subheadline.weight(.semibold)).foregroundStyle(DS.Palette.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(filling)
            .accessibilityIdentifier("event.fillIn")
        } else if beforeFill != nil {
            HStack {
                Label("Filled in from your words", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo", action: undoFill)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("event.fillIn.undo")
            }
        }
    }

    /// The form filled in from the title's words: the model says which words are which when
    /// there's one here, the dates are read by the system (`EventPhrase.read`).
    @MainActor private func fillIn() async {
        guard !filling else { return }
        filling = true
        defer { filling = false }
        let length = max(15 * 60, eventEnd.timeIntervalSince(eventStart))
        let draft = await EventPhrase.read(cleanTitle, defaultDuration: length)
        beforeFill = FilledFields(title: title, start: eventStart, end: eventEnd, isAllDay: isAllDay, location: location,
                                  structuredLocation: structuredLocation, recurrence: recurrence, guests: guests,
                                  askingWhich: askingWhich)
        if !draft.title.isEmpty { title = draft.title }
        if let start = draft.start {
            isAllDay = draft.isAllDay
            // All-day here ends on its last day, not the morning after.
            setTimes(start, draft.isAllDay ? start : (draft.end ?? start.addingTimeInterval(length)))
        }
        if let place = draft.location {
            location = place
            structuredLocation = nil
        }
        if let repeating = draft.recurrence { recurrence = repeating }
        filledTitle = cleanTitle
        await addGuests(named: draft.guests)
    }

    /// Who the names are: the one picked before for that name, else the only fit, else a favourite
    /// clearly ahead of the rest (`GuestDirectory.best`). Anyone unclear is asked about.
    @MainActor private func addGuests(named names: [String]) async {
        guard !names.isEmpty else { return }
        if names.contains(where: { !$0.contains("@") }) {
            // Names to match: the first time, contacts are asked for — here, where it's clear why.
            let had = GuestSources.contactsAllowed
            let allowed = await GuestSources.requestContactsIfNeeded()
            if people.isEmpty || (allowed && !had) { people = await GuestSources.people() }
        }
        for name in names {
            let picks = GuestPicks.picks(for: name)
            if let person = GuestDirectory.best(name, in: people, picks: picks) {
                addGuest(person, for: name)
            } else {
                askingWhich.removeAll { $0.name == name }
                askingWhich.append(GuestQuestion(name: name,
                                                 options: Array(GuestDirectory.matches(name, in: people, picks: picks).prefix(4))))
            }
        }
    }

    private func addGuest(_ person: GuestPerson, for name: String?) {
        if !guests.contains(where: { $0.email == person.email }) { guests.append(person) }
        if let name, !name.contains("@") { chosenFor[person.email] = name }
        askingWhich.removeAll { $0.name == name }
    }

    private var saveTitle: String { guests.isEmpty ? "Save" : "Save & Invite" }

    private var guestSuggestions: [GuestPerson] {
        let query = guestQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let chosen = Set(guests.map(\.email))
        return Array(GuestDirectory.matches(query, in: people, picks: GuestPicks.picks(for: query))
            .filter { !chosen.contains($0.email) }.prefix(4))
    }

    /// Who it's with: the guests, "Which Sam?" for a name that fits several, and a field that
    /// finds people by name — the ones you meet most first — or takes an address.
    private var guestsSection: some View {
        Section {
            ForEach(guests) { person in
                HStack(spacing: DS.Space.m) {
                    GuestAvatar(person: person)
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(person.displayName)
                        if person.name != nil {
                            Text(person.email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { guests.removeAll { $0.email == person.email }; chosenFor[person.email] = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(person.displayName)")
                }
                .accessibilityIdentifier("event.guest")
            }
            ForEach(askingWhich) { question in
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(question.options.isEmpty
                         ? "No one called \u{201C}\(question.name)\u{201D} in your calendars or contacts \u{2014} add them by email below."
                         : "Which \(question.name)?")
                        .font(.subheadline)
                    ForEach(question.options) { person in
                        Button { addGuest(person, for: question.name) } label: {
                            HStack(spacing: DS.Space.s) {
                                GuestAvatar(person: person)
                                VStack(alignment: .leading, spacing: DS.Space.hair) {
                                    Text(person.displayName).foregroundStyle(.primary)
                                    Text(person.email).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("event.guest.option")
                    }
                }
            }
            TextField("Add a guest \u{2014} name or email", text: $guestQuery)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .autocorrectionDisabled()
                .onSubmit(addTypedGuest)
                .onChange(of: guestQuery) { _, query in
                    guard !query.isEmpty, people.isEmpty || !GuestSources.contactsAllowed else { return }
                    Task {
                        _ = await GuestSources.requestContactsIfNeeded()
                        people = await GuestSources.people()
                    }
                }
                .accessibilityIdentifier("event.guestField")
            ForEach(guestSuggestions) { person in
                Button {
                    addGuest(person, for: guestQuery)
                    guestQuery = ""
                } label: {
                    HStack(spacing: DS.Space.s) {
                        GuestAvatar(person: person)
                        VStack(alignment: .leading, spacing: DS.Space.hair) {
                            Text(person.displayName).foregroundStyle(.primary)
                            Text(person.isFavorite ? "\(person.email) \u{00B7} you meet often" : person.email)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("event.guest.suggestion")
            }
        } header: {
            Text("Guests")
        } footer: {
            Text(guests.isEmpty
                 ? "People you meet most come first."
                 : "Google emails each guest an invitation when you save.")
        }
    }

    /// Return in the guest field: the best match, or the address typed.
    private func addTypedGuest() {
        let query = guestQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let person = guestSuggestions.first ?? GuestDirectory.best(query, in: people) {
            addGuest(person, for: query)
            guestQuery = ""
        }
    }

    /// A start and an end together. Moving the start alone carries the end along (the handler on
    /// `eventStart`); here the end is the one given.
    private func setTimes(_ start: Date, _ end: Date) {
        if start != eventStart { pendingEnd = end }
        eventStart = start
        eventEnd = end
    }

    private func undoFill() {
        guard let before = beforeFill else { return }
        title = before.title
        isAllDay = before.isAllDay
        setTimes(before.start, before.end)
        location = before.location
        structuredLocation = before.structuredLocation
        recurrence = before.recurrence
        guests = before.guests
        askingWhich = before.askingWhich
        beforeFill = nil
        filledTitle = nil
    }

    private var eventForm: some View {
        Form {
            Section {
                TextField("What’s happening?", text: $title)
                    .font(.headline)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { if phraseDraft != nil { Task { await fillIn() } } }
                    .accessibilityIdentifier("event.title")
                phraseRow
                ForEach(matchingTemplates) { template in
                    Button {
                        apply(template)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(DS.Palette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(template.title).foregroundStyle(.primary)
                                Text(templateSubtitle(template))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let selectedCalendar {
                    NavigationLink {
                        CalendarDestinationPicker(
                            calendars: calendars,
                            selection: $calendarID
                        )
                    } label: {
                        HStack {
                            Text("Calendar")
                            Spacer()
                            Circle()
                                .fill(calendarTint(SmartScheduleStore.shared.shownColor(selectedCalendar.id, google: selectedCalendar.colorHex)))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(selectedCalendar.title)
                                    .foregroundStyle(.primary)
                                Text(selectedCalendar.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("event.calendar.destination")
                } else {
                    LabeledContent("Calendar") {
                        Text("Default")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Event")
            } footer: {
                if cleanTitle.isEmpty {
                    Text("Type it the way you\u{2019}d say it \u{2014} \u{201C}Lunch with Sam Friday 1pm at Balthazar\u{201D} \u{2014} and Banana fills in the rest for you to check.")
                }
            }

            Section("When") {
                Toggle("All-day", isOn: $isAllDay)
                if isAllDay {
                    DatePicker("Starts", selection: $eventStart, displayedComponents: .date)
                    DatePicker("Ends", selection: $eventEnd, displayedComponents: .date)
                } else {
                    #if os(iOS)
                    LabeledContent("Starts") {
                        FiveMinuteTimeWheel(selection: $eventStart, mode: .fullDate, style: .compact)
                    }
                    LabeledContent("Ends") {
                        FiveMinuteTimeWheel(selection: $eventEnd, mode: .fullDate, style: .compact)
                    }
                    #else
                    DatePicker("Starts", selection: $eventStart, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $eventEnd, displayedComponents: [.date, .hourAndMinute])
                    #endif
                    HStack(spacing: 8) {
                        Text("Quick duration")
                        Spacer()
                        ForEach([30, 45, 60, 120], id: \.self) { minutes in
                            Button(durationLabel(minutes)) {
                                eventEnd = eventStart.addingTimeInterval(TimeInterval(minutes * 60))
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
                if !timeRangeIsValid {
                    Text("The event must end after it starts.")
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.danger)
                }
            }

            if !conflicts.isEmpty {
                AuthoringConflictSection(conflicts: conflicts)
            }

            Section("Where") {
                EventLocationField(
                    location: $location,
                    structuredLocation: $structuredLocation
                )
                TextField("Video call link", text: $videoCallLink)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("event.videoLink")
                if !videoCallLinkIsValid {
                    Text("Enter a valid web address, such as meet.google.com/…")
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.danger)
                }
            }

            guestsSection

            Section("Scheduling") {
                Picker("Show as", selection: $availability) {
                    ForEach(CalendarEventAvailability.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .accessibilityIdentifier("event.availability")
                Picker("Alert", selection: $alertMinutesBefore) {
                    Text("None").tag(-1)
                    Text("At start").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                }
                .accessibilityIdentifier("event.alert")
                Picker("Second alert", selection: $secondaryAlertMinutesBefore) {
                    Text("None").tag(-1)
                    Text("At start").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                    Text("1 day before").tag(1_440)
                }
                .accessibilityIdentifier("event.secondAlert")
                RepeatPicker(recurrence: $recurrence, start: normalizedStart, isAllDay: isAllDay)
                Text("Save this event here, then add invitees in Google Calendar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 86)
                    .accessibilityIdentifier("event.notes")
            }

            Section {
                Text("Banana saves directly to the selected Google calendar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .onChange(of: eventStart) { oldStart, newStart in
            if let pendingEnd {
                eventEnd = pendingEnd
                self.pendingEnd = nil
                return
            }
            guard !isAllDay else { return }
            let oldDuration = max(15 * 60, eventEnd.timeIntervalSince(oldStart))
            eventEnd = newStart.addingTimeInterval(oldDuration)
        }
        .onChange(of: isAllDay) {
            if isAllDay {
                eventEnd = eventStart
            } else if eventEnd <= eventStart {
                eventEnd = eventStart.addingTimeInterval(3_600)
            }
        }
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes == 60 { return "1h" }
        return "\(minutes / 60)h"
    }

    private func templateSubtitle(_ template: CalendarEventTemplate) -> String {
        var parts = [durationLabel(template.durationMinutes)]
        if let location = template.location, !location.isEmpty { parts.append(location) }
        if template.useCount > 1 { parts.append("used \(template.useCount)×") }
        return parts.joined(separator: " · ")
    }

    private func apply(_ template: CalendarEventTemplate) {
        title = template.title
        eventEnd = eventStart.addingTimeInterval(TimeInterval(template.durationMinutes * 60))
        location = template.location ?? ""
        structuredLocation = template.structuredLocation
        if calendars.contains(where: { $0.id == template.calendarID }) {
            calendarID = template.calendarID
        }
    }

    private func save() {
        guard !cleanTitle.isEmpty, timeRangeIsValid, videoCallLinkIsValid else { return }
        saving = true
        // The event is recorded and drawn before the write finishes, so this closes at once
        // instead of holding the sheet open through a network round trip. A failure surfaces on
        // the event itself, on the grid, where it can be retried — not in a sheet that has gone.
        occurrences.createCalendarEventOptimistically(input: input, calendarID: calendarID)
        // Who each name meant, so the next "Sam" is this one without asking.
        for (email, name) in chosenFor where guests.contains(where: { $0.email == email }) {
            GuestPicks.record(name: name, email: email)
        }
        Task {
            do {
                if let calendarID {
                    lastCalendarID = calendarID
                }
                if !isAllDay {
                    UserDefaults.standard.set(
                        max(15, Int(eventEnd.timeIntervalSince(eventStart) / 60)),
                        forKey: "eventAuthoringDurationMinutes"
                    )
                }
                dismiss()
            }
        }
    }

}

struct CalendarDestinationPicker: View {
    let calendars: [CalendarSourceInfo]
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss

    private struct Account: Identifiable {
        let id: String
        let title: String
        let calendars: [CalendarSourceInfo]
    }

    private var accounts: [Account] {
        Dictionary(grouping: calendars, by: \.sourceID)
            .map { sourceID, calendars in
                let sourceTitle = calendars.first?.sourceTitle ?? ""
                return Account(
                    id: sourceID,
                    title: sourceTitle.isEmpty ? "On My Device" : sourceTitle,
                    calendars: calendars.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                )
            }
            .sorted {
                if $0.title != $1.title {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    var body: some View {
        List {
            ForEach(accounts) { account in
                Section(account.title) {
                    ForEach(account.calendars) { calendar in
                        Button {
                            selection = calendar.id
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(calendarTint(SmartScheduleStore.shared.shownColor(calendar.id, google: calendar.colorHex)))
                                    .frame(width: 12, height: 12)
                                Text(calendar.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selection == calendar.id {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(DS.Palette.accent)
                                }
                            }
                        }
                        .accessibilityLabel("\(calendar.title), \(account.title)")
                    }
                }
            }

            Section {
                Text("Manage Apple accounts in Calendar settings and direct Google accounts in Banana settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shared: the week grids colour event blocks by their source calendar with this too.
/// A calendar's colour, evened out for the current appearance (see `CalendarColor`). A calendar
/// with no colour is neutral grey — never the brand accent, which means "Banana", not "unknown".
func calendarTint(_ hex: String?) -> Color {
    CalendarColor.color(hex: hex) ?? Color.secondary
}

/// Uses the already-materialized timeline for an immediate conflict preview. It intentionally
/// performs no EventKit or network fetch while the user edits dates, so scrolling a picker stays
/// cheap and the preview cannot turn into a background battery drain.
/// Conflicts for a proposed span.
///
/// Takes the store so it can use the `byDay` index rather than the whole horizon. This is called
/// from a computed property in the authoring sheets, so it re-runs on every render while someone
/// is spinning a time picker — scanning all 31 days each time to look at one. A span can only
/// conflict with the days it touches.
@MainActor
private func schedulingConflicts(
    in store: OccurrenceStore,
    from start: Date,
    to end: Date,
    calendar cal: Calendar = .current
) -> [Occurrence] {
    guard end > start else { return [] }
    var candidates = store.occurrences(on: start)
    let endDay = cal.startOfDay(for: end)
    if endDay != cal.startOfDay(for: start) {
        candidates += store.occurrences(on: end)   // a span crossing midnight touches two
    }
    return schedulingConflicts(in: candidates, from: start, to: end)
}

private func schedulingConflicts(
    in occurrences: [Occurrence],
    from start: Date,
    to end: Date
) -> [Occurrence] {
    guard end > start else { return [] }
    return occurrences.filter { occurrence in
        // A day blocked all day is in the way of anything that day.
        guard occurrence.hasScheduledTime || occurrence.blocksWholeDay,
              !occurrence.skipped,
              !occurrence.completed else { return false }
        let blocksTime: Bool
        switch occurrence.behavior {
        case .event:
            blocksTime = true
        case .allDay:
            blocksTime = occurrence.blocksWholeDay
        case .block:
            blocksTime = occurrence.writePolicy == .busy
        case .task:
            blocksTime = !occurrence.overdue
        case .cue:
            blocksTime = occurrence.schedule.moveable
        case .alarm:
            blocksTime = false
        }
        let occurrenceEnd: Date
        if occurrence.behavior == .cue,
           let duration = occurrence.schedule.constraints?.duration {
            occurrenceEnd = occurrence.start.addingTimeInterval(duration)
        } else {
            occurrenceEnd = occurrence.resolvedEnd
        }
        return blocksTime && occurrence.start < end && occurrenceEnd > start
    }
    .sorted { $0.start < $1.start }
}

private struct AuthoringConflictSection: View {
    let conflicts: [Occurrence]

    var body: some View {
        Section {
            Label(
                "Conflicts with \(conflicts.count) \(conflicts.count == 1 ? "item" : "items")",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(DS.Palette.accent)
            ForEach(Array(conflicts.prefix(3))) { conflict in
                HStack {
                    Text(conflict.title).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(conflict.start, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.footnote)
            }
            if conflicts.count > 3 {
                Text("And \(conflicts.count - 3) more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("You can still save; this is a warning, not a blocker.")
        }
    }
}

/// Creates the task where Banana already reads tasks: the person's default Apple Reminders list.
/// A time makes it immediately eligible for calendar write-back; a day-only task stays available
/// to Re-plan without inventing a second task store.
struct NewTaskSheet: View {
    @EnvironmentObject private var occurrences: OccurrenceStore
    @EnvironmentObject private var smart: SmartScheduleStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var hasTime = true
    @State private var day: Date
    @State private var time: Date
    @AppStorage("taskAuthoringDurationMinutes")
    private var durationMinutes = TaskDurationStore.defaultMinutes
    @State private var notes = ""
    @State private var priority = 0
    @State private var recurrence: CalendarItemRecurrence = .never
    /// Due around a moment rather than only at its time — after your workout (`ReminderAnchors`).
    @State private var anchor: TimingAnchor?
    @State private var recurrenceHasEnd = false
    @State private var recurrenceEnd = Date()
    @State private var lists: [RemindersService.ReminderListInfo] = []
    @State private var listID: String?
    @AppStorage("taskAuthoringLastListID") private var lastListID = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var loading = false
    @FocusState private var titleFocused: Bool
    private let reminderID: String?

    /// `initialDue` lets a caller that already knows the time — the week grid's "new reminder
    /// here" — open the sheet on that slot instead of an hour from now.
    init(reminderID: String? = nil, initialDue: Date? = nil) {
        self.reminderID = reminderID
        // An hour from now lands on an arbitrary minute (14:37). Seed the grid the picker
        // steps on, so the default offered is 15:00 and not something only typing could reach.
        let initial = FiveMinuteGrid.snapped(
            initialDue ?? Date().addingTimeInterval(3_600))
        _day = State(initialValue: initial)
        _time = State(initialValue: initial)
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var due: Date {
        let calendar = Calendar.current
        guard hasTime else { return calendar.startOfDay(for: day) }
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        let exact = calendar.date(
            bySettingHour: clock.hour ?? 9,
            minute: clock.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
        // The five-minute grid is the product rule, not just the iOS picker's step: the Mac
        // still uses a plain minute picker, and an off-grid due date can arrive from a
        // reminder authored in Apple Reminders.
        return FiveMinuteGrid.snapped(exact)
    }

    private var selectedList: RemindersService.ReminderListInfo? {
        lists.first { $0.id == listID }
    }

    private var conflicts: [Occurrence] {
        guard hasTime else { return [] }
        return schedulingConflicts(
            in: occurrences,
            from: due,
            to: due.addingTimeInterval(TimeInterval(durationMinutes * 60))
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing?", text: $title)
                        .focused($titleFocused)
                        .accessibilityIdentifier("task.title")
                    if let selectedList {
                        NavigationLink {
                            ReminderDestinationPicker(lists: lists, selection: $listID)
                        } label: {
                            LabeledContent("List") {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(selectedList.title).foregroundStyle(.primary)
                                    Text(selectedList.sourceTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("task.list.destination")
                    } else {
                        LabeledContent("List") {
                            Text("Default").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Task")
                }

                Section {
                    Toggle("Schedule a time", isOn: $hasTime)
                        .tint(DS.Palette.accent)
                    if reminderID == nil {
                        DatePicker(
                            "Date",
                            selection: $day,
                            in: Calendar.current.startOfDay(for: Date())...,
                            displayedComponents: .date
                        )
                    } else {
                        DatePicker("Date", selection: $day, displayedComponents: .date)
                    }
                    if hasTime {
                        #if os(iOS)
                        LabeledContent("Time") {
                            FiveMinuteTimeWheel(selection: $time, mode: .hourAndMinuteOnly, style: .compact)
                        }
                        #else
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        #endif
                    }
                    Picker("Reserve", selection: $durationMinutes) {
                        ForEach(TaskDurationStore.options, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .accessibilityIdentifier("task.duration")
                    Picker("Priority", selection: $priority) {
                        Text("None").tag(0)
                        Text("High").tag(1)
                        Text("Medium").tag(5)
                        Text("Low").tag(9)
                    }
                    .accessibilityIdentifier("task.priority")
                    Picker("Repeat", selection: $recurrence) {
                        ForEach(CalendarItemRecurrence.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .accessibilityIdentifier("task.recurrence")
                } header: {
                    Text("When")
                } footer: {
                    Text(
                        hasTime
                            ? (smart.settings.reserveTaskTime
                                ? "Saved to Apple Reminders. Banana reserves every timed occurrence in your calendar by default."
                                : "Saved to Apple Reminders. Shows on your Banana timeline only — calendar reservations for tasks are off in Settings.")
                            : "Saved to Apple Reminders without a time. Use Re-plan my day when you want Banana to find it a slot."
                    )
                }

                if recurrence != .never {
                    Section {
                        TimingFields(anchor: $anchor, time: $time, others: anchorChoices, showsOwnTime: false)
                    } header: {
                        Text("Due around")
                    } footer: {
                        Text(anchor == nil
                             ? "Tie it to a moment \u{2014} after your workout, before breakfast \u{2014} and it\u{2019}s due then, not late before."
                             : "Its time above is when it\u{2019}s due on days the moment doesn\u{2019}t come. Banana moves it in Reminders on the day.")
                    }
                }

                if !conflicts.isEmpty {
                    AuthoringConflictSection(conflicts: conflicts)
                }


                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 72)
                        .accessibilityIdentifier("task.notes")
                }
            }
            .navigationTitle(reminderID == nil ? "New task" : "Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(cleanTitle.isEmpty || saving || loading)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .interactiveDismissDisabled(saving)
            .alert(reminderID == nil ? "Couldn’t create task" : "Couldn’t save reminder", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                lists = occurrences.writableReminderLists
                if let reminderID {
                    loading = true
                    if let draft = occurrences.editableTask(reminderID) {
                        title = draft.title
                        notes = draft.notes
                        hasTime = draft.hasTime
                        day = draft.due
                        time = FiveMinuteGrid.snapped(draft.due)
                        priority = draft.priority
                        recurrence = draft.recurrence
                        anchor = ReminderAnchors.shared.anchor(externalID: externalID(of: reminderID), title: draft.title)
                        // Tied, today's due may have moved to its moment: the time shown is its own.
                        if anchor != nil, let usual = ReminderAnchors.shared.usualMinutes(
                            externalID: externalID(of: reminderID), title: draft.title),
                           let own = Calendar.current.date(bySettingHour: usual / 60, minute: usual % 60, second: 0, of: draft.due) {
                            time = own
                        }
                        durationMinutes = TaskDurationStore.shared.minutes(for: reminderID)
                        listID = lists.first(where: { $0.id == draft.listID })?.id
                            ?? lists.first(where: \.isDefault)?.id
                            ?? lists.first?.id
                    } else {
                        errorMessage = "This reminder no longer exists."
                    }
                    loading = false
                } else {
                    listID = lists.first(where: { $0.id == lastListID })?.id
                        ?? lists.first(where: \.isDefault)?.id
                        ?? lists.first?.id
                    titleFocused = true
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !cleanTitle.isEmpty else { return }
        saving = true
        Task {
            do {
                if let reminderID {
                    try await occurrences.updateTask(
                        reminderID: reminderID,
                        title: cleanTitle,
                        due: due,
                        hasTime: hasTime,
                        durationMinutes: durationMinutes,
                        listID: listID,
                        notes: notes,
                        priority: priority,
                        recurrence: recurrence
                    )
                } else {
                    try await occurrences.createTask(
                        title: cleanTitle,
                        due: due,
                        hasTime: hasTime,
                        durationMinutes: durationMinutes,
                        listID: listID,
                        notes: notes,
                        priority: priority,
                        recurrence: recurrence
                    )
                }
                if let listID { lastListID = listID }
                saveAnchor()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }
}

extension NewTaskSheet {
    /// What a reminder could be due around besides the usual moments: other repeating reminders,
    /// and Taken items.
    var anchorChoices: [TimingAnchor.Moment] {
        var seen = Set<String>()
        let reminders = occurrences.occurrences
            .filter { $0.behavior == .task && $0.reminderID != reminderID && $0.title.lowercased() != cleanTitle.lowercased() }
            .compactMap { occurrence -> TimingAnchor.Moment? in
                guard seen.insert(occurrence.title.lowercased()).inserted else { return nil }
                return .reminder(id: occurrence.reminderExternalID ?? occurrence.title, title: occurrence.title)
            }
        return reminders + AnchoredTimingHub.otherMoments(excluding: nil, supplements: WellnessStore.shared.supplements)
    }

    func externalID(of reminderID: String) -> String? {
        occurrences.occurrences.first { $0.reminderID == reminderID }?.reminderExternalID
    }

    /// Ties it (or unties it) in `ReminderAnchors`, with its time of day as what it's due at otherwise.
    func saveAnchor() {
        let rules = ReminderAnchors.shared
        let external = reminderID.flatMap(externalID(of:))
        let had = rules.anchor(externalID: external, title: cleanTitle) != nil
        guard anchor != nil || had else { return }
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        rules.set(recurrence == .never ? nil : anchor, externalID: external, title: cleanTitle,
                  usualMinutes: hasTime ? (clock.hour ?? 20) * 60 + (clock.minute ?? 0) : nil)
    }
}

private struct ReminderDestinationPicker: View {
    let lists: [RemindersService.ReminderListInfo]
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss

    private struct Account: Identifiable {
        let id: String
        let title: String
        let lists: [RemindersService.ReminderListInfo]
    }

    private var accounts: [Account] {
        Dictionary(grouping: lists, by: \.sourceID)
            .map { sourceID, lists in
                Account(
                    id: sourceID,
                    title: lists.first?.sourceTitle.isEmpty == false
                        ? lists.first!.sourceTitle : "On My Device",
                    lists: lists.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                )
            }
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    var body: some View {
        List {
            ForEach(accounts) { account in
                Section(account.title) {
                    ForEach(account.lists) { list in
                        Button {
                            selection = list.id
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(DS.Palette.accent)
                                Text(list.title).foregroundStyle(.primary)
                                Spacer()
                                if selection == list.id {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(DS.Palette.accent)
                                }
                            }
                        }
                        .accessibilityLabel("\(list.title), \(account.title)")
                    }
                }
            }
        }
        .navigationTitle("Reminders list")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Preview of a "Re-plan my day" — proposed placements + anything that couldn't fit. Apply
/// writes the new times back to Reminders (never drops a task).
private struct ReplanSheet: View {
    let result: Scheduler.Result
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// The two ways nothing fits are completely different problems.
    private var whyUnplaced: String {
        guard let window = result.window else {
            return "There's no day left to plan into — it's past your bedtime, so the window has "
                 + "already closed. Plan tomorrow instead."
        }
        let from = window.start.formatted(.dateTime.hour().minute())
        let to = window.end.formatted(.dateTime.hour().minute())
        if result.busy.isEmpty {
            return "No open slot between \(from) and \(to). Left where they are, not dropped."
        }
        return "No gap long enough between \(from) and \(to) — \(result.busy.count) "
             + "\(result.busy.count == 1 ? "thing is" : "things are") already booked in it. "
             + "Left where they are, not dropped."
    }

    var body: some View {
        NavigationStack {
            List {
                if !result.placements.isEmpty {
                    Section {
                        ForEach(result.placements) { p in
                            HStack {
                                Image(systemName: "checklist").foregroundStyle(DS.Palette.task)
                                Text(p.occurrence.title).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(p.start, format: .dateTime.hour().minute())
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    } header: { Text("Proposed") } footer: { Text("Each task's reminder gets its new time.") }
                }
                if !result.unplaced.isEmpty {
                    Section {
                        ForEach(result.unplaced) { occ in
                            Label(occ.title, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        }
                    } header: { Text("Couldn't place (\(result.unplaced.count))") }
                    footer: { Text(whyUnplaced) }

                    // "Couldn't place" on its own is an assertion you can't check — a genuinely
                    // full day and a window that shut an hour ago look identical, and they want
                    // opposite things from you. So show the working.
                    if !result.busy.isEmpty {
                        Section("What's in the way") {
                            ForEach(Array(result.busy.enumerated()), id: \.offset) { _, block in
                                HStack {
                                    Text(block.title).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("\(block.start, format: .dateTime.hour().minute())–\(block.end, format: .dateTime.hour().minute())")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.footnote)
                            }
                        }
                    }
                }
                // Anything dropped from the pool gets named. "Nothing to schedule — your open
                // tasks are all set" was a lie whenever the workout had been quietly excluded:
                // the screen asserted all was well while the cue sat stranded on the timeline.
                if !result.excluded.isEmpty {
                    Section("Not scheduled") {
                        ForEach(Array(result.excluded.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                                Text(item.title)
                                Spacer(minLength: 8)
                                Text(item.reason).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if result.placements.isEmpty && result.unplaced.isEmpty && result.excluded.isEmpty {
                    Text("Nothing to schedule — your open tasks are all set.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Re-plan today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(); dismiss() }.disabled(result.placements.isEmpty)
                }
            }
        }
    }
}

/// A small date+time picker sheet for moving an occurrence or scheduling an extra.
struct OccurrenceTimeSheet: View {
    let title: String
    let onSave: (Date) -> Void
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: Date, onSave: @escaping (Date) -> Void) {
        self.title = title
        self.onSave = onSave
        _date = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    // Time first: rescheduling is usually "same day, different time".
                    #if os(iOS)
                    FiveMinuteTimeWheel(selection: $date, mode: .hourAndMinuteOnly)
                        .frame(height: 190)
                    #else
                    DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                        .padding(.horizontal)
                    #endif
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding(.horizontal)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(date); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}

/// A guest's initial in a circle, starred for someone you meet often.
struct GuestAvatar: View {
    let person: GuestPerson

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.primary.opacity(DS.Tint.soft))
                .frame(width: 30, height: 30)
                .overlay(Text(String(person.displayName.prefix(1)).uppercased()).font(.footnote.weight(.semibold)))
            if person.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Palette.accent)
                    .offset(x: 2, y: 2)
                    .accessibilityLabel("You meet often")
            }
        }
    }
}
