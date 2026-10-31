import HealthKit
import SwiftUI

struct WatchWorkoutPlanPreview: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @EnvironmentObject private var plans: WatchWorkoutPlanStore
    let plan: WorkoutPlan
    @State private var starting = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await start() }
                } label: {
                    Label(starting ? "Starting…" : "Start", systemImage: "play.fill")
                }
                .disabled(starting || plan.exercises.isEmpty)
                .tint(.orange)
            }
            ForEach(plan.exercises) { item in
                if let exercise = ExerciseCatalog.exercise(item.exerciseID) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name).font(.footnote.weight(.semibold))
                        Text(watchSetDescription(item)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(plan.title)
    }

    @MainActor private func start() async {
        starting = true
        if !recorder.isAuthorized { await recorder.requestAuthorization() }
        guard recorder.isAuthorized else { starting = false; return }
        let activity: HKWorkoutActivityType = plan.focus == .mobility ? .flexibility : .traditionalStrengthTraining
        plans.begin(plan)
        recorder.start(activity: activity, name: plan.title, indoor: true)
        if !recorder.isRecording { plans.cancelActive(); starting = false }
    }
}

struct WatchGuidedWorkoutView: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @EnvironmentObject private var plans: WatchWorkoutPlanStore
    let plan: WorkoutPlan
    @State private var page = 0
    @State private var index = 0
    @State private var setNumber = 1
    @State private var remaining = 0
    @State private var resting = false
    @State private var paused = false
    @State private var pendingIndex = 0
    @State private var pendingSet = 1
    @State private var completed: [String] = []
    @State private var startedAt = Date()
    @State private var showEnd = false

    private var item: ExercisePrescription { plan.exercises[min(index, plan.exercises.count - 1)] }
    private var exercise: ExerciseDefinition { ExerciseCatalog.exercise(item.exerciseID)! }
    private var timerIdentity: String { "\(index)-\(setNumber)-\(resting)-\(remaining)-\(paused)" }

    var body: some View {
        TabView(selection: $page) {
            primaryPage.tag(0)
            cuesPage.tag(1)
        }
        .tabViewStyle(.verticalPage)
        .onAppear {
            startedAt = Date()
            remaining = item.durationSeconds ?? 0
        }
        .task(id: timerIdentity) {
            guard !paused, remaining > 0, resting || item.durationSeconds != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !paused else { return }
            remaining -= 1
            if remaining == 0 { resting ? endRest() : completeSet() }
        }
        .confirmationDialog("End workout?", isPresented: $showEnd) {
            Button("Save partial") { finish() }
            Button("Discard", role: .destructive) { recorder.stop(); plans.cancelActive() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var primaryPage: some View {
        VStack(spacing: 6) {
            HStack {
                Text(resting ? "REST" : "\(index + 1)/\(plan.exercises.count)").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                Spacer()
                Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }.buttonStyle(.plain)
            }
            if resting {
                Image(systemName: "timer").font(.title2).foregroundStyle(.orange)
                Text("\(remaining)").font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit()
                Text("Next: \(ExerciseCatalog.exercise(plan.exercises[pendingIndex].exerciseID)?.name ?? "Move")").font(.caption2).lineLimit(1)
                Button("Skip") { endRest() }.buttonStyle(.bordered)
            } else {
                Text(exercise.name).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                WatchExerciseDiagram(kind: exercise.visual)
                    .frame(height: 62)
                Text(item.reps.map { "\($0) reps" } ?? "\(remaining) sec")
                    .font(.title3.bold()).monospacedDigit()
                Text("Set \(setNumber) of \(item.sets)").font(.caption2).foregroundStyle(.secondary)
                if item.reps != nil {
                    Button("Set done") { completeSet() }.buttonStyle(.borderedProminent).tint(.orange)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var cuesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("FORM").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                ForEach(exercise.formCues.prefix(3), id: \.self) { cue in
                    Label(cue, systemImage: "checkmark.circle").font(.caption2)
                }
                Text("Guide only. Stop for sharp pain or dizziness.").font(.caption2).foregroundStyle(.secondary)
                Button("End workout", role: .destructive) { showEnd = true }.font(.caption)
            }.padding(.horizontal, 5)
        }
    }

    private func completeSet() {
        if setNumber < item.sets {
            pendingIndex = index; pendingSet = setNumber + 1; startRest()
        } else {
            if !completed.contains(item.exerciseID) { completed.append(item.exerciseID) }
            guard index + 1 < plan.exercises.count else { finish(); return }
            pendingIndex = index + 1; pendingSet = 1; startRest()
        }
    }
    private func startRest() { resting = true; remaining = item.restSeconds }
    private func endRest() { index = pendingIndex; setNumber = pendingSet; resting = false; remaining = plan.exercises[index].durationSeconds ?? 0; page = 0 }
    private func finish() { plans.finish(startedAt: startedAt, exerciseIDs: completed); recorder.stop() }
}

private struct WatchExerciseDiagram: View {
    let kind: ExerciseVisualKind

    var body: some View {
        HStack(spacing: 4) {
            pose(phase: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            pose(phase: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Start and finish form diagram")
    }

    private func pose(phase: Int) -> some View {
        Canvas { context, size in
            let p = points(phase: phase)
            func q(_ i: Int) -> CGPoint { CGPoint(x: p[i].x * size.width, y: p[i].y * size.height) }
            for edge in [(0,1),(1,2),(2,3),(1,4),(4,5),(2,6),(6,7)] {
                var line = Path(); line.move(to: q(edge.0)); line.addLine(to: q(edge.1))
                context.stroke(line, with: .color(.primary), style: .init(lineWidth: 3, lineCap: .round))
            }
            let h = q(0); context.fill(Path(ellipseIn: .init(x: h.x-3.5, y: h.y-3.5, width: 7, height: 7)), with: .color(.primary))
        }
        .padding(3).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    /// head, shoulder, hip, left foot, right elbow/hand, left knee/foot. Side-view is clearer at
    /// wrist scale than a dense full skeleton; the paired frames carry the movement direction.
    private func points(phase: Int) -> [CGPoint] {
        switch kind {
        case .squat:
            return phase == 0 ? standing : [p(0.48,0.16),p(0.5,0.3),p(0.55,0.58),p(0.25,0.88),p(0.68,0.4),p(0.77,0.47),p(0.34,0.67),p(0.73,0.88)]
        case .lunge, .hipFlexorStretch:
            return phase == 0 ? standing : [p(0.48,0.14),p(0.49,0.3),p(0.5,0.56),p(0.18,0.88),p(0.6,0.43),p(0.63,0.61),p(0.7,0.7),p(0.84,0.88)]
        case .pushup, .plank:
            let y = phase == 1 && kind == .pushup ? 0.58 : 0.42
            return [p(0.15,y),p(0.28,y+0.03),p(0.58,y+0.12),p(0.9,0.78),p(0.34,0.62),p(0.43,0.83),p(0.73,y+0.2),p(0.9,0.78)]
        case .bridge:
            return [p(0.14,0.75),p(0.27,0.74),p(0.57,phase == 0 ? 0.74:0.45),p(0.86,0.86),p(0.4,0.79),p(0.52,0.86),p(0.72,0.57),p(0.86,0.86)]
        case .deadBug, .thoracicRotation:
            return [p(0.15,0.76),p(0.29,0.73),p(0.55,0.72),p(0.83,0.55),p(phase == 0 ? 0.42:0.22,phase == 0 ? 0.5:0.28),p(phase == 0 ? 0.44:0.12,phase == 0 ? 0.3:0.15),p(0.62,0.5),p(0.82,0.5)]
        case .birdDog, .childPose:
            return [p(0.2,0.48),p(0.36,0.51),p(0.62,0.57),p(0.82,0.86),p(phase == 0 ? 0.4:0.2,0.68),p(phase == 0 ? 0.4:0.08,0.87),p(0.65,0.72),p(0.82,0.86)]
        case .row, .hamstringStretch:
            return [p(0.2,0.27),p(0.36,0.37),p(0.62,0.55),p(0.82,0.88),p(0.48,phase == 0 ? 0.62:0.44),p(0.55,phase == 0 ? 0.78:0.52),p(0.58,0.7),p(0.48,0.88)]
        case .overheadPress, .chestStretch:
            var out = standing; out[4] = p(phase == 0 ? 0.64:0.72, phase == 0 ? 0.4:0.18); out[5] = p(phase == 0 ? 0.61:0.78, phase == 0 ? 0.58:0.06); return out
        case .curl:
            var out = standing; out[5] = p(0.61, phase == 0 ? 0.6:0.3); return out
        case .calfStretch:
            return [p(0.24,0.18),p(0.34,0.31),p(0.55,0.53),p(0.88,0.88),p(0.27,0.45),p(0.12,0.53),p(0.7,0.68),p(0.88,0.88)]
        }
    }
    private var standing: [CGPoint] { [p(0.5,0.1),p(0.5,0.27),p(0.5,0.55),p(0.4,0.88),p(0.62,0.42),p(0.61,0.6),p(0.57,0.72),p(0.64,0.88)] }
    private func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
}

private func watchSetDescription(_ item: ExercisePrescription) -> String {
    if let reps = item.reps { return "\(item.sets) × \(reps)" }
    return "\(item.sets) × \(item.durationSeconds ?? 0)s"
}
