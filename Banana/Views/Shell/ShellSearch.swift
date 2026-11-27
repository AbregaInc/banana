import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

// "Search or ask": the one field of the navigation layer (docs/design/BOTTOM-BAR-SHELL.md). Its
// results come from the searches the pages already had — the plan's timeline, Mail's index (the
// same `observeList` a Mail search uses) and Notes' repository — and nothing new is indexed.

/// One thing the field found.
struct ShellSearchHit: Identifiable, Equatable {
    enum Target: Equatable {
        case plan(start: Date, calendarID: String?, eventID: String?)
        #if !BANANA_PUBLIC
        case mail(MailConversationID)
        #endif
        case note(UUID)
    }

    let id: String
    let title: String
    let detail: String
    let target: Target
}

/// What the field has typed and found. Its own object, so a keystroke redraws the field and the
/// results and never the shell or the page under them.
@MainActor
final class ShellSearch: ObservableObject {
    static let shared = ShellSearch()

    @Published var text = "" { didSet { updateFieldMode() } }
    /// The field has the keyboard. Mirrored from the field's focus, for the bar and the results.
    @Published var focused = false {
        didSet {
            if focused && !presented { presented = true }
            updateFieldMode()
        }
    }
    /// A scroll may dismiss the keyboard while the picker remains the task in progress.
    @Published private(set) var presented = false { didSet { updateFieldMode() } }

    /// The field's mode alone. The bar and the shell observe this, not the search: a keystroke or
    /// a result arriving changes the mode only when the field empties, fills, opens or closes, and
    /// they redraw only then (the bar redrew with every keystroke and result, five times a
    /// second while typing on the owner's phone).
    final class FieldModeState: ObservableObject {
        @Published fileprivate(set) var mode: ShellFieldMode = .idle
    }
    let fieldMode = FieldModeState()

    private func updateFieldMode() {
        let mode = self.mode
        if fieldMode.mode != mode { fieldMode.mode = mode }
    }
    @Published private(set) var groups = ShellSearchGroups<ShellSearchHit>()
    /// The words `groups` answers, so a result list is never shown under other words.
    @Published private(set) var answered: String?
    @Published private(set) var searchingNotes = false

    /// A request to give the field the keyboard (the bar's field, wherever it is drawn).
    let focusRequests = PassthroughSubject<Bool, Never>()

    private var pending: Task<Void, Never>?
    #if !BANANA_PUBLIC
    private var mailObservation: MailObservation?
    #endif

    var mode: ShellFieldMode { .of(text: text, focused: focused, presented: presented) }

