import SwiftUI

/// Sleep at a glance, on the phone and the Mac: last night — how long, and every time you were
/// up and what for — the week, and how the last two weeks average out. Each wake-up can be
/// relabelled in a tap, which also teaches the guesses.
struct SleepView: View {
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var smart: SmartScheduleStore
    @State private var expandedNight: Date?

    /// Newest first, with your labels and the baby-duty switch applied.
    private var nights: [NightSummary] {
        SleepNights.classified(health.trends.nights, labels: smart.nightWakeLabelKinds,
                               babyDuty: smart.settings.babyDutyAtNight)
            .sorted { $0.night > $1.night }
    }

    var body: some View {
        let _ = RenderStats.note("SleepView")
        // A grouped list, as Notes and Review are: each part a section under the system's own
        // header, not rows straight on the page under black titles.
        List {
            let nights = nights
            if let last = nights.first {
                lastNight(last)
            } else {
                Section {
                    ContentUnavailableView {
                        Label("No nights yet", systemImage: "bed.double")
                    } description: {
                        Text("Wear your Apple Watch to bed, and your nights and wake-ups appear here.")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            let week = Array(health.trends.sleepHours.suffix(7))
            if !week.isEmpty {
                Section {
                    // The card is the row: no second card around it.
                    SleepWeekCard(sleep: week)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if nights.count > 1 { averages(nights) }
            if nights.count > 1 { earlier(Array(nights.dropFirst())) }
            babyDuty(nights)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        // A column in the middle of an iPad or a wide window, not rows stretched across it.
        .readableColumn()
        .navigationTitle("Sleep")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Health is otherwise only re-read from the Workouts tab. Hand-washing is new since Health
        // was connected, so this is where it's asked for.
        .task {
            if await health.requestNewReadAccessIfNeeded() {
                await health.refresh()
            } else {
                await health.refreshIfStale()
            }
        }
        .refreshable { await health.refresh() }
    }

    // MARK: - Last night

    @ViewBuilder private func lastNight(_ night: NightSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                StatValue(label: Calendar.current.isDateInToday(night.night) ? "Last night" : night.night.formatted(.dateTime.weekday(.wide).month().day()),
                          value: SleepNights.duration(night.asleepMinutes), size: .hero)
                Text("\(night.bedtime.formatted(date: .omitted, time: .shortened)) \u{2013} \(night.wake.formatted(date: .omitted, time: .shortened)) \u{00B7} \(SleepNights.upLine(night))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: DS.Space.s) {
                    tile("Awake", SleepNights.duration(SleepNights.awakeMinutes(night)))
                    tile("Longest sleep", SleepNights.duration(SleepNights.longestSleepMinutes(night)))
                    tile("First trip", SleepNights.firstTripMinutes(night).map { SleepNights.duration($0) } ?? "None")
                }
            }
            .padding(.vertical, DS.Space.xs)
            let unconfirmed = SleepNights.unconfirmed(night)
            if !unconfirmed.isEmpty {
                Button {
                    for wake in unconfirmed { smart.labelNightWake(wake, as: wake.kind) }
                } label: {
                    Label(unconfirmed.count == 1 ? "That\u{2019}s right" : "These are right", systemImage: "checkmark")
                }
                .buttonStyle(.secondary)
                .accessibilityIdentifier("sleep.confirmGuesses")
            }
        }
        if !night.wakes.isEmpty {
            Section("Wake-ups") {
                WakeList(wakes: night.wakes) { wake, kind in smart.labelNightWake(wake, as: kind) }
            }
        }
    }

    // MARK: - Two weeks

    private func averages(_ nights: [NightSummary]) -> some View {
        let recent = Array(nights.prefix(14))
        return Section("Last \(recent.count) nights") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: DS.Space.s)], spacing: DS.Space.m) {
                tile("Asleep", SleepNights.averageAsleepMinutes(recent).map { SleepNights.duration($0) })
                tile("Awake", SleepNights.averageMinutes(recent, SleepNights.awakeMinutes).map { SleepNights.duration($0) })
                tile("Up a night", SleepNights.average(recent, \.timesUp).map { String(format: "%.1f", $0) })
                tile("Bathroom", SleepNights.average(recent) { $0.count(.bathroom) }.map { String(format: "%.1f", $0) })
                tile("2+ trips", "\(SleepNights.nightsWithTwoOrMoreTrips(recent)) of \(recent.count)")
                if smart.settings.babyDutyAtNight || recent.contains(where: { $0.count(.baby) > 0 }) {
                    tile("Baby", SleepNights.average(recent) { $0.count(.baby) }.map { String(format: "%.1f", $0) })
                }
            }
            .padding(.vertical, DS.Space.xs)
        }
    }

    /// A number in a row: the row is the card, so the tile has none of its own.
    private func tile(_ label: String, _ value: String?) -> some View {
        StatValue(label: label, value: value ?? DS.placeholder, size: .tile)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Earlier nights

    private func earlier(_ nights: [NightSummary]) -> some View {
        Section("Earlier") {
            ForEach(nights) { night in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        expandedNight = expandedNight == night.night ? nil : night.night
                    }
                } label: {
                    HStack {
                        Text(night.night.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        Spacer()
                        Text(SleepNights.upLine(night)).foregroundStyle(.secondary).lineLimit(1)
                        Text(SleepNights.duration(night.asleepMinutes)).monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expandedNight == night.night ? 90 : 0))
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expandedNight == night.night, !night.wakes.isEmpty {
                    WakeList(wakes: night.wakes) { wake, kind in smart.labelNightWake(wake, as: kind) }
                }
            }
        }
    }

