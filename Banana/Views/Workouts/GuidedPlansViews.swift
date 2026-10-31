import SwiftUI

// Guided plans: the saved plans, the builder, a plan's exercises and its coach. They were in the
// phone's Nutrition file and compiled for iOS alone, so the Mac's Workouts page had no way to
// them; nothing in them is the phone's.

/// Guided plans: pushed from the "Guided plans" row of the Workouts list, on the phone, the iPad's
/// wide page and the Mac's.
struct WorkoutPlansView: View {
    @EnvironmentObject private var wellness: WellnessStore
    @State private var showBuilder = false

    private static let builderNote = "Apple Intelligence runs on this device. Banana never sends workout details to an external AI provider. If Apple Intelligence is unavailable, Banana builds from its offline exercise catalog."

    var body: some View {
        List {
            Section {
                Button { showBuilder = true } label: {
                    Label("Build a workout", systemImage: "sparkles.rectangle.stack")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
                .accessibilityIdentifier("wellness.buildWorkout")
                #if os(macOS)
                // A Mac list gives a section's footer one line and cuts it off: a row instead.
                Text(Self.builderNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            } footer: {
                #if os(iOS)
                Text(Self.builderNote)
                #endif
            }

            Section("Saved plans") {
                if wellness.workoutPlans.isEmpty {
                    ContentUnavailableView("No workout plans", systemImage: "figure.strengthtraining.traditional", description: Text("Build a strength, stretch, or mixed session."))
                } else {
                    ForEach(wellness.workoutPlans) { plan in
                        NavigationLink(value: ShellState.WorkoutsRoute.plan(plan.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.title).font(.headline)
                                Text("\(plan.targetMinutes) min · \(plan.exercises.count) exercises · \(plan.focus.title)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { DeleteUndo.workoutPlan(plan.id, in: wellness) } }
                        // And by a right-click or a long press: a swipe isn't how a Mac deletes.
                        .contextMenu {
                            Button(role: .destructive) { DeleteUndo.workoutPlan(plan.id, in: wellness) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Guided plans")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBuilder) { WorkoutBuilderView() }
    }
}

struct WorkoutBuilderView: View {
    @EnvironmentObject private var wellness: WellnessStore
    @Environment(\.dismiss) private var dismiss
    @State private var focus: WorkoutFocus = .mixed
    @State private var experience: WorkoutExperience = .beginner
    @State private var duration = 30
    @State private var equipment: Set<WorkoutEquipment> = [.bodyweight]
    @State private var avoidExerciseIDs: Set<String> = []
    @State private var notes = ""
    @State private var building = false
    @State private var result: WorkoutBuildResult?

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    Picker("Focus", selection: $focus) { ForEach(WorkoutFocus.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker("Experience", selection: $experience) { ForEach(WorkoutExperience.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Stepper("\(duration) minutes", value: $duration, in: 10...90, step: 5)
                }
                Section("Equipment") {
                    ForEach(WorkoutEquipment.allCases, id: \.self) { item in
                        Toggle(item.title, isOn: equipmentBinding(for: item))
                            .disabled(item == .bodyweight)
                    }
                    NavigationLink {
                        ExerciseExclusionsView(selection: $avoidExerciseIDs)
                    } label: {
                        LabeledContent("Avoid movements", value: avoidExerciseIDs.isEmpty ? "None" : "\(avoidExerciseIDs.count)")
                    }
                }
                Section {
                    TextField("Preferences or context", text: $notes, axis: .vertical).lineLimit(3...6)
                } header: {
                    Text("Anything to account for?")
                } footer: { Text("This is not medical care or rehabilitation. Stop for sharp pain, dizziness, numbness, or symptoms that concern you.") }

                if let result {
                    Section("Ready") {
                        Text(result.plan.title).font(.headline)
                        Text(result.note).font(.caption).foregroundStyle(.secondary)
                        ForEach(result.plan.exercises) { item in
                            if let exercise = ExerciseCatalog.exercise(item.exerciseID) {
                                Text("\(exercise.name) · \(setDescription(item))")
                            }
                        }
                        Button("Save plan") { wellness.saveWorkoutPlan(result.plan); dismiss() }
                            .buttonStyle(.primary)
                            .disabled(result.plan.exercises.isEmpty)
                    }
                }
            }
            .editingFormStyle()
            .navigationTitle("Workout builder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(building ? "Building…" : "Build") { Task { await build() } }.disabled(building)
                }
            }
        }
        #if os(macOS)
        // A sheet on the Mac is as big as it's told to be.
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    @MainActor private func build() async {
        building = true; result = nil
        result = await WorkoutPlanBuilder.build(preferences: .init(
            focus: focus,
            experience: experience,
            durationMinutes: duration,
            equipment: equipment,
            avoidExerciseIDs: avoidExerciseIDs,
            notes: notes))
        building = false
    }

    private func equipmentBinding(for item: WorkoutEquipment) -> Binding<Bool> {
        Binding(
            get: { equipment.contains(item) },
            set: { enabled in
                if enabled {
                    equipment.insert(item)
                } else if item != WorkoutEquipment.bodyweight {
                    equipment.remove(item)
                }
            })
    }
}

private struct ExerciseExclusionsView: View {
    @Binding var selection: Set<String>

    var body: some View {
        List {
            ForEach([ExerciseCategory.strength, .mobility], id: \.self) { category in
                Section(category == .strength ? "Strength" : "Stretch") {
                    ForEach(ExerciseCatalog.all.filter { $0.category == category }) { exercise in
                        Button {
                            if selection.contains(exercise.id) {
                                selection.remove(exercise.id)
                            } else {
                                selection.insert(exercise.id)
                            }
                        } label: {
                            HStack {
                                Text(exercise.name).foregroundStyle(.primary)
                                Spacer()
                                if selection.contains(exercise.id) {
                                    Image(systemName: "checkmark").foregroundStyle(DS.Palette.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Avoid movements")
    }
}

struct WorkoutPlanDetailView: View {
    let plan: WorkoutPlan
    @ObservedObject private var sessions = GuidedSessionStore.shared
    var body: some View {
        List {
            Section {
                Text(plan.rationale).foregroundStyle(.secondary)
                NavigationLink(value: ShellState.WorkoutsRoute.coach(plan.id)) {
                    Label(sessions.session(for: plan.id) == nil ? "Start guided workout" : "Resume guided workout",
                          systemImage: "play.circle.fill").font(.headline).foregroundStyle(DS.Palette.accent)
                }
                .accessibilityIdentifier("wellness.startCoach")
            }
            ForEach(Array(plan.exercises.enumerated()), id: \.element.id) { index, item in
                if let exercise = ExerciseCatalog.exercise(item.exerciseID) {
                    Section("\(index + 1) · \(exercise.name)") {
                        ExerciseFormDiagram(exercise: exercise)
                        Text(setDescription(item)).font(.headline)
                        ForEach(exercise.instructions, id: \.self) { Text($0) }
                        ForEach(exercise.formCues, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle(plan.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkoutCoachView: View {
    @EnvironmentObject private var wellness: WellnessStore
    @Environment(\.dismiss) private var dismiss
    /// Progress lives in the store, not here: the screen is rebuilt after every trip to the
    /// background, and a guided workout is exactly when the phone gets locked between sets.
    @ObservedObject private var sessions = GuidedSessionStore.shared
    let plan: WorkoutPlan
    @State private var showEnd = false

    /// Until `onAppear` starts or resumes the stored session, show the one it would start.
    private var session: GuidedSession { sessions.session(for: plan.id) ?? GuidedSession(plan: plan, now: Date()) }
    private var item: ExercisePrescription { session.item(in: plan) }
    private var exercise: ExerciseDefinition { ExerciseCatalog.exercise(item.exerciseID)! }
    /// A new wait whenever the phase or its deadline changes.
    private var phaseKey: String {
        "\(session.index)-\(session.setNumber)-\(session.resting)-\(session.paused)-\(session.phaseEndsAt?.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(session.resting ? "REST" : "EXERCISE \(session.index + 1) OF \(plan.exercises.count)").font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(DS.Palette.accent)
                    Spacer(); Text("Set \(session.setNumber)/\(item.sets)").font(.subheadline).foregroundStyle(.secondary)
                }
                if session.resting {
                    VStack(spacing: 16) {
                        Image(systemName: "timer").font(.system(size: 54)).foregroundStyle(DS.Palette.accent)
                        countdown { Text("\($0)").font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit() }
                        Text("Up next: \(ExerciseCatalog.exercise(plan.exercises[session.pendingIndex].exerciseID)?.name ?? "Exercise")").foregroundStyle(.secondary)
                        Button("Skip rest") { sessions.update { $0.endRest(in: plan, at: Date()) } }.buttonStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    Text(exercise.name).font(.largeTitle.bold())
                    ExerciseFormDiagram(exercise: exercise)
                    Group {
                        if let reps = item.reps {
                            Text("\(reps) reps")
                        } else {
                            countdown { Text("\($0) seconds") }
                        }
                    }
                    .font(.title2.bold()).monospacedDigit().frame(maxWidth: .infinity, alignment: .center)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(exercise.instructions, id: \.self) { Label($0, systemImage: "circle.fill").font(.subheadline).symbolRenderingMode(.hierarchical) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FORM CUES").font(.caption.weight(.bold)).foregroundStyle(DS.Palette.accent)
                        ForEach(exercise.formCues, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    if item.reps != nil {
                        Button("Complete set") { completeSet() }.buttonStyle(.primaryPage)
                    }
                }
                Text("Visual guide only. Use a comfortable range and stop for sharp pain, dizziness, or numbness.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .navigationTitle(plan.title).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)   // leaving goes through End, so a session is never half-abandoned
        .toolbar {
            ToolbarItem(placement: Self.pausePlacement) {
                Button { sessions.update { $0.togglePause(at: Date()) } } label: {
                    Image(systemName: session.paused ? "play.fill" : "pause.fill")
                }
                .accessibilityLabel(session.paused ? "Resume" : "Pause")
            }
            ToolbarItem(placement: Self.endPlacement) { Button("End") { showEnd = true } }
        }
        .interactiveDismissDisabled()
        .onAppear {
            sessions.begin(plan)
            advance()   // catch up on whatever ran out while the screen was gone
        }
        // Sleep until the running phase's deadline, then let the session move on.
        .task(id: phaseKey) {
            guard !session.paused, let end = session.phaseEndsAt else { return }
            // Re-check against the wall clock after each sleep: the sleep runs on a monotonic
            // clock, and a clock change would otherwise leave the countdown sitting at 0.
            while !Task.isCancelled, end.timeIntervalSinceNow > 0 {
                try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
            }
            guard !Task.isCancelled else { return }
            advance()
        }
        .confirmationDialog("End this workout?", isPresented: $showEnd) {
            Button("Save partial workout") { finishAndDismiss() }
            Button("Discard", role: .destructive) { sessions.end(); dismiss() }
            Button("Keep going", role: .cancel) {}
        }
    }

    #if os(iOS)
    private static let pausePlacement = ToolbarItemPlacement.topBarTrailing
    private static let endPlacement = ToolbarItemPlacement.topBarLeading
    #else
    private static let pausePlacement = ToolbarItemPlacement.primaryAction
    private static let endPlacement = ToolbarItemPlacement.cancellationAction
    #endif

    /// Seconds left in the running phase, redrawn once a second from the wall clock.
    private func countdown<V: View>(@ViewBuilder _ content: @escaping (Int) -> V) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(session.remaining(at: context.date))
        }
    }

    private func completeSet() {
        var outcome = GuidedSession.Outcome.running
        sessions.update { outcome = $0.completeSet(in: plan, at: Date()) }
        if outcome == .finished { finishAndDismiss() }
    }

    private func advance() {
        var outcome = GuidedSession.Outcome.running
        sessions.update { outcome = $0.tick(in: plan, now: Date()) }
        if outcome == .finished { finishAndDismiss() }
    }

    private func finishAndDismiss() {
        let finished = session
        wellness.recordWorkoutCompletion(.init(planID: plan.id, startedAt: finished.startedAt,
                                               endedAt: finished.finishedAt ?? Date(),
                                               completedExerciseIDs: finished.completed))
        sessions.end()
        dismiss()
    }
}

private func setDescription(_ item: ExercisePrescription) -> String {
    if let reps = item.reps { return "\(item.sets) × \(reps) reps · \(item.restSeconds)s rest" }
    return "\(item.sets) × \(item.durationSeconds ?? 0)s · \(item.restSeconds)s rest"
}
