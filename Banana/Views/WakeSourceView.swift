import SwiftUI

/// Choose what plays after an alarm rings: nothing, a subscribed podcast, or an
/// Apple Music playlist / album / song.
struct WakeSourceView: View {
    var slot: SourceSlot = .wake
    @EnvironmentObject var wake: WakeStore
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var music: MusicController
    @State private var showAddSleep = false
    @State private var sleepQuery = ""

    var body: some View {
        List {
            if slot == .sleep {
                Section {
                    Menu {
                        ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                            Button("\(minutes) minutes") {
                                Task { await WakeCoordinator.shared.play(slot: .sleep, reason: "sleep-button", sleepTimerMinutes: minutes) }
                            }
                        }
                    } label: {
                        Label("Play to sleep", systemImage: "moon.zzz.fill")
                    }
                    .tint(DS.Palette.Feature.wake)
                    .disabled(wake.source(for: .sleep) == nil)
                } footer: {
                    Text("Plays your Sleep source and fades out after the time you pick.")
                }
            }

            Section {
                selectableRow(title: "None", subtitle: "Nothing", systemImage: "bell.slash",
                              selected: wake.source(for: slot) == nil) {
                    wake.clear(slot)
                }
            } footer: {
                Text(slot.blurb)
            }

            Section("Podcasts") {
                if library.podcasts.isEmpty {
                    Text("No podcasts yet — add one below or in the Podcasts tab.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(library.podcasts) { podcast in
                    Button {
                        // Tap the selected show again to deselect it.
                        if wake.isPodcast(podcast.id, for: slot) {
                            wake.clear(slot)
                        } else {
                            wake.setPodcast(podcast.id, for: slot)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Artwork(url: podcast.artworkURL, size: 40)
                            rowContent(title: podcast.title, subtitle: "Next episode",
                                       selected: wake.isPodcast(podcast.id, for: slot))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if slot == .sleep {
                Section {
                    ForEach(AddPodcastSheet.sleepSuggestions, id: \.self) { name in
                        Button {
                            sleepQuery = name
                            showAddSleep = true
                        } label: {
                            Label(name, systemImage: "moon.stars.fill")
                        }
                        .tint(DS.Palette.Feature.wake)
                    }
                } header: {
                    Text("Suggested sleep shows")
                } footer: {
                    Text("Free calming feeds — add one, then select it above.")
                }
            }

            Section {
                if !music.isAuthorized {
                    Button {
                        Task { await music.requestAuthorization() }
                    } label: {
                        Label("Connect Apple Music", systemImage: "music.note")
                    }
                    .tint(DS.Palette.accent)
                } else {
                    NavigationLink {
                        MusicPickerList(kind: .playlist, items: music.playlists, slot: slot)
                    } label: { Label("Playlists", systemImage: "music.note.list") }
                    NavigationLink {
                        MusicPickerList(kind: .album, items: music.albums, slot: slot)
                    } label: { Label("Albums", systemImage: "square.stack") }
                    NavigationLink {
                        MusicPickerList(kind: .song, items: music.songs, slot: slot)
                    } label: { Label("Songs", systemImage: "music.note") }

                    if let item = wake.appleMusicItem(for: slot) {
                        rowContent(title: item.title, subtitle: "Selected · \(item.kind.rawValue)", selected: true)
                    }
                }
            } header: {
                Text("Apple Music")
            } footer: {
                if !music.hasSubscription && music.isAuthorized {
                    Text("An active Apple Music subscription is required to play.")
                }
            }
        }
        .navigationTitle("\(slot.label) source")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddSleep) { AddPodcastSheet(initialQuery: sleepQuery) }
        .task {
            if music.isAuthorized && music.playlists.isEmpty { await music.loadLibrary() }
        }
        .alert(
            "Apple Music",
            isPresented: Binding(
                get: { music.errorMessage != nil },
                set: { if !$0 { music.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { music.errorMessage = nil } },
            message: { Text(music.errorMessage ?? "") }
        )
    }

    private func selectableRow(title: String, subtitle: String, systemImage: String,
                               selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 24)
                rowContent(title: title, subtitle: subtitle, selected: selected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowContent(title: String, subtitle: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.accent)
            }
        }
    }
}

/// A flat list of Apple Music library items of one kind; tapping selects it as
/// the wake source.
struct MusicPickerList: View {
    let kind: MusicWakeItem.Kind
    let items: [MusicWakeItem]
    var slot: SourceSlot = .wake
    @EnvironmentObject var wake: WakeStore
    @EnvironmentObject var music: MusicController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(items) { item in
            Button {
                wake.setAppleMusic(item, for: slot)
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
                    if wake.appleMusicItem(for: slot) == item {
                        Image(systemName: "checkmark").foregroundStyle(DS.Palette.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(title)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: kind == .playlist ? "music.note.list" : "music.note",
                                       description: Text("No \(title.lowercased()) found in your Apple Music library."))
            }
        }
        .refreshable { await music.loadLibrary() }
    }

    private var title: String {
        switch kind {
        case .playlist: return "Playlists"
        case .album: return "Albums"
        case .song: return "Songs"
        }
    }
}
