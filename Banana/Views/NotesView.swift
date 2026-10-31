import AVFoundation
import Combine
import SwiftUI

/// Capture on iPhone/Watch; review with full podcast context on either screen.
struct NotesView: View {
    /// The room this screen has (docs/design/ADAPTIVE-LAYOUT.md).
    @Environment(\.layoutClass) private var layoutClass
    @ObservedObject private var store = VoiceNoteStore.shared
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: PodcastLibrary
    @EnvironmentObject private var smart: SmartScheduleStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var shell = ShellNavigation.shared
    @ObservedObject private var toasts = ToastCenter.shared
    @ObservedObject private var presentation = NotesPresentation.shared
    private var search: String { presentation.filter.text }
    private var filter: LiveFilter { presentation.filter }
    private var filterBar: some View { LiveFilterSearch(scope: "notes", filter: $presentation.filter).padding(.horizontal).padding(.vertical, 8).background(.background) }

    /// The open note: the pushed screen on iPhone, the list selection on the Mac. Kept in
    /// ShellNavigation, not `@State`, so leaving the tab or the app doesn't close it.
    private var selection: UUID? {
        get { shell.state.notes.last }
        nonmutating set { shell.state.notes = newValue.map { [$0] } ?? [] }
    }

    /// A restored note deleted in the meantime (here or on another device) shouldn't reopen.
    private func pruneOpenNotes() {
        guard store.storageError == nil else { return }
        let kept = ShellState.pruned(shell.state.notes, known: Set(shell.state.notes.filter { store.note($0) != nil }))
        if kept != shell.state.notes { shell.state.notes = kept }
    }

    private var filteredNotes: [VoiceNote] {
        PendingRemovals.visible(activePage, id: { DeleteUndo.hidingID(note: $0.id) }, hiding: toasts.hiddenIDs)
    }
    private var archivedNotes: [VoiceNote] {
        PendingRemovals.visible(archivedPage, id: { DeleteUndo.hidingID(note: $0.id) }, hiding: toasts.hiddenIDs)
    }
    @State private var activePage: [VoiceNote] = []
    @State private var archivedPage: [VoiceNote] = []
    @State private var activeTotal = 0
    @State private var archivedTotal = 0
    @State private var pageOffset = 0
    @State private var isLoading = true
    @State private var pageError: String?
    @State private var loadedQuery: QueryKey?
    private var hasArchived: Bool { store.archivedCount > 0 }
    private var includesArchived: Bool { filter.value("archived") == "true" || (filter.value("archived") == nil && (smart.settings.showArchivedNotes || !filter.isEmpty)) }
    private struct QueryKey: Hashable {
        let revision: Int
        let search: String
        let filter: LiveFilter
        let day: Date?
        let archived: Bool
        let offset: Int
    }
    @ViewBuilder private var pagingControls: some View {
        let total = max(activeTotal, archivedTotal)
        if total > 100 {
            HStack {
                Button("Previous") { pageOffset = max(0, pageOffset - 100) }
                    .disabled(pageOffset == 0)
                    .accessibilityIdentifier("notes.page.previous")
                Spacer()
                Text("\(pageOffset + 1)–\(min(pageOffset + 100, total))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Next") { pageOffset += 100 }
                    .disabled(pageOffset + 100 >= total)
                    .accessibilityIdentifier("notes.page.next")
            }
            .buttonStyle(.borderless)
            .padding()
            .background(.regularMaterial)
        }
    }

    /// Toolbar control for the synced show-archived toggle. Only offered once something
    /// is actually archived — before that it would be a mystery button.
    @ViewBuilder private var archivedToggleButton: some View {
        if hasArchived {
            Button {
                smart.settings.showArchivedNotes.toggle()
            } label: {
                Label(smart.settings.showArchivedNotes ? "Hide archived" : "Show archived",
                      systemImage: smart.settings.showArchivedNotes ? "archivebox.fill" : "archivebox")
            }
            .help(smart.settings.showArchivedNotes
                  ? "Hide archived notes (applies on all your devices)"
                  : "Show archived notes (applies on all your devices)")
        }
    }

    /// What Copy and Share put on the pasteboard: the thought itself, or a stub for a
    /// note that hasn't transcribed yet.
    private func shareText(for note: VoiceNote) -> String {
        if let transcript = note.transcript, !transcript.isEmpty { return transcript }
        return "Voice note recorded \(note.createdAt.formatted(.dateTime.month().day().hour().minute()))"
    }

