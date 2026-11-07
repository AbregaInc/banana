#if os(iOS)
import Combine
import SwiftUI
import UIKit

// The compact-width shell (docs/design/BOTTOM-BAR-SHELL.md): one bar at the bottom of the screen
// in place of the tab bar and every top button row. The page switcher at the left, "Search or
// ask" across the middle, the assistant at the right; the podcast player sits just above it.
// Glass is on this navigation layer only, from the system (`.glassEffect`, `.buttonStyle(.glass)`).

/// What the bar shows besides the field. Its own object: opening the switcher or hiding the player
/// redraws the bar and the overlay, never the page.
@MainActor
final class ShellChrome: ObservableObject {
    static let shared = ShellChrome()

    @Published var switcherOpen = false
    /// The player is folded into the small artwork at the left of the field.
    @Published var playerHidden = false
    /// A keyboard is up for something other than the field (a note, a form): the bar steps away.
    @Published private(set) var keyboardUp = false
    /// The height of the bar and the player above it, for what is laid out over the page.
    @Published private(set) var barHeight: CGFloat = 76

    private var loadedEpisode: String?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if !ShellChrome.shared.keyboardUp { ShellChrome.shared.keyboardUp = true } }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if ShellChrome.shared.keyboardUp { ShellChrome.shared.keyboardUp = false } }
        })
    }

    func setBarHeight(_ height: CGFloat) {
        let rounded = height.rounded()
        if abs(rounded - barHeight) >= 1 { barHeight = rounded }
    }

    /// A new episode shows its capsule again; the same one keeps what was chosen.
    func episodeChanged(_ id: String?) {
        let hidden = ShellPlayerPlacement.hiddenAfterLoad(previous: loadedEpisode, current: id, hidden: playerHidden)
        loadedEpisode = id
        if hidden != playerHidden { playerHidden = hidden }
    }
}

/// The height of the bar's round buttons and field.
private enum ShellMetrics {
    static let control: CGFloat = 52
    static let gutter: CGFloat = DS.Space.l
    static let spacing: CGFloat = DS.Space.m
}

// MARK: - The bar

/// The bar, except while a keyboard is up for something else (a note, a form): the bar would
/// ride up on it and cover what is being written.
struct ShellBarHost: View {
    let section: AppSection
    let pages: [ShellPage]
    let open: (ShellPage) -> Void
    let expandPlayer: () -> Void
    @ObservedObject private var chrome = ShellChrome.shared
    @ObservedObject private var search = ShellSearch.shared

    var body: some View {
        if !chrome.keyboardUp || search.focused {
            ShellBottomBar(section: section, pages: pages, open: open, expandPlayer: expandPlayer)
        }
    }
}

struct ShellBottomBar: View {
    /// The page showing.
    let section: AppSection
    let pages: [ShellPage]
    let open: (ShellPage) -> Void
    /// The full player.
    let expandPlayer: () -> Void

    @ObservedObject private var chrome = ShellChrome.shared
    @ObservedObject private var search = ShellSearch.shared
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var music: MusicController

