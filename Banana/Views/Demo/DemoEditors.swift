import SwiftUI

struct DemoEventEditor: View {
    @ObservedObject var session: DemoSession
    @Environment(\.dismiss) private var dismiss
    @State private var event: DemoEvent
    private let existed: Bool

    init(session: DemoSession, event: DemoEvent) {
        self.session = session
        _event = State(initialValue: event)
        existed = session.workspace?.events.contains(where: { $0.id == event.id }) == true
    }

    private var readOnly: Bool { session.workspace?.calendars.first(where: { $0.id == event.calendarID })?.readOnly == true }

    var body: some View {
        NavigationStack {
            Form {
                if readOnly {
                    Section {
                        Text(event.title).font(.headline)
                        Text(event.start.formatted(date: .abbreviated, time: .shortened))
                        Text("This calendar shares availability only.").foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField("Title", text: $event.title).accessibilityIdentifier("demo.event.title")
                        Picker("Calendar", selection: $event.calendarID) {
                            ForEach((session.workspace?.calendars ?? []).filter { !$0.readOnly }) { Text($0.title).tag($0.id) }
                        }
                        DatePicker("Starts", selection: $event.start).accessibilityIdentifier("demo.event.start")
                        DatePicker("Ends", selection: $event.end).accessibilityIdentifier("demo.event.end")
                        TextField("Location", text: $event.location)
                        Picker("Repeat", selection: $event.recurrence) {
                            ForEach(DemoEvent.Repeat.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        TextField("Notes", text: $event.notes, axis: .vertical).lineLimit(3...8)
                    } footer: {
                        Text("Changes stay in the demo. Repeating-event edits change the sample series.")
                    }
                    if existed {
                        Section {
                            Button("Delete sample event", role: .destructive) {
                                Task { if await session.perform(.deleteEvent(event.id)) { dismiss() } }
                            }.accessibilityIdentifier("demo.event.delete")
                        }
                    }
                }
            }
            .navigationTitle(readOnly ? "Availability" : existed ? "Edit event" : "New event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(readOnly ? "Done" : "Cancel") { dismiss() } }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { if await session.perform(.saveEvent(event)) { dismiss() } } }
                            .disabled(event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || event.end <= event.start || session.saving > 0)
                            .accessibilityIdentifier("demo.event.save")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { DemoSaveError(session: session) }
        }
        .frame(minWidth: 320, minHeight: 400)
    }
}

struct DemoMealEditor: View {
    @ObservedObject var session: DemoSession
    @Environment(\.dismiss) private var dismiss
    @State private var meal: MealEntry
    private let existed: Bool

    init(session: DemoSession, meal: MealEntry) {
        self.session = session
        _meal = State(initialValue: meal)
        existed = session.workspace?.meals.contains(where: { $0.id == meal.id }) == true
    }

    private var valid: Bool {
        !meal.items.isEmpty && meal.items.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Meal name", text: $meal.name).accessibilityIdentifier("demo.meal.name")
                    DatePicker("Eaten at", selection: $meal.date).accessibilityIdentifier("demo.meal.date")
                }
                ForEach($meal.items) { $item in
                    Section {
                        TextField("Food", text: $item.name).accessibilityIdentifier("demo.meal.food")
                        TextField("Serving", text: $item.serving)
                        if let grams = item.grams {
                            HStack {
                                Text("Grams")
                                TextField("Grams", value: Binding(get: { item.grams ?? grams }, set: { item = item.withGrams($0) }), format: .number)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        number("Calories", value: $item.macros.calories)
                        number("Protein (g)", value: $item.macros.proteinGrams)
                        number("Carbohydrate (g)", value: $item.macros.carbohydrateGrams)
                        number("Fat (g)", value: $item.macros.fatGrams)
                    }
                }
                Section {
                    Button("Add food", systemImage: "plus") { meal.items.append(.init(name: "", serving: "1 serving", macros: .init())) }
                    TextField("Note", text: $meal.note, axis: .vertical)
                }
                Section("Total") {
                    Text("\(meal.totals.calories.formatted(.number.precision(.fractionLength(0)))) kcal · \(meal.totals.proteinGrams.formatted(.number.precision(.fractionLength(0)))) g protein")
                }
                if existed {
                    Section {
                        Button("Delete sample meal", role: .destructive) {
                            Task { if await session.perform(.deleteMeal(meal.id)) { dismiss() } }
                        }
                    }
                }
            }
            .navigationTitle(existed ? "Edit meal" : "Log a meal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await session.perform(.saveMeal(meal)) { dismiss() } } }
                        .disabled(!valid || session.saving > 0).accessibilityIdentifier("demo.meal.save")
                }
            }
            .safeAreaInset(edge: .bottom) { DemoSaveError(session: session) }
        }.frame(minWidth: 320, minHeight: 400)
    }

    private func number(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            TextField(title, value: value, format: .number).multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
        }
    }
}

struct DemoNoteEditor: View {
    @ObservedObject var session: DemoSession
    @Environment(\.dismiss) private var dismiss
    @State private var note: VoiceNote
    @State private var text: String
    @State private var draft: Task<Void, Never>?
    @FocusState private var focused: Bool
    private let existed: Bool