    var body: some View {
        let _ = RenderStats.note("NotesView")
        Group {
            #if os(macOS)
            wideLayout
            #else
            // The list beside the open note where there's room for both (an iPad, an unfolded
            // phone); one pushed over the other where there isn't.
            if layoutClass == .regular {
                padLayout
            } else {
                phoneLayout
            }
            #endif
        }
        .safeAreaInset(edge: .top) {
            if let error = store.reminderWriteError {
                HStack {
                    Text(error).font(.caption)
                    Spacer()
                    Button("Retry") { store.retryReminderWrites() }
                }
                .padding().background(.regularMaterial)
                .accessibilityIdentifier("notes.reminderWriteBack.pending")
            }
        }
        .onAppear { RenderStats.note("Notes.appear") }
        .onChange(of: filter) { _, _ in pageOffset = 0 }
        .onChange(of: includesArchived) { _, _ in pageOffset = 0 }
        .task(id: QueryKey(revision: store.revision, search: search, filter: filter, day: filter.interval()?.start, archived: includesArchived, offset: pageOffset)) {
            let request = QueryKey(revision: store.revision, search: search, filter: filter, day: filter.interval()?.start, archived: includesArchived, offset: pageOffset)
            // Keep the displayed page across tab visits. Revision changes, filters and paging
            // invalidate it; cancellation and failures never mark an unfinished page as loaded.
            #if DEBUG
            let reuseLoadedPage = !ProcessInfo.processInfo.arguments.contains("--notes-reload-on-appear")
            #else
            let reuseLoadedPage = true
            #endif
            if reuseLoadedPage && loadedQuery == request {
                isLoading = false
                pageError = nil
                return
            }
            let _ = RenderStats.note("Notes.loadPage")
            isLoading = true
            let offset = request.offset
            do {
                try Task.checkCancellation()
                let active = filter.value("archived") != "true" && filter.canRun
                    ? try await store.page(search: search, archived: false, offset: offset, filter: filter)
                    : NoteRepository.Page(rows: [], total: 0)
                let archived = includesArchived && filter.canRun
                    ? try await store.page(search: search, archived: true, offset: offset, filter: filter)
                    : NoteRepository.Page(rows: [], total: 0)
                guard !Task.isCancelled else { return }
                let total = max(active.total, archived.total)
                if offset > 0 && offset >= total {
                    pageOffset = max(0, ((max(1, total) - 1) / 100) * 100)
                    return
                }
                activePage = active.rows
                archivedPage = archived.rows
                activeTotal = active.total
                archivedTotal = archived.total
                pageError = nil
                loadedQuery = request
            } catch {
                guard !Task.isCancelled else { return }
                pageError = error.localizedDescription
            }
            isLoading = false
        }
        .overlay {
            if isLoading && filteredNotes.isEmpty && archivedNotes.isEmpty { ProgressView("Loading notes…") }
            if let pageError { ContentUnavailableView("Notes unavailable", systemImage: "exclamationmark.triangle", description: Text(pageError)) }
        }
        // Writing a note, or editing one's text — from the list, the toolbar or a note's own
        // screen. In ShellNavigation so a half-written note survives a trip to another app.
        .sheet(item: Binding(
            get: { shell.state.noteComposer.map(NoteComposerTarget.init(id:)) },
            set: { shell.state.noteComposer = $0?.id }
        )) { target in
            NoteComposer(target: target.id)
        }
        #if DEBUG
        // `--note-composer`: open the composer at launch, for a screenshot.
        .task {
            if ProcessInfo.processInfo.arguments.contains("--note-composer") {
                shell.state.noteComposer = NoteComposer.new
            }
        }
        #endif
    }

    private func writeNote() {
        shell.state.noteComposer = NoteComposer.new
    }