    var body: some View {
        let _ = RenderStats.note("ShellBottomBar")
        let mode = search.mode
        let placement = ShellPlayerPlacement.of(loaded: player.currentEpisode != nil,
                                                hidden: chrome.playerHidden,
                                                fieldInUse: mode.hidesSideButtons)
        VStack(spacing: DS.Space.s) {
            if placement == .capsule {
                ShellPlayerCapsule(expand: expandPlayer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if player.currentEpisode == nil, music.wakePlaying != nil, !mode.hidesSideButtons {
                MusicWakeBar()
                    .frame(height: ShellMetrics.control)
                    .glassEffect(.regular, in: .capsule)
            }
            GlassEffectContainer(spacing: ShellMetrics.spacing) {
                HStack(spacing: ShellMetrics.spacing) {
                    if !mode.hidesSideButtons {
                        switcherButton
                    }
                    ShellFieldRow(section: section, search: search, showsChip: placement == .chip)
                    if !mode.hidesSideButtons, ShellAssistant.isAvailable {
                        roundButton("sparkle", label: "Ask Banana", identifier: "shell.ai") {
                            chrome.switcherOpen = false
                            ShellAssistant.open()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, ShellMetrics.gutter)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.xs)
        .animation(.snappy(duration: 0.25), value: placement)
        .animation(.snappy(duration: 0.25), value: mode.hidesSideButtons)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chrome.setBarHeight($0) }
        .onChange(of: player.currentEpisode?.id, initial: true) { _, id in chrome.episodeChanged(id.map { "\($0)" }) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.bar")
    }

    private var switcherButton: some View {
        roundButton(chrome.switcherOpen ? "xmark" : "circle.grid.3x3.fill",
                    label: chrome.switcherOpen ? "Close pages" : "Pages",
                    identifier: "shell.switcher") {
            withAnimation(.snappy(duration: 0.28)) { chrome.switcherOpen.toggle() }
        }
        .accessibilityValue(chrome.switcherOpen ? "Open" : "Closed")
    }

    private func roundButton(_ symbol: String, label: String, identifier: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: ShellMetrics.control - 12, height: ShellMetrics.control - 12)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(DS.Palette.accent)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The field, and in an open conversation the round Archive beside it. Mail's reader is watched
/// here and not by the bar, so a conversation opening redraws this row only.
private struct ShellFieldRow: View {
    let section: AppSection
    @ObservedObject var search: ShellSearch
    let showsChip: Bool

    var body: some View {
        #if BANANA_UNRELEASED
        if section == .mail {
            MailReaderAware { reader in
                if let reader {
                    replyField(reader)
                } else {
                    ShellField(search: search, showsChip: showsChip)
                }
            }
        } else {
            ShellField(search: search, showsChip: showsChip)
        }
        #else
        ShellField(search: search, showsChip: showsChip)
        #endif
    }

    #if BANANA_UNRELEASED
    /// In an open conversation the field starts a reply, and Archive sits beside it.
    @ViewBuilder private func replyField(_ session: MailSession) -> some View {
        Button { session.reply(.reply) } label: {
            HStack(spacing: DS.Space.s) {
                if showsChip { ShellPlayerChip() }
                Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
                Text("Reply or ask").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(maxWidth: .infinity, minHeight: ShellMetrics.control)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(!session.allowsComposing)
        .accessibilityLabel("Reply")
        .accessibilityIdentifier("shell.reply")
        Button { session.act(.done) } label: {
            Image(systemName: "checkmark")
                .font(.title3.weight(.semibold))
                .frame(width: ShellMetrics.control - 12, height: ShellMetrics.control - 12)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(DS.Palette.accent)
        .disabled(!session.canPerform(.done))
        .accessibilityLabel("Archive")
        .accessibilityIdentifier("shell.archive")
    }
    #endif
}

#if BANANA_UNRELEASED
/// Hands its content the Mail session while a conversation is open over the list, else nil.
struct MailReaderAware<Content: View>: View {
    @ObservedObject private var application = MailApplication.shared
    @ViewBuilder let content: (MailSession?) -> Content

    var body: some View {
        if let session = application.session {
            Watching(navigation: session.navigation, session: session, content: content)
        } else {
            content(nil)
        }
    }

    private struct Watching: View {
        @ObservedObject var navigation: MailNavigation
        let session: MailSession
        let content: (MailSession?) -> Content
        var body: some View { content(navigation.reader == nil ? nil : session) }
    }
}
#endif

/// "Search or ask": the field itself. Focusing it raises the keyboard; what it finds is shown
/// over the page (`ShellResultsOverlay`).
struct ShellField: View {
    @ObservedObject var search: ShellSearch
    var showsChip = false
    var prompt = "Search or ask"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if showsChip { ShellPlayerChip() }
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $search.text)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit {
                    // Return with words and an assistant asks; without one it only searches.
                    if ShellAssistant.isAvailable, ShellSearchRules.query(search.text) != nil, search.groups.isEmpty {
                        search.ask()
                    }
                }
                .accessibilityIdentifier("shell.field")
            if !search.text.isEmpty || focused {
                Button { search.clear() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(search.text.isEmpty ? "Close search" : "Clear")
                .accessibilityIdentifier("shell.field.clear")
            }
        }
        .padding(.leading, showsChip ? DS.Space.xs : DS.Space.l)
        .padding(.trailing, DS.Space.m)
        .frame(maxWidth: .infinity, minHeight: ShellMetrics.control)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .glassEffect(.regular.interactive(), in: .capsule)
        .onChange(of: search.text) { _, _ in search.textChanged() }
        .onChange(of: focused) { _, now in
            if search.focused != now { search.focused = now }
            if now { ShellChrome.shared.switcherOpen = false }
        }
        .onReceive(search.focusRequests) { focused = $0 }
    }
}

// MARK: - The switcher

/// The pages, in a column of round buttons rising from the switcher; the rest of the screen dims.
struct ShellSwitcherOverlay: View {
    let pages: [ShellPage]
    let current: ShellPage?
    let open: (ShellPage) -> Void
    @ObservedObject private var chrome = ShellChrome.shared

    var body: some View {
        if chrome.switcherOpen {
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .accessibilityLabel("Close pages")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("shell.switcher.dim")
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(pages.reversed()) { page in
                        Button {
                            close()
                            open(page)
                        } label: {
                            HStack(spacing: DS.Space.m) {
                                Image(systemName: page.symbol)
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(page == current ? DS.Palette.accent : Color.primary)
                                    .frame(width: ShellMetrics.control, height: ShellMetrics.control)
                                    .glassEffect(page == current ? .regular.tint(DS.Palette.accent.opacity(0.25)).interactive()
                                                                 : .regular.interactive(), in: .circle)
                                Text(page.title)
                                    .font(.body.weight(page == current ? .semibold : .regular))
                                    .foregroundStyle(page == current ? DS.Palette.accent : Color.primary)
                                    .padding(.horizontal, DS.Space.m)
                                    .padding(.vertical, DS.Space.xs + 2)
                                    .glassEffect(.regular, in: .capsule)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(page.title)
                        .accessibilityAddTraits(page == current ? .isSelected : [])
                        .accessibilityIdentifier("shell.page.\(page.rawValue)")
                    }
                }
                .padding(.leading, ShellMetrics.gutter)
                .padding(.bottom, chrome.barHeight + DS.Space.s)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shell.switcher.pages")
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.25)) { chrome.switcherOpen = false }
    }
}

// MARK: - The results

/// What the field found, over the page and above the bar. Solid: it is content, not navigation.
struct ShellResultsOverlay: View {
    let section: AppSection
    /// The height of a page's top row (the navigation bar) under the status bar.
    private static let topRow: CGFloat = 54
    @ObservedObject private var search = ShellSearch.shared
    @ObservedObject private var chrome = ShellChrome.shared

    var body: some View {
        if search.mode != .idle {
            ShellSearchResults(search: search, section: section)
                .background(Color(.systemBackground))
                // The page's top row stays in view above it, as in the approved design.
                .padding(.top, Self.topRow)
                // Down to the field: the bar's top padding is open page otherwise.
                .padding(.bottom, chrome.barHeight - DS.Space.s)
                .transition(.opacity)
        }
    }
}

// MARK: - The player

/// The episode loaded: a slim capsule above the bar. Tap opens the player; the chevron folds it
/// into the field. The 1 Hz playhead redraws only the progress line, never the bar.
struct ShellPlayerCapsule: View {
    let expand: () -> Void
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: PodcastLibrary

    var body: some View {
        let _ = RenderStats.note("ShellPlayerCapsule")
        if let episode = player.currentEpisode {
            let podcast = player.currentPodcastID.flatMap { library.podcast($0) }
            HStack(spacing: DS.Space.m) {
                Button(action: expand) {
                    HStack(spacing: DS.Space.m) {
                        Artwork(url: podcast?.artworkURL, size: 40, fallbackSeed: podcast?.title)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(podcast?.title ?? episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(episode.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(podcast?.title ?? ""), \(episode.title)")
                .accessibilityHint("Opens the player")
                .accessibilityIdentifier("shell.player.open")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("shell.player.play")
                Button {
                    withAnimation(.snappy(duration: 0.25)) { ShellChrome.shared.playerHidden = true }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide player")
                .accessibilityIdentifier("shell.player.hide")
            }
            .tint(.primary)
            .padding(.leading, DS.Space.s)
            .padding(.trailing, DS.Space.xs)
            .padding(.vertical, DS.Space.s)
            .overlay(alignment: .bottom) {
                ShellPlaybackLine()
                    .padding(.horizontal, DS.Space.l)
                    .padding(.bottom, 3)
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shell.player")
        }
    }
}

/// The capsule's progress: the only part of it that follows the playhead.
private struct ShellPlaybackLine: View {
    @EnvironmentObject private var clock: PlaybackClock

    var body: some View {
        let _ = RenderStats.note("ShellPlaybackLine")
        ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(DS.Palette.accent)
            .scaleEffect(x: 1, y: 0.6, anchor: .center)
            .accessibilityHidden(true)
    }

    private var fraction: Double {
        guard clock.duration > 0, clock.time.isFinite else { return 0 }
        return min(1, max(0, clock.time / clock.duration))
    }
}

/// The hidden player: its artwork in a ring of progress at the left end of the field. Tap brings
/// the capsule back; a swipe away stops playback.
struct ShellPlayerChip: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: PodcastLibrary
    @State private var drag: CGFloat = 0

    var body: some View {
        let podcast = player.currentPodcastID.flatMap { library.podcast($0) }
        ZStack {
            Artwork(url: podcast?.artworkURL, size: 34, fallbackSeed: podcast?.title)
                .clipShape(Circle())
            ShellPlaybackRing()
        }
        .frame(width: 42, height: 42)
        .offset(x: drag)
        .opacity(1 - min(0.7, abs(drag) / 80))
        .contentShape(Circle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.25)) { ShellChrome.shared.playerHidden = false }
        }
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { drag = min(0, $0.translation.width) }
            .onEnded { value in
                if value.translation.width < -44 || value.predictedEndTranslation.width < -90 {
                    player.stop()
                }
                withAnimation(.snappy) { drag = 0 }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Player, \(player.currentEpisode?.title ?? "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the player")
        .accessibilityAction(named: "Stop playback") { player.stop() }
        .accessibilityIdentifier("shell.player.chip")
    }
}

private struct ShellPlaybackRing: View {
    @EnvironmentObject private var clock: PlaybackClock

    var body: some View {
        let fraction = clock.duration > 0 && clock.time.isFinite ? min(1, max(0, clock.time / clock.duration)) : 0
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: fraction)
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: - Page content under the bar

extension View {
    /// A page in the shell's tab view: the bar at the bottom (`bottomBar`) or the rail and one
    /// toolbar (wide). Either way the tab bar is gone; the pages are the switcher's or the rail's.
    func shellPage(bottomBar: Bool) -> some View {
        modifier(ShellPageModifier(bottomBar: bottomBar))
    }
}

private struct ShellPageModifier: ViewModifier {
    let bottomBar: Bool
    func body(content: Content) -> some View {
        content
            .environment(\.bottomBarShell, bottomBar)
            .environment(\.wideShell, !bottomBar)
            .toolbarVisibility(.hidden, for: .tabBar)
            // An iPad's floating tab strip and sidebar ignore the SwiftUI setting: the tab bar
            // controller hides them itself.
            .background(TabBarHider())
    }
}

/// Hides the enclosing `UITabBarController`'s bar (an iPad's floating strip included) and its
/// sidebar. Zero-size; does nothing outside a tab bar controller.
private struct TabBarHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.hide() }

    final class Controller: UIViewController {
        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            hide()
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            hide()
        }
        // Turning an iPad brings the sidebar back: hidden again as the turn ends.
        override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: { _ in self.hide() }, completion: { _ in self.hide() })
        }
        override func traitCollectionDidChange(_ previous: UITraitCollection?) {
            super.traitCollectionDidChange(previous)
            hide()
        }
        func hide() {
            guard let tabs = tabBarController else { return }
            if !tabs.isTabBarHidden { tabs.setTabBarHidden(true, animated: false) }
            if !tabs.sidebar.isHidden { tabs.sidebar.isHidden = true }
        }
    }
}
#endif
