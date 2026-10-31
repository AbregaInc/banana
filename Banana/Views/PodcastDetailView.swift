import SwiftUI
import Foundation

/// A single podcast: artwork, the play-direction picker, wake-source toggle,
/// and the episode list in play order.
/// Download(s) the person asked for while on cellular — held until they confirm.
struct CellularDownload: Identifiable {
    let id = UUID()
    let episodes: [Episode]
    let podcast: Podcast
}

struct PodcastDetailView: View {
    @State private var cellularPrompt: CellularDownload?
    @State private var episodeInfo: Episode?
    @State private var showConfiguration = false
    let podcastID: UUID
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var skipPlans: SkipPlanService
    @EnvironmentObject var settings: AppSettings
    /// Voice verdicts, so a narrator row can show what was decided and let it be corrected.
    /// Observed rather than read once: correcting one narrator has to redraw the list.
    @ObservedObject private var voices = NarratorVoiceStore.shared

    @StateObject private var browser = PodcastEpisodeBrowser()
    @State private var includingListened = false
    @State private var retryPage = 0
    private var podcast: Podcast? { library.podcast(podcastID) }

    /// Invalidates a page when feed identity, direction, or episode snapshot changes.
    private static func orderKey(_ p: Podcast) -> String {
        "\(p.id)|\(p.direction.rawValue)|\(p.episodeRevision)"
    }

