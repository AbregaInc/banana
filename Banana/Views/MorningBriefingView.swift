import SwiftUI

/// The wake payoff: shown when you open the app within the wake window. Last
/// night's sleep, recovery, today's first meeting, and whatever's now playing.
struct MorningBriefingView: View {
    @EnvironmentObject var health: HealthKitStore
    @EnvironmentObject var smart: SmartScheduleStore
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var music: MusicController
    @EnvironmentObject private var fitness: FitnessStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modules = ModuleStore.shared

    /// Last 7 nights, shared by the "Last night" stat card and `SleepWeekCard` so the two never
    /// disagree. Live HealthKit on iOS; the phone-synced cache on the Mac (and anywhere else
    /// HealthKit itself isn't available).
    @State private var sleepWeek: [MetricPoint] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    // Health's cards are the Workouts and sleep module's.
                    if modules.includes(.workouts) {
                        if !cards.isEmpty {
                            VStack(spacing: 12) { ForEach(cards.indices, id: \.self) { cards[$0] } }
                        }
                        LastNightCard()   // times up in the night, and what for
                        if !sleepWeek.isEmpty { SleepWeekCard(sleep: sleepWeek) }
                        if let workout = yesterdaysWorkout { yesterdaysWorkoutLink(workout) }
                    }
                    if let meeting = nextMeetingToday { meetingCard(meeting) }
                    if modules.includes(.podcasts), player.currentEpisode != nil {
                        nowPlayingCard
                    } else if music.wakePlaying != nil {
                        musicWakeCard   // a music wake never touches the podcast player
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .groupedPage()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            // Health is otherwise only re-read from the Workouts tab — last night wouldn't be in yet.
            async let night: Void = health.refreshIfStale()
            await loadSleepWeek()
            await night
        }
    }

    private func loadSleepWeek() async {
        if health.isAvailable {
            let now = Date()
            let start = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
            let week = await health.rhythmHealth(from: start, to: now, bucket: .day)
            sleepWeek = week.sleep
        } else {
            sleepWeek = Array(health.trends.sleepHours.suffix(7))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TodayText.greeting()).font(.largeTitle.bold())
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.title3).foregroundStyle(.secondary)
        }
    }

    // MARK: - Cards

    private var cards: [AnyView] {
        // Last night is `LastNightCard`'s, below, with what woke you: a second "Last night" here
        // gave another number for it (the trend's hours against the night's own).
        var rows: [(title: String, value: String, icon: String, tint: Color)] = []
        if let rhr = health.trends.restingHR.last?.value {
            rows.append(("Resting HR", "\(Int(rhr)) bpm", "heart.fill", DS.Palette.danger))
        }
        if let hrv = health.trends.hrv.last?.value {
            rows.append(("HRV", "\(Int(hrv)) ms", "waveform.path.ecg", DS.Palette.success))
        }
        guard !rows.isEmpty else { return [] }
        // One grouped card with a row each, built as "Last night" is.
        return [AnyView(
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, DS.Space.m + DS.Row.glyphTile + DS.Space.m) }
                    statRow(rows[index].title, rows[index].value, rows[index].icon, rows[index].tint)
                }
            }
            .dsCard()
        )]
    }

    private func statRow(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: icon, tint: color, style: .soft, size: DS.Row.glyphTile)
            Text(title).font(.headline)
            Spacer()
            Text(value).font(.headline.monospacedDigit())
        }
        .padding(DS.Space.m)
    }

    private func meetingCard(_ meeting: Occurrence) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: "calendar", tint: DS.Palette.Feature.calendar, style: .soft, size: DS.Row.glyphTile)
            VStack(alignment: .leading, spacing: 2) {
                // What it is and how soon, not only a time.
                Text(meeting.title).font(.headline).lineLimit(2)
                Text("\(TimeRangeText.time(meeting.start)) \u{00B7} \(TodayText.countdown(to: meeting.start))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .groupedCard()
    }

    private var nowPlayingCard: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: player.isPlaying ? "waveform" : "pause.fill", tint: DS.Palette.Feature.wake,
                     style: .soft, size: DS.Row.glyphTile)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentEpisode?.title ?? "").font(.headline).lineLimit(2)
                Text("Wake source").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
            }.tint(DS.Palette.accent)
        }
        .groupedCard()
    }

    private func yesterdaysWorkoutLink(_ entry: WorkoutEntry) -> some View {
        NavigationLink {
            PostWorkoutReviewView(subject: WorkoutReviewSubject(summary: entry.summary, health: entry.health))
        } label: {
            HStack(spacing: DS.Space.m) {
                IconTile(systemImage: WorkoutActivityKind(activity: entry.activity).systemImage,
                         tint: DS.Palette.Feature.workouts, style: .soft, size: DS.Row.glyphTile)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yesterday's workout").font(.headline)
                    Text(workoutLine(entry)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .groupedCard()
        }
        .buttonStyle(.plain)
    }

    private func workoutLine(_ entry: WorkoutEntry) -> String {
        let minutes = entry.duration / 60
        return [entry.activity, minutes >= 1 ? DS.duration(minutes: minutes.rounded(.down)) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var musicWakeCard: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: "music.note", tint: DS.Palette.Feature.wake, style: .soft, size: DS.Row.glyphTile)
            VStack(alignment: .leading, spacing: 2) {
                Text(music.wakePlaying?.title ?? "").font(.headline).lineLimit(2)
                Text("Wake music").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { music.stopWake() } label: {
                Image(systemName: "stop.circle.fill").font(.largeTitle)
            }.tint(DS.Palette.accent)
        }
        .groupedCard()
    }

    // MARK: - Data

    /// The next meeting still to come today. It was the day's first by its time alone, which
    /// read "First meeting 9:00 AM" at four in the afternoon.
    private var nextMeetingToday: Occurrence? {
        let now = Date()
        return OccurrenceStore.shared.occurrences(on: now)
            .filter { $0.behavior == .event && $0.hasScheduledTime && !$0.skipped && $0.start > now }
            .min { $0.start < $1.start }
    }

    /// The most recent workout, if it happened within the last 20 hours — a run finished right
    /// before bed still reads as "yesterday's" the next morning, but nothing older belongs here.
    private var yesterdaysWorkout: WorkoutEntry? {
        guard let entry = WorkoutEntry.merge(summaries: fitness.summaries, health: health.workouts).first,
              entry.start > Date().addingTimeInterval(-20 * 60 * 60) else { return nil }
        return entry
    }

}
