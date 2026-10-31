import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct WorkoutBuildResult: Sendable {
    var plan: WorkoutPlan
    var usedOnDeviceModel: Bool
    var note: String
}

enum WorkoutPlanBuilder {
    static var isAIAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    static func build(preferences: WorkoutPreferences) async -> WorkoutBuildResult {
        let fallback = DeterministicWorkoutBuilder.build(preferences: preferences)
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *),
           SystemLanguageModel.default.availability == .available {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt(preferences: preferences),
                    generating: GeneratedWorkoutPlan.self,
                    options: .init(temperature: 0.2, maximumResponseTokens: 1_200))
                let generated = response.content.asPlan(focus: preferences.focus,
                                                        targetMinutes: preferences.sanitizedDuration)
                if let validated = WorkoutPlanValidator.validate(generated, preferences: preferences) {
                    return .init(plan: validated, usedOnDeviceModel: true,
                                 note: "Built on this device and checked against Banana’s exercise catalog.")
                }
            } catch {
                // The deterministic builder below is a complete path, not an error screen.
            }
        }
        #endif
        let note = fallback.exercises.isEmpty
            ? "No catalog exercises match those equipment and avoidance choices. Re-enable a movement to build a plan."
            : "Built locally from your settings. Apple Intelligence was unavailable."
        return .init(plan: fallback, usedOnDeviceModel: false, note: note)
    }

    private static func prompt(preferences: WorkoutPreferences) -> String {
        let allowed = ExerciseCatalog.all
            .filter { $0.equipment.isSubset(of: preferences.equipment.union([.bodyweight])) }
            .map { "\($0.id): \($0.name), \($0.category.rawValue), equipment \($0.equipment.map(\.rawValue).sorted().joined(separator: ","))" }
            .joined(separator: "\n")
        let avoided = preferences.avoidExerciseIDs.sorted().joined(separator: ", ")
        return """
        Build one \(preferences.sanitizedDuration)-minute \(preferences.focus.title.lowercased()) workout.
        Experience: \(preferences.experience.title).
        Available equipment: \(preferences.equipment.map(\.title).sorted().joined(separator: ", ")).
        Exercise IDs to avoid: \(avoided.isEmpty ? "none" : avoided).
        Person's notes: \(preferences.notes.prefix(500))

        You may use ONLY exact IDs from this catalog:
        \(allowed)

        Prefer a balanced, realistic session. Do not diagnose, prescribe rehabilitation, or invent movements.
        """
    }

    private static let instructions = """
    You assemble workouts only from the supplied exercise catalog. Return exact catalog IDs. The app validates every
    field, but you must still keep strength work between 1 and 6 sets, repetitions between 1 and 30, timed work between
    10 and 180 seconds, and rest between 10 and 180 seconds. Respect excluded movements and equipment. A person's note
    about pain means omit the related movement pattern; never offer treatment or medical advice.
    """
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedWorkoutPlan {
    @Guide(description: "A short workout title.")
    var title: String
    @Guide(description: "One concise sentence explaining how the plan fits the request.")
    var rationale: String
    @Guide(description: "Ordered workout exercises using only exact IDs supplied in the prompt.")
    var exercises: [GeneratedExercisePrescription]

    func asPlan(focus: WorkoutFocus, targetMinutes: Int) -> WorkoutPlan {
        WorkoutPlan(
            title: title,
            focus: focus,
            targetMinutes: targetMinutes,
            exercises: exercises.map {
                ExercisePrescription(
                    exerciseID: $0.exerciseID,
                    sets: $0.sets,
                    reps: $0.reps,
                    durationSeconds: $0.durationSeconds,
                    restSeconds: $0.restSeconds)
            },
            rationale: rationale)
    }
}

@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedExercisePrescription {
    @Guide(description: "An exact exercise ID from the supplied catalog.")
    var exerciseID: String
    @Guide(description: "Number of sets, from 1 through 6.")
    var sets: Int
    @Guide(description: "Repetitions per set for repetition exercises; nil for timed exercises.")
    var reps: Int?
    @Guide(description: "Seconds per set for timed exercises; nil for repetition exercises.")
    var durationSeconds: Int?
    @Guide(description: "Rest after each set in seconds, from 10 through 180.")
    var restSeconds: Int
}
#endif