    /// Called on each change of `text`: the searches run once typing settles.
    func textChanged() {
        pending?.cancel()
        guard let query = ShellSearchRules.query(text) else {
            stopMail()
            if !groups.isEmpty { groups = ShellSearchGroups() }
            answered = nil
            searchingNotes = false
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: ShellSearchRules.settle)
            guard !Task.isCancelled else { return }
            await self?.run(query)
        }
    }

    /// Clears the field and lets the keyboard go.
    func clear() {
        presented = false
        text = ""
        textChanged()
        focusRequests.send(false)
        // A field in a toolbar (the wide shell's) keeps the keyboard whatever its focus state is
        // told: the keyboard is let go of directly, and the field counts as put away.
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        if focused { focused = false }
    }

    private func run(_ query: String) async {
        searchingNotes = true
        var next = ShellSearchGroups<ShellSearchHit>()
        let snapshot = OccurrenceStore.shared.occurrences
        let worker = Task.detached(priority: .userInitiated) {
            Self.selectPlanOccurrences(query, in: snapshot, limit: ShellSearchGroups<ShellSearchHit>.shownPerGroup, now: Date())
        }
        let matches = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, ShellSearchRules.query(text) == query else { return }
        next.plan = Self.plan(matches)
        next.mail = groups.mail.filter { _ in answered == query }
        groups = next
        answered = query
        searchMail(query)
        let notes = await Self.notes(query)
        guard !Task.isCancelled, answered == query, ShellSearchRules.query(text) == query else { return }
        if groups.notes != notes { groups.notes = notes }
        searchingNotes = false
    }

    // MARK: Plan — the timeline already in memory (the assistant's search reads the same).

    static func matchingPlanOccurrences(_ query: String, limit: Int, now: Date = Date()) -> [Occurrence] {
        selectPlanOccurrences(query, in: OccurrenceStore.shared.occurrences, limit: limit, now: now)
    }

    nonisolated static func selectPlanOccurrences(_ query: String, in occurrences: [Occurrence], limit: Int, now: Date) -> [Occurrence] {
        let wanted = ShellSearchRules.words(query)
        guard !wanted.isEmpty, limit > 0 else { return [] }
        let today = Calendar.current.startOfDay(for: now)
        var titles: [Occurrence] = [], details: [Occurrence] = []
        for item in occurrences {
            if Task.isCancelled { return [] }
            let remaining = wanted.filter { !ShellSearchRules.containsPrefix($0, in: item.title) }
            if remaining.isEmpty {
                titles.append(item)
            } else if let meeting = item.meeting, !meeting.isAvailabilityOnly {
                if remaining.allSatisfy({ word in
                    ShellSearchRules.containsPrefix(word, in: meeting.address ?? "") ||
                        ShellSearchRules.containsPrefix(word, in: meeting.searchDetails ?? "")
                }) {
                    details.append(item)
                }
            }
        }
        func ordered(_ matches: [Occurrence]) -> [Occurrence] {
            matches.sorted { lhs, rhs in
                if (lhs.start >= today) != (rhs.start >= today) { return lhs.start >= today }
                return lhs.start >= today ? lhs.start < rhs.start : lhs.start > rhs.start
            }
        }
        let first = Array(ordered(titles).prefix(limit))
        return first.count == limit ? first : first + ordered(details).prefix(limit - first.count)
    }

    private static func plan(_ matches: [Occurrence]) -> [ShellSearchHit] {
        matches.map { occurrence in
            let route = occurrence.meeting?.eventID.flatMap(GoogleCalendarIDs.rawEventRoute(from:))
            return ShellSearchHit(
                id: "plan:" + occurrence.id,
                title: occurrence.title,
                detail: when(occurrence),
                target: .plan(start: occurrence.start, calendarID: route?.calendarID, eventID: route?.eventID))
        }
    }

    private static func when(_ occurrence: Occurrence) -> String {
        let calendar = Calendar.current
        let dayWords = calendar.isDateInToday(occurrence.start) ? "today"
            : calendar.isDateInTomorrow(occurrence.start) ? "tomorrow"
            : calendar.isDateInYesterday(occurrence.start) ? "yesterday"
            : occurrence.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        guard occurrence.hasScheduledTime, occurrence.behavior != .allDay else { return dayWords }
        return TimeRangeText.compact(occurrence.start, occurrence.resolvedEnd) + " " + dayWords
    }

    // MARK: Notes — the list's own search.

    private static func notes(_ query: String) async -> [ShellSearchHit] {
        #if BANANA_MODULE_NOTES
        guard ModuleStore.shared.includes(.notes) else { return [] }
        return await VoiceNoteStore.shared.searchResults(query, limit: ShellSearchGroups<ShellSearchHit>.shownPerGroup)
            .map { note in
                ShellSearchHit(id: "note:\(note.id)", title: note.displayTitle,
                               detail: String((note.transcript ?? "").prefix(120)),
                               target: .note(note.id))
            }
        #else
        _ = query
        return []
        #endif
    }

    // MARK: Mail — the same observation a Mail search makes, five rows.

    private func searchMail(_ query: String) {
        #if BANANA_UNRELEASED
        guard ModuleStore.shared.includes(.email) else { return }
        MailApplication.shared.start()
        guard let session = MailApplication.shared.session else { return }
        let scope = MailScope(place: .search(LiveFilterParser.parse(query, scope: "mail").searchExpression))
        let observation = session.source.observeList(scope, limit: ShellSearchGroups<ShellSearchHit>.shownPerGroup) {
            [weak self] snapshot in
            guard let self, self.answered == query else { return }
            let hits = snapshot.rows.prefix(ShellSearchGroups<ShellSearchHit>.shownPerGroup).map { row in
                ShellSearchHit(id: "mail:\(row.id)", title: row.subject.isEmpty ? "(No subject)" : row.subject,
                               detail: Self.people(row) + " · " + Self.mailDate(row.date),
                               target: .mail(row.id))
            }
            if self.groups.mail != hits { self.groups.mail = hits }
        }
        stopMail()
        mailObservation = observation
        #endif
    }

    private func stopMail() {
        #if !BANANA_PUBLIC
        mailObservation?.cancel()
        mailObservation = nil
        #endif
    }

    #if !BANANA_PUBLIC
    private static func people(_ row: MailRow) -> String {
        row.people.prefix(2).map { $0.name ?? $0.address }.joined(separator: ", ")
    }

    private static func mailDate(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : Calendar.current.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    #endif

    // MARK: Opening a hit

    /// Opens what was found on its page, and puts the field away.
    func open(_ hit: ShellSearchHit) {
        let words = text
        clear()
        let shell = ShellNavigation.shared
        switch hit.target {
        case .plan(let start, let calendarID, let eventID):
            Self.show(.plan)
            PlanOpenRequests.shared.pending = .init(calendarID: calendarID, eventID: eventID, start: start)
        case .note(let id):
            shell.state.notes = [id]
            Self.show(.notes)
        #if !BANANA_PUBLIC
        case .mail(let id):
            Self.show(.mail)
            ShellMailOpener.open(id, searchedFor: words)
        #endif
        }
    }

    /// Shows a section: the shell's tab on iOS, the window's section on the Mac.
    static func show(_ section: AppSection) {
        #if os(macOS)
        MacNavigator.shared.section = section
        #else
        ShellNavigation.shared.state.tab = section
        #endif
    }

    /// Hands the words to the assistant, which starts on them.
    func ask() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clear()
        ShellAssistant.ask(words)
    }
}

