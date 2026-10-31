import SwiftUI

/// Create or edit a cue: what triggers it, what it plays, and how firmly it fires.
struct RoutineEditorView: View {
    @EnvironmentObject var routines: RoutineStore
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var smart: SmartScheduleStore
    @Environment(\.dismiss) private var dismiss

    @State var draft: Routine
    let isNew: Bool

    private let icons = ["sunrise.fill", "figure.run", "car.fill", "scope", "figure.walk",
                         "moon.fill", "moon.zzz.fill", "cup.and.saucer.fill", "book.fill", "circle.fill"]

    private var autonomy: Autonomy { Autonomy.default(for: draft.triggerKind) }

    /// One form on the iPhone, the iPad and the Mac (ADAPTIVE-LAYOUT.md rule 5).
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Trigger", selection: $draft.triggerKind) {
                        Text("At a time").tag(RoutineTriggerKind.time)
                        Text("Before first meeting").tag(RoutineTriggerKind.earliestMeeting)
                        // The Wake routine is what the others follow; it can't follow itself.
                        if draft.cueType != .wake {
                            Text("When you wake up").tag(RoutineTriggerKind.wakeUp)
                        }
                        Text("With calendar events").tag(RoutineTriggerKind.calendarMatch)
                        Text("When a workout starts").tag(RoutineTriggerKind.workoutStart)
                        Text("Manual (a button)").tag(RoutineTriggerKind.manual)
                    }
                    if draft.triggerKind == .time {
                        TimeField("Time", selection: timeBinding)
                        weekdayPicker
                        ForEach($draft.extraSlots) { $slot in
                            HStack {
                                TimeField("Also at", selection: slotTimeBinding($slot))
                                Button(role: .destructive) {
                                    draft.extraSlots.removeAll { $0.id == slot.id }
                                } label: { Image(systemName: "minus.circle.fill") }
                                .iconButton()
                            }
                            weekdayRow($slot.weekdays, identifier: "routine.slot.\(slot.id)")
                        }
                        Button {
                            draft.extraSlots.append(CueSlot(weekdays: [], hour: draft.hour, minute: draft.minute))
                        } label: { Label("Add another time", systemImage: "plus.circle") }
                    }
                    if draft.triggerKind == .calendarMatch {
                        TextField("Title keywords (comma-separated)", text: keywordsBinding)
                            .autocorrectionDisabled()
                        Picker("Fire", selection: $draft.leadMinutes) {
                            Text("At event start").tag(0)
                            ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min before").tag($0) }
                        }
                    }
                    if draft.triggerKind == .wakeUp {
                        Picker("Starts", selection: $draft.leadMinutes) {
                            Text("When you wake up").tag(0)
                            ForEach(WakeFollowing.minuteChoices, id: \.self) { Text("\($0) min after").tag($0) }
                        }
                        weekdayPicker
                    }
                    if draft.triggerKind == .workoutStart {
                        // How long you train is yours to say: it's the length the workout takes
                        // on your day when you give it a time.
                        Picker("Usually takes", selection: $draft.durationMinutes) {
                            ForEach([20, 30, 45, 60, 75, 90, 120], id: \.self) { m in
                                Text(m >= 60
                                     ? (m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min")
                                     : "\(m) min").tag(m)
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(RoutineWording.sentence(autonomy.level))
                            .fixedSize(horizontal: false, vertical: true)
                        if draft.triggerKind == .workoutStart {
                            Text("It fires whenever you actually start a workout, so it has no time of its own on your day.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if draft.triggerKind == .wakeUp {
                            Text(Self.wakeFollowingNote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if draft.triggerKind == .earliestMeeting {
                            Text("The exact time comes from Wake & bedtime: ~\(smart.settings.prepBufferMinutes) min before your first meeting, minus travel, never earlier than your earliest-wake floor, and held to a steady rhythm across the week. Change the offset in Routines → Smart wake schedule.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if draft.triggerKind == .calendarMatch {
                            Text("Fires whenever a calendar event's title contains one of these keywords — e.g. “gym, lift” triggers on your Gym events. Matches across all your calendars, on the day each event happens.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // A Mac's form sizes a footer to its longest line unless told its width.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    NavigationLink {
                        CueSourcesEditor(ids: $draft.podcastIDs, musicItem: $draft.musicItem)
                    } label: {
                        HStack {
                            Text("Sources")
                            Spacer()
                            Text(sourceSummary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Plays")
                } footer: {
                    Text(draft.podcastIDs.count > 1
                         ? "Plays #1's next unfinished episode; drops to the next when it's caught up."
                         : "The show(s) this routine plays. Add several to set a priority order.")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    Toggle("Sleep timer", isOn: sleepTimerBinding)
                    if draft.sleepTimerMinutes != nil {
                        Picker("Fade out after", selection: sleepMinutesBinding) {
                            ForEach(AppSettings.sleepDurationOptions, id: \.self) { Text("\($0) min").tag($0) }
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Part of day", selection: $draft.group) {
                        ForEach(RoutineGroup.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    colorPicker
                    iconPicker
                }

                if !isNew {
                    Section {
                        Button("Delete", role: .destructive) {
                            DeleteUndo.routine(draft.id, in: routines); dismiss()
                        }
                    }
                }
            }
            .editingFormStyle()
            .navigationTitle(isNew ? "New routine" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 620)
        #endif
    }

    private var sourceSummary: String {
        if draft.podcastIDs.count == 1 { return library.podcast(draft.podcastIDs[0])?.title ?? "1 show" }
        if draft.podcastIDs.count > 1 { return "\(draft.podcastIDs.count) shows" }
        if let music = draft.musicItem { return music.title }
        return "None"
    }

    private func save() {
        draft.autonomy = autonomy
        if draft.podcastIDs.count == 1 { draft.sourceLabel = library.podcast(draft.podcastIDs[0])?.title ?? draft.sourceLabel }
        else if draft.podcastIDs.count > 1 { draft.sourceLabel = "\(draft.podcastIDs.count) shows" }
        else if let music = draft.musicItem { draft.sourceLabel = music.title }
        else if draft.slot == nil { draft.sourceLabel = "Keep playing" }
        routines.upsert(draft)
        dismiss()
    }

    // MARK: - Sub-pickers

    private var weekdayPicker: some View { weekdayRow($draft.weekdays, identifier: "routine") }

    /// The one weekday row. Here no day chosen means every day, so the last one can go.
    private func weekdayRow(_ weekdays: Binding<[Int]>, identifier: String) -> some View {
        WeekdayToggleRow(
            selection: Binding(
                get: { RoutineEditorValues.days(weekdays.wrappedValue) },
                set: { weekdays.wrappedValue = RoutineEditorValues.weekdays($0) }),
            identifier: identifier,
            allowsEmpty: true)
    }

    private func slotTimeBinding(_ slot: Binding<CueSlot>) -> Binding<Date> {
        Binding(
            get: { RoutineEditorValues.date(hour: slot.wrappedValue.hour, minute: slot.wrappedValue.minute) },
            set: {
                let clock = RoutineEditorValues.clock(of: $0)
                slot.wrappedValue.hour = clock.hour
                slot.wrappedValue.minute = clock.minute
            }
        )
    }

    private var colorPicker: some View {
        HStack(spacing: 10) {
            ForEach(RoutineColor.allCases, id: \.self) { c in
                Circle().fill(c.color).frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.primary, lineWidth: draft.color == c ? 2.5 : 0).padding(-3))
                    .onTapGesture { draft.color = c }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A row to swipe along on a phone; a pointer has nothing to swipe with, so the Mac wraps.
    @ViewBuilder private var iconPicker: some View {
        #if os(macOS)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 10)], alignment: .leading, spacing: 10) {
            iconChoices
        }
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) { iconChoices }
        }
        #endif
    }

    private var iconChoices: some View {
        ForEach(icons, id: \.self) { name in
            Image(systemName: name)
                .font(.system(size: 18))
                .frame(width: 38, height: 38)
                .background(draft.icon == name ? draft.color.color.opacity(DS.Tint.fill) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .foregroundStyle(draft.icon == name ? draft.color.color : .secondary)
                .onTapGesture { draft.icon = name }
        }
    }

    // MARK: - Bindings

    private var timeBinding: Binding<Date> {
        Binding(
            get: { RoutineEditorValues.date(hour: draft.hour, minute: draft.minute) },
            set: {
                let clock = RoutineEditorValues.clock(of: $0)
                draft.hour = clock.hour
                draft.minute = clock.minute
            }
        )
    }
    private var keywordsBinding: Binding<String> {
        Binding(
            get: { draft.matchKeywords.joined(separator: ", ") },
            set: {
                draft.matchKeywords = $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
    private var sleepTimerBinding: Binding<Bool> {
        Binding(get: { draft.sleepTimerMinutes != nil },
                set: { draft.sleepTimerMinutes = $0 ? (draft.sleepTimerMinutes ?? 45) : nil })
    }
    private var sleepMinutesBinding: Binding<Int> {
        Binding(get: { draft.sleepTimerMinutes ?? 45 }, set: { draft.sleepTimerMinutes = $0 })
    }

    /// What "When you wake up" follows, under the control on both layouts.
    private static let wakeFollowingNote = "Follows your Wake routine: its time each day, which moves with your first meeting, plus the minutes you choose. With no Wake routine it keeps its own time."

}

/// The cue's source pool — always editable (drag to reorder, swipe/– to remove, +
/// to add), so there's no Edit button to toggle.
private struct CueSourcesEditor: View {
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var music: MusicController
    @Binding var ids: [UUID]
    @Binding var musicItem: MusicWakeItem?

    @State private var showingMusicPicker = false

    private var available: [Podcast] { library.podcasts.filter { !ids.contains($0.id) } }

    var body: some View {
        List {
            if !ids.isEmpty {
                Section {
                    ForEach(ids, id: \.self) { id in
                        let rank = (ids.firstIndex(of: id) ?? 0) + 1
                        HStack(spacing: 10) {
                            Text("\(rank)").font(.footnote.weight(.bold)).foregroundStyle(DS.Palette.accent).frame(width: 16)
                            Text(library.podcast(id)?.title ?? "Unknown show")
                        }
                    }
                    .onMove { ids.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { ids.remove(atOffsets: $0) }
                } header: {
                    Text("Podcasts · priority order")
                } footer: {
                    Text(ids.count > 1
                         ? "#1 plays first; drops to the next when it's caught up. Drag to reorder, swipe to remove."
                         : "One show. Add more from ✚ to build a priority list.")
                }
            }

            if let item = musicItem {
                Section("Apple Music") {
                    Label(item.title, systemImage: "music.note")
                }
            }

            if ids.isEmpty && musicItem == nil {
                Section {
                    Text("No sources yet. Add a show or Apple Music from ✚ above — the routine plays podcasts if any are set, otherwise Apple Music.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))   // podcasts always draggable + removable
        #endif
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .automatic) { addMenu }
        }
        .sheet(isPresented: $showingMusicPicker) {
            NavigationStack { CueMusicPicker(selection: $musicItem) }
        }
    }

    // Add/remove sources live in the toolbar so list edit-mode can't grey them out.
    @ViewBuilder private var addMenu: some View {
        Menu {
            if !available.isEmpty {
                Menu {
                    ForEach(available) { podcast in Button(podcast.title) { ids.append(podcast.id) } }
                } label: { Label("Add a show", systemImage: "waveform") }
            } else if library.podcasts.isEmpty {
                Label("Add shows in Library first", systemImage: "info.circle")
            }

            if music.isAuthorized {
                Button { showingMusicPicker = true } label: {
                    Label(musicItem == nil ? "Add Apple Music" : "Change Apple Music", systemImage: "music.note")
                }
                if musicItem != nil {
                    Button(role: .destructive) { musicItem = nil } label: { Label("Remove Apple Music", systemImage: "minus.circle") }
                }
            } else {
                Button { Task { await music.requestAuthorization() } } label: { Label("Connect Apple Music", systemImage: "music.note") }
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}

/// Pick an Apple Music playlist / album / song for a cue.
private struct CueMusicPicker: View {
    @EnvironmentObject var music: MusicController
    @Binding var selection: MusicWakeItem?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            section("Playlists", music.playlists)
            section("Albums", music.albums)
            section("Songs", music.songs)
        }
        .navigationTitle("Apple Music")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .overlay {
            if music.playlists.isEmpty && music.albums.isEmpty && music.songs.isEmpty {
                if music.isLoading { ProgressView() }
                else { ContentUnavailableView("Nothing found", systemImage: "music.note",
                                               description: Text("No items in your Apple Music library.")) }
            }
        }
        .task { if music.playlists.isEmpty { await music.loadLibrary() } }
        .refreshable { await music.loadLibrary() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    @ViewBuilder private func section(_ title: String, _ items: [MusicWakeItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button {
                        selection = item
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage).foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).foregroundStyle(.primary).lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if selection == item { Image(systemName: "checkmark").foregroundStyle(DS.Palette.accent) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
