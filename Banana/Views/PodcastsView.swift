import SwiftUI

/// The Podcasts tab: subscribed feeds, plus adding a new one by URL.
struct PodcastsView: View {
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var wake: WakeStore
    // Action-only (delete cleanup) — observing the download manager here re-rendered the whole
    // List container on every percent tick. Rows that show download state observe it themselves.
    private var downloads: DownloadManager { WakeCoordinator.shared.downloads }
    @State private var showingAdd = false
    /// The open podcast. In ShellNavigation, not `@State`: the iOS tree is rebuilt after every
    /// trip to the background, and the Mac rebuilds this view whenever the sidebar leaves it.
    @ObservedObject private var shell = ShellNavigation.shared
    @ObservedObject private var toasts = ToastCenter.shared
    private var shows: [Podcast] {
        PendingRemovals.visible(library.podcasts, id: { DeleteUndo.hidingID(podcast: $0.id) }, hiding: toasts.hiddenIDs)
    }
    /// A grid of shows where there's room for one, the list where there isn't
    /// (docs/design/ADAPTIVE-LAYOUT.md).
    @Environment(\.layoutClass) private var layoutClass

    var body: some View {

        let _ = RenderStats.note("PodcastsView")
        Group {
            #if os(macOS)
            NavigationStack { wideLayout }
            #else
            GeometryReader { geometry in
                if LayoutClass(width: geometry.size.width) == .regular {
                    wideLayout
                } else {
                    NavigationStack(path: $shell.state.library) {
                        podcastList(wide: false)
                            .navigationDestination(for: UUID.self) { PodcastDetailView(podcastID: $0) }
                    }
                }
            }
            #endif
        }
            .onAdd(.podcast) { _ in showingAdd = true }
            .sheet(isPresented: $showingAdd) {
                AddPodcastSheet()
            }
            .alert(
                "Podcast",
                isPresented: Binding(
                    get: { library.errorMessage != nil },
                    set: { if !$0 { library.errorMessage = nil } }
                ),
                actions: { Button("OK", role: .cancel) { library.errorMessage = nil } },
                message: { Text(library.errorMessage ?? "") }
            )
        .task {
            downloads.startPeerSharing()
            // A podcast unsubscribed in the meantime shouldn't reopen as "Podcast unavailable".
            let kept = ShellState.pruned(shell.state.library, known: Set(library.podcasts.map(\.id)))
            if kept != shell.state.library { shell.state.library = kept }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--library-detail"),
               let firstPodcastID = library.podcasts.first?.id {
                shell.state.library = [firstPodcastID]
            }
            #endif
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(get: { shell.state.library.last }, set: { shell.state.library = $0.map { [$0] } ?? [] })
    }

    private var wideLayout: some View {
        WorkspaceColumns {
            podcastList(wide: true)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            NavigationStack {
                if let id = shell.state.library.last, library.podcast(id) != nil {
                    PodcastDetailView(podcastID: id)
                        .id(id)
                } else {
                    ContentUnavailableView("Select a podcast", systemImage: "headphones",
                        description: Text("Choose a show to browse its episodes."))
                }
            }
        }
    }

    private func podcastList(wide: Bool) -> some View {
            Group {
                if shows.isEmpty {
                    emptyState
                } else if layoutClass == .regular {
                    showGrid
                } else {
                    List(selection: wide ? selectionBinding : nil) {
                        ForEach(shows) { podcast in
                            Group {
                                if wide {
                                    PodcastRow(podcast: podcast, isWake: wake.isWakePodcast(podcast.id))
                                        .tag(podcast.id)
                                } else {
                                    NavigationLink(value: podcast.id) {
                                        PodcastRow(podcast: podcast, isWake: wake.isWakePodcast(podcast.id))
                                    }
                                }
                            }
                            // Press-and-hold offers what the swipe does, as the grid's rows do.
                            .contextMenu {
                                Button("Unsubscribe", systemImage: "trash", role: .destructive) { unsubscribe(podcast.id) }
                            }
                        }
                        .onDelete { indexSet in
                            for id in indexSet.map({ shows[$0].id }) { unsubscribe(id) }
                        }
                    }
                    .listStyle(.plain)
                    .tint(.gray)
                    .accessibilityIdentifier("library.list")
                    .refreshable {
                        // Explicit gesture — skip the staleness throttle and re-apply the
                        // auto-download rules so new episodes start fetching right away.
                        await downloads.refreshFeedsAndReconcile(force: true)
                    }
                }
            }
            .navigationTitle("Library")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // What you've listened to, and where, is looking back: in Review (the chart
            // button), under Listening. It was a clock menu here, and in Settings before that.
            .toolbar {
                ReviewToolbarItem(section: .library)
                #if os(iOS)
                ToolbarItem(placement: .automatic) { MoreMenu() }
                #endif
            }
            .addButton(identifier: "library.add") { showingAdd = true }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No podcasts yet", systemImage: "waveform")
        } description: {
            Text("Search for any show by name.")
        } actions: {
            // Ink on the accent, like every other main button: the system's white label on this
            // orange is 2.3:1.
            Button("Add podcast") { showingAdd = true }
                .buttonStyle(AppButtonStyle(kind: .primary))
        }
    }
}