/// The assistant this build has, if any: the one the Mac's "Ask or add" and the phone's "…"
/// opened (`AssistantView`). No assistant, no AI button and no "Ask" row.
enum ShellAssistant {
    static var isAvailable: Bool {
        #if BANANA_AI
        true
        #else
        false
        #endif
    }

    @MainActor static func open() {
        #if BANANA_AI
        #if os(iOS)
        PageChrome.shared.showAssistant = true
        #else
        NotificationCenter.default.post(name: .shellOpenAssistant, object: nil)
        #endif
        #endif
    }

    @MainActor static func ask(_ words: String) {
        #if BANANA_AI
        PageChrome.shared.agentPrefill = words.isEmpty ? nil : words
        open()
        #endif
    }
}

extension Notification.Name {
    /// The Mac's window opens its assistant panel.
    static let shellOpenAssistant = Notification.Name("banana.shell.open-assistant")
}

#if !BANANA_PUBLIC
/// A conversation found by the field: Mail shows the same search, and opens it once the list has
/// it (a conversation opens from its list, so the cursor and Back work as for any other).
@MainActor
enum ShellMailOpener {
    private static var waiting: AnyCancellable?

    static func open(_ id: MailConversationID, searchedFor words: String) {
        MailApplication.shared.start()
        guard let session = MailApplication.shared.session else { return }
        let scope = MailScope(place: .search(LiveFilterParser.parse(words, scope: "mail").searchExpression))
        session.switchTo(scope)
        if session.feed.shown.rows.contains(where: { $0.id == id }) { session.open(id); return }
        waiting = session.feed.$shown
            .first { $0.rows.contains { $0.id == id } }
            .timeout(.seconds(5), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { _ in waiting = nil } receiveValue: { _ in
                session.open(id)
                waiting = nil
            }
    }
}
#endif

// MARK: - The results

/// Under the field: the "Ask Banana" row, then what each page's search found. Opened with
/// nothing typed: what can be added, this page's kinds first (the one list a + used to open).
struct ShellSearchResults: View {
    @ObservedObject var search: ShellSearch
    /// The page the field is on, for the add list's order.
    let section: AppSection
    @ObservedObject private var modules = ModuleStore.shared