    var body: some View {

        let _ = RenderStats.note("PodcastDetailView")
        if let podcast {
            ScrollViewReader { scrollProxy in
            List {
                Section {
                    header(podcast)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    Picker("Episodes", selection: $includingListened) {
                        Text("Unplayed").tag(false)
                        Text("All episodes").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("library.episodes.scope")
                    if browser.isLoading {
                        ProgressView("Loading episodes…")
                    } else if let error = browser.error {
                        Text("Episodes could not be loaded. \(error)").foregroundStyle(.secondary)
                        Button("Try again") { retryPage += 1 }
                    } else if browser.count == 0 {
                        Text(includingListened ? "No episodes yet" : "You're all caught up")
                            .foregroundStyle(.secondary)
                        if !includingListened {
                            Button("Show listened episodes") { includingListened = true }
                        }
                    }
                    // One row per position lets native List reuse rows lazily. Bodies stay on
                    // disk and pages load ahead of scrolling; listened prefixes cost no taps.
                    ForEach(0..<browser.count, id: \.self) { index in
                        PodcastBrowserRow(browser: browser, index: index) { episode in
                            episodeListRow(episode, in: podcast)
                        }
                    }
                    #if DEBUG
                    // Only for the screenshot run that scrolls here. Always present, this invisible
                    // last row took the card's rounded bottom and left a stray separator above it
                    // in every debug build — which is what the phone runs.
                    if ProcessInfo.processInfo.arguments.contains("--scroll-bottom") {
                        Color.clear.frame(height: 1)
                            .listRowBackground(Color.clear)
                            .id("episodes-end")
                    }
                    #endif
                } header: {
                    Text(browser.isLoading ? "Episodes" : "Episodes (\(browser.count))")
                        .accessibilityIdentifier("library.episodes.heading")
                }
            }
            .listStyle(.insetGrouped)
            // Pull to refresh, as the Library does; there's no Refresh button in the bar.
            .refreshable {
                await library.refresh(podcastID)
                if let updated = library.podcast(podcastID) { downloads.reconcile(updated) }
            }
            #if DEBUG
            // Screenshot automation (--scroll-bottom): land the sim shot on the episode list.
            .onAppear {
                guard ProcessInfo.processInfo.arguments.contains("--scroll-bottom") else { return }
                for delay in [1.5, 4.0, 7.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        scrollProxy.scrollTo("episodes-end", anchor: .bottom)
                    }
                }
            }
            #endif
            .task(id: "\(skipKey(podcast))|\(includingListened)|\(retryPage)") {
                await browser.configure(podcast: podcast, includingListened: includingListened, voiceOf: voices.lookup())
            }
            .onChange(of: podcast.completed) { _, _ in
                Task { await browser.configure(podcast: podcast, includingListened: includingListened, voiceOf: voices.lookup()) }
            }
            .task(id: podcast.id) {
                // Fetch the ad-server headers for the episode most likely to be played next, so a
                // streamed episode is not still waiting on a HEAD request while its first ad plays.
                // Only for episodes with no local file: a downloaded one already captured its
                // headers from the download itself, on the very bytes it will play.
                let upcoming = await Task.detached(priority: .utility) { podcast.nextUnplayed(2) }.value
                guard !Task.isCancelled else { return }
                for episode in upcoming
                where downloads.localURL(for: episode.id) == nil {
                    skipPlans.prefetchDeclaredSlots(episode: episode, podcast: podcast)
                }
            }
            .alert("Download over cellular?", isPresented: .constant(cellularPrompt != nil),
                   presenting: cellularPrompt) { pending in
                Button("Download") {
                    downloads.downloadAll(pending.episodes, podcast: pending.podcast, allowCellular: true)
                    cellularPrompt = nil
                }
                Button("Wait for Wi-Fi", role: .cancel) {
                    // Not cancelled — parked. They start themselves when Wi-Fi is back.
                    downloads.downloadAll(pending.episodes, podcast: pending.podcast, allowCellular: false)
                    cellularPrompt = nil
                }
            } message: { pending in
                Text(cellularMessage(pending))
            }
            // The header names the show; the bar doesn't say it a second time.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $episodeInfo) { episode in
                EpisodeInfoSheet(episode: episode)
            }
            .sheet(isPresented: $showConfiguration) {
                configurationSheet(podcast)
            }
            }   // end ScrollViewReader
        } else {
            ContentUnavailableView("Podcast unavailable", systemImage: "waveform.slash")
        }
    }

    /// Bulk downloads take the same route: free on Wi-Fi, confirmed on cellular.
    /// Consecutive listened stretches (≥ 2, never including the loaded episode) plus the
    /// open stretches between them, as ranges into the ordered list.
    static func listenedRuns(
        _ ordered: [Episode],
        completed: Set<String>,
        currentID: String?
    ) -> [(listened: Bool, range: Range<Int>)] {
        var runs: [(listened: Bool, range: Range<Int>)] = []
        var start = 0
        var index = 0
        func flush(_ listened: Bool, upTo end: Int) {
            guard end > start else { return }
            runs.append((listened, start..<end))
            start = end
        }
        while index < ordered.count {
            let episode = ordered[index]
            let isListened = completed.contains(episode.id) && episode.id != currentID
            let runStart = index
            while index < ordered.count {
                let e = ordered[index]
                let listened = completed.contains(e.id) && e.id != currentID
                guard listened == isListened else { break }
                index += 1
            }
            // Folding a single listened episode saves nothing — keep it inline.
            let fold = isListened && (index - runStart) >= 2
            flush(!fold ? false : true, upTo: index)
        }
        // Merge adjacent open runs created by unfolded singletons.
        var merged: [(listened: Bool, range: Range<Int>)] = []
        for run in runs {
            if let last = merged.last, !last.listened, !run.listened {
                merged[merged.count - 1] = (false, last.range.lowerBound..<run.range.upperBound)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// One row per episode — extracted so open lists and expanded folds share it.
    @ViewBuilder private func episodeListRow(_ episode: Episode, in podcast: Podcast) -> some View {
        HStack(spacing: 8) {
            EpisodeRow(
                episode: episode,
                isCurrent: player.currentEpisode?.id == episode.id,
                isPlaying: player.isPlaying && player.currentEpisode?.id == episode.id,
                isCompleted: podcast.completed.contains(episode.id),
                progress: progressFraction(episode, in: podcast),
                isSkipped: false
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Already loaded and paused — resume it rather than rebuilding
                // the player item from the stored position.
                if player.currentEpisode?.id == episode.id, !player.isPlaying {
                    player.setPlaying(true)
                } else {
                    player.play(episode, in: podcast)
                }
            }

            // One quiet trailing control per row; "Episode info" lives in it.
            episodeMenu(episode, podcast: podcast)
        }
    }

    private func promptOrDownload(_ episodes: [Episode], podcast: Podcast) {
        guard !episodes.isEmpty else { return }
        if NetworkMonitor.shared.isCheap {
            downloads.downloadAll(episodes, podcast: podcast)
        } else {
            cellularPrompt = CellularDownload(episodes: episodes, podcast: podcast)
        }
    }

    /// Make the cost concrete. Podcast audio runs ~1 MB/minute at 128 kbps.
    private func cellularMessage(_ pending: CellularDownload) -> String {
        let minutes = pending.episodes.reduce(0.0) { $0 + ($1.duration ?? 0) } / 60
        let megabytes = Int(minutes.rounded())
        let what = pending.episodes.count == 1
            ? "This episode is about \(megabytes) MB"
            : "These \(pending.episodes.count) episodes are about \(megabytes) MB"
        return "You're not on Wi-Fi. \(what), and it will come out of your data plan. "
            + "Waiting will download them automatically when you're back on Wi-Fi."
    }

    /// The show at a glance, compact so its episodes start high on a phone: the cover at the
    /// left, its name and who makes it beside it, then Play and its settings.
    private func header(_ podcast: Podcast) -> some View {
        HStack(alignment: .top, spacing: DS.Space.l) {
            Artwork(url: podcast.artworkURL, size: 112)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(podcast.title).font(.title3.bold()).lineLimit(3)
                if let author = podcast.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: DS.Space.s)
                HStack(spacing: DS.Space.s) {
                    Button {
                        player.playNext(in: podcast)
                    } label: {
                        Label("Play next", systemImage: "play.fill")
                    }
                    .buttonStyle(.primary)
                    .accessibilityLabel("Play next episode")

                    Button {
                        showConfiguration = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(.secondary)   // a setting, not the main action — the accent stays on Play
                    .accessibilityLabel("Podcast settings")
                    .accessibilityIdentifier("podcast.settings.button")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        }
        .padding(.vertical, DS.Space.s)
    }

    private func configurationSheet(_ podcast: Podcast) -> some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Direction", selection: directionBinding(podcast)) {
                        ForEach(PlayDirection.allCases) { direction in
                            Text(direction.label).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(podcast.direction.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Speed", selection: speedBinding(podcast)) {
                        ForEach(PlayerController.speedOptions, id: \.self) { rate in
                            Text(speedLabel(rate)).tag(rate)
                        }
                    }

                    Picker("Skip opening", selection: autoSkipBinding(podcast)) {
                        ForEach(Self.autoSkipPresets, id: \.self) { seconds in
                            Text(autoSkipLabel(seconds)).tag(seconds)
                        }
                    }
                    .accessibilityIdentifier("podcast.settings.autoSkip")
                    Text("Automatically skips publisher pre-roll when starting a new episode. Resuming keeps your saved position. Where Banana has worked out this show's real ad breaks, it uses those instead of this fixed amount.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                adSkippingSection(podcast)
                narratorsSection(podcast)
                voiceFilterSection(podcast)

                Section {
                    Picker("Auto-download", selection: downloadRuleBinding(podcast)) {
                        ForEach(DownloadRule.presets, id: \.self) { rule in
                            Text(rule.label).tag(rule)
                        }
                    }
                    // On every device, like every setting: the phone does the sending.
                    Toggle(isOn: syncBinding(podcast)) {
                        Label("Sync to Apple Watch", systemImage: "applewatch")
                    }
                    if podcast.syncToWatch {
                        Picker("Watch quality", selection: watchQualityBinding(podcast)) {
                            Text("Use default").tag(WatchAudioQuality?.none)
                            ForEach(WatchAudioQuality.allCases) { quality in
                                Text(quality.label).tag(WatchAudioQuality?.some(quality))
                            }
                        }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text(Self.playedDownloadsRule(on: DeviceRole.current))
                }
            }
            .editingFormStyle()
            .navigationTitle("Podcast settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showConfiguration = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 390)
        #endif
    }

    /// This show's ad-skipping choice, and what skipping has stopped doing here.
    ///
    /// The choice is always shown, because a show whose ads you want to hear is a decision only
    /// you can make and there is nowhere else to make it. The retired-detector rows below it are
    /// still conditional: an empty "nothing has been retired" list would be a permanent fixture
    /// explaining a mechanism most shows never trigger.
    /// Which narrators this show uses, and which to stop being offered.
    ///
    /// Only drawn for shows that actually credit more than one person. A single-narrator show has
    /// nothing to choose between, and the section would be noise on every other podcast.
    @ViewBuilder
    private func narratorsSection(_ podcast: Podcast) -> some View {
        let roster = NarratorCredit.roster(for: podcast.episodes.map(\.summary))
        if roster.count > 1 {
            Section {
                ForEach(roster, id: \.name) { entry in
                    Toggle(isOn: narratorBinding(podcast, entry.name)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                            Text(narratorDetail(name: entry.name, episodes: entry.episodes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("podcast.narrator.\(entry.name)")
                    // Only while a gender is actually being filtered. A verdict is invisible
                    // machinery right up until it hides something you wanted; this is where you
                    // find out it exists and say it is wrong. The classifier gets roughly one
                    // narrator in ten wrong and sounds equally certain when it does.
                    if !podcast.mutedVoiceGenders.isEmpty {
                        Picker("Voice", selection: voiceOverrideBinding(entry.name)) {
                            Text("Not judged").tag(VoiceGender?.none)
                            ForEach(VoiceGender.allCases, id: \.rawValue) { gender in
                                Text(gender.label).tag(VoiceGender?.some(gender))
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("podcast.narratorVoice.\(entry.name)")
                    }
                }
            } header: {
                Text("Narrators")
            } footer: {
                Text("Turn one off and their episodes stop being downloaded or offered up next. Episodes that don't name a narrator are always kept — not knowing who read one is no reason to hide it. While you're filtering by voice, each narrator shows what Banana decided; correct it and your answer sticks.")
                    .font(.caption)
            }
        }
    }

    /// Filtering by how the narrator sounds, for shows that never credit one.
    ///
    /// Separate from the narrator list above because it answers a different question. That list is
    /// exact and needs a switch per person; this one decides for itself, including for a narrator
    /// the show has not used before — which is the point, since a show that adds someone every few
    /// weeks would otherwise mean a new switch every few weeks.
    @ViewBuilder
    private func voiceFilterSection(_ podcast: Podcast) -> some View {
        Section {
            ForEach(VoiceGender.allCases, id: \.rawValue) { gender in
                Toggle(isOn: voiceBinding(podcast, gender)) {
                    Text("Skip \(gender.label.lowercased())-sounding narration")
                }
                .accessibilityIdentifier("podcast.voice.\(gender.rawValue)")
            }
        } header: {
            Text("Narrator voice")
        } footer: {
            Text("Banana listens to about a minute of a downloaded episode and decides how its narrator sounds — including on shows that credit their narrators, so a new one every few weeks doesn't mean a new switch every few weeks. A narrator is judged once and it covers everything they read. It is a guess: roughly one in ten is wrong and sounds just as sure, so each narrator above shows its verdict and you can correct it. Nobody is skipped until they have been judged.")
                .font(.caption)
        }
    }

    /// Episode count, plus the voice verdict once one exists — and whether it was decided by hand,
    /// so a correction reads as yours rather than something the app might quietly overwrite.
    private func narratorDetail(name: String, episodes: Int) -> String {
        let count = "\(episodes) episode\(episodes == 1 ? "" : "s")"
        if let corrected = voices.override(forNarrator: name) {
            return "\(count) · \(corrected.label), set by you"
        }
        guard let reading = voices.reading(forNarrator: name) else { return count }
        return "\(count) · sounds \(reading.gender.label.lowercased()) (\(Int(reading.confidence * 100))%)"
    }

    private func voiceOverrideBinding(_ name: String) -> Binding<VoiceGender?> {
        Binding(
            get: { voices.override(forNarrator: name) ?? voices.gender(forNarrator: name) },
            set: {
                voices.setOverride($0, forNarrator: name)
                applyFilter(podcastID)
            }
        )
    }

    private func voiceBinding(_ podcast: Podcast, _ gender: VoiceGender) -> Binding<Bool> {
        Binding(
            get: { podcast.mutedVoiceGenders.contains(gender) },
            set: {
                library.setVoiceGenderMuted($0, gender: gender, for: podcast.id)
                applyFilter(podcast.id)
            }
        )
    }

    private func narratorBinding(_ podcast: Podcast, _ name: String) -> Binding<Bool> {
        Binding(
            get: { !podcast.mutedNarrators.contains(name) },
            set: {
                library.setNarratorMuted(!$0, narrator: name, for: podcast.id)
                applyFilter(podcast.id)
            }
        )
    }

    /// A filter change applies at once: the download rule swaps skipped episodes for the next
    /// ones it keeps (it used to wait for the next refresh).
    private func applyFilter(_ podcastID: UUID) {
        if let updated = library.podcast(podcastID) { downloads.reconcile(updated) }
    }

    /// Changes when the feed, what's muted, or a voice verdict does.
    private func skipKey(_ podcast: Podcast) -> String {
        "\(Self.orderKey(podcast))|\(podcast.mutedNarrators.sorted().joined(separator: ","))|"
            + "\(podcast.mutedVoiceGenders.map(\.rawValue).sorted().joined(separator: ","))|\(voices.revision)"
    }

    @ViewBuilder
    private func adSkippingSection(_ podcast: Podcast) -> some View {
        let retired = skipPlans.retiredDetectors(forShow: podcast.id)
        Section("Ad skipping") {
            // Three states, not a switch: a show that has made no choice should follow the global
            // setting, so turning ad skipping off everywhere still turns it off here. Only an
            // explicit "Always"/"Never" pins this show against that.
            Picker("Skip ads", selection: adSkipBinding(podcast)) {
                Text("Use default").tag(Bool?.none)
                Text("Always").tag(Bool?.some(true))
                Text("Never").tag(Bool?.some(false))
            }
            .accessibilityIdentifier("podcast.settings.adSkip")
            Text(Self.adSkipDetail(podcast.skipsAdsAutomatically,
                                   globalDefault: settings.automaticAdSkip))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !retired.isEmpty {
                ForEach(retired, id: \.rawValue) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(Self.retiredTitle(source), systemImage: "hand.raised")
                        Text(Self.retiredDetail(source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Banana stopped these on this show after you rewound back into what they skipped. Everything else it finds here still skips as normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func adSkipBinding(_ podcast: Podcast) -> Binding<Bool?> {
        Binding(
            get: { podcast.skipsAdsAutomatically },
            set: { library.setAutomaticAdSkip($0, for: podcast.id) }
        )
    }

    /// Says what the current choice actually means, including what "Use default" resolves to right
    /// now — otherwise the row reads the same whether the global switch is on or off.
    private static func adSkipDetail(_ choice: Bool?, globalDefault: Bool) -> String {
        switch choice {
        case .some(true):
            return "Ads, promos and repeated openings are skipped on this show, even if you turn skipping off everywhere else."
        case .some(false):
            return "Nothing is skipped on this show. Your fixed opening skip above still applies."
        case .none:
            return globalDefault
                ? "Following your setting in Settings → Podcasts, which is currently on."
                : "Following your setting in Settings → Podcasts, which is currently off."
        }
    }

    private static func retiredTitle(_ source: SkipSource) -> String {
        switch source {
        case .declaredByHost:     return "Declared ad breaks"
        case .encoderSeam:        return "Stitched ad breaks"
        case .repeatedBoilerplate: return "Repeated boilerplate"
        case .taglineBoundary:    return "Show opening"
        case .silenceExtension:   return "Opening music"
        case .sponsorRead:        return "Host-read sponsors"
        }
    }

    private static func retiredDetail(_ source: SkipSource) -> String {
        switch source {
        case .declaredByHost:     return "Breaks the host's own server marks in the file."
        case .encoderSeam:        return "Breaks found from where the ad was spliced into the audio."
        case .repeatedBoilerplate: return "Wording this show repeats word-for-word every episode."
        case .taglineBoundary:    return "The show's usual opening line."
        case .silenceExtension:   return "The music bed after the opening line."
        case .sponsorRead:        return "Sponsor messages the host reads aloud."
        }
    }

    private static let autoSkipPresets = [0, 15, 30, 45, 60, 90, 120, 180, 300]

    private func autoSkipBinding(_ podcast: Podcast) -> Binding<Int> {
        Binding(
            get: { podcast.autoSkipSeconds },
            set: { library.setAutoSkipSeconds($0, for: podcast.id) }
        )
    }

    private func autoSkipLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "Off"
        case 60: return "1 minute"
        case 90: return "1½ minutes"
        case 120: return "2 minutes"
        case 180: return "3 minutes"
        case 300: return "5 minutes"
        default: return "\(seconds) seconds"
        }
    }

    private func watchQualityBinding(_ podcast: Podcast) -> Binding<WatchAudioQuality?> {
        Binding(
            get: { podcast.watchAudioQuality },
            set: { library.setWatchAudioQuality($0, for: podcast.id) }
        )
    }

    private func directionBinding(_ podcast: Podcast) -> Binding<PlayDirection> {
        Binding(
            get: { podcast.direction },
            set: { library.setDirection($0, for: podcast.id) }
        )
    }

    private func speedBinding(_ podcast: Podcast) -> Binding<Double> {
        Binding(
            get: { podcast.speed },
            set: { newValue in
                library.setSpeed(newValue, for: podcast.id)
                if player.currentPodcastID == podcast.id { player.setSpeed(newValue) }
            }
        )
    }

    private func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(String(format: "%g", rate))×"
    }

    private func downloadRuleBinding(_ podcast: Podcast) -> Binding<DownloadRule> {
        Binding(
            get: { podcast.downloadRule },
            set: { rule in
                library.setDownloadRule(rule, for: podcast.id)
                if let updated = library.podcast(podcast.id) { downloads.reconcile(updated) }
            }
        )
    }

    private func syncBinding(_ podcast: Podcast) -> Binding<Bool> {
        Binding(
            get: { podcast.syncToWatch },
            set: { on in
                library.setSyncToWatch(on, for: podcast.id)
                if on { downloads.backfillWatch() }   // push already-downloaded episodes
            }
        )
    }


    /// The "…" menu for an episode: download (single / all-before / all-after / cancel /
    /// remove) and played (this / all-before / all-after).
    @ViewBuilder private func episodeMenu(_ episode: Episode, podcast: Podcast) -> some View {
        let state = downloads.state(episode.id)
        Group {
            if state == DownloadManager.State.none || state == .failed {
                // Not on the device: the down-arrow downloads on a tap; everything else is a
                // press-and-hold away, in the same menu.
                Menu {
                    episodeMenuItems(episode, podcast: podcast, state: state)
                } label: {
                    menuLabel(state, episodeID: episode.id)
                } primaryAction: {
                    requestDownload(episode, podcast: podcast)
                }
                .accessibilityLabel("Download")
            } else {
                Menu {
                    episodeMenuItems(episode, podcast: podcast, state: state)
                } label: {
                    menuLabel(state, episodeID: episode.id)
                }
                .accessibilityLabel("Episode actions")
            }
        }
        // The app's accent would otherwise tint this orange whatever the label asks for.
        .tint(.secondary)
        .menuIndicator(.hidden)
    }

    /// Automatic downloads are Wi-Fi only. A download you asked for can use cellular — but not
    /// without telling you first.
    private func requestDownload(_ episode: Episode, podcast: Podcast) {
        if NetworkMonitor.shared.isCheap {
            downloads.download(episode, podcast: podcast)
        } else {
            cellularPrompt = CellularDownload(episodes: [episode], podcast: podcast)
        }
    }

    @ViewBuilder private func episodeMenuItems(_ episode: Episode, podcast: Podcast,
                                               state: DownloadManager.State) -> some View {
        let played = podcast.completed.contains(episode.id)
        Button { episodeInfo = episode } label: {
            Label("Episode info", systemImage: "info.circle")
        }
        Divider()
        switch state {
        case .downloaded:
            Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.delete(episode.id) }
        case .waitingForWiFi:
            // The system is holding this until Wi-Fi. Showing that and offering no way out
            // would just be a locked door: let it be overridden, with the cost stated.
            Button("Download Now", systemImage: "antenna.radiowaves.left.and.right") {
                if NetworkMonitor.shared.isCheap {
                    downloads.download(episode, podcast: podcast, allowCellular: true)
                } else {
                    cellularPrompt = CellularDownload(episodes: [episode], podcast: podcast)
                }
            }
            Button("Cancel Download", systemImage: "xmark.circle") { downloads.cancel(episode.id) }
        case .downloading:
            Button("Cancel Download", systemImage: "xmark.circle") { downloads.cancel(episode.id) }
        default:
            Button("Download", systemImage: "arrow.down.circle") { requestDownload(episode, podcast: podcast) }
        }
        Button("Download All Older", systemImage: "arrow.down.circle") {
            bulkEpisodes(relativeTo: episode, podcast: podcast, older: true) { promptOrDownload($0, podcast: podcast) }
        }
        Button("Download All Newer", systemImage: "arrow.up.circle") {
            bulkEpisodes(relativeTo: episode, podcast: podcast, older: false) { promptOrDownload($0, podcast: podcast) }
        }

        Divider()

        if played {
            Button("Mark as Unplayed", systemImage: "circle") { library.markUnplayed(podcastID: podcast.id, episodeID: episode.id) }
        } else {
            Button("Mark as Played", systemImage: "checkmark.circle") { markPlayed([episode.id], in: podcast) }
        }
        Menu("Mark older…", systemImage: "chevron.down") {
            Button("Played") { bulkEpisodes(relativeTo: episode, podcast: podcast, older: true) { markPlayed($0.map(\.id), in: podcast) } }
            Button("Unplayed") { bulkEpisodes(relativeTo: episode, podcast: podcast, older: true) { library.markUnplayed(podcastID: podcast.id, episodeIDs: $0.map(\.id)) } }
        }
        Menu("Mark newer…", systemImage: "chevron.up") {
            Button("Played") { bulkEpisodes(relativeTo: episode, podcast: podcast, older: false) { markPlayed($0.map(\.id), in: podcast) } }
            Button("Unplayed") { bulkEpisodes(relativeTo: episode, podcast: podcast, older: false) { library.markUnplayed(podcastID: podcast.id, episodeIDs: $0.map(\.id)) } }
        }
    }

    /// A bulk operation may read history, after selection and away from the input lane.
    private func bulkEpisodes(relativeTo episode: Episode, podcast: Podcast, older: Bool,
                              perform: @escaping @MainActor ([Episode]) -> Void) {
        Task {
            let values = await Task.detached(priority: .userInitiated) {
                let date = episode.pubDate ?? .distantPast
                return podcast.episodes.filter {
                    older ? ($0.pubDate ?? .distantPast) < date : ($0.pubDate ?? .distantPast) > date
                }
            }.value
            perform(values)
        }
    }

    /// What happens to a played episode's download, in the words of the device it's on: only the
    /// phone sends episodes to the Watch, so only it removes them there too.
    static func playedDownloadsRule(on device: DeviceRole) -> String {
        let from = device.isHub ? "this iPhone and your Watch" : "this \(device.name)"
        let watch = device.isHub ? "" : " Your iPhone sends a synced show\u{2019}s episodes to your Watch."
        return "When an episode is played \u{2014} finished, or marked played \u{2014} its download is removed from \(from), even one you downloaded yourself. Marking one played offers Undo for a few seconds, and the file stays until it closes.\(watch)"
    }

    /// Marks episodes played and says what that does to their downloads — a played episode's
    /// file is removed — with Undo. The file stays until the Undo closes (see
    /// `DownloadManager.observeCompletions`), and undoing puts back where you'd got to.
    private func markPlayed(_ ids: [String], in podcast: Podcast) {
        let unplayed = ids.filter { !podcast.completed.contains($0) }
        guard !unplayed.isEmpty else { return }
        let positions = podcast.positions.filter { unplayed.contains($0.key) }
        let removing = unplayed.filter { downloads.isDownloaded($0) }.count
        library.markCompleted(podcastID: podcast.id, episodeIDs: unplayed)
        let what = unplayed.count == 1 ? "Marked played" : "Marked \(unplayed.count) episodes played"
        let files = switch removing {
        case 0: ""
        case 1: " \u{00B7} download removed"
        default: " \u{00B7} \(removing) downloads removed"
        }
        let library = library
        let podcastID = podcast.id
        Task {
            await ToastCenter.shared.offerUndo(what + files) {
                library.markUnplayed(podcastID: podcastID, episodeIDs: unplayed, restoring: positions)
                return nil
            }
        }
    }

    @ViewBuilder private func menuLabel(_ state: DownloadManager.State, episodeID: String) -> some View {
        switch state {
        case .downloading:
            // The ring is its own view observing the progress ticker, so the per-percent tick
            // re-renders THIS 20 pt circle — not the detail view and its whole episode list.
            DownloadRing(episodeID: episodeID, ticker: downloads.progressTicker)
        case .downloaded:
            // Downloaded is a state, not an action: a quiet tick, like the rest of the row.
            labelIcon("checkmark.circle.fill", Color.secondary)
        case .waitingForWiFi:
            labelIcon("wifi.exclamationmark", .secondary)
        default:
            // Not on the device: the arrow is the action (a tap downloads).
            labelIcon("arrow.down.circle", .secondary)
        }
    }

    private func labelIcon<S: ShapeStyle>(_ name: String, _ style: S) -> some View {
        Image(systemName: name).font(.system(size: 20, weight: .regular)).foregroundStyle(style)
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }

    private func progressFraction(_ episode: Episode, in podcast: Podcast) -> Double? {
        guard let pos = podcast.positions[episode.id], let dur = episode.duration, dur > 0 else { return nil }
        return min(1, pos / dur)
    }
}

/// Episode descriptions and extracted credits used to be visible only after opening Transcript.
/// Keeping them beside the episode list makes the publisher's context available before playback.
private struct EpisodeInfoSheet: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss
    @State private var credits: EpisodeCredits?
    /// Built once, off the main thread, when the sheet opens — see `ShowNotes`.
    @State private var summary: AttributedString?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(episode.title).font(.headline)
                    if let date = episode.pubDate {
                        LabeledContent("Published", value: date.formatted(.dateTime.month().day().year()))
                    }
                    if let duration = episode.duration {
                        LabeledContent("Duration", value: durationLabel(duration))
                    }
                }

                if let credits, !credits.isEmpty {
                    Section("People") {
                        if let host = credits.host { LabeledContent("Host", value: host) }
                        if !credits.narrators.isEmpty {
                            ForEach(credits.narrators) { narrator in
                                LabeledContent(narrator.role == .primary ? "Primary narrator" : "Narrator", value: narrator.name)
                            }
                        }
                        if !credits.guests.isEmpty { LabeledContent("Guests", value: credits.guests.joined(separator: ", ")) }
                    }
                }

                if let summary {
                    Section("Episode notes") {
                        Text(summary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Episode info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            let html = episode.summary ?? ""
            summary = await Task.detached(priority: .userInitiated) { ShowNotes.attributed(html) }.value
            credits = await TranscriptCoordinator.shared.credits(for: episode)
        }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// The live download-progress ring. Deliberately a separate view: it observes the manager's
/// ProgressTicker (up to 100 publishes per download), and being its own leaf means those ticks
/// invalidate a 20 pt circle instead of every row in the episode list.
private struct DownloadRing: View {
    let episodeID: String
    @ObservedObject var ticker: DownloadManager.ProgressTicker

    var body: some View {
        let fraction = ticker.fractions[episodeID] ?? 0
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle().trim(from: 0, to: max(0.03, fraction))
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: fraction)
        }
        .frame(width: 20, height: 20).frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

/// One episode: a date line, the title, and a play capsule that carries the state — playing,
/// how far in, how much is left (DESIGN-SYSTEM.md, "Rows"). Progress lives inside the capsule
/// rather than as a loose bar under the text, and the row has one leading edge instead of an
/// icon column.
struct EpisodeRow: View {
    let episode: Episode
    let isCurrent: Bool
    let isPlaying: Bool
    let isCompleted: Bool
    let progress: Double?
    /// The voice filter passes over it: dimmed and labelled, still playable with a tap.
    var isSkipped = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let date = episode.pubDate {
                Text(EpisodeRowText.dateLine(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(episode.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(isCompleted || isSkipped ? .secondary : .primary)
            if isSkipped {
                Label("Skipped by your narrator filter", systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            capsule
                .padding(.top, DS.Space.hair)
        }
        .padding(.vertical, DS.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("podcast.episode.\(episode.id)")
    }

    /// ▶ ━━ 20m left. Accent while it's the loaded episode; quiet otherwise.
    private var capsule: some View {
        let text = EpisodeRowText.capsule(duration: episode.duration, progress: progress, completed: isCompleted)
        let started = (progress ?? 0) > 0.01 && (progress ?? 0) < 0.99 && !isCompleted
        let tint: Color = isCurrent ? DS.Palette.accent : .secondary
        return HStack(spacing: DS.Space.s - 2) {
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 10, weight: .bold))
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            }
            if started, let progress {
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(DS.Tint.strong))
                    Capsule().fill(tint).frame(width: 28 * progress)
                }
                .frame(width: 28, height: 3)
            }
            if let text {
                Text(text)
                    .font(.caption.weight(.medium).monospacedDigit())
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(tint.opacity(isCurrent ? DS.Tint.soft : DS.Tint.subtle), in: Capsule())
    }

    /// What a tap will do — or, while playing, that it's live. A loaded but paused episode shows
    /// play; the accent is what marks it as "paused here" rather than "never started".
    /// Played says so in words only: the row's one tick is the downloaded one.
    private var glyph: String? {
        if isPlaying { return "waveform" }
        if isCompleted { return nil }
        return "play.fill"
    }
}

/// A constant row shape keeps List's identity pass from materializing the retained feed.
private struct PodcastBrowserRow<Content: View>: View {
    @ObservedObject var browser: PodcastEpisodeBrowser
    let index: Int
    @ViewBuilder let content: (Episode) -> Content

    var body: some View {
        VStack(alignment: .leading) {
            if let episode = browser.episode(at: index) {
                content(episode)
            } else {
                ProgressView("Loading episode…")
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            }
        }
        .task { await browser.reveal(index) }
    }
}
