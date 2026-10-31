import CoreLocation
import SwiftUI

/// "Where is “Chelsea”?" — the one question that makes a vague calendar location timeable.
///
/// Calendar events often name a neighbourhood or a brand instead of an address, and only you
/// know which one is meant. Banana asks once: the answer is remembered for every event with the
/// same location text, synced to your other devices, and every trip is re-timed straight away.
/// Businesses and landmarks near home come first, nearest first, with the distance shown so the
/// right one is easy to spot.
struct PlacePickerView: View {
    /// The calendar's location text, exactly as the event has it.
    let locationText: String
    /// What's being timed ("Lap Swim · 2:45 PM"), so the question has context.
    var context: String? = nil
    /// The event's title, which hints what kind of place to search for ("Lap Swim" → pools).
    var eventTitle: String? = nil

    @ObservedObject private var smart = SmartScheduleStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlaceCandidate] = []
    @State private var searching = false
    @State private var searched = false
    /// nil = automatic: walk if it's close, otherwise the default mode.
    @State private var mode: TransitMode?
    @State private var searchTask: Task<Void, Never>?

    private var current: SavedPlace? { smart.settings.savedPlaces.place(for: locationText) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if searching && results.isEmpty {
                        HStack(spacing: DS.Space.s) {
                            ProgressView()
                            Text("Searching near home…").foregroundStyle(.secondary)
                        }
                    } else if results.isEmpty && searched {
                        Text(smart.travelSearchCenter == nil ? "Set your home first" : "Nothing found")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { candidate in
                        Button { choose(candidate) } label: { row(candidate) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("placePicker.result")
                    }
                } header: {
                    Text(query == locationText ? "Near home" : "Results")
                }

                Section {
                    Picker("Getting there", selection: $mode) {
                        Text("Automatic").tag(TransitMode?.none)
                        ForEach(TransitMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage).tag(TransitMode?.some(mode))
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Where is this?")
            .searchable(text: $query, prompt: "Business name or address")
            .onSubmit(of: .search) { startSearch() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                query = locationText
                mode = current?.mode
                startSearch()
            }
            .onDisappear { searchTask?.cancel() }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 520, idealHeight: 600)
        #endif
    }


    private func row(_ candidate: PlaceCandidate) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: "mappin", tint: DS.Palette.travel, style: .soft)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(candidate.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = candidate.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s)
            Text(PlaceDistance.text(candidate.distanceMeters))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if isCurrent(candidate) {
                Image(systemName: "checkmark").foregroundStyle(DS.Palette.accent)
            }
        }
        .frame(minHeight: DS.Row.minHeight)
        .contentShape(Rectangle())
    }

    private func isCurrent(_ candidate: PlaceCandidate) -> Bool {
        guard let current else { return false }
        return abs(current.latitude - candidate.latitude) < 1e-5 && abs(current.longitude - candidate.longitude) < 1e-5
    }

    /// One search at a time: a slow earlier search must not land over a newer one's results.
    private func startSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        searching = true
        searchTask = Task {
            // The hint only helps the original question; a typed search is taken as it is.
            let title = text == locationText ? eventTitle : nil
            // Keyword results at once, then Apple Intelligence's when it has read the event.
            let quick = await smart.placeCandidates(for: text, eventTitle: title, useModel: false)
            guard !Task.isCancelled else { return }
            results = quick
            searched = true
            guard title != nil else { searching = false; return }
            let full = await smart.placeCandidates(for: text, eventTitle: title, useModel: true)
            guard !Task.isCancelled else { return }
            if !full.isEmpty { results = full }
            searching = false
        }
    }

    private func choose(_ candidate: PlaceCandidate) {
        smart.confirmPlace(locationText, name: candidate.name, address: candidate.subtitle,
                           coordinate: candidate.coordinate, mode: mode, replacingMode: true)
        ToastCenter.shared.notify("\u{201C}\(locationText)\u{201D} is \(candidate.name)")
        dismiss()
    }
}