    var body: some View {
        let _ = RenderStats.note("ShellSearchResults")
        List {
            switch search.mode {
            case .idle:
                EmptyView()
            case .add:
                addRows
            case .results:
                resultRows
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        // The add rows are the list a + used to open: the same name, for tests and VoiceOver.
        .accessibilityIdentifier(search.mode == .add ? "page.add.list" : "shell.results")
    }

    @ViewBuilder private var addRows: some View {
        ForEach(AddKind.groups(for: section, with: modules.effectiveChoice), id: \.section) { group in
            Section(group.section == .nutrition ? "Food" : group.section.title) {
                ForEach(group.kinds) { kind in
                    Button { pick(kind) } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .tint(.primary)
                    .accessibilityIdentifier(kind.identifier)
                }
            }
        }
    }

    @ViewBuilder private var resultRows: some View {
        if ShellAssistant.isAvailable {
            Button { search.ask() } label: {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "sparkles").foregroundStyle(DS.Palette.accent)
                    Text("Ask Banana: ") .foregroundStyle(DS.Palette.accent)
                        + Text(search.text.trimmingCharacters(in: .whitespaces)).foregroundStyle(DS.Palette.accent)
                    Spacer(minLength: 0)
                    RowChevron()
                }
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shell.ask")
        }
        let currentAnswer = search.answered != nil && search.answered == ShellSearchRules.query(search.text)
        let groups = currentAnswer ? search.groups : ShellSearchGroups<ShellSearchHit>()
        ForEach(groups.nonEmpty, id: \.self) { group in
            Section {
                ForEach(groups.items(group)) { hit in
                    Button { search.open(hit) } label: { row(hit, group: group) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("shell.hit.\(group.rawValue)")
                }
            } header: {
                HStack {
                    Text(title(group))
                    Spacer()
                    let count = groups.items(group).count
                    Text(count == 1 ? "1 result" : "\(count) results").foregroundStyle(.secondary)
                }
            }
        }
        if currentAnswer, !search.searchingNotes, groups.isEmpty {
            Text("Nothing found")
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("shell.results.none")
        }
        if groups.plan.isEmpty || search.answered != nil {
            // Beyond the days on this device: the calendar search the plan's magnifier opened.
            Button { showsCalendarSearch = true } label: {
                Label("Search all calendars", systemImage: "calendar")
            }
            .tint(.primary)
            .accessibilityIdentifier("shell.calendarSearch")
            .sheet(isPresented: $showsCalendarSearch) { CalendarSearchSheet(text: search.text) }
        }
    }

    @State private var showsCalendarSearch = false

    private func row(_ hit: ShellSearchHit, group: ShellSearchGroups<ShellSearchHit>.Group) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: symbol(group), tint: tint(group), style: .soft)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(hit.title).font(.body.weight(.semibold)).lineLimit(1)
                if !hit.detail.isEmpty {
                    Text(hit.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            RowChevron()
        }
        .contentShape(Rectangle())
    }

    private func title(_ group: ShellSearchGroups<ShellSearchHit>.Group) -> String {
        switch group {
        case .plan: "Plan"
        case .mail: "Mail"
        case .notes: "Notes"
        }
    }

    private func symbol(_ group: ShellSearchGroups<ShellSearchHit>.Group) -> String {
        switch group {
        case .plan: "calendar"
        case .mail: "envelope"
        case .notes: "doc.text"
        }
    }

    private func tint(_ group: ShellSearchGroups<ShellSearchHit>.Group) -> Color {
        switch group {
        case .plan: DS.Palette.success
        case .mail: DS.Palette.info
        case .notes: DS.Palette.warning
        }
    }

    private func pick(_ kind: AddKind) {
        search.clear()
        // The page the kind belongs to starts it (`onAdd`), as a pick from the old + list did.
        if let half = kind.nutritionSection { ShellNavigation.shared.state.nutritionSection = half }
        #if os(macOS)
        if kind == .supplement {
            MacNavigator.shared.openBody(.taken)
        } else {
            ShellSearch.show(kind.section)
        }
        #else
        ShellSearch.show(kind.section)
        #endif
        PageChrome.shared.pendingAdd = kind
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if PageChrome.shared.pendingAdd == kind { PageChrome.shared.pendingAdd = nil }
        }
    }
}