extension PodcastsView {
    /// The wide arrangement: shows as cards, as many across as fit. A list of one-line rows
    /// stretched across an iPad left most of the screen empty.
    var showGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: DS.Space.xl, alignment: .top)],
                      alignment: .leading, spacing: DS.Space.xl) {
                ForEach(shows) { podcast in
                    NavigationLink(value: podcast.id) {
                        PodcastCard(podcast: podcast, isWake: wake.isWakePodcast(podcast.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { unsubscribe(podcast.id) } label: {
                            Label("Unsubscribe", systemImage: "trash")
                        }
                    }
                    .accessibilityIdentifier("library.card")
                }
            }
            .padding(DS.Space.xl)
        }
        .refreshable { await downloads.refreshFeedsAndReconcile(force: true) }
    }

    /// As swipe-to-delete does in the list.
    func unsubscribe(_ id: UUID) {
        guard let podcast = library.podcast(id) else { return }
        let library = library, wake = wake, downloads = downloads
        DeleteUndo.podcast(podcast) {
            if let podcast = library.podcast(id) { downloads.removeAllDownloads(for: podcast) }
            wake.clearIfPodcast(id)
            library.remove(id)
        }
    }
}

/// A show in the Library's grid: its artwork, its name, and how many episodes are unplayed.
struct PodcastCard: View {
    let podcast: Podcast
    let isWake: Bool