/// How a meeting's trip there is timed — mode, minutes, place, leave-by — with the two things
/// you can change: which place it is, and how you get there. Shown in the event inspector
/// (Mac) and the event sheet (iPhone).
struct GettingThereView: View {
    enum Style {
        /// A section of the Mac inspector: eyebrow header, icon rows.
        case inspector
        /// A section of an iOS form.
        case form
    }

    let meeting: MeetingInfo
    var style: Style = .inspector
    @ObservedObject private var smart = SmartScheduleStore.shared
    @State private var picking = false

    /// The trip there: the live leg, or the reserved block's detail if routing hasn't run yet.
    private var leg: (leaveBy: Date, detail: TravelLegDetail)? {
        if let leg = smart.commuteLegs.first(where: {
            abs($0.start.timeIntervalSince(meeting.start)) < 60 && $0.title == meeting.title
        }), let detail = leg.detail {
            return (leg.leaveBy, detail)
        }
        if let block = OccurrenceStore.shared.occurrences.first(where: {
            $0.behavior == .block && $0.title == "Travel to \(meeting.title)"
                && abs($0.resolvedEnd.timeIntervalSince(meeting.start)) < 60
        }), let detail = block.travel {
            return (block.start, detail)
        }
        return nil
    }

    /// Nothing at all — not even a header — when there's no trip to show.
    var body: some View {
        if meeting.hasPhysicalLocation, meeting.start > Date(), let leg {
            switch style {
            case .inspector:
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("GETTING THERE")
                        .font(DS.Typeface.eyebrow)
                        .tracking(DS.Typeface.eyebrowTracking)
                        .foregroundStyle(.tertiary)
                    rows(leg)
                }
            case .form:
                Section("Getting there") { rows(leg) }
            }
        }
    }

    private func rows(_ leg: (leaveBy: Date, detail: TravelLegDetail)) -> some View {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                row(leg.detail.mode.systemImage) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(leg.detail.mode.label) · \(leg.detail.minutes) min")
                        Text("Leave by \(TimeRangeText.time(leg.leaveBy))")
                            .foregroundStyle(.secondary)
                        if let basis = leg.detail.basis {
                            Text(basis).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: DS.Space.s)
                    if !leg.detail.needsConfirming, let query = leg.detail.query {
                        modeMenu(query: query, detail: leg.detail)
                    }
                }
                row("mappin.and.ellipse") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(leg.detail.placeName ?? meeting.address ?? "")
                            .lineLimit(2)
                        if leg.detail.needsConfirming {
                            Text("A guess \u{2014} \u{201C}\(leg.detail.query ?? "")\u{201D} could be several places")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: DS.Space.s)
                    if leg.detail.query != nil {
                        Button(leg.detail.needsConfirming ? "Where is this?" : "Change") { picking = true }
                            .buttonStyle(.inline)
                            .accessibilityIdentifier("gettingThere.place")
                    }
                }
            }
            .sheet(isPresented: $picking) {
                PlacePickerView(locationText: leg.detail.query ?? meeting.address ?? "",
                                context: "\(meeting.title) at \(TimeRangeText.time(meeting.start))",
                                eventTitle: meeting.title)
            }
    }

    private func row<Content: View>(_ symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(DS.Palette.travel)
                .frame(width: 18)
            content()
        }
    }

    private func modeMenu(query: String, detail: TravelLegDetail) -> some View {
        let saved = smart.settings.savedPlaces.place(for: query)
        return Menu {
            Picker("Getting there", selection: Binding(
                get: { saved?.mode },
                set: { mode in
                    smart.setMode(mode, forPlace: query, fallbackName: detail.placeName ?? query,
                                  coordinate: saved?.coordinate ?? detail.coordinate ?? meeting.coordinate)
                }
            )) {
                Text("Automatic").tag(TransitMode?.none)
                ForEach(TransitMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(TransitMode?.some(mode))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("Mode")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("How you get to \(detail.placeName ?? query) — remembered for this place")
    }
}

/// The ask, where it pays off: the first upcoming trip timed to a guess gets a card on Today —
/// "Where is “Chelsea”?" — with the nearest matches in its picker. Answering fixes every event
/// with that location, on every device; nothing else ever interrupts to ask.
struct PlaceQuestionCard: View {
    @ObservedObject private var smart = SmartScheduleStore.shared
    @State private var picking = false

    /// Whether the card has anything to ask — so Today can show one prompt card at a time.
    static func hasQuestion(_ smart: SmartScheduleStore) -> Bool { question(in: smart) != nil }

    /// The soonest trip whose place is a guess. One question at a time.
    private var question: (leg: NotificationService.CommuteLeg, detail: TravelLegDetail, query: String)? {
        Self.question(in: smart)
    }

    private static func question(in smart: SmartScheduleStore)
    -> (leg: NotificationService.CommuteLeg, detail: TravelLegDetail, query: String)? {
        smart.commuteLegs
            .filter { $0.start > Date() }
            .sorted { $0.start < $1.start }
            .lazy
            .compactMap { leg in
                guard let detail = leg.detail, detail.needsConfirming, let query = detail.query,
                      smart.settings.savedPlaces.place(for: query) == nil else { return nil }
                return (leg, detail, query)
            }
            .first
    }

    var body: some View {
        if let question {
            // The plan's prompt shape: the picker lists the places near home, nearest first.
            PromptCard(symbol: "mappin.and.ellipse", tint: DS.Palette.travel,
                       title: "Where is \u{201C}\(question.query)\u{201D}?", id: "today.placeQuestion") {
                if let coordinate = question.detail.coordinate {
                    Button("Keep guess") {
                        smart.confirmPlace(question.query, name: question.detail.placeName ?? question.query,
                                           address: nil, coordinate: coordinate)
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("today.placeQuestion.keep")
                }
                Button("Choose") { picking = true }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("today.placeQuestion.choose")
            }
            .accessibilityIdentifier("today.placeQuestion")
            .sheet(isPresented: $picking) {
                PlacePickerView(locationText: question.query,
                                context: "\(question.leg.title) at \(TimeRangeText.time(question.leg.start))",
                                eventTitle: question.leg.title)
            }
        }
    }
}

/// Settings › Places: every location you've confirmed, what it means, and how you get there.
struct SavedPlacesView: View {
    @ObservedObject private var smart = SmartScheduleStore.shared
    @State private var editing: SavedPlace?

    var body: some View {
        List {
            if smart.settings.savedPlaces.isEmpty {
                Text("When an event's location could be several places, Banana asks which one you mean and remembers it here.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(smart.settings.savedPlaces.sorted { $0.query < $1.query }) { place in
                        HStack(spacing: DS.Space.m) {
                            IconTile(systemImage: place.mode?.systemImage ?? "mappin",
                                     tint: DS.Palette.travel, style: .soft)
                            VStack(alignment: .leading, spacing: DS.Space.hair) {
                                Text("\u{201C}\(place.query)\u{201D}")
                                Text(place.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: DS.Space.s)
                            Text(place.mode?.label ?? "Automatic")
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: DS.Row.minHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = place }
                        .contextMenu {
                            Button("Change place…") { editing = place }
                            Button("Forget", role: .destructive) { forget(place) }
                        }
                    }
                    .onDelete { offsets in
                        let sorted = smart.settings.savedPlaces.sorted { $0.query < $1.query }
                        offsets.map { sorted[$0] }.forEach(forget)
                    }
                } footer: {
                    Text("Each answer covers every event with that location, on all your devices.")
                }
            }
        }
        .navigationTitle("Places")
        .sheet(item: $editing) { place in
            PlacePickerView(locationText: place.query)
        }
    }

    private func forget(_ place: SavedPlace) {
        let smart = smart
        var places = smart.settings.savedPlaces
        places.removeAll { $0.query == place.query }
        smart.settings.savedPlaces = places
        Task {
            await ToastCenter.shared.offerUndo("Forgot \u{201C}\(place.query)\u{201D}") {
                var restored = smart.settings.savedPlaces
                restored.remember(place)
                smart.settings.savedPlaces = restored
                return nil
            }
        }
    }
}
