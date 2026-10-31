import MusicKit
import SwiftUI
import Combine

/// Wraps MusicKit: authorization, subscription status, browsing the user's
/// Apple Music library (playlists / albums / songs), and playing a chosen
/// item as wake content via the system Music player.
///
/// Note: MusicKit playback requires an active Apple Music subscription and the
/// app's App ID to have the MusicKit service enabled. It does not work in the
/// Simulator — test on a device signed into Apple Music.
@MainActor
final class MusicController: ObservableObject {
    @Published var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @Published var hasSubscription = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var playlists: [MusicWakeItem] = []
    @Published var albums: [MusicWakeItem] = []
    @Published var songs: [MusicWakeItem] = []

    var isAuthorized: Bool { authorization == .authorized }

    /// Re-read the system status. `authorization` is seeded once at init and otherwise only
    /// written by `requestAuthorization`, so revoking access in Settings left the app believing
    /// it still had permission until the next launch. Called on foreground; a no-op when
    /// nothing moved, and it loads the library when access has just appeared.
    func syncAuthorization() async {
        let current = MusicAuthorization.currentStatus
        guard current != authorization else { return }
        authorization = current
        if isAuthorized {
            await refreshSubscription()
            await loadLibrary()
        }
    }

    init() {
        // The property initializer above already read MusicAuthorization.currentStatus —
        // this mark exists to price that read in the launch trace.
        LaunchClock.mark("music.init")
    }

    private enum MusicError: LocalizedError {
        case notFound
        var errorDescription: String? { "That item could not be found in your Apple Music library." }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        authorization = await MusicAuthorization.request()
        if isAuthorized {
            await refreshSubscription()
            await loadLibrary()
        }
    }

    func refreshSubscription() async {
        do {
            let sub = try await MusicSubscription.current
            hasSubscription = sub.canPlayCatalogContent
        } catch {
            hasSubscription = false
        }
    }

    // MARK: - Browsing the library