    private var unplayed: Int {
        podcast.episodes.filter { !podcast.completed.contains($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Artwork(url: podcast.artworkURL, size: 150, fallbackSeed: podcast.title)
                .overlay(alignment: .topTrailing) {
                    if unplayed > 0 {
                        Text("\(unplayed)")
                            .font(.footnote.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.hair)
                            .background(DS.Palette.accent, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(DS.Space.s)
                    }
                }
            HStack(spacing: DS.Space.xs) {
                Text(podcast.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if isWake { Image(systemName: "alarm.fill").font(.caption).foregroundStyle(DS.Palette.accent) }
            }
            if let author = podcast.author {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PodcastRow: View {
    @EnvironmentObject var downloads: DownloadManager
    let podcast: Podcast
    let isWake: Bool

    @State private var unplayed = 0
    @State private var downloaded = 0
    private struct CountsKey: Hashable {
        let episodes: String
        let completed: Set<String>
        let downloads: Int
    }

    private var subtitle: String {
        let count = podcast.episodeCount == 1 ? "1 episode" : "\(podcast.episodeCount) episodes"
        guard let latest = podcast.latestEpisodeDate else { return count }
        return "\(count) · Updated \(latest.formatted(.relative(presentation: .named)))"
    }

    /// "810 episodes · Updated 2 days ago · ⬇ 15" as one run of text, so it wraps as a sentence.
    /// The count used to be a separate Label beside it, which squeezed the text into a column
    /// and pulled the row's separator over to itself.
    private var detailLine: Text {
        // The unplayed count is the badge on the right; this line says how fresh the show is
        // instead of repeating it.
        let base = Text(subtitle)
        guard downloaded > 0 else { return base }
        return base + Text(" \u{00B7} ")
            + Text(Image(systemName: "arrow.down.circle.fill")).foregroundStyle(DS.Palette.success)
            + Text(" \(downloaded)").foregroundStyle(DS.Palette.success)
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Artwork(url: podcast.artworkURL, size: 56, fallbackSeed: podcast.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title).font(.headline).lineLimit(1)
                if let author = podcast.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                detailLine
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            // The separator starts under the title on every row. Left to SwiftUI, it lined up
            // with whichever text it found first — the download count, or text inside the
            // artwork — so each row's line started somewhere different.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer()
            if isWake {
                Image(systemName: "alarm.fill").foregroundStyle(DS.Palette.accent)
            }
            if unplayed > 0 {
                Text("\(unplayed)")
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.hair)
                    .background(DS.Palette.accent.opacity(DS.Tint.soft), in: Capsule())
                    .foregroundStyle(DS.Palette.accent)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("library.podcast.\(podcast.id.uuidString)")
        .task(id: CountsKey(episodes: podcast.episodeRevision, completed: podcast.completed,
                           downloads: downloads.catalogRevision)) {
            let downloadedIDs = downloads.downloadedEpisodeIDs
            let completed = podcast.completed
            let counts = await Task.detached(priority: .utility) {
                let ids = podcast.episodeIDs()
                return (ids.subtracting(completed).count, ids.intersection(downloadedIDs).count)
            }.value
            guard !Task.isCancelled else { return }
            if unplayed != counts.0 { unplayed = counts.0 }
            if downloaded != counts.1 { downloaded = counts.1 }
        }
    }
}

/// Sheet to find and subscribe to a podcast by searching the iTunes directory
/// (or pasting a raw RSS URL as a fallback).
struct AddPodcastSheet: View {
    var initialQuery = ""
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var wake: WakeStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var subscribing = false

    static let sleepSuggestions = [
        "Nothing Much Happens", "Get Sleepy", "Sleep With Me",
        "Boring Books for Bedtime", "Slow Radio", "LibriVox Audiobooks",
    ]

    var body: some View {
        NavigationStack {
            List {
                if looksLikeURL {
                    Section {
                        Button { subscribe(to: query) } label: {
                            Label("Add feed directly", systemImage: "link")
                        }
                        .tint(DS.Palette.accent)
                    } footer: {
                        Text(query)
                    }
                }
                if query.isEmpty && results.isEmpty {
                    Section {
                        ForEach(Self.sleepSuggestions, id: \.self) { name in
                            Button { query = name } label: {
                                Label(name, systemImage: "moon.stars.fill")
                            }
                            .tint(.indigo)
                        }
                    } header: {
                        Text("Sleep stories")
                    } footer: {
                        Text("Free calming feeds — tap to search and add.")
                    }
                }
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    Button { subscribe(to: result.feedURL.absoluteString) } label: {
                        resultRow(result).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(subscribing)
                    .listRowSeparator(index == 0 && !looksLikeURL ? .hidden : .automatic, edges: .top)
                }
            }
            .listStyle(.plain)
            .overlay { statusOverlay }
            .navigationTitle("Add podcast")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search podcasts, or paste an RSS URL")
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
            .onAppear { if query.isEmpty && !initialQuery.isEmpty { query = initialQuery } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .interactiveDismissDisabled(subscribing)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func resultRow(_ result: PodcastSearchResult) -> some View {
        HStack(spacing: 12) {
            Artwork(url: result.artworkURL, size: 52, fallbackSeed: result.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                if !result.author.isEmpty {
                    Text(result.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "plus.circle.fill").foregroundStyle(DS.Palette.accent)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusOverlay: some View {
        if subscribing {
            VStack(spacing: 10) {
                ProgressView()
                Text("Subscribing…").font(.subheadline).foregroundStyle(.secondary)
            }
        } else if isSearching {
            ProgressView()
        } else if results.isEmpty && !looksLikeURL && !query.isEmpty {
            // Only when a search returned nothing — the Sleep-stories section already
            // fills the empty-query state (overlaying here would stack on top of it).
            ContentUnavailableView.search(text: query)
        }
    }

    private var looksLikeURL: Bool { query.contains("://") }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            isSearching = true
            let found = (try? await PodcastSearch.search(trimmed)) ?? []
            if Task.isCancelled { return }
            results = found
            isSearching = false
        }
    }

    private func subscribe(to feedURL: String) {
        subscribing = true
        Task {
            let newID = await library.addPodcast(from: feedURL)
            // First subscription becomes the wake source by default.
            if let newID, wake.source == nil { wake.setPodcast(newID) }
            subscribing = false
            if library.errorMessage == nil { dismiss() }
        }
    }
}

/// Cached artwork (disk + memory via `ImageCache`) with a placeholder — fetches
/// each image at most once instead of re-pulling it over Wi-Fi on every appearance.
struct Artwork: View {
    let url: URL?
    var size: CGFloat
    var fallbackSeed: String?
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    init(url: URL?, size: CGFloat, fallbackSeed: String? = nil) {
        self.url = url
        self.size = size
        self.fallbackSeed = fallbackSeed
        // Synchronous memory-cache check: `.task` runs after first layout, so even artwork
        // already decoded in memory flashed the placeholder for a frame and popped. A hit here
        // renders on the very first pass; misses keep the async disk/network path.
        _image = State(initialValue: url.flatMap {
            ImageCache.shared.memoryImage(
                for: $0,
                targetPixelSize: size * Self.initialDisplayScale)
        })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let fallbackSeed, !fallbackSeed.isEmpty {
                fallbackArtwork(for: fallbackSeed)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DS.artworkRadius(for: size), style: .continuous))
        // A hairline edge, so a white cover doesn't dissolve into a light background (or a dark
        // one into a dark background).
        .overlay(RoundedRectangle(cornerRadius: DS.artworkRadius(for: size), style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .task(id: "\(url?.absoluteString ?? "none")|\(displayScale)") {
            guard let url else { image = nil; return }
            let targetPixels = size * displayScale
            if let hit = ImageCache.shared.memoryImage(
                for: url,
                targetPixelSize: targetPixels) {
                image = hit
            } else {
                image = await ImageCache.shared.image(
                    for: url,
                    targetPixelSize: targetPixels)
            }
        }
    }

    private func fallbackArtwork(for seed: String) -> some View {
        let colors: [Color] = [.orange, .indigo, .teal, .pink, .blue, .purple]
        let scalarSum = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let color = colors[scalarSum % colors.count]
        let initials = seed.split(separator: " ").prefix(2).compactMap(\.first)
        return ZStack {
            color.opacity(0.82)
            Text(String(initials))
                .font(.system(size: max(12, size * 0.30), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private static var initialDisplayScale: CGFloat {
        #if os(iOS)
        // iPhone artwork is normally 3x. The environment-provided exact scale takes over in the
        // view task; this value only enables a no-placeholder first frame on a warm cache.
        return 3
        #else
        return 2
        #endif
    }
}