    #if os(iOS)
    /// A note in the list: pushed where the list has the screen to itself, shown beside the
    /// list where there's room (the open note is the same `ShellNavigation` path either way, so
    /// turning an iPad keeps it).
    @ViewBuilder private func noteLink(_ note: VoiceNote) -> some View {
        if layoutClass == .regular {
            Button { shell.state.notes = [note.id] } label: {
                VoiceNoteRow(note: note).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(shell.state.notes.last == note.id
                                ? DS.Palette.accent.opacity(DS.Tint.soft)
                                : Color(.secondarySystemGroupedBackground))
        } else {
            NavigationLink(value: note.id) {
                VoiceNoteRow(note: note)
            }
        }
    }

    private var phoneLayout: some View {
        NavigationStack(path: $shell.state.notes) { notesList }
    }

    /// The list beside the open note, in the system's split view: it gives the list its
    /// width, its title, its search field and its toolbar, and keeps clear of the tab bar. (It
    /// was a hand-made row of two panes, which sat badly under the iPad's tab bar.)
    private var padLayout: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            notesList
                // The grouped page's own white rows on grey, not the sidebar's grey tint, which
                // made every note look selected or disabled.
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                // Asked for, not granted: on an iPad held upright the system keeps this column at
                // 320 pt whatever is asked (measured with 360 to 460 and with a fixed 400), so
                // what is in it is laid out for 320 (`inColumn`).
                .navigationSplitViewColumnWidth(min: 360, ideal: 400, max: 460)
                // Always beside its note: the list is the way to every other note.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack {
                if let id = shell.state.notes.last, store.note(id) != nil {
                    VoiceNoteDetailView(noteID: id).id(id)
                } else {
                    ContentUnavailableView("No note open", systemImage: "note.text")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Beside the open note, the list is a 320 pt column that already has margins of its own.
    private var inColumn: Bool { layoutClass == .regular }

    private var notesList: some View {
            List {
                if filteredNotes.isEmpty && archivedNotes.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    if !filteredNotes.isEmpty {
                    Section("Your notes") {
                        ForEach(filteredNotes) { note in
                            noteLink(note)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = shareText(for: note)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Button {
                                    store.setArchived(note.id, true)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                ShareLink(item: shareText(for: note)) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    DeleteUndo.note(note, in: store)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { filteredNotes[$0] }.forEach { DeleteUndo.note($0, in: store) }
                        }
                    }
                    }   // end !filteredNotes.isEmpty
                    if !archivedNotes.isEmpty {
                        Section("Archived") {
                            ForEach(archivedNotes) { note in
                                noteLink(note)
                                .contextMenu {
                                    Button {
                                        store.setArchived(note.id, false)
                                    } label: {
                                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                                    }
                                    Button {
                                        UIPasteboard.general.string = shareText(for: note)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    ShareLink(item: shareText(for: note)) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    Button(role: .destructive) {
                                        DeleteUndo.note(note, in: store)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .top) { filterBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { pagingControls }
            .navigationTitle("Notes")
            .navigationDestination(for: UUID.self) { VoiceNoteDetailView(noteID: $0) }
            // Runs whether or not the list itself is on screen (a restored stack opens with the
            // note pushed), and again whenever notes change on another device.
            .onChange(of: store.revision, initial: true) { _, _ in pruneOpenNotes() }
            // Beside a note the list has no room to pull down for its search field: it stays out.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ReviewToolbarItem(section: .notes)
                ToolbarItem(placement: .automatic) {
                    MoreMenu { archivedToggleButton }
                }
            }
            // The one + (`PageChrome`). There were four ways in: two icons at the top right, a
            // card at the head of the list and a row under it.
            .addMenu(identifier: "notes.add") {
                Button { store.beginCapture(kind: .podcastCapture) } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .accessibilityIdentifier("notes.capture")
                Button(action: writeNote) {
                    Label("Write", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("notes.write")
            }
            // The same two, picked from the + on the tab bar's row.
            .onAdd(.recordNote, .writeNote) { kind in
                if kind == .recordNote { store.beginCapture(kind: .podcastCapture) } else { writeNote() }
            }
            // The recording screen is shown by RootView's VoiceCaptureHost (see there).
            .task { await store.refreshFromCloud() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await store.refreshFromCloud() }
            }
    }

    #endif

    #if os(macOS)
    private var wideLayout: some View {
        Group {
            #if os(macOS)
            NavigationStack { wideContent }
            #else
            wideContent
            #endif
        }
    }

    private var wideContent: some View {
            WorkspaceColumns {
                VStack(spacing: 0) {
                    filterBar
                    if filteredNotes.isEmpty && archivedNotes.isEmpty {
                        emptyState
                    } else {
                        List(selection: Binding(get: { selection }, set: { selection = $0 })) {
                            ForEach(filteredNotes) { note in
                                VoiceNoteRow(note: note)
                                    .tag(note.id)
                                    .contextMenu {
                                        // Copy and Share, as the phone's list has.
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(shareText(for: note), forType: .string)
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        Button {
                                            store.setArchived(note.id, true)
                                        } label: {
                                            Label("Archive", systemImage: "archivebox")
                                        }
                                        ShareLink(item: shareText(for: note)) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                        Button(role: .destructive) {
                                            DeleteUndo.note(note, in: store)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                            if !archivedNotes.isEmpty {
                                Section("Archived") {
                                    ForEach(archivedNotes) { note in
                                        VoiceNoteRow(note: note)
                                            .tag(note.id)
                                            .contextMenu {
                                                Button {
                                                    store.setArchived(note.id, false)
                                                } label: {
                                                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                                                }
                                                Button(role: .destructive) {
                                                    DeleteUndo.note(note, in: store)
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .tint(.gray)
                        .accessibilityIdentifier("notes.list")
                    }
                    pagingControls
                }
            .navigationTitle("Notes")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button { store.beginCapture(kind: .podcastCapture) } label: {
                        Label("Record note", systemImage: "mic.fill")
                    }
                }
                #endif
                ToolbarItem(placement: .automatic) {
                    archivedToggleButton
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await store.refreshFromCloud(force: true) }
                    } label: {
                        Label("Refresh notes", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.syncState == .syncing)
                }
                // Whether iCloud is bringing notes in: the toolbar's, where a header of its own
                // with three sentences about notes was.
                ToolbarItem(placement: .automatic) { syncIndicator }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: writeNote) {
                        Label("New note", systemImage: "square.and.pencil")
                    }
                    .help("Write a note")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            } detail: {
                Group {
                    if let selection,
                       store.note(selection) != nil {
                        VoiceNoteDetailView(noteID: selection)
                            .id(selection)
                    } else {
                        ContentUnavailableView {
                            Label("Select a note", systemImage: "quote.bubble")
                        } description: {
                            Text("Review the thought, what was playing, and the passage that prompted it.")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task {
                await store.refreshFromCloud()
                if selection == nil { selection = filteredNotes.first?.id }
            }
            .onChange(of: (filteredNotes + archivedNotes).map(\.id), initial: true) { _, ids in
                guard !isLoading else { return }
                if selection == nil || selection.map({ store.note($0) == nil }) == true {
                    selection = ids.first
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await store.refreshFromCloud() }
            }
    }

    #endif

    private var macHeader: some View {
        HStack(spacing: DS.Space.s) {
            Text("Notes").font(.headline)
            Text("\(activeTotal + archivedTotal)")
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            syncIndicator
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: DS.Mail.header)
    }

    @ViewBuilder private var syncIndicator: some View {
        switch store.syncState {
        case .syncing:
            ProgressView().controlSize(.small).help("Syncing notes from iCloud")
        case .synced:
            Image(systemName: "icloud.and.arrow.down.fill")
                .foregroundStyle(DS.Palette.success)
                .help("Notes are current")
        case .unavailable:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
                .help("iCloud notes are unavailable in this build or account")
        case .idle:
            EmptyView()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(search.isEmpty ? "No notes yet" : "No matching notes", systemImage: "quote.bubble")
        } description: {
            if !search.isEmpty {
                Text("Try a podcast name, episode title, or words from the note.")
            } else if hasArchived {
                // Everything is archived and the toggle is off — say so instead of
                // pretending the notes are gone.
                Text("All your notes are archived. Show them from the \u{2026} menu.")
            }
        } actions: {
            if search.isEmpty && !hasArchived {
                Button("Write a note", action: writeNote)
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("notes.empty.write")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

/// Session-only reading state survives tab changes, backgrounding and compact/wide transitions.
/// Scroll offsets don't publish: scrolling a note must not invalidate the whole notes list.
@MainActor
private final class NotesPresentation: ObservableObject {
    static let shared = NotesPresentation()
    @Published var filter = LiveFilter(scope: "notes")
    var offsets: [UUID: CGFloat] = [:]
}

private struct VoiceNoteRow: View {
    let note: VoiceNote

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(note.displayTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(note.status == .transcribed ? .primary : .secondary)
                .lineLimit(3)
            if let context = note.context {
                // What it was said over: the episode, in the quiet colour (the accent is for what
                // can be tapped, and the row is the tap).
                // A plain stack, not a Label: in a List a Label gets a whole icon column.
                // Only the title truncates; the timestamp keeps its width.
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "headphones")
                    Text(context.episodeTitle ?? context.podcastTitle ?? "Podcast")
                        .lineLimit(1)
                    if let timestamp = context.timestamp {
                        Text("· \(VoiceNote.Context.clock(timestamp))")
                            .fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let source = note.source {
                    Text("·")
                    Text(source.title)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        // The separator starts under the title, whatever the lines below hold.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .accessibilityIdentifier("notes.row.\(note.id.uuidString)")
    }

}

private struct VoiceNoteDetailView: View {
    let noteID: UUID

    @ObservedObject private var store = VoiceNoteStore.shared
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: PodcastLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playing = false
    @State private var audioPosition: TimeInterval = 0
    @State private var confirmDelete = false
    @State private var position: ScrollPosition

    init(noteID: UUID) {
        self.noteID = noteID
        _position = State(initialValue: ScrollPosition(y: NotesPresentation.shared.offsets[noteID] ?? 0))
    }
    /// Drives `audioPosition`/finish-detection only while actually playing — see
    /// `startTicker`/`stopTicker`. Idle and paused states cost zero wakeups.
    @State private var ticker: AnyCancellable?

    private var note: VoiceNote? { store.note(noteID) }

    var body: some View {
        Group {
            if let note {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        detailHeader(note)
                        transcript(note)
                        if let context = note.context { contextCard(context) }
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .accessibilityIdentifier("notes.detail.\(noteID.uuidString)")
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) {
                    max(0, $0.contentOffset.y + $0.contentInsets.top).rounded()
                } action: { _, offset in
                    NotesPresentation.shared.offsets[noteID] = offset
                }
                .background(Color(.systemGroupedBackground))
                #if os(iOS)
                .navigationTitle("Note")
                #endif
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    // One "…" for what can be done with a note (it was three icons in a row).
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            // Every note's text can change: a written one, or a transcription
                            // that got words wrong.
                            Button { ShellNavigation.shared.state.noteComposer = note.id.uuidString } label: {
                                Label(note.isWritten ? "Edit note" : "Edit text", systemImage: "pencil")
                            }
                            .accessibilityIdentifier("notes.edit")
                            ShareLink(item: shareText(note)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            // At once, with Undo in the toast: the list (and this screen with it)
                            // lets go of the note, and it is removed when that window closes.
                            Button(role: .destructive) {
                                DeleteUndo.note(note, in: store)
                                dismiss()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityIdentifier("notes.delete")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                        .accessibilityIdentifier("notes.more")
                    }
                }
            } else {
                ContentUnavailableView("Note unavailable", systemImage: "quote.bubble")
            }
        }
        .onChange(of: playing) { _, isPlaying in
            if isPlaying { startTicker() } else { stopTicker() }
        }
        .onDisappear {
            stopTicker()
            audioPlayer?.stop()
        }
    }

    /// Polls `audioPlayer.currentTime` at the same 5 Hz cadence the old unconditional
    /// timer used, but only while `playing` is true — see the wakeup-cost finding this
    /// replaced. Also carries the original finish-detection: if the player stops on its
    /// own (natural end of track), snap to duration and flip `playing` back to false
    /// (which tears the ticker down via the `onChange` above).
    private func startTicker() {
        ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { _ in
            guard let audioPlayer else { return }
            audioPosition = audioPlayer.currentTime
            if playing && !audioPlayer.isPlaying {
                playing = false
                audioPosition = audioPlayer.duration
            }
        }
    }

    /// Cancels the ticker. Reads `audioPlayer.currentTime` one last time first so the
    /// displayed position is exact at the pause instant instead of up to 200ms stale —
    /// matching what the old ungated timer's next tick would have overwritten it with.
    ///
    /// Skipped once `audioPosition` already reached `duration`: natural end-of-track flips
    /// `playing` to false inside the ticker's own sink (above), which re-enters this via the
    /// `onChange(of: playing)` — re-reading `currentTime` here would clobber the deliberate
    /// snap-to-`duration` with a value that can be fractionally short of it (AVAudioPlayer's
    /// buffer/frame rounding), showing e.g. "2:59" instead of "3:00" at the end.
    private func stopTicker() {
        if let audioPlayer, audioPosition < audioPlayer.duration {
            audioPosition = audioPlayer.currentTime
        }
        ticker?.cancel()
        ticker = nil
    }

    private func detailHeader(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // One line, in the list's format: the long date wrapped in a narrow column.
            Label("\(sourceLabel(note)) · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))",
                  systemImage: sourceIcon(note))
            .lineLimit(1)
            .font(.subheadline)
            .foregroundStyle(.secondary)

            // A written note, or one whose audio is gone, has nothing to play.
            if !note.isWritten && store.hasAudio(for: note) {
            Button { toggleAudio(note) } label: {
                Label(playing ? "Pause recording" : "Play recording",
                      systemImage: playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.primary)

            if let audioPlayer, audioPlayer.duration > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { min(audioPosition, audioPlayer.duration) },
                        set: {
                            audioPosition = $0
                            audioPlayer.currentTime = $0
                        }
                    ), in: 0...audioPlayer.duration)
                    .accessibilityLabel("Recording position")
                    .accessibilityValue("\(VoiceNote.Context.clock(audioPosition)) of \(VoiceNote.Context.clock(audioPlayer.duration))")

                    HStack {
                        Text(VoiceNote.Context.clock(audioPosition))
                        Spacer()
                        Text(VoiceNote.Context.clock(audioPlayer.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360)
            }
            }
        }
    }

    private func sourceLabel(_ note: VoiceNote) -> String {
        if note.isWritten { return note.source.map { "Written on \($0.title)" } ?? "Written" }
        return note.source?.title ?? "Captured note"
    }

    @ViewBuilder private func transcript(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.isWritten ? "Note" : "What you said")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(note.displayTitle)
                .font(.title2.weight(.medium))
                .textSelection(.enabled)
            if note.status == .failed {
                Button("Retry transcription") { store.retry(note.id) }
                    .buttonStyle(.secondary)
            }
        }
    }

    private func contextCard(_ context: VoiceNote.Context) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What prompted it")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let podcast = context.podcastTitle {
                Text(podcast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Palette.accent)
            }
            if let episode = context.episodeTitle {
                Text(episode).font(.title3.weight(.semibold))
            }
            if let excerpt = context.transcriptExcerpt, !excerpt.isEmpty {
                Text("“\(excerpt)”")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .italic()
                    .textSelection(.enabled)
            }
            if context.episodeID != nil {
                Button { playFromContext(context) } label: {
                    Label(context.timestamp.map {
                        "Play from \(VoiceNote.Context.clock($0))"
                    } ?? "Play episode", systemImage: "play.circle.fill")
                }
                .buttonStyle(.secondary)
            }
        }
        .padding(DS.Space.l)
        .dsCard()
    }

    private func toggleAudio(_ note: VoiceNote) {
        if playing {
            audioPlayer?.pause()
            playing = false
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        #endif
        if audioPlayer == nil, let url = store.audioURL(for: note) {
            if SpaceSyncFlag.isOn, !FileManager.default.fileExists(atPath: url.path) {
                // Its recording comes down on first use (the data platform), then it plays.
                Task { @MainActor in
                    guard let fetched = await store.ensureAudio(for: note) else { return }
                    audioPlayer = try? AVAudioPlayer(contentsOf: fetched)
                    audioPlayer?.play()
                    playing = audioPlayer?.isPlaying == true
                }
                return
            }
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
        }
        if let audioPlayer, audioPlayer.currentTime >= audioPlayer.duration {
            audioPlayer.currentTime = 0
        }
        audioPlayer?.play()
        playing = audioPlayer?.isPlaying == true
    }

    private func playFromContext(_ context: VoiceNote.Context) {
        guard let episodeID = context.episodeID else { return }
        for podcast in library.podcasts {
            guard let episode = podcast.episode(episodeID) else { continue }
            player.play(episode, in: podcast, autoSleepEligible: false)
            if let timestamp = context.timestamp { player.seek(to: timestamp) }
            return
        }
    }

    private func shareText(_ note: VoiceNote) -> String {
        var parts = [note.displayTitle]
        if let anchor = note.context?.anchorLine { parts.append(anchor) }
        if let excerpt = note.context?.transcriptExcerpt, !excerpt.isEmpty {
            parts.append("“\(excerpt)”")
        }
        return parts.joined(separator: "\n\n")
    }

    private func sourceIcon(_ note: VoiceNote) -> String {
        if note.isWritten { return "square.and.pencil" }
        return switch note.source {
        case .watch: "applewatch"
        case .iPhone: "iphone"
        case nil: "waveform"
        }
    }
}
