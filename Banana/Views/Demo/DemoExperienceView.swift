import SwiftUI
import Charts
import AVFoundation

struct DemoEntryButton: View {
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Label("Try with sample data", systemImage: "play.rectangle").frame(minHeight: 44) }
            .accessibilityIdentifier("demo.open")
            .demoPresentation(isPresented: $showing)
    }
}

private extension View {
    @ViewBuilder func demoPresentation(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { DemoExperienceView() }
        #else
        sheet(isPresented: isPresented) { DemoExperienceView().frame(minWidth: 900, minHeight: 650) }
        #endif
    }
}

private enum DemoSection: String, CaseIterable, Identifiable {
    case plan = "Plan", body = "Body", notes = "Notes", library = "Library"
    var id: String { rawValue }
    var symbol: String { switch self { case .plan: "sun.max"; case .body: "heart"; case .notes: "quote.bubble"; case .library: "books.vertical" } }
}

struct DemoExperienceView: View {
    @StateObject private var session = DemoSession()
    @StateObject private var audio = DemoNarration()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @State private var section: DemoSection = .plan
    @State private var editingEvent: DemoEvent?
    @State private var editingMeal: MealEntry?
    @State private var editingNote: VoiceNote?
    @State private var resetting = false
    @State private var bodyPage = 0
    @State private var recording = false
    @State private var archived = false
    @State private var noteFilter = LiveFilter(scope: "notes")
    @State private var workoutFilter = LiveFilter(scope: "workouts")