    // MARK: - Baby duty, and where the numbers come from

    private func babyDuty(_ nights: [NightSummary]) -> some View {
        Section {
            Toggle(isOn: Binding(get: { smart.settings.babyDutyAtNight },
                                 set: { smart.settings.babyDutyAtNight = $0 })) {
                Label("Baby duty at night", systemImage: NightWakeKind.baby.symbol)
            }
            .formControls()
        } footer: {
            Text("Longer trips are guessed as the baby.")
        }
    }
}

/// A night's wake-ups: a row for each time you got up and each long stretch awake in bed, and
/// the brief stretches in bed as one line that opens to show them (so they can still be
/// relabelled).
struct WakeList: View {
    let wakes: [NightWake]
    let relabel: (NightWake, NightWakeKind?) -> Void
    @State private var showsBrief = false

    var body: some View {
        let (listed, brief) = SleepNights.split(wakes)
        // List rows of their own, with the list's insets and separators.
        Group {
            ForEach(listed) { wake in
                WakeRow(wake: wake) { relabel(wake, $0) }
            }
            if !brief.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsBrief.toggle() }
                } label: {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: NightWakeKind.awakeInBed.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(SleepNights.briefLine(brief))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showsBrief ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sleep.briefWakes")
                if showsBrief {
                    ForEach(brief) { wake in
                        WakeRow(wake: wake) { relabel(wake, $0) }
                    }
                }
            }
        }
    }
}

/// One wake-up: when, what it was, how long and how many steps — and a menu to say what it
/// really was.
struct WakeRow: View {
    let wake: NightWake
    let relabel: (NightWakeKind?) -> Void

    var body: some View {
        Menu {
            ForEach(NightWakeKind.allCases, id: \.self) { kind in
                Button { relabel(kind) } label: {
                    Label(kind.label, systemImage: kind == wake.kind && wake.labelled ? "checkmark" : kind.symbol)
                }
            }
            if wake.labelled {
                Divider()
                Button("Let Banana guess") { relabel(nil) }
            }
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: wake.kind.symbol)
                    .foregroundStyle(wake.kind.gotUp ? DS.Palette.accent : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    HStack(spacing: DS.Space.xs) {
                        Text(wake.kind.label).foregroundStyle(.primary)
                        if !wake.labelled {
                            Text("guess").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text("\(SleepNights.duration(wake.minutes)) \u{00B7} \(wake.steps) steps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(wake.start.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Say what this was")
    }
}

/// Last night in a line — "7 h 12 m · Up 2×: bathroom, baby" — for the Sleep row in Workouts,
/// Today's morning card and the morning summary. Nothing when there's no recent night.
struct LastNightLine: View {
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var smart: SmartScheduleStore

    /// The newest night, if it ended in the last day.
    static func latest(_ nights: [NightSummary], labels: [String: NightWakeKind], babyDuty: Bool,
                       now: Date = Date()) -> NightSummary? {
        SleepNights.classified(nights, labels: labels, babyDuty: babyDuty)
            .max { $0.wake < $1.wake }
            .flatMap { now.timeIntervalSince($0.wake) < 20 * 3_600 ? $0 : nil }
    }

    var body: some View {
        if let night = Self.latest(health.trends.nights, labels: smart.nightWakeLabelKinds,
                                   babyDuty: smart.settings.babyDutyAtNight) {
            Text("\(SleepNights.duration(night.asleepMinutes)) \u{00B7} \(SleepNights.upLine(night))")
        }
    }
}

/// Last night as a card — time asleep and how many times you were up, and what for — opening
/// the Sleep page. On Today in the morning, and in the morning summary.
struct LastNightCard: View {
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var smart: SmartScheduleStore

    var body: some View {
        if let night = LastNightLine.latest(health.trends.nights, labels: smart.nightWakeLabelKinds,
                                            babyDuty: smart.settings.babyDutyAtNight) {
            NavigationLink { SleepView() } label: {
                HStack(spacing: DS.Space.m) {
                    IconTile(systemImage: "bed.double.fill", tint: DS.Palette.Feature.wake, style: .soft, size: DS.Row.glyphTile)
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text("Last night").font(.caption).foregroundStyle(.secondary)
                        Text(SleepNights.duration(night.asleepMinutes)).font(.headline.monospacedDigit())
                        Text(SleepNights.upLine(night)).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(DS.Space.m)
                .dsCard()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sleep.lastNight")
        }
    }
}

extension SmartScheduleStore {
    /// Your night wake-up labels, as kinds.
    var nightWakeLabelKinds: [String: NightWakeKind] {
        settings.nightWakeLabels.compactMapValues(NightWakeKind.init(rawValue:))
    }

    /// Say what a wake-up was (nil: let Banana guess again). Replaces a label on the same stretch
    /// even if its start has shifted a minute or two, and drops labels older than 60 days.
    func labelNightWake(_ wake: NightWake, as kind: NightWakeKind?) {
        var labels = settings.nightWakeLabels
        let minute = Int(wake.start.timeIntervalSince1970 / 60)
        for offset in -3...3 { labels[String(minute + offset)] = nil }
        if let kind { labels[SleepNights.labelKey(wake.start)] = kind.rawValue }
        let cutoff = minute - 60 * 24 * 60
        labels = labels.filter { (Int($0.key) ?? 0) >= cutoff }
        settings.nightWakeLabels = labels
    }
}
