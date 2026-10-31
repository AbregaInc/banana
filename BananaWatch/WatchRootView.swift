import SwiftUI
import HealthKit
import WatchKit

struct WatchRootView: View {
    @EnvironmentObject var recorder: WorkoutRecorder
    @EnvironmentObject var audio: WatchAudioPlayer
    @EnvironmentObject var workoutPlans: WatchWorkoutPlanStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAgenda = false
    @State private var agendaPreviewItems: [WatchCalendarItem]?

    private var showsMoreWorkoutsPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--more-workouts-preview")
        #else
        false
        #endif
    }

    private var showsWorkoutHistoryPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--workout-history-preview")
        #else
        false
        #endif
    }

    var body: some View {
        // A running workout takes over the whole screen with its own paged view, so the
        // metrics never have to share space with (or scroll past) the podcast list.
        Group {
            if recorder.isRecovering {
                ProgressView("Recovering workout…")
            } else if recorder.isFinishing {
                ProgressView("Saving workout…")
            } else if Features.guidedPlans, recorder.isRecording, let plan = workoutPlans.activePlan {
                WatchGuidedWorkoutView(plan: plan)
            } else if recorder.isRecording {
                ActiveWorkoutView()
            } else if showsMoreWorkoutsPreview {
                NavigationStack {
                    WatchMoreWorkoutsView(types: Array(WatchWorkoutType.all.suffix(2)))
                }
            } else if showsWorkoutHistoryPreview {
                NavigationStack {
                    WatchWorkoutHistoryView()
                }
            } else if showingAgenda {
                WatchAgendaView(
                    onClose: { showingAgenda = false },
                    previewItems: agendaPreviewItems)
            } else {
                TabView {
                    WatchWorkoutView()
                    WatchPodcastsView()
                }
                .tabViewStyle(.verticalPage)
            }
        }
        .onAppear {
            WatchAudioPlayer.shared.setInterfaceActive(scenePhase == .active)
            WatchDownloadManager.shared.escalateStalled()
            NightMotionHarvester.shared.harvestIfDue()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--strength-workout"), !recorder.isRecording {
                recorder.startFakeWorkout(splitDistanceMeters: 0)
            }
            if showsMoreWorkoutsPreview {
                recorder.isAuthorized = true
            }
            if ProcessInfo.processInfo.arguments.contains("--agenda-preview") {
                agendaPreviewItems = WatchCalendarItem.agendaPreviewItems()
                showingAgenda = true
            }
            if ProcessInfo.processInfo.arguments.contains("--guided-workout-preview"), !recorder.isRecording {
                let plan = DeterministicWorkoutBuilder.build(preferences: .init(
                    focus: .mixed,
                    experience: .beginner,
                    durationMinutes: 30,
                    equipment: [.bodyweight]))
                workoutPlans.begin(plan)
                recorder.startFakeWorkout(splitDistanceMeters: 1_000)
            }
            #endif
        }
        // Asked to play with no headphones: nothing plays from the speaker, and this says why.
        .alert("Connect headphones", isPresented: Binding(
            get: { audio.needsHeadphones },
            set: { if !$0 { audio.dismissHeadphonesPrompt() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Banana doesn\u{2019}t play podcasts from the Watch speaker.")
        }
        .alert("Workout", isPresented: Binding(
            get: { recorder.lastError != nil },
            set: { if !$0 { recorder.lastError = nil } })) {
            Button("OK", role: .cancel) { recorder.lastError = nil }
        } message: {
            Text(recorder.lastError ?? "")
        }
        .onOpenURL { url in
            guard url.scheme == "bananawatch", url.host == "agenda" else { return }
            showingAgenda = true
        }
        .onChange(of: scenePhase) { _, phase in
            WatchAudioPlayer.shared.setInterfaceActive(phase == .active)
            if phase == .active {
                WatchDownloadManager.shared.escalateStalled()
                NightMotionHarvester.shared.harvestIfDue()
            }
        }
    }
}

// MARK: - Workout tab

/// Curated workout types the watch can start. This order is the stable fallback until workout
/// history gives the picker a personalized order.
struct WatchWorkoutType: Identifiable {
    let name: String
    let activity: HKWorkoutActivityType
    let icon: String
    let indoor: Bool
    /// Pool or open water. Swimming is the one activity where the type alone doesn't describe the
    /// session, so it gets two rows rather than a single "Swimming" that HealthKit can't classify.
    var swimmingLocation: HKWorkoutSwimmingLocationType? = nil
    var id: String { name }

    static let all: [WatchWorkoutType] = [
        .init(name: "Running", activity: .running, icon: "figure.run", indoor: false),
        .init(name: "Yoga", activity: .yoga, icon: "figure.yoga", indoor: true),
        .init(name: "Strength", activity: .traditionalStrengthTraining, icon: "dumbbell.fill", indoor: true),
        .init(name: "Walking", activity: .walking, icon: "figure.walk", indoor: false),
        .init(name: "Cycling", activity: .cycling, icon: "figure.outdoor.cycle", indoor: false),
        // Lap length is NOT baked in here — it comes from the phone setting, because it describes
        // the pool rather than the workout type.
        .init(name: "Pool Swim", activity: .swimming, icon: "figure.pool.swim", indoor: true,
              swimmingLocation: .pool),
        .init(name: "Open Water", activity: .swimming, icon: "figure.open.water.swim", indoor: false,
              swimmingLocation: .openWater),
        .init(name: "HIIT", activity: .highIntensityIntervalTraining, icon: "flame.fill", indoor: true),
        .init(name: "Core", activity: .coreTraining, icon: "figure.core.training", indoor: true),
        .init(name: "Rowing", activity: .rowing, icon: "figure.rower", indoor: true),
        .init(name: "Hiking", activity: .hiking, icon: "figure.hiking", indoor: false),
        .init(name: "Other", activity: .other, icon: "figure.mixed.cardio", indoor: false),
    ]

    /// How far back the picker looks when ranking types by use. A type you did a lot last winter
    /// but not since should not outrank what you actually do now.
    static let rankingWindow: TimeInterval = 90 * 24 * 60 * 60

    static func ordered(by completedWorkouts: [WorkoutSummary], now: Date = Date()) -> [WatchWorkoutType] {
        let cutoff = now.addingTimeInterval(-rankingWindow)
        let recentCounts = Dictionary(grouping: completedWorkouts.filter { $0.start >= cutoff }, by: \.activity)
            .mapValues(\.count)
        // All-time use only breaks ties between types with the same recent count, so a type you
        // used to do still edges out one you never have — without dominating the recent order.
        let allTimeCounts = Dictionary(grouping: completedWorkouts, by: \.activity)
            .mapValues(\.count)
        let fallbackPositions = Dictionary(uniqueKeysWithValues:
            all.enumerated().map { ($0.element.id, $0.offset) })

        return all.sorted { lhs, rhs in
            let lhsRecent = recentCounts[lhs.name, default: 0]
            let rhsRecent = recentCounts[rhs.name, default: 0]
            if lhsRecent != rhsRecent { return lhsRecent > rhsRecent }
            let lhsTotal = allTimeCounts[lhs.name, default: 0]
            let rhsTotal = allTimeCounts[rhs.name, default: 0]
            if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
            return fallbackPositions[lhs.id, default: 0] < fallbackPositions[rhs.id, default: 0]
        }
    }
}

struct WatchWorkoutView: View {
    @EnvironmentObject var recorder: WorkoutRecorder
    @EnvironmentObject var episodes: WatchEpisodeStore
    @EnvironmentObject var audio: WatchAudioPlayer
    @EnvironmentObject var remote: WatchPhoneRemote
    @EnvironmentObject var workoutPlans: WatchWorkoutPlanStore
    @State private var pickerScrollID: String?

    private var orderedTypes: [WatchWorkoutType] {
        WatchWorkoutType.ordered(by: recorder.savedSessions)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if !recorder.isAuthorized {
                        Section {
                            Button("Allow Health access") {
                                Task { await recorder.requestAuthorization() }
                            }
                            .tint(.orange)
                        } footer: {
                            Text("Records heart rate, motion, and GPS during a workout for later analysis on your iPhone.")
                        }
                    }

                    if Features.guidedPlans, let plan = workoutPlans.latestPlan, !plan.exercises.isEmpty {
                        Section("Guided") {
                            NavigationLink {
                                WatchWorkoutPlanPreview(plan: plan)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(plan.title, systemImage: "sparkles")
                                    Text("\(plan.targetMinutes) min · \(plan.exercises.count) moves")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section {
                        ForEach(Array(orderedTypes.prefix(10))) { type in
                            WatchWorkoutStartRow(type: type)
                        }

                        let additionalTypes = Array(orderedTypes.dropFirst(10))
                        if !additionalTypes.isEmpty {
                            NavigationLink {
                                WatchMoreWorkoutsView(types: additionalTypes)
                            } label: {
                                Label("More…", systemImage: "ellipsis.circle")
                            }
                            .id("more")
                        }

                        // A deliberate thick rule so the eye can tell "start something" from
                        // "look back" while scrolling — the rows otherwise look identical.
                        WatchSectionRule()

                        NavigationLink {
                            WatchWorkoutHistoryView()
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .id("history")
                    } header: {
                        Text("Start")
                    } footer: {
                        if !episodes.episodes.isEmpty {
                            Text("Downloaded episodes start automatically, except for swims.")
                        }
                    }
                }
                .navigationTitle("Workout")
                .onChange(of: pickerScrollID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--workout-nav-preview") {
                recorder.isAuthorized = true
                try? await Task.sleep(nanoseconds: 300_000_000)
                pickerScrollID = "history"
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--activeworkout") {
                if !recorder.isRecording {
                    let poolSwimming = ProcessInfo.processInfo.arguments.contains("--pool-swim")
                    recorder.startFakeWorkout(
                        splitDistanceMeters: poolSwimming ? episodes.poolLengthMeters : (episodes.useMiles ? 1609.344 : 1000),
                        poolSwimming: poolSwimming)
                    if ProcessInfo.processInfo.arguments.contains("--splits-page") {
                        recorder.debugSeedSplits()
                    }
                    // `--paused`: the workout paused, to look at the stopped clock and Resume.
                    if ProcessInfo.processInfo.arguments.contains("--paused") { recorder.pause() }
                    if ProcessInfo.processInfo.arguments.contains("--phone-now-playing") {
                        remote.debugSeedNowPlaying()
                    } else {
                        audio.debugSeedNowPlaying()
                    }
                }
                return   // skip the real auth check so it can't downgrade the fake state
            }
            if ProcessInfo.processInfo.arguments.contains("--workout-picker") {
                recorder.isAuthorized = true
                return
            }
            #endif
            await recorder.refreshAuthorization()   // don't re-prompt if already granted
        }
    }

}

/// A thick horizontal rule used as a list row: separates the workout starters from History.
private struct WatchSectionRule: View {
    var body: some View {
        Rectangle()
            .fill(.tertiary)
            .frame(height: 3)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .accessibilityHidden(true)
    }
}

private struct WatchWorkoutStartRow: View {
    @EnvironmentObject var recorder: WorkoutRecorder
    @EnvironmentObject var episodes: WatchEpisodeStore
    @EnvironmentObject var audio: WatchAudioPlayer
    @EnvironmentObject var remote: WatchPhoneRemote

    let type: WatchWorkoutType

    var body: some View {
        HoldToConfirmButton(
            duration: 1.5,
            tint: .orange,
            action: start,
            label: { holding in
                VStack(alignment: .leading, spacing: 1) {
                    Label(type.name, systemImage: type.icon)
                    Text(holding ? "Keep holding…" : subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            }
        )
        .disabled(!recorder.isAuthorized)
        .frame(maxWidth: .infinity, minHeight: 48)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .accessibilityLabel("Start \(type.name) workout")
        .accessibilityHint("Hold for one and a half seconds to start")
    }

    /// Pool swims say which pool they will measure against, before you're in the water: every
    /// length is counted at this value, and a wrong one is invisible once the swim has started.
    private var subtitle: String {
        guard type.swimmingLocation == .pool else { return "Hold to start" }
        return "Hold to start · \(Self.poolLabel(episodes.poolLengthMeters)) pool"
    }

    static func poolLabel(_ meters: Double) -> String {
        switch meters {
        case 22.8...22.9: return "25 yd"
        case 33.3...33.4: return "33⅓ m"
        default: return "\(Int(meters.rounded())) m"
        }
    }

    private func start() {
        recorder.start(
            activity: type.activity,
            name: type.name,
            indoor: type.indoor,
            splitDistanceMeters: episodes.useMiles ? 1609.344 : 1000,
            paceWindowMeters: episodes.useMiles ? 402.336 : 400,
            swimmingLocation: type.swimmingLocation,
            lapLengthMeters: type.swimmingLocation == .pool ? episodes.poolLengthMeters : nil
        )
        guard recorder.isRecording else { return }
        if type.activity == .swimming {
            audio.pause()
            remote.send("pause")
            return
        }
        // Without headphones a workout starts in silence rather than on the Watch's speaker.
        if WorkoutMediaRouting.shouldAutoStartOnWatch(
            hasWatchEpisode: audio.currentID != nil,
            phoneIsPlaying: remote.isPlaying,
            hasHeadphones: audio.sessionReachesHeadphones(announce: false)
        ) {
            audio.playWorkout(
                preferredPodcasts: episodes.workoutPodcasts,
                episodes: episodes.episodes,
                store: episodes)
        }
    }
}

private struct WatchMoreWorkoutsView: View {
    let types: [WatchWorkoutType]

    var body: some View {
        List(types) { type in
            WatchWorkoutStartRow(type: type)
        }
        .navigationTitle("More")
    }
}

private struct WatchWorkoutHistoryView: View {
    @EnvironmentObject var recorder: WorkoutRecorder

    var body: some View {
        List {
            if recorder.savedSessions.isEmpty {
                Text("No workouts recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recorder.savedSessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.activity).font(.footnote.weight(.medium))
                        Text(session.start.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(clock(session.duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { recorder.deleteSession(session.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
    }
}

// MARK: - Active workout (its own paged screen while recording)

/// Full-screen workout view shown while recording. Three vertically-paged screens so
/// nothing has to scroll on a watch face:
///   • Metrics — hero timer, HR / energy / distance, and split time.
///   • Splits — current progress, recent splits, and the hold-to-end control.
///   • Media — now playing + transport.
struct ActiveWorkoutView: View {
    // Only isRecording/isPoolSwimming/isSwimTouchInputLocked/etc. remain @Published on
    // WorkoutRecorder itself — the 1 Hz-ticking numbers live on `recorder.live`
    // (WorkoutLiveMetrics, see WorkoutRecorder.swift), which this view hands down to
    // WorkoutMetricsPage/WorkoutSplitsPage. That keeps this view (and mediaPage, which reads
    // none of the ticking fields) from re-rendering every second.
    @EnvironmentObject var recorder: WorkoutRecorder
    @EnvironmentObject var audio: WatchAudioPlayer
    @EnvironmentObject var episodes: WatchEpisodeStore
    @EnvironmentObject var remote: WatchPhoneRemote
    @ObservedObject private var voice = WatchVoiceRecorder.shared

    @State private var page = 0
    @State private var showEpisodePicker = false

    var body: some View {
        TabView(selection: $page) {
            WorkoutMetricsPage(
                live: recorder.live,
                showsPace: recorder.showsPace,
                isPoolSwimming: recorder.isPoolSwimming,
                useMiles: episodes.useMiles,
                showsRestTimer: recorder.showsRestTimer,
                restDeadline: recorder.restDeadline,
                startRest: { recorder.startRest(seconds: $0) },
                cancelRest: { recorder.cancelRest() }
            ).tag(0)
            WorkoutSplitsPage(
                live: recorder.live,
                isPoolSwimming: recorder.isPoolSwimming,
                onPauseToggle: { recorder.togglePause() },
                onEnd: { recorder.stop() }
            ).tag(1)
            // Always reachable — even with nothing playing yet. Gating this page on
            // `currentID != nil` was the "no way to switch podcasts mid-workout" bug: if the
            // workout started with no episode auto-picked (or the audio is on the phone), the
            // page vanished and the picker with it. Now the page is always there and shows a
            // "choose episode" state when the watch isn't playing anything.
            mediaPage.tag(2)
        }
        .tabViewStyle(.verticalPage)
        // Water Lock is the primary protection and gives the swimmer the familiar Crown-to-eject
        // water escape hatch. This invisible shield closes the start-up race before watchOS has
        // acknowledged the lock, so neither a page swipe nor the end control can fire from water.
        .overlay {
            if recorder.isSwimTouchInputLocked {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--splits-page") { page = 1 }
            if ProcessInfo.processInfo.arguments.contains("--media-page") { page = 2 }
        }
        #endif
    }

    // MARK: Media page

    @ViewBuilder private var mediaPage: some View {
        Group {
            switch WorkoutMediaRouting.source(
                hasWatchEpisode: audio.currentID != nil,
                hasPhoneEpisode: remote.isActive
            ) {
            case .watch:
                nowPlayingControls
            case .phone:
                phoneNowPlayingControls
            case .none:
                chooseEpisodePrompt
            }
        }
        .padding(.horizontal, 8)
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerView(onPick: { ep in
                audio.play(ep, url: episodes.localURL(for: ep))
                showEpisodePicker = false
            })
        }
    }

    /// Transport controls for a podcast whose audio remains on the iPhone.
    private var phoneNowPlayingControls: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            Text("ON IPHONE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            Text(remote.title)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if !remote.podcast.isEmpty {
                Text(remote.podcast)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                Button { remote.send("skipBack") } label: { Image(systemName: "gobackward.15") }
                Spacer()
                Button { remote.send(remote.isPlaying ? "pause" : "play") } label: {
                    Image(systemName: remote.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                }
                Spacer()
                Button { remote.send("skipFwd") } label: { Image(systemName: "goforward.30") }
            }
            .buttonStyle(.plain).tint(.orange).font(.title2)

            HStack(spacing: 14) {
                // The phone's speed, for what the phone is playing.
                WatchSpeedButton(speed: remote.speed) { remote.cycleSpeed() }
                Button { showEpisodePicker = true } label: {
                    Label("Switch", systemImage: "list.bullet").font(.caption2)
                }
                .buttonStyle(.plain).tint(.secondary)

                workoutNoteButton
            }

            Spacer(minLength: 0)
        }
    }

    /// Transport + "Switch" — shown when the watch is the thing playing audio.
    private var nowPlayingControls: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            if let title = audio.currentTitle {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            WatchMediaProgress(clock: audio.clock, duration: audio.duration)
                .padding(.horizontal, 4)

            HStack(spacing: 0) {
                Button { audio.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                Spacer()
                Button { audio.togglePlayPause() } label: {
                    Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                }
                Spacer()
                Button { audio.skip(by: 30) } label: { Image(systemName: "goforward.30") }
            }
            .buttonStyle(.plain).tint(.orange).font(.title2)

            // Switch what's playing without leaving the workout — the pool auto-picks one on start,
            // but you can change your mind mid-run.
            HStack(spacing: 14) {
                WatchSpeedButton(speed: audio.speed) { audio.cycleSpeed() }
                Button { showEpisodePicker = true } label: {
                    Label("Switch", systemImage: "list.bullet").font(.caption2)
                }
                .buttonStyle(.plain).tint(.secondary)

                workoutNoteButton
            }

            Spacer(minLength: 0)
        }
    }

    /// Start/stop a voice note without leaving the workout. The Action Button is the eyes-free way to
    /// do this on the Ultra; this on-screen button is the fallback for every other watch. The recorder
    /// routes itself (records on whichever device holds the audio), so here we just toggle it.
    private var workoutNoteButton: some View {
        let rec = voice.anyRecording
        return Button { voice.toggle() } label: {
            Label(rec ? "Stop" : "Note", systemImage: rec ? "stop.circle.fill" : "mic.fill")
                .font(.caption2)
        }
        .buttonStyle(.plain).tint(rec ? .red : .orange)
    }

    /// Nothing playing on the watch — a prominent way into the picker so a workout that started
    /// silent (nothing auto-picked, or audio living on the phone) can still choose something.
    private var chooseEpisodePrompt: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "headphones").font(.title2).foregroundStyle(.secondary)
            Text("Nothing playing").font(.footnote).foregroundStyle(.secondary)
            Button { showEpisodePicker = true } label: {
                Label("Choose episode", systemImage: "list.bullet")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.borderedProminent).tint(.orange)

            // A note doesn't need audio playing — capture a thought mid-set even in silence.
            workoutNoteButton
            Spacer(minLength: 0)
        }
    }
}

/// Six equal tiles filling the screen — time, heart rate, pace, distance, calories, and split.
///
/// The old layout centred a stack in the middle of the watch and let the edges go to waste,
/// which meant the numbers had to be small to fit. Giving every value the same rectangle and
/// pushing them to the edges means each one can be as large as its cell allows: the type is set
/// big and shrinks only if a value genuinely needs the room (a 3-digit heart rate, 10:00 pace).
/// Read at arm's length, while moving, which is the only way this screen is ever read.
///
/// Observes `WorkoutLiveMetrics` directly (not `WorkoutRecorder`) so this is the only page that
/// re-renders on the 1 Hz tick — the splits page, media page, and the rest of the app don't.
private struct WorkoutMetricsPage: View {
    @ObservedObject var live: WorkoutLiveMetrics
    let showsPace: Bool
    let isPoolSwimming: Bool
    let useMiles: Bool
    let showsRestTimer: Bool
    let restDeadline: Date?
    let startRest: (Int) -> Void
    let cancelRest: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                // Paused: the time stands still and says why.
                tile(clock(live.elapsed), live.isPaused ? "PAUSED" : "TIME", live.isPaused ? .yellow : .orange)
                tile(live.heartRate > 0 ? "\(Int(live.heartRate))" : "—", "BPM", .red)
            }
            if showsRestTimer {
                VStack(spacing: 5) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = WorkoutRestTimer.remaining(until: restDeadline, now: context.date)
                        HStack {
                            Label("REST", systemImage: "timer").font(.caption2.weight(.bold))
                            Spacer()
                            Text(restDeadline == nil ? "Ready" : clock(TimeInterval(remaining)))
                                .font(.title3.monospacedDigit()).foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    HStack(spacing: 4) {
                        Button("30s") { startRest(30) }.accessibilityLabel("Start 30 second rest")
                        Button("1 min") { startRest(60) }.accessibilityLabel("Start 1 minute rest")
                        if restDeadline != nil {
                            Button(action: cancelRest) { Image(systemName: "xmark") }
                                .accessibilityLabel("Cancel rest timer")
                        }
                    }
                    .buttonStyle(.bordered).tint(.orange)
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            } else {
            HStack(spacing: 3) {
                if showsPace {
                    // Running/walking/hiking: pace earns a tile. On a rowing machine or under a
                    // barbell it would be noise, so distance takes the whole row instead.
                    tile(paceLabel(live.pace), useMiles ? "¼ MI" : "400 M", .green)
                }
                tile(distanceLabel(live.distance), isPoolSwimming ? "LAPS" : "DIST", .cyan)
            }
            }
            HStack(spacing: 3) {
                tile("\(Int(live.energy))", "KCAL", .yellow)
                if live.supportsDistanceSplits {
                    tile(splitTileTime, splitTileLabel, .purple)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // take the whole face, not a band in the middle
        .padding(.horizontal, 3)
        .padding(.bottom, 2)
        .ignoresSafeArea(edges: .bottom)   // the bottom inset is reserved for a home indicator the watch doesn't have
    }

    private var splitTileTime: String {
        clock(live.splits.last?.duration ?? live.currentSplitElapsed)
    }

    private var splitTileLabel: String {
        if isPoolSwimming {
            return live.splits.isEmpty ? "CURRENT LAP" : "LAST LAP"
        }
        return live.splits.isEmpty ? "CURRENT SPLIT" : "LAST SPLIT"
    }

    private func distanceLabel(_ meters: Double) -> String {
        if isPoolSwimming, let lapLength = live.splitDistanceMeters, lapLength > 0 {
            // Pool distance is useful to the swimmer as a count of completed lengths. HealthKit
            // still records metres underneath; this is only the Watch presentation.
            return "\(Int((meters / lapLength).rounded(.down)))"
        }
        if useMiles {
            let miles = meters / 1609.344
            return miles >= 0.1 ? String(format: "%.2f mi", miles) : "\(Int(meters * 3.28084)) ft"
        }
        return meters >= 1000 ? String(format: "%.2f km", meters / 1000) : "\(Int(meters)) m"
    }

    /// `pace` is seconds per meter. Shown as minutes per mile/km — the units a runner actually
    /// thinks in. An em-dash until there's enough movement to be honest about it: a made-up pace
    /// is worse than none, because you'd chase it.
    private func paceLabel(_ secondsPerMeter: Double) -> String {
        guard secondsPerMeter > 0 else { return "—" }
        let perUnit = secondsPerMeter * (useMiles ? 1609.344 : 1000)
        guard perUnit.isFinite, perUnit < 60 * 60 else { return "—" }   // slower than an hour: not a pace
        let minutes = Int(perUnit) / 60
        let seconds = Int(perUnit) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// One value in a tinted rectangle that fills its share of the screen.
    private func tile(_ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.35).lineLimit(1)
            Text(unit)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Current progress, recent splits, and the hold-to-end control. Observes `WorkoutLiveMetrics`
/// directly (see `WorkoutMetricsPage` doc comment) so it re-renders only on an actual split
/// crossing/distance update, not on every 1 Hz elapsed tick.
private struct WorkoutSplitsPage: View {
    @ObservedObject var live: WorkoutLiveMetrics
    let isPoolSwimming: Bool
    let onPauseToggle: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("SPLITS").font(.caption.weight(.bold)).tracking(0.7)
                Spacer()
            }

            if let interval = live.splitDistanceMeters {
                VStack(spacing: 3) {
                    HStack {
                        Text("NOW").font(.caption2.weight(.bold))
                        Spacer()
                        Text("\(currentSplitDistanceLabel)  ·  \(clock(live.currentSplitElapsed))")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    ProgressView(value: min(1, live.currentSplitDistanceMeters / interval))
                        .tint(.purple)
                }
                .padding(.horizontal, 7)
                .frame(height: 34)
                .background(Color.purple.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))

                if live.splits.isEmpty {
                    Text("Completed splits appear here")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                } else {
                    ForEach(Array(live.splits.suffix(3).reversed())) { split in
                        HStack {
                            Text("#\(split.number)  \(splitUnitLabel)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(clock(split.duration)).monospacedDigit()
                        }
                        .font(.caption.weight(.semibold))
                        .frame(height: 20)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Spacer(minLength: 0)
                Text("Distance splits aren’t tracked for this workout.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }

            // Pause beside End: a tap, since a pause is taken back with another tap. (End is a
            // hold because it isn't.)
            HStack(spacing: 4) {
                PauseResumeButton(isPaused: live.isPaused, action: onPauseToggle)
                HoldToEndButton(duration: 2, action: onEnd)
            }
            .frame(height: 48)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private var splitUnitLabel: String {
        if isPoolSwimming { return "LAP" }
        return (live.splitDistanceMeters ?? 1000) > 1200 ? "MI" : "KM"
    }

    private var currentSplitDistanceLabel: String {
        guard let interval = live.splitDistanceMeters else { return "—" }
        if isPoolSwimming {
            return String(format: "%.2f lap", live.currentSplitDistanceMeters / interval)
        }
        return String(format: "%.2f %@", live.currentSplitDistanceMeters / interval, splitUnitLabel.lowercased())
    }
}

// MARK: - Hold-to-confirm controls

/// The only path to `action` is completion of the native long-press gesture. A tap starts and
/// immediately cancels the visual fill; it never primes a second interaction or fires a haptic.
struct HoldToConfirmButton<Label: View>: View {
    var duration: Double = 2
    var tint: Color
    var drawsRestingBackground: Bool
    var action: () -> Void
    private let label: (Bool) -> Label

    @Environment(\.isEnabled) private var isEnabled
    @State private var progress: Double = 0
    @State private var holding = false
    @State private var completing = false

    init(
        duration: Double = 2,
        tint: Color,
        drawsRestingBackground: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping (Bool) -> Label
    ) {
        self.duration = duration
        self.tint = tint
        self.drawsRestingBackground = drawsRestingBackground
        self.action = action
        self.label = label
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The background owns the progress geometry. Its bounds are the button's exact
            // bounds, so the fill starts at x = 0 rather than at a scaled shape's visible edge.
            shape.fill(drawsRestingBackground ? Color.white.opacity(0.10) : Color.clear)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(tint.opacity(0.42))
                            .frame(width: proxy.size.width * progress, height: proxy.size.height)
                    }
                }
            label(holding)
                .padding(.horizontal, 8)
        }
        .clipShape(shape)
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.45)
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 24) {
            guard isEnabled, !completing else { return }
            completing = true
            holding = true
            // The gesture threshold and the fill animation end together. Keep the completed
            // state on screen briefly so the Watch can render a genuinely full final frame
            // before the action changes views.
            withAnimation(.linear(duration: 0.1)) { progress = 1 }
            #if os(watchOS)
            WKInterfaceDevice.current().play(.success)
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                action()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    holding = false
                    progress = 0
                    completing = false
                }
            }
        } onPressingChanged: { pressing in
            guard isEnabled else { return }
            if pressing {
                guard !completing else { return }
                holding = true
                progress = 0
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else if holding, !completing {
                holding = false
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// Pause a workout, or carry on: one tap either way.
struct PauseResumeButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill").font(.system(size: 22, weight: .bold))
                Text(isPaused ? "RESUME" : "PAUSE")
                    .font(.system(size: 9, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(isPaused ? .black : .white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isPaused ? Color.green : Color.yellow.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume workout" : "Pause workout")
        .accessibilityIdentifier("watch.workout.pause")
    }
}

/// Full-size workout tile using the same one-step hold interaction as workout start rows.
struct HoldToEndButton: View {
    var duration: Double = 2
    var action: () -> Void

    var body: some View {
        HoldToConfirmButton(duration: duration, tint: .red, action: action) { holding in
            VStack(spacing: 0) {
                Image(systemName: "stop.fill").font(.system(size: 22, weight: .bold))
                Text(holding ? "KEEP HOLDING" : "HOLD TO END")
                    .font(.system(size: 9, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("End workout")
        .accessibilityHint("Hold for two seconds to end")
    }
}

// MARK: - Podcasts tab

struct WatchPodcastsView: View {
    @EnvironmentObject var episodes: WatchEpisodeStore
    @EnvironmentObject var audio: WatchAudioPlayer
    @EnvironmentObject var downloader: WatchDownloadManager
    @EnvironmentObject var remote: WatchPhoneRemote

    /// When the running binary was built, read from the executable's own file date. Reflects the
    /// actual installed build, so it changes every deploy — the reliable "did my new build land" tell.
    static let buildStamp: String = {
        guard let url = Bundle.main.executableURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: date)
    }()

    /// Interrupt the phone's podcast to record a voice note. The phone does the recording (it holds
    /// the AirPods mic); this is the trigger. Reflects the live recording state pushed back.
    @ObservedObject private var voice = WatchVoiceRecorder.shared
    private var noteButton: some View {
        let rec = voice.anyRecording
        return Button { voice.toggle() } label: {
            Label(rec ? "Stop note" : "Record note", systemImage: rec ? "stop.circle.fill" : "mic.fill")
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(rec ? .red : .orange)
    }

    var body: some View {
        NavigationStack {
            List {
                #if DEBUG
                // Dev builds only. This section interpolates `audio.currentTime`, which ticks at
                // 1 Hz during playback — shipping it in release forced a whole-List re-render
                // (plus the orderedEpisodes sort) every second the Podcasts tab was up.
                Section("DEBUG") {
                    // The installed binary's own build time. Ends the "is this actually on my watch?"
                    // guessing — glance here and you know exactly which build is running.
                    Text("build \(Self.buildStamp)")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    Text("pool(\(episodes.workoutPodcasts.count)): \(episodes.workoutPodcasts.joined(separator: " · "))")
                        .font(.caption2).foregroundStyle(.orange)
                    WatchDebugClockText(
                        currentID: audio.currentID,
                        duration: audio.duration,
                        clock: audio.clock)
                    ForEach(episodes.episodes.prefix(4)) { e in
                        Text("[\(e.podcast.prefix(12))] p=\(Int(episodes.positions[e.id] ?? -1)) d=\(Int(episodes.durations[e.id] ?? -1))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                #endif

                if remote.isActive {
                    Section("On iPhone") {
                        Text(remote.title).font(.footnote).lineLimit(2)
                        HStack {
                            Button { remote.send("skipBack") } label: { Image(systemName: "gobackward.15") }
                            Spacer()
                            Button { remote.send(remote.isPlaying ? "pause" : "play") } label: {
                                Image(systemName: remote.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
                            }
                            Spacer()
                            Button { remote.send("skipFwd") } label: { Image(systemName: "goforward.30") }
                        }
                        .buttonStyle(.plain).tint(.orange)
                        // The phone's speed, for what the phone is playing.
                        WatchSpeedButton(speed: remote.speed, labelled: true) { remote.cycleSpeed() }

                        noteButton
                    }
                }

                if !downloader.active.isEmpty {
                    Section("Downloading") {
                        ForEach(downloader.active) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.caption2).lineLimit(1)
                                ProgressView(value: item.fraction).tint(.orange)
                            }
                        }
                    }
                }
                if let title = audio.currentTitle, audio.currentID != nil {
                    Section("Now Playing") {
                        Text(title).font(.footnote).lineLimit(2)
                        HStack {
                            Button { audio.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                            Spacer()
                            Button { audio.togglePlayPause() } label: {
                                Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
                            }
                            Spacer()
                            Button { audio.skip(by: 30) } label: { Image(systemName: "goforward.30") }
                        }
                        .buttonStyle(.plain).tint(.orange)
                        WatchSpeedButton(speed: audio.speed, labelled: true) { audio.cycleSpeed() }
                    }
                }

                if episodes.episodes.isEmpty {
                    Section {
                        Label("No downloads", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Turn on “Sync to Apple Watch” for a podcast on your iPhone and download episodes.")
                    }
                } else {
                    ForEach(episodes.orderedEpisodes) { episode in
                        // Two different questions, and conflating them was the trap. `isLoaded` is
                        // "this is in the player right now" and decides whether a tap toggles or
                        // starts. `isCurrent` is "this is the one you'd resume" and drives the
                        // icon — it also covers the episode the PHONE handed over, which has no
                        // player state here yet. Toggling that one would do nothing at all.
                        let isLoaded = audio.currentID == episode.id
                        let isCurrent = isLoaded
                            || (audio.currentID == nil && episodes.currentEpisodeID == episode.id)
                        Button {
                            if isLoaded {
                                audio.togglePlayPause()
                            } else {
                                audio.play(episode, url: episodes.localURL(for: episode))
                            }
                        } label: {
                            HStack(spacing: 10) {
                                WatchEpisodePlayIcon(
                                    isCurrent: isCurrent,
                                    isPlaying: audio.isPlaying,
                                    storedProgress: episodes.progress(for: episode.id),
                                    duration: audio.duration,
                                    clock: audio.clock)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(episode.title).font(.footnote).lineLimit(2)
                                    Text(episode.podcast).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                if audio.currentID == episode.id { audio.stop() }
                                episodes.delete(episode)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("Podcasts")
        }
    }
}

/// The only active-workout media subview that needs one-second playhead updates.
private struct WatchMediaProgress: View {
    @ObservedObject var clock: WatchPlaybackClock
    let duration: TimeInterval

    private var progress: Double {
        duration > 0 ? min(1, max(0, clock.time / duration)) : 0
    }

    var body: some View {
        ProgressView(value: progress).tint(.orange)
    }
}

#if DEBUG
private struct WatchDebugClockText: View {
    let currentID: String?
    let duration: TimeInterval
    @ObservedObject var clock: WatchPlaybackClock

    var body: some View {
        Text("cur=\(currentID?.prefix(6).description ?? "nil") dur=\(Int(duration)) t=\(Int(clock.time))")
            .font(.caption2)
    }
}
#endif

/// Isolates live playhead observation to a 28×28 progress ring instead of invalidating and
/// re-sorting the complete podcast list every second.
/// The speed button: shows the speed, and a tap goes to the next one up (round to the slowest).
struct WatchSpeedButton: View {
    let speed: Double
    /// A row of its own in a list ("Speed 1.5×"); otherwise just the number, beside other buttons.
    var labelled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if labelled {
                HStack {
                    Label("Speed", systemImage: "gauge.with.dots.needle.50percent").font(.caption)
                    Spacer()
                    Text(PlaybackSpeeds.label(speed)).font(.caption.weight(.semibold).monospacedDigit())
                }
            } else {
                Text(PlaybackSpeeds.label(speed))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .tint(.orange)
        .accessibilityLabel("Speed \(PlaybackSpeeds.label(speed))")
        .accessibilityHint("Changes to the next speed")
        .accessibilityIdentifier("watch.speed")
    }
}

private struct WatchEpisodePlayIcon: View {
    let isCurrent: Bool
    let isPlaying: Bool
    let storedProgress: Double?
    let duration: TimeInterval
    @ObservedObject var clock: WatchPlaybackClock

    private var progress: Double? {
        if isCurrent, duration > 0 {
            return min(1, max(0, clock.time / duration))
        }
        return storedProgress
    }

    var body: some View {
        ZStack {
            if let progress {
                Circle().stroke(Color.orange.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
        .frame(width: 28, height: 28)
    }
}

private func clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// A quick list of the episodes downloaded to the Watch, so you can change what's playing during a
/// workout. Shows the ones you're mid-way through first.
struct EpisodePickerView: View {
    @EnvironmentObject var episodes: WatchEpisodeStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (WatchEpisode) -> Void

    private var ordered: [WatchEpisode] {
        episodes.episodes.sorted { episodes.position(for: $0.id) > episodes.position(for: $1.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if ordered.isEmpty {
                    Text("No downloaded episodes on the Watch.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(ordered) { ep in
                    Button { onPick(ep) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.title).font(.footnote).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(ep.podcast).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if episodes.position(for: ep.id) > 30 {
                                    Text("· resume").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Play")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