    private var wide: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if wide {
                NavigationSplitView {
                    List(DemoSection.allCases) { value in
                        Button { section = value } label: { Label(value.rawValue, systemImage: value.symbol) }
                            .buttonStyle(.plain)
                            .listRowBackground(section == value ? Color.accentColor.opacity(0.12) : Color.clear)
                            .accessibilityIdentifier("demo.tab.\(value.id.lowercased())")
                    }.navigationTitle("Banana demo")
                } detail: { navigation }
            } else {
                navigation
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        HStack {
                            ForEach(DemoSection.allCases) { value in
                                Button { section = value } label: {
                                    VStack(spacing: 4) { Image(systemName: value.symbol).font(.title3); Text(value.rawValue).font(.caption) }
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .foregroundStyle(section == value ? Color.accentColor : .secondary)
                                }.buttonStyle(.plain).accessibilityIdentifier("demo.tab.\(value.id.lowercased())")
                            }
                        }.background(.bar)
                    }
            }
        }
        .task { await session.load() }
        .sheet(item: $editingEvent) { DemoEventEditor(session: session, event: $0) }
        .sheet(item: $editingMeal) { DemoMealEditor(session: session, meal: $0) }
        .sheet(item: $editingNote) { DemoNoteEditor(session: session, note: $0) }
        .sheet(isPresented: $recording) { DemoWorkoutRecorder(session: session) }
        .confirmationDialog("Reset sample data?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset sample data", role: .destructive) { audio.stop(); Task { await session.reset() } }
        } message: { Text("Only changes made in this demo will be removed. Your personal data is unaffected.") }
        .onDisappear { audio.stop() }
        .onChange(of: phase) { _, phase in if phase != .active { audio.stop() } }
        .onChange(of: audio.finishedID) { _, id in
            guard let id, var episode = session.workspace?.episodes.first(where: { $0.id == id }) else { return }
            episode.listened = true
            Task { await session.perform(.saveEpisode(episode)) }
        }
    }

    private var navigation: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label("Demo", systemImage: "sparkles").font(.caption.weight(.semibold))
                    Text("Sample data · changes stay here").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding(.horizontal).padding(.vertical, 8).background(.tint.opacity(0.08))
                    .accessibilityIdentifier("demo.banner")
                if session.workspace != nil {
                    switch section {
                    case .plan: plan
                    case .body: bodyContent
                    case .notes: notes
                    case .library: library
                    }
                } else if session.error == nil {
                    ProgressView("Opening sample data…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Demo could not open", systemImage: "externaldrive.badge.exclamationmark", description: Text(session.error ?? ""))
                }
            }
            .navigationTitle(section.rawValue)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Exit demo") { audio.stop(); dismiss() }.disabled(session.saving > 0).accessibilityIdentifier("demo.exit")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Reset sample data", systemImage: "arrow.counterclockwise") { resetting = true }
                        Text("No Google account or native permissions are needed. Demo actions never send invitations, schedule notifications or change Apple Health.")
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Demo options")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = session.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("demo.error")
                        HStack {
                            if session.canRetrySave {
                                Button("Retry save") { Task { await session.retrySave() } }.disabled(session.saving > 0)
                            }
                            if session.workspace != nil { Button("Dismiss") { session.clearError() } }
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                }
            }
        }
    }

    private var plan: some View {
        VStack(spacing: 0) {
            if let workspace = session.workspace {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(workspace.tasks) { task in
                            Button {
                                Task { await session.perform(.completeTask(task.id, !task.completed)) }
                            } label: {
                                Label(task.title, systemImage: task.completed ? "checkmark.circle.fill" : task.kind == .routine ? "repeat" : "circle")
                                    .strikethrough(task.completed).font(.subheadline)
                                    .padding(.horizontal, 12).padding(.vertical, 9).background(.quaternary, in: Capsule())
                            }.buttonStyle(.plain).accessibilityValue(task.completed ? "Completed" : "Not completed")
                                .accessibilityIdentifier("demo.task.\(task.id.uuidString)")
                        }
                    }.padding()
                }
            }
            DemoCalendarView(session: session, editing: $editingEvent)
        }
    }

    private var bodyContent: some View {
        VStack {
            Picker("Body", selection: $bodyPage) { Text("Workouts and sleep").tag(0); Text("Food").tag(1) }
                .pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("demo.body.page")
            if bodyPage == 0 { workouts } else { meals }
        }
    }

    private var meals: some View {
        List {
            if let workspace = session.workspace {
                Section {
                    Button("Log a meal", systemImage: "plus") {
                        editingMeal = MealEntry(date: workspace.anchor, items: [.init(name: "", serving: "1 serving", macros: .init())])
                    }.accessibilityIdentifier("demo.meal.add")
                }
                Section("Meals") {
                    ForEach(workspace.meals.sorted { $0.date > $1.date }) { meal in
                        Button { editingMeal = meal } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(meal.name.isEmpty ? meal.items.map(\.name).joined(separator: ", ") : meal.name).font(.headline)
                                Text(meal.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                Text("\(meal.totals.calories.formatted(.number.precision(.fractionLength(0)))) kcal · \(meal.totals.proteinGrams.formatted(.number.precision(.fractionLength(0)))) g protein").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("demo.meal.\(meal.id.uuidString)")
                    }
                }
                Section("Past meals") {
                    ForEach(workspace.meals.sorted { $0.date > $1.date }) { meal in
                        Button("Log \(meal.name.isEmpty ? meal.items.map(\.name).joined(separator: ", ") : meal.name) again", systemImage: "arrow.counterclockwise") {
                            var copy = meal; copy.id = UUID(); copy.date = workspace.anchor
                            editingMeal = copy
                        }.accessibilityIdentifier("demo.meal.repeat.\(meal.id.uuidString)")
                    }
                }
            }
        }
    }

    private var notes: some View {
        VStack {
            LiveFilterSearch(scope: "notes", filter: $noteFilter).padding(.horizontal)
            Toggle("Show archived notes", isOn: $archived).padding(.horizontal)
            List {
                Button("New note", systemImage: "square.and.pencil") {
                    guard let workspace = session.workspace else { return }
                    editingNote = VoiceNote(createdAt: workspace.anchor, audioFilename: "", transcript: workspace.drafts["note"] ?? "", status: .transcribed)
                }.accessibilityIdentifier("demo.note.add")
                if let workspace = session.workspace {
                    let predicate = noteFilter.predicate(now: workspace.anchor, calendar: workspace.calendar)
                    let showArchived = noteFilter.value("archived").map { $0 == "true" } ?? archived
                    ForEach(workspace.notes.filter { ($0.archivedAt != nil) == showArchived && predicate($0.createdAt, $0.displayTitle, nil, nil) }
                        .sorted { $0.createdAt > $1.createdAt }) { note in
                        Button { editingNote = note } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(note.displayTitle).lineLimit(3)
                                if let context = note.context?.anchorLine { Text(context).font(.caption).foregroundStyle(.secondary) }
                                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("demo.note.\(note.id.uuidString)")
                    }
                }
            }
        }
    }

    private var workouts: some View {
        List {
            Section {
                Button("Start sample workout", systemImage: "figure.strengthtraining.traditional") { recording = true }
                    .accessibilityIdentifier("demo.workout.start")
                Text("Sample workouts are simulated. Nothing is recorded to Apple Health or your Watch.").font(.caption).foregroundStyle(.secondary)
            }
            if let workspace = session.workspace {
                Section("Workouts") {
                    LiveFilterSearch(scope: "workouts", filter: $workoutFilter)
                    let predicate = workoutFilter.predicate(now: workspace.anchor, calendar: workspace.calendar)
                    ForEach(workspace.workouts.filter { predicate($0.start, $0.activity, $0.activity, $0.duration) }.sorted { $0.start > $1.start }) { workout in
                        NavigationLink { workoutDetail(workout) } label: {
                            VStack(alignment: .leading) {
                                Text(workout.activity).font(.headline)
                                Text("\(Int(workout.duration / 60)) min · \(Int(workout.totalEnergy ?? 0)) kcal").foregroundStyle(.secondary)
                                Text(workout.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("demo.workout.\(workout.id.uuidString)")
                    }
                }
                Section("Sleep") {
                    Chart(workspace.sleep) { night in
                        BarMark(x: .value("Night", night.start, unit: .day), y: .value("Hours", night.hours)).foregroundStyle(.purple)
                    }.frame(height: 150).accessibilityLabel("Seven sample nights, around seven to eight hours per night")
                    ForEach(workspace.sleep) { night in
                        LabeledContent(night.start.formatted(date: .abbreviated, time: .omitted), value: String(format: "%.1f hours", night.hours))
                    }
                }
            }
        }
    }

    private func workoutDetail(_ workout: FitnessSession) -> some View {
        List {
            LabeledContent("Duration", value: "\(Int(workout.duration / 60)) minutes")
            LabeledContent("Energy", value: "\(Int(workout.totalEnergy ?? 0)) kcal")
            LabeledContent("Average heart rate", value: "\(Int(workout.avgHeartRate ?? 0)) bpm")
            Chart(workout.samples.filter { $0.kind == .heartRate }, id: \.t) { sample in
                LineMark(x: .value("Seconds", sample.t), y: .value("Heart rate", sample.v1)).foregroundStyle(.pink)
            }.frame(height: 200).accessibilityLabel("Sample heart rate")
            Button("Delete sample workout", role: .destructive) { Task { await session.perform(.deleteWorkout(workout.id)) } }
        }.navigationTitle(workout.activity)
    }

    private var library: some View {
        List {
            Section {
                Text("Sample narration uses your device’s system voice. No podcast subscriptions or listening history outside this demo are changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(session.workspace?.episodes ?? []) { episode in
                Section {
                    Text(episode.show).font(.caption).foregroundStyle(.secondary)
                    Text(episode.title).font(.headline)
                    HStack {
                        Button(audio.playingID == episode.id ? "Pause" : "Play sample", systemImage: audio.playingID == episode.id ? "pause.fill" : "play.fill") {
                            audio.play(episode)
                        }.accessibilityIdentifier("demo.episode.play.\(episode.id.uuidString)")
                        Spacer()
                        Menu("\(episode.speed.formatted())×") {
                            ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                                Button("\(speed.formatted())×") { var changed = episode; changed.speed = speed; audio.stop(); Task { await session.perform(.saveEpisode(changed)) } }
                            }
                        }
                    }
                    Text(episode.transcript).font(.body)
                    Button(episode.listened ? "Mark unlistened" : "Mark listened", systemImage: episode.listened ? "checkmark.circle.fill" : "circle") {
                        var changed = episode; changed.listened.toggle(); Task { await session.perform(.saveEpisode(changed)) }
                    }.accessibilityIdentifier("demo.episode.listened.\(episode.id.uuidString)")
                    Button("Save a note from this episode", systemImage: "quote.bubble") {
                        editingNote = VoiceNote(createdAt: session.workspace?.anchor ?? Date(), audioFilename: "", transcript: "", kind: .podcastCapture,
                            context: .init(episodeID: episode.id.uuidString, episodeTitle: episode.title, podcastTitle: episode.show, timestamp: 0), status: .transcribed)
                    }
                }
            }
        }
    }
}

@MainActor
private final class DemoNarration: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var playingID: UUID?
    @Published private(set) var finishedID: UUID?
    private let speech = AVSpeechSynthesizer()
    private var activeID: UUID?
    private var activeUtterance: ObjectIdentifier?
    override init() { super.init(); speech.delegate = self }
    func play(_ episode: DemoEpisode) {
        if activeID == episode.id, speech.isPaused { speech.continueSpeaking(); playingID = episode.id; return }
        if playingID == episode.id { speech.pauseSpeaking(at: .word); playingID = nil; return }
        stop(); activeID = episode.id; playingID = episode.id; finishedID = nil
        let utterance = AVSpeechUtterance(string: episode.transcript)
        activeUtterance = ObjectIdentifier(utterance)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(episode.speed)
        speech.speak(utterance)
    }
    func stop() { activeUtterance = nil; speech.stopSpeaking(at: .immediate); playingID = nil; activeID = nil }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance == identity else { return }
            self.finishedID = self.activeID; self.playingID = nil; self.activeID = nil; self.activeUtterance = nil
        }
    }
}