    init(session: DemoSession, note: VoiceNote) {
        self.session = session
        _note = State(initialValue: note)
        _text = State(initialValue: note.transcript ?? "")
        existed = session.workspace?.notes.contains(where: { $0.id == note.id }) == true
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let anchor = note.context?.anchorLine { Text(anchor).font(.caption).foregroundStyle(.secondary) }
                NoteTextEditor(text: $text, focused: $focused).accessibilityIdentifier("demo.note.text")
                if existed {
                    HStack {
                        Button(note.archivedAt == nil ? "Archive" : "Unarchive") {
                            draft?.cancel()
                            Task { if await session.perform(.archiveNote(note.id, note.archivedAt == nil)) { dismiss() } }
                        }.accessibilityIdentifier("demo.note.archive")
                        Spacer()
                        Button("Delete", role: .destructive) {
                            draft?.cancel()
                            Task { if await session.perform(.deleteNote(note.id)) { dismiss() } }
                        }.accessibilityIdentifier("demo.note.delete")
                    }
                }
            }.padding()
            .navigationTitle(existed ? "Edit note" : "New note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { draft?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft?.cancel()
                        var saved = note; saved.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.updatedAt = session.workspace?.anchor; saved.status = .transcribed
                        Task { if await session.perform(.saveNote(saved)) { dismiss() } }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.saving > 0)
                        .accessibilityIdentifier("demo.note.save")
                }
            }
            .onChange(of: text) { _, value in
                draft?.cancel()
                guard !existed else { return }
                draft = Task {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard !Task.isCancelled else { return }
                    await session.perform(.saveDraft("note", value))
                }
            }
            .onAppear { focused = true }
            .onDisappear { draft?.cancel() }
            .safeAreaInset(edge: .bottom) { DemoSaveError(session: session) }
        }.frame(minWidth: 320, minHeight: 360)
    }
}

struct DemoSaveError: View {
    @ObservedObject var session: DemoSession
    var body: some View {
        if let error = session.error {
            Text(error).font(.callout).foregroundStyle(.red).padding()
                .frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                .accessibilityIdentifier("demo.editor.error")
        }
    }
}

struct DemoWorkoutRecorder: View {
    @ObservedObject var session: DemoSession
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var paused = false
    @State private var restUntil: Date?
    @State private var pausedAt: Date?
    @State private var pauses: [FitnessPause] = []
    @State private var id = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Label("Simulated strength workout", systemImage: "figure.strengthtraining.traditional").font(.title2)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = WorkoutPauses.activeElapsed(wall: context.date.timeIntervalSince(start), pauses: pauses,
                        openSince: pausedAt.map { $0.timeIntervalSince(start) })
                    Text(VoiceNote.Context.clock(elapsed)).font(.system(size: 48, weight: .medium, design: .monospaced))
                    Text("\(112 + Int(elapsed) % 12) bpm · sample metrics").foregroundStyle(.secondary)
                    if let restUntil {
                        Text(restUntil > context.date ? "Rest: \(Int(ceil(restUntil.timeIntervalSince(context.date)))) seconds" : "Rest complete")
                            .accessibilityIdentifier("demo.workout.rest")
                    }
                }
                HStack {
                    Button("Rest 30 seconds") { restUntil = Date().addingTimeInterval(30) }
                    Button("Rest 1 minute") { restUntil = Date().addingTimeInterval(60) }
                }.buttonStyle(.bordered)
                HStack {
                    Button(paused ? "Resume" : "Pause") {
                        if paused {
                            if let pausedAt { pauses.append(FitnessPause(start: pausedAt.timeIntervalSince(start), end: Date().timeIntervalSince(start))) }
                            pausedAt = nil
                        }
                        else { pausedAt = Date() }
                        paused.toggle()
                    }.buttonStyle(.bordered)
                    Button("End sample workout") { end() }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("demo.workout.end")
                }
                Text("No sensors, Apple Health records or Watch sessions are started.").font(.caption).foregroundStyle(.secondary)
                DemoSaveError(session: session)
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Sample workout")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.frame(minWidth: 320, minHeight: 400)
    }

    private func end() {
        let end = min(start.addingTimeInterval(3600), max(start.addingTimeInterval(1), Date()))
        let duration = end.timeIntervalSince(start)
        let closed = WorkoutPauses.closed(pauses, openSince: pausedAt.map { $0.timeIntervalSince(start) }, at: duration)
        let samples = (0..<max(1, Int(duration))).filter { second in
            !closed.contains { Double(second) >= $0.start && Double(second) < $0.end }
        }.map { FitnessSample(t: Double($0), kind: .heartRate, v1: Double(112 + $0 % 12), v2: nil, v3: nil) }
        let workout = FitnessSession(id: id, start: start, end: end, activity: "Strength · sample", avgHeartRate: 118,
            totalEnergy: max(1, (duration - WorkoutPauses.pausedSeconds(closed)) / 10), totalDistance: nil, pauses: closed, samples: samples)
        Task { if await session.perform(.saveWorkout(workout)) { dismiss() } }
    }
}