    func loadLibrary() async {
        guard isAuthorized else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var playlistReq = MusicLibraryRequest<Playlist>()
            playlistReq.limit = 100
            let playlistItems = try await playlistReq.response().items
            playlists = playlistItems.map {
                MusicWakeItem(kind: .playlist, id: $0.id.rawValue, title: $0.name, subtitle: $0.curatorName)
            }

            var albumReq = MusicLibraryRequest<Album>()
            albumReq.limit = 100
            let albumItems = try await albumReq.response().items
            albums = albumItems.map {
                MusicWakeItem(kind: .album, id: $0.id.rawValue, title: $0.title, subtitle: $0.artistName)
            }

            var songReq = MusicLibraryRequest<Song>()
            songReq.limit = 100
            let songItems = try await songReq.response().items
            songs = songItems.map {
                MusicWakeItem(kind: .song, id: $0.id.rawValue, title: $0.title, subtitle: $0.artistName)
            }
        } catch {
            errorMessage = "Couldn't load your Apple Music library: \(error.localizedDescription)"
        }
    }

    // MARK: - Playback

    // The system player, deliberately: playback runs in the Music app's process, so it starts
    // from a background-launched alarm stop intent and KEEPS PLAYING if this process is
    // suspended moments after the intent returns. ApplicationMusicPlayer plays in-process and
    // guaranteed neither — the intent would churn the audio session and produce no sound
    // until the app was foregrounded. (macOS has no system player; the Mac never wakes.)
    #if os(iOS)
    private typealias WakePlayer = SystemMusicPlayer
    #else
    private typealias WakePlayer = ApplicationMusicPlayer
    #endif

    /// The wake item currently playing (drives the in-app bar + briefing card). `nil` once
    /// playback stops anywhere — our Stop button, the Lock Screen, or the Music app.
    @Published private(set) var wakePlaying: MusicWakeItem?
    private var wakeStateWatch: AnyCancellable?
    private var lastWakeStart: Date?

    /// Play a previously-chosen wake item (called after an alarm fires).
    ///
    /// Callers on the alarm path must AWAIT this (no fire-and-forget Task): the stop intent's
    /// process is only kept alive until `perform()` returns, and the queue build + play round-trip
    /// is exactly the work that got cut off when the intent returned early.
    func playWake(_ item: MusicWakeItem) async {
        guard isAuthorized else {
            PlaybackDiagnostics.shared.log("WAKE MUSIC skipped", "MusicKit not authorized")
            return
        }
        // Once per wake: the stop intent starts this in the background, then the on-open path
        // asks again minutes later. Restarting the song from zero — or resurrecting one the
        // user already stopped from the Lock Screen — is not what "idempotent" means.
        if let started = lastWakeStart, Date().timeIntervalSince(started) < 30 * 60 {
            PlaybackDiagnostics.shared.log("WAKE MUSIC skipped", "already started \(Int(Date().timeIntervalSince(started)))s ago")
            return
        }
        let player = WakePlayer.shared
        do {
            // Playlists shuffle; albums and single songs don't. A playlist is a pool to draw from,
            // and hearing the same track open every routine is what makes a routine stale. An
            // album is a running order someone chose, so scrambling it would be a bug.
            var shuffled = false
            switch item.kind {
            case .song:
                guard let song = try await librarySong(id: item.id) else { throw MusicError.notFound }
                player.queue = WakePlayer.Queue(arrayLiteral: song)
            case .album:
                guard let album = try await libraryAlbum(id: item.id) else { throw MusicError.notFound }
                let full = try await album.with(.tracks)
                guard let first = full.tracks?.first else { throw MusicError.notFound }
                player.queue = WakePlayer.Queue(album: full, startingAt: first)
            case .playlist:
                guard let playlist = try await libraryPlaylist(id: item.id) else { throw MusicError.notFound }
                let full = try await playlist.with(.entries)
                // Random STARTING entry, not just shuffleMode. Shuffle reorders what follows but
                // leaves the queue's starting item where it is, so on its own it would still have
                // opened with the same song every time — the actual complaint.
                guard let start = full.entries?.randomElement() else { throw MusicError.notFound }
                player.queue = WakePlayer.Queue(playlist: full, startingAt: start)
                shuffled = true
            }
            // Set every time, not only when turning it on. ApplicationMusicPlayer is a singleton
            // whose shuffle mode outlives the play that set it, so a playlist would otherwise
            // leave shuffle armed and scramble the next album.
            player.state.shuffleMode = shuffled ? .songs : .off
            try await player.play()
            lastWakeStart = Date()
            wakePlaying = item
            watchWakePlayback()
            PlaybackDiagnostics.shared.log("WAKE MUSIC playing", "\"\(item.title)\"")
        } catch {
            PlaybackDiagnostics.shared.log("WAKE MUSIC FAILED", error.localizedDescription)
            errorMessage = "Couldn't play Apple Music: \(error.localizedDescription)"
        }
    }

    /// Stop the wake music (the in-app bar's Stop button).
    func stopWake() {
        WakePlayer.shared.pause()
        wakePlaying = nil
        wakeStateWatch = nil
        PlaybackDiagnostics.shared.log("WAKE MUSIC stopped", "by=user")
    }

    /// Re-check reality on foreground: if the music was stopped while this process was
    /// suspended (Lock Screen, Music app), the state watch never ran — drop the stale bar.
    func reconcileWakeState() {
        guard wakePlaying != nil, WakePlayer.shared.state.playbackStatus != .playing else { return }
        wakePlaying = nil
        wakeStateWatch = nil
    }

    /// Track the player so the bar disappears when playback ends anywhere, not just via our
    /// Stop button. (objectWillChange fires pre-change; the main-queue hop reads post-change.)
    private func watchWakePlayback() {
        wakeStateWatch = WakePlayer.shared.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.wakePlaying != nil else { return }
                switch WakePlayer.shared.state.playbackStatus {
                case .paused, .stopped, .interrupted:
                    self.wakePlaying = nil
                    self.wakeStateWatch = nil
                default:
                    break
                }
            }
    }

    // MARK: - Reconstructing library items by id

    private func libraryPlaylist(id: String) async throws -> Playlist? {
        var req = MusicLibraryRequest<Playlist>()
        req.limit = 100
        return try await req.response().items.first { $0.id.rawValue == id }
    }

    private func libraryAlbum(id: String) async throws -> Album? {
        var req = MusicLibraryRequest<Album>()
        req.limit = 100
        return try await req.response().items.first { $0.id.rawValue == id }
    }

    private func librarySong(id: String) async throws -> Song? {
        var req = MusicLibraryRequest<Song>()
        req.limit = 100
        return try await req.response().items.first { $0.id.rawValue == id }
    }
}
